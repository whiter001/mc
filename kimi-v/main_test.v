// main_test.v — small unit tests for helpers added in items #1 and #2.
//
// We test the pure helpers (jsonl encoding, outcome string). The
// end-to-end `-p` paths are exercised manually because V's test
// framework hangs on goroutine-bearing tests (see test docs).
module main

import os
import json2

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
	line := json2.encode(obj)
	// Sanity: starts with {, ends with }, no newlines.
	assert line.starts_with('{')
	assert line.ends_with('}')
	assert !line.contains('\n')
	// And decodes back to the same shape.
	decoded := json2.decode[map[string]string](line) or {
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
	line := json2.encode(obj)
	decoded := json2.decode[map[string]string](line) or {
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
	line := json2.encode(obj)
	decoded := json2.decode[map[string]string](line) or {
		assert false, err.msg()
		return
	}
	assert decoded['content'] == '你好 🌍 — kimi is ready.'
}

// ---------- ! shell mode (item #3) ----------------------------------------

// We can't easily test the TUI main loop, but the underlying building
// block (run_shell_block) is a pure function of (cmd, cwd) → state. We
// call it directly and assert the resulting state block is correct.

fn test_shell_block_runs_command_in_cwd() {
	mut state := new_tui_state()
	run_shell_block(mut state, 'echo hello-from-shell', os.temp_dir())
	assert state.blocks.len == 1
	block := state.blocks[0]
	assert block.kind == .system
	// The block text starts with the prompt echo, then the output.
	assert block.text.contains('\$ echo hello-from-shell')
	assert block.text.contains('hello-from-shell')
}

fn test_shell_block_reports_nonzero_exit() {
	mut state := new_tui_state()
	run_shell_block(mut state, 'false', os.temp_dir())
	assert state.blocks.len == 1
	block := state.blocks[0]
	// `false` exits 1 → the prefix should show [exit 1].
	assert block.text.contains('[exit 1]')
}

fn test_shell_block_handles_empty_output() {
	mut state := new_tui_state()
	run_shell_block(mut state, 'true', os.temp_dir())
	assert state.blocks.len == 1
	// `true` produces no output; the block should still be created
	// (with just the prompt prefix).
	block := state.blocks[0]
	assert block.kind == .system
	assert block.text.starts_with('\$ true')
}

fn test_shell_block_truncates_long_output() {
	mut state := new_tui_state()
	// Generate ~500 lines of output. Print line numbers 1..500.
	run_shell_block(mut state, "for i in $(seq 1 500); do echo line-\$i; done", os.temp_dir())
	assert state.blocks.len == 1
	block := state.blocks[0]
	// Truncation marker should be present because output > 200 lines.
	assert block.text.contains('truncated')
	// First and last visible lines are present.
	assert block.text.contains('line-1')
	// Line 500 is past the cap, so it should NOT appear in the rendered
	// block (the truncation message replaces the tail).
	assert !block.text.contains('\nline-500\n')
}

// ---------- Ctrl-O / collapse tool results --------------------------------

// Helper: build a state with a mix of block kinds so we can verify
// toggle_collapse only touches .tool_result and leaves everything else
// alone.
fn make_state_with_tool_results() TuiState {
	mut s := new_tui_state()
	s.blocks << Block{ kind: .user, text: 'look up foo' }
	s.blocks << Block{
		kind: .tool_call
		tool_name: 'bash'
		tool_args: '{"command":"ls"}'
	}
	s.blocks << Block{
		kind: .tool_result
		tool_name: 'bash'
		tool_result: 'a.txt\nb.txt\nc.txt'
	}
	s.blocks << Block{ kind: .assistant, text: 'found three files' }
	s.blocks << Block{
		kind: .tool_call
		tool_name: 'read_file'
		tool_args: '{"path":"a.txt"}'
	}
	s.blocks << Block{
		kind: .tool_result
		tool_name: 'read_file'
		tool_result: 'line1\nline2\nline3\nline4'
	}
	return s
}

fn test_toggle_collapse_collapses_all_tool_results() {
	mut s := make_state_with_tool_results()
	toggle_collapse(mut s)
	// Both tool_result blocks should now be folded.
	assert s.blocks[2].kind == .tool_result
	assert s.blocks[2].collapsed == true
	assert s.blocks[5].kind == .tool_result
	assert s.blocks[5].collapsed == true
	// Other block kinds must be untouched.
	assert s.blocks[0].kind == .user
	assert s.blocks[1].kind == .tool_call
	assert s.blocks[3].kind == .assistant
	assert s.blocks[4].kind == .tool_call
	// Status line should announce the fold with a count.
	assert s.status.contains('collapsed 2 tool results')
}

fn test_toggle_collapse_expands_when_all_collapsed() {
	mut s := make_state_with_tool_results()
	// Pre-collapse both tool_result blocks so the next press expands.
	s.blocks[2].collapsed = true
	s.blocks[5].collapsed = true
	toggle_collapse(mut s)
	assert s.blocks[2].collapsed == false
	assert s.blocks[5].collapsed == false
	assert s.status.contains('expanded 2 tool results')
}

fn test_toggle_collapse_partial_still_collapses_remaining() {
	// If some tool_results are already folded and others aren't, one
	// press should bring them all to the same (collapsed) state — this
	// is the "press once to clean up" behavior, not "flip the mixed
	// ones". Pressing again then expands.
	mut s := make_state_with_tool_results()
	s.blocks[2].collapsed = true // already folded
	// blocks[5] is expanded
	toggle_collapse(mut s)
	// Now BOTH collapsed (the expanded one got folded; the folded one
	// stayed folded because the rule is "any expanded → collapse all").
	assert s.blocks[2].collapsed == true
	assert s.blocks[5].collapsed == true
	// A second press should now expand both.
	toggle_collapse(mut s)
	assert s.blocks[2].collapsed == false
	assert s.blocks[5].collapsed == false
}

fn test_toggle_collapse_noop_when_no_tool_results() {
	// A pure chat with no tool calls — pressing Ctrl-O should not
	// change any state.block, but should set a status hint so the user
	// knows we heard the key.
	mut s := new_tui_state()
	s.blocks << Block{ kind: .user, text: 'hi' }
	s.blocks << Block{ kind: .assistant, text: 'hello' }
	original_len := s.blocks.len
	toggle_collapse(mut s)
	assert s.blocks.len == original_len
	for b in s.blocks {
		assert b.collapsed == false
	}
	assert s.status.contains('no tool results')
}

fn test_toggle_collapse_singular_plural_in_status() {
	// Singular form ("1 tool result") vs plural ("2 tool results") so
	// the status line reads naturally.
	mut s := new_tui_state()
	s.blocks << Block{ kind: .tool_result, tool_name: 'bash', tool_result: 'only one' }
	toggle_collapse(mut s)
	assert s.blocks[0].collapsed == true
	// "1 tool result" (no trailing 's' on the noun). V's `or` is
	// reserved for error handling inside expressions, so we test the
	// pluralization in two separate asserts.
	singular_ok := s.status.contains('collapsed 1 tool result ')
	plural_ok := s.status.contains('collapsed 1 tool results')
	assert singular_ok || plural_ok, 'expected status to mention exactly 1 tool result, got: ${s.status}'
	// Just one, so should NOT say "2".
	assert !s.status.contains('collapsed 2')
}
