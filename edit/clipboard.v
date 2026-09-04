module main

// Port of crates/edit/src/clipboard.rs (microsoft/edit).
// The builtin, internal clipboard of the editor.

// Clipboard is the editor-internal clipboard.
//
// This is useful particularly when the terminal doesn't support
// OSC 52 or when the clipboard contents are huge (e.g. 1GiB).
pub struct Clipboard {
mut:
	data            []u8
	line_copy       bool
	wants_host_sync bool
	// Sticky "Always" preference for the large-clipboard warning. Default
	// false; only flipped by the user's explicit choice in the modal
	// (matches Rust state.large_clipboard_always_send).
	large_always_send bool
	// True while a "send to terminal?" warning modal is pending for this
	// clipboard payload. While set, process_input() must not emit OSC 52
	// directly — the modal handler resolves the sync.
	large_pending bool
}

// LARGE_CLIPBOARD_THRESHOLD is the data size at which an OSC 52 sync prompts
// the user before sending (Rust main.rs LARGE_CLIPBOARD_THRESHOLD = 128 KiB).
pub const large_clipboard_threshold = 128 * 1024

// wants_host_sync returns true if we should emit an OSC 52 sequence to sync
// the clipboard with the hosting terminal.
pub fn (c Clipboard) wants_host_sync() bool {
	return c.wants_host_sync
}

// mark_as_synchronized should be called once the clipboard has been
// synchronized with the host.
pub fn (mut c Clipboard) mark_as_synchronized() {
	c.wants_host_sync = false
	c.large_pending = false
}

// is_line_copy reflects the editor's special behavior when you have no
// selection and press Ctrl+C: it copies the current line to the clipboard.
// Then, when you paste it, it inserts the line at *the start* of the current
// line, effectively prepending the current line with the copied line.
pub fn (c Clipboard) is_line_copy() bool {
	return c.line_copy
}

// read returns the current contents of the clipboard.
pub fn (c Clipboard) read() []u8 {
	return c.data
}

// write fills the clipboard with the given data.
pub fn (mut c Clipboard) write(data []u8) {
	if data.len > 0 {
		c.data = data
		c.line_copy = false
		c.wants_host_sync = true
	}
}

// write_was_line_copy sets the line_copy flag; see is_line_copy.
pub fn (mut c Clipboard) write_was_line_copy(line_copy bool) {
	c.line_copy = line_copy
}

// clipboard_size returns the byte length of the clipboard payload.
pub fn (c Clipboard) clipboard_size() int {
	return c.data.len
}

// clipboard_wants_warning reports whether the next OSC 52 sync needs to be
// gated behind the user confirmation modal (payload large and not already
// whitelisted by the sticky "Always" preference).
pub fn (c Clipboard) clipboard_wants_warning() bool {
	return c.wants_host_sync && !c.large_always_send && c.data.len >= large_clipboard_threshold
}

// resolve_large_pending resolves a pending warning modal: if `sending` is
// true the payload is emitted via OSC 52 and the sync is cleared, otherwise
// the pending sync is dropped silently.
pub fn (mut c Clipboard) resolve_large_pending(sending bool) {
	if sending {
		c.wants_host_sync = false
	}
	c.large_pending = false
}
