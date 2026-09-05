module main

// language_picker.v — extracted from main.v.
//
// Status-bar anchored modal listing "Auto Detect" / "Plain Text"
// / 25 lsh languages. Internally the picker uses non-negative
// display positions (0 = Auto, 1 = Plain, 2+ = lsh_languages[i-2]);
// translation to/from the TextBuffer.language encoding
// (-2 = auto, -1 = plain, 0..N = language) happens only at apply /
// current time, so scrolling and hit-testing stay consistent across
// the render loop, mouse handler, and keyboard handler.
//
// Geometry mirrors draw_indent_picker: anchored to the language
// button's right edge, clamped above the menu bar, the whole panel
// reverse-videoed and the selected row double-reversed to read as
// a highlight.
//
// State lives on the Editor struct in main.v (language_picker,
// language_picker_sel, language_picker_scroll,
// language_picker_explicit).

const language_picker_width = CoordType(24)

// Display-position indices used by the language picker itself.
// Position 0 is the Auto Detect row, 1 is Plain Text, and 2+ map
// to lsh_languages[i-2].
const language_picker_pos_auto = 0
const language_picker_pos_plain = 1

// language_picker_count returns the number of entries: Auto
// Detect, Plain Text, and the 25 lsh_languages.
fn (ed &Editor) language_picker_count() int {
	return 2 + lsh_languages.len
}

// language_picker_label returns the display label for a
// display-position index.
fn (ed &Editor) language_picker_label(pos int) string {
	match pos {
		language_picker_pos_auto { return 'Auto Detect' }
		language_picker_pos_plain { return 'Plain Text' }
		else {
			lang_idx := pos - 2
			if lang_idx < 0 || lang_idx >= lsh_languages.len {
				return ''
			}
			return lsh_languages[lang_idx].name
		}
	}
}

// language_picker_current returns the display-position index that
// corresponds to the buffer's current effective language, used
// to seed the picker.
fn (ed &Editor) language_picker_current() int {
	if ed.language_picker_explicit == -2 {
		// Auto: seed with whatever the buffer actually shows right now.
		lang := ed.docs[ed.active].buf.language()
		if lang < 0 {
			return language_picker_pos_plain
		}
		return lang + 2
	}
	if ed.language_picker_explicit == -1 {
		return language_picker_pos_plain
	}
	lang_idx := ed.language_picker_explicit
	if lang_idx < 0 || lang_idx >= lsh_languages.len {
		return language_picker_pos_plain
	}
	return lang_idx + 2
}

// language_picker_rect returns the modal Rect, anchored to the
// language button's right edge with width 24 columns.
fn (ed &Editor) language_picker_rect() Rect {
	width := language_picker_width
	mut left := CoordType(0)
	for btn in ed.compute_status_buttons() {
		if btn.kind == .language {
			left = btn.right - width
		}
	}
	if left < 0 {
		left = 0
	}
	if left + width > ed.size.width {
		left = ed.size.width - width
	}
	if left < 0 {
		left = 0
	}
	return Rect{
		left:   left
		top:    0 // recomputed by draw_language_picker from status_y
		right:  left + width
		bottom: 0
	}
}

// language_picker_list_height returns the number of entries that
// fit between the menu bar (row 0) and the status bar, capped at
// the total entry count.
fn (ed &Editor) language_picker_list_height(status_y CoordType) int {
	// The block starts at status_y - height; clamp top >= 1 so it
	// never overlaps the menu bar. The +1 on height reserves a
	// one-row header strip (used here as the title row; visible
	// entries are height - 1).
	max_rows := status_y - 1
	if max_rows < 1 {
		return 1
	}
	total := ed.language_picker_count()
	return int(coord_min(CoordType(total), max_rows))
}

// language_picker_clamp_scroll keeps the selection visible inside
// the list.
fn (mut ed Editor) language_picker_clamp_scroll(list_h int) {
	if list_h <= 0 {
		ed.language_picker_scroll = 0
		return
	}
	if ed.language_picker_sel < ed.language_picker_scroll {
		ed.language_picker_scroll = ed.language_picker_sel
	}
	if ed.language_picker_sel >= ed.language_picker_scroll + list_h {
		ed.language_picker_scroll = ed.language_picker_sel - list_h + 1
	}
}

// open_language_picker opens the language picker modal and seeds
// the selection with the buffer's current effective language.
fn (mut ed Editor) open_language_picker() {
	ed.language_picker = true
	ed.language_picker_sel = ed.language_picker_current()
	ed.language_picker_scroll = 0
	ed.language_picker_clamp_scroll(ed.language_picker_list_height(ed.size
		.height - 1))
}

// language_picker_apply applies a picked display-position index to
// the buffer. Translates the position to the TextBuffer.language
// encoding (-2/-1/0..N) so the rest of the editor keeps treating
// language as a single int.
fn (mut ed Editor) language_picker_apply(pos int) {
	mut b := &ed.docs[ed.active].buf
	match pos {
		language_picker_pos_auto {
			ed.language_picker_explicit = -2
			// Auto-detect from the active document's path; untitled
			// buffers fall back to plain text (no extension to match).
			path := ed.cur().path
			detected := if path == '' { -1 } else { lsh_language_for_path(path) }
			b.set_language(detected)
		}
		language_picker_pos_plain {
			ed.language_picker_explicit = -1
			b.set_language(-1)
		}
		else {
			lang_idx := pos - 2
			if lang_idx < 0 || lang_idx >= lsh_languages.len {
				ed.language_picker_explicit = -1
				b.set_language(-1)
				return
			}
			ed.language_picker_explicit = lang_idx
			b.set_language(lang_idx)
		}
	}
}

// handle_language_picker_key processes a keyboard event while
// the language picker is open.
fn (mut ed Editor) handle_language_picker_key(key InputKey) {
	mods := u32(key) & kbmod_mask
	vk := u32(key) & vk_mask
	status_y := ed.size.height - 1
	list_h := ed.language_picker_list_height(status_y)
	total := ed.language_picker_count()
	match vk {
		vk_escape {
			ed.language_picker = false
		}
		vk_up {
			if mods == kbmod_none || mods == kbmod_shift {
				if ed.language_picker_sel > 0 {
					ed.language_picker_sel--
				}
				ed.language_picker_clamp_scroll(list_h)
			}
		}
		vk_down {
			if mods == kbmod_none || mods == kbmod_shift {
				if ed.language_picker_sel + 1 < total {
					ed.language_picker_sel++
				}
				ed.language_picker_clamp_scroll(list_h)
			}
		}
		vk_home {
			ed.language_picker_sel = 0
			ed.language_picker_clamp_scroll(list_h)
		}
		vk_end {
			ed.language_picker_sel = total - 1
			ed.language_picker_clamp_scroll(list_h)
		}
		vk_prior {
			if mods == kbmod_none {
				mut step := list_h
				if step <= 0 {
					step = 1
				}
				ed.language_picker_sel -= step
				if ed.language_picker_sel < 0 {
					ed.language_picker_sel = 0
				}
				ed.language_picker_clamp_scroll(list_h)
			}
		}
		vk_next {
			if mods == kbmod_none {
				mut step := list_h
				if step <= 0 {
					step = 1
				}
				ed.language_picker_sel += step
				if ed.language_picker_sel >= total {
					ed.language_picker_sel = total - 1
				}
				ed.language_picker_clamp_scroll(list_h)
			}
		}
		vk_return {
			if mods == kbmod_none {
				sel := ed.language_picker_sel
				ed.language_picker_apply(sel)
				ed.language_picker = false
			}
		}
		else {}
	}
}

// handle_language_picker_mouse processes a click inside the
// language picker. A click on a row activates it (mirrors Rust
// ListSelection::Activated and the goto_file modal's
// click-to-activate behavior).
fn (mut ed Editor) handle_language_picker_mouse(mouse InputMouse) {
	if mouse.state != .left || mouse.drag {
		return
	}
	status_y := ed.size.height - 1
	width := language_picker_width
	mut left := CoordType(0)
	for btn in ed.compute_status_buttons() {
		if btn.kind == .language {
			left = btn.right - width
		}
	}
	if left < 0 {
		left = 0
	}
	if left + width > ed.size.width {
		left = ed.size.width - width
	}
	if left < 0 {
		left = 0
	}
	height := ed.language_picker_list_height(status_y) + 1 // title row + list
	mut top := status_y - height
	if top < 1 {
		top = 1
	}
	if mouse.position.x < left || mouse.position.x >= left + width {
		return
	}
	if mouse.position.y < top + 1 || mouse.position.y >= top + height {
		return
	}
	pos := ed.language_picker_scroll + int(mouse.position.y - (top + 1))
	if pos < 0 || pos >= ed.language_picker_count() {
		return
	}
	ed.language_picker_sel = pos
	ed.language_picker_apply(pos)
	ed.language_picker = false
}

// draw_language_picker renders the language picker anchored above
// the status bar. The top row is the title " Language " (reverse),
// followed by up to `list_h` entries with the selected row
// highlighted.
fn (mut ed Editor) draw_language_picker(status_y CoordType) {
	width := language_picker_width
	mut left := CoordType(0)
	for btn in ed.compute_status_buttons() {
		if btn.kind == .language {
			left = btn.right - width
		}
	}
	if left < 0 {
		left = 0
	}
	if left + width > ed.size.width {
		left = ed.size.width - width
	}
	if left < 0 {
		left = 0
	}
	list_h := ed.language_picker_list_height(status_y)
	height := list_h + 1
	mut top := status_y - height
	if top < 1 {
		top = 1
	}
	ed.language_picker_clamp_scroll(list_h)

	// Whole panel reverse-videoed.
	ed.fb.reverse(mut Rect{
		left:   left
		top:    top
		right:  left + width
		bottom: top + height
	})

	// Title row.
	mut title_row := Rect{
		left:   left
		top:    top
		right:  left + width
		bottom: top + 1
	}
	ed.fb.replace_text(top, left, left + width, picker_fit_line(' Language ', width))
	ed.fb.reverse(mut title_row)

	// Entries.
	for i in 0 .. list_h {
		idx := ed.language_picker_scroll + i
		if idx >= ed.language_picker_count() {
			break
		}
		y := top + 1 + CoordType(i)
		label := ' ${ed.language_picker_label(idx)} '
		ed.fb.replace_text(y, left, left + width, picker_fit_line(label, width))
		mut item_row := Rect{
			left:   left
			top:    y
			right:  left + width
			bottom: y + 1
		}
		ed.fb.reverse(mut item_row)
		if idx == ed.language_picker_sel {
			// Double-reverse = normal colors, reads as a highlight.
			ed.fb.reverse(mut item_row)
		}
	}
}
