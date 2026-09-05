module main

// measurement_test.v — port of the #[cfg(test)] mod tests at the bottom of
// crates/edit/src/unicode/measurement.rs (microsoft/edit), plus extra tests
// for skip_newline, StringDocument and goto_offset/goto_logical/goto_visual
// round-trips.
//
// Rust's tests use `&[u8]` documents; here they use StringDocument, which
// returns identical bytes. The ChunkedDoc tests keep the chunked document.

// ChunkedDoc ports the test-only document from measurement.rs:
// it serves the document in separate chunks.
struct ChunkedDoc {
	chunks [][]u8
}

fn (d ChunkedDoc) read_forward(off int) []u8 {
	mut o := off
	for chunk in d.chunks {
		if o < chunk.len {
			return chunk[o..]
		}
		o -= chunk.len
	}
	return []u8{}
}

fn (d ChunkedDoc) read_backward(off int) []u8 {
	mut o := off
	for i := d.chunks.len - 1; i >= 0; i-- {
		chunk := d.chunks[i]
		if o < chunk.len {
			return chunk[0..chunk.len - o]
		}
		o -= chunk.len
	}
	return []u8{}
}

fn test_measure_forward_newline_start() {
	doc := StringDocument{
		text: 'foo\nbar'
	}
	mut cfg := new_measurement_config(doc)
	cursor := cfg.goto_visual(Point{
		x: 0
		y: 1
	})
	assert cursor == Cursor{
		offset:      4
		logical_pos: Point{
			x: 0
			y: 1
		}
		visual_pos:  Point{
			x: 0
			y: 1
		}
		column:      0
		wrap_opp:    false
	}
}

fn test_measure_forward_clipped_wide_char() {
	doc := StringDocument{
		text: 'a😶‍🌫️b'
	}
	mut cfg := new_measurement_config(doc)
	cursor := cfg.goto_visual(Point{
		x: 2
		y: 0
	})
	assert cursor == Cursor{
		offset:      1
		logical_pos: Point{
			x: 1
			y: 0
		}
		visual_pos:  Point{
			x: 1
			y: 0
		}
		column:      1
		wrap_opp:    false
	}
}

fn test_measure_forward_word_wrap() {
	//   |foo␣  |
	//   |bar␣  |
	//   |baz   |
	text := 'foo bar \nbaz'

	// Does hitting a logical target wrap the visual position along with the word?
	mut cfg := new_measurement_config(StringDocument{
		text: text
	}).with_word_wrap_column(6)
	cursor := cfg.goto_logical(Point{
		x: 5
		y: 0
	})
	assert cursor == Cursor{
		offset:      5
		logical_pos: Point{
			x: 5
			y: 0
		}
		visual_pos:  Point{
			x: 1
			y: 1
		}
		column:      5
		wrap_opp:    true
	}

	// Does hitting the visual target within a word reset the hit back to the end of the visual line?
	mut cfg2 := new_measurement_config(StringDocument{
		text: text
	}).with_word_wrap_column(6)
	cursor2 := cfg2.goto_visual(Point{
		x: coord_type_max
		y: 0
	})
	assert cursor2 == Cursor{
		offset:      4
		logical_pos: Point{
			x: 4
			y: 0
		}
		visual_pos:  Point{
			x: 4
			y: 0
		}
		column:      4
		wrap_opp:    true
	}

	// Does hitting the same target but with a non-zero starting position result in the same outcome?
	mut cfg3 := new_measurement_config(StringDocument{
		text: text
	}).with_word_wrap_column(6).with_cursor(Cursor{
		offset:      1
		logical_pos: Point{
			x: 1
			y: 0
		}
		visual_pos:  Point{
			x: 1
			y: 0
		}
		column:      1
		wrap_opp:    false
	})
	cursor3 := cfg3.goto_visual(Point{
		x: 5
		y: 0
	})
	assert cursor3 == Cursor{
		offset:      4
		logical_pos: Point{
			x: 4
			y: 0
		}
		visual_pos:  Point{
			x: 4
			y: 0
		}
		column:      4
		wrap_opp:    true
	}

	cursor4 := cfg3.goto_visual(Point{
		x: 0
		y: 1
	})
	assert cursor4 == Cursor{
		offset:      4
		logical_pos: Point{
			x: 4
			y: 0
		}
		visual_pos:  Point{
			x: 0
			y: 1
		}
		column:      4
		wrap_opp:    false
	}

	cursor5 := cfg3.goto_visual(Point{
		x: 5
		y: 1
	})
	assert cursor5 == Cursor{
		offset:      8
		logical_pos: Point{
			x: 8
			y: 0
		}
		visual_pos:  Point{
			x: 4
			y: 1
		}
		column:      8
		wrap_opp:    false
	}

	cursor6 := cfg3.goto_visual(Point{
		x: 0
		y: 2
	})
	assert cursor6 == Cursor{
		offset:      9
		logical_pos: Point{
			x: 0
			y: 1
		}
		visual_pos:  Point{
			x: 0
			y: 2
		}
		column:      0
		wrap_opp:    false
	}

	cursor7 := cfg3.goto_visual(Point{
		x: 5
		y: 2
	})
	assert cursor7 == Cursor{
		offset:      12
		logical_pos: Point{
			x: 3
			y: 1
		}
		visual_pos:  Point{
			x: 3
			y: 2
		}
		column:      3
		wrap_opp:    false
	}
}

fn test_measure_forward_tabs() {
	mut cfg := new_measurement_config(StringDocument{
		text: 'a\tb\tc'
	}).with_tab_size(4)
	cursor := cfg.goto_visual(Point{
		x: 4
		y: 0
	})
	assert cursor == Cursor{
		offset:      2
		logical_pos: Point{
			x: 2
			y: 0
		}
		visual_pos:  Point{
			x: 4
			y: 0
		}
		column:      4
		wrap_opp:    false
	}
}

fn test_measure_forward_chunk_boundaries() {
	chunks := [
		'Hello'.bytes(),
		'👩🏻'.bytes(), // 8 bytes, 2 columns
		'World'.bytes(),
	]
	doc := ChunkedDoc{
		chunks: chunks
	}
	mut cfg := new_measurement_config(doc)
	cursor := cfg.goto_visual(Point{
		x: 5 + 2 + 3
		y: 0
	})
	assert cursor.offset == 5 + 8 + 3
	assert cursor.logical_pos == Point{
		x: 5 + 1 + 3
		y: 0
	}
}

fn test_exact_wrap() {
	//   |foo_   |
	//   |bar.   |
	//   |abc    |
	chunks := ['foo '.bytes(), 'bar'.bytes(), '.\n'.bytes(), 'abc'.bytes()]
	doc := ChunkedDoc{
		chunks: chunks
	}
	mut cfg := new_measurement_config(doc).with_word_wrap_column(7)
	max := coord_type_max

	end0 := cfg.goto_visual(Point{
		x: 7
		y: 0
	})
	assert end0 == Cursor{
		offset:      4
		logical_pos: Point{
			x: 4
			y: 0
		}
		visual_pos:  Point{
			x: 4
			y: 0
		}
		column:      4
		wrap_opp:    true
	}

	beg1 := cfg.goto_visual(Point{
		x: 0
		y: 1
	})
	assert beg1 == Cursor{
		offset:      4
		logical_pos: Point{
			x: 4
			y: 0
		}
		visual_pos:  Point{
			x: 0
			y: 1
		}
		column:      4
		wrap_opp:    false
	}

	end1 := cfg.goto_visual(Point{
		x: max
		y: 1
	})
	assert end1 == Cursor{
		offset:      8
		logical_pos: Point{
			x: 8
			y: 0
		}
		visual_pos:  Point{
			x: 4
			y: 1
		}
		column:      8
		wrap_opp:    false
	}

	beg2 := cfg.goto_visual(Point{
		x: 0
		y: 2
	})
	assert beg2 == Cursor{
		offset:      9
		logical_pos: Point{
			x: 0
			y: 1
		}
		visual_pos:  Point{
			x: 0
			y: 2
		}
		column:      0
		wrap_opp:    false
	}

	end2 := cfg.goto_visual(Point{
		x: max
		y: 2
	})
	assert end2 == Cursor{
		offset:      12
		logical_pos: Point{
			x: 3
			y: 1
		}
		visual_pos:  Point{
			x: 3
			y: 2
		}
		column:      3
		wrap_opp:    false
	}
}

fn test_force_wrap() {
	// |//_     |
	// |aaaaaaaa|
	// |aaaa    |
	mut cfg := new_measurement_config(StringDocument{
		text: '// aaaaaaaaaaaa'
	}).with_word_wrap_column(8)
	max := coord_type_max

	// At the end of "// " there should be a wrap.
	end0 := cfg.goto_visual(Point{
		x: max
		y: 0
	})
	assert end0 == Cursor{
		offset:      3
		logical_pos: Point{
			x: 3
			y: 0
		}
		visual_pos:  Point{
			x: 3
			y: 0
		}
		column:      3
		wrap_opp:    true
	}

	// Test if the ambiguous visual position at the wrap location doesn't change the offset.
	beg0 := cfg.goto_visual(Point{
		x: 0
		y: 1
	})
	assert beg0 == Cursor{
		offset:      3
		logical_pos: Point{
			x: 3
			y: 0
		}
		visual_pos:  Point{
			x: 0
			y: 1
		}
		column:      3
		wrap_opp:    false
	}

	// Test if navigating inside the wrapped line doesn't cause further wrapping.
	//
	// This step of the test is important, as it ensures that the following force-wrap works,
	// even if 1 of the 8 "a"s was already processed.
	beg0_off1 := cfg.goto_logical(Point{
		x: 4
		y: 0
	})
	assert beg0_off1 == Cursor{
		offset:      4
		logical_pos: Point{
			x: 4
			y: 0
		}
		visual_pos:  Point{
			x: 1
			y: 1
		}
		column:      4
		wrap_opp:    false
	}

	// Test if the force-wrap applies at the end of the first 8 "a"s.
	end1 := cfg.goto_visual(Point{
		x: max
		y: 1
	})
	assert end1 == Cursor{
		offset:      11
		logical_pos: Point{
			x: 11
			y: 0
		}
		visual_pos:  Point{
			x: 8
			y: 1
		}
		column:      11
		wrap_opp:    true
	}

	// Test if the remaining 4 "a"s are properly laid-out.
	end2 := cfg.goto_visual(Point{
		x: max
		y: 2
	})
	assert end2 == Cursor{
		offset:      15
		logical_pos: Point{
			x: 15
			y: 0
		}
		visual_pos:  Point{
			x: 4
			y: 2
		}
		column:      15
		wrap_opp:    false
	}
}

fn test_force_wrap_wide() {
	// These Yijing Hexagram Symbols form no word wrap opportunities.
	text := '䷀䷁䷂䷃䷄䷅䷆䷇䷈䷉'
	expected := ['䷀䷁', '䷂䷃', '䷄䷅', '䷆䷇', '䷈䷉']
	mut cfg := new_measurement_config(StringDocument{
		text: text
	}).with_word_wrap_column(5)

	for y, exp in expected {
		// In order for `goto_visual()` to hit column 0 after a word wrap,
		// it MUST be able to go back by 1 grapheme, which is what this tests.
		beg := cfg.goto_visual(Point{
			x: 0
			y: CoordType(y)
		})
		end := cfg.goto_visual(Point{
			x: 5
			y: CoordType(y)
		})
		actual := text[beg.offset..end.offset]
		assert actual == exp
	}
}

// Similar to the `test_force_wrap` test, but here we vertically descend
// down the document without ever touching the first or last column.
// I found that this finds curious bugs at times.
fn test_force_wrap_column() {
	// |//_     |
	// |aaaaaaaa|
	// |aaaa    |
	mut cfg := new_measurement_config(StringDocument{
		text: '// aaaaaaaaaaaa'
	}).with_word_wrap_column(8)

	// At the end of "// " there should be a wrap.
	end0 := cfg.goto_visual(Point{
		x: coord_type_max
		y: 0
	})
	assert end0 == Cursor{
		offset:      3
		logical_pos: Point{
			x: 3
			y: 0
		}
		visual_pos:  Point{
			x: 3
			y: 0
		}
		column:      3
		wrap_opp:    true
	}

	mid1 := cfg.goto_visual(Point{
		x: end0.visual_pos.x
		y: 1
	})
	assert mid1 == Cursor{
		offset:      6
		logical_pos: Point{
			x: 6
			y: 0
		}
		visual_pos:  Point{
			x: 3
			y: 1
		}
		column:      6
		wrap_opp:    false
	}

	mid2 := cfg.goto_visual(Point{
		x: end0.visual_pos.x
		y: 2
	})
	assert mid2 == Cursor{
		offset:      14
		logical_pos: Point{
			x: 14
			y: 0
		}
		visual_pos:  Point{
			x: 3
			y: 2
		}
		column:      14
		wrap_opp:    false
	}
}

fn test_any_wrap() {
	// |//_-----|
	// |------- |
	mut cfg := new_measurement_config(StringDocument{
		text: '// ------------'
	}).with_word_wrap_column(8)
	max := coord_type_max

	end0 := cfg.goto_visual(Point{
		x: max
		y: 0
	})
	assert end0 == Cursor{
		offset:      8
		logical_pos: Point{
			x: 8
			y: 0
		}
		visual_pos:  Point{
			x: 8
			y: 0
		}
		column:      8
		wrap_opp:    true
	}

	end1 := cfg.goto_visual(Point{
		x: max
		y: 1
	})
	assert end1 == Cursor{
		offset:      15
		logical_pos: Point{
			x: 15
			y: 0
		}
		visual_pos:  Point{
			x: 7
			y: 1
		}
		column:      15
		wrap_opp:    true
	}
}

fn test_any_wrap_wide() {
	// These Japanese characters form word wrap opportunity between each character.
	text := '零一二三四五六七八九'
	expected := ['零一', '二三', '四五', '六七', '八九']
	mut cfg := new_measurement_config(StringDocument{
		text: text
	}).with_word_wrap_column(5)

	for y, exp in expected {
		// In order for `goto_visual()` to hit column 0 after a word wrap,
		// it MUST be able to go back by 1 grapheme, which is what this tests.
		beg := cfg.goto_visual(Point{
			x: 0
			y: CoordType(y)
		})
		end := cfg.goto_visual(Point{
			x: 5
			y: CoordType(y)
		})
		actual := text[beg.offset..end.offset]
		assert actual == exp
	}
}

fn test_wrap_tab() {
	// |foo_    | <- 1 space
	// |____b   | <- 1 tab, 1 space
	text := 'foo \t b'
	mut cfg := new_measurement_config(StringDocument{
		text: text
	}).with_word_wrap_column(8).with_tab_size(4)
	max := coord_type_max

	end0 := cfg.goto_visual(Point{
		x: max
		y: 0
	})
	assert end0 == Cursor{
		offset:      4
		logical_pos: Point{
			x: 4
			y: 0
		}
		visual_pos:  Point{
			x: 4
			y: 0
		}
		column:      4
		wrap_opp:    true
	}

	beg1 := cfg.goto_visual(Point{
		x: 0
		y: 1
	})
	assert beg1 == Cursor{
		offset:      4
		logical_pos: Point{
			x: 4
			y: 0
		}
		visual_pos:  Point{
			x: 0
			y: 1
		}
		column:      4
		wrap_opp:    false
	}

	end1 := cfg.goto_visual(Point{
		x: max
		y: 1
	})
	assert end1 == Cursor{
		offset:      7
		logical_pos: Point{
			x: 7
			y: 0
		}
		visual_pos:  Point{
			x: 6
			y: 1
		}
		column:      10
		wrap_opp:    true
	}
}

fn test_crlf() {
	mut cfg := new_measurement_config(StringDocument{
		text: 'a\r\nbcd\r\ne'
	})
	cursor := cfg.goto_visual(Point{
		x: coord_type_max
		y: 1
	})
	assert cursor == Cursor{
		offset:      6
		logical_pos: Point{
			x: 3
			y: 1
		}
		visual_pos:  Point{
			x: 3
			y: 1
		}
		column:      3
		wrap_opp:    false
	}
}

fn test_wrapped_cursor_can_seek_backward() {
	mut cfg := new_measurement_config(StringDocument{
		text: 'hello world'
	}).with_word_wrap_column(10)

	// When the word wrap at column 10 hits, the cursor will be at the end of the word "world" (between l and d).
	// This tests if the algorithm is capable of going back to the start of the word and find the actual target.
	cursor := cfg.goto_visual(Point{
		x: 2
		y: 1
	})
	assert cursor == Cursor{
		offset:      8
		logical_pos: Point{
			x: 8
			y: 0
		}
		visual_pos:  Point{
			x: 2
			y: 1
		}
		column:      8
		wrap_opp:    false
	}
}

fn test_strip_newline() {
	assert strip_newline('hello\n'.bytes()) == 'hello'.bytes()
	assert strip_newline('hello\r\n'.bytes()) == 'hello'.bytes()
	assert strip_newline('hello'.bytes()) == 'hello'.bytes()
}

// --- Additional tests beyond the Rust original ---

fn test_skip_newline() {
	assert skip_newline('hello\n'.bytes(), 5) == 6
	assert skip_newline('hello\r\n'.bytes(), 5) == 7
	assert skip_newline('hello\r'.bytes(), 5) == 6
	assert skip_newline('hello'.bytes(), 5) == 5
	assert skip_newline('hello'.bytes(), 10) == 10
	assert skip_newline('ab'.bytes(), 0) == 0
}

// For every grapheme cluster boundary in a multi-line document,
// goto_logical(goto_offset(o).logical_pos) and goto_visual(goto_offset(o).visual_pos)
// must lead back to the same offset.
fn test_goto_offset_logical_visual_inverse() {
	text := 'Hello\nWorld\n中文\n'
	doc := StringDocument{
		text: text
	}
	// Cluster boundaries: ASCII lines, a CJK line, and the final offset.
	offsets := [0, 1, 5, 6, 7, 11, 12, 15, 18, 19]
	for off in offsets {
		mut cfg := new_measurement_config(doc)
		c := cfg.goto_offset(off)
		assert c.offset == off

		mut cfg_logical := new_measurement_config(doc)
		c_logical := cfg_logical.goto_logical(c.logical_pos)
		assert c_logical.offset == c.offset

		mut cfg_visual := new_measurement_config(doc)
		c_visual := cfg_visual.goto_visual(c.visual_pos)
		assert c_visual.offset == c.offset
	}
}

fn test_string_document_read() {
	doc := StringDocument{
		text: 'abc'
	}
	assert doc.read_forward(1) == 'bc'.bytes()
	assert doc.read_backward(2) == 'ab'.bytes()
	// Out-of-bounds offsets are clamped.
	assert doc.read_forward(100).len == 0
	assert doc.read_backward(100) == 'abc'.bytes()
	assert doc.read_forward(-1) == 'abc'.bytes()
	assert doc.read_backward(-1).len == 0
}

fn test_string_document_replace() {
	mut doc := StringDocument{
		text: 'hello world'
	}
	doc.replace(6, 11, 'V'.bytes())
	assert doc.text == 'hello V'

	// Out-of-bounds ranges are clamped.
	mut doc2 := StringDocument{
		text: 'hello V'
	}
	doc2.replace(-5, 100, 'x'.bytes())
	assert doc2.text == 'x'

	// The replacement may not be valid UTF-8: it is sanitized lossily
	// (ED A0 80 is an overlong/surrogate sequence -> 3x U+FFFD, like
	// Rust's String::from_utf8_lossy).
	mut doc3 := StringDocument{
		text: 'ab'
	}
	doc3.replace(1, 2, [u8(0xED), 0xA0, 0x80])
	assert doc3.text == 'a\uFFFD\uFFFD\uFFFD'
}

fn test_string_document_implements_interfaces() {
	mut doc := &StringDocument{
		text: 'abc'
	}
	mut w := WriteableDocument(doc)
	w.replace(1, 2, 'X'.bytes())
	assert doc.text == 'aXc'
	r := ReadableDocument(doc)
	assert r.read_forward(1) == 'Xc'.bytes()
	assert r.read_backward(2) == 'aX'.bytes()
}

// Port of stdext's utf8.rs test_broken_utf8:
// [a, ED A0 80, b] -> 'a', U+FFFD x3, 'b' with exact byte offsets.
fn test_utf8_chars_broken_utf8() {
	source := [u8(`a`), 0xED, 0xA0, 0x80, `b`]
	mut chars := new_utf8_chars(source, 0)
	mut results := []rune{}
	mut offsets := []int{}
	for {
		ch := chars.next() or { break }
		results << ch
		offsets << chars.offset
	}
	assert results == [rune(`a`), rune(0xFFFD), rune(0xFFFD), rune(0xFFFD), rune(`b`)]
	assert offsets == [1, 2, 3, 4, 5]
}

// ---- Pure helpers (measurement.v) ---------------------------------------

fn test_point_max_returns_coord_type_max_on_both_axes() {
	// point_max() returns the same value on both x and y.
	pm := point_max()
	assert pm.x == coord_type_max
	assert pm.y == coord_type_max
}

fn test_measurement_config_cursor_returns_constructor_state() {
	// new_measurement_config() seeds the cursor at offset 0, logical (0, 0).
	mut c := new_measurement_config(StringDocument{ text: 'hello' })
	cur := c.cursor()
	assert cur.offset == 0
	assert cur.logical_pos == Point{ x: 0, y: 0 }
	// After moving the cursor through goto_offset, cursor() reflects it.
	c.goto_offset(3)
	cur2 := c.cursor()
	assert cur2.offset == 3
	assert cur2.logical_pos == Point{ x: 3, y: 0 }
}

fn test_skip_newline_lf() {
	// LF at the offset advances by 1.
	assert skip_newline('hello\nworld'.bytes(), 5) == 6
	// CRLF at the offset advances by 2.
	assert skip_newline('hello\r\nworld'.bytes(), 5) == 7
}

fn test_skip_newline_past_end_returns_offset_unchanged() {
	// offset at or past text.len leaves the offset alone.
	assert skip_newline('hello'.bytes(), 5) == 5
	assert skip_newline('hello'.bytes(), 100) == 100
}

fn test_skip_newline_non_newline_offset_returns_offset_unchanged() {
	// Ordinary characters do not advance.
	assert skip_newline('hello'.bytes(), 0) == 0
	assert skip_newline('hello'.bytes(), 3) == 3
}

fn test_skip_newline_cr_at_end_consumes_cr_anyway() {
	// skip_newline consumes a CR even if no LF follows; the LF check
	// then bails because off == text.len. This is the implementation's
	// current behavior — pin it so a future tightening is intentional.
	assert skip_newline('hi\r'.bytes(), 2) == 3
	assert skip_newline('\r'.bytes(), 0) == 1
	// A bare LF at the end is also consumed.
	assert skip_newline('hi\n'.bytes(), 2) == 3
}

fn test_strip_newline_lf_only() {
	// Trailing LF stripped, rest preserved.
	assert strip_newline('hello\n'.bytes()).bytestr() == 'hello'
}

fn test_strip_newline_crlf() {
	// Trailing CRLF stripped (LF first, then CR).
	assert strip_newline('hello\r\n'.bytes()).bytestr() == 'hello'
}

fn test_strip_newline_no_trailing_newline() {
	// No trailing newline: pass-through unchanged.
	assert strip_newline('hello'.bytes()).bytestr() == 'hello'
}

fn test_strip_newline_empty_and_only_newline() {
	// Empty buffer stays empty.
	assert strip_newline(''.bytes()).len == 0
	// A bare newline is stripped fully.
	assert strip_newline('\n'.bytes()).len == 0
	assert strip_newline('\r\n'.bytes()).len == 0
}
