module main

// framebuffer_test.v — tests for the V port of crates/edit/src/framebuffer.rs.
//
// Covers replace_text clipping & wide-character handling, the effects of
// blend_bg/blend_fg/reverse/replace_attr, draw_scrollbar staying in bounds,
// and the render() diff between adjacent frames.

fn test_fb_replace_text_basic() {
	mut fb := framebuffer_new()
	fb.flip(Size{ width: 20, height: 5 })
	idx := int(fb.frame_counter & 1)

	// Basic insertion: the rest of the line stays as whitespace.
	fb.replace_text(0, 0, 20, 'hello')
	assert fb.buffers[idx].text.lines[0] == 'hello' + ' '.repeat(15)

	// Text longer than clip_right is truncated.
	fb.replace_text(1, 0, 10, 'abcdefghijklmnop')
	assert fb.buffers[idx].text.lines[1] == 'abcdefghij' + ' '.repeat(10)

	// Text starting at/after the right edge is not inserted at all.
	fb.replace_text(2, 15, 10, 'x')
	assert fb.buffers[idx].text.lines[2] == ' '.repeat(20)

	// Out-of-range lines are ignored (no panic).
	fb.replace_text(99, 0, 20, 'x')
	fb.replace_text(-1, 0, 20, 'x')
	assert fb.buffers[idx].text.lines.len == 5
}

fn test_fb_replace_text_wide() {
	mut fb := framebuffer_new()
	fb.flip(Size{ width: 20, height: 5 })
	idx := int(fb.frame_counter & 1)

	// '界' is a wide (width 2) character; everything fits in 4 columns.
	fb.replace_text(0, 0, 10, 'a界b')
	assert fb.buffers[idx].text.lines[0] == 'a界b' + ' '.repeat(16)

	// Clipping at the right edge: 'b' doesn't fit into 3 columns.
	fb.replace_text(1, 0, 3, 'a界b')
	assert fb.buffers[idx].text.lines[1] == 'a界' + ' '.repeat(17)

	// Clipping inside a wide glyph: only 'a' fits into 2 columns.
	fb.replace_text(2, 0, 2, 'a界b')
	assert fb.buffers[idx].text.lines[2].starts_with('a')
	assert fb.buffers[idx].text.lines[2].len == 20
}

fn test_fb_blend_bg_fg() {
	mut fb := framebuffer_new()
	fb.flip(Size{ width: 10, height: 5 })
	idx := int(fb.frame_counter & 1)
	orig_bg := fb.buffers[idx].bg_bitmap.data[0].to_rgba()
	orig_fg := fb.buffers[idx].fg_bitmap.data[0].to_rgba()

	// Opaque blends overwrite the cells inside the rect.
	mut rect := Rect{ left: 2, top: 1, right: 5, bottom: 3 }
	fb.blend_bg(mut rect, StraightRgba{ value: 0xff0000ff })
	fb.blend_fg(mut rect, StraightRgba{ value: 0x00ff00ff })

	assert fb.buffers[idx].bg_bitmap.data[1 * 10 + 2].to_rgba() == 0xff0000ff
	assert fb.buffers[idx].bg_bitmap.data[2 * 10 + 4].to_rgba() == 0xff0000ff
	assert fb.buffers[idx].fg_bitmap.data[1 * 10 + 2].to_rgba() == 0x00ff00ff

	// Cells outside the rect are untouched.
	assert fb.buffers[idx].bg_bitmap.data[0].to_rgba() == orig_bg
	assert fb.buffers[idx].fg_bitmap.data[4 * 10 + 9].to_rgba() == orig_fg

	// A rect partially outside the framebuffer is clipped.
	mut partial := Rect{ left: 8, top: 0, right: 12, bottom: 1 }
	fb.blend_bg(mut partial, StraightRgba{ value: 0xff0000ff })
	assert fb.buffers[idx].bg_bitmap.data[0 * 10 + 9].to_rgba() == 0xff0000ff
	assert fb.buffers[idx].bg_bitmap.data[0 * 10 + 7].to_rgba() == orig_bg

	// A rect fully outside the framebuffer changes nothing.
	mut outside := Rect{ left: 20, top: 20, right: 22, bottom: 22 }
	fb.blend_bg(mut outside, StraightRgba{ value: 0xff0000ff })
	assert fb.buffers[idx].bg_bitmap.data[4 * 10 + 9].to_rgba() == orig_bg

	// A fully transparent blend changes nothing.
	mut trans := Rect{ left: 0, top: 0, right: 10, bottom: 1 }
	fb.blend_bg(mut trans, StraightRgba{ value: 0x00ff0000 })
	assert fb.buffers[idx].bg_bitmap.data[0].to_rgba() == orig_bg

	// A semi-transparent blend produces a color distinct from both inputs.
	mut semi := Rect{ left: 0, top: 4, right: 2, bottom: 5 }
	fb.blend_bg(mut semi, StraightRgba{ value: 0xffffff80 })
	blended := fb.buffers[idx].bg_bitmap.data[4 * 10 + 0].to_rgba()
	assert blended != orig_bg
	assert blended != 0xffffff80
}

fn test_fb_reverse() {
	mut fb := framebuffer_new()
	fb.flip(Size{ width: 10, height: 5 })
	idx := int(fb.frame_counter & 1)

	mut rect := Rect{ left: 1, top: 1, right: 4, bottom: 2 }
	fb.blend_bg(mut rect, StraightRgba{ value: 0x112233ff })
	fb.blend_fg(mut rect, StraightRgba{ value: 0xaabbccff })

	bg_before := fb.buffers[idx].bg_bitmap.data[1 * 10 + 1].to_rgba()
	fg_before := fb.buffers[idx].fg_bitmap.data[1 * 10 + 1].to_rgba()

	mut rev := Rect{ left: 1, top: 1, right: 4, bottom: 2 }
	fb.reverse(mut rev)

	// Foreground and background are swapped inside the rect...
	assert fb.buffers[idx].bg_bitmap.data[1 * 10 + 1].to_rgba() == fg_before
	assert fb.buffers[idx].fg_bitmap.data[1 * 10 + 1].to_rgba() == bg_before

	// ...and untouched outside of it.
	assert fb.buffers[idx].bg_bitmap.data[0].to_rgba() == 0x000000ff
	assert fb.buffers[idx].fg_bitmap.data[0].to_rgba() == 0xbebebeff
}

fn test_fb_replace_attr() {
	mut fb := framebuffer_new()
	fb.flip(Size{ width: 10, height: 5 })
	idx := int(fb.frame_counter & 1)

	mut rect := Rect{ left: 2, top: 0, right: 6, bottom: 1 }
	fb.replace_attr(mut rect, attr_all, attr_bold)

	assert fb.buffers[idx].attributes.data[0 * 10 + 2].value == 1
	assert fb.buffers[idx].attributes.data[0 * 10 + 5].value == 1
	// Outside the rect: untouched (none).
	assert fb.buffers[idx].attributes.data[0 * 10 + 0].value == 0
	assert fb.buffers[idx].attributes.data[1 * 10 + 2].value == 0

	// A partial mask only sets the requested bits.
	mut rect2 := Rect{ left: 0, top: 2, right: 3, bottom: 3 }
	fb.replace_attr(mut rect2, attr_underlined, attr_underlined)
	assert fb.buffers[idx].attributes.data[2 * 10 + 1].value == 4
	assert fb.buffers[idx].attributes.data[2 * 10 + 1].is(attr_underlined)
	assert !fb.buffers[idx].attributes.data[2 * 10 + 1].is(attr_bold)
}

fn test_fb_draw_scrollbar() {
	mut fb := framebuffer_new()
	fb.flip(Size{ width: 20, height: 10 })
	idx := int(fb.frame_counter & 1)
	orig_bg := fb.buffers[idx].bg_bitmap.data[0].to_rgba() // 0x000000ff

	// Content fits in the viewport: no scrollbar is drawn.
	track_fit := Rect{ left: 18, top: 0, right: 20, bottom: 10 }
	r := fb.draw_scrollbar(track_fit, track_fit, 0, 10)
	assert r == 0
	assert fb.buffers[idx].bg_bitmap.data[0 * 20 + 18].to_rgba() == orig_bg

	// Content exceeds the viewport: a thumb is drawn inside the track.
	mut track := Rect{ left: 18, top: 0, right: 20, bottom: 10 }
	r2 := fb.draw_scrollbar(track, track, 0, 100)
	assert r2 >= 1

	// The whole track got the bright-black background...
	assert fb.buffers[idx].bg_bitmap.data[0 * 20 + 18].to_rgba() == 0x808080ff
	assert fb.buffers[idx].bg_bitmap.data[9 * 20 + 19].to_rgba() == 0x808080ff
	// ...while everything outside the track is untouched.
	assert fb.buffers[idx].bg_bitmap.data[0 * 20 + 17].to_rgba() == orig_bg
	assert fb.buffers[idx].bg_bitmap.data[5 * 20 + 16].to_rgba() == orig_bg

	// The thumb block is drawn at the top (content_offset = 0).
	assert fb.buffers[idx].text.lines[0] == ' '.repeat(18) + '█' + ' '
	// Every line stays well-formed (nothing drawn out of bounds).
	for y in 0..10 {
		assert fb.buffers[idx].text.lines[y].len >= 18
	}
}

fn test_fb_draw_scrollbar_clipped() {
	// A clip rect that only covers part of the track: the scrollbar may not
	// paint outside of the clip area.
	mut fb := framebuffer_new()
	fb.flip(Size{ width: 20, height: 10 })
	idx := int(fb.frame_counter & 1)

	mut clip := Rect{ left: 18, top: 2, right: 20, bottom: 8 }
	track := Rect{ left: 18, top: 0, right: 20, bottom: 10 }
	fb.draw_scrollbar(clip, track, 0, 100)

	// Outside the clip area (but inside the track): untouched.
	assert fb.buffers[idx].bg_bitmap.data[0 * 20 + 18].to_rgba() == 0x000000ff
	assert fb.buffers[idx].bg_bitmap.data[9 * 20 + 18].to_rgba() == 0x000000ff
	// Inside the clip area: the track background is painted.
	assert fb.buffers[idx].bg_bitmap.data[4 * 20 + 18].to_rgba() == 0x808080ff
	assert fb.buffers[idx].bg_bitmap.data[7 * 20 + 19].to_rgba() == 0x808080ff
}

fn test_fb_render_first_frame_nonempty() {
	mut fb := framebuffer_new()
	fb.flip(Size{ width: 20, height: 5 })
	fb.replace_text(0, 0, 20, 'hello')

	out := fb.render()
	assert out.len > 0
	assert out.starts_with('\x1b[m')
	assert out.contains('\x1b[1;1H')
	assert out.contains('hello')
}

fn test_fb_render_diff_is_small() {
	mut fb := framebuffer_new()
	fb.flip(Size{ width: 20, height: 5 })
	fb.replace_text(0, 0, 20, 'hello')
	fb.replace_text(2, 0, 20, 'world')
	fb.render() // discard the initial full frame

	// Identical content: the next frame emits nothing at all.
	fb.flip(Size{ width: 20, height: 5 })
	fb.replace_text(0, 0, 20, 'hello')
	fb.replace_text(2, 0, 20, 'world')
	out := fb.render()
	assert out == ''

	// Only line 3 changes: only that line is emitted.
	fb.flip(Size{ width: 20, height: 5 })
	fb.replace_text(0, 0, 20, 'hello')
	fb.replace_text(2, 0, 20, 'world!')
	out2 := fb.render()
	assert out2.len > 0
	assert out2.contains('\x1b[3;1H')
	assert !out2.contains('\x1b[1;1H')
}

// ---- is_unsane / visualize / sanitize_control_chars ------------------
//
// These three helpers live in framebuffer.v but don't touch any
// Framebuffer state — they map an input byte stream to a UTF-8
// visualization plus a list of byte ranges the caller should
// re-color. The Rust port is in render.rs; the tests below pin the
// boundary semantics (which control characters get replaced, how
// U+FFFD is treated, and the borrowed-vs-owned string flag).

fn test_is_unsane_c0_and_del() {
	// All C0 controls (0x00..0x1F) are unsane.
	for ch in [rune(0x00), rune(0x01), rune(0x0a), rune(0x1f)] {
		assert is_unsane([]u8{}, 0, 0, ch)
	}
	// DEL is unsane.
	assert is_unsane([]u8{}, 0, 0, rune(0x7f))
}

fn test_is_unsane_c1_range() {
	// All C1 controls (0x80..0x9F) are unsane.
	for ch in [rune(0x80), rune(0x8a), rune(0x9f)] {
		assert is_unsane([]u8{}, 0, 0, ch)
	}
}

fn test_is_unsane_printable_ascii_is_sane() {
	// Plain ASCII letters, digits, and printable symbols are sane.
	for ch in [`a`, `Z`, `0`, `9`, ` `, `!`] {
		assert !is_unsane([]u8{}, 0, 0, ch)
	}
}

fn test_is_unsane_fffd_only_when_decoded_from_invalid_bytes() {
	// U+FFFD from valid UTF-8 (the 3-byte sequence 0xEF 0xBF 0xBD)
	// is treated as a legitimate source character and stays sane.
	valid_fffd := [u8(0xEF), 0xBF, 0xBD]
	assert !is_unsane(valid_fffd, 0, valid_fffd.len, rune(0xFFFD))
	// The same rune from a single 0xEF byte (or any other invalid
	// sequence) is the decoder's replacement and is unsane.
	assert is_unsane([u8(0xEF)], 0, 1, rune(0xFFFD))
	assert is_unsane([]u8{}, 0, 0, rune(0xFFFD))
}

fn test_is_unsane_high_unicode_is_sane() {
	// CJK, emoji, combining marks all pass through as sane.
	for ch in [rune(0x4e2d), rune(0x1F600), rune(0x0301)] {
		assert !is_unsane([]u8{}, 0, 0, ch)
	}
}

fn test_visualize_c0_to_block_glyph() {
	// C0 controls map to U+2580..U+259F — the upper-half through
	// quadrant-and-three-quarters block glyphs.
	assert visualize(rune(0x00)) == '\u2580' // upper half block
	assert visualize(rune(0x01)) == '\u2581' // lower one eighth block
	assert visualize(rune(0x1f)) == '\u259F' // quadrant upper right and lower left and lower right
}

fn test_visualize_del_and_c1() {
	// DEL (0x7F) and C1 controls (0x80..0x9F) use different glyphs.
	assert visualize(rune(0x7f)) == '\u25A1' // white square
	assert visualize(rune(0x80)) == '\u25A6' // square with horizontal fill
	assert visualize(rune(0x9f)) == '\u25A6'
}

fn test_visualize_fffd_passes_through() {
	// U+FFFD renders as itself so the caller can replace an
	// already-replaced byte with the same glyph.
	assert visualize(rune(0xFFFD)) == '\uFFFD'
}

fn test_sanitize_control_chars_empty_input() {
	res := sanitize_control_chars([]u8{})
	assert res.text == ''
	assert res.unsane_ranges.len == 0
	assert res.owned == false
}

fn test_sanitize_control_chars_all_sane_passes_through() {
	// All-sane input is returned without an allocation: `owned`
	// is false so the caller knows it can borrow without freeing.
	res := sanitize_control_chars('hello world'.bytes())
	assert res.text == 'hello world'
	assert res.unsane_ranges.len == 0
	assert res.owned == false
}

fn test_sanitize_control_chars_replaces_c0() {
	// A single LF at the start is replaced with the U+258A glyph
	// (LF is byte 0x0A; the C0 glyph is U+2580 | byte).
	res := sanitize_control_chars('\nhi'.bytes())
	assert res.text.len > 2
	assert res.text[0..3] == '\u258A'
	assert res.text[3..] == 'hi'
	assert res.unsane_ranges.len == 1
	assert res.unsane_ranges[0].start == 0
	assert res.unsane_ranges[0].end == 3
	assert res.owned == true
}

fn test_sanitize_control_chars_replaces_del() {
	// DEL (0x7F) becomes the white-square glyph U+25A1.
	res := sanitize_control_chars([u8(`a`), 0x7f, u8(`b`)])
	assert res.text == 'a\u25A1b'
	assert res.unsane_ranges.len == 1
	assert res.unsane_ranges[0].start == 1
	assert res.unsane_ranges[0].end == 4
}

fn test_sanitize_control_chars_replaces_invalid_byte_runs() {
	// Raw 0x80 is an invalid UTF-8 start byte, so utf8_chars yields
	// U+FFFD for it. is_unsane then sees an FFFD that wasn't backed
	// by the real FFFD byte sequence and replaces it with the FFFD
	// visualization. The end result is two consecutive FFFD bytes
	// collapsed into a single FFFD in the output.
	res := sanitize_control_chars([u8(`a`), 0x80, u8(`b`)])
	assert res.text == 'a\uFFFDb'
	assert res.unsane_ranges.len == 1
}

fn test_sanitize_control_chars_keeps_legitimate_fffd() {
	// A genuinely-encoded U+FFFD stays as-is and does not show up
	// in unsane_ranges (it's already a printable glyph).
	res := sanitize_control_chars([u8(`a`), 0xEF, 0xBF, 0xBD, u8(`b`)])
	assert res.text == 'a\uFFFDb'
	assert res.unsane_ranges.len == 0
}

fn test_sanitize_control_chars_groups_consecutive_unsane() {
	// Two consecutive control chars share a single range, not two.
	res := sanitize_control_chars([u8(`a`), 0x01, 0x02, u8(`b`)])
	assert res.text == 'a\u2581\u2582b'
	// Just one range covers both glyphs.
	assert res.unsane_ranges.len == 1
	assert res.unsane_ranges[0].start == 1
	assert res.unsane_ranges[0].end == 7
}
