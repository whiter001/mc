// llm_anthropic.v — Anthropic Messages API provider (Claude).
//
// Wire format:
//   POST {api_base}/v1/messages
//   x-api-key: <key>, anthropic-version: 2023-06-01
//   {
//     "model": "...", "max_tokens": N, "system": "...",
//     "messages": [{ "role": "user", "content": [{ "type": "text", "text": "..." }] }],
//     "tools": [{ "name": "...", "description": "...", "input_schema": {...} }],
//     "stream": true
//   }
//
// Response (SSE, one JSON object per `data:` line, discriminated by `type`):
//   {"type":"message_start","message":{...,"usage":{"input_tokens":25}}}
//   {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
//   {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
//   {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"..."}}
//   {"type":"content_block_stop","index":0}
//   {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":15}}
//   {"type":"message_stop"}
//   {"type":"error","error":{"type":"overloaded_error","message":"..."}}
//
// NOTE on request encoding: V 0.5's `json.encode` no longer honors custom
// `json()` hooks (llm_openai_compat.v's RawJson relies on that trick), so a
// pre-encoded JSON object can't be embedded through struct encoding. We
// hand-assemble the request body instead: string values are escaped with
// `json.encode(s)` (which returns a quoted literal), pre-encoded JSON
// (`input`, `input_schema`) is spliced in verbatim, and numbers are
// interpolated directly.
module main

import json
import strings
import time

// AnthropicProvider implements an Anthropic Messages API client.
pub struct AnthropicProvider {
pub:
	name     string = 'anthropic'
	model    string
	api_base string = 'https://api.anthropic.com'
	api_key  string
}

// json_lit returns s as a quoted, escaped JSON string literal.
fn json_lit(s string) string {
	return json.encode(s)
}

// ---- Request body assembly -----------------------------------------------

// anthropic_system_prompt concatenates all system messages (the Messages API
// takes system prompts in a top-level `system` field, not as messages).
pub fn anthropic_system_prompt(messages []Message) string {
	mut parts := []string{}
	for m in messages {
		if m.role == .system && m.content.len > 0 {
			parts << m.content
		}
	}
	return parts.join('\n\n')
}

fn anthropic_text_block(text string) string {
	return '{"type":"text","text":${json_lit(text)}}'
}

fn anthropic_image_block(mime string, b64 string) string {
	return '{"type":"image","source":{"type":"base64","media_type":${json_lit(mime)},"data":${json_lit(b64)}}}'
}

// anthropic_tool_use_block renders an assistant tool call. `arguments` is a
// pre-encoded JSON object string; it is spliced into the `input` field
// verbatim.
fn anthropic_tool_use_block(id string, name string, arguments string) string {
	arg := if arguments.trim_space().len > 0 { arguments } else { '{}' }
	return '{"type":"tool_use","id":${json_lit(id)},"name":${json_lit(name)},"input":${arg}}'
}

// anthropic_tool_result_block renders a tool result. `content` may be a plain
// string or a pre-encoded JSON array of blocks; the Messages API accepts both.
fn anthropic_tool_result_block(tool_use_id string, content string) string {
	return '{"type":"tool_result","tool_use_id":${json_lit(tool_use_id)},"content":${json_lit(content)}}'
}

fn anthropic_message_wire(role string, blocks []string) string {
	return '{"role":${json_lit(role)},"content":[${blocks.join(',')}]}'
}

// anthropic_wire_messages renders the JSON array of wire messages. System
// messages go to the top-level `system` field (see anthropic_system_prompt),
// not here. Consecutive .tool messages group into one user message of
// tool_result blocks; assistant tool_calls become tool_use blocks; image
// attachments become image blocks. Anthropic requires the conversation to
// start with a user message, so a leading assistant message gets a synthetic
// empty user message prepended.
pub fn anthropic_wire_messages(messages []Message) string {
	mut parts := []string{}
	mut first_role := ''
	mut i := 0
	for i < messages.len {
		m := messages[i]
		if m.role == .system {
			i++
			continue
		}
		if m.role == .tool {
			mut blocks := []string{}
			for i < messages.len && messages[i].role == .tool {
				tm := messages[i]
				blocks << anthropic_tool_result_block(tm.tool_call_id, tm.content)
				i++
			}
			parts << anthropic_message_wire('user', blocks)
			if first_role.len == 0 {
				first_role = 'user'
			}
			continue
		}
		mut blocks := []string{}
		if m.content.len > 0 {
			blocks << anthropic_text_block(m.content)
		}
		for att in m.attachments {
			blocks << anthropic_image_block(att.mime, att.b64)
		}
		if m.role == .assistant {
			for tc in m.tool_calls {
				blocks << anthropic_tool_use_block(tc.id, tc.name, tc.arguments)
			}
		}
		if blocks.len == 0 {
			blocks << anthropic_text_block('')
		}
		parts << anthropic_message_wire(m.role.str(), blocks)
		if first_role.len == 0 {
			first_role = m.role.str()
		}
		i++
	}
	if first_role == 'assistant' {
		parts.prepend(anthropic_message_wire('user', [anthropic_text_block('')]))
	}
	return '[' + parts.join(',') + ']'
}

// anthropic_tools_wire renders the tools array. Each ToolDef.parameters is a
// pre-encoded JSON Schema object spliced verbatim into `input_schema`.
pub fn anthropic_tools_wire(tools []ToolDef) string {
	mut parts := []string{}
	for t in tools {
		schema := if t.parameters.trim_space().len > 0 { t.parameters } else { '{}' }
		parts << '{"name":${json_lit(t.name)},"description":${json_lit(t.description)},"input_schema":${schema}}'
	}
	return '[' + parts.join(',') + ']'
}

// build_anthropic_body renders the full request body for the Messages API.
pub fn build_anthropic_body(req ChatRequest) string {
	return '{"model":${json_lit(req.model)},"max_tokens":${req.max_tokens},"system":${json_lit(anthropic_system_prompt(req.messages))},"messages":${anthropic_wire_messages(req.messages)},"tools":${anthropic_tools_wire(req.tools)},"stream":true}'
}

// ---- SSE event types (decode side only) ----------------------------------
//
// V 0.5's json.decode ignores missing fields, so every field is optional
// except the discriminator; ?-wrapped fields are used where a key is absent
// from some event types.

struct AnthropicEventT {
	typ           string                      @[json: type]
	message       ?AnthropicMessageT          @[json: message]
	index         ?int                        @[json: index]
	content_block ?AnthropicContentBlockStart @[json: content_block]
	delta         ?AnthropicDeltaT            @[json: delta]
	usage         ?AnthropicUsageT            @[json: usage]
	error         ?AnthropicErrT              @[json: error]
}

struct AnthropicMessageT {
	id    string           @[json: id]
	model string           @[json: model]
	usage ?AnthropicUsageT @[json: usage]
}

struct AnthropicContentBlockStart {
	typ  string @[json: type]
	text string @[json: text]
	id   string @[json: id]
	name string @[json: name]
}

struct AnthropicDeltaT {
	typ          string @[json: type]
	text         string @[json: text]
	partial_json string @[json: partial_json]
	stop_reason  string @[json: stop_reason]
}

struct AnthropicUsageT {
	input_tokens  int @[json: input_tokens]
	output_tokens int @[json: output_tokens]
}

struct AnthropicErrT {
	typ     string @[json: type]
	message string @[json: message]
}

// ---- SSE parser ----------------------------------------------------------

// AnthropicPendingToolUse accumulates a tool_use block's id/name and the
// input_json_delta fragments of its `input` argument.
struct AnthropicPendingToolUse {
pub mut:
	id        string
	name      string
	arguments strings.Builder
}

// AnthropicSseParser walks Anthropic SSE data payloads and emits ChatEvents.
struct AnthropicSseParser {
pub mut:
	// tool_uses[index] = accumulated (id, name, arguments)
	tool_uses     map[int]AnthropicPendingToolUse
	input_tokens  int
	output_tokens int
	stop_reason   string
}

fn new_anthropic_parser() AnthropicSseParser {
	return AnthropicSseParser{
		tool_uses: map[int]AnthropicPendingToolUse{}
	}
}

// feed decodes one SSE data payload and emits the corresponding ChatEvents.
fn (mut p AnthropicSseParser) feed(event_data string, out chan ChatEvent, cancel_ch chan int) {
	ev := json.decode(AnthropicEventT, event_data) or {
		return
	}
	// Non-blocking cancel check before processing the event.
	select {
		_ := <-cancel_ch {
			return
		}
		1 * time.millisecond {
			// no cancel signal in time; fall through
		}
	}
	match ev.typ {
		'message_start' {
			// Record the input token count; no event emitted.
			if m := ev.message {
				if u := m.usage {
					p.input_tokens = u.input_tokens
				}
			}
		}
		'content_block_start' {
			if cb := ev.content_block {
				if cb.typ == 'tool_use' {
					idx := ev.index or { 0 }
					p.tool_uses[idx] = AnthropicPendingToolUse{
						id:   cb.id
						name: cb.name
						arguments: strings.Builder{}
					}
				}
			}
		}
		'content_block_delta' {
			d := ev.delta or { return }
			idx := ev.index or { 0 }
			if d.typ == 'text_delta' && d.text.len > 0 {
				out <- ChatEvent{
					kind:    .delta
					content: d.text
				}
			} else if d.typ == 'input_json_delta' {
				if idx in p.tool_uses {
					mut existing := p.tool_uses[idx] or { return }
					existing.arguments.write_string(d.partial_json)
					p.tool_uses[idx] = existing
				}
			}
		}
		'content_block_stop' {
			idx := ev.index or { 0 }
			if idx in p.tool_uses {
				mut pending := p.tool_uses[idx] or { return }
				out <- ChatEvent{
					kind:      .tool_call
					index:     idx
					id:        pending.id
					name:      pending.name
					arguments: pending.arguments.str()
				}
				p.tool_uses.delete(idx)
			}
		}
		'message_delta' {
			if d := ev.delta {
				if d.stop_reason.len > 0 {
					p.stop_reason = d.stop_reason
				}
			}
			if u := ev.usage {
				p.output_tokens = u.output_tokens
				if u.input_tokens > 0 {
					p.input_tokens = u.input_tokens
				}
			}
			out <- ChatEvent{
				kind:          .finish
				reason:        anthropic_stop_reason(p.stop_reason)
				input_tokens:  p.input_tokens
				output_tokens: p.output_tokens
			}
		}
		'error' {
			if e := ev.error {
				out <- ChatEvent{
					kind:      .err_kind
					err:       'anthropic ${e.typ}: ${e.message}'
					retryable: anthropic_error_retryable(e.typ)
				}
			} else {
				out <- ChatEvent{
					kind: .err_kind
					err:  'anthropic error event'
				}
			}
		}
		else {}
	}
}

// anthropic_stop_reason maps an Anthropic stop_reason to FinishReason.
pub fn anthropic_stop_reason(s string) FinishReason {
	return match s {
		'end_turn' { .stop }
		'tool_use' { .tool_calls }
		'max_tokens' { .length }
		'stop_sequence' { .stop }
		else { .unknown }
	}
}

// anthropic_error_retryable reports whether an Anthropic error type is worth
// retrying. overloaded_error and rate_limit_error are transient; the rest
// (invalid_request_error, api_error, authentication_error, ...) are not.
pub fn anthropic_error_retryable(err_type string) bool {
	return err_type == 'overloaded_error' || err_type == 'rate_limit_error'
}

// read_anthropic_sse drives a StreamReader, parses SSE events, and emits
// ChatEvents into `out`. Same framing loop as read_sse_stream (streaming.v);
// Anthropic has no [DONE] sentinel — the stream just closes after
// `message_stop`.
fn read_anthropic_sse(mut reader StreamReader, out chan ChatEvent, cancel_ch chan int) ! {
	defer {
		reader.close()
	}

	mut parser := new_anthropic_parser()
	mut current_data := strings.Builder{}
	for {
		// Check for cancellation before each read (non-blocking; the reader
		// itself is blocking).
		select {
			_ := <-cancel_ch {
				return
			}
			1 * time.millisecond {
				// no cancel signal in time; fall through
			}
		}
		line := reader.read_line() or { break }
		if line.len == 0 {
			// End of one SSE event — dispatch if there's data.
			if current_data.len > 0 {
				data := current_data.str()
				current_data = strings.Builder{}
				if data.trim_space().len > 0 {
					parser.feed(data, out, cancel_ch)
				}
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

// ---- chat() implementation ----------------------------------------------

// chat sends a chat request and streams the response as ChatEvents.
pub fn (p AnthropicProvider) chat(req ChatRequest, out chan ChatEvent, cancel_ch chan int) ! {
	url_str := '${p.api_base}/v1/messages'
	parsed_url := parse_url(url_str) or {
		out <- ChatEvent{
			kind: .err_kind
			err:  'bad url: ${err.msg()}'
		}
		return
	}

	if parsed_url.scheme == 'http' || parsed_url.scheme == 'https' {
		chat_anthropic_streaming(p, parsed_url, req, out, cancel_ch) or {
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
		out <- ChatEvent{
			kind: .err_kind
			err:  'unsupported URL scheme for anthropic: ${parsed_url.scheme}'
		}
	}
	// Sentinel: the consumer reads events until it sees this, then knows
	// the stream is fully drained. Always sent, even after a cancel.
	out <- ChatEvent{ kind: .end_of_stream }
	out.close()
}

// chat_anthropic_streaming issues a streaming request and feeds SSE events to out.
fn chat_anthropic_streaming(p AnthropicProvider, url ParsedUrl, req ChatRequest, out chan ChatEvent, cancel_ch chan int) ! {
	body := build_anthropic_body(req)
	mut reader := http_post_streaming(url, body, {
		'x-api-key':         p.api_key
		'anthropic-version': '2023-06-01'
	})!

	read_anthropic_sse(mut reader, out, cancel_ch)!
}
