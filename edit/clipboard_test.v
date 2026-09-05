module main

// clipboard_test.v — coverage for the editor-internal Clipboard
// struct in clipboard.v. The struct is pure in-memory state, so we
// can construct it directly and exercise every mutator / accessor.

fn fresh_clipboard() Clipboard {
	return Clipboard{}
}

fn test_clipboard_starts_empty_and_unsynced() {
	c := fresh_clipboard()
	assert c.data.len == 0
	assert c.line_copy == false
	assert c.wants_host_sync == false
	assert c.large_always_send == false
	assert c.large_pending == false
	// Accessors reflect the same state.
	assert c.is_line_copy() == false
	assert c.wants_host_sync() == false
	assert c.clipboard_size() == 0
	assert c.read().len == 0
	assert c.clipboard_wants_warning() == false
}

fn test_clipboard_write_marks_for_host_sync() {
	mut c := fresh_clipboard()
	c.write('hello'.bytes())
	assert c.data == 'hello'.bytes()
	assert c.wants_host_sync == true
	// A regular write is not a line copy.
	assert c.line_copy == false
	assert c.is_line_copy() == false
	assert c.wants_host_sync() == true
	assert c.clipboard_size() == 5
}

fn test_clipboard_write_empty_does_not_set_sync() {
	// The write() mutator skips empty payloads — the editor doesn't
	// want OSC 52 spam just because someone pressed Ctrl+X on an
	// empty selection.
	mut c := fresh_clipboard()
	c.write([]u8{})
	assert c.data.len == 0
	assert c.wants_host_sync == false
	// But a non-empty write after that still sets the flag.
	c.write('x'.bytes())
	assert c.wants_host_sync == true
}

fn test_clipboard_write_resets_line_copy_flag() {
	mut c := fresh_clipboard()
	c.write_was_line_copy(true)
	assert c.is_line_copy() == true
	// A subsequent regular write must clear line_copy so the
	// paste-time prepend behavior doesn't kick in by mistake.
	c.write('regular'.bytes())
	assert c.is_line_copy() == false
}

fn test_clipboard_write_was_line_copy_round_trip() {
	mut c := fresh_clipboard()
	c.write_was_line_copy(true)
	assert c.is_line_copy() == true
	c.write_was_line_copy(false)
	assert c.is_line_copy() == false
}

fn test_clipboard_mark_as_synchronized_clears_sync_and_pending() {
	mut c := fresh_clipboard()
	c.write('x'.bytes())
	c.large_pending = true
	assert c.wants_host_sync() == true
	c.mark_as_synchronized()
	assert c.wants_host_sync() == false
	assert c.large_pending == false
	// wants_warning goes false too because the gate is driven by
	// wants_host_sync.
	assert c.clipboard_wants_warning() == false
}

fn test_clipboard_wants_warning_threshold() {
	// Just under the threshold → no warning.
	mut c := fresh_clipboard()
	c.write([]u8{len: large_clipboard_threshold - 1})
	assert c.clipboard_wants_warning() == false
	// At the threshold → warning.
	c.write([]u8{len: large_clipboard_threshold})
	assert c.clipboard_wants_warning() == true
	// Above the threshold → still warning.
	c.write([]u8{len: large_clipboard_threshold + 1})
	assert c.clipboard_wants_warning() == true
}

fn test_clipboard_wants_warning_off_when_always_send_set() {
	// The sticky "Always" preference bypasses the gate.
	mut c := fresh_clipboard()
	c.large_always_send = true
	c.write([]u8{len: large_clipboard_threshold * 4})
	assert c.clipboard_wants_warning() == false
}

fn test_clipboard_wants_warning_off_when_no_pending_sync() {
	// Even a huge payload doesn't warn if the host sync flag is off
	// (e.g. the data was just loaded, not written by the user).
	mut c := fresh_clipboard()
	c.data = []u8{len: 1024 * 1024}
	c.wants_host_sync = false
	assert c.clipboard_wants_warning() == false
}

fn test_clipboard_resolve_large_pending_dropping_clears_only_pending() {
	// resolve_large_pending(false) clears the pending flag but leaves
	// wants_host_sync intact so a later, smaller write doesn't drop
	// the pending sync accidentally.
	mut c := fresh_clipboard()
	c.write('x'.bytes())
	c.large_pending = true
	assert c.wants_host_sync() == true
	c.resolve_large_pending(false)
	assert c.large_pending == false
	assert c.wants_host_sync() == true
}

fn test_clipboard_resolve_large_pending_sending_clears_both() {
	mut c := fresh_clipboard()
	c.write('x'.bytes())
	c.large_pending = true
	c.resolve_large_pending(true)
	assert c.large_pending == false
	assert c.wants_host_sync() == false
}

fn test_clipboard_read_returns_a_copy_of_data() {
	// read() returns whatever was written — the value, not the
	// identity, matters; clipboard ops treat data as immutable bytes.
	mut c := fresh_clipboard()
	payload := 'selection'.bytes()
	c.write(payload.clone())
	assert c.read() == payload
	assert c.read().len == payload.len
}
