module main

// Tests for error_log and terminal title state management.

// Helper that creates an Editor with one untitled, non-dirty document.
fn fresh_editor_with_buffer() Editor {
	mut ed := Editor{ fb: framebuffer_new() }
	ed.size = Size{ width: CoordType(80), height: CoordType(24) }
	ed.add_document('') or { return ed }
	return ed
}

// ---- Dirty modal ----------------------------------------------------------------

fn test_dirty_modal_cancel_leaves_buffer_alone() {
	mut ed := fresh_editor_with_buffer()
	ed.docs[ed.active].buf.write_canon([u8(`x`)])
	ed.docs[ed.active].buf.mark_as_dirty()
	assert ed.docs[ed.active].buf.is_dirty()
	assert ed.docs.len == 1

	ed.close_active()
	assert ed.dirty_modal == true
	assert ed.dirty_action == 2 // Cancel is default

	ed.resolve_dirty_modal()

	// Document must still be open and dirty.
	assert ed.dirty_modal == false
	assert ed.docs.len == 1
	assert ed.docs[ed.active].buf.is_dirty()
}

fn test_dirty_modal_discard_closes_document() {
	mut ed := fresh_editor_with_buffer()
	ed.docs[ed.active].buf.write_canon([u8(`x`)])
	ed.docs[ed.active].buf.mark_as_dirty()
	assert ed.docs.len == 1

	ed.close_active()
	assert ed.dirty_modal == true
	ed.dirty_action = 1 // Discard

	ed.resolve_dirty_modal()

	assert ed.dirty_modal == false
	assert ed.docs.len == 0
	assert ed.quit == true
}

fn test_dirty_modal_save_routes_through_save_active() {
	mut ed := fresh_editor_with_buffer()
	ed.docs[ed.active].buf.write_canon([u8(`x`)])
	ed.docs[ed.active].buf.mark_as_dirty()
	// Untitled doc: save_active() opens the picker.
	assert ed.docs[ed.active].path == ''

	ed.close_active()
	assert ed.dirty_modal == true
	ed.dirty_action = 0 // Save

	ed.resolve_dirty_modal()

	// Untitled buffer + Save → picker opens.
	assert ed.dirty_modal == false
	assert ed.picker == true
	assert ed.picker_save_as == true
}

fn test_dirty_modal_quit_does_not_close_when_canceled() {
	mut ed := fresh_editor_with_buffer()
	ed.docs[ed.active].buf.write_canon([u8(`x`)])
	ed.docs[ed.active].buf.mark_as_dirty()

	ed.request_exit()
	assert ed.dirty_modal == true
	assert ed.dirty_for_quit == true
	assert ed.dirty_action == 2

	ed.resolve_dirty_modal()

	assert ed.dirty_modal == false
	assert ed.quit == false
	assert ed.docs.len == 1
}

fn test_dirty_modal_quit_with_discard_sets_quit() {
	mut ed := fresh_editor_with_buffer()
	ed.docs[ed.active].buf.write_canon([u8(`x`)])
	ed.docs[ed.active].buf.mark_as_dirty()

	ed.request_exit()
	assert ed.dirty_modal == true
	assert ed.dirty_for_quit == true
	ed.dirty_action = 1 // Discard

	ed.resolve_dirty_modal()

	assert ed.dirty_modal == false
	assert ed.quit == true
}

// ---- Error log ----------------------------------------------------------------

fn test_error_log_add_records_in_order() {
	mut ed := Editor{
		fb: framebuffer_new()
	}
	ed.error_log_add('first error')
	ed.error_log_add('second error')
	ed.error_log_add('third error')

	assert ed.error_log_count == 3
	assert ed.error_log_open == true

	// Verify order: messages should be readable oldest-to-newest.
	// The ring buffer stores newest at error_log_index, oldest before it.
	beg := (ed.error_log_index + error_log_capacity - ed.error_log_count) % error_log_capacity
	assert ed.error_log[(beg + 0) % error_log_capacity] == 'first error'
	assert ed.error_log[(beg + 1) % error_log_capacity] == 'second error'
	assert ed.error_log[(beg + 2) % error_log_capacity] == 'third error'
}

fn test_error_log_add_wraps_at_capacity() {
	mut ed := Editor{
		fb: framebuffer_new()
	}
	// Fill beyond capacity.
	for i in 0 .. error_log_capacity + 3 {
		ed.error_log_add('msg ${i}')
	}
	assert ed.error_log_count == error_log_capacity
	assert ed.error_log_open == true

	// The newest 8 messages should be present; the oldest 3 should be gone.
	beg := (ed.error_log_index + error_log_capacity - ed.error_log_count) % error_log_capacity
	for i in 0 .. error_log_capacity {
		idx := (beg + i) % error_log_capacity
		assert ed.error_log[idx] == 'msg ${i + 3}'
	}
}

fn test_error_log_add_ignores_empty_message() {
	mut ed := Editor{
		fb: framebuffer_new()
	}
	ed.error_log_add('')
	assert ed.error_log_count == 0
	assert ed.error_log_open == false

	ed.error_log_add('real error')
	assert ed.error_log_count == 1
	assert ed.error_log_open == true
}

fn test_error_log_close_does_not_drop_entries() {
	mut ed := Editor{
		fb: framebuffer_new()
	}
	ed.error_log_add('error one')
	ed.error_log_add('error two')
	assert ed.error_log_count == 2
	assert ed.error_log_open == true

	ed.error_log_close()
	assert ed.error_log_count == 2
	assert ed.error_log_open == false

	// After close the entries are still in the buffer; re-opening shows them.
	ed.error_log_open = true
	assert ed.error_log_count == 2
	beg := (ed.error_log_index + error_log_capacity - ed.error_log_count) % error_log_capacity
	assert ed.error_log[(beg + 0) % error_log_capacity] == 'error one'
	assert ed.error_log[(beg + 1) % error_log_capacity] == 'error two'
}
