// compaction.v — context-window overflow protection.
//
// When the session grows past a configurable fraction of the model's
// context window, we summarize the older messages via the same LLM and
// replace them in the session with a single user/assistant pair that
// carries the summary. The most recent K messages are kept verbatim so
// the model's local working context (latest user turn, pending tool
// results) is not lost.
//
// Design choices (for self-use parity target):
//   - Estimate tokens as `bytes / 3`. Real BPE would cost us a dependency
//     and a lot of code; an over-estimate is safer than an under-estimate
//     (we compact earlier, never miss a 400 from the model).
//   - Default threshold: 60% of context window. Upstream kimi-cli uses
//     ~75%; we go lower because failing open is worse than compacting too
//     eagerly when you're the only user.
//   - Summary uses the same provider/model. No special model routing.
//   - Compaction failure is non-fatal: log and continue. We'd rather
//     lose a turn than crash the session.

module main

import strings

// default_context_window is the fallback when the agent doesn't know
// the model's window. 128k covers k1.5 / Claude / GPT-4-class models.
pub const default_context_window = 128_000

// default_compact_threshold is the fraction of context_window above which
// compaction triggers. 0.6 = compact when estimated tokens exceed 60%.
pub const default_compact_threshold = f32(0.6)

// compact_keep_recent is how many trailing messages to keep verbatim
// after compaction. 2 = the latest user turn + the latest assistant turn
// (or 1 user + 1 tool result if the model just got a tool result back).
// More than 2 starts to defeat the purpose; less risks cutting the model
// off mid-task.
pub const compact_keep_recent = 2

// compact_min_messages is the minimum message count required to consider
// compacting. Below this, the conversation is too short to be worth
// summarizing (and likely the model hasn't accumulated much context).
pub const compact_min_messages = 4

// estimate_tokens returns a rough token count for the message list.
//
// Algorithm: bytes / 3. This is a deliberate over-estimate for English
// (real ratio is ~4 bytes/token) and a deliberate under-estimate for
// CJK (real ratio is ~1.5 bytes/token). On mixed content the bias
// averages out to something close to accurate. We add a small per-
// message overhead to account for role tags and message framing that
// the tokenizer adds.
//
// For tool_calls, we count the JSON arguments bytes too — those are
// sent to the model and count against the context.
pub fn estimate_tokens(messages []Message) int {
	mut total := 0
	for m in messages {
		// Content bytes / 3.
		total += m.content.len / 3
		// Per-message overhead: ~4 tokens for role tag + framing.
		total += 4
		// Tool calls: name + JSON arguments bytes.
		for tc in m.tool_calls {
			total += tc.name.len / 3
			total += tc.arguments.len / 3
			total += 4
		}
	}
	return total
}

// should_compact returns true if the estimated token count is above the
// configured threshold of the model's context window.
pub fn should_compact(estimated int, context_window int, threshold f32) bool {
	if context_window <= 0 {
		return false
	}
	cutoff := int(f32(context_window) * threshold)
	return estimated > cutoff
}

// format_messages_for_summary renders the messages as plain text suitable
// for sending to the LLM as a "summarize this" prompt. Each message
// becomes `[role]\ncontent` plus any tool calls on separate indented
// lines.
fn format_messages_for_summary(messages []Message) string {
	mut buf := strings.new_builder(1024)
	for m in messages {
		buf.write_string('[${m.role.str()}]\n')
		if m.content.len > 0 {
			buf.write_string(m.content)
		}
		for tc in m.tool_calls {
			buf.write_string('\n  tool_call: ${tc.name}(${tc.arguments})')
		}
		buf.write_string('\n\n')
	}
	return buf.str()
}

// compact summarizes older messages via the LLM and replaces them in the
// session. Returns true if any compaction happened, false if it was a
// no-op (session too small, under threshold, or summary call failed).
//
// Failures are non-fatal: we log to stderr and return false. The caller
// should not abort the agent loop on a compaction failure.
//
// The most recent `compact_keep_recent` messages are kept verbatim.
// Everything before that is summarized and replaced with two synthetic
// messages: a user message containing the summary, and an assistant
// acknowledgement.
pub fn (mut a Agent) compact(mut sess Session) !bool {
	estimated := estimate_tokens(sess.messages)
	if !should_compact(estimated, a.context_window, a.compact_threshold) {
		return false
	}
	if sess.messages.len < compact_min_messages {
		return false
	}
	if sess.messages.len <= compact_keep_recent {
		return false
	}

	cutoff := sess.messages.len - compact_keep_recent
	to_summarize := sess.messages[..cutoff].clone()
	recent := sess.messages[cutoff..].clone()

	// ── PreCompact hook (observation-only; return value ignored) ──
	mut pre_c := map[string]string{}
	pre_c['trigger'] = 'auto'
	pre_c['estimated_tokens'] = estimated.str()
	a.hooks_engine().run_hook_for_event(.pre_compact, 'auto', pre_c)

	summary := a.summarize_messages(to_summarize) or {
		eprintln('compaction: summary call failed: ${err.msg()}')
		return false
	}
	if summary.trim_space().len == 0 {
		eprintln('compaction: summary was empty, skipping')
		return false
	}

	// Build the new message list: summary as a user turn, ack from
	// assistant, then the recent messages we kept verbatim.
	mut new_messages := []Message{cap: recent.len + 2}
	new_messages << Message{
		role: .user
		content: 'Here is a summary of the earlier conversation that has been compacted to save context space:\n\n${summary}\n\nThe most recent messages follow. Continue from where we left off.'
	}
	new_messages << Message{
		role: .assistant
		content: 'Understood. I have the summarized context. Continuing with the recent messages.'
	}
	new_messages << recent

	before := sess.messages.len
	sess.messages = new_messages
	after := sess.messages.len
	after_tokens := estimate_tokens(sess.messages)

	if cb := a.on_compact {
		cb(estimated, after_tokens)
	}
	// ── PostCompact hook (observation-only) ──
	mut post_c := map[string]string{}
	post_c['trigger'] = 'auto'
	post_c['before_tokens'] = estimated.str()
	post_c['after_tokens'] = after_tokens.str()
	a.hooks_engine().run_hook_for_event(.post_compact, 'auto', post_c)
	eprintln('compaction: ${before} messages (${estimated} est tokens) → ${after} messages (${after_tokens} est tokens)')
	return true
}

// summarize_messages calls the LLM to summarize the given message list.
// Uses a separate cancel channel so a Ctrl-C during summarization
// doesn't affect the next turn's cancel signal.
//
// The summary prompt is engineered to preserve:
//   - The user's original goal(s)
//   - Key file paths and code snippets referenced
//   - Decisions made and the reasoning behind them
//   - Open issues / next steps
//   - Tool results containing essential state (test output, file listings)
//
// Max output capped at 1024 tokens to keep the summary bounded.
fn (mut a Agent) summarize_messages(messages []Message) !string {
	body := format_messages_for_summary(messages)
	prompt := 'You are summarizing a coding agent conversation for context preservation. ' +
		'Produce a concise summary that preserves:\n' +
		'- The user\'s original goal(s)\n' +
		'- Key file paths and code snippets referenced\n' +
		'- Decisions made and the reasoning behind them\n' +
		'- Open issues / next steps\n' +
		'- Tool results that contain essential state (e.g. test output, file listings)\n\n' +
		'Be concise but lossless on facts. Do not editorialize. ' +
		'Write in the same language as the conversation (English or Chinese).\n\n' +
		'--- Conversation to summarize ---\n\n${body}'

	req := ChatRequest{
		model:       a.provider.model
		messages:    [Message{ role: .user, content: prompt }]
		temperature: 0.0
		max_tokens:  1024
	}

	// Separate cancel channel so a Ctrl-C during summary doesn't poison
	// the next step's cancel signal.
	summary_cancel := chan int{cap: 1}
	ch := chan ChatEvent{cap: 32}
	go a.provider.chat(req, ch, summary_cancel)

	mut buf := strings.new_builder(512)
	for {
		ev := <-ch or { break }
		match ev.kind {
			.delta {
				buf.write_string(ev.content)
			}
			.err_kind {
				return error('provider: ${ev.err}')
			}
			.end_of_stream {
				break
			}
			else {
				continue
			}
		}
	}
	return buf.str()
}
