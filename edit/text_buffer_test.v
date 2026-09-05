module main

import os

// These tests port the behavioral coverage from crates/edit/src/buffer/mod.rs
// (microsoft/edit) to the V rewrite. They focus on the first-version scope:
// UTF-8 text, no lsh highlighting, substring search, 64KiB-chunked file I/O.

fn buf_text(mut b TextBuffer) string {
	mut sd := StringDocument{ text: '' }
	b.save_as_string(mut sd)
	return sd.text
}

fn has_no_selection(b &TextBuffer) bool {
	return !b.has_selection()
}

// wr / wcn are thin wrappers that convert a string literal into the []u8
// that write_raw / write_canon expect.
fn wr(mut b TextBuffer, s string) {
	b.write_raw(s.bytes())
}

fn wcn(mut b TextBuffer, s string) {
	b.write_canon(s.bytes())
}

// ---------------------------------------------------------------------------
// Construction & basic accessors
// ---------------------------------------------------------------------------

fn test_new_buffer() {
	mut b := new_text_buffer(false)
	assert b.text_length() == 0
	assert b.logical_line_count() == 1
	assert b.visual_line_count() == 1
	assert b.is_dirty() == false
	assert b.encoding() == 'UTF-8'
	assert b.is_crlf() == false
	assert b.tab_size() == 4
	assert b.cursor_logical_pos().x == 0
	assert b.cursor_logical_pos().y == 0
}

// ---------------------------------------------------------------------------
// Insert + cursor movement (logical & visual)
// ---------------------------------------------------------------------------

fn test_insert_and_cursor() {
	mut b := new_text_buffer(false)
	wr(mut b, 'hello')
	assert b.text_length() == 5
	assert b.cursor_logical_pos().x == 5
	assert b.cursor_logical_pos().y == 0
	assert b.cursor_visual_pos().x == 5
	assert b.cursor_visual_pos().y == 0

	wr(mut b, '\nworld')
	// contents: "hello\nworld", cursor at end of line 1.
	assert buf_text(mut b) == 'hello\nworld'
	assert b.logical_line_count() == 2
	assert b.cursor_logical_pos().x == 5
	assert b.cursor_logical_pos().y == 1
}

fn test_cursor_move_logical_visual() {
	mut b := new_text_buffer(false)
	wr(mut b, 'line0\nline1\nline2')
	// Cursor starts at the end: logical (5, 2).
	assert b.cursor_logical_pos().y == 2

	b.cursor_move_to_logical(Point{ x: 2, y: 1 })
	assert b.cursor_logical_pos().x == 2
	assert b.cursor_logical_pos().y == 1
	assert b.cursor_visual_pos().y == 1

	// Moving to an offset updates both positions.
	b.cursor_move_to_offset(0)
	assert b.cursor_logical_pos().x == 0
	assert b.cursor_logical_pos().y == 0
}

fn test_cursor_move_delta_grapheme() {
	mut b := new_text_buffer(false)
	wr(mut b, 'abc')
	b.cursor_move_to_offset(0)
	b.cursor_move_delta(CursorMovement.grapheme, 2)
	assert b.cursor_logical_pos().x == 2
	b.cursor_move_delta(CursorMovement.grapheme, -1)
	assert b.cursor_logical_pos().x == 1
}

fn test_cursor_move_delta_word() {
	mut b := new_text_buffer(false)
	wr(mut b, 'hello world foo')
	b.cursor_move_to_logical(Point{ x: 0, y: 0 })
	b.cursor_move_delta(CursorMovement.word, 1)
	// After skipping "hello" we stop at the space before "world".
	assert b.cursor.offset == 5
	b.cursor_move_delta(CursorMovement.word, 1)
	assert b.cursor.offset == 11
}

// ---------------------------------------------------------------------------
// write_raw / write_canon newline normalization
// ---------------------------------------------------------------------------

fn test_write_canon_normalizes_crlf_to_lf() {
	mut b := new_text_buffer(false)
	b.set_crlf(false)
	// CRLF input gets normalized to the buffer's LF style.
	wcn(mut b, 'a\r\nb\r\nc')
	assert buf_text(mut b) == 'a\nb\nc'
	assert b.logical_line_count() == 3
}

fn test_write_raw_normalizes_lf_to_crlf() {
	mut b := new_text_buffer(false)
	b.set_crlf(true)
	wr(mut b, 'a\nb\nc')
	assert buf_text(mut b) == 'a\r\nb\r\nc'
	assert b.is_crlf() == true
}

// ---------------------------------------------------------------------------
// Delete & replace
// ---------------------------------------------------------------------------

fn test_delete_single_grapheme() {
	mut b := new_text_buffer(false)
	wr(mut b, 'hello')
	b.cursor_move_to_offset(5)
	b.delete(CursorMovement.grapheme, -1)
	assert buf_text(mut b) == 'hell'
}

fn test_delete_forward() {
	mut b := new_text_buffer(false)
	wr(mut b, 'hello')
	b.cursor_move_to_offset(0)
	b.delete(CursorMovement.grapheme, 1)
	assert buf_text(mut b) == 'ello'
}

fn test_replace_via_selection() {
	mut b := new_text_buffer(false)
	wr(mut b, 'hello world')
	b.cursor_move_to_logical(Point{ x: 0, y: 0 })
	b.start_selection()
	b.selection_update_delta(CursorMovement.grapheme, 5) // selects "hello"
	assert b.has_selection()
	wr(mut b, 'HI')
	assert buf_text(mut b) == 'HI world'
}

// ---------------------------------------------------------------------------
// Undo / redo round trip
// ---------------------------------------------------------------------------

fn test_undo_redo() {
	mut b := new_text_buffer(false)
	wr(mut b, 'hello')
	assert buf_text(mut b) == 'hello'

	b.undo()
	assert buf_text(mut b) == ''

	b.redo()
	assert buf_text(mut b) == 'hello'
}

fn test_undo_redo_multiple_edits_grouped() {
	mut b := new_text_buffer(false)
	wr(mut b, 'a')
	wr(mut b, 'b')
	wr(mut b, 'c')
	assert buf_text(mut b) == 'abc'

	// One undo per contiguous write (same HistoryType), so a single undo
	// removes the last contiguous run.
	b.undo()
	assert buf_text(mut b) == 'ab'
	b.undo()
	assert buf_text(mut b) == 'a'
	b.undo()
	assert buf_text(mut b) == ''

	b.redo()
	b.redo()
	b.redo()
	assert buf_text(mut b) == 'abc'
}

// ---------------------------------------------------------------------------
// Selection & extract_user_selection
// ---------------------------------------------------------------------------

fn test_selection_and_extract_user_selection() {
	mut b := new_text_buffer(false)
	wr(mut b, 'hello world')
	b.cursor_move_to_logical(Point{ x: 0, y: 0 })
	b.start_selection()
	b.selection_update_delta(CursorMovement.grapheme, 5) // selects "hello"

	// Without delete: returns the selected text, buffer unchanged.
	sel := b.extract_user_selection(false) or { panic('expected a user selection') }
	assert sel.bytestr() == 'hello'
	assert buf_text(mut b) == 'hello world'
	assert b.has_selection()

	// With delete: returns the selected text and removes it.
	sel2 := b.extract_user_selection(true) or { panic('expected a user selection') }
	assert sel2.bytestr() == 'hello'
	assert buf_text(mut b) == ' world'

	// No selection anymore: extract returns none.
	assert has_no_selection(b)
	if _ := b.extract_user_selection(false) {
		panic('expected none without selection')
	}
}

fn test_clear_selection() {
	mut b := new_text_buffer(false)
	wr(mut b, 'abc')
	b.cursor_move_to_logical(Point{ x: 0, y: 0 })
	b.start_selection()
	b.selection_update_delta(CursorMovement.grapheme, 2)
	assert b.has_selection()
	b.clear_selection()
	assert !b.has_selection()
}

// ---------------------------------------------------------------------------
// indent_change
// ---------------------------------------------------------------------------

fn test_indent_change_indent_line() {
	mut b := new_text_buffer(false)
	wr(mut b, 'a\nb\nc')
	b.cursor_move_to_logical(Point{ x: 0, y: 1 }) // line "b"
	b.indent_change(1)
	// No selection + indent => insert a tab, expanded to `tab_size` spaces.
	assert buf_text(mut b) == 'a\n    b\nc'
}

fn test_indent_change_unindent_line() {
	mut b := new_text_buffer(false)
	wr(mut b, 'a\n    b\nc')
	b.cursor_move_to_logical(Point{ x: 0, y: 1 }) // line "    b"
	b.indent_change(-1)
	assert buf_text(mut b) == 'a\nb\nc'
}

// ---------------------------------------------------------------------------
// move_selected_lines
// ---------------------------------------------------------------------------

fn test_move_selected_lines_down() {
	mut b := new_text_buffer(false)
	wr(mut b, 'a\nb\nc')
	b.cursor_move_to_logical(Point{ x: 0, y: 0 }) // "a"
	b.move_selected_lines(MoveLineDirection.down)
	assert buf_text(mut b) == 'b\na\nc'
}

fn test_move_selected_lines_up() {
	mut b := new_text_buffer(false)
	wr(mut b, 'a\nb\nc')
	b.cursor_move_to_logical(Point{ x: 0, y: 2 }) // "c"
	b.move_selected_lines(MoveLineDirection.up)
	// Moving the last line up leaves a trailing newline: the paste target
	// line does not exist, so the Rust original (buffer/mod.rs
	// move_selected_lines) first writes '\n' and then the cut line which
	// itself still ends in '\n'. This mirrors that behavior exactly.
	assert buf_text(mut b) == 'a\nc\nb\n'
}

// ---------------------------------------------------------------------------
// normalize_newlines
// ---------------------------------------------------------------------------

fn test_normalize_newlines_lf_to_crlf() {
	mut b := new_text_buffer(false)
	wr(mut b, 'a\nb\nc')
	b.normalize_newlines(true)
	assert b.is_crlf() == true
	assert buf_text(mut b) == 'a\r\nb\r\nc'
}

fn test_normalize_newlines_crlf_to_lf() {
	mut b := new_text_buffer(false)
	b.set_crlf(true)
	wr(mut b, 'a\r\nb\r\nc')
	b.normalize_newlines(false)
	assert b.is_crlf() == false
	assert buf_text(mut b) == 'a\nb\nc'
}

// ---------------------------------------------------------------------------
// find_and_select / find_and_replace(_all) — substring semantics
// ---------------------------------------------------------------------------

fn test_find_and_select_next() {
	mut b := new_text_buffer(false)
	wr(mut b, 'hello world hello')
	b.find_and_select('hello', SearchOptions{})
	mut ok, mut beg, mut end := b.selection_range()
	assert ok
	assert beg.offset == 0
	assert end.offset == 5

	// Second call finds the next occurrence.
	b.find_and_select('hello', SearchOptions{})
	ok, beg, end = b.selection_range()
	assert ok
	assert beg.offset == 12
	assert end.offset == 17
}

fn test_find_and_select_case_insensitive() {
	mut b := new_text_buffer(false)
	wr(mut b, 'Hello World')
	b.find_and_select('hello', SearchOptions{ match_case: false })
	mut ok, mut beg, mut end := b.selection_range()
	assert ok
	assert beg.offset == 0
	assert end.offset == 5
}

fn test_find_and_select_case_sensitive() {
	mut b := new_text_buffer(false)
	wr(mut b, 'Hello World')
	// Case-sensitive: "hello" (lowercase) is not in "Hello".
	b.find_and_select('hello', SearchOptions{ match_case: true })
	// No selection should be set (find failed).
	assert !b.has_selection()
}

fn test_find_and_replace_all() {
	mut b := new_text_buffer(false)
	wr(mut b, 'aXbXcXd')
	b.find_and_replace_all('X', SearchOptions{}, '-'.bytes())
	assert buf_text(mut b) == 'a-b-c-d'
}

fn test_find_whole_word() {
	mut b := new_text_buffer(false)
	wr(mut b, 'cat concatenate scatter')
	// "cat" as a whole word should only match the first token.
	b.find_and_select('cat', SearchOptions{ whole_word: true })
	mut ok, mut beg, mut end := b.selection_range()
	assert ok
	assert beg.offset == 0
	assert end.offset == 3
}

// ---------------------------------------------------------------------------
// read_file / write_file round trip on a temp file
// ---------------------------------------------------------------------------

fn test_read_write_file_roundtrip() {
	path := os.join_path(os.temp_dir(), 'edit_v_test_roundtrip.txt')
	os.rm(path) or {}
	defer { os.rm(path) or {} }

	os.write_file(path, 'hello\nworld\n') or { panic('setup write failed: ${err}') }

	mut b := new_text_buffer(false)
	b.read_file(path) or { assert false, 'read_file: ${err}' }
	assert buf_text(mut b) == 'hello\nworld\n'
	// The trailing '\n' implies a third, empty last line (Rust: lines + 1).
	assert b.logical_line_count() == 3

	// Modify, save back, and re-read.
	b.cursor_move_to_logical(Point{ x: coord_type_max, y: 0 })
	wcn(mut b, '!')
	b.write_file(path) or { assert false, 'write_file: ${err}' }

	mut b2 := new_text_buffer(false)
	b2.read_file(path) or { assert false, 're-read_file: ${err}' }
	assert buf_text(mut b2) == 'hello!\nworld\n'
}

fn test_read_file_empty() {
	path := os.join_path(os.temp_dir(), 'edit_v_test_empty.txt')
	os.rm(path) or {}
	defer { os.rm(path) or {} }

	os.write_file(path, '') or { panic('setup write failed: ${err}') }

	mut b := new_text_buffer(false)
	b.read_file(path) or { assert false, 'read_file: ${err}' }
	assert buf_text(mut b) == ''
}

// ---------------------------------------------------------------------------
// render into a Framebuffer
// ---------------------------------------------------------------------------

fn render_frame(mut b TextBuffer, width CoordType, height CoordType) string {
	mut fb := framebuffer_new()
	size := Size{ width: width, height: height }
	fb.flip(size)
	b.render(Point{ x: 0, y: 0 }, size.as_rect(), true, mut fb) or { RenderResult{} }
	return fb.render()
}

fn test_render_separates_lines() {
	mut b := new_text_buffer(false)
	wr(mut b, 'line1\nline2\n')
	b.set_margin_enabled(true)
	frame := render_frame(mut b, 20, 5)
	// The newline must never leak into the rendered row (U+258A is the
	// framebuffer's visualization of a raw '\n' control character).
	assert !frame.contains('\u258a')
	assert frame.contains('line1')
	assert frame.contains('line2')
}

fn test_render_margin_line_numbers() {
	mut b := new_text_buffer(false)
	wr(mut b, 'a\nb\nc')
	b.set_margin_enabled(true)
	frame := render_frame(mut b, 20, 5)
	// The margin shows right-aligned line numbers plus the " │ " separator.
	assert frame.contains('1 │ ')
	assert frame.contains('2 │ ')
	assert frame.contains('3 │ ')
}

fn test_copy_from_str_multiline() {
	mut b := new_text_buffer(false)
	b.copy_from_str(StringDocument{
		text: 'Hello from redirected stdin\nLine 2\nLine 3\n'
	})
	assert b.logical_line_count() == 4
	assert buf_text(mut b) == 'Hello from redirected stdin\nLine 2\nLine 3\n'
	b.copy_from_str(StringDocument{ text: 'single' })
	assert b.logical_line_count() == 1
	assert buf_text(mut b) == 'single'
}
