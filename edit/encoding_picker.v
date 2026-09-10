module main

enum EncodingChange {
	convert
	reopen
}

fn encoding_fuzzy_score(haystack string, needle string) int {
	if needle == '' {
		return 1
	}
	hay := haystack.to_lower()
	query := needle.to_lower()
	mut hi := 0
	mut score := 0
	mut streak := 0
	for qc in query {
		mut found := false
		for hi < hay.len {
			hc := hay[hi]
			hi++
			if hc == qc {
				streak++
				score += 10 + streak * 2
				found = true
				break
			}
			streak = 0
		}
		if !found {
			return 0
		}
	}
	return score
}

fn (mut ed Editor) encoding_picker_filter() {
	mut scored := []int{}
	mut scores := []int{}
	needle := ed.encoding_picker_needle.trim_space()
	for i, enc in editor_encodings {
		score := encoding_fuzzy_score(enc.label + ' ' + enc.canonical, needle)
		if score <= 0 {
			continue
		}
		mut at := 0
		for at < scores.len && scores[at] >= score {
			at++
		}
		scores.insert(at, score)
		scored.insert(at, i)
	}
	ed.encoding_picker_results = scored
	if ed.encoding_picker_sel >= scored.len {
		ed.encoding_picker_sel = if scored.len > 0 { scored.len - 1 } else { 0 }
	}
	if ed.encoding_picker_sel < 0 {
		ed.encoding_picker_sel = 0
	}
	ed.encoding_picker_scroll = 0
}

fn (mut ed Editor) open_encoding_actions() {
	if ed.cur().path == '' {
		ed.open_encoding_picker(.convert)
		return
	}
	ed.encoding_action_picker = true
	ed.encoding_action_sel = 0
	ed.indent_picker = false
	ed.language_picker = false
	ed.encoding_picker = false
}

fn (ed &Editor) encoding_actions_rect(status_y CoordType) Rect {
	width := coord_min(CoordType(22), ed.size.width)
	mut left := CoordType(0)
	for btn in ed.compute_status_buttons() {
		if btn.kind == .encoding {
			left = btn.right - width
		}
	}
	left = coord_max(coord_min(left, ed.size.width - width), 0)
	top := coord_max(status_y - 1, 1)
	return Rect{ left: left, top: top, right: left + width, bottom: top + 1 }
}

fn (mut ed Editor) open_encoding_picker(action EncodingChange) {
	ed.encoding_action_picker = false
	ed.encoding_picker = true
	ed.encoding_picker_action = action
	ed.encoding_picker_needle = ''
	ed.encoding_picker_sel = 0
	ed.encoding_picker_scroll = 0
	ed.encoding_picker_filter()
	ed.indent_picker = false
	ed.language_picker = false
}

fn (ed &Editor) encoding_picker_rect() Rect {
	w := coord_min(coord_max(ed.size.width - 20, 24), ed.size.width)
	h := coord_min(coord_max(ed.size.height - 10, 8), ed.size.height)
	return Rect{
		left: (ed.size.width - w) / 2
		top: (ed.size.height - h) / 2
		right: (ed.size.width + w) / 2
		bottom: (ed.size.height + h) / 2
	}
}

fn (ed &Editor) encoding_picker_list_height() int {
	r := ed.encoding_picker_rect()
	return int(coord_max(r.height() - 2, 0))
}

fn (mut ed Editor) encoding_picker_clamp_scroll() {
	h := ed.encoding_picker_list_height()
	if ed.encoding_picker_sel < ed.encoding_picker_scroll {
		ed.encoding_picker_scroll = ed.encoding_picker_sel
	}
	if h > 0 && ed.encoding_picker_sel >= ed.encoding_picker_scroll + h {
		ed.encoding_picker_scroll = ed.encoding_picker_sel - h + 1
	}
}

fn (mut ed Editor) encoding_picker_apply() {
	if ed.encoding_picker_sel < 0 || ed.encoding_picker_sel >= ed.encoding_picker_results.len {
		return
	}
	enc := editor_encodings[ed.encoding_picker_results[ed.encoding_picker_sel]].canonical
	if ed.encoding_picker_action == .convert {
		ed.docs[ed.active].buf.set_encoding(enc)
		ed.status = 'encoding: ${enc}'
		ed.encoding_picker = false
		return
	}
	path := ed.cur().path
	if path == '' {
		ed.error_log_add('reopen failed: document has no path')
		return
	}
	mut b := &ed.docs[ed.active].buf
	// Match the Rust workflow: preserve dirty edits by saving them in the
	// current encoding before reopening with a different decoder.
	if b.is_dirty() {
		b.write_file(path) or {
			ed.error_log_add('reopen save failed: ${path}: ${err}')
			return
		}
	}
	b.read_file_encoding(path, enc) or {
		ed.error_log_add('reopen failed: ${path} as ${enc}: ${err}')
		return
	}
	if fid := file_id(path) {
		ed.docs[ed.active].file_id = fid
		ed.docs[ed.active].has_file_id = true
	}
	ed.status = 'reopened as ${enc}'
	ed.encoding_picker = false
	ed.reset_view_state()
}

fn (mut ed Editor) handle_encoding_action_key(key InputKey) {
	mods := u32(key) & kbmod_mask
	vk := u32(key) & vk_mask
	match vk {
		vk_escape {
			ed.encoding_action_picker = false
		}
		vk_left, vk_up {
			if mods == kbmod_none {
				ed.encoding_action_sel = 0
			}
		}
		vk_right, vk_down, vk_tab {
			if mods == kbmod_none {
				ed.encoding_action_sel = 1
			}
		}
		vk_return {
			if mods == kbmod_none {
				ed.open_encoding_picker(if ed.encoding_action_sel == 0 { .reopen } else { .convert })
			}
		}
		else {}
	}
}

fn (mut ed Editor) handle_encoding_action_mouse(mouse InputMouse) {
	if mouse.state != .left || mouse.drag {
		return
	}
	r := ed.encoding_actions_rect(ed.size.height - 1)
	if !r.contains(mouse.position) {
		ed.encoding_action_picker = false
		return
	}
	rel_x := mouse.position.x - r.left
	if rel_x >= 1 && rel_x < 7 {
		ed.encoding_action_sel = 0
		ed.open_encoding_picker(.reopen)
	} else if rel_x >= 12 && rel_x < 19 {
		ed.encoding_action_sel = 1
		ed.open_encoding_picker(.convert)
	}
}

fn (mut ed Editor) handle_encoding_picker_key(key InputKey) {
	mods := u32(key) & kbmod_mask
	vk := u32(key) & vk_mask
	match vk {
		vk_escape {
			ed.encoding_picker = false
		}
		vk_back {
			if mods == kbmod_none && ed.encoding_picker_needle.len > 0 {
				beg := utf8_prev_start(ed.encoding_picker_needle.bytes(), ed.encoding_picker_needle.len)
				ed.encoding_picker_needle = ed.encoding_picker_needle[..beg]
				ed.encoding_picker_filter()
			}
		}
		vk_up {
			if ed.encoding_picker_sel > 0 { ed.encoding_picker_sel-- }
			ed.encoding_picker_clamp_scroll()
		}
		vk_down {
			if ed.encoding_picker_sel + 1 < ed.encoding_picker_results.len { ed.encoding_picker_sel++ }
			ed.encoding_picker_clamp_scroll()
		}
		vk_home {
			ed.encoding_picker_sel = 0
			ed.encoding_picker_clamp_scroll()
		}
		vk_end {
			if ed.encoding_picker_results.len > 0 {
				ed.encoding_picker_sel = ed.encoding_picker_results.len - 1
			}
			ed.encoding_picker_clamp_scroll()
		}
		vk_return {
			if mods == kbmod_none { ed.encoding_picker_apply() }
		}
		else {}
	}
}

fn (mut ed Editor) handle_encoding_picker_text(text string) {
	mut s := text.replace('\n', '').replace('\r', '').replace('\t', '')
	if s == '' {
		return
	}
	ed.encoding_picker_needle += s
	ed.encoding_picker_filter()
}

fn (mut ed Editor) handle_encoding_picker_mouse(mouse InputMouse) {
	if mouse.state != .left || mouse.drag {
		return
	}
	r := ed.encoding_picker_rect()
	if !r.contains(mouse.position) {
		ed.encoding_picker = false
		return
	}
	if mouse.position.y < r.top + 2 {
		return
	}
	idx := ed.encoding_picker_scroll + int(mouse.position.y - r.top - 2)
	if idx >= 0 && idx < ed.encoding_picker_results.len {
		ed.encoding_picker_sel = idx
		ed.encoding_picker_apply()
	}
}

fn (mut ed Editor) draw_encoding_actions(status_y CoordType) {
	r := ed.encoding_actions_rect(status_y)
	ed.fb.replace_text(r.top, r.left, r.right, picker_fit_line(' Reopen     Convert', r.width()))
	mut row := r
	ed.fb.reverse(mut row)
	cols := [CoordType(1), CoordType(12)]
	lens := [CoordType(6), CoordType(7)]
	mut selected := Rect{ left: r.left + cols[ed.encoding_action_sel], top: r.top, right: r.left + cols[ed.encoding_action_sel] + lens[ed.encoding_action_sel], bottom: r.bottom }
	ed.fb.reverse(mut selected)
}

fn (mut ed Editor) draw_encoding_picker() {
	r := ed.encoding_picker_rect()
	mut panel := r
	ed.fb.reverse(mut panel)
	title := if ed.encoding_picker_action == .reopen {
		' Reopen Encoding '
	} else {
		' Convert Encoding '
	}
	ed.fb.replace_text(r.top, r.left, r.right, picker_fit_line(title, r.width()))
	ed.fb.replace_text(r.top + 1, r.left, r.right, picker_fit_line(' Search: ${ed.encoding_picker_needle}', r.width()))
	list_h := ed.encoding_picker_list_height()
	ed.encoding_picker_clamp_scroll()
	for i in 0 .. list_h {
		result_idx := ed.encoding_picker_scroll + i
		if result_idx >= ed.encoding_picker_results.len {
			break
		}
		enc := editor_encodings[ed.encoding_picker_results[result_idx]]
		mark := if enc.canonical == ed.docs[ed.active].buf.encoding() { '* ' } else { '  ' }
		ed.fb.replace_text(r.top + 2 + CoordType(i), r.left, r.right, picker_fit_line(mark + enc.label, r.width()))
		if result_idx == ed.encoding_picker_sel {
			mut item := Rect{ left: r.left, top: r.top + 2 + CoordType(i), right: r.right, bottom: r.top + 3 + CoordType(i) }
			ed.fb.reverse(mut item)
		}
	}
	mut search_row := Rect{ left: r.left, top: r.top + 1, right: r.right, bottom: r.top + 2 }
	ed.fb.reverse(mut search_row)
	ed.fb.set_cursor(Point{ x: coord_min(r.left + CoordType(9 + ed.encoding_picker_needle.len), r.right - 1), y: r.top + 1 }, false)
}
