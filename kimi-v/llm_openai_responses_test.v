// llm_openai_responses_test.v — unit tests for the OpenAI Responses provider.
//
// Wire-conversion (build_responses_body) and SSE-parser (ResponsesSseParser.feed)
// functions are pure (no network), so they are tested directly. feed() sends
// into a buffered channel; drain_responses_events collects what was emitted.
//
// Canned SSE payloads are single-quoted V strings; `\\"` produces a literal
// backslash-quote so the JSON string values keep their escaped quotes.
module main

import time

// ---------- drain helper ---------------------------------------------------

// drain_responses_events collects everything buffered in `out`. feed() sends
// synchronously, so by the time it returns every event is already in the
// buffer; we stop after a short quiet period with nothing pending.
fn drain_responses_events(out chan ChatEvent) []ChatEvent {
	mut got := []ChatEvent{}
	mut quiet := 0
	mut done := false
	for !done {
		select {
			ev := <-out {
				got << ev
				quiet = 0
			}
			1 * time.millisecond {
				quiet++
				if quiet > 3 {
					done = true
				}
			}
		}
	}
	return got
}

// feed_responses_events feeds a sequence of SSE data payloads through a fresh
// parser and returns the emitted ChatEvents.
fn feed_responses_events(events []string) []ChatEvent {
	out := chan ChatEvent{cap: 64}
	cancel := chan int{cap: 1}
	mut p := new_responses_parser()
	for e in events {
		p.feed(e, out, cancel)
	}
	return drain_responses_events(out)
}

// ---------- request body assembly ------------------------------------------

fn test_build_responses_body_user_text_and_image() {
	req := ChatRequest{
		model: 'gpt-4o'
		messages: [
			Message{
				role:    .user
				content: 'see this'
				attachments: [
					Attachment{
						mime: 'image/png'
						b64:  'iVBORw0KGgo='
					},
				]
			},
		]
	}
	body := build_responses_body(req)
	// User text → input_text; image attachment → input_image with a data: URL.
	assert body.contains('"input_text"'), 'user text should become input_text'
	assert body.contains('"input_image"'), 'image attachment should become input_image'
	assert body.contains('"data:image/png;base64,iVBORw0KGgo="'), 'attachment b64 must be embedded'
}

fn test_build_responses_body_assistant_tool_calls() {
	req := ChatRequest{
		model: 'gpt-4o'
		messages: [
			Message{
				role:    .assistant
				content: 'let me run'
				tool_calls: [
					ToolCall{
						id:        'c1'
						name:      'bash'
						arguments: '{"path":"a.txt"}'
					},
				]
			},
		]
	}
	body := build_responses_body(req)
	// Assistant tool calls are their own `function_call` input items, not
	// fields on the message.
	assert body.contains('"type":"function_call"'), 'assistant tool calls become function_call items'
	assert body.contains('"call_id":"c1"')
	assert body.contains('"name":"bash"')
}

fn test_build_responses_body_tool_result() {
	req := ChatRequest{
		model: 'gpt-4o'
		messages: [
			Message{
				role:         .tool
				tool_call_id: 't1'
				content:      '{"exit_code":0}'
			},
		]
	}
	body := build_responses_body(req)
	// Tool results become `function_call_output` items.
	assert body.contains('"type":"function_call_output"'), 'tool results become function_call_output'
	assert body.contains('"call_id":"t1"')
}

fn test_build_responses_body_tools_flat() {
	req := ChatRequest{
		model: 'gpt-4o'
		messages: [
			Message{
				role:    .user
				content: 'hi'
			},
		]
		tools: [
			ToolDef{
				name:        'bash'
				description: 'run a command'
				parameters:  '{"type":"object","properties":{"cmd":{"type":"string"}}}'
			},
		]
	}
	body := build_responses_body(req)
	// The Responses API keeps tools flat: {"type":"function","name":...,...}
	// with NO nested {"function":{...}} wrapper (that's chat completions).
	assert body.contains('"type":"function"'), 'tools use the flat function type'
	assert body.contains('"name":"bash"'), 'tool name serialized at the top level'
	assert !body.contains('"function":{'), 'tools must NOT be nested under a function key'
}

fn test_build_responses_body_o3_no_temperature() {
	// Reasoning models (o1/o3/gpt-5 ...) reject `temperature` — the body
	// must omit it entirely even when the caller supplied one.
	req := ChatRequest{
		model:      'o3'
		messages:   [Message{ role: .user, content: 'hi' }]
		temperature: 0.7
	}
	body := build_responses_body(req)
	assert !body.contains('"temperature"'), 'reasoning model o3 must not send temperature'
}

fn test_build_responses_body_gpt4o_temperature() {
	// Non-thinking models keep `temperature`.
	req := ChatRequest{
		model:      'gpt-4o'
		messages:   [Message{ role: .user, content: 'hi' }]
		temperature: 0.7
	}
	body := build_responses_body(req)
	assert body.contains('"temperature"'), 'non-reasoning gpt-4o must send temperature'
}

// ---------- SSE parser -----------------------------------------------------

fn test_responses_parser_text_delta() {
	got := feed_responses_events([
		'{"type":"response.output_text.delta","delta":"Hello"}',
	])
	assert got.len == 1, 'expected exactly one event'
	assert got[0].kind == .delta
	assert got[0].content == 'Hello'
}

fn test_responses_parser_reasoning_delta() {
	got := feed_responses_events([
		'{"type":"response.reasoning_text.delta","delta":"thinking step"}',
	])
	assert got.len == 1, 'expected exactly one event'
	assert got[0].kind == .thinking
	assert got[0].thinking == 'thinking step'
}

fn test_responses_parser_completed_with_tools() {
	completed := '{"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"type":"function_call","id":"fc1","call_id":"call_1","name":"bash","arguments":"{\\"path\\":\\"a.txt\\"}"},{"type":"function_call","id":"fc2","call_id":"call_2","name":"read","arguments":"{\\"file\\":\\"b.txt\\"}"}],"usage":{"input_tokens":42,"output_tokens":7}}}'
	got := feed_responses_events([completed])
	// Two complete function_call items become two .tool_call events, then a
	// single .finish carrying the usage.
	assert got.len == 3, 'expected two tool_calls + one finish'
	assert got[0].kind == .tool_call, 'first event is a tool_call'
	assert got[0].id == 'call_1'
	assert got[0].name == 'bash'
	assert got[0].arguments == '{"path":"a.txt"}'
	assert got[1].kind == .tool_call, 'second event is a tool_call'
	assert got[1].id == 'call_2'
	assert got[1].name == 'read'
	assert got[1].arguments == '{"file":"b.txt"}'
	assert got[2].kind == .finish
	assert got[2].reason == .stop
	assert got[2].input_tokens == 42
	assert got[2].output_tokens == 7
}

fn test_responses_parser_failed() {
	got := feed_responses_events([
		'{"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"boom"}}}',
	])
	assert got.len == 1, 'expected exactly one event'
	assert got[0].kind == .err_kind
	assert got[0].err.contains('boom'), 'error message should be surfaced'
}

fn test_responses_parser_duplicate_completed_no_double_finish() {
	// A second response.completed must NOT emit a second .finish — the
	// parser guards with emitted_finish. (It will re-emit the function_call
	// items, which is acceptable; only .finish must be singular.)
	completed := '{"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"type":"function_call","id":"fc1","call_id":"call_1","name":"bash","arguments":"{\\"path\\":\\"a.txt\\"}"}],"usage":{"input_tokens":3,"output_tokens":1}}}'
	got := feed_responses_events([completed, completed])
	mut finishes := 0
	for e in got {
		if e.kind == .finish {
			finishes++
		}
	}
	assert finishes == 1, 'duplicate completed must not emit a second finish'
}
