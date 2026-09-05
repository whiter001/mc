module main

// document_test.v — coverage for the small pure helpers in document.v
// (clamp_offset, utf8_lossy) and the StringDocument methods that
// depend only on its in-memory text.

fn test_clamp_offset_negative_clamps_to_zero() {
	assert clamp_offset(-1, 10) == 0
	assert clamp_offset(-100, 10) == 0
}

fn test_clamp_offset_past_end_clamps_to_len() {
	assert clamp_offset(11, 10) == 10
	assert clamp_offset(100, 10) == 10
}

fn test_clamp_offset_in_range_passes_through() {
	assert clamp_offset(0, 10) == 0
	assert clamp_offset(5, 10) == 5
	assert clamp_offset(10, 10) == 10
}

fn test_clamp_offset_empty_buffer() {
	// len == 0: only 0 is in range; -1 and 1 both clamp to 0.
	assert clamp_offset(0, 0) == 0
	assert clamp_offset(-1, 0) == 0
	assert clamp_offset(1, 0) == 0
}

fn test_utf8_lossy_passes_valid_utf8() {
	assert utf8_lossy('hello'.bytes()) == 'hello'
	assert utf8_lossy(''.bytes()) == ''
	assert utf8_lossy('中'.bytes()) == '中'
	assert utf8_lossy('Hi\nThere'.bytes()) == 'Hi\nThere'
}

fn test_utf8_lossy_replaces_invalid_sequences() {
	// Lone continuation byte 0x80 is invalid; WHATWG says replace with
	// U+FFFD. The function must not panic and must return at least the
	// valid prefix.
	got := utf8_lossy([u8(0x80)])
	assert got == '\uFFFD'
	// A valid byte followed by an invalid byte keeps both runes.
	got2 := utf8_lossy([u8(`a`), 0x80])
	assert got2.len > 1
	assert got2[0] == `a`
}

// StringDocument round-trips read_forward / read_backward / replace.

fn test_string_document_read_forward_clamp() {
	mut d := StringDocument{ text: 'hello' }
	// Negative offset clamps to 0.
	assert d.read_forward(-1).bytestr() == 'hello'
	// Past-end offset clamps to len.
	assert d.read_forward(100).len == 0
	// Mid-buffer offset returns the tail.
	assert d.read_forward(2).bytestr() == 'llo'
}

fn test_string_document_read_backward_clamp() {
	mut d := StringDocument{ text: 'hello' }
	// Negative clamps to 0.
	assert d.read_backward(-1).len == 0
	// Past-end clamps to len.
	assert d.read_backward(100).bytestr() == 'hello'
	// Mid-buffer offset returns the prefix.
	assert d.read_backward(2).bytestr() == 'he'
}

fn test_string_document_replace_inserts_at_offset() {
	mut d := StringDocument{ text: 'hello' }
	// Insert "X" at offset 2 without deleting anything (start == end).
	d.replace(2, 2, 'X'.bytes())
	assert d.text == 'heXllo'
	// Replace range with same length (no net change in length).
	d = StringDocument{ text: 'hello' }
	d.replace(1, 3, 'IP'.bytes())
	assert d.text == 'hIPlo'
	// Replace a range with a longer string.
	d = StringDocument{ text: 'hello' }
	d.replace(1, 3, 'ABCDE'.bytes())
	assert d.text == 'hABCDElo'
	// Replace a range with a shorter string.
	d = StringDocument{ text: 'hello' }
	d.replace(1, 4, 'X'.bytes())
	assert d.text == 'hXo'
}

fn test_string_document_replace_clamps_offsets() {
	mut d := StringDocument{ text: 'ab' }
	// Negative start clamps to 0; end beyond len clamps to len.
	d.replace(-5, 100, 'XY'.bytes())
	assert d.text == 'XY'
}
