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

import os

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

// ---------- Ctrl-X / clear_attachments (P0.7) ----------------------------

fn test_ctrl_x_constant_matches_ascii() {
	// ctrl_x must be 0x18 (24) so a raw terminal byte decodes to the
	// right key. Same guard pattern as ctrl_s / ctrl_o.
	assert ctrl_x == 24
}

fn test_clear_attachments_kind_does_not_consume_input() {
	// .clear_attachments is a SIGNAL: handle_key owns the logic. The
	// input buffer must not react (no text change, no cursor move) so
	// the user's draft is preserved across a Ctrl-X press.
	mut b := new_input_buf()
	b.insert('keep this')
	b.apply(KeyEvent{ kind: .clear_attachments })
	assert b.text == 'keep this'
	assert b.cursor == b.text.len
}

fn test_attach_file_success_reads_and_encodes() {
	// Write a small temp file, attach it, verify the resulting
	// attachment has the right mime / non-empty b64 / right name.
	tmp := os.join_path(os.temp_dir(), 'kimi-v-attach-test.png')
	// PNG magic bytes + 16 bytes of fake payload.
	payload := [u8(0x89), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00,
		0x00, 0x0D, 0x49, 0x48, 0x44, 0x52]
	os.write_file(tmp, payload.bytestr())!
	mut b := new_input_buf()
	ok := b.attach_file('/tmp', tmp, 'gpt-4o')
	assert ok == true, 'attach_file should succeed for a valid png'
	assert b.attachments.len == 1
	att := b.attachments[0]
	assert att.mime == 'image/png'
	assert att.b64.len > 0
	assert att.name == 'kimi-v-attach-test.png'
	os.rm(tmp) or {}
}

fn test_attach_file_missing_path_returns_false() {
	// Path that doesn't exist → false, no attachment added.
	mut b := new_input_buf()
	ok := b.attach_file('/tmp', '/this/path/should/not/exist/foo.png', 'gpt-4o')
	assert ok == false
	assert b.attachments.len == 0
}

fn test_attach_file_wrong_extension_returns_false() {
	// .txt is not in the recognized image set — should be rejected
	// even if the file exists and is small.
	tmp := os.join_path(os.temp_dir(), 'kimi-v-attach-test.txt')
	os.write_file(tmp, 'hello')!
	mut b := new_input_buf()
	ok := b.attach_file('/tmp', tmp, 'gpt-4o')
	assert ok == false
	assert b.attachments.len == 0
	os.rm(tmp) or {}
}

fn test_attach_data_url_valid_png() {
	// data:image/png;base64,AAAA — well-formed URL, payload is "AAAA"
	// which decodes to bytes 0x00 0x00 0x00 (3 bytes of zero). We just
	// check the helper extracts mime + payload correctly.
	mut b := new_input_buf()
	ok := b.attach_data_url('data:image/png;base64,AAAA', 'gpt-4o')
	assert ok == true
	assert b.attachments.len == 1
	att := b.attachments[0]
	assert att.mime == 'image/png'
	assert att.b64 == 'AAAA'
	assert att.name == 'pasted.png'
}

fn test_attach_data_url_invalid_prefix_returns_false() {
	// data:video/mp4;... — only image/* is supported. The TUI rejects
	// other mimes so we don't accidentally send non-image blobs to
	// vision endpoints.
	mut b := new_input_buf()
	ok := b.attach_data_url('data:video/mp4;base64,AAAA', 'gpt-4o')
	assert ok == false
	assert b.attachments.len == 0
}

fn test_attach_data_url_non_base64_returns_false() {
	// data:image/png;charset=utf-8,... — non-base64 payloads aren't
	// supported in v1. The user can decode and re-paste.
	mut b := new_input_buf()
	ok := b.attach_data_url('data:image/png,hello', 'gpt-4o')
	assert ok == false
}

fn test_clear_attachments_returns_count_and_empties() {
	// After attaching two things, clear_attachments() should return
	// 2 and leave the slice empty. Used by handle_key to surface a
	// status hint with the right pluralization.
	mut b := new_input_buf()
	b.attachments << Attachment{ mime: 'image/png', b64: 'aaa', name: 'a.png' }
	b.attachments << Attachment{ mime: 'image/jpeg', b64: 'bbb', name: 'b.jpg' }
	assert b.has_attachments() == true
	n := b.clear_attachments()
	assert n == 2
	assert b.attachments.len == 0
	assert b.has_attachments() == false
}

fn test_looks_like_attach_candidate_short_text_rejected() {
	// Single char or 3-char typing noise should not be treated as an
	// attach candidate — otherwise "ls " or "1+1" would trigger the
	// path resolver.
	assert looks_like_attach_candidate('a') == false
	assert looks_like_attach_candidate('ab') == false
	assert looks_like_attach_candidate('abc') == false
}

fn test_looks_like_attach_candidate_with_whitespace_rejected() {
	// Real paste of natural language always contains spaces; the
	// filter rejects anything with whitespace so the attach path
	// only runs on token-shaped input.
	assert looks_like_attach_candidate('look at this.png') == false
	assert looks_like_attach_candidate('hi there') == false
}

fn test_looks_like_attach_candidate_absolute_path_accepted() {
	// "/foo/bar.png" is a candidate (will be rejected later by
	// attach_file if the file doesn't exist, but the filter passes
	// it through).
	assert looks_like_attach_candidate('/foo/bar.png') == true
	assert looks_like_attach_candidate('~/Pictures/shot.png') == true
	assert looks_like_attach_candidate('./shot.png') == true
	assert looks_like_attach_candidate('../shot.png') == true
}

fn test_looks_like_attach_candidate_data_url_accepted() {
	// data: URLs always pass the filter (the attach_data_url
	// helper handles the heavy lifting).
	assert looks_like_attach_candidate('data:image/png;base64,AAAA') == true
}

fn test_looks_like_attach_candidate_bare_filename_rejected() {
	// "screenshot.png" (no path prefix) is intentionally NOT a
	// candidate — we don't want typing a filename to trigger an
	// attach. The user must include a path prefix to disambiguate
	// "I just typed the name" from "I pasted a path".
	assert looks_like_attach_candidate('screenshot.png') == false
	assert looks_like_attach_candidate('foo.jpg') == false
}

