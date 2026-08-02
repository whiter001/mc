// llm_anthropic_test.v — unit tests for the Anthropic Messages API provider.
//
// Wire-conversion and SSE-parser functions are pure (no network), so they're
// tested directly. `feed` sends into a buffered channel; `drain_events`
// collects what was emitted.
module main

import time

// ---------- drain helper ---------------------------------------------------

// drain_events collects everything buffered in `out`, stopping after a quiet
// period with nothing pending. feed() sends synchronously, so by the time it
// returns every event is already in the buffer.
fn drain_events(out chan ChatEvent) []ChatEvent {
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

// feed_anthropic_events feeds a sequence of SSE data payloads through a fresh
// parser and returns the emitted ChatEvents.
fn feed_anthropic_events(events []string) []ChatEvent {
	out := chan ChatEvent{cap: 64}
	cancel := chan int{cap: 1}
	mut p := new_anthropic_parser()
	for e in events {
		p.feed(e, out, cancel)
	}
	return drain_events(out)
}

// ---------- request wire conversion ----------------------------------------

fn test_anthropic_wire_messages_basic_user() {
	msgs := [
		Message{
			role:    .user
			content: 'hi'
		},
	]
	wire := anthropic_wire_messages(msgs)
	assert wire == '[{"role":"user","content":[{"type":"text","text":"hi"}]}]'
}

fn test_anthropic_wire_messages_system_excluded() {
	msgs := [
		Message{
			role:    .system
			content: 'be nice'
		},
		Message{
			role:    .user
			content: 'hello'
		},
	]
	wire := anthropic_wire_messages(msgs)
	assert wire == '[{"role":"user","content":[{"type":"text","text":"hello"}]}]'
}

fn test_anthropic_wire_messages_tool_result_grouping() {
	msgs := [
		Message{
			role:         .tool
			tool_call_id: 't1'
			content:      '{"exit_code":0}'
		},
		Message{
			role:         .tool
			tool_call_id: 't2'
			content:      '{"exit_code":1}'
		},
	]
	wire := anthropic_wire_messages(msgs)
	// Consecutive tool results group into a single user message.
	assert wire.count('"role":"user"') == 1
	assert wire.contains('"type":"tool_result"')
	assert wire.contains('"tool_use_id":"t1"')
	assert wire.contains('"tool_use_id":"t2"')
	assert wire.contains('"content":"{\\"exit_code\\":0}"')
}

fn test_anthropic_wire_messages_assistant_tool_calls() {
	msgs := [
		Message{
			role:    .assistant
			content: 'let me check'
			tool_calls: [
				ToolCall{
					id:        'toolu_1'
					name:      'bash'
					arguments: '{"path":"a.txt"}'
				},
			]
		},
	]
	wire := anthropic_wire_messages(msgs)
	assert wire.contains('"type":"tool_use"')
	assert wire.contains('"id":"toolu_1"')
	assert wire.contains('"name":"bash"')
	// Pre-encoded arguments splice into `input` verbatim.
	assert wire.contains('"input":{"path":"a.txt"}')
}

fn test_anthropic_wire_messages_leading_assistant_protected() {
	// Anthropic requires the conversation to start with a user message;
	// a synthetic empty one is prepended.
	msgs := [
		Message{
			role:    .assistant
			content: 'hi there'
		},
	]
	wire := anthropic_wire_messages(msgs)
	assert wire.starts_with('[{"role":"user","content":[{"type":"text","text":""}]},{"role":"assistant"')
}

fn test_anthropic_wire_messages_empty_content_fallback() {
	msgs := [
		Message{
			role:    .user
			content: ''
		},
	]
	wire := anthropic_wire_messages(msgs)
	assert wire == '[{"role":"user","content":[{"type":"text","text":""}]}]'
}

fn test_anthropic_wire_messages_image_attachment() {
	msgs := [
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
	wire := anthropic_wire_messages(msgs)
	assert wire.contains('"type":"image"')
	assert wire.contains('"media_type":"image/png"')
	assert wire.contains('"data":"iVBORw0KGgo="')
}

fn test_anthropic_system_prompt_concatenates() {
	msgs := [
		Message{
			role:    .system
			content: 'a'
		},
		Message{
			role:    .user
			content: 'x'
		},
		Message{
			role:    .system
			content: 'b'
		},
	]
	assert anthropic_system_prompt(msgs) == 'a\n\nb'
}

fn test_anthropic_tools_wire_embeds_schema() {
	tools := [
		ToolDef{
			name:        'bash'
			description: 'run a command'
			parameters:  '{"type":"object","properties":{"cmd":{"type":"string"}}}'
		},
	]
	wire := anthropic_tools_wire(tools)
	assert wire == '[{"name":"bash","description":"run a command","input_schema":{"type":"object","properties":{"cmd":{"type":"string"}}}}]'
}

fn test_anthropic_tools_wire_empty_parameters_fallback() {
	tools := [
		ToolDef{
			name:        'noop'
			description: ''
		},
	]
	wire := anthropic_tools_wire(tools)
	assert wire == '[{"name":"noop","description":"","input_schema":{}}]'
}

fn test_anthropic_build_body_basic() {
	req := ChatRequest{
		model:      'claude-sonnet-4-5'
		messages:   [
			Message{
				role:    .user
				content: 'hi'
			},
		]
		max_tokens: 2048
	}
	body := build_anthropic_body(req)
	assert body.contains('"model":"claude-sonnet-4-5"')
	assert body.contains('"max_tokens":2048')
	assert body.contains('"stream":true')
	assert body.contains('"system":""')
	assert body.contains('"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]')
}

fn test_anthropic_json_lit_escapes() {
	// json.encode(s) returns a quoted, escaped literal: quote/backslash/newline
	// escapes and non-ASCII → \uXXXX.
	assert json_lit('a"b') == '"a\\"b"'
	assert json_lit('x\ny') == '"x\\ny"'
	assert json_lit('back\\slash') == '"back\\\\slash"'
	assert json_lit('中文') == '"\\u4e2d\\u6587"'
}

// ---------- stop reason / error classification -----------------------------

fn test_anthropic_stop_reason_mapping() {
	assert anthropic_stop_reason('end_turn') == .stop
	assert anthropic_stop_reason('tool_use') == .tool_calls
	assert anthropic_stop_reason('max_tokens') == .length
	assert anthropic_stop_reason('stop_sequence') == .stop
	assert anthropic_stop_reason('') == .unknown
	assert anthropic_stop_reason('nonsense') == .unknown
}

fn test_anthropic_error_retryable() {
	assert anthropic_error_retryable('overloaded_error')
	assert anthropic_error_retryable('rate_limit_error')
	assert !anthropic_error_retryable('invalid_request_error')
	assert !anthropic_error_retryable('api_error')
	assert !anthropic_error_retryable('authentication_error')
}

// ---------- SSE parser -----------------------------------------------------

fn test_anthropic_parser_text_stream() {
	events := [
		'{"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","content":[],"model":"claude-3-5-sonnet-20241022","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":25,"output_tokens":1}}}',
		'{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
		'{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}',
		'{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}',
		'{"type":"content_block_stop","index":0}',
		'{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":15}}',
		'{"type":"message_stop"}',
	]
	got := feed_anthropic_events(events)
	assert got.len == 3
	assert got[0].kind == .delta
	assert got[0].content == 'Hello'
	assert got[1].kind == .delta
	assert got[1].content == ' world'
	assert got[2].kind == .finish
	assert got[2].reason == .stop
	assert got[2].input_tokens == 25
	assert got[2].output_tokens == 15
}

fn test_anthropic_parser_tool_use_stream() {
	events := [
		'{"type":"message_start","message":{"id":"msg_02","usage":{"input_tokens":25,"output_tokens":1}}}',
		'{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
		'{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01","name":"bash","input":{}}}',
		'{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\": \\""}}',
		'{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"a.txt\\"}"}}',
		'{"type":"content_block_stop","index":1}',
		'{"type":"content_block_stop","index":0}',
		'{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":30}}',
		'{"type":"message_stop"}',
	]
	got := feed_anthropic_events(events)
	assert got.len == 2
	assert got[0].kind == .tool_call
	assert got[0].index == 1
	assert got[0].id == 'toolu_01'
	assert got[0].name == 'bash'
	assert got[0].arguments == '{"path": "a.txt"}'
	assert got[1].kind == .finish
	assert got[1].reason == .tool_calls
	assert got[1].input_tokens == 25
	assert got[1].output_tokens == 30
}

fn test_anthropic_parser_error_event() {
	got := feed_anthropic_events([
		'{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}',
	])
	assert got.len == 1
	assert got[0].kind == .err_kind
	assert got[0].err.contains('overloaded_error')
	assert got[0].retryable == true
}

fn test_anthropic_parser_ignores_garbage() {
	// Non-JSON data lines are skipped, not fatal.
	got := feed_anthropic_events([
		'not json at all',
		'{"type":"message_start","message":{"usage":{"input_tokens":7}}}',
		'{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}',
		'{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}',
	])
	assert got.len == 2
	assert got[0].kind == .delta
	assert got[0].content == 'ok'
	assert got[1].kind == .finish
	assert got[1].input_tokens == 7
	assert got[1].output_tokens == 3
}
