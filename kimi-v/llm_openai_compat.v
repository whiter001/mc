// internal/llm/openai_compat.v
// OpenAI-compatible chat completions provider. Kimi, DeepSeek, Together,
// OpenRouter, and a long tail of providers speak this protocol, so it's the
// natural default for the V rewrite.
//
// P0: non-streaming (we issue one HTTP request and emit the result as a
// single delta + finish event). Streaming via raw TCP lives in streaming.v
// and will replace this in P0.5.
module main

import json
import net.http

pub struct OpenAICompatProvider {
pub:
	name     string = 'openai-compat'
	model    string
	api_base string = 'https://api.openai.com'
	api_key  string
pub mut:
	unused int
}

// ---- Wire types (only the fields we actually need) -----------------------

struct OaiRequestT {
	model       string        @[json: model]
	messages    []OaiMessageT @[json: messages]
	tools       []OaiToolT    @[json: tools]
	temperature f32           @[json: temperature]
	max_tokens  int           @[json: max_tokens]
	stream      bool          @[json: stream]
}

struct OaiMessageT {
	role         string          @[json: role]
	content      string          @[json: content]
	tool_calls   ?[]OaiToolCallT @[json: tool_calls]
	tool_call_id string          @[json: tool_call_id]
	name         string          @[json: name]
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

fn (p OpenAICompatProvider) build_request(req ChatRequest) OaiRequestT {
	mut msgs := []OaiMessageT{}
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
		msgs << OaiMessageT{
			role:         m.role.str()
			content:      m.content
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
	}
}

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

pub fn (p OpenAICompatProvider) chat(req ChatRequest, out chan ChatEvent) ! {
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
		chat_streaming_http(p, parsed_url, req, out) or {
			out <- ChatEvent{
				kind: .err_kind
				err:  'streaming failed: ${err.msg()}'
			}
		}
	} else {
		// Anything else (e.g. file://, ws://): fall back to non-streaming
		// POST via V's stdlib HTTP client.
		chat_buffered_https(p, req, out)
	}
	// Sentinel: the consumer reads events until it sees this, then knows
	// the stream is fully drained. Required because `finish` and `usage`
	// arrive in separate chunks and the consumer must keep reading past
	// `finish` to capture `usage`.
	out <- ChatEvent{ kind: .end_of_stream }
	out.close()
}

fn chat_streaming_http(p OpenAICompatProvider, url ParsedUrl, req ChatRequest, out chan ChatEvent) ! {
	wire := build_streaming_request(p, req)
	body := json.encode(wire)

	mut reader := http_post_streaming(url, body, {
		'Authorization': 'Bearer ${p.api_key}'
	})!

	read_sse_stream(mut reader, out)!
}

fn build_streaming_request(p OpenAICompatProvider, req ChatRequest) OaiRequestT {
	mut msgs := []OaiMessageT{cap: req.messages.len}
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
		msgs << OaiMessageT{
			role:         m.role.str()
			content:      m.content
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
	}
}

fn chat_buffered_https(p OpenAICompatProvider, req ChatRequest, out chan ChatEvent) {
	wire := p.build_request(req)
	body := json.encode(wire)

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
		out <- ChatEvent{
			kind: .err_kind
			err:  'http error: ${err.msg()}'
		}
		return
	}

	if resp.status_code != 200 {
		if err_resp := json.decode(OaiResponseT, resp.body) {
			if err_resp.error != none {
				e := err_resp.error or { return }
				out <- ChatEvent{
					kind: .err_kind
					err:  'http ${resp.status_code}: ${e.message}'
				}
				return
			}
		}
		out <- ChatEvent{
			kind: .err_kind
			err:  'http ${resp.status_code}: ${resp.body}'
		}
		return
	}

	parsed := json.decode(OaiResponseT, resp.body) or {
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
