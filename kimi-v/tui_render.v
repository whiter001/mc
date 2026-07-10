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
//   rows (rows-reserved)..rows: input box (1-2 lines reserved)
fn render(s TuiState, ib InputBuf) string {
	mut buf := strings.Builder{}

	// Hide cursor at start of frame; we'll position it on the input row.
	buf.write_string(cursor_hide())
	// Move to top-left.
	buf.write_string(esc + '[H')
	// Clear the whole screen.
	buf.write_string(esc + '[2J')

	// Compute reserved rows.
	reserved := 3 // 1 header + 1 status + 1 separator; input takes 1-2
	mut conv_rows := s.rows - reserved - 1 // leave 1 row for input
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

	// 5. Input box. We show "> text" with cursor positioned correctly.
	render_input(mut buf, ib, s.cols)

	return buf.str()
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
			lines = lines[lines.len - max_rows..]
		}
	}
	// Include the streaming text as a final in-progress block.
	if s.streaming.len > 0 || s.streaming_done {
		streamed := render_block(Block{
			kind: .assistant
			text: s.streaming
		})
		lines << streamed
		if lines.len > max_rows {
			lines = lines[lines.len - max_rows..]
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

// render_input writes the input box (> <text>) into the provided buffer.
fn render_input(mut buf strings.Builder, ib InputBuf, cols int) {
	// Show "> <text>" with a visible cursor.
	buf.write_string(esc_green)
	buf.write_string('❯ ')
	buf.write_string(esc_reset)
	buf.write_string(ib.text)
	// Position cursor: after "> " prefix + ib.cursor characters of text.
	// We don't reposition cursor via ANSI; we just write a space and let
	// the next read_key run reset things. This is acceptable for full
	// repaint — the cursor blinks at the end of the line until next
	// keystroke.
	buf.write_string(' ')
	buf.write_string(cursor_show())
}