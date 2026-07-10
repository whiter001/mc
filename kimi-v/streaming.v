// streaming.v — raw TCP + SSE for OpenAI-compatible streaming endpoints.
//
// We can't use `net.http` for streaming because it buffers the full response
// before returning. So we write HTTP/1.1 manually against a raw TCP socket
// (or `SSLConn` for HTTPS) and parse the response line-by-line.
//
// Wire format (per OpenAI SSE spec):
//   POST /v1/chat/completions HTTP/1.1
//   Content-Type: application/json
//   Authorization: Bearer ...
//   ...
//
//   { "model": "...", "messages": [...], "stream": true }
//
// Response:
//   HTTP/1.1 200 OK
//   Content-Type: text/event-stream
//   ...
//
//   data: {"id":"...","choices":[{"delta":{"content":"Hello"},"index":0}]}
//   data: {"id":"...","choices":[{"delta":{"content":" world"},"index":0}]}
//   data: {"id":"...","choices":[{"delta":{},"finish_reason":"stop"}]}
//   data: [DONE]
//
// Tool calls stream as partial JSON in `tool_calls[i].function.arguments`. We
// buffer by index and emit a complete ToolCallEvent only when we see a
// finish_reason for that choice.
module main

import net
import net.openssl { SSLConn, SSLConnectConfig, new_ssl_conn }
import json
import strings
import time

// ---------- URL parsing ---------------------------------------------------

struct ParsedUrl {
pub:
	scheme string
	host   string
	port   int
	path   string
}

fn parse_url(raw string) !ParsedUrl {
	// Strip scheme://
	mut rest := raw
	mut scheme := 'http'
	if rest.starts_with('https://') {
		scheme = 'https'
		rest = rest[8..]
	} else if rest.starts_with('http://') {
		rest = rest[7..]
	}

	// Split host:port/path
	slash := rest.index('/') or { rest.len }
	host_port := rest[..slash]
	path := if slash < rest.len { rest[slash..] } else { '/' }

	mut host := host_port
	mut port := if scheme == 'https' { 443 } else { 80 }
	if c := host_port.index(':') {
		host = host_port[..c]
		port = host_port[c + 1..].int()
	}

	return ParsedUrl{
		scheme: scheme
		host:   host
		port:   port
		path:   path
	}
}

// ---------- StreamReader interface ---------------------------------------

interface StreamReader {
mut:
	read_line() !string
	close()
}

// ---------- Plain HTTP reader --------------------------------------------

struct HttpStreamReader {
mut:
	conn net.TcpConn
	// Carry-over buffer for bytes read past the end of the previous line.
	carry []u8
	// When true, the connection has signaled EOF.
	eof bool
}

fn (mut r HttpStreamReader) read_line() !string {
	if r.eof && r.carry.len == 0 {
		return error('eof')
	}
	mut acc := []u8{}
	// First, drain anything already buffered.
	for r.carry.len > 0 {
		b := r.carry[0]
		r.carry = r.carry[1..]
		acc << b
		if b == `\n` {
			mut end := acc.len - 1
			if end > 0 && acc[end - 1] == `\r` {
				end--
			}
			return acc[..end].bytestr()
		}
	}

	// Then keep reading from the socket until we see \n or EOF.
	mut buf := []u8{len: 4096}
	for !r.eof {
		n := r.conn.read(mut buf)!
		if n == 0 {
			r.eof = true
			break
		}
		for i in 0 .. n {
			acc << buf[i]
			if buf[i] == `\n` {
				// Stash any unread tail for next call.
				if i + 1 < n {
					r.carry = buf[i + 1..n].clone()
				}
				mut end := acc.len - 1
				if end > 0 && acc[end - 1] == `\r` {
					end--
				}
				return acc[..end].bytestr()
			}
		}
	}
	if acc.len == 0 {
		return error('eof')
	}
	// Trailing partial line (no terminating newline).
	mut end := acc.len
	if end > 0 && acc[end - 1] == `\r` {
		end--
	}
	return acc[..end].bytestr()
}

fn (mut r HttpStreamReader) close() {
	r.conn.close() or {}
}

// ---------- HTTPS reader (via OpenSSL) -----------------------------------
//
// `net.openssl` is a thin wrapper around libssl/libcrypto. macOS systems
// usually have LibreSSL (system) but Homebrew's openssl@3 works fine; V's
// `import net.openssl` adds `-lssl -lcrypto` and V's runtime resolves it
// against either. Linux distros ship OpenSSL directly.
//
// `HttpsStreamReader` mirrors `HttpStreamReader` but reads from an SSLConn.
// We keep the carry-buffer pattern so bytes read past a line terminator
// aren't lost.

struct HttpsStreamReader {
mut:
	ssl   &SSLConn
	carry []u8
	eof   bool
}

fn (mut r HttpsStreamReader) read_line() !string {
	if r.eof && r.carry.len == 0 {
		return error('eof')
	}
	mut acc := []u8{}
	for r.carry.len > 0 {
		b := r.carry[0]
		r.carry = r.carry[1..]
		acc << b
		if b == `\n` {
			mut end := acc.len - 1
			if end > 0 && acc[end - 1] == `\r` {
				end--
			}
			return acc[..end].bytestr()
		}
	}
	mut buf := []u8{len: 4096}
	for !r.eof {
		n := r.ssl.read(mut buf)!
		if n == 0 {
			r.eof = true
			break
		}
		for i in 0 .. n {
			acc << buf[i]
			if buf[i] == `\n` {
				if i + 1 < n {
					r.carry = buf[i + 1..n].clone()
				}
				mut end := acc.len - 1
				if end > 0 && acc[end - 1] == `\r` {
					end--
				}
				return acc[..end].bytestr()
			}
		}
	}
	if acc.len == 0 {
		return error('eof')
	}
	mut end := acc.len
	if end > 0 && acc[end - 1] == `\r` {
		end--
	}
	return acc[..end].bytestr()
}

fn (mut r HttpsStreamReader) close() {
	r.ssl.shutdown() or {}
}

// ---------- HTTP request helpers -----------------------------------------

fn http_post_streaming(url ParsedUrl, body string, headers map[string]string) !StreamReader {
	if url.scheme == 'https' {
		return https_post_streaming(url, body, headers)!
	}
	return http_post_streaming_plain(url, body, headers)!
}

fn http_post_streaming_plain(url ParsedUrl, body string, headers map[string]string) !StreamReader {
	mut req := 'POST ${url.path} HTTP/1.1\r\n'
	req += 'Host: ${url.host}:${url.port}\r\n'
	req += 'Accept: text/event-stream\r\n'
	req += 'Content-Type: application/json\r\n'
	req += 'Content-Length: ${body.len}\r\n'
	req += 'Connection: close\r\n'
	for k, v in headers {
		req += '${k}: ${v}\r\n'
	}
	req += '\r\n'
	req += body

	addr := '${url.host}:${url.port}'
	mut conn := net.dial_tcp(addr) or { return error('dial ${addr} failed: ${err.msg()}') }
	conn.set_read_timeout(60 * time.second)
	conn.write(req.bytes()) or {
		conn.close() or {}
		return error('write failed: ${err.msg()}')
	}

	// Status line
	mut reader := HttpStreamReader{
		conn: conn
	}
	status_line := reader.read_line() or {
		reader.close()
		return error('no status line: ${err.msg()}')
	}
	// Parse "HTTP/1.1 200 OK" — we accept anything 2xx.
	parts := status_line.split(' ')
	if parts.len < 2 || !parts[0].starts_with('HTTP/') {
		reader.close()
		return error('bad status line: ${status_line}')
	}
	status_code := parts[1].int()
	if status_code < 200 || status_code >= 300 {
		// Drain error body
		mut body_acc := strings.Builder{}
		for {
			l := reader.read_line() or { break }
			body_acc.write_string(l)
			body_acc.write_string('\n')
		}
		reader.close()
		return error('http ${status_code}: ${body_acc.str()}')
	}

	// Headers (until empty line)
	for {
		line := reader.read_line() or { break }
		if line.len == 0 {
			break
		}
	}

	// Wrap so the caller still uses StreamReader
	return reader
}

// https_post_streaming dials TLS, sends the request, and returns a reader
// bound to the SSLConn's read side. The TLS handshake is done here; if it
// fails, we surface the error before sending any bytes.
fn https_post_streaming(url ParsedUrl, body string, headers map[string]string) !StreamReader {
	mut ssl := new_ssl_conn(SSLConnectConfig{})!
	ssl.dial(url.host, url.port) or {
		return error('tls dial ${url.host}:${url.port} failed: ${err.msg()}')
	}

	mut req := 'POST ${url.path} HTTP/1.1\r\n'
	req += 'Host: ${url.host}\r\n'
	req += 'Accept: text/event-stream\r\n'
	req += 'Content-Type: application/json\r\n'
	req += 'Content-Length: ${body.len}\r\n'
	req += 'Connection: close\r\n'
	for k, v in headers {
		req += '${k}: ${v}\r\n'
	}
	req += '\r\n'
	req += body

	ssl.write(req.bytes()) or {
		ssl.shutdown() or {}
		return error('tls write failed: ${err.msg()}')
	}

	mut reader := HttpsStreamReader{
		ssl: ssl
	}
	status_line := reader.read_line() or {
		reader.close()
		return error('no status line: ${err.msg()}')
	}
	parts := status_line.split(' ')
	if parts.len < 2 || !parts[0].starts_with('HTTP/') {
		reader.close()
		return error('bad status line: ${status_line}')
	}
	status_code := parts[1].int()
	if status_code < 200 || status_code >= 300 {
		mut body_acc := strings.Builder{}
		for {
			l := reader.read_line() or { break }
			body_acc.write_string(l)
			body_acc.write_string('\n')
		}
		reader.close()
		return error('http ${status_code}: ${body_acc.str()}')
	}

	for {
		line := reader.read_line() or { break }
		if line.len == 0 {
			break
		}
	}
	return reader
}

// ---------- SSE parsing --------------------------------------------------

struct OaiStreamChunk {
pub:
	id      string            @[json: id]
	model   string            @[json: model]
	choices []OaiStreamChoice @[json: choices]
	usage   ?OaiStreamUsage   @[json: usage]
}

struct OaiStreamChoice {
pub:
	index         int            @[json: index]
	delta         OaiStreamDelta @[json: delta]
	finish_reason ?string        @[json: finish_reason]
}

struct OaiStreamDelta {
pub:
	content    string                      @[json: content]
	role       string                      @[json: role]
	tool_calls ?[]OaiStreamToolCallPartial @[json: tool_calls]
}

struct OaiStreamToolCallPartial {
pub:
	index    ?int          @[json: index]
	id       string        @[json: id]
	typ      string        @[json: type]
	function OaiCallFnPart @[json: function]
}

struct OaiCallFnPart {
pub:
	name      string @[json: name]
	arguments string @[json: arguments]
}

struct OaiStreamUsage {
pub:
	prompt_tokens     int @[json: prompt_tokens]
	completion_tokens int @[json: completion_tokens]
	total_tokens      int @[json: total_tokens]
}

// SseParser walks an SSE byte stream and emits ChatEvents into `out`.
// It buffers tool-call JSON per choice index so we can emit a complete
// ToolCall once we see finish_reason for that choice.
struct SseParser {
pub mut:
	// tool_calls[index] = accumulated (id, name, arguments)
	tool_calls map[int]SsePendingToolCall
	// was any text emitted? used to ensure at least one delta.
	saw_content bool
}

struct SsePendingToolCall {
pub mut:
	id        string
	name      string
	arguments strings.Builder
}

fn new_sse_parser() SseParser {
	return SseParser{
		tool_calls: map[int]SsePendingToolCall{}
	}
}

fn (mut p SseParser) feed(event_data string, out chan ChatEvent) {
	chunk := json.decode(OaiStreamChunk, event_data) or { return }

	for choice in chunk.choices {
		// Text delta
		if choice.delta.content.len > 0 {
			p.saw_content = true
			out <- ChatEvent{
				kind:    .delta
				content: choice.delta.content
			}
		}

		// Tool call deltas — accumulate by index.
		if tcs := choice.delta.tool_calls {
			for tc in tcs {
				idx := tc.index or { 0 }
				if tc.id.len > 0 || tc.function.name.len > 0 || tc.function.arguments.len > 0 {
					if idx in p.tool_calls {
						// Existing entry; append.
						mut existing := p.tool_calls[idx] or { continue }
						if tc.id.len > 0 {
							existing.id = tc.id
						}
						if tc.function.name.len > 0 {
							existing.name = tc.function.name
						}
						existing.arguments.write_string(tc.function.arguments)
						p.tool_calls[idx] = existing
					} else {
						mut bld := strings.Builder{}
						bld.write_string(tc.function.arguments)
						p.tool_calls[idx] = SsePendingToolCall{
							id:        tc.id
							name:      tc.function.name
							arguments: bld
						}
					}
				}
			}
		}

		// finish_reason for this choice — flush any accumulated tool call.
		if reason := choice.finish_reason {
			eprintln('[sse] finish_reason=${reason}')
			if reason == 'tool_calls' {
				// Emit each accumulated tool call.
				for idx, mut call in p.tool_calls {
					out <- ChatEvent{
						kind:      .tool_call
						index:     idx
						id:        call.id
						name:      call.name
						arguments: call.arguments.str()
					}
				}
			}
			out <- ChatEvent{
				kind:   .finish
				reason: parse_finish_reason(reason)
			}
		}
	}

	// Usage arrives in a separate chunk after finish_reason (when the
	// provider sends `stream_options.include_usage: true`). Emit it as a
	// dedicated .usage event; the agent loop collects it and patches the
	// finish event's input_tokens/output_tokens.
	if u := chunk.usage {
		out <- ChatEvent{
			kind:          .usage
			input_tokens:  u.prompt_tokens
			output_tokens: u.completion_tokens
		}
	}
}

// read_sse_stream drives a StreamReader, parses SSE events, and emits
// ChatEvents into `out`. Returns when the connection closes or the stream
// signals [DONE].
fn read_sse_stream(mut reader StreamReader, out chan ChatEvent) ! {
	defer {
		reader.close()
	}

	mut current_data := strings.Builder{}
	for {
		line := reader.read_line() or { break }
		if line.len == 0 {
			// End of one SSE event — dispatch if there's data.
			if current_data.len > 0 {
				data := current_data.str()
				current_data = strings.Builder{}
				if data.trim_space() == '[DONE]' {
					return
				}
				mut parser := new_sse_parser()
				parser.feed(data, out)
			}
			continue
		}
		if line.starts_with('data:') {
			mut payload := line[5..]
			// Strip leading space if present.
			if payload.len > 0 && payload[0] == ` ` {
				payload = payload[1..]
			}
			if current_data.len > 0 {
				current_data.write_string('\n')
			}
			current_data.write_string(payload)
		}
		// Ignore `event:`, `id:`, `retry:`, comments (`:`).
	}
}
