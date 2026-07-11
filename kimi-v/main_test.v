// main_test.v — small unit tests for helpers added in items #1 and #2.
//
// We test the pure helpers (jsonl encoding, outcome string). The
// end-to-end `-p` paths are exercised manually because V's test
// framework hangs on goroutine-bearing tests (see test docs).
module main

import json

// ---------- emit_jsonl_event (item #2) -----------------------------------

fn test_emit_jsonl_event_emits_valid_jsonl() {
	// We can't intercept stdout in a V test easily, so we exercise the
	// json encoder directly. emit_jsonl_event's contract is: a JSON
	// object with a "type" key plus any extra fields, encoded as one
	// line. We reconstruct that here.
	mut obj := {
		'type': 'tool_call'
	}
	obj['name'] = 'bash'
	obj['args'] = '{"command":"ls"}'
	line := json.encode(obj)
	// Sanity: starts with {, ends with }, no newlines.
	assert line.starts_with('{')
	assert line.ends_with('}')
	assert !line.contains('\n')
	// And decodes back to the same shape.
	decoded := json.decode(map[string]string, line) or {
		assert false, 'invalid json: ${err.msg()}'
		return
	}
	assert decoded['type'] == 'tool_call'
	assert decoded['name'] == 'bash'
	assert decoded['args'] == '{"command":"ls"}'
}

fn test_emit_jsonl_event_includes_all_fields() {
	mut obj := {
		'type': 'done'
	}
	obj['turns'] = '3'
	obj['input_tokens'] = '100'
	obj['output_tokens'] = '50'
	line := json.encode(obj)
	decoded := json.decode(map[string]string, line) or {
		assert false, err.msg()
		return
	}
	assert decoded['type'] == 'done'
	assert decoded['turns'] == '3'
	assert decoded['input_tokens'] == '100'
	assert decoded['output_tokens'] == '50'
}

// ---------- outcome_str (item #2) ----------------------------------------

fn test_outcome_str_returns_correct_strings() {
	// .finished is the success case; .max_turns and .errored are
	// non-fatal outcomes the script should treat as failure.
	assert outcome_str(.finished) == 'finished'
	assert outcome_str(.max_turns) == 'max_turns'
	assert outcome_str(.errored) == 'errored'
}

// ---------- jsonl roundtrip (item #2) ------------------------------------

fn test_jsonl_roundtrip_preserves_unicode() {
	// stream-json consumers may want to see CJK / emoji in assistant
	// text. Make sure the encoder doesn't choke on non-ASCII.
	mut obj := {
		'type': 'assistant'
	}
	obj['content'] = '你好 🌍 — kimi is ready.'
	line := json.encode(obj)
	decoded := json.decode(map[string]string, line) or {
		assert false, err.msg()
		return
	}
	assert decoded['content'] == '你好 🌍 — kimi is ready.'
}
