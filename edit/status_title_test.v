module main

// Tests for error_log and terminal title state management.

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
