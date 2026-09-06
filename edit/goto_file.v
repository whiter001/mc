module main

// open_goto_file opens the document switcher modal.
fn (mut ed Editor) open_goto_file() {
	if ed.docs.len == 0 {
		return
	}
	ed.goto_file = true
	ed.goto_file_sel = ed.active
	ed.goto_file_scroll = 0
	ed.goto_file_clamp_scroll()
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
	return int(coord_max(r.bottom - r.top - 1, 0))
}

fn (mut ed Editor) goto_file_clamp_scroll() {
	list_h := ed.goto_file_list_height()
	if ed.goto_file_sel < ed.goto_file_scroll {
		ed.goto_file_scroll = ed.goto_file_sel
	}
	if list_h > 0 && ed.goto_file_sel >= ed.goto_file_scroll + list_h {
		ed.goto_file_scroll = ed.goto_file_sel - list_h + 1
	}
}

// goto_file_has_scrollbar reports whether the document list overflows the
// modal, in which case the rightmost column is reserved for a scrollbar.
fn (ed &Editor) goto_file_has_scrollbar() bool {
	return ed.docs.len > ed.goto_file_list_height()
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
	label := if doc.path == '' { '[untitled]' } else { doc.path }
	mark := if doc.buf.is_dirty() { '* ' } else { '  ' }
	return mark + label
}

fn (mut ed Editor) goto_file_activate() {
	if ed.goto_file_sel < 0 || ed.goto_file_sel >= ed.docs.len {
		return
	}
	ed.active = ed.goto_file_sel
	ed.goto_file = false
	ed.reset_view_state()
}

fn (mut ed Editor) handle_goto_file_key(key InputKey) {
	mods := u32(key) & kbmod_mask
	vk := u32(key) & vk_mask
	match vk {
		vk_escape {
			ed.goto_file = false
		}
		vk_up {
			if ed.goto_file_sel > 0 {
				ed.goto_file_sel--
				ed.goto_file_clamp_scroll()
			}
		}
		vk_down {
			if ed.goto_file_sel + 1 < ed.docs.len {
				ed.goto_file_sel++
				ed.goto_file_clamp_scroll()
			}
		}
		vk_home {
			ed.goto_file_sel = 0
			ed.goto_file_clamp_scroll()
		}
		vk_end {
			ed.goto_file_sel = ed.docs.len - 1
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
			if mods == kbmod_none && ed.goto_file_sel + 1 < ed.docs.len {
				step := ed.goto_file_list_height()
				if step > 0 {
					ed.goto_file_sel += step
				} else {
					ed.goto_file_sel++
				}
				max_sel := ed.docs.len - 1
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
		else {}
	}
}

fn (mut ed Editor) handle_goto_file_mouse(mouse InputMouse) {
	if mouse.state == .scroll {
		if mouse.scroll.y != 0 {
			// scroll the list: scroll.y < 0 moves selection up, ×3 mirrors main.v handle_mouse
			delta := mouse.scroll.y * CoordType(3)
			ed.goto_file_sel += int(delta)
			if ed.goto_file_sel < 0 {
				ed.goto_file_sel = 0
			} else if ed.goto_file_sel >= ed.docs.len {
				ed.goto_file_sel = ed.docs.len - 1
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
	if mouse.position.x >= list_right || mouse.position.y == r.top {
		// Click landed on the title row or scrollbar gutter: dismiss.
		ed.goto_file = false
		return
	}
	idx := ed.goto_file_scroll + int(mouse.position.y - (r.top + 1))
	if idx >= 0 && idx < ed.docs.len {
		ed.goto_file_sel = idx
		ed.goto_file_activate()
	}
}

fn (mut ed Editor) draw_goto_file() {
	r := ed.goto_file_rect()
	width := r.right - r.left
	mut row := Rect{
		left: r.left
		top: r.top
		right: r.right
		bottom: r.top + 1
	}
	ed.fb.replace_text(r.top, r.left, r.right, picker_fit_line(' Go to File ', width))
	ed.fb.reverse(mut row)
	list_h := ed.goto_file_list_height()
	list_right := ed.goto_file_list_right()
	for i in 0 .. list_h {
		idx := ed.goto_file_scroll + i
		// Rows past the last document are painted blank on purpose:
		// leaving them untouched lets the editor text underneath show
		// through the modal.
		line := if idx >= 0 && idx < ed.docs.len {
			picker_fit_line(ed.goto_file_entry_text(idx), list_right - r.left)
		} else {
			picker_fit_line('', list_right - r.left)
		}
		y := r.top + 1 + CoordType(i)
		ed.fb.replace_text(y, r.left, list_right, line)
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

	if ed.goto_file_has_scrollbar() {
		// After the reversed rows: draw_scrollbar sets explicit fg/bg
		// colors that reverse() would otherwise swap.
		track := Rect{
			left: r.right - 1
			top: r.top + 1
			right: r.right
			bottom: r.bottom
		}
		ed.fb.draw_scrollbar(r, track, ed.goto_file_scroll, ed.docs.len)
	}
}
