// internal/llm/openai_compat.v
// OpenAI-compatible chat completions provider. Kimi, DeepSeek, Together,
// OpenRouter, and a long tail of providers speak this protocol, so it's the
// natural default for the V rewrite.
//
// P0: non-streaming (we issue one HTTP request and emit the result as a
// single delta + finish event). Streaming via raw TCP lives in streaming.v
// and will replace this in P0.5.
module main

import json2
import net.http

// OpenAICompatProvider implements an OpenAI-compatible chat completions client.
pub struct OpenAICompatProvider {
pub:
	name     string = 'openai-compat'
	model    string
	api_base string = 'https://api.openai.com'
	api_key  string
}

// ---- Wire types (only the fields we actually need) -----------------------

struct StreamOptions {
	include_usage bool @[json: include_usage]
}

struct OaiRequestT {
	model           string            @[json: model]
	messages        []OaiReqMessageT  @[json: messages]
	tools           []OaiToolT        @[json: tools]
	temperature     f32               @[json: temperature]
	max_tokens      int               @[json: max_tokens]
	stream          bool              @[json: stream]
	reasoning_split bool              @[json: reasoning_split]
	stream_options  ?StreamOptions    @[json: stream_options]
}

struct OaiMessageT {
	role         string          @[json: role]
	content      string          @[json: content]
	tool_calls   ?[]OaiToolCallT @[json: tool_calls]
	tool_call_id string          @[json: tool_call_id]
	name         string          @[json: name]
}

// OaiReqMessageT is the wire shape we send TO the provider. Unlike
// OaiMessageT (the response side, which always sees `content` as a
// string), the request side always uses the array form for `content`.
// The OpenAI-compatible protocol accepts both string and array
// content; arrays are required for multimodal (image_url) and we
// use the same shape uniformly so a single encoder handles text-only
// and image-bearing messages. P0.7: image attachments.
//
// Wire shape:
//
//	{"role":"user","content":[
//	  {"type":"text","text":"look at this"},
//	  {"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}
//	]}
struct OaiReqMessageT {
	role         string            @[json: role]
	content      []OaiContentPartT @[json: content]
	tool_calls   ?[]OaiToolCallT   @[json: tool_calls]
	tool_call_id string            @[json: tool_call_id]
	name         string            @[json: name]
}

// OaiContentPartT is one element of the request content array. Either
// `text` or `image_url` is set, never both. The optional fields are
// tagged with `?` so the JSON encoder omits the unset one — text
// parts get `{"type":"text","text":"..."}`, image parts get
// `{"type":"image_url","image_url":{"url":"..."}}`.
struct OaiContentPartT {
	typ       string        @[json: type]
	text      ?string       @[json: text]
	image_url ?OaiImageUrlT @[json: image_url]
}

struct OaiImageUrlT {
	url string @[json: url]
}

struct OaiToolT {
	typ      string     @[json: type]
	function OaiToolFnT @[json: function]
}

struct OaiToolFnT {
	name        string @[json: name]
	description string @[json: description]
	parameters  RawJson @[json: parameters] // Raw JSON object (no extra quotes)
}

// RawJson is a wrapper that serializes its string value as-is (not as a quoted string).
// This lets us pass pre-encoded JSON objects without re-parsing them.
struct RawJson {
mut:
	data string
}

fn (r RawJson) str() string {
	return r.data
}

fn (r RawJson) json() string {
	return r.data
}

struct OaiToolCallT {
	id       string     @[json: id]
	typ      string     @[json: type]
	function OaiCallFnT @[json: function]
}

struct OaiCallFnT {
	name      string @[json: name]
	arguments string @[json: arguments]
}

struct OaiResponseT {
	id      string       @[json: id]
	model   string       @[json: model]
	choices []OaiChoiceT @[json: choices]
	usage   ?OaiUsageT   @[json: usage]
	error   ?OaiErrorT   @[json: error]
}

struct OaiChoiceT {
	index         int         @[json: index]
	message       OaiMessageT @[json: message]
	finish_reason string      @[json: finish_reason]
}

struct OaiUsageT {
	prompt_tokens     int @[json: prompt_tokens]
	completion_tokens int @[json: completion_tokens]
	total_tokens      int @[json: total_tokens]
}

struct OaiErrorT {
	message string @[json: message]
	typ     string @[json: type]
	code    string @[json: code]
}

// ---- Translate our canonical types into the wire form --------------------

// build_request translates a ChatRequest into the non-streaming wire payload.
fn (p OpenAICompatProvider) build_request(req ChatRequest) OaiRequestT {
	mut msgs := []OaiReqMessageT{}
	for m in req.messages {
		mut tcs := if m.tool_calls.len > 0 { []OaiToolCallT{} } else { []OaiToolCallT{} }
		for c in m.tool_calls {
			tcs << OaiToolCallT{
				id:       c.id
				typ:      'function'
				function: OaiCallFnT{
					name:      c.name
					arguments: c.arguments
				}
			}
		}
		parts := build_content_parts(m)
		msgs << OaiReqMessageT{
			role:         m.role.str()
			content:      parts
			tool_calls:   if tcs.len > 0 { tcs } else { none }
			tool_call_id: m.tool_call_id
			name:         m.name
		}
	}

	tools := build_tools_array(req.tools)
	return OaiRequestT{
		model:       req.model
		messages:    msgs
		tools:       tools
		temperature: req.temperature
		max_tokens:  req.max_tokens
		stream:      false
		reasoning_split: true
		stream_options:  none
	}
}

// build_content_parts translates a canonical Message into the wire
// content array used by OaiReqMessageT. The array always has at least
// one element — the OpenAI API rejects an empty `content` array, so
// when the message has no text and no attachments we emit a single
// empty text part (which mirrors how text-only messages are sent).
//
// Order matters: text part first, then attachments. The model reads
// the text as the user's "ask" and the images as supporting context;
// the order we send is the order the model sees.
pub fn build_content_parts(m Message) []OaiContentPartT {
	mut parts := []OaiContentPartT{}
	if m.content.len > 0 {
		parts << OaiContentPartT{
			typ:       'text'
			text:      m.content
			image_url: none
		}
	}
	for att in m.attachments {
		parts << OaiContentPartT{
			typ:       'image_url'
			text:      none
			image_url: OaiImageUrlT{ url: 'data:${att.mime};base64,${att.b64}' }
		}
	}
	if parts.len == 0 {
		// Edge case: empty user submit. Send a single empty text part
		// so the wire form is well-formed. The provider will see an
		// empty user turn and respond appropriately (often an error or
		// a clarification request).
		parts << OaiContentPartT{
			typ:       'text'
			text:      ''
			image_url: none
		}
	}
	return parts
}

// build_tools_array converts ToolDef values into the OpenAI tool schema.
fn build_tools_array(tools []ToolDef) []OaiToolT {
	mut out := []OaiToolT{cap: tools.len}
	for t in tools {
		out << OaiToolT{
			typ:      'function'
			function: OaiToolFnT{
				name:        t.name
				description: t.description
				parameters:  RawJson{t.parameters}
			}
		}
	}
	return out
}

fn parse_finish_reason(s string) FinishReason {
	return match s {
		'stop' { .stop }
		'length' { .length }
		'tool_calls' { .tool_calls }
		'content_filter' { .content_filter }
		'' { .unknown }
		else { .unknown }
	}
}

// ---- chat() implementation ----------------------------------------------

// chat sends a chat request and streams the response as ChatEvents.
pub fn (p OpenAICompatProvider) chat(req ChatRequest, out chan ChatEvent, cancel_ch chan int) ! {
	// P0.6: real streaming for both http:// and https://. streaming.v's
	// http_post_streaming() dispatches by URL scheme; HTTPS uses the
	// OpenSSL binding (net.openssl) for true wire-level streaming.
	url_str := '${p.api_base}/v1/chat/completions'
	parsed_url := parse_url(url_str) or {
		out <- ChatEvent{
			kind: .err_kind
			err:  'bad url: ${err.msg()}'
		}
		return
	}

	if parsed_url.scheme == 'http' || parsed_url.scheme == 'https' {
		chat_streaming_http(p, parsed_url, req, out, cancel_ch) or {
			// ProviderError carries a retryable flag (429 / 5xx / dial
			// failures); anything else here is a mid-stream read failure,
			// which is a network problem and also worth retrying.
			retry := if err is ProviderError { err.retryable } else { true }
			out <- ChatEvent{
				kind:      .err_kind
				err:       'streaming failed: ${err.msg()}'
				retryable: retry
			}
		}
	} else {
		// Anything else (e.g. file://, ws://): fall back to non-streaming
		// POST via V's stdlib HTTP client.
		chat_buffered_https(p, req, out, cancel_ch)
	}
	// Sentinel: the consumer reads events until it sees this, then knows
	// the stream is fully drained. Required because `finish` and `usage`
	// arrive in separate chunks and the consumer must keep reading past
	// `finish` to capture `usage`.
	//
	// Always sent, even after a cancel — the agent has spawned a
	// drainer goroutine on cancel to absorb any buffered events; the
	// sentinel lets the drainer exit cleanly when it then sees `close`.
	out <- ChatEvent{ kind: .end_of_stream }
	out.close()
}

// chat_streaming_http issues a streaming HTTP request and feeds SSE events to out.
fn chat_streaming_http(p OpenAICompatProvider, url ParsedUrl, req ChatRequest, out chan ChatEvent, cancel_ch chan int) ! {
	wire := build_streaming_request(p, req)
	body := json2.encode(wire)

	mut reader := http_post_streaming(url, body, {
		'Authorization': 'Bearer ${p.api_key}'
	})!

	read_sse_stream(mut reader, out, cancel_ch)!
}

// build_streaming_request builds the wire payload for a streaming chat request.
fn build_streaming_request(_ OpenAICompatProvider, req ChatRequest) OaiRequestT {
	mut msgs := []OaiReqMessageT{cap: req.messages.len}
	for m in req.messages {
		mut tcs := []OaiToolCallT{}
		for c in m.tool_calls {
			tcs << OaiToolCallT{
				id:       c.id
				typ:      'function'
				function: OaiCallFnT{
					name:      c.name
					arguments: c.arguments
				}
			}
		}
		parts := build_content_parts(m)
		msgs << OaiReqMessageT{
			role:         m.role.str()
			content:      parts
			tool_calls:   if tcs.len > 0 { tcs } else { none }
			tool_call_id: m.tool_call_id
			name:         m.name
		}
	}

	tools := build_tools_array(req.tools)
	return OaiRequestT{
		model:       req.model
		messages:    msgs
		tools:       tools
		temperature: req.temperature
		max_tokens:  req.max_tokens
		stream:      true
		reasoning_split: true
		stream_options:  StreamOptions{ include_usage: true }
	}
}

// chat_buffered_https is the non-streaming fallback using V's net.http client.
fn chat_buffered_https(p OpenAICompatProvider, req ChatRequest, out chan ChatEvent, cancel_ch chan int) {
	// Non-streaming fallback: a single blocking HTTP call. The cancel
	// channel isn't checked here because the fetch runs to completion
	// (or fails); cancellation at this layer is best-effort.
	_ = cancel_ch
	wire := p.build_request(req)
	body := json2.encode(wire)

	url := '${p.api_base}/v1/chat/completions'
	header := http.new_header(http.HeaderConfig{ key: .content_type, value: 'application/json' }, http.HeaderConfig{
		key:   .authorization
		value: 'Bearer ${p.api_key}'
	})

	resp := http.fetch(http.FetchConfig{
		url:    url
		method: .post
		header: header
		data:   body
	}) or {
		// Network-level failure (DNS / connect / TLS / timeout) — transient.
		out <- ChatEvent{
			kind:      .err_kind
			err:       'http error: ${err.msg()}'
			retryable: true
		}
		return
	}

	if resp.status_code != 200 {
		retry := is_retryable_status(resp.status_code)
		if err_resp := json2.decode[OaiResponseT](resp.body) {
			if err_resp.error != none {
				e := err_resp.error or { return }
				out <- ChatEvent{
					kind:      .err_kind
					err:       'http ${resp.status_code}: ${e.message}'
					retryable: retry
				}
				return
			}
		}
		out <- ChatEvent{
			kind:      .err_kind
			err:       'http ${resp.status_code}: ${resp.body}'
			retryable: retry
		}
		return
	}

	parsed := json2.decode[OaiResponseT](resp.body) or {
		out <- ChatEvent{
			kind: .err_kind
			err:  'parse error: ${err.msg()}'
		}
		return
	}

	if parsed.error != none {
		e := parsed.error or { return }
		out <- ChatEvent{
			kind: .err_kind
			err:  '${e.typ}: ${e.message}'
		}
		return
	}

	if parsed.choices.len == 0 {
		out <- ChatEvent{
			kind: .err_kind
			err:  'provider returned no choices'
		}
		return
	}

	choice := parsed.choices[0]
	msg := choice.message

	if msg.content.len > 0 {
		out <- ChatEvent{
			kind:    .delta
			content: msg.content
		}
	}

	mut idx := 0
	if tcs := msg.tool_calls {
		for c in tcs {
			out <- ChatEvent{
				kind:      .tool_call
				index:     idx
				id:        c.id
				name:      c.function.name
				arguments: c.function.arguments
			}
			idx++
		}
	}

	mut fin_input := 0
	mut fin_output := 0
	if u := parsed.usage {
		fin_input = u.prompt_tokens
		fin_output = u.completion_tokens
	}
	out <- ChatEvent{
		kind:          .finish
		reason:        parse_finish_reason(choice.finish_reason)
		input_tokens:  fin_input
		output_tokens: fin_output
	}
}
