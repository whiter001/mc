// tui_render.v — render the TUI frame.
//
// Strategy: full repaint each frame. Diff rendering (only updating changed
// regions) is a P1.5 optimization. For MVP, full repaint at ~30fps is
// cheap enough and drastically simpler.
//
// Layout:
//
//   ┌─ kimi (model-name) ─────── tokens: in/out ─────────┐   row 1
//   │ status line (running / idle / error)              │   row 2
//   │                                                    │
//   │ [conversation blocks, scrollback]                 │   rows 3..N-3
//   │                                                    │
//   │ ───────────────────────────────────────────────  │   row N-2 (separator)
//   │ > input box (multi-line, with cursor)            │   rows N-1..N
//   └────────────────────────────────────────────────────┘   row N
//
// `render()` writes the whole frame to stdout in one go so the user
// never sees a partial frame.
module main

import strings

// render produces the full ANSI escape sequence for one frame.
//
// Layout:
//   row 1:    header (model + tokens)
//   row 2:    status
//   rows 3..(rows-reserved-2): conversation scrollback
//   row rows-reserved-1: separator
//   rows (rows-reserved)..rows: input box (1+ lines, multi-line capable)
fn render(s TuiState, ib InputBuf) string {
	mut buf := strings.Builder{}

	// Hide cursor at start of frame; we'll position it on the input row.
	buf.write_string(cursor_hide())
	// Move to top-left.
	buf.write_string(esc + '[H')
	// Clear the whole screen.
	buf.write_string(esc + '[2J')

	// Compute the input area height. Multi-line input grows with the
	// number of \n in the buffer; cap at max_input_rows so a runaway
	// paste can't eat the whole screen.
	mut max_input_rows := if s.rows / 4 < 8 { s.rows / 4 } else { 8 }
	if max_input_rows < 1 { max_input_rows = 1 }
	mut input_rows := input_line_count(ib.text)
	if input_rows > max_input_rows {
		input_rows = max_input_rows
	}
	if input_rows < 1 { input_rows = 1 }

	// Reserved: 1 header + 1 status + 1 separator + input_rows.
	reserved := 3 + input_rows
	mut conv_rows := s.rows - reserved
	if conv_rows < 3 { conv_rows = 3 }

	// 1. Header.
	buf.write_string(esc_gray)
	buf.write_string('─ kimi')
	if s.input_tokens > 0 || s.output_tokens > 0 {
		buf.write_string('  ─  tokens: ${s.input_tokens}↑ ${s.output_tokens}↓')
	}
	buf.write_string(esc_reset)
	buf.write_string('\n')

	// 2. Status line.
	buf.write_string(esc_dim)
	if s.status.len > 0 {
		buf.write_string('  ${s.status}')
	} else {
		buf.write_string('  idle')
	}
	buf.write_string(esc_reset)
	buf.write_string('\n')

	// 3. Conversation scrollback (most recent at bottom).
	lines := render_conversation(s, conv_rows)
	for line in lines {
		buf.write_string(line)
		buf.write_string('\n')
	}

	// Pad to fill the conversation area.
	pad := conv_rows - lines.len
	for _ in 0 .. pad {
		buf.write_string('\n')
	}

	// 4. Separator.
	buf.write_string(esc_gray)
	buf.write_string('─'.repeat(s.cols))
	buf.write_string(esc_reset)
	buf.write_string('\n')

	// 5. Input box. We show "❯ <text>" split on \n; first line gets the
	// prompt prefix, continuation lines are indented to align under it.
	render_input(mut buf, ib)

	// 6. Approval modal (drawn last so it sits on top of the input row).
	if req := s.pending_approval {
		render_approval_modal(mut buf, req, s.cols)
	}

	return buf.str()
}

// render_approval_modal draws a single-line "y/n" prompt anchored to the
// bottom of the screen. We use a single bright row instead of a centered
// box to keep the diff small; users on narrow terminals still see the
// prompt and the tool name.
fn render_approval_modal(mut buf strings.Builder, req ApprovalRequest, cols int) {
	// Truncate the args display so a 4KB bash command doesn't flood the
	// modal. 200 chars is enough to see what's about to run.
	preview := if req.args.len > 200 { req.args[..200] + '...' } else { req.args }
	// Move to the last line; clear it; write the prompt; show cursor.
	buf.write_string(esc + '[${0};1H')
	buf.write_string(esc + '[2K')
	buf.write_string(esc_bg_blue)
	buf.write_string(esc + '[97m') // bright white
	buf.write_string('  ⚠ approve ${req.tool_name}? ')
	buf.write_string(esc_reset)
	buf.write_string(esc_bg_blue)
	buf.write_string(esc_gray)
	buf.write_string(preview.replace('\n', ' '))
	buf.write_string('  ')
	buf.write_string(esc + '[97m')
	buf.write_string('[y]es  [a]lways  [n]o')
	buf.write_string(esc_reset)
	buf.write_string(cursor_show())
}

// input_line_count returns how many screen rows the input buffer will
// occupy when rendered. It's 1 + the number of \n in the text. Soft-
// wrapping long single lines isn't counted (we accept overflow today;
// fixed-width terminals with sane widths won't see this in practice).
fn input_line_count(text string) int {
	if text.len == 0 {
		return 1
	}
	mut n := 1
	for i := 0; i < text.len; i++ {
		if text[i] == `\n` {
			n++
		}
	}
	return n
}

// render_conversation walks the blocks list (most recent first), renders
// each one to a list of wrapped lines, then truncates to fit the available
// rows. Returns the visible lines in display order.
fn render_conversation(s TuiState, max_rows int) []string {
	mut lines := []string{}
	// Walk blocks in reverse so most recent is at the bottom.
	for i := s.blocks.len - 1; i >= 0 && lines.len < max_rows; i-- {
		block := s.blocks[i]
		// Skip if block's lines are entirely below the visible window
		// (handled later by truncation).
		rendered := render_block(block)
		// Prepend: append current then add rendered at front.
		mut new_lines := rendered.clone()
		new_lines << lines.clone()
		lines = new_lines.clone()
		if lines.len > max_rows {
			lines = unsafe { lines[lines.len - max_rows..] }
		}
	}
	// Include in-progress streaming as the final blocks: thinking first
	// (above the answer), then the assistant text. Renders live as chunks
	// arrive via state.streaming_thinking / state.streaming.
	if s.streaming_thinking.len > 0 {
		thinking := render_block(Block{
			kind: .thinking
			text: s.streaming_thinking
		})
		lines << thinking
		if lines.len > max_rows {
			// Drop the oldest rows; `lines` is local so the unsafe slice
			// header aliasing is fine.
			lines = unsafe { lines[lines.len - max_rows..] }
		}
	}
	if s.streaming.len > 0 || s.streaming_done {
		streamed := render_block(Block{
			kind: .assistant
			text: s.streaming
		})
		lines << streamed
		if lines.len > max_rows {
			lines = unsafe { lines[lines.len - max_rows..] }
		}
	}
	return lines
}

// render_block converts a single block to a list of display lines.
fn render_block(b Block) []string {
	match b.kind {
		.user {
			prefix := '${esc_green}❯${esc_reset} '
			return wrap_lines(b.text, prefix, '')
		}
		.assistant {
			return wrap_lines(b.text, '', '')
		}
		.thinking {
			// Reasoning content (k1.5 / R1 style). Dim gray with a brain
			// emoji on the first line so it's visually distinct from the
			// final assistant answer that follows.
			prefix := '${esc_gray}💭 ${esc_reset}${esc_dim}'
			return wrap_lines(b.text, prefix, '${esc_dim}')
		}
		.tool_call {
			head := '${esc_cyan}⚙ ${b.tool_name}${esc_reset}${esc_dim}(${b.tool_args})${esc_reset}'
			return [head]
		}
		.tool_result {
			// Folded: render a single summary line so the conversation
			// scrollback stays compact when the user hits Ctrl-O. The
			// collapsed count is the number of source lines we hid
			// (trimmed, then split on \n), which gives a useful "how
			// much am I hiding?" hint without doing byte math.
			if b.collapsed {
				body := b.tool_result.trim_space()
				line_count := body.split('\n').len
				plural := if line_count == 1 { '' } else { 's' }
				folded := '${esc_dim}  ← ${b.tool_name}: ${line_count} line${plural} collapsed — Ctrl-O to expand${esc_reset}'
				return [folded]
			}
			color := if b.tool_is_error { esc_red } else { esc_dim }
			body := b.tool_result.trim_space()
			return wrap_lines(body, '${color}  ← ${esc_reset}', '')
		}
		.system {
			return wrap_lines(b.text, '${esc_yellow}! ${esc_reset}', '')
		}
	}
}

// wrap_lines hard-wraps `text` at `width` columns, prefixing the first
// line with `first_prefix` and subsequent lines with `rest_prefix`. The
// returned lines do NOT include trailing newlines.
//
// Word-wrap respects whitespace; very long words break at width.
fn wrap_lines(text string, first_prefix string, rest_prefix string) []string {
	mut out := []string{}
	width := 100 // soft default; real width applied by caller

	mut current := first_prefix
	mut cur_len := first_prefix.len // approximate; ignores ANSI escape width
	mut first := true
	words := text.split(' ')
	for word in words {
		wlen := word.len
		if cur_len + wlen + 1 > width && !first {
			out << current
			current = rest_prefix
			cur_len = rest_prefix.len
			first = false
		}
		current += '${word} '
		cur_len += wlen + 1
	}
	if current.len > 0 {
		out << current
	}
	return out
}

// render_input writes the input box (❯ <text>) into the provided buffer.
// Splits on \n so the user can type multi-line prompts: the first line
// gets the "❯ " prefix, each continuation line gets a 2-space indent
// to keep text aligned under the prompt.
//
// Cursor positioning is left at the end of the buffer (we don't try to
// position the visible cursor mid-line — that needs absolute ANSI
// cursor addressing and tracking of (row, col) instead of a flat byte
// offset, which is a follow-up).
fn render_input(mut buf strings.Builder, ib InputBuf) {
	// Empty input: just show the prompt, no text, cursor at column 2.
	if ib.text.len == 0 {
		buf.write_string(esc_green)
		buf.write_string('❯ ')
		buf.write_string(esc_reset)
		buf.write_string(cursor_show())
		return
	}
	// Split on \n and render each segment on its own visual line.
	mut first := true
	mut start := 0
	for i := 0; i <= ib.text.len; i++ {
		at_end := i == ib.text.len
		at_newline := !at_end && ib.text[i] == `\n`
		if at_end || at_newline {
			if first {
				buf.write_string(esc_green)
				buf.write_string('❯ ')
				buf.write_string(esc_reset)
				first = false
			} else {
				buf.write_string('  ')
			}
			buf.write_string(ib.text[start..i])
			// Pad to end of row so the previous content is fully
			// overwritten (we cleared the whole screen at frame start,
			// but each line needs its own newline terminator).
			if !at_end {
				buf.write_string('\n')
			}
			start = i + 1
		}
	}
	// Trailing space for the blinking cursor. Drop the cursor on the
	// last visual line; the user can type to extend.
	buf.write_string(' ')
	buf.write_string(cursor_show())
}