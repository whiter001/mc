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
