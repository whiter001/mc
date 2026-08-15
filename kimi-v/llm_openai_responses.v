// llm_openai_responses.v — OpenAI Responses API provider.
//
// Wire format (POST {api_base}/v1/responses, Authorization: Bearer):
//   {
//     "model": "...",
//     "input": [
//       {"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]},
//       {"type":"message","role":"user","content":[{"type":"input_image","image_url":"data:image/png;base64,..."}]},
//       {"type":"message","role":"assistant","content":[{"type":"output_text","text":"..."}]},
//       {"type":"function_call","call_id":"...","name":"bash","arguments":"{\"path\":\"a.txt\"}"},
//       {"type":"function_call_output","call_id":"...","output":"..."}
//     ],
//     "tools": [{"type":"function","name":"...","description":"...","parameters":{...}}],
//     "max_output_tokens": N,
//     "stream": true,
//     "store": false
//   }
//
// `temperature` is sent only for models the capability registry marks as
// non-thinking — reasoning models (o1/o3/gpt-5 ...) reject it outright.
// Unlike chat completions, the Responses API does NOT nest tools under a
// `function` key and assistant tool calls are separate `function_call`
// input items rather than fields on a message.
//
// Response (SSE, one JSON object per `data:` line, discriminated by `type`):
//   {"type":"response.output_text.delta","delta":"Hello"}
//   {"type":"response.reasoning_summary_text.delta","delta":"..."}
//   {"type":"response.reasoning_text.delta","delta":"..."}
//   {"type":"response.completed","response":{...,"output":[...],"usage":{...}}}
//   {"type":"response.incomplete","response":{...,"incomplete_details":{"reason":"max_output_tokens"}}}
//   {"type":"response.failed","response":{"error":{"code":"...","message":"..."}}}
//   {"type":"error","code":"...","message":"...","param":"..."}
//
// Simplified streaming strategy (vs. chat completions):
//   - text streams via `response.output_text.delta` deltas
//   - tool calls come ONLY from the final `response.completed` `output`
//     array, where each `function_call` item is complete — no incremental
//     argument assembly needed
//   - usage is read from `response.completed`'s `usage` object
module main

import json2
import os
import strings
import time

// OpenAIResponsesProvider implements an OpenAI Responses API client.
pub struct OpenAIResponsesProvider {
pub:
	name     string = 'openai-responses'
	model    string
	api_base string = 'https://api.openai.com'
	api_key  string
}

// ---- Request body assembly -----------------------------------------------

// responses_content_parts renders the content-part array for a message.
// User/system content uses `input_text`; assistant history content uses
// `output_text`, the Responses API's documented shape for assistant
// messages (chat-completions-style `text` parts are rejected for them).
// Image attachments become `input_image` parts carrying a data: URL.
pub fn responses_content_parts(m Message) []string {
	mut parts := []string{}
	text_type := if m.role == .assistant { 'output_text' } else { 'input_text' }
	if m.content.len > 0 {
		parts << '{"type":${json_lit(text_type)},"text":${json_lit(m.content)}}'
	}
	for att in m.attachments {
		parts << '{"type":"input_image","image_url":${json_lit('data:${att.mime};base64,${att.b64}')}}'
	}
	return parts
}

// responses_message_item renders one `message` input item.
fn responses_message_item(m Message, parts []string) string {
	return '{"type":"message","role":${json_lit(m.role.str())},"content":[${parts.join(',')}]}'
}

// responses_function_call_item renders an assistant tool call as a
// standalone `function_call` input item. `arguments` is a pre-encoded JSON
// string (matching ToolCall.arguments) and is serialized as a JSON string
// literal, not spliced as an object.
pub fn responses_function_call_item(tc ToolCall) string {
	arg := if tc.arguments.trim_space().len > 0 { tc.arguments } else { '{}' }
	return '{"type":"function_call","call_id":${json_lit(tc.id)},"name":${json_lit(tc.name)},"arguments":${json_lit(arg)}}'
}

// responses_function_call_output renders a tool result as a
// `function_call_output` input item.
pub fn responses_function_call_output(m Message) string {
	return '{"type":"function_call_output","call_id":${json_lit(m.tool_call_id)},"output":${json_lit(m.content)}}'
}

// responses_wire_input renders the `input` array from canonical messages.
// System/user/assistant messages become `message` items; assistant tool
// calls become standalone `function_call` items; tool results become
// `function_call_output` items. An empty message falls back to a single
// empty text part so the wire form stays well-formed (mirrors
// build_content_parts in llm_openai_compat.v).
pub fn responses_wire_input(messages []Message) string {
	mut items := []string{}
	for m in messages {
		if m.role == .tool {
			items << responses_function_call_output(m)
			continue
		}
		parts := responses_content_parts(m)
		if parts.len > 0 {
			items << responses_message_item(m, parts)
		} else {
			// Edge case: empty submit. Send a single empty text part.
			text_type := if m.role == .assistant { 'output_text' } else { 'input_text' }
			items << responses_message_item(m, ['{"type":${json_lit(text_type)},"text":""}'])
		}
		if m.role == .assistant {
			for tc in m.tool_calls {
				items << responses_function_call_item(tc)
			}
		}
	}
	return '[' + items.join(',') + ']'
}

// responses_wire_tools renders the `tools` array. Unlike chat completions,
// each entry is FLAT — {"type":"function","name":...,"description":...,
// "parameters":{...}} — there is no nested `function` object. The
// parameters JSON Schema string is spliced verbatim.
pub fn responses_wire_tools(tools []ToolDef) string {
	mut parts := []string{}
	for t in tools {
		schema := if t.parameters.trim_space().len > 0 { t.parameters } else { '{}' }
		parts << '{"type":"function","name":${json_lit(t.name)},"description":${json_lit(t.description)},"parameters":${schema}}'
	}
	return '[' + parts.join(',') + ']'
}

// build_responses_body renders the full request body for the Responses API.
pub fn build_responses_body(req ChatRequest) string {
	cap := lookup_capability(req.model)
	mut parts := []string{}
	parts << '"model":${json_lit(req.model)}'
	parts << '"input":${responses_wire_input(req.messages)}'
	parts << '"tools":${responses_wire_tools(req.tools)}'
	parts << '"max_output_tokens":${req.max_tokens}'
	// Reasoning models reject `temperature` outright (400 error); gate on
	// the capability registry so only non-thinking models get it.
	if !cap.thinking {
		parts << '"temperature":${req.temperature}'
	}
	parts << '"stream":true'
	parts << '"store":false'
	return '{' + parts.join(',') + '}'
}

// ---- SSE event types (decode side only) ----------------------------------
//
// V 0.5's json2.decode ignores missing fields, so one struct covers every
// event type; ?-wrapped fields are used where a key is absent from some
// events.

struct ResponsesEventT {
	typ      string              @[json: type]
	delta    string              @[json: delta]
	response ?ResponsesResponseT @[json: response]
	message  string              @[json: message]
	code     string              @[json: code]
	param    string              @[json: param]
}

struct ResponsesResponseT {
	id                 string                  @[json: id]
	status             string                  @[json: status]
	output             []ResponsesOutputItemT  @[json: output]
	usage              ?ResponsesUsageT        @[json: usage]
	incomplete_details ?ResponsesIncompleteT   @[json: incomplete_details]
	error              ?ResponsesErrorT        @[json: error]
}

struct ResponsesOutputItemT {
	typ       string                  @[json: type]
	id        string                  @[json: id]
	call_id   string                  @[json: call_id]
	name      string                  @[json: name]
	// `arguments` arrives as a JSON-encoded STRING (e.g.
	// "{\"path\":\"a.txt\"}"), which is exactly ToolCall.arguments' shape.
	arguments string                  @[json: arguments]
	content   []ResponsesContentPartT @[json: content]
}

struct ResponsesContentPartT {
	typ  string @[json: type]
	text string @[json: text]
}

struct ResponsesUsageT {
	input_tokens  int @[json: input_tokens]
	output_tokens int @[json: output_tokens]
}

struct ResponsesIncompleteT {
	reason string @[json: reason]
}

struct ResponsesErrorT {
	code    string @[json: code]
	message string @[json: message]
}

// ---- SSE parser ----------------------------------------------------------

// ResponsesSseParser walks Responses SSE data payloads and emits
// ChatEvents. It tracks token counts and guards against emitting a second
// .finish if both response.completed and response.incomplete arrive.
struct ResponsesSseParser {
pub mut:
	input_tokens   int
	output_tokens  int
	emitted_finish bool
}

fn new_responses_parser() ResponsesSseParser {
	return ResponsesSseParser{}
}

// feed decodes one SSE data payload and emits the corresponding ChatEvents.
fn (mut p ResponsesSseParser) feed(event_data string, out chan ChatEvent, cancel_ch chan int) {
	ev := json2.decode[ResponsesEventT](event_data) or {
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
		'response.output_text.delta' {
			if ev.delta.len > 0 {
				out <- ChatEvent{
					kind:    .delta
					content: ev.delta
				}
			}
		}
		'response.reasoning_summary_text.delta', 'response.reasoning_text.delta' {
			if ev.delta.len > 0 {
				out <- ChatEvent{
					kind:     .thinking
					thinking: ev.delta
				}
			}
		}
		'response.completed', 'response.incomplete' {
			p.emit_completed(ev, out)
		}
		'response.failed' {
			if r := ev.response {
				if e := r.error {
					out <- ChatEvent{
						kind: .err_kind
						err:  'responses failed: ${e.message}'
					}
				} else {
					out <- ChatEvent{
						kind: .err_kind
						err:  'responses failed: ${r.status}'
					}
				}
			} else {
				out <- ChatEvent{
					kind: .err_kind
					err:  'responses failed'
				}
			}
		}
		'error' {
			mut msg := ev.message
			if ev.code.len > 0 {
				msg = '${ev.code}: ${msg}'
			}
			out <- ChatEvent{
				kind: .err_kind
				err:  'responses error: ${msg}'
			}
		}
		else {}
	}
}

// emit_completed handles response.completed / response.incomplete: it
// extracts complete `function_call` items from the `output` array (the
// authoritative source — no incremental arguments assembly), records usage,
// and emits a single .finish event. completed → .stop, incomplete → .length.
fn (mut p ResponsesSseParser) emit_completed(ev ResponsesEventT, out chan ChatEvent) {
	r := ev.response or { return }
	if u := r.usage {
		p.input_tokens = u.input_tokens
		p.output_tokens = u.output_tokens
	}
	// Complete function_call items are the tool calls. Text in `message`
	// items is NOT re-emitted here — it already streamed via
	// response.output_text.delta deltas, and replaying it would duplicate.
	mut idx := 0
	for item in r.output {
		if item.typ == 'function_call' {
			cid := if item.call_id.len > 0 { item.call_id } else { item.id }
			out <- ChatEvent{
				kind:      .tool_call
				index:     idx
				id:        cid
				name:      item.name
				arguments: item.arguments
			}
			idx++
		}
	}
	if p.emitted_finish {
		return
	}
	p.emitted_finish = true
	reason := if ev.typ == 'response.completed' { FinishReason.stop } else { FinishReason.length }
	out <- ChatEvent{
		kind:          .finish
		reason:        reason
		input_tokens:  p.input_tokens
		output_tokens: p.output_tokens
	}
}

// read_responses_sse drives a StreamReader, parses SSE events, and emits
// ChatEvents into `out`. Same framing loop as read_anthropic_sse
// (llm_anthropic.v); Responses streams carry no [DONE] sentinel — the
// connection closes after response.completed. [DONE] is tolerated for
// gateways that add it.
fn read_responses_sse(mut reader StreamReader, out chan ChatEvent, cancel_ch chan int) ! {
	defer {
		reader.close()
	}

	mut parser := new_responses_parser()
	mut current_data := strings.Builder{}
	for {
		// Check for cancellation before each read (non-blocking).
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
				if data.trim_space() == '[DONE]' {
					return
				}
				parser.feed(data, out, cancel_ch)
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
pub fn (p OpenAIResponsesProvider) chat(req ChatRequest, out chan ChatEvent, cancel_ch chan int) ! {
	url_str := '${p.api_base}/v1/responses'
	parsed_url := parse_url(url_str) or {
		out <- ChatEvent{
			kind: .err_kind
			err:  'bad url: ${err.msg()}'
		}
		return
	}

	if parsed_url.scheme == 'http' || parsed_url.scheme == 'https' {
		chat_responses_streaming(p, parsed_url, req, out, cancel_ch) or {
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
			err:  'unsupported URL scheme for openai-responses: ${parsed_url.scheme}'
		}
	}
	// Sentinel: the consumer reads events until it sees this, then knows
	// the stream is fully drained. Always sent, even after a cancel.
	out <- ChatEvent{ kind: .end_of_stream }
	out.close()
}

// chat_responses_streaming issues a streaming request and feeds SSE events
// to out.
fn chat_responses_streaming(p OpenAIResponsesProvider, url ParsedUrl, req ChatRequest, out chan ChatEvent, cancel_ch chan int) ! {
	body := build_responses_body(req)
	if os.getenv('KIMI_DEBUG_DUMP_REQUEST') != '' {
		os.write_file(os.getenv('KIMI_DEBUG_DUMP_REQUEST'), body) or {}
	}
	mut reader := http_post_streaming(url, body, {
		'Authorization': 'Bearer ${p.api_key}'
	})!

	read_responses_sse(mut reader, out, cancel_ch)!
}
