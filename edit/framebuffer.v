module main

// Port of crates/edit/src/framebuffer.rs (microsoft/edit).
// A shoddy framebuffer for terminal applications: you draw text/colors into it,
// and it diffs against the previous frame and emits the minimal VT escape
// sequences needed to update the screen.

import math as _

// Same constants as used in the PCG family of RNGs.
const hash_multiplier = u64(6364136223846793005) // Knuth's MMIX multiplier (64-bit)

// The size of our contrast cache table. 1<<8 = 256.
const cache_table_log2_size = 8
const cache_table_size = 1 << cache_table_log2_size
// To index the cache we hash the color and shift down to the top bits.
const cache_table_shift = 64 - cache_table_log2_size

// coord_type_min mirrors Rust's CoordType::MIN (i32::MIN), used for the
// "invalid" cursor sentinel. coord_type_max lives in measurement.v.
const coord_type_min = -coord_type_max - 1

// Standard 16 VT & default foreground/background colors.
enum IndexedColor {
	black
	red
	green
	yellow
	blue
	magenta
	cyan
	white
	bright_black
	bright_red
	bright_green
	bright_yellow
	bright_blue
	bright_magenta
	bright_cyan
	bright_white
	background
	foreground
}



// DEFAULT_THEME is the fallback theme. Matches Windows Terminal's Ottosson theme.
fn default_theme() []StraightRgba {
	return [
		StraightRgba{ value: 0x000000ff }, // Black
		StraightRgba{ value: 0xbe2c21ff }, // Red
		StraightRgba{ value: 0x3fae3aff }, // Green
		StraightRgba{ value: 0xbe9a4aff }, // Yellow
		StraightRgba{ value: 0x204dbeff }, // Blue
		StraightRgba{ value: 0xbb54beff }, // Magenta
		StraightRgba{ value: 0x00a7b2ff }, // Cyan
		StraightRgba{ value: 0xbebebeff }, // White
		StraightRgba{ value: 0x808080ff }, // BrightBlack
		StraightRgba{ value: 0xff3e30ff }, // BrightRed
		StraightRgba{ value: 0x58ea51ff }, // BrightGreen
		StraightRgba{ value: 0xffc944ff }, // BrightYellow
		StraightRgba{ value: 0x2f6affff }, // BrightBlue
		StraightRgba{ value: 0xfc74ffff }, // BrightMagenta
		StraightRgba{ value: 0x00e1f0ff }, // BrightCyan
		StraightRgba{ value: 0xffffffff }, // BrightWhite
		StraightRgba{ value: 0x000000ff }, // Background
		StraightRgba{ value: 0xbebebeff }, // Foreground
	]
}

// Framebuffer is a shoddy framebuffer for terminal applications.
struct Framebuffer {
mut:
	// The color palette.
	indexed_colors []StraightRgba
	// Front and back buffers. Indexed by `frame_counter & 1`.
	buffers [2]Buffer
	// The current frame counter. Increments on every `flip` call.
	frame_counter int
	// The colors used for `contrast()`. Stores [dark, light] unless the
	// palette is recognized as a light theme, in which case they're swapped.
	auto_colors [2]StraightRgba
	// Above this lightness value, we consider a color to be "light".
	auto_color_threshold f32
	// A cache table for previously contrasted colors.
	contrast_colors [cache_table_size]ContrastCache
	background_fill StraightRgba
	foreground_fill StraightRgba
}

// Buffer is one of the two framebuffers (front/back).
struct Buffer {
mut:
	text LineBuffer
	bg_bitmap Bitmap
	fg_bitmap Bitmap
	attributes AttributeBuffer
	cursor FbCursor
}

// FbCursor stores the cursor position and type for the framebuffer.
// NOTE: this is the framebuffer's own Cursor (Rust: framebuffer.rs), which is
// distinct from the measurement Cursor in measurement.v (different fields).
struct FbCursor {
mut:
	pos Point
	overtype bool
}

fn fb_cursor_new_invalid() FbCursor {
	return FbCursor{ pos: Point{ x: coord_type_min, y: coord_type_min }, overtype: false }
}

fn fb_cursor_new_disabled() FbCursor {
	return FbCursor{ pos: Point{ x: -1, y: -1 }, overtype: false }
}

// ContrastCache caches a (color -> contrasted color) pair for the cache table.
struct ContrastCache {
mut:
	color StraightRgba
	result StraightRgba
}

// LineBuffer is a buffer for the text contents of the framebuffer.
struct LineBuffer {
mut:
	lines []string
	size Size
}

fn line_buffer_new(size Size) LineBuffer {
	mut lines := []string{ len: int(size.height) }
	return LineBuffer{ lines: lines, size: size }
}

fn (mut lb LineBuffer) fill_whitespace() {
	width := int(lb.size.width)
	for i in 0..lb.lines.len {
		lb.lines[i] = ' '.repeat(width)
	}
}

// replace_text replaces text contents in a single line of the framebuffer.
// All coordinates are in viewport coordinates. Assumes control characters
// have been sanitized (see sanitize_control_chars).
fn (mut lb LineBuffer) replace_text(y CoordType, origin_x CoordType, clip_right CoordType, text string) {
	if y < 0 || int(y) >= lb.lines.len {
		return
	}
	mut line := lb.lines[int(y)]
	bytes := text.bytes()
	mut cr := clip_right
	if cr < 0 {
		cr = 0
	}
	if cr > lb.size.width {
		cr = lb.size.width
	}
	layout_width := cr - origin_x
	if layout_width <= 0 || bytes.len == 0 {
		return
	}

	mut cfg := new_measurement_config(StringDocument{ text: text })

	// Check if the text intersects with the left edge of the framebuffer
	// and figure out the parts that are inside.
	mut left := origin_x
	if left < 0 {
		mut cursor := cfg.goto_visual(Point{ x: -left, y: 0 })
		if left + cursor.visual_pos.x < 0 && cursor.offset < text.len {
			// `-left` must've intersected a wide glyph; step forward to the next glyph.
			cursor = cfg.goto_logical(Point{ x: cursor.logical_pos.x + 1, y: 0 })
		}
		left += cursor.visual_pos.x
	}

	// If the text still starts outside, or starts past the right edge, nothing to do.
	if left < 0 || left >= cr {
		return
	}

	// Measure the width of the new text (= end.visual_pos.x).
	// NOTE: `beg_off` must be captured *before* goto_visual advances the cursor.
	beg_off := cfg.cursor().offset
	end := cfg.goto_visual(Point{ x: layout_width, y: 0 })
	right := left + end.visual_pos.x

	mut cfg_old := new_measurement_config(StringDocument{ text: line })
	res_old_beg := cfg_old.goto_visual(Point{ x: left, y: 0 })
	mut res_old_end := cfg_old.goto_visual(Point{ x: right, y: 0 })

	// Since goto functions stop short of the target, step beyond it if we
	// intersect with a wide glyph.
	if res_old_end.visual_pos.x < right {
		res_old_end = cfg_old.goto_logical(Point{ x: res_old_end.logical_pos.x + 1, y: 0 })
	}

	src := text[beg_off..end.offset]
	mut overlap_beg := left - res_old_beg.visual_pos.x
	if overlap_beg < 0 {
		overlap_beg = 0
	}
	mut overlap_end := res_old_end.visual_pos.x - right
	if overlap_end < 0 {
		overlap_end = 0
	}

	// Hand-written splice: replace [res_old_beg.offset, res_old_end.offset) in
	// the line with the (possibly space-padded) source text.
	mut new_line := line[0..res_old_beg.offset]
	new_line += ' '.repeat(int(overlap_beg))
	new_line += src
	new_line += ' '.repeat(int(overlap_end))
	new_line += line[res_old_end.offset..line.len]
	lb.lines[int(y)] = new_line
}

// Bitmap is an sRGB bitmap.
struct Bitmap {
mut:
	data []StraightRgba
	size Size
}

fn bitmap_new(size Size) Bitmap {
	mut data := []StraightRgba{ len: int(size.width * size.height) }
	return Bitmap{ data: data, size: size }
}

fn (mut b Bitmap) fill(color StraightRgba) {
	for i in 0..b.data.len {
		b.data[i] = color
	}
}

// blend blends the given sRGB color onto the bitmap (using oklab for blending).
fn (mut b Bitmap) blend(mut target Rect, color StraightRgba) {
	if color.alpha() == 0 {
		return
	}
	target = target.intersect(b.size.as_rect())
	if target.is_empty() {
		return
	}
	top := int(target.top)
	bottom := int(target.bottom)
	left := int(target.left)
	right := int(target.right)
	stride := int(b.size.width)

	for y in top..bottom {
		beg := y * stride + left
		end := y * stride + right
		mut data := b.data[beg..end]

		if color.alpha() == 0xff {
			for i in 0..data.len {
				data[i] = color
			}
		} else {
			mut off := 0
			for {
				c := data[off]
				chunk_beg := off
				for {
					off++
					if off >= data.len {
						break
					}
					if data[off] != c {
						break
					}
				}
				chunk_end := off
				blended := c.oklab_blend(color)
				for i in chunk_beg..chunk_end {
					data[i] = blended
				}
				if off >= data.len {
					break
				}
			}
		}
	}
}

// Attributes is a bitfield for VT text attributes. Being a bitfield allows for
// simple diffing.
struct Attributes {
	value u8
}

const attr_none = Attributes{ value: 0 }
const attr_bold = Attributes{ value: 1 }
const attr_italic = Attributes{ value: 2 }
const attr_underlined = Attributes{ value: 4 }
const attr_strikethrough = Attributes{ value: 8 }
const attr_all = Attributes{ value: 15 }

fn (a Attributes) is(b Attributes) bool {
	return (a.value & b.value) == b.value
}

// AttributeBuffer stores VT attributes for the framebuffer.
struct AttributeBuffer {
mut:
	data []Attributes
	size Size
}

fn attribute_buffer_new(size Size) AttributeBuffer {
	mut data := []Attributes{ len: int(size.width * size.height) }
	return AttributeBuffer{ data: data, size: size }
}

fn (mut ab AttributeBuffer) reset() {
	for i in 0..ab.data.len {
		ab.data[i] = attr_none
	}
}

fn (mut ab AttributeBuffer) replace(mut target Rect, mask Attributes, attr Attributes) {
	target = target.intersect(ab.size.as_rect())
	if target.is_empty() {
		return
	}
	top := int(target.top)
	bottom := int(target.bottom)
	left := int(target.left)
	right := int(target.right)
	stride := int(ab.size.width)

	for y in top..bottom {
		beg := y * stride + left
		end := y * stride + right
		mut dst := ab.data[beg..end]

		if mask == attr_all {
			for i in 0..dst.len {
				dst[i] = attr
			}
		} else {
			for i in 0..dst.len {
				dst[i] = Attributes{ value: dst[i].value & ~mask.value | attr.value }
			}
		}
	}
}

// Range is a byte range, used by sanitized control-char tracking.
struct Range {
	start int
	end int
}

// SanitizedControlChars holds the sanitized text plus the byte ranges of the
// characters that were replaced.
struct SanitizedControlChars {
	text string
	unsane_ranges []Range
	owned bool
}

// framebuffer_new creates a new framebuffer with the default theme.
fn framebuffer_new() Framebuffer {
	theme := default_theme()
	return Framebuffer{
		indexed_colors: theme
		buffers: [Buffer{}, Buffer{}]!
		frame_counter: 0
		auto_colors: [theme[int(IndexedColor.black)], theme[int(IndexedColor.bright_white)]]!
		auto_color_threshold: f32(0.5)
		contrast_colors: [cache_table_size]ContrastCache{}
		background_fill: theme[int(IndexedColor.background)]
		foreground_fill: theme[int(IndexedColor.foreground)]
	}
}

// set_indexed_colors sets the base color palette.
fn (mut fb Framebuffer) set_indexed_colors(colors []StraightRgba) {
	fb.indexed_colors = colors
	fb.background_fill = StraightRgba{ value: 0 }
	fb.foreground_fill = StraightRgba{ value: 0 }

	fb.auto_colors = [colors[int(IndexedColor.black)], colors[int(IndexedColor.bright_white)]]!

	lightness0 := fb.auto_colors[0].as_oklab().lightness()
	lightness1 := fb.auto_colors[1].as_oklab().lightness()
	fb.auto_color_threshold = (lightness0 + lightness1) * f32(0.5)

	// Ensure [0] is dark and [1] is light.
	if lightness0 > lightness1 {
		tmp := fb.auto_colors[0]
		fb.auto_colors[0] = fb.auto_colors[1]
		fb.auto_colors[1] = tmp
	}
}

// flip begins a new frame with the given `size`.
fn (mut fb Framebuffer) flip(size Size) {
	if size != fb.buffers[0].bg_bitmap.size {
		for i in 0..2 {
			fb.buffers[i].text = line_buffer_new(size)
			fb.buffers[i].bg_bitmap = bitmap_new(size)
			fb.buffers[i].fg_bitmap = bitmap_new(size)
			fb.buffers[i].attributes = attribute_buffer_new(size)
		}

		front_idx := int(fb.frame_counter & 1)
		// Trigger a full redraw. (Yes, it's a hack.)
		fb.buffers[front_idx].fg_bitmap.fill(StraightRgba{ value: 0x01000000 })
		// Trigger a cursor update as well, just to be sure.
		fb.buffers[front_idx].cursor = fb_cursor_new_invalid()
	}

	fb.frame_counter++

	back_idx := int(fb.frame_counter & 1)
	mut back := &fb.buffers[back_idx]
	back.text.fill_whitespace()
	back.bg_bitmap.fill(fb.background_fill)
	back.fg_bitmap.fill(fb.foreground_fill)
	back.attributes.reset()
	back.cursor = fb_cursor_new_disabled()
}

// replace_text replaces text contents in a single line of the framebuffer.
// All coordinates are in viewport coordinates. Assumes control characters
// have been replaced or escaped.
fn (mut fb Framebuffer) replace_text(y CoordType, origin_x CoordType, clip_right CoordType, text string) {
	sanitized := sanitize_control_chars(text.bytes())
	idx := int(fb.frame_counter & 1)
	fb.buffers[idx].text.replace_text(y, origin_x, clip_right, sanitized.text)

	if sanitized.owned {
		fb.highlight_sanitized(y, origin_x, clip_right, sanitized)
	}
}

// highlight_sanitized highlights the replacements sanitize_control_chars made,
// in yellow, so that invalid control characters are visible.
fn (mut fb Framebuffer) highlight_sanitized(y CoordType, origin_x CoordType, clip_right CoordType, sanitized SanitizedControlChars) {
	bg := fb.indexed(IndexedColor.yellow)
	fg := fb.contrasted(bg)
	mut cfg := new_measurement_config(StringDocument{ text: sanitized.text })

	for range in sanitized.unsane_ranges {
		// The ranges are sorted, so once we're past the right edge we're done.
		left := origin_x + cfg.goto_offset(range.start).visual_pos.x
		if left >= clip_right {
			break
		}

		right := origin_x + cfg.goto_offset(range.end).visual_pos.x
		rect_left := left
		mut rect_right := right
		if rect_right > clip_right {
			rect_right = clip_right
		}
		mut rect := Rect{ left: rect_left, top: y, right: rect_right, bottom: y + 1 }
		fb.blend_bg(mut rect, bg)
		fb.blend_fg(mut rect, fg)
	}
}

// draw_scrollbar draws a scrollbar in the given `track` rectangle.
fn (mut fb Framebuffer) draw_scrollbar(clip_rect Rect, track Rect, content_offset CoordType, content_height CoordType) CoordType {
	mut track_clipped := track.intersect(clip_rect)
	if track_clipped.is_empty() {
		return 0
	}

	mut viewport_height := i64(track.height())
	mut ch := i64(content_height)
	if ch < viewport_height {
		ch = viewport_height
	}

	// No need to draw a scrollbar if the content fits in the viewport.
	mut content_offset_max := ch - viewport_height
	if content_offset_max == 0 {
		return 0
	}

	// Clamp the content offset to [0, content_offset_max].
	mut co := i64(content_offset)
	if co < 0 {
		co = 0
	}
	if co > content_offset_max {
		co = content_offset_max
	}

	// Use 1/8th blocks for higher visual resolution.
	viewport_height *= 8
	content_offset_max *= 8
	co *= 8
	ch *= 8

	// Proportional thumb height, rounded.
	mut numerator := viewport_height * viewport_height + ch / 2
	mut thumb_height := numerator / ch
	// Ensure a minimum size of 1 row.
	if thumb_height < 8 {
		thumb_height = 8
	}

	// Proportional thumb top position, rounded.
	numerator = (viewport_height - thumb_height) * co + content_offset_max / 2
	mut thumb_top := numerator / content_offset_max
	mut thumb_bottom := thumb_top + thumb_height

	// Shift to absolute coordinates.
	thumb_top += i64(track.top) * 8
	thumb_bottom += i64(track.top) * 8

	// Clamp to the visible area.
	if thumb_top < i64(track_clipped.top) * 8 {
		thumb_top = i64(track_clipped.top) * 8
	}
	if thumb_bottom > i64(track_clipped.bottom) * 8 {
		thumb_bottom = i64(track_clipped.bottom) * 8
	}

	// Height of the top/bottom cell of the thumb, in 1/8ths.
	top_fract := CoordType(thumb_top % 8)
	bottom_fract := CoordType(thumb_bottom % 8)

	// Shift back to absolute (whole) rows.
	thumb_top = (thumb_top + 7) / 8
	thumb_bottom = thumb_bottom / 8

	fb.blend_bg(mut track_clipped, fb.indexed(IndexedColor.bright_black))
	fb.blend_fg(mut track_clipped, fb.indexed(IndexedColor.bright_white))

	// Draw the full blocks.
	for y in thumb_top..thumb_bottom {
		fb.replace_text(CoordType(y), track_clipped.left, track_clipped.right, '█')
	}

	// Draw the top/bottom cell of the thumb with partial blocks.
	// U+2581 to U+2588: ▁▂▃▄▅▆▇█ (1/8th to 8/8th block elements).
	mut fract_buf := [u8(0xE2), 0x96, 0x88]
	if top_fract != 0 {
		fract_buf[2] = u8(0x88 - top_fract)
		fb.replace_text(thumb_top - 1, track_clipped.left, track_clipped.right, fract_buf[0..3].bytestr())
	}
	if bottom_fract != 0 {
		fract_buf[2] = u8(0x88 - bottom_fract)
		fb.replace_text(thumb_bottom, track_clipped.left, track_clipped.right, fract_buf[0..3].bytestr())
		mut rect := Rect{
			left: track_clipped.left
			top: thumb_bottom
			right: track_clipped.right
			bottom: thumb_bottom + 1
		}
		fb.blend_bg(mut rect, fb.indexed(IndexedColor.bright_white))
		fb.blend_fg(mut rect, fb.indexed(IndexedColor.bright_black))
	}

	return CoordType((thumb_height + 4) / 8)
}

// indexed returns a palette color.
fn (fb &Framebuffer) indexed(index IndexedColor) StraightRgba {
	return fb.indexed_colors[int(index)]
}

// indexed_alpha returns a palette color with the given alpha fraction.
fn (fb &Framebuffer) indexed_alpha(index IndexedColor, numerator u32, denominator u32) StraightRgba {
	c := fb.indexed_colors[int(index)].to_rgba()
	a := 255 * numerator / denominator
	return StraightRgba{ value: (c & 0xffffff00) | a }
}

// contrasted returns a color opposite to the brightness of the given `color`.
fn (mut fb Framebuffer) contrasted(color StraightRgba) StraightRgba {
	idx := int((u64(color.to_rgba()) * hash_multiplier) >> cache_table_shift)
	slot := fb.contrast_colors[idx]
	if slot.color == color {
		return slot.result
	}
	return fb.contrasted_slow(color)
}

fn (mut fb Framebuffer) contrasted_slow(color StraightRgba) StraightRgba {
	idx := int((u64(color.to_rgba()) * hash_multiplier) >> cache_table_shift)
	is_dark := color.as_oklab().lightness() < fb.auto_color_threshold
	contrast := fb.auto_colors[int(is_dark)]
	fb.contrast_colors[idx] = ContrastCache{ color: color, result: contrast }
	return contrast
}

// blend_bg blends the given sRGB color onto the background bitmap.
fn (mut fb Framebuffer) blend_bg(mut target Rect, bg StraightRgba) {
	idx := int(fb.frame_counter & 1)
	fb.buffers[idx].bg_bitmap.blend(mut target, bg)
}

// blend_fg blends the given sRGB color onto the foreground bitmap.
fn (mut fb Framebuffer) blend_fg(mut target Rect, fg StraightRgba) {
	idx := int(fb.frame_counter & 1)
	fb.buffers[idx].fg_bitmap.blend(mut target, fg)
}

// reverse reverses the foreground and background colors in the given rectangle.
fn (mut fb Framebuffer) reverse(mut target Rect) {
	idx := int(fb.frame_counter & 1)
	target = target.intersect(fb.buffers[idx].bg_bitmap.size.as_rect())
	if target.is_empty() {
		return
	}
	top := int(target.top)
	bottom := int(target.bottom)
	left := int(target.left)
	right := int(target.right)
	stride := int(fb.buffers[idx].bg_bitmap.size.width)

	for y in top..bottom {
		beg := y * stride + left
		end := y * stride + right
		for i in beg..end {
			bd := fb.buffers[idx].bg_bitmap.data[i]
			fd := fb.buffers[idx].fg_bitmap.data[i]
			fb.buffers[idx].bg_bitmap.data[i] = fd
			fb.buffers[idx].fg_bitmap.data[i] = bd
		}
	}
}

// replace_attr replaces VT attributes in the given rectangle.
fn (mut fb Framebuffer) replace_attr(mut target Rect, mask Attributes, attr Attributes) {
	idx := int(fb.frame_counter & 1)
	fb.buffers[idx].attributes.replace(mut target, mask, attr)
}

// set_cursor sets the current visible cursor position and type.
fn (mut fb Framebuffer) set_cursor(pos Point, overtype bool) {
	idx := int(fb.frame_counter & 1)
	fb.buffers[idx].cursor.pos = pos
	fb.buffers[idx].cursor.overtype = overtype
}

// render renders the framebuffer contents accumulated since the last flip()
// and returns them serialized as VT escape sequences (a diff against the
// previous frame).
fn (fb &Framebuffer) render() string {
	idx := int(fb.frame_counter & 1)
	back := fb.buffers[idx]
	front := fb.buffers[1 - idx]

	width := int(back.bg_bitmap.size.width)
	mut result := ''
	mut last_bg := u64(0xffffffffffffffff)
	mut last_fg := u64(0xffffffffffffffff)
	mut last_attr := Attributes{ value: 0 }

	for y in 0..int(front.text.size.height) {
		front_line := front.text.lines[y]
		front_bg := front.bg_bitmap.data[y * width..(y + 1) * width]
		front_fg := front.fg_bitmap.data[y * width..(y + 1) * width]
		front_attr := front.attributes.data[y * width..(y + 1) * width]
		back_line := back.text.lines[y]
		back_bg := back.bg_bitmap.data[y * width..(y + 1) * width]
		back_fg := back.fg_bitmap.data[y * width..(y + 1) * width]
		back_attr := back.attributes.data[y * width..(y + 1) * width]

		// Only redraw a line if something changed.
		if front_line == back_line && front_bg == back_bg && front_fg == back_fg
			&& front_attr == back_attr {
			continue
		}

		mut cfg := new_measurement_config(StringDocument{ text: back_line })
		mut chunk_end := 0

		if result.len == 0 {
			result += '\x1b[m'
		}
		result += '\x1b[${y + 1};1H'

		for {
			bg := back_bg[chunk_end]
			fg := back_fg[chunk_end]
			attr := back_attr[chunk_end]

			// Chunk into runs of the same color.
			for {
				chunk_end++
				if chunk_end >= back_bg.len {
					break
				}
				if back_bg[chunk_end] != bg || back_fg[chunk_end] != fg
					|| back_attr[chunk_end] != attr {
					break
				}
			}

			if last_bg != u64(bg.to_rgba()) {
				last_bg = u64(bg.to_rgba())
				result = fb.format_color(result, false, bg)
			}

			if last_fg != u64(fg.to_rgba()) {
				last_fg = u64(fg.to_rgba())
				result = fb.format_color(result, true, fg)
			}

			if last_attr != attr {
				diff := Attributes{ value: last_attr.value ^ attr.value }
				if diff.is(attr_bold) {
					if attr.is(attr_bold) {
						result += '\x1b[1m'
					} else {
						result += '\x1b[22m'
					}
				}
				if diff.is(attr_italic) {
					if attr.is(attr_italic) {
						result += '\x1b[3m'
					} else {
						result += '\x1b[23m'
					}
				}
				if diff.is(attr_underlined) {
					if attr.is(attr_underlined) {
						result += '\x1b[4m'
					} else {
						result += '\x1b[24m'
					}
				}
				if diff.is(attr_strikethrough) {
					if attr.is(attr_strikethrough) {
						result += '\x1b[9m'
					} else {
						result += '\x1b[29m'
					}
				}
				last_attr = attr
			}

			beg := cfg.cursor().offset
			end := cfg.goto_visual(Point{ x: CoordType(chunk_end), y: 0 }).offset
			result += back_line[beg..end]

			if chunk_end >= back_bg.len {
				break
			}
		}
	}

	// Update the cursor if needed.
	if result.len > 0 || back.cursor != front.cursor {
		if back.cursor.pos.x >= 0 && back.cursor.pos.y >= 0 {
			// CUP to the cursor position, DECSCUSR for style, DECTCEM to show.
			result += '\x1b[${back.cursor.pos.y + 1};${back.cursor.pos.x + 1}H\x1b[${if back.cursor.overtype { 1 } else { 5 }} q\x1b[?25h'
		} else {
			// DECTCEM to hide the cursor.
			result += '\x1b[?25l'
		}
	}

	return result
}

// format_color writes the escape sequence for the given sRGB color and
// returns the updated output string.
fn (fb &Framebuffer) format_color(dst string, fg bool, color StraightRgba) string {
	typ := if fg { '3' } else { '4' }

	// Transparent (0x00000000) maps to the default terminal color.
	if color.to_rgba() == 0 {
		return dst + '\x1b[${typ}9m'
	}

	mut c := color
	if c.alpha() != 0xff {
		idx := if fg { IndexedColor.foreground } else { IndexedColor.background }
		dst_color := fb.indexed(idx)
		c = dst_color.oklab_blend(c)
	}

	r := c.red()
	g := c.green()
	b := c.blue()
	return dst + '\x1b[${typ}8;2;${r};${g};${b}m'
}

// ---- Control character sanitization ----------------------------------------
// Ports crates/stdext/src/unicode/sanitize.rs `sanitize_control_chars`.
// V uses strings directly instead of the arena/BString optimizations.

// is_unsane reports whether the character at [beg,end) should be visualized.
fn is_unsane(text []u8, beg int, end int, ch rune) bool {
	if ch < rune(0x20) {
		return true
	}
	if ch >= rune(0x7f) && ch <= rune(0x9f) {
		return true
	}
	if ch == rune(0xfffd) {
		// U+FFFD can be a legitimate source character, so only treat it as
		// unsane if the original bytes weren't actually U+FFFD.
		return text[beg..end] != [u8(0xEF), 0xBF, 0xBD]
	}
	return false
}

// visualize returns the Unicode representation of a C0/C1 control character.
fn visualize(ch rune) string {
	if ch != rune(0xfffd) {
		mut buf := [u8(0xE2), 0x96, 0x80]
		if ch <= rune(0x1f) {
			buf[2] = u8(0x80 | u8(ch))
		} else if ch == rune(0x7f) {
			buf[2] = 0xA1
		} else {
			// C1 control characters: U+2426 (no picture glyphs exist).
			buf[2] = 0xA6
		}
		return buf[0..3].bytestr()
	}
	return '\ufffd'
}

// sanitize_control_chars strips all C0/C1 control characters (and replaces
// them with their Unicode representations). It returns the sanitized text and,
// if any replacements were made, the byte ranges of the replacements.
fn sanitize_control_chars(text []u8) SanitizedControlChars {
	if text.len == 0 {
		return SanitizedControlChars{ text: '', unsane_ranges: [], owned: false }
	}

	mut chars := new_utf8_chars(text, 0)
	mut out := ''
	mut ranges := []Range{}
	mut sane_beg := 0
	mut sane_end := 0
	mut ch := rune(0)

	for sane_beg < text.len {
		// Find the next unsane character.
		for {
			sane_end = chars.offset
			ch = chars.next() or { break }
			if is_unsane(text, sane_end, chars.offset, ch) {
				break
			}
		}

		// Everything up to `sane_end` decoded successfully.
		sane := text[sane_beg..sane_end].bytestr()
		if out.len == 0 && sane_end == text.len {
			return SanitizedControlChars{ text: sane, unsane_ranges: [], owned: false }
		}

		out += sane
		if sane_end == text.len {
			break
		}

		unsane_beg := out.len
		for {
			out += visualize(ch)
			sane_beg = chars.offset
			ch = chars.next() or { break }
			if !is_unsane(text, sane_beg, chars.offset, ch) {
				break
			}
		}
		ranges << Range{ start: unsane_beg, end: out.len }
	}

	return SanitizedControlChars{ text: out, unsane_ranges: ranges, owned: true }
}
