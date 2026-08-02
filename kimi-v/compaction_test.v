// compaction_test.v — unit tests for context-window overflow protection.
//
// Run with: v test compaction
// (or v test . from the project root)
module main

// ---------- Fake provider --------------------------------------------------
//
// We don't want to hit a real LLM in unit tests. FakeProvider implements
// the Provider interface and lets each test configure what `chat()` emits
// (text, error, etc.). The .end_of_stream sentinel is always emitted
// after, matching real providers.
//
// Note: chat() takes a non-mut receiver because the Provider interface
// declares it that way. We can't mutate provider state from inside
// chat() — but we don't need to; tests inspect messages on the Session
// instead.

struct FakeProvider {
	name     string
	model    string
	api_base string
	api_key  string
	// What chat() should emit as a sequence of deltas.
	deltas []string
	// If non-empty, emit a .err_kind event with this message and stop.
	err_msg string
}

fn new_fake(deltas []string) FakeProvider {
	return FakeProvider{
		name:     'fake'
		model:    'fake-model'
		api_base: 'http://fake'
		api_key:  'fake-key'
		deltas:   deltas
	}
}

fn new_fake_err(msg string) FakeProvider {
	return FakeProvider{
		name:     'fake'
		model:    'fake-model'
		api_base: 'http://fake'
		api_key:  'fake-key'
		err_msg:  msg
	}
}

fn (p FakeProvider) chat(req ChatRequest, out chan ChatEvent, cancel_ch chan int) ! {
	if p.err_msg.len > 0 {
		out <- ChatEvent{
			kind: .err_kind
			err:  p.err_msg
		}
		out <- ChatEvent{
			kind: .end_of_stream
		}
		return
	}
	for d in p.deltas {
		out <- ChatEvent{
			kind:    .delta
			content: d
		}
	}
	out <- ChatEvent{
		kind:   .finish
		reason: .stop
	}
	out <- ChatEvent{
		kind:          .usage
		input_tokens:  100
		output_tokens: 50
	}
	out <- ChatEvent{
		kind: .end_of_stream
	}
}

// ---------- estimate_tokens -----------------------------------------------

fn test_estimate_tokens_empty() {
	assert estimate_tokens([]Message{}) == 0
}

fn test_estimate_tokens_ascii() {
	msgs := [Message{ role: .user, content: 'hello world' }]
	// 11 bytes / 3 = 3, plus 4 overhead = 7
	t := estimate_tokens(msgs)
	assert t == 7, 'got ${t}'
}

fn test_estimate_tokens_cjk() {
	// '你好' = 6 bytes UTF-8. 6/3 = 2, plus 4 = 6
	msgs := [Message{ role: .user, content: '你好' }]
	t := estimate_tokens(msgs)
	assert t == 6, 'got ${t}'
}

fn test_estimate_tokens_long_message() {
	// 300-byte ASCII message: 300/3 = 100, plus 4 = 104
	msgs := [Message{ role: .user, content: 'a'.repeat(300) }]
	t := estimate_tokens(msgs)
	assert t == 104, 'got ${t}'
}

fn test_estimate_tokens_counts_tool_calls() {
	msgs := [
		Message{
			role:       .assistant
			content:    'calling tool'
			tool_calls: [
				ToolCall{
					id:        '1'
					name:      'bash'
					arguments: '{"cmd":"ls -la"}'
				},
			]
		},
	]
	t := estimate_tokens(msgs)
	// content "calling tool" = 12 bytes, 12/3 = 4, + 4 overhead = 8
	// tool_call name "bash" = 4 bytes, 4/3 = 1
	// tool_call args '{"cmd":"ls -la"}' = 16 bytes, 16/3 = 5
	// + 4 per-tool overhead = 10
	// total: 8 + 10 = 18
	assert t == 18, 'got ${t}'
}

fn test_estimate_tokens_sum_across_messages() {
	msgs := [
		Message{
			role:    .user
			content: 'hi'
		},
		Message{
			role:    .assistant
			content: 'hello there'
		},
		Message{
			role:    .user
			content: 'how are you?'
		},
	]
	// msg 1: 2/3 + 4 = 4
	// msg 2: 11/3 + 4 = 7
	// msg 3: 12/3 + 4 = 8
	// total: 19
	assert estimate_tokens(msgs) == 19, 'got ${estimate_tokens(msgs)}'
}

// ---------- should_compact ------------------------------------------------

fn test_should_compact_under_threshold() {
	// 1000 tokens estimated, 10000 window, 0.6 threshold = cutoff 6000. Below.
	assert should_compact(1000, 10000, 0.6) == false
}

fn test_should_compact_over_threshold() {
	// 7000 estimated > 6000 cutoff.
	assert should_compact(7000, 10000, 0.6) == true
}

fn test_should_compact_at_threshold_not_triggered() {
	// Strictly greater than cutoff. 6000 == 6000 → not triggered.
	assert should_compact(6000, 10000, 0.6) == false
}

fn test_should_compact_zero_window() {
	// Defensive: don't trigger on garbage config.
	assert should_compact(999999, 0, 0.6) == false
}

// ---------- format_messages_for_summary -----------------------------------

fn test_format_messages_basic() {
	msgs := [
		Message{
			role:    .user
			content: 'help me'
		},
		Message{
			role:    .assistant
			content: 'sure'
		},
	]
	s := format_messages_for_summary(msgs)
	assert s.contains('[user]')
	assert s.contains('[assistant]')
	assert s.contains('help me')
	assert s.contains('sure')
}

fn test_format_messages_includes_tool_calls() {
	msgs := [
		Message{
			role:       .assistant
			content:    'running'
			tool_calls: [
				ToolCall{
					id:        '1'
					name:      'bash'
					arguments: '{"cmd":"ls"}'
				},
			]
		},
	]
	s := format_messages_for_summary(msgs)
	assert s.contains('tool_call: bash(')
	assert s.contains('"cmd":"ls"')
}

// ---------- compact(): no-op cases ---------------------------------------

fn test_compact_noop_when_under_threshold() {
	mut a := new_agent(new_fake([]string{}), '')
	a.context_window = 10000
	a.compact_threshold = 0.6
	// 3 small messages, way under 6000 tokens.
	mut sess := new_session('/tmp')
	sess.append_user('hi')
	sess.append_assistant('hello', []ToolCall{})
	sess.append_user('how are you?')
	compacted := a.compact(mut sess, false, '')!
	assert compacted == false
	// FakeProvider should NOT have been called.
	// (FakeProvider's mut state isn't observable from here directly, but
	// the message list is unchanged, which is what matters.)
	assert sess.messages.len == 3
}

fn test_compact_noop_when_too_few_messages() {
	mut a := new_agent(new_fake([]string{}), '')
	a.context_window = 100 // tiny window, anything triggers should_compact
	a.compact_threshold = 0.1
	mut sess := new_session('/tmp')
	sess.append_user('hi')
	sess.append_assistant('hello', []ToolCall{})
	// Only 2 messages — below compact_min_messages (4).
	compacted := a.compact(mut sess, false, '')!
	assert compacted == false
	assert sess.messages.len == 2
}

// ---------- compact(): actual compaction ---------------------------------

fn test_compact_replaces_old_messages_with_summary() {
	mut a := new_agent(new_fake([
		'SUMMARY: The user asked to refactor a function. ' +
			'I read the file, identified the issue, and proposed a fix.',
	]), '')
	a.context_window = 100 // tiny so should_compact always fires
	a.compact_threshold = 0.1
	mut sess := new_session('/tmp')
	sess.append_user('please refactor foo()')
	sess.append_assistant('looking at it', []ToolCall{})
	sess.append_tool_result('1', 'read', 'fn foo() { ... }')
	sess.append_assistant('here is the refactor', []ToolCall{})
	sess.append_user('also add tests')
	assert sess.messages.len == 5

	compacted := a.compact(mut sess, false, '')!
	assert compacted == true
	// After: 2 synthetic (summary + ack) + 2 kept recent = 4 messages.
	assert sess.messages.len == 4, 'got len ${sess.messages.len}'
	// First message is the summary (user role).
	assert sess.messages[0].role == .user
	assert sess.messages[0].content.contains('SUMMARY:')
	// Second is the assistant ack.
	assert sess.messages[1].role == .assistant
	assert sess.messages[1].content.contains('Understood')
	// Last 2 are the kept recent messages.
	assert sess.messages[2].role == .assistant
	assert sess.messages[3].role == .user
	assert sess.messages[3].content == 'also add tests'
}

fn test_compact_preserves_only_compact_keep_recent() {
	// Test that exactly 2 messages are kept (the trailing pair).
	mut a := new_agent(new_fake(['summary']), '')
	a.context_window = 50
	a.compact_threshold = 0.1
	mut sess := new_session('/tmp')
	for i in 0 .. 10 {
		sess.append_user('user msg ${i}')
		sess.append_assistant('assistant msg ${i}', []ToolCall{})
	}
	assert sess.messages.len == 20

	compacted := a.compact(mut sess, false, '')!
	assert compacted == true
	// 2 synthetic + 2 recent = 4
	assert sess.messages.len == 4
	// Last 2 are the original 19th and 20th messages.
	assert sess.messages[2].content == 'user msg 9'
	assert sess.messages[3].content == 'assistant msg 9'
}

fn test_compact_calls_on_compact_callback() {
	// Use a channel to detect callback invocation — V's ?fn (function
	// pointer) doesn't capture local mut vars, but it captures channels
	// (they're reference types). This matches how the TUI wires its
	// on_delta callback to a status channel.
	cb_ch := chan int{cap: 2}
	// Use a long fake summary so after < before; a short summary + a
	// verbose synthetic intro would actually be longer than the
	// original (this is expected — compaction only saves tokens when
	// the original session is long).
	summary_text := 'x'.repeat(500)
	mut a := new_agent(new_fake([summary_text]), '')
	a.context_window = 200
	a.compact_threshold = 0.1
	a.on_compact = fn [cb_ch] (before int, after int) {
		cb_ch <- before
		cb_ch <- after
	}
	mut sess := new_session('/tmp')
	// 8 long messages, well over the 200-token window.
	for i in 0 .. 8 {
		sess.append_user('user message number ${i}: ${'y'.repeat(200)}')
	}
	a.compact(mut sess, false, '')!
	before := <-cb_ch or {
		assert false, 'on_compact was not called (channel empty for before)'
		return
	}
	after := <-cb_ch or {
		assert false, 'on_compact second value missing'
		return
	}
	assert before > 0, 'before=${before}'
	assert after > 0, 'after=${after}'
	assert after < before, 'expected after < before, got after=${after} before=${before}'
}

fn test_compact_graceful_on_summary_failure() {
	// FakeProvider returns an error event. compact() should NOT panic,
	// should NOT mutate the session, and should return false.
	mut a := new_agent(new_fake_err('simulated network error'), '')
	a.context_window = 50
	a.compact_threshold = 0.1
	mut sess := new_session('/tmp')
	for i in 0 .. 6 {
		sess.append_user('user ${i}')
	}
	before_len := sess.messages.len
	compacted := a.compact(mut sess, false, '')!
	assert compacted == false
	// Session unchanged.
	assert sess.messages.len == before_len
}

fn test_compact_graceful_on_empty_summary() {
	// FakeProvider returns no deltas. compact() should treat empty
	// summary as failure and not mutate the session.
	mut a := new_agent(new_fake([]string{}), '')
	a.context_window = 50
	a.compact_threshold = 0.1
	mut sess := new_session('/tmp')
	for i in 0 .. 6 {
		sess.append_user('user ${i}')
	}
	before_len := sess.messages.len
	compacted := a.compact(mut sess, false, '')!
	assert compacted == false
	assert sess.messages.len == before_len
}

fn test_compact_reduces_estimated_tokens() {
	// After compaction, the estimated token count should be noticeably
	// smaller. We seed a long session, compact, then check.
	mut a := new_agent(new_fake(['z'.repeat(500)]), '')
	a.context_window = 100 // tiny window so compaction triggers
	a.compact_threshold = 0.1
	mut sess := new_session('/tmp')
	long := 'x'.repeat(500) // 500-byte message
	for i in 0 .. 6 {
		sess.append_user('msg ${i}: ${long}')
	}
	before := estimate_tokens(sess.messages)
	a.compact(mut sess, false, '')!
	after := estimate_tokens(sess.messages)
	assert after < before, 'expected after (${after}) < before (${before})'
}

fn test_build_summary_prompt() {
	body := 'conversation body here'
	// No instruction: the prompt should not contain the instruction marker.
	plain := build_summary_prompt(body, '')
	assert !plain.contains('Additional user instruction')
	assert plain.contains('--- Conversation to summarize ---')
	// The body must come after the section marker.
	body_idx := plain.index(body) or { -1 }
	marker_idx := plain.index('--- Conversation to summarize ---') or { -1 }
	assert marker_idx >= 0 && body_idx > marker_idx
	// With an instruction: marker present, instruction text present, body still last.
	instr := 'focus on the API design decisions'
	guided := build_summary_prompt(body, instr)
	assert guided.contains('Additional user instruction for this compaction:')
	assert guided.contains(instr)
	assert guided.contains('--- Conversation to summarize ---')
	assert guided.index(body) or { -1 } > guided.index('--- Conversation to summarize ---') or {
		-1
	}
}
