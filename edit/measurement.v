module main

// Port of crates/edit/src/unicode/measurement.rs (microsoft/edit),
// plus the Utf8Chars iterator from crates/stdext/src/unicode/utf8.rs.
//
// cold_path() hints from the Rust original are performance-only and omitted.

// On one hand it's disgusting that I wrote this as a global variable, but on the
// other hand, this isn't a public library API, and it makes the code a lot cleaner,
// because we don't need to inject this once-per-process value everywhere.
// (Rust: `static mut AMBIGUOUS_WIDTH: usize = 1`, guarded by a OnceLock-like
// set-once-per-process contract; V uses `__global`.)
__global (
	g_ambiguous_width = int(1)
)

// coord_type_max is CoordType::MAX, used for Point::MAX and usize::MAX targets.
const coord_type_max = CoordType(0x7fffffff)

// offset_target_max stands in for Rust's usize::MAX offset targets.
const offset_target_max = int(0x7fffffff)

// setup_ambiguous_width sets the width of "ambiguous" width characters as per
// "UAX #11: East Asian Width".
//
// Defaults to 1.
pub fn setup_ambiguous_width(ambiguous_width CoordType) {
	g_ambiguous_width = int(ambiguous_width)
}

// ambiguous_width reads the global set by setup_ambiguous_width.
@[inline]
fn ambiguous_width() int {
	// This is a global variable that is set once per process.
	// It is never changed after that, so this is safe to call.
	return g_ambiguous_width
}

// point_max is Rust's Point::MAX.
fn point_max() Point {
	return Point{
		x: coord_type_max
		y: coord_type_max
	}
}

// Cursor stores a position inside a ReadableDocument.
//
// The cursor tracks both the absolute byte-offset,
// as well as the position in terminal-related coordinates.
pub struct Cursor {
pub mut:
	// Offset in bytes within the buffer.
	offset int
	// Position in the buffer in lines (.y) and grapheme clusters (.x).
	//
	// Line wrapping has NO influence on this.
	logical_pos Point
	// Position in the buffer in laid out rows (.y) and columns (.x).
	//
	// Line wrapping has an influence on this.
	visual_pos Point
	// Horizontal position in visual columns.
	//
	// Line wrapping has NO influence on this and if word wrap is disabled,
	// it's identical to `visual_pos.x`. This is useful for calculating tab widths.
	column CoordType
	// When `measure_forward` hits the `word_wrap_column`, the question is:
	// Was there a wrap opportunity on this line? Because if there wasn't,
	// a hard-wrap is required; otherwise, the word that is being laid-out is
	// moved to the next line. This boolean carries this state between calls.
	wrap_opp bool
}

// MeasurementConfig is your entrypoint to navigating inside a ReadableDocument.
pub struct MeasurementConfig {
mut:
	cursor           Cursor
	tab_size         CoordType = 8
	word_wrap_column CoordType
	buffer           ReadableDocument
}

// new_measurement_config creates a new MeasurementConfig for the given document.
pub fn new_measurement_config(buffer ReadableDocument) MeasurementConfig {
	return MeasurementConfig{
		cursor:           Cursor{}
		tab_size:         8
		word_wrap_column: 0
		buffer:           buffer
	}
}

// with_cursor sets the initial cursor to the given position.
//
// WARNING: While the code doesn't panic if the cursor is invalid,
// the results will obviously be complete garbage.
pub fn (c MeasurementConfig) with_cursor(cursor Cursor) MeasurementConfig {
	mut res := c
	res.cursor = cursor
	return res
}

// with_tab_size sets the tab size.
//
// Defaults to 8, because that's what a tab in terminals evaluates to.
pub fn (c MeasurementConfig) with_tab_size(tab_size CoordType) MeasurementConfig {
	mut res := c
	res.tab_size = if tab_size > 1 { tab_size } else { CoordType(1) }
	return res
}

// with_word_wrap_column: You want word wrap? Set it here!
//
// Defaults to 0, which means no word wrap.
pub fn (c MeasurementConfig) with_word_wrap_column(word_wrap_column CoordType) MeasurementConfig {
	mut res := c
	res.word_wrap_column = word_wrap_column
	return res
}

// goto_offset navigates **forward** to the given absolute offset.
//
// Returns the cursor position after the navigation.
pub fn (mut c MeasurementConfig) goto_offset(offset int) Cursor {
	return c.measure_forward(offset, point_max(), point_max())
}

// goto_logical navigates **forward** to the given logical position.
//
// Logical positions are in lines and grapheme clusters.
//
// Returns the cursor position after the navigation.
pub fn (mut c MeasurementConfig) goto_logical(logical_target Point) Cursor {
	return c.measure_forward(offset_target_max, logical_target, point_max())
}

// goto_visual navigates **forward** to the given visual position.
//
// Visual positions are in laid out rows and columns.
//
// Returns the cursor position after the navigation.
pub fn (mut c MeasurementConfig) goto_visual(visual_target Point) Cursor {
	return c.measure_forward(offset_target_max, point_max(), visual_target)
}

// cursor returns the current cursor position.
pub fn (c MeasurementConfig) cursor() Cursor {
	return c.cursor
}

// NOTE that going to a visual target can result in ambiguous results,
// where going to an identical logical target will yield a different result.
//
// Imagine if you have a `word_wrap_column` of 6 and there's "Hello World" on the line:
// `goto_logical` will return a `visual_pos` of {0,1}, while `goto_visual` returns {6,0}.
// This is because from a logical POV, if the wrap location equals the wrap column,
// the wrap exists on both lines and it'll default to wrapping. `goto_visual` however will always
// try to return a Y position that matches the requested position, so that Home/End works properly.
fn (mut c MeasurementConfig) measure_forward(offset_target int, logical_target Point, visual_target Point) Cursor {
	if c.cursor.offset >= offset_target || c.cursor.logical_pos.compare(logical_target) >= 0
		|| c.cursor.visual_pos.compare(visual_target) >= 0 {
		return c.cursor
	}

	mut offset := c.cursor.offset
	mut logical_pos_x := c.cursor.logical_pos.x
	mut logical_pos_y := c.cursor.logical_pos.y
	mut visual_pos_x := c.cursor.visual_pos.x
	mut visual_pos_y := c.cursor.visual_pos.y
	mut column := c.cursor.column

	mut logical_target_x := calc_target_x(logical_target, logical_pos_y)
	mut visual_target_x := calc_target_x(visual_target, visual_pos_y)

	// wrap_opp = Wrap Opportunity
	// These store the position and column of the last wrap opportunity. If `word_wrap_column` is
	// zero (word wrap disabled), all grapheme clusters are a wrap opportunity, because none are.
	mut wrap_opp := c.cursor.wrap_opp
	mut wrap_opp_offset := offset
	mut wrap_opp_logical_pos_x := logical_pos_x
	mut wrap_opp_visual_pos_x := visual_pos_x
	mut wrap_opp_column := column

	mut chunk_iter := new_utf8_chars([]u8{}, 0)
	mut chunk_start := offset
	mut chunk_end := offset
	mut props_next_cluster := ucd_start_of_text_properties()

	for {
		// Have we reached the target already? Stop.
		if offset >= offset_target || logical_pos_x >= logical_target_x
			|| visual_pos_x >= visual_target_x {
			break
		}

		props_current_cluster := props_next_cluster
		mut props_last_char := 0
		mut offset_next_cluster := 0
		mut state := u32(0)
		mut width := CoordType(0)

		// Since we want to measure the width of the current cluster,
		// by necessity we need to seek to the next cluster.
		// We'll then reuse the offset and properties of the next cluster in
		// the next iteration of the this (outer) loop (`props_next_cluster`).
		for {
			if !chunk_iter.has_next() {
				chunk_iter = new_utf8_chars(c.buffer.read_forward(chunk_end), 0)
				chunk_start = chunk_end
				chunk_end = chunk_end + chunk_iter.len()
			}

			// Since this loop seeks ahead to the next cluster, and since `chunk_iter`
			// records the offset of the next character after the returned one, we need
			// to save the offset of the previous `chunk_iter` before calling `next()`.
			// Similar applies to the width.
			props_last_char = props_next_cluster
			offset_next_cluster = chunk_start + chunk_iter.offset
			width += CoordType(ucd_grapheme_cluster_character_width(props_next_cluster,
				ambiguous_width()))

			// The `ReadableDocument.read_forward` interface promises us that it will not split
			// grapheme clusters across chunks. Therefore, we can safely break here.
			ch := chunk_iter.next() or { break }

			// Get the properties of the next cluster.
			props_next_cluster = ucd_grapheme_cluster_lookup(ch)
			state = ucd_grapheme_cluster_joins(state, props_last_char, props_next_cluster)

			// Stop if the next character does not join.
			if ucd_grapheme_cluster_joins_done(state) {
				break
			}
		}

		if offset_next_cluster == offset {
			// No advance and the iterator is empty? End of text reached.
			if chunk_iter.is_empty() {
				break
			}
			// Ignore the first iteration when processing the start-of-text.
			continue
		}

		// The max. width of a terminal cell is 2.
		if width > 2 {
			width = 2
		}

		// Tabs require special handling because they can have a variable width.
		if props_last_char == ucd_tab_properties() {
			// `c.tab_size` is clamped to >= 1 in `with_tab_size`.
			width = c.tab_size - (column % c.tab_size)
		}

		// Hard wrap: Both the logical and visual position advance by one line.
		if props_last_char == ucd_linefeed_properties() {
			wrap_opp = false

			// Don't cross the newline if the target is on this line but we haven't reached it.
			// E.g. if the callers asks for column 100 on a 10 column line,
			// we'll return with the cursor set to column 10.
			if logical_pos_y >= logical_target.y || visual_pos_y >= visual_target.y {
				break
			}

			offset = offset_next_cluster
			logical_pos_x = 0
			logical_pos_y += 1
			visual_pos_x = 0
			visual_pos_y += 1
			column = 0

			logical_target_x = calc_target_x(logical_target, logical_pos_y)
			visual_target_x = calc_target_x(visual_target, visual_pos_y)
			continue
		}

		// Avoid advancing past the visual target, because `width` can be greater than 1.
		if visual_pos_x + width > visual_target_x {
			break
		}

		// Since this code above may need to revert to a previous `wrap_opp_*`,
		// it must be done before advancing / checking for `ucd_line_break_joins`.
		if c.word_wrap_column > 0 && visual_pos_x + width > c.word_wrap_column {
			if !wrap_opp {
				// Otherwise, the lack of a wrap opportunity means that a single word
				// is wider than the word wrap column. We need to force-break the word.
				// This is similar to the above, but "bar" gets written at column 0.
				wrap_opp_offset = offset
				wrap_opp_logical_pos_x = logical_pos_x
				wrap_opp_visual_pos_x = visual_pos_x
				wrap_opp_column = column
				visual_pos_x = 0
			} else {
				// If we had a wrap opportunity on this line, we can move all
				// characters since then to the next line without stopping this loop:
				//   +---------+      +---------+      +---------+
				//   |      foo|  ->  |         |  ->  |         |
				//   |         |      |foo      |      |foobar   |
				//   +---------+      +---------+      +---------+
				// We don't actually move "foo", but rather just change where "bar" goes.
				// Since this function doesn't copy text, the end result is the same.
				visual_pos_x -= wrap_opp_visual_pos_x
			}

			wrap_opp = false
			visual_pos_y += 1
			visual_target_x = calc_target_x(visual_target, visual_pos_y)

			if visual_pos_x == visual_target_x {
				break
			}

			// Imagine the word is "hello" and on the "o" we notice it wraps.
			// If the target however was the "e", then we must revert back to "h" and search for it.
			if visual_pos_x > visual_target_x {
				offset = wrap_opp_offset
				logical_pos_x = wrap_opp_logical_pos_x
				visual_pos_x = 0
				column = wrap_opp_column

				chunk_iter.seek(chunk_iter.len())
				chunk_start = offset
				chunk_end = offset
				props_next_cluster = ucd_start_of_text_properties()
				continue
			}
		}

		offset = offset_next_cluster
		logical_pos_x += 1
		visual_pos_x += width
		column += width

		if c.word_wrap_column > 0
			&& !ucd_line_break_joins(props_current_cluster, props_next_cluster) {
			wrap_opp = true
			wrap_opp_offset = offset
			wrap_opp_logical_pos_x = logical_pos_x
			wrap_opp_visual_pos_x = visual_pos_x
			wrap_opp_column = column
		}
	}

	// If we're here, we hit our target. Now the only question is:
	// Is the word we're currently on so wide that it will be wrapped further down the document?
	if c.word_wrap_column > 0 {
		if !wrap_opp {
			// If the current laid-out line had no wrap opportunities, it means we had an input
			// such as "fooooooooooooooooooooo" at a `word_wrap_column` of e.g. 10. The word
			// didn't fit and the lack of a `wrap_opp` indicates we must force a hard wrap.
			// Thankfully, if we reach this point, that was already done by the code above.
		} else if wrap_opp_logical_pos_x != logical_pos_x && visual_pos_y <= visual_target.y {
			// Imagine the string "foo bar" with a word wrap column of 6. If I ask for the cursor at
			// `logical_pos={5,0}`, then the code above exited while reaching the target.
			// At this point, this function doesn't know yet that after the "b" there's "ar"
			// which causes a word wrap, and causes the final visual position to be {1,1}.
			// This code thus seeks ahead and checks if the current word will wrap or not.
			// Of course we only need to do this if the cursor isn't on a wrap opportunity already.

			// The loop below should not modify the target we already found.
			mut visual_pos_x_lookahead := visual_pos_x

			for {
				props_current_cluster := props_next_cluster
				mut props_last_char := 0
				mut offset_next_cluster := 0
				mut state := u32(0)
				mut width := CoordType(0)

				// Since we want to measure the width of the current cluster,
				// by necessity we need to seek to the next cluster.
				// We'll then reuse the offset and properties of the next cluster in
				// the next iteration of the this (outer) loop (`props_next_cluster`).
				for {
					if !chunk_iter.has_next() {
						chunk_iter = new_utf8_chars(c.buffer.read_forward(chunk_end), 0)
						chunk_start = chunk_end
						chunk_end = chunk_end + chunk_iter.len()
					}

					// Since this loop seeks ahead to the next cluster, and since `chunk_iter`
					// records the offset of the next character after the returned one, we need
					// to save the offset of the previous `chunk_iter` before calling `next()`.
					// Similar applies to the width.
					props_last_char = props_next_cluster
					offset_next_cluster = chunk_start + chunk_iter.offset
					width += CoordType(ucd_grapheme_cluster_character_width(props_next_cluster,
						ambiguous_width()))

					// The `ReadableDocument.read_forward` interface promises us that it will not split
					// grapheme clusters across chunks. Therefore, we can safely break here.
					ch := chunk_iter.next() or { break }

					// Get the properties of the next cluster.
					props_next_cluster = ucd_grapheme_cluster_lookup(ch)
					state = ucd_grapheme_cluster_joins(state, props_last_char, props_next_cluster)

					// Stop if the next character does not join.
					if ucd_grapheme_cluster_joins_done(state) {
						break
					}
				}

				if offset_next_cluster == offset {
					// No advance and the iterator is empty? End of text reached.
					if chunk_iter.is_empty() {
						break
					}
					// Ignore the first iteration when processing the start-of-text.
					continue
				}

				// The max. width of a terminal cell is 2.
				if width > 2 {
					width = 2
				}

				// Tabs require special handling because they can have a variable width.
				if props_last_char == ucd_tab_properties() {
					// `c.tab_size` is clamped to >= 1 in `with_tab_size`.
					width = c.tab_size - (column % c.tab_size)
				}

				// Hard wrap: Both the logical and visual position advance by one line.
				if props_last_char == ucd_linefeed_properties() {
					break
				}

				visual_pos_x_lookahead += width

				if visual_pos_x_lookahead > c.word_wrap_column {
					visual_pos_x -= wrap_opp_visual_pos_x
					visual_pos_y += 1
					break
				} else if !ucd_line_break_joins(props_current_cluster, props_next_cluster) {
					break
				}
			}
		}

		if visual_pos_y > visual_target.y {
			// Imagine the string "foo bar" with a word wrap column of 6. If I ask for the cursor at
			// `visual_pos={100,0}`, the code above exited early after wrapping without reaching the target.
			// Since I asked for the last character on the first line, we must wrap back up the last wrap
			offset = wrap_opp_offset
			logical_pos_x = wrap_opp_logical_pos_x
			visual_pos_x = wrap_opp_visual_pos_x
			visual_pos_y = visual_target.y
			column = wrap_opp_column
			wrap_opp = true
		}
	}

	c.cursor.offset = offset
	c.cursor.logical_pos = Point{
		x: logical_pos_x
		y: logical_pos_y
	}
	c.cursor.visual_pos = Point{
		x: visual_pos_x
		y: visual_pos_y
	}
	c.cursor.column = column
	c.cursor.wrap_opp = wrap_opp
	return c.cursor
}

@[inline]
fn calc_target_x(target Point, pos_y CoordType) CoordType {
	if pos_y < target.y {
		return coord_type_max
	}
	if pos_y == target.y {
		return target.x
	}
	return CoordType(0)
}

// skip_newline returns an offset past a newline.
//
// If `offset` is right in front of a newline,
// this will return the offset past said newline.
pub fn skip_newline(text []u8, offset int) int {
	mut off := offset
	if off >= text.len {
		return off
	}
	if text[off] == `\r` {
		off += 1
	}
	if off >= text.len {
		return off
	}
	if text[off] == `\n` {
		off += 1
	}
	return off
}

// strip_newline strips a trailing newline from the given text.
pub fn strip_newline(text []u8) []u8 {
	mut len := text.len
	if len > 0 && text[len - 1] == `\n` {
		len--
	}
	if len > 0 && text[len - 1] == `\r` {
		len--
	}
	return text[..len]
}

// Utf8Chars is an iterator over UTF-8 encoded characters.
// Port of crates/stdext/src/unicode/utf8.rs `Utf8Chars`.
//
// This differs from V's own UTF-8 decoding in that it works on unsanitized
// byte slices and transparently replaces invalid UTF-8 sequences with U+FFFD.
//
// This follows ICU's bitmask approach for `U8_NEXT_OR_FFFD` relatively
// closely. This is important for compatibility, because it implements the
// WHATWG recommendation for UTF8 error recovery.
struct Utf8Chars {
	source []u8
mut:
	offset int
}

// new_utf8_chars creates a new Utf8Chars iterator starting at the given `offset`.
fn new_utf8_chars(source []u8, offset int) Utf8Chars {
	return Utf8Chars{
		source: source
		offset: offset
	}
}

// is_empty checks if the source is empty.
fn (it Utf8Chars) is_empty() bool {
	return it.source.len == 0
}

// len returns the length of the source.
fn (it Utf8Chars) len() int {
	return it.source.len
}

// seek sets the offset to continue iterating from.
fn (mut it Utf8Chars) seek(offset int) {
	it.offset = offset
}

// has_next returns true if `next` will return another character.
fn (it Utf8Chars) has_next() bool {
	return it.offset < it.source.len
}

// next returns the next character, or none if the end of the source is reached.
fn (mut it Utf8Chars) next() ?rune {
	if it.offset >= it.source.len {
		return none
	}

	c := it.source[it.offset]
	it.offset += 1

	// Fast-passing ASCII allows this function to be trivially inlined everywhere,
	// as the full decoder is a little too large for that.
	if (c & 0x80) == 0 {
		// UTF8-1 = %x00-7F
		return rune(c)
	}
	return it.next_slow(c)
}

fn (mut it Utf8Chars) next_slow(c u8) rune {
	if it.offset >= it.source.len {
		return fffd()
	}

	mut cp := u32(c)

	if cp < 0xE0 {
		// UTF8-2 = %xC2-DF UTF8-tail

		if cp < 0xC2 {
			return fffd()
		}

		// The lead byte is 110xxxxx
		// -> Strip off the 110 prefix
		cp &= ~u32(0xE0)
	} else if cp < 0xF0 {
		// UTF8-3 =
		//   %xE0    %xA0-BF   UTF8-tail
		//   %xE1-EC UTF8-tail UTF8-tail
		//   %xED    %x80-9F   UTF8-tail
		//   %xEE-EF UTF8-tail UTF8-tail

		// This is a pretty neat approach seen in ICU4C, because it's a 1:1 translation of the RFC.
		// I don't understand why others don't do the same thing. It's rather performant.
		//             v-- lead byte
		// lead byte 0xE0: 0xA0-BF, aka 0b101xxxxx
		// lead byte 0xED: 0x80-9F, aka 0b100xxxxx
		// all others:     both
		lead_trail1_bits := [
			u8(1 << 0b101), // 0xE0
			(1 << 0b100) | (1 << 0b101), // 0xE1
			(1 << 0b100) | (1 << 0b101), // 0xE2
			(1 << 0b100) | (1 << 0b101), // 0xE3
			(1 << 0b100) | (1 << 0b101), // 0xE4
			(1 << 0b100) | (1 << 0b101), // 0xE5
			(1 << 0b100) | (1 << 0b101), // 0xE6
			(1 << 0b100) | (1 << 0b101), // 0xE7
			(1 << 0b100) | (1 << 0b101), // 0xE8
			(1 << 0b100) | (1 << 0b101), // 0xE9
			(1 << 0b100) | (1 << 0b101), // 0xEA
			(1 << 0b100) | (1 << 0b101), // 0xEB
			(1 << 0b100) | (1 << 0b101), // 0xEC
			u8(1 << 0b100), // 0xED
			(1 << 0b100) | (1 << 0b101), // 0xEE
			(1 << 0b100) | (1 << 0b101), // 0xEF
		]

		// The lead byte is 1110xxxx
		// -> Strip off the 1110 prefix
		cp &= ~u32(0xF0)

		t := u32(it.source[it.offset])
		if lead_trail1_bits[int(cp)] & (u8(1) << (t >> 5)) == 0 {
			return fffd()
		}
		cp = (cp << 6) | (t & 0x3F)

		it.offset += 1
		if it.offset >= it.source.len {
			return fffd()
		}
	} else {
		// UTF8-4 =
		//   %xF0    %x90-BF   UTF8-tail UTF8-tail
		//   %xF1-F3 UTF8-tail UTF8-tail UTF8-tail
		//   %xF4    %x80-8F   UTF8-tail UTF8-tail

		// This is similar to the above, but with the indices flipped:
		// The trail byte is the index and the lead byte mask is the value.
		// This is because the split at 0x90 requires more bits than fit into an u8.
		// --------- 0xF4 lead
		// |         ...
		// |   +---- 0xF0 lead
		// v   v
		trail1_lead_bits := [
			u8(0b00000), //
			0b00000, //
			0b00000, //
			0b00000, //
			0b00000, //
			0b00000, //
			0b00000, // trail bytes:
			0b00000, //
			0b11110, // 0x80-8F -> 0x80-8F can be preceded by 0xF1-F4
			0b01111, // 0x90-9F -v
			0b01111, // 0xA0-AF -> 0x90-BF can be preceded by 0xF0-F3
			0b01111, // 0xB0-BF -^
			0b00000, //
			0b00000, //
			0b00000, //
			0b00000, //
		]

		// The lead byte *may* be 11110xxx, but could also be e.g. 11111xxx.
		// -> Only strip off the 1111 prefix
		cp &= ~u32(0xF0)

		// Now we can verify if it's actually <= 0xF4.
		if cp > 4 {
			return fffd()
		}

		t := u32(it.source[it.offset])
		if trail1_lead_bits[int(t >> 4)] & (u8(1) << cp) == 0 {
			return fffd()
		}
		cp = (cp << 6) | (t & 0x3F)

		it.offset += 1
		if it.offset >= it.source.len {
			return fffd()
		}

		// UTF8-tail = %x80-BF
		t2 := u32(it.source[it.offset]) - 0x80 // wraps like Rust's wrapping_sub
		if t2 > 0x3F {
			return fffd()
		}
		cp = (cp << 6) | t2

		it.offset += 1
		if it.offset >= it.source.len {
			return fffd()
		}
	}

	// All branches above check for `if it.offset >= it.source.len`
	// one way or another.
	// UTF8-tail = %x80-BF
	t := u32(it.source[it.offset]) - 0x80 // wraps like Rust's wrapping_sub
	if t > 0x3F {
		return fffd()
	}
	cp = (cp << 6) | t

	it.offset += 1

	// If `cp` wasn't a valid codepoint, we already returned U+FFFD above.
	return rune(cp)
}

// fffd returns the U+FFFD replacement character.
fn fffd() rune {
	return rune(0xFFFD)
}
