// session_switch.v — in-TUI session browsing, switching, and manual
// compaction.
//
// The runner loop owns the live Session; the TUI cannot mutate it
// directly. To switch sessions or force a compaction we send a
// SessionControl over session_control_ch, which the runner drains at the
// top of each loop iteration (non-blocking, 1ms poll so idle waits are
// skipped immediately — same pattern as the plan-control drain).
module main

// SessionControlKind selects what the runner should do with a control
// message.
pub enum SessionControlKind {
	switch
	compact
}

// SessionControl is a request from the TUI to the runner loop.
pub struct SessionControl {
pub:
	kind SessionControlKind
	// For .switch: the target session id.
	session_id string
	// For .compact: optional instruction injected into the summary prompt
	// so a manual /compact can steer what the summary should focus on.
	instruction string
}

// session_messages_to_blocks converts a loaded Session's messages into
// renderable conversation blocks. Used after switching sessions to redraw
// the TUI from disk state — the runner never ships big payloads over the
// status channel, the TUI just reloads the session from disk itself.
fn session_messages_to_blocks(messages []Message) []Block {
	mut blocks := []Block{}
	for m in messages {
		match m.role {
			.user {
				blocks << Block{
					kind: .user
					text: m.content
				}
			}
			.assistant {
				blocks << Block{
					kind: .assistant
					text: m.content
				}
				// Each tool call the assistant emitted is its own block so
				// the follow-up .tool result can be paired visually with it.
				for tc in m.tool_calls {
					blocks << Block{
						kind:      .tool_call
						tool_name: tc.name
						tool_args: tc.arguments
					}
				}
			}
			.tool {
				blocks << Block{
					kind:          .tool_result
					tool_name:     m.name
					tool_result:   m.content
					tool_is_error: false
				}
			}
			.system {
				blocks << Block{
					kind: .system
					text: m.content
				}
			}
		}
	}
	return blocks
}

// format_session_modal_lines renders the /sessions picker overlay as
// display lines. Line 0 is the header (highlighted), lines 1..n are the
// numbered sessions (1-based, newest first), and the last line is the
// hint row. The caller renders it like the ask/plan modals.
fn format_session_modal_lines(summaries []SessionSummary) []string {
	mut lines := []string{cap: summaries.len + 2}
	lines << 'sessions (newest first):'
	for i, s in summaries {
		num := i + 1
		mut id := s.id
		if id.len > 20 {
			id = id[..20] + '…'
		}
		// time format "2006-01-02 15:04:05" → keep "01-02 15:04".
		ts := s.updated_at.format()
		short_ts := if ts.len >= 16 { ts[5..16] } else { ts }
		mut preview := s.first_user
		if preview.len > 40 {
			preview = preview[..40] + '…'
		}
		lines << '${num}) ${id}  ${short_ts}  ${s.msg_count} msgs  ${preview}'
	}
	lines << 'pick a number; Esc to cancel'
	return lines
}
