module main

// main_test.v — tests for the small set of pure helpers in main.v.
//
// main.v mostly hosts the Editor + its methods (which need a full
// Framebuffer to instantiate), but a couple of byte-count formatters are
// pure. Keeping them here keeps `cpulimit -l 200 -z -- ./build.sh test`
// honest without dragging in the rest of the editor.

// wr writes a string into a buffer. Each _test.v is compiled on its own, so
// the helper in text_buffer_test.v is not visible here.
fn wr(mut b TextBuffer, s string) {
	b.write_raw(s.bytes())
}

fn test_run_prompt_search_sets_search_failed() {
	mut ed := Editor{ fb: framebuffer_new() }
	ed.add_document('') or { panic('add_document: ${err}') }
	wr(mut ed.docs[ed.active].buf, 'hello world')

	// A needle with no match flips the failed flag (drives the red prompt line).
	ed.mode = .prompt
	ed.prompt_kind = .search
	ed.prompt_text = 'zzz'
	ed.run_prompt_search()
	assert ed.search_failed == true

	// A present needle clears the failed flag.
	ed.prompt_text = 'world'
	ed.run_prompt_search()
	assert ed.search_failed == false
}

fn test_start_prompt_prefills_needle_from_selection() {
	mut ed := Editor{ fb: framebuffer_new() }
	ed.add_document('') or { panic('add_document: ${err}') }
	wr(mut ed.docs[ed.active].buf, 'hello world')
	mut b := &ed.docs[ed.active].buf
	// Select 'world' (offset 6..11 on line 0).
	b.set_selection(OptSelection{ valid: true, beg: Point{ x: 6, y: 0 }, end: Point{ x: 11, y: 0 } })

	// Ctrl+F/Ctrl+R with a selection prefills the needle with it.
	ed.start_prompt(.search)
	assert ed.prompt_text == 'world'
	ed.start_prompt(.replace)
	assert ed.prompt_text == 'world'

	// With no selection, the needle falls back to last_search.
	ed.last_search = 'foo'
	b.set_selection(OptSelection{ valid: false })
	ed.start_prompt(.search)
	assert ed.prompt_text == 'foo'
}

fn test_prompt_f3_finds_next_hit() {
	mut ed := Editor{ fb: framebuffer_new() }
	ed.add_document('') or { panic('add_document: ${err}') }
	wr(mut ed.docs[ed.active].buf, 'foo\nbaz foo\nfoo\n')

	ed.start_prompt(.search)
	ed.prompt_text = 'foo'
	ed.run_prompt_search()

	mut b := &ed.docs[ed.active].buf
	assert b.has_selection()
	assert b.selection.beg.y == 0

	// F3 works from inside the prompt, using the needle currently in it
	// (Rust main.rs:410 runs search_execute with state.search_needle).
	ed.handle_prompt_key(InputKey(vk_f3))
	assert b.selection.beg.y == 1
	ed.handle_prompt_key(InputKey(vk_f3))
	assert b.selection.beg.y == 2
	assert ed.search_failed == false
	assert ed.last_search == 'foo'
}

fn test_clipboard_size_label_bytes() {
	// Below 1 KiB is still formatted in KiB with one decimal.
	assert clipboard_size_label(0) == '0 KiB'
	assert clipboard_size_label(512) == '0.5 KiB'
	assert clipboard_size_label(1023) == '0.9 KiB'
}

fn test_clipboard_size_label_kib_exact() {
	// Exact KiB values drop the decimal.
	assert clipboard_size_label(1024) == '1 KiB'
	assert clipboard_size_label(2 * 1024) == '2 KiB'
	assert clipboard_size_label(127 * 1024) == '127 KiB'
}

fn test_clipboard_size_label_kib_decimal() {
	// The function rounds to one decimal place via integer math:
	// dec = (size % 1024) * 10 / 1024. To get dec == 2 we need
	// (size % 1024) in [205, 307] (so 205*10/1024 = 2).
	assert clipboard_size_label(1024 + 256) == '1.2 KiB'
	// For dec == 5: (size % 1024) in [512, 614]. 512*10/1024 = 5.
	assert clipboard_size_label(1024 + 512) == '1.5 KiB'
	// 100 KiB + 512 bytes → kib=100, dec=512*10/1024=5 → "100.5 KiB".
	assert clipboard_size_label(100 * 1024 + 512) == '100.5 KiB'
}

fn test_clipboard_size_label_mib_exact() {
	// Exact MiB values drop the decimal.
	assert clipboard_size_label(1024 * 1024) == '1 MiB'
	assert clipboard_size_label(2 * 1024 * 1024) == '2 MiB'
	assert clipboard_size_label(8 * 1024 * 1024) == '8 MiB'
}

fn test_clipboard_size_label_mib_decimal() {
	// 1.5 MiB: mib=1, dec = 512*1024*10 / (1024*1024) = 5 → "1.5 MiB".
	assert clipboard_size_label(1024 * 1024 + 512 * 1024) == '1.5 MiB'
	// 2.3 MiB: mib=2, dec = 314573 * 10 / 1048576 = 3 (3145730/1048576=3).
	assert clipboard_size_label(2 * 1024 * 1024 + 314573) == '2.3 MiB'
}

fn test_prompt_prev_codepoint_ascii() {
	assert prompt_prev_codepoint('abc', 0) == 0
	assert prompt_prev_codepoint('abc', 1) == 0
	assert prompt_prev_codepoint('abc', 2) == 1
	assert prompt_prev_codepoint('abc', 3) == 2
	// Off past the end clamps to len.
	assert prompt_prev_codepoint('abc', 99) == 2
}

fn test_prompt_prev_codepoint_utf8() {
	// '漢' is 3 bytes; '𝄞' is 4 bytes.
	s := 'a漢𝄞b'
	// s = 'a' (1) + '漢' (3) + '𝄞' (4) + 'b' (1) = 9 bytes.
	assert s.len == 9
	// Walking back from each byte boundary lands on the previous codepoint.
	assert prompt_prev_codepoint(s, 1) == 0
	assert prompt_prev_codepoint(s, 4) == 1
	assert prompt_prev_codepoint(s, 8) == 4
	assert prompt_prev_codepoint(s, 9) == 8
	// Walking back from a continuation byte lands on the lead byte.
	assert prompt_prev_codepoint(s, 2) == 1
	assert prompt_prev_codepoint(s, 3) == 1
}

fn test_prompt_next_codepoint_utf8() {
	s := 'a漢𝄞b'
	// From each lead byte, advance to the next codepoint's lead.
	assert prompt_next_codepoint(s, 0) == 1
	assert prompt_next_codepoint(s, 1) == 4
	assert prompt_next_codepoint(s, 4) == 8
	// Past end clamps to len (9).
	assert prompt_next_codepoint(s, 99) == 9
	// Negative offsets clamp to 0.
	assert prompt_next_codepoint(s, -5) == 0
}

fn test_prompt_effective_cursor_clamps() {
	mut ed := Editor{ fb: framebuffer_new() }
	ed.prompt_text = 'foo'
	// The default (-1) and any out-of-range offset both become len().
	assert ed.prompt_effective_cursor() == 3
	ed.prompt_cursor = 2
	assert ed.prompt_effective_cursor() == 2
	ed.prompt_cursor = 99
	assert ed.prompt_effective_cursor() == 3
	ed.prompt_cursor = -10
	assert ed.prompt_effective_cursor() == 3
}

fn test_prompt_insert_at_cursor() {
	mut ed := Editor{ fb: framebuffer_new() }
	ed.prompt_text = 'helloworld'
	ed.prompt_cursor = 5 // between 'hello' and 'world'
	ed.prompt_insert(' ')
	assert ed.prompt_text == 'hello world'
	assert ed.prompt_cursor == 6

	// Inserting again at the new cursor.
	ed.prompt_insert('!')
	assert ed.prompt_text == 'hello !world'
	assert ed.prompt_cursor == 7
}

fn test_prompt_backspace_respects_cursor() {
	mut ed := Editor{ fb: framebuffer_new() }
	ed.prompt_text = 'hello'
	ed.prompt_cursor = 5
	ed.prompt_backspace()
	assert ed.prompt_text == 'hell'
	assert ed.prompt_cursor == 4

	// Cursor at 0 is a no-op.
	ed.prompt_cursor = 0
	ed.prompt_backspace()
	assert ed.prompt_text == 'hell'
	assert ed.prompt_cursor == 0
}

fn test_prompt_delete_removes_forward_codepoint() {
	mut ed := Editor{ fb: framebuffer_new() }
	ed.prompt_text = 'a漢b'
	ed.prompt_cursor = 1 // before '漢'
	ed.prompt_delete()
	assert ed.prompt_text == 'ab'
	assert ed.prompt_cursor == 1

	// Deleting past the end is a no-op.
	ed.prompt_text = 'ab'
	ed.prompt_cursor = 2
	ed.prompt_delete()
	assert ed.prompt_text == 'ab'
}

fn test_prompt_kill_to_end() {
	mut ed := Editor{ fb: framebuffer_new() }
	ed.prompt_text = 'abcdef'
	ed.prompt_cursor = 2
	ed.prompt_kill_to_end()
	assert ed.prompt_text == 'ab'
	assert ed.prompt_cursor == 2

	// Cursor at end is a no-op.
	ed.prompt_text = 'ab'
	ed.prompt_cursor = 2
	ed.prompt_kill_to_end()
	assert ed.prompt_text == 'ab'
}

fn test_prompt_kill_line() {
	mut ed := Editor{ fb: framebuffer_new() }
	ed.prompt_text = 'abc'
	ed.prompt_cursor = 1
	ed.prompt_kill_line()
	assert ed.prompt_text == ''
	assert ed.prompt_cursor == 0
}

fn test_prompt_move_home_end_left_right() {
	mut ed := Editor{ fb: framebuffer_new() }
	ed.prompt_text = 'a漢b' // bytes: a=1 漢=3 b=1 → len 5
	ed.prompt_cursor = 5
	ed.prompt_move_home()
	assert ed.prompt_cursor == 0
	ed.prompt_move_end()
	assert ed.prompt_cursor == 5
	ed.prompt_move_left()
	assert ed.prompt_cursor == 4 // back over 'b'
	ed.prompt_move_left()
	assert ed.prompt_cursor == 1 // back over '漢' (3 bytes)
	ed.prompt_move_right()
	assert ed.prompt_cursor == 4 // forward over '漢'
}

fn test_handle_prompt_key_arrow_home_end_delete() {
	mut ed := Editor{ fb: framebuffer_new() }
	ed.add_document('') or { panic('add_document: ${err}') }
	wr(mut ed.docs[ed.active].buf, 'foo')
	ed.start_prompt(.search)
	ed.prompt_text = 'hello'
	ed.prompt_cursor = ed.prompt_text.len // cursor at end

	// ← moves one codepoint back.
	ed.handle_prompt_key(InputKey(vk_left))
	assert ed.prompt_cursor == 4
	// Home jumps to 0.
	ed.handle_prompt_key(InputKey(vk_home))
	assert ed.prompt_cursor == 0
	// End jumps to len.
	ed.handle_prompt_key(InputKey(vk_end))
	assert ed.prompt_cursor == 5
	// Delete removes the codepoint at the cursor (now end → no-op).
	ed.handle_prompt_key(InputKey(vk_delete))
	assert ed.prompt_text == 'hello'
	// Move back one and delete forward.
	ed.handle_prompt_key(InputKey(vk_left))
	ed.handle_prompt_key(InputKey(vk_delete))
	assert ed.prompt_text == 'hell'
	assert ed.prompt_cursor == 4
}

fn test_handle_prompt_key_ctrl_a_k_u() {
	mut ed := Editor{ fb: framebuffer_new() }
	ed.add_document('') or { panic('add_document: ${err}') }
	ed.start_prompt(.search)
	ed.prompt_text = 'abcdef'
	ed.prompt_cursor = 3

	// Ctrl+K kills from cursor to end.
	ed.handle_prompt_key(InputKey(vk_k | kbmod_ctrl))
	assert ed.prompt_text == 'abc'
	assert ed.prompt_cursor == 3

	// Ctrl+U kills the whole line regardless of cursor.
	ed.prompt_cursor = 1
	ed.handle_prompt_key(InputKey(vk_u | kbmod_ctrl))
	assert ed.prompt_text == ''
	assert ed.prompt_cursor == 0

	// Ctrl+A moves to start (no in-prompt selection model yet).
	ed.prompt_text = 'xyz'
	ed.prompt_cursor = 2
	ed.handle_prompt_key(InputKey(vk_a | kbmod_ctrl))
	assert ed.prompt_cursor == 0
}
