module main

// Port of crates/edit/src/document.rs (microsoft/edit).
// Abstractions over reading/writing arbitrary text containers.

// ReadableDocument is an abstraction over reading from text containers.
pub interface ReadableDocument {
	// read_forward reads some bytes starting at (including) the given absolute offset.
	//
	// Warning:
	// * Be lenient on inputs:
	//   * The given offset may be out of bounds and you MUST clamp it.
	//   * You should not assume that offsets are at grapheme cluster boundaries.
	// * Be strict on outputs:
	//   * You MUST NOT break grapheme clusters across chunks.
	//   * You MUST NOT return an empty slice unless the offset is at or beyond the end.
	read_forward(off int) []u8
	// read_backward reads some bytes before (but not including) the given absolute offset.
	//
	// Warning:
	// * Be lenient on inputs:
	//   * The given offset may be out of bounds and you MUST clamp it.
	//   * You should not assume that offsets are at grapheme cluster boundaries.
	// * Be strict on outputs:
	//   * You MUST NOT break grapheme clusters across chunks.
	//   * You MUST NOT return an empty slice unless the offset is zero.
	read_backward(off int) []u8
}

// WriteableDocument is an abstraction over writing to text containers.
pub interface WriteableDocument {
	ReadableDocument
mut:
	// replace replaces the given range with the given bytes.
	//
	// Warning:
	// * The given range may be out of bounds and you MUST clamp it.
	// * The replacement may not be valid UTF8.
	replace(start int, end int, replacement []u8)
}

// StringDocument wraps a string and implements both ReadableDocument and
// WriteableDocument. Used by tests and editline.
pub struct StringDocument {
pub mut:
	text string
}

// read_forward implements ReadableDocument.read_forward for StringDocument.
pub fn (d StringDocument) read_forward(off int) []u8 {
	clamped := clamp_offset(off, d.text.len)
	return d.text.bytes()[clamped..]
}

// read_backward implements ReadableDocument.read_backward for StringDocument.
pub fn (d StringDocument) read_backward(off int) []u8 {
	clamped := clamp_offset(off, d.text.len)
	return d.text.bytes()[0..clamped]
}

// replace implements WriteableDocument.replace for StringDocument.
// `replacement` is not guaranteed to be valid UTF-8, so we need to sanitize it
// (equivalent to Rust's String::from_utf8_lossy).
pub fn (mut d StringDocument) replace(start int, end int, replacement []u8) {
	// Same clamping as stdext's vec_replace_impl:
	// off = start.min(len); del_len = end.saturating_sub(off).min(len - off).
	off := clamp_offset(start, d.text.len)
	mut del_len := end - off
	if del_len < 0 {
		del_len = 0
	}
	if del_len > d.text.len - off {
		del_len = d.text.len - off
	}
	utf8 := utf8_lossy(replacement)
	d.text = d.text[0..off] + utf8 + d.text[off + del_len..]
}

// clamp_offset clamps an offset into [0, len]. Rust uses usize which cannot
// be negative; V ints can, so we clamp both sides (be lenient on inputs).
fn clamp_offset(off int, len int) int {
	if off < 0 {
		return 0
	}
	if off > len {
		return len
	}
	return off
}

// utf8_lossy sanitizes a possibly invalid UTF-8 byte string, replacing invalid
// sequences with U+FFFD. Equivalent to Rust's String::from_utf8_lossy, which
// follows the WHATWG recommendation for UTF-8 error recovery, just like
// Utf8Chars does.
fn utf8_lossy(bytes []u8) string {
	mut chars := new_utf8_chars(bytes, 0)
	mut runes := []rune{cap: bytes.len}
	for {
		ch := chars.next() or { break }
		runes << ch
	}
	return runes.string()
}
