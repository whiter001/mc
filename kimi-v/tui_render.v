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
//   row rows-reserved:     attachment row (only when there are pending
//                         attachments — P0.7)
//   rows (rows-reserved+1)..rows: input box (1+ lines, multi-line capable)
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
	// paste can't eat the whole screen. The attachment row (when any
	// attachments are pending) is one extra row above the prompt.
	mut max_input_rows := if s.rows / 4 < 8 { s.rows / 4 } else { 8 }
	if max_input_rows < 1 { max_input_rows = 1 }
	mut input_rows := input_line_count(ib.text, ib.attachments.len)
	if input_rows > max_input_rows {
		input_rows = max_input_rows
	}
	if input_rows < 1 { input_rows = 1 }

	// Reserved: 1 header + 1 status + 1 separator + attachment_row? + input_rows.
	mut reserved := 3 + input_rows
	if ib.attachments.len > 0 {
		reserved++
	}
	mut conv_rows := s.rows - reserved
	if conv_rows < 3 { conv_rows = 3 }

	// 1. Header.
	buf.write_string(esc_gray)
	buf.write_string('─ kimi')
	if s.plan_mode_active {
		buf.write_string(esc_yellow)
		buf.write_string('  [PLAN MODE]')
		buf.write_string(esc_gray)
	}
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

	// 3. Conversation scrollback (most recent at bottom). We pass the
	// real terminal width so hard-wrapping matches the physical columns
	// (otherwise lines wrap past `cols`, the terminal soft-wraps them
	// again, and the separator/input rows get drawn over the tail of the
	// conversation — making the AI reply invisible).
	lines := render_conversation(s, conv_rows, s.cols)
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

	// 5. Attachment row (P0.7) — only when there are pending
	// attachments. Shows one badge per attachment with the display
	// name and an inline size hint. Cleared with Ctrl-X.
	if ib.attachments.len > 0 {
		render_attachment_row(mut buf, ib)
	}

	// 6. Input box. We show "❯ <text>" split on \n; first line gets the
	// prompt prefix, continuation lines are indented to align under it.
	// Compute the input box's first row (1-based) so the render can place
	// the cursor at the real editing position (see render_input).
	att := if ib.attachments.len > 0 { 1 } else { 0 }
	input_start_row := conv_rows + 4 + att
	render_input(mut buf, ib, input_start_row, s.cols)

	// 7. Approval modal (drawn last so it sits on top of the input row).
	if req := s.pending_approval {
		render_approval_modal(mut buf, req, s.cols)
	}

	// 8. AskUserQuestion modal (also drawn last / on top).
	if areq := s.pending_ask {
		render_ask_modal(mut buf, areq, s.cols, s.rows)
	}

	// 9. ExitPlanMode review modal (drawn last / on top).
	if preq := s.pending_exit_plan {
		render_exit_plan_modal(mut buf, preq, s.cols, s.rows)
	}

	return buf.str()
}

// render_exit_plan_modal draws the plan-review overlay anchored to the bottom
// of the screen. It shows the plan text (truncated to fit) plus the approval
// controls: y=approve, n=reject, e=reject+exit, r=revise, Esc=dismiss, and a
// numbered choice when the model offered multiple approaches.
fn render_exit_plan_modal(mut buf strings.Builder, req ExitPlanRequest, cols int, rows int) {
	// Build the modal text lines.
	mut lines := []string{}
	lines << '📋 Plan ready for approval' + if req.path.len > 0 { '  (${req.path})' } else { '' }
	// Show the plan body, truncated to a few lines so the modal stays
	// compact. The full plan is also written to the plan file.
	plan_lines := req.plan.split('\n')
	mut shown := 0
	for line in plan_lines {
		if shown >= 8 {
			lines << '  … (plan truncated — full text in plan file)'
			break
		}
		disp := if line.len > cols - 4 { line[..cols - 5] + '…' } else { line }
		lines << '  ${disp}'
		shown++
	}
	for i, opt in req.options {
		desc := if opt.description.len > 0 { ' — ${opt.description}' } else { '' }
		lines << '  ${i + 1}) ${opt.label}${desc}'
	}
	mut hint := '[y] approve'
	if req.options.len >= 2 {
		hint += '  [1-3] pick approach'
	}
	hint += '  [n] reject  [e] reject+exit  [r] revise  [Esc] dismiss'
	lines << hint

	modal_height := lines.len
	start_row := if rows > modal_height { rows - modal_height + 1 } else { 1 }

	for i, line in lines {
		row := start_row + i
		buf.write_string(esc + '[${row};1H')
		buf.write_string(esc + '[2K')
		if i == 0 {
			buf.write_string(esc_bg_blue)
			buf.write_string(esc + '[97m')
			buf.write_string('  ')
		} else {
			buf.write_string(esc + '[100m') // bg gray
			buf.write_string(esc_gray)
			buf.write_string('  ')
		}
		disp := if line.len > cols - 3 { line[..cols - 4] + '…' } else { line }
		buf.write_string(disp)
		buf.write_string(esc_reset)
	}
	buf.write_string(cursor_show())
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

// render_ask_modal draws the AskUserQuestion prompt anchored to the bottom
// of the screen. It shows the question on one row, then one numbered row
// per option, and a hint line. The user picks with digit keys (handled in
// tui_loop.handle_key). Multi-select prompts say so; the harness collects a
// comma-separated list.
fn render_ask_modal(mut buf strings.Builder, req AskRequest, cols int, rows int) {
	// Build the text lines first so we know how tall the modal is.
	mut lines := []string{}
	header := if req.header.len > 0 { '${req.header}: ' } else { '' }
	q := '${header}${req.question}'
	lines << q
	for i, opt in req.options {
		desc := if opt.description.len > 0 { ' — ${opt.description}' } else { '' }
		lines << '  ${i + 1}) ${opt.label}${desc}'
	}
	lines << if req.multi { 'pick one or more (e.g. "1,3"); Esc to skip' } else { 'pick a number; Esc to skip' }

	modal_height := lines.len
	start_row := if rows > modal_height { rows - modal_height + 1 } else { 1 }

	for i, line in lines {
		row := start_row + i
		buf.write_string(esc + '[${row};1H')
		buf.write_string(esc + '[2K')
		// Highlight the first (question) line subtly.
		if i == 0 {
			buf.write_string(esc_bg_blue)
			buf.write_string(esc + '[97m')
			buf.write_string('  ? ')
		} else {
			buf.write_string(esc + '[96m') // cyan for option lines
			buf.write_string('  ')
		}
		// Truncate to terminal width to avoid wrap.
		disp := if line.len > cols - 3 { line[..cols - 4] + '…' } else { line }
		buf.write_string(disp)
		buf.write_string(esc_reset)
	}
	buf.write_string(cursor_show())
}

// input_line_count returns how many screen rows the input area will
// occupy when rendered. It's 1 + the number of \n in the text, plus
// one row for the attachment badges when any attachments are pending
// (P0.7). Soft-wrapping long single lines isn't counted (we accept
// overflow today; fixed-width terminals with sane widths won't see
// this in practice).
fn input_line_count(text string, attachment_count int) int {
	mut n := 1
	if attachment_count > 0 {
		n++
	}
	for i := 0; i < text.len; i++ {
		if text[i] == `\n` {
			n++
		}
	}
	return n
}

// render_attachment_row writes the one-line "📎 name1 (size)  📎 name2
// (size)" badge strip that appears above the prompt when the input
// buffer has pending attachments. Sizes are shown in human-readable
// form (B / KB / MB) using the original byte length — base64-encoded
// size is roughly +33% but the original is more useful for the user
// ("that's the 2MB screenshot I took").
//
// We truncate long names so a 200-char filename doesn't push the
// prompt off-screen; the truncation suffix is "…" (single glyph) to
// make the limit obvious.
fn render_attachment_row(mut buf strings.Builder, ib InputBuf) {
	buf.write_string(esc_dim)
	mut first := true
	for att in ib.attachments {
		if !first {
			buf.write_string('  ')
		}
		first = false
		buf.write_string('📎 ')
		// Truncate display name to keep the row single-line. 32 chars
		// fits comfortably next to the prompt even on narrow terminals.
		name := if att.name.len > 32 { att.name[..31] + '…' } else { att.name }
		buf.write_string(name)
		// Inline size hint: decode the base64 length to get the
		// original byte count. base64 encodes 3 input bytes as 4
		// output chars, so bytes ≈ b64_len * 3 / 4. (Padded inputs
		// use `=` for the last group, so subtract any padding.)
		orig_bytes := b64_decoded_size(att.b64)
		buf.write_string(' (${human_bytes(orig_bytes)})')
	}
	buf.write_string(esc_reset)
	buf.write_string('\n')
}

// b64_decoded_size returns the approximate decoded byte count for a
// base64 string. Used to render a useful "X MB" size hint on
// attachment badges without re-decoding the whole image.
fn b64_decoded_size(b64 string) int {
	// Strip trailing padding if any (b64.decode() is lenient about it,
	// but the math isn't — we want the true decoded length).
	mut n := b64.len
	mut pad := 0
	if n > 0 && b64[n - 1] == `=` { pad++ }
	if n > 1 && b64[n - 2] == `=` { pad++ }
	return (n / 4) * 3 - pad
}

// human_bytes renders a byte count as "B" / "KB" / "MB" / "GB". We
// never see anything bigger than 10 MB in practice (capped by
// max_attachment_bytes in tui_input.v), so GB is mostly future-
// proofing.
fn human_bytes(b int) string {
	if b < 1024 {
		return '${b} B'
	}
	if b < 1024 * 1024 {
		kb := b / 1024
		return '${kb} KB'
	}
	mb := b / (1024 * 1024)
	return '${mb} MB'
}

// render_conversation renders all blocks (oldest first) plus any live
// streaming text into a single list of wrapped lines in display order
// (most recent at the bottom), then truncates to `max_rows` by dropping
// the oldest lines at the top.
//
// We accumulate into one growing list and tail-truncate once at the end,
// which is O(total lines). The previous implementation prepended each
// block's lines with a clone (O(n²) for long scrollback); this avoids
// that quadratic blow-up.
fn render_conversation(s TuiState, max_rows int, cols int) []string {
	// Guard against a zero/garbage width so we don't divide by zero or
	// produce a single giant unwrapped line.
	wrap := if cols > 0 { cols } else { 80 }
	mut lines := []string{}
	// Walk blocks in forward order (oldest first); most recent ends up last.
	for block in s.blocks {
		lines << render_block(block, wrap)
	}
	// Include in-progress streaming as the final blocks: thinking first
	// (above the answer), then the assistant text. Renders live as chunks
	// arrive via state.streaming_thinking / state.streaming.
	if s.streaming_thinking.len > 0 {
		lines << render_block(Block{
			kind: .thinking
			text: s.streaming_thinking
		}, wrap)
	}
	if s.streaming.len > 0 || s.streaming_done {
		lines << render_block(Block{
			kind: .assistant
			text: s.streaming
		}, wrap)
	}
	// Tail-truncate to the visible window (drop oldest lines at the top).
	if lines.len > max_rows {
		lines = unsafe { lines[lines.len - max_rows..] }
	}
	return lines
}

// render_block converts a single block to a list of display lines.
// `width` is the physical terminal width in columns; we hard-wrap to it so
// the rendered line count matches what actually occupies the screen.
fn render_block(b Block, width int) []string {
	match b.kind {
		.user {
			prefix := '${esc_green}❯${esc_reset} '
			return wrap_lines(b.text, prefix, '', width)
		}
		.assistant {
			return wrap_lines(b.text, '', '', width)
		}
		.thinking {
			// Reasoning content (k1.5 / R1 style). Dim gray with a brain
			// emoji on the first line so it's visually distinct from the
			// final assistant answer that follows.
			prefix := '${esc_gray}💭 ${esc_reset}${esc_dim}'
			return wrap_lines(b.text, prefix, '${esc_dim}', width)
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
			return wrap_lines(body, '${color}  ← ${esc_reset}', '', width)
		}
		.system {
			return wrap_lines(b.text, '${esc_yellow}! ${esc_reset}', '', width)
		}
	}
}

// wrap_lines hard-wraps `text` at `width` columns, prefixing the first
// line with `first_prefix` and subsequent lines with `rest_prefix`. The
// returned lines do NOT include trailing newlines.
//
// Word-wrap respects whitespace; very long words break at width. The
// prefixes may contain ANSI escape codes (zero on-screen width) — we pass
// their *visible* length separately so wrapping lands at the right column.
fn wrap_lines(text string, first_prefix string, rest_prefix string, width int) []string {
	mut out := []string{}
	// The prefixes carry ANSI color codes (invisible on screen) plus a
	// small visible glyph ("❯ ", "💭 ", "  ← "). We approximate the
	// visible width by stripping the escape sequences so the wrap count
	// matches what the terminal actually shows.
	first_vis := visible_len(first_prefix)
	rest_vis := visible_len(rest_prefix)
	mut cur_width := width
	if cur_width <= 0 {
		cur_width = 80
	}

	mut current := first_prefix
	mut cur_len := first_vis
	// We always keep at least one word per line (never break in the
	// middle of a word); when a single word is wider than the terminal
	// it stays on its own line and the terminal soft-wraps the overflow.
	words := text.split(' ')
	for word in words {
		wlen := visible_len(word)
		if cur_len > 0 && cur_len + wlen + 1 > cur_width {
			// Current line already has content and this word won't fit
			// — flush it and start a new line with the rest prefix.
			out << current
			current = rest_prefix
			cur_len = rest_vis
		}
		current += '${word} '
		cur_len += wlen + 1
	}
	if current.len > 0 {
		out << current
	}
	return out
}

// visible_len returns the on-screen width of `s`, ignoring ANSI escape
// sequences (e.g. "\x1b[31m"). This is an approximation (it doesn't
// account for wide/full-width Unicode glyphs) but is good enough for
// line-wrapping decisions in the TUI.
fn visible_len(s string) int {
	mut len := 0
	mut i := 0
	for i < s.len {
		if s[i] == `\x1b` {
			// Skip an ANSI CSI sequence: ESC [ ... letter.
			i++
			for i < s.len && s[i] != `[` {
				i++
			}
			i++ // consume '['
			for i < s.len && !(s[i] >= `A` && s[i] <= `Z`) && !(s[i] >= `a` && s[i] <= `z`) {
				i++
			}
			if i < s.len {
				i++ // consume the final letter
			}
			continue
		}
		len++
		i++
	}
	return len
}

// render_input writes the input box (❯ <text>) into the provided buffer.
// Splits on \n so the user can type multi-line prompts: the first line
// gets the "❯ " prefix, each continuation line gets a 2-space indent
// to keep text aligned under the prompt.
//
// The cursor is positioned at the real editing location (ib.cursor byte
// offset) using absolute ANSI addressing, not just left at line end — so
// arrow keys / editing land the beam exactly where the user expects.
fn render_input(mut buf strings.Builder, ib InputBuf, input_start_row int, cols int) {
	// Empty input: just show the prompt, no text, cursor on column 3
	// (after "❯ ").
	if ib.text.len == 0 {
		buf.write_string(esc_green)
		buf.write_string('❯ ')
		buf.write_string(esc_reset)
		position_cursor(mut buf, input_start_row, 3)
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
	// Trailing space for the blinking cursor, then position it at the
	// actual editing offset (so mid-line edits show the beam correctly).
	buf.write_string(' ')
	line_off, col := input_cursor_pos(ib, cols)
	position_cursor(mut buf, input_start_row + line_off, col)
}

// position_cursor emits an absolute cursor-move escape (1-based row/col)
// and makes the cursor visible. Used to place the input beam at the real
// editing location rather than always at line end.
fn position_cursor(mut buf strings.Builder, row int, col int) {
	buf.write_string('${esc}[${row};${col}H')
	buf.write_string(cursor_show())
}

// input_cursor_pos maps the input buffer's cursor byte offset to a
// (line_offset, col) within the input box, where line_offset is 0-based
// from the first input row and col is 1-based (ANSI). Each visual line has
// a 2-column prefix ("❯ " on the first line, "  " on continuation lines)
// so the cursor starts at column 3. Soft-wrap of lines longer than the
// terminal width is approximated by wrapping when the column reaches
// `cols`; wide (CJK/emoji) glyphs are counted as 1 cell, which can be off
// for very long single lines but matches the rest of the TUI's wrapping
// assumptions.
fn input_cursor_pos(ib InputBuf, cols int) (int, int) {
	mut line := 0
	mut col := 2 // prefix width ("❯ " / "  ")
	mut i := 0
	for i < ib.cursor && i < ib.text.len {
		c := ib.text[i]
		if c == `\n` {
			line++
			col = 2
			i++
			continue
		}
		col++
		if col >= cols {
			line++
			col = 0
		}
		step := codepoint_len(ib.text, i)
		i += if step > 0 { step } else { 1 }
	}
	return line, col + 1 // convert 0-based col to 1-based ANSI column
}