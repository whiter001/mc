module main

// goto_file_test.v — coverage for the pure helpers in goto_file.v
// (goto_file_rect, goto_file_list_height, goto_file_entry_text) and
// the state mutators that don't need a Framebuffer draw pass
// (goto_file_clamp_scroll, goto_file_activate, handle_goto_file_key).
//
// Most of these need an Editor + a few documents. We define a
// fresh_editor_with_buffer helper here too (private-fn lookup is
// per-file in V's stable compiler).

fn fresh_editor_with_buffer() Editor {
	mut ed := Editor{ fb: framebuffer_new() }
	ed.size = Size{ width: CoordType(80), height: CoordType(24) }
	ed.add_document('') or { return ed }
	return ed
}

// ---- goto_file_rect / goto_file_list_height ---------------------------

fn test_goto_file_rect_is_centered() {
	// On an 80x24 viewport the rect is width-20=60 wide, height-10=14
	// tall, anchored so it is exactly centered (left=10, top=5).
	ed := fresh_editor_with_buffer()
	r := ed.goto_file_rect()
	assert r.left == 10
	assert r.top == 5
	assert r.right == 70
	assert r.bottom == 19
	assert r.width() == 60
	assert r.height() == 14
}

fn test_goto_file_rect_min_size_enforced_on_large_viewport() {
	// On a viewport where (size - 20) is still >= 10, the minimum
	// 10x10 stands and the rect just sizes to it. (Tested via
	// list_height on the same viewport in the next test.)
	mut ed := fresh_editor_with_buffer()
	ed.size = Size{ width: CoordType(20), height: CoordType(20) }
	r := ed.goto_file_rect()
	assert r.width() == 10
	assert r.height() == 10
}

fn test_goto_file_rect_clamped_to_viewport_when_smaller() {
	// On a viewport smaller than the minimum, the minimum is
	// clamped down to the viewport itself (caller can't get a
	// rect bigger than the screen).
	mut ed := fresh_editor_with_buffer()
	ed.size = Size{ width: CoordType(5), height: CoordType(5) }
	r := ed.goto_file_rect()
	assert r.width() == 5
	assert r.height() == 5
	assert r.right == 5
	assert r.bottom == 5
}

fn test_goto_file_list_height_subtracts_title() {
	// The list gets one less row than the rect height (the title row).
	ed := fresh_editor_with_buffer()
	r := ed.goto_file_rect()
	assert ed.goto_file_list_height() == r.height() - 1
}

// ---- goto_file_entry_text ----------------------------------------------

fn test_goto_file_entry_text_named_clean() {
	// A named, non-dirty document gets "  <path>" (two-space mark).
	mut ed := fresh_editor_with_buffer()
	ed.add_document('/tmp/foo.txt') or { return }
	assert ed.goto_file_entry_text(1) == '  /tmp/foo.txt'
}

fn test_goto_file_entry_text_untitled() {
	// A document with no path is labeled [untitled].
	ed := fresh_editor_with_buffer()
	assert ed.goto_file_entry_text(0) == '  [untitled]'
}

fn test_goto_file_entry_text_dirty_mark() {
	// A dirty document gets a leading "* " mark replacing the first
	// of the two clean-state spaces; the visual alignment with the
	// non-dirty rows is preserved.
	mut ed := fresh_editor_with_buffer()
	ed.docs[0].buf.copy_from_str(StringDocument{ text: 'x' })
	ed.docs[0].buf.mark_as_dirty()
	assert ed.goto_file_entry_text(0) == '* [untitled]'
}

fn test_goto_file_entry_text_out_of_range_returns_empty() {
	ed := fresh_editor_with_buffer()
	// Negative index and past-end both yield ''.
	assert ed.goto_file_entry_text(-1) == ''
	assert ed.goto_file_entry_text(99) == ''
}

// ---- goto_file_clamp_scroll --------------------------------------------

fn test_goto_file_clamp_scroll_keeps_selection_visible_at_top() {
	// When the selection moves above the scroll window, scroll up.
	mut ed := fresh_editor_with_buffer()
	for i in 1 .. 30 {
		ed.add_document('/tmp/x${i}.txt') or { return }
	}
	ed.goto_file_scroll = 10
	ed.goto_file_sel = 5
	ed.goto_file_clamp_scroll()
	assert ed.goto_file_scroll == 5
}

fn test_goto_file_clamp_scroll_keeps_selection_visible_at_bottom() {
	// When the selection moves below the scroll window, scroll down.
	mut ed := fresh_editor_with_buffer()
	for i in 1 .. 30 {
		ed.add_document('/tmp/x${i}.txt') or { return }
	}
	// 80x24 → list_h = 13, so a selection of 25 needs scroll >= 13.
	ed.goto_file_scroll = 0
	ed.goto_file_sel = 25
	ed.goto_file_clamp_scroll()
	assert ed.goto_file_scroll == 25 - 13 + 1
}

// ---- goto_file_activate ------------------------------------------------

fn test_goto_file_activate_switches_active_doc() {
	mut ed := fresh_editor_with_buffer()
	ed.add_document('/tmp/foo.txt') or { return }
	ed.add_document('/tmp/bar.txt') or { return }
	ed.goto_file_sel = 2
	ed.goto_file_activate()
	assert ed.active == 2
	assert ed.goto_file == false
}

fn test_goto_file_activate_out_of_range_is_noop() {
	// Negative or past-end selection must not crash or change state.
	mut ed := fresh_editor_with_buffer()
	ed.goto_file_sel = -1
	ed.goto_file_activate()
	assert ed.active == 0
	assert ed.goto_file == false
	ed.goto_file_sel = 99
	ed.goto_file_activate()
	assert ed.active == 0
	assert ed.goto_file == false
}

// ---- handle_goto_file_key (up / down / home / end / prior / next) ----

fn test_goto_file_key_up_down_moves_selection() {
	mut ed := fresh_editor_with_buffer()
	ed.add_document('/tmp/foo.txt') or { return }
	ed.add_document('/tmp/bar.txt') or { return }
	ed.open_goto_file()
	assert ed.goto_file_sel == 0
	ed.handle_goto_file_key(InputKey(vk_down))
	assert ed.goto_file_sel == 1
	ed.handle_goto_file_key(InputKey(vk_down))
	assert ed.goto_file_sel == 2
	ed.handle_goto_file_key(InputKey(vk_down))
	// Past-end clamp.
	assert ed.goto_file_sel == 2
	ed.handle_goto_file_key(InputKey(vk_up))
	assert ed.goto_file_sel == 1
	ed.handle_goto_file_key(InputKey(vk_up))
	assert ed.goto_file_sel == 0
	ed.handle_goto_file_key(InputKey(vk_up))
	// Below-zero clamp.
	assert ed.goto_file_sel == 0
}

fn test_goto_file_key_home_end_jumps_to_bounds() {
	mut ed := fresh_editor_with_buffer()
	for i in 1 .. 5 {
		ed.add_document('/tmp/x${i}.txt') or { return }
	}
	ed.open_goto_file()
	ed.handle_goto_file_key(InputKey(vk_end))
	assert ed.goto_file_sel == 4
	ed.handle_goto_file_key(InputKey(vk_home))
	assert ed.goto_file_sel == 0
}

fn test_goto_file_key_prior_next_pages() {
	mut ed := fresh_editor_with_buffer()
	for i in 1 .. 30 {
		ed.add_document('/tmp/x${i}.txt') or { return }
	}
	ed.open_goto_file()
	// Page-down from 0 jumps by list_h (80x24 → 13).
	ed.handle_goto_file_key(InputKey(vk_next))
	assert ed.goto_file_sel == 13
	// Page-down again.
	ed.handle_goto_file_key(InputKey(vk_next))
	assert ed.goto_file_sel == 26
	// Past-end clamp.
	ed.handle_goto_file_key(InputKey(vk_next))
	assert ed.goto_file_sel == 29
	// Page-up jumps back by the same step.
	ed.handle_goto_file_key(InputKey(vk_prior))
	assert ed.goto_file_sel == 29 - 13
}

fn test_goto_file_key_return_activates() {
	mut ed := fresh_editor_with_buffer()
	ed.add_document('/tmp/foo.txt') or { return }
	ed.add_document('/tmp/bar.txt') or { return }
	ed.open_goto_file()
	ed.goto_file_sel = 2
	ed.handle_goto_file_key(InputKey(vk_return))
	assert ed.active == 2
	assert ed.goto_file == false
}

fn test_goto_file_key_escape_closes() {
	mut ed := fresh_editor_with_buffer()
	ed.open_goto_file()
	ed.handle_goto_file_key(InputKey(vk_escape))
	assert ed.goto_file == false
}
