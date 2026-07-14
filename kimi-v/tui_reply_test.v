// Temporary test: simulate the agent->status->render path for an assistant
// reply WITHOUT any network, to confirm the display layer renders streamed
// deltas + the promoted assistant block. If this passes, the rendering path
// is correct and the "reply not showing" bug lives upstream (provider/agent).
module main

import os

fn test_assistant_reply_renders_without_network() {
	mut state := new_tui_state()
	ib := new_input_buf()
	state.cols = 80
	state.rows = 24
	handle_status(status_started(), mut state)
	handle_status(status_delta('Hello'), mut state)
	handle_status(status_delta(' world'), mut state)
	handle_status(status_finished(10, 5), mut state)
	frame := render(state, ib)
	assert frame.contains('Hello world'), 'assistant reply not rendered in frame:\n${frame}'
	// And the user message path too.
	mut s2 := new_tui_state()
	s2.cols = 80
	s2.rows = 24
	s2.blocks << Block{ kind: .user, text: 'ping' }
	f2 := render(s2, ib)
	assert f2.contains('ping'), 'user message not rendered:\n${f2}'
}

// CJK / full-width glyphs occupy 2 terminal cells. The cursor math in the
// input box and the line-wrapping width must account for that, otherwise
// the cursor lands in the wrong column and the input box looks misaligned
// when typing Chinese. These tests pin that behaviour.
fn test_visible_len_counts_wide_glyphs_as_two_cells() {
	assert visible_len('❯ ') == 2, 'prefix should be 2 cells'
	assert visible_len('你好世界') == 8, '6 CJK chars should be 8 cells, got ${visible_len("你好世界")}'
	assert visible_len('a你b') == 4, 'mixed-width should sum per-glyph'
	// ANSI color codes are invisible and must not count.
	assert visible_len('${esc_green}hi') == 2, 'ANSI escapes must not add width'
}

fn test_input_cursor_pos_tracks_wide_glyphs() {
	cols := 80
	mut ib := new_input_buf()
	mut line := 0
	mut col := 0
	// Cursor at start: on column 3 (right after the "❯ " prefix).
	ib.text = '你好世界这是第一行'
	ib.cursor = 0
	line, col = input_cursor_pos(ib, cols)
	assert line == 0 && col == 3, 'empty cursor should sit at col 3, got ${line},${col}'
	// Cursor at end of 9 CJK chars: 2 (prefix) + 9*2 = 20 cells → col 21.
	ib.cursor = ib.text.len
	line, col = input_cursor_pos(ib, cols)
	assert line == 0 && col == 21, '9 CJK chars should land at col 21, got ${line},${col}'
	// Multi-line: "你好\n世界" — second line indented, cursor after 世界.
	ib.text = '你好\n世界'
	ib.cursor = ib.text.len
	line, col = input_cursor_pos(ib, cols)
	assert line == 1 && col == 7, 'second line cursor at col 7, got ${line},${col}'
	// Mid-string cursor: after the first CJK char (2 cells) on line 1.
	ib.text = '你好\n世界'
	ib.cursor = 3 // byte offset of the first char (3 bytes)
	line, col = input_cursor_pos(ib, cols)
	assert line == 0 && col == 5, 'after one CJK char on line 1: col 5, got ${line},${col}'
}

// Multi-line CJK draft must render both lines aligned: first line gets the
// "❯ " prompt, continuation gets a 2-space indent, both with text at col 3.
fn test_render_multiline_cjk_draft_aligns() {
	mut state := new_tui_state()
	state.cols = 80
	state.rows = 24
	mut ib := new_input_buf()
	ib.text = '你好世界这是第一行\n第二行中文输入'
	ib.cursor = ib.text.len
	frame := render(state, ib)
	// Strip ANSI to make the structure assertable.
	mut clean := ''
	mut i := 0
	for i < frame.len {
		if frame[i] == `\x1b` {
			i++
			for i < frame.len && frame[i] != `[` { i++ }
			i++
			for i < frame.len && !((frame[i] >= 65 && frame[i] <= 90) || (frame[i] >= 97 && frame[i] <= 122)) { i++ }
			if i < frame.len { i++ }
			continue
		}
		clean += frame[i].ascii_str()
		i++
	}
	lines := clean.split('\n')
	// The input box sits at the bottom: separator, then the two input
	// lines (first line gets "❯ ", continuation gets a 2-space indent).
	n := lines.len
	assert lines[n - 3].starts_with('─'), 'separator missing, got: ${lines[n - 3]}'
	assert lines[n - 2] == '❯ 你好世界这是第一行', 'first input line wrong: ${lines[n - 2]}'
	assert lines[n - 1].starts_with('  第二行中文输入'), 'continuation indent wrong: "${lines[n - 1]}"'
}
