module main

import os

// open_goto_file opens the document switcher modal.
fn (mut ed Editor) open_goto_file() {
	if ed.docs.len == 0 {
		return
	}
	ed.goto_file = true
	ed.goto_file_filter = ''
	ed.goto_file_compute_filtered()
	// 初始 sel 指向当前 active doc 在 filtered 里的位置；找不到则 0
	ed.goto_file_sel = 0
	for i, idx in ed.goto_file_filtered {
		if idx == ed.active {
			ed.goto_file_sel = i
			break
		}
	}
	ed.goto_file_scroll = 0
	ed.goto_file_clamp_scroll()
}

// goto_file_compute_filtered rebuilds goto_file_filtered from the current
// filter: case-insensitive substring on the document path, or the stable
// display name for untitled documents. An empty filter is a no-op and yields
// the full list in ed.docs order.
fn (mut ed Editor) goto_file_compute_filtered() {
	ed.goto_file_filtered = []int{cap: ed.docs.len}
	needle := ed.goto_file_filter.to_lower()
	for i in 0 .. ed.docs.len {
		doc := ed.docs[i]
		// Keep filtering aligned with the label rendered in the list. Named
		// documents remain searchable by their full path; untitled documents
		// use their stable display name (e.g. `Untitled-1.txt`).
		hay := (if doc.path == '' { ed.document_display_name(&doc) } else { doc.path }).to_lower()
		if needle == '' || hay.contains(needle) {
			ed.goto_file_filtered << i
		}
	}
}

fn (ed &Editor) goto_file_rect() Rect {
	w := coord_min(coord_max(ed.size.width - 20, 10), ed.size.width)
	h := coord_min(coord_max(ed.size.height - 10, 10), ed.size.height)
	left := (ed.size.width - w) / 2
	top := (ed.size.height - h) / 2
	return Rect{
		left: left
		top: top
		right: left + w
		bottom: top + h
	}
}

fn (ed &Editor) goto_file_list_height() int {
	r := ed.goto_file_rect()
	// Two rows are reserved: title (r.top) and filter editline (r.top+1).
	return int(coord_max(r.bottom - r.top - 2, 0))
}

fn (mut ed Editor) goto_file_clamp_scroll() {
	list_h := ed.goto_file_list_height()
	n := ed.goto_file_filtered.len
	if ed.goto_file_sel < ed.goto_file_scroll {
		ed.goto_file_scroll = ed.goto_file_sel
	}
	if list_h > 0 && ed.goto_file_sel >= ed.goto_file_scroll + list_h {
		ed.goto_file_scroll = ed.goto_file_sel - list_h + 1
	}
	if ed.goto_file_scroll > n {
		ed.goto_file_scroll = if n > 0 { n - 1 } else { 0 }
	}
}

// goto_file_has_scrollbar reports whether the document list overflows the
// modal, in which case the rightmost column is reserved for a scrollbar.
fn (ed &Editor) goto_file_has_scrollbar() bool {
	return ed.goto_file_filtered.len > ed.goto_file_list_height()
}

// goto_file_list_right returns the exclusive right edge of the list rows,
// leaving room for the scrollbar when there is one.
fn (ed &Editor) goto_file_list_right() CoordType {
	r := ed.goto_file_rect()
	if ed.goto_file_has_scrollbar() {
		return r.right - 1
	}
	return r.right
}

fn (ed &Editor) goto_file_entry_text(idx int) string {
	if idx < 0 || idx >= ed.docs.len {
		return ''
	}
	doc := ed.docs[idx]
	label := if doc.path == '' { ed.document_display_name(&doc) } else { doc.path }
	mark := if doc.buf.is_dirty() { '* ' } else { '  ' }
	return mark + label
}

// goto_file_entry_dir returns the directory portion of doc idx's path,
// suitable for right-aligned italic display next to the filename. Returns
// '' when the path is empty or has no meaningful parent.
fn (ed &Editor) goto_file_entry_dir(idx int) string {
	if idx < 0 || idx >= ed.docs.len {
		return ''
	}
	doc := ed.docs[idx]
	if doc.path == '' {
		return ''
	}
	dir := os.dir(doc.path)
	if dir == '' || dir == '.' || dir == '/' {
		return ''
	}
	return dir
}

fn (mut ed Editor) goto_file_activate() {
	if ed.goto_file_sel < 0 || ed.goto_file_sel >= ed.goto_file_filtered.len {
		return
	}
	ed.active = ed.goto_file_filtered[ed.goto_file_sel]
	ed.goto_file = false
	ed.reset_view_state()
}

fn (mut ed Editor) handle_goto_file_key(key InputKey) {
	mods := u32(key) & kbmod_mask
	vk := u32(key) & vk_mask
	match vk {
		vk_escape {
			if ed.goto_file_filter.len > 0 {
				ed.goto_file_filter = ''
				ed.goto_file_compute_filtered()
				ed.goto_file_sel = 0
				ed.goto_file_scroll = 0
			} else {
				ed.goto_file = false
			}
		}
		vk_up {
			if ed.goto_file_sel > 0 {
				ed.goto_file_sel--
				ed.goto_file_clamp_scroll()
			}
		}
		vk_down {
			if ed.goto_file_sel + 1 < ed.goto_file_filtered.len {
				ed.goto_file_sel++
				ed.goto_file_clamp_scroll()
			}
		}
		vk_home {
			ed.goto_file_sel = 0
			ed.goto_file_clamp_scroll()
		}
		vk_end {
			if ed.goto_file_filtered.len > 0 {
				ed.goto_file_sel = ed.goto_file_filtered.len - 1
			} else {
				ed.goto_file_sel = 0
			}
			ed.goto_file_clamp_scroll()
		}
		vk_prior {
			if mods == kbmod_none && ed.goto_file_sel > 0 {
				step := ed.goto_file_list_height()
				if step > 0 {
					ed.goto_file_sel -= step
					if ed.goto_file_sel < 0 {
						ed.goto_file_sel = 0
					}
				} else {
					ed.goto_file_sel--
				}
				ed.goto_file_clamp_scroll()
			}
		}
		vk_next {
			if mods == kbmod_none && ed.goto_file_sel + 1 < ed.goto_file_filtered.len {
				step := ed.goto_file_list_height()
				if step > 0 {
					ed.goto_file_sel += step
				} else {
					ed.goto_file_sel++
				}
				max_sel := if ed.goto_file_filtered.len > 0 {
					ed.goto_file_filtered.len - 1
				} else {
					0
				}
				if ed.goto_file_sel > max_sel {
					ed.goto_file_sel = max_sel
				}
				ed.goto_file_clamp_scroll()
			}
		}
		vk_return {
			if mods == kbmod_none {
				ed.goto_file_activate()
			}
		}
		vk_back {
			if mods == kbmod_none && ed.goto_file_filter.len > 0 {
				ed.goto_file_filter = picker_trim_last_utf8_char(ed.goto_file_filter)
				ed.goto_file_compute_filtered()
				// sel clamp 到新范围
				if ed.goto_file_sel >= ed.goto_file_filtered.len {
					ed.goto_file_sel = if ed.goto_file_filtered.len > 0 {
						ed.goto_file_filtered.len - 1
					} else {
						0
					}
				}
				ed.goto_file_clamp_scroll()
			}
		}
		else {}
	}
}

// handle_goto_file_text appends printable text to the filter. Multi-line
// text inputs are already stripped of newlines by the caller (see
// main.v handle_event, .text/.paste branch for goto_file).
fn (mut ed Editor) handle_goto_file_text(text string) {
	ed.goto_file_filter += text
	ed.goto_file_compute_filtered()
	ed.goto_file_sel = 0
	ed.goto_file_scroll = 0
	ed.goto_file_clamp_scroll()
}

fn (mut ed Editor) handle_goto_file_mouse(mouse InputMouse) {
	if mouse.state == .scroll {
		if mouse.scroll.y != 0 {
			// scroll the list: scroll.y < 0 moves selection up, ×3 mirrors main.v handle_mouse
			delta := mouse.scroll.y * CoordType(3)
			ed.goto_file_sel += int(delta)
			if ed.goto_file_sel < 0 {
				ed.goto_file_sel = 0
			} else if ed.goto_file_sel >= ed.goto_file_filtered.len {
				ed.goto_file_sel = if ed.goto_file_filtered.len > 0 {
					ed.goto_file_filtered.len - 1
				} else {
					0
				}
			}
			ed.goto_file_clamp_scroll()
		}
		return
	}
	if mouse.state != .left || mouse.drag {
		return
	}
	r := ed.goto_file_rect()
	list_right := ed.goto_file_list_right()
	// Rust modal_end semantics: click outside dismisses
	if mouse.position.x < r.left || mouse.position.x >= r.right
		|| mouse.position.y < r.top || mouse.position.y >= r.bottom {
		ed.goto_file = false
		return
	}
	if mouse.position.x >= list_right || mouse.position.y < r.top + 2 {
		// Click landed on the title row, filter row, or scrollbar gutter: dismiss.
		ed.goto_file = false
		return
	}
	// +2 because title and filter each take one row above the list.
	idx := ed.goto_file_scroll + int(mouse.position.y - (r.top + 2))
	if idx >= 0 && idx < ed.goto_file_filtered.len {
		ed.goto_file_sel = idx
		ed.goto_file_activate()
	}
}

fn (mut ed Editor) draw_goto_file() {
	r := ed.goto_file_rect()
	width := r.right - r.left

	// Title row (r.top).
	mut title_row := Rect{
		left: r.left
		top: r.top
		right: r.right
		bottom: r.top + 1
	}
	ed.fb.replace_text(r.top, r.left, r.right, picker_fit_line(' Go to File ', width))
	ed.fb.reverse(mut title_row)

	list_h := ed.goto_file_list_height()
	list_right := ed.goto_file_list_right()

	// Filter row (r.top + 1).
	filter_y := r.top + 1
	filter_line := picker_fit_line(' Filter: ${ed.goto_file_filter}', list_right - r.left)
	ed.fb.replace_text(filter_y, r.left, list_right, filter_line)
	mut filter_row := Rect{
		left: r.left
		top: filter_y
		right: list_right
		bottom: filter_y + 1
	}
	ed.fb.reverse(mut filter_row)

	// List rows (r.top + 2 .. r.bottom - 1).
	row_w := list_right - r.left
	for i in 0 .. list_h {
		idx := ed.goto_file_scroll + i
		// Rows past the last filtered entry are painted blank on purpose:
		// leaving them untouched lets the editor text underneath show
		// through the modal.
		line := if idx >= 0 && idx < ed.goto_file_filtered.len {
			doc_idx := ed.goto_file_filtered[idx]
			doc := ed.docs[doc_idx]
			label := ed.document_display_name(&doc)
			mark := if doc.buf.is_dirty() { '* ' } else { '  ' }
			dir := ed.goto_file_entry_dir(doc_idx)
			if dir == '' {
				picker_fit_line(mark + label, row_w)
			} else {
				// Dir is right-aligned with a 3-space gutter; the combined
				// row must still fit in row_w. We truncate the label
				// segment if needed and pad to push the dir to the right.
				suffix := '   ' + dir
				suffix_w := picker_display_width(suffix)
				max_label := coord_max(row_w - suffix_w, CoordType(0))
				truncated := picker_truncate(mark + label, max_label)
				mut pad := int(max_label - picker_display_width(truncated))
				if pad < 0 {
					pad = 0
				}
				picker_fit_line(truncated + ' '.repeat(pad) + suffix, row_w)
			}
		} else {
			picker_fit_line('', row_w)
		}
		y := r.top + 2 + CoordType(i)
		ed.fb.replace_text(y, r.left, list_right, line)

		// Italicize the dir portion of the row, if any.
		if idx >= 0 && idx < ed.goto_file_filtered.len {
			doc_idx := ed.goto_file_filtered[idx]
			dir := ed.goto_file_entry_dir(doc_idx)
			if dir != '' {
				suffix := '   ' + dir
				suffix_w := picker_display_width(suffix)
				dir_left := list_right - suffix_w
				mut attr_rect := Rect{
					left: dir_left
					top: y
					right: dir_left + suffix_w
					bottom: y + 1
				}
				ed.fb.replace_attr(mut attr_rect, attr_italic, attr_italic)
			}
		}

		mut item_row := Rect{
			left: r.left
			top: y
			right: list_right
			bottom: y + 1
		}
		ed.fb.reverse(mut item_row)
		if idx == ed.goto_file_sel {
			ed.fb.reverse(mut item_row)
		}
	}

	// Set the visible text cursor at the end of the filter row so the
	// user sees where the next character will land.
	mut cfg := new_measurement_config(StringDocument{ text: ' Filter: ${ed.goto_file_filter}' })
	filter_cursor_x := cfg.goto_visual(Point{ x: coord_type_max, y: 0 }).visual_pos.x
	ed.fb.set_cursor(Point{
		x: coord_min(r.left + filter_cursor_x, list_right - 1)
		y: filter_y
	}, false)

	if ed.goto_file_has_scrollbar() {
		// After the reversed rows: draw_scrollbar sets explicit fg/bg
		// colors that reverse() would otherwise swap. The track spans
		// the entire modal (including title and filter rows) like the
		// Rust original.
		track := Rect{
			left: r.right - 1
			top: r.top + 1
			right: r.right
			bottom: r.bottom
		}
		ed.fb.draw_scrollbar(r, track, ed.goto_file_scroll, ed.goto_file_filtered.len)
	}
}
