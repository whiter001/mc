// tui_input_test.v — unit tests for UTF-8 aware cursor / edit operations.
//
// Run with: v test tui_input
// (or v test . from the project root)
//
// These tests guard against the byte-vs-rune bug: cursor and text edits
// must operate on whole Unicode codepoints, not raw bytes. The previous
// implementation backspaced one byte at a time, leaving broken UTF-8
// when the user typed CJK / emoji / accented Latin.
module main

// hex_of renders a string as space-separated 2-digit hex per byte. Used in
// assertion messages to make broken-UTF-8 bugs obvious.
fn hex_of(s string) string {
	mut parts := []string{}
	for c in s {
		parts << c.hex()
	}
	return parts.join(' ')
}

// ---------- backspace -----------------------------------------------------

fn test_backspace_ascii() {
	mut b := new_input_buf()
	b.insert('hello')
	b.backspace()
	assert b.text == 'hell'
	assert b.cursor == 4
}

fn test_backspace_empty_noop() {
	mut b := new_input_buf()
	b.backspace()
	assert b.text == ''
	assert b.cursor == 0
}

fn test_backspace_at_start_noop() {
	mut b := new_input_buf()
	b.insert('abc')
	b.cursor = 0
	b.backspace()
	assert b.text == 'abc'
	assert b.cursor == 0
}

fn test_backspace_two_byte_latin() {
	// é = 0xC3 0xA9 (2 bytes)
	mut b := new_input_buf()
	b.insert('caf' + '\xc3\xa9')
	b.backspace()
	assert b.text == 'caf', 'got hex=[${hex_of(b.text)}]'
	assert b.cursor == 3
}

fn test_backspace_three_byte_cjk() {
	// 中 = 0xE4 0xB8 0xAD (3 bytes)
	mut b := new_input_buf()
	b.insert('a' + '\xe4\xb8\xad')
	b.backspace()
	assert b.text == 'a', 'got hex=[${hex_of(b.text)}]'
	assert b.cursor == 1
}

fn test_backspace_four_byte_emoji() {
	// 🎉 = 0xF0 0x9F 0x8E 0x89 (4 bytes)
	mut b := new_input_buf()
	b.insert('x' + '\xf0\x9f\x8e\x89')
	b.backspace()
	assert b.text == 'x', 'got hex=[${hex_of(b.text)}]'
	assert b.cursor == 1
}

fn test_backspace_mixed_multibyte() {
	// 你好🎉 — three codepoints, 10 bytes total
	mut b := new_input_buf()
	b.insert('\xe4\xbd\xa0\xe5\xa5\xbd' + '\xf0\x9f\x8e\x89')
	b.backspace()
	assert b.text == '\xe4\xbd\xa0\xe5\xa5\xbd', 'got hex=[${hex_of(b.text)}]'
	assert b.cursor == 6
	// One more backspace drops 好.
	b.backspace()
	assert b.text == '\xe4\xbd\xa0', 'got hex=[${hex_of(b.text)}]'
	assert b.cursor == 3
	// And 你.
	b.backspace()
	assert b.text == '', 'got hex=[${hex_of(b.text)}]'
	assert b.cursor == 0
}

fn test_backspace_mid_buffer() {
	// Cursor in the middle of a buffer — set explicitly to byte 5, the
	// boundary right after 中. Backspace should drop 中 (all 3 bytes),
	// not the single byte before the cursor.
	mut b := new_input_buf()
	b.insert('ab' + '\xe4\xb8\xad' + 'cd')
	assert b.cursor == 7
	b.cursor = 5  // right after 中
	b.backspace()
	assert b.text == 'abcd', 'got hex=[${hex_of(b.text)}]'
	assert b.cursor == 2
}

// ---------- delete_forward -----------------------------------------------

fn test_delete_forward_ascii() {
	mut b := new_input_buf()
	b.insert('hello')
	b.cursor = 0
	b.delete_forward()
	assert b.text == 'ello'
	assert b.cursor == 0
}

fn test_delete_forward_three_byte_cjk() {
	mut b := new_input_buf()
	b.insert('a' + '\xe4\xb8\xad' + 'b')
	b.cursor = 1
	b.delete_forward()
	assert b.text == 'ab', 'got hex=[${hex_of(b.text)}]'
	assert b.cursor == 1
}

fn test_delete_forward_four_byte_emoji() {
	mut b := new_input_buf()
	b.insert('x' + '\xf0\x9f\x8e\x89' + 'y')
	b.cursor = 1
	b.delete_forward()
	assert b.text == 'xy', 'got hex=[${hex_of(b.text)}]'
	assert b.cursor == 1
}

fn test_delete_forward_at_end_noop() {
	mut b := new_input_buf()
	b.insert('abc')
	b.delete_forward()
	assert b.text == 'abc'
	assert b.cursor == 3
}

// ---------- left / right arrow -------------------------------------------

fn test_left_arrow_walks_codepoints() {
	mut b := new_input_buf()
	// 你好 = 6 bytes
	b.insert('\xe4\xbd\xa0\xe5\xa5\xbd')
	assert b.cursor == 6
	// Left should jump from byte 6 to byte 3 (start of 好), not 5.
	b.apply(KeyEvent{ kind: .left })
	assert b.cursor == 3, 'expected cursor at start of 好 (byte 3), got ${b.cursor}'
	b.apply(KeyEvent{ kind: .left })
	assert b.cursor == 0, 'expected cursor at start, got ${b.cursor}'
}

fn test_left_arrow_skips_emoji() {
	mut b := new_input_buf()
	b.insert('a' + '\xf0\x9f\x8e\x89' + 'b')  // a🎉b = 6 bytes
	assert b.cursor == 6
	b.apply(KeyEvent{ kind: .left })
	assert b.cursor == 5, 'expected cursor before b, got ${b.cursor}'
	b.apply(KeyEvent{ kind: .left })
	assert b.cursor == 1, 'expected cursor at start of emoji, got ${b.cursor}'
	b.apply(KeyEvent{ kind: .left })
	assert b.cursor == 0
}

fn test_right_arrow_walks_codepoints() {
	mut b := new_input_buf()
	b.insert('\xe4\xbd\xa0\xe5\xa5\xbd')
	b.cursor = 0
	b.apply(KeyEvent{ kind: .right })
	assert b.cursor == 3, 'expected cursor after 你, got ${b.cursor}'
	b.apply(KeyEvent{ kind: .right })
	assert b.cursor == 6
}

fn test_left_at_start_noop() {
	mut b := new_input_buf()
	b.insert('abc')
	b.cursor = 0
	b.apply(KeyEvent{ kind: .left })
	assert b.cursor == 0
}

fn test_right_at_end_noop() {
	mut b := new_input_buf()
	b.insert('abc')
	b.apply(KeyEvent{ kind: .right })
	assert b.cursor == 3
}

// ---------- kill_word (Ctrl-W) -------------------------------------------

fn test_kill_word_ascii() {
	mut b := new_input_buf()
	b.insert('hello world')
	b.cursor = b.text.len
	b.kill_word()
	assert b.text == 'hello ', 'got [${b.text}]'
	assert b.cursor == 6
}

fn test_kill_word_cjk_treats_as_single_unit() {
	// "你好世界" — single word, all CJK, no spaces. kill_word from end
	// should drop the whole thing (proves it walks by codepoint, not byte).
	mut b := new_input_buf()
	b.insert('\xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8\x96\xe7\x95\x8c')
	assert b.text.len == 12
	b.cursor = b.text.len
	b.kill_word()
	assert b.text == '', 'got hex=[${hex_of(b.text)}]'
	assert b.cursor == 0
}

fn test_kill_word_cjk_stops_at_space() {
	// "你好 世界" — two words separated by a space. kill_word from end
	// drops the trailing word "世界" (6 bytes), stops at the space.
	mut b := new_input_buf()
	b.insert('\xe4\xbd\xa0\xe5\xa5\xbd \xe4\xb8\x96\xe7\x95\x8c')
	b.cursor = b.text.len  // byte 13
	b.kill_word()
	assert b.text == '\xe4\xbd\xa0\xe5\xa5\xbd ', 'got hex=[${hex_of(b.text)}]'
	assert b.cursor == 7
}

fn test_kill_word_emoji_treats_as_single_unit() {
	// "x🎉" — single word. kill_word from end drops the whole thing.
	// Proves the 4-byte emoji is treated as one unit, not 4 separate bytes.
	mut b := new_input_buf()
	b.insert('x' + '\xf0\x9f\x8e\x89')
	assert b.text.len == 5
	b.cursor = b.text.len
	b.kill_word()
	assert b.text == '', 'got hex=[${hex_of(b.text)}]'
	assert b.cursor == 0
}

fn test_kill_word_emoji_does_not_split_codepoint() {
	// Regression: ensure the walk stays on codepoint boundaries even when
	// the previous char was multi-byte. Old impl walked byte-by-byte and
	// could in principle stop inside an emoji; the new impl walks by
	// codepoint so it cannot.
	mut b := new_input_buf()
	// "a🎉b" is a single word (no whitespace), so kill_word from end
	// drops the whole thing — but the key invariant is that the emoji
	// is never split into orphan continuation bytes.
	b.insert('a' + '\xf0\x9f\x8e\x89' + 'b')
	assert b.text.len == 6
	b.cursor = b.text.len
	b.kill_word()
	assert b.text == '', 'got hex=[${hex_of(b.text)}]'
	assert b.cursor == 0
}

fn test_kill_word_at_start_noop() {
	mut b := new_input_buf()
	b.cursor = 0
	b.kill_word()
	assert b.text == ''
	assert b.cursor == 0
}

// ---------- insert + apply round-trip -----------------------------------

fn test_apply_insert_then_backspace_round_trip() {
	// Simulate typing a CJK char via KeyEvent then backspace via KeyEvent.
	mut b := new_input_buf()
	b.apply(KeyEvent{ kind: .char, text: '\xe4\xb8\xad' })
	assert b.text == '\xe4\xb8\xad'
	assert b.cursor == 3
	b.apply(KeyEvent{ kind: .backspace })
	assert b.text == ''
	assert b.cursor == 0
}

// ---------- Ctrl-S / steer (Phase 1.5) -----------------------------------

fn test_ctrl_s_constant_matches_ascii() {
	// ctrl_s must be 0x13 (19) so a raw terminal byte decodes to the
	// right key. If we ever change the wiring (e.g. switch to a CSI
	// sequence), this guard catches it.
	assert ctrl_s == 19
}

fn test_steer_kind_does_not_consume_input() {
	// The .steer key is a SIGNAL, not an edit. It must not modify the
	// input buffer (the actual apppending happens server-side in the
	// TUI's handle_key, not in InputBuf.apply).
	mut b := new_input_buf()
	b.insert('try grep in src/ instead')
	b.apply(KeyEvent{ kind: .steer })
	assert b.text == 'try grep in src/ instead'
	assert b.cursor == b.text.len
}

// ---------- Ctrl-O / collapse tool results --------------------------------

fn test_ctrl_o_constant_matches_ascii() {
	// ctrl_o must be 0x0F (15) so a raw terminal byte decodes to the
	// right key. If we ever change the wiring (e.g. switch to a CSI
	// sequence), this guard catches it — same reasoning as ctrl_s.
	assert ctrl_o == 15
}

fn test_collapse_kind_does_not_consume_input() {
	// The .collapse key is a SIGNAL (handled by handle_key, not by the
	// input buffer). It must not modify the buffer — the input box
	// should stay exactly as the user left it.
	mut b := new_input_buf()
	b.insert('this should not change')
	b.apply(KeyEvent{ kind: .collapse })
	assert b.text == 'this should not change'
	assert b.cursor == b.text.len
}

