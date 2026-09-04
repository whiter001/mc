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
	if mouse.state != .left || mouse.drag {
		return
	}
	r := ed.goto_file_rect()
	if mouse.position.x < r.left || mouse.position.x >= r.right {
		return
	}
	if mouse.position.y < r.top + 1 || mouse.position.y >= r.bottom {
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
	for i in 0 .. list_h {
		idx := ed.goto_file_scroll + i
		if idx >= ed.docs.len {
			break
		}
		y := r.top + 1 + CoordType(i)
		line := picker_fit_line(ed.goto_file_entry_text(idx), width)
		ed.fb.replace_text(y, r.left, r.right, line)
		mut item_row := Rect{
			left: r.left
			top: y
			right: r.right
			bottom: y + 1
		}
		ed.fb.reverse(mut item_row)
		if idx == ed.goto_file_sel {
			ed.fb.reverse(mut item_row)
		}
	}
}
