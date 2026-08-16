module main

// File picker (open / save-as), a simplified take on draw_filepicker.rs in the
// Rust original: a centered modal with the current directory, a filename
// editline, and a sorted directory listing ('..', then directories with a
// trailing '/', then files). Up/Down moves the selection into the name field,
// Enter navigates into directories or accepts a file, Backspace on an empty
// name goes up one directory, Escape cancels. Save-as onto an existing file
// shows an overwrite warning (y/n).
//
// Scope trims vs. the Rust original: no autocomplete suggestions, byte-wise
// sorting instead of ICU collation, and no drive picker (Windows-only there).

import os

// picker_normalize resolves '.' and '..' path components purely textually
// (Rust path::normalize). Absolute paths stay absolute, '..' at the root
// clamps to the root.
fn picker_normalize(path string) string {
	is_abs := path.starts_with('/')
	mut parts := []string{cap: 8}
	for comp in path.split('/') {
		match comp {
			'', '.' {}
			'..' {
				if parts.len > 0 {
					parts.delete(parts.len - 1)
				}
			}
			else {
				parts << comp
			}
		}
	}
	joined := parts.join('/')
	if is_abs {
		return '/' + joined
	}
	return if joined == '' { '.' } else { joined }
}

// picker_join joins the picker directory with the typed name and normalizes
// the result. An absolute name replaces the directory; a trailing '/' (as
// carried by directory entries) is stripped first.
fn picker_join(dir string, name string) string {
	n := name.trim_right('/')
	if os.is_abs_path(n) {
		return picker_normalize(n)
	}
	return picker_normalize(dir + '/' + n)
}

// open_picker shows the file picker. In save-as mode the name field is
// pre-filled with the current document's filename, like StateFilePicker::SaveAs.
fn (mut ed Editor) open_picker(save_as bool) {
	cur := ed.cur()
	mut dir := if cur.path == '' { os.getwd() } else { os.dir(cur.path) }
	if !os.is_abs_path(dir) {
		dir = picker_normalize(os.getwd() + '/' + dir)
	}
	ed.picker = true
	ed.picker_save_as = save_as
	ed.picker_dir = picker_normalize(dir)
	ed.picker_name = if save_as {
		if cur.path == '' {
			'untitled.txt'
		} else {
			os.file_name(cur.path)
		}
	} else {
		''
	}
	ed.picker_sel = 0
	ed.picker_scroll = 0
	ed.picker_overwrite = ''
	ed.picker_refresh()
}

// picker_refresh reloads the directory listing: ['..', dirs..., files...],
// each group sorted by name. '..' is omitted at the filesystem root.
fn (mut ed Editor) picker_refresh() {
	mut dirs := []string{}
	mut files := []string{}
	for name in os.ls(ed.picker_dir) or { []string{} } {
		if os.is_dir(os.join_path(ed.picker_dir, name)) {
			dirs << name + '/'
		} else {
			files << name
		}
	}
	dirs.sort()
	files.sort()
	mut entries := []string{cap: dirs.len + files.len + 1}
	if ed.picker_dir != '/' {
		entries << '..'
	}
	entries << dirs
	entries << files
	ed.picker_entries = entries
	if ed.picker_sel >= entries.len {
		ed.picker_sel = entries.len - 1
	}
}

// picker_rect returns the centered modal Rect, sized like the Rust original
// (width - 20, height - 10, minimum 10x10).
fn (ed &Editor) picker_rect() Rect {
	w := coord_min(coord_max(ed.size.width - 20, 10), ed.size.width)
	h := coord_min(coord_max(ed.size.height - 10, 10), ed.size.height)
	left := (ed.size.width - w) / 2
	top := (ed.size.height - h) / 2
	return Rect{
		left:   left
		top:    top
		right:  left + w
		bottom: top + h
	}
}

// picker_list_height returns how many entry rows fit into the modal
// (title, path and name rows take up 3 rows).
fn (ed &Editor) picker_list_height() int {
	r := ed.picker_rect()
	return int(coord_max(r.bottom - r.top - 3, 0))
}

// picker_sync_name copies the selected entry into the name field, like
// ListSelection::Selected in the Rust original.
fn (mut ed Editor) picker_sync_name() {
	if ed.picker_sel >= 0 && ed.picker_sel < ed.picker_entries.len {
		ed.picker_name = ed.picker_entries[ed.picker_sel]
	}
}

// picker_clamp_scroll scrolls the entry list so the selection stays visible.
fn (mut ed Editor) picker_clamp_scroll() {
	list_h := ed.picker_list_height()
	if ed.picker_sel < ed.picker_scroll {
		ed.picker_scroll = ed.picker_sel
	}
	if list_h > 0 && ed.picker_sel >= ed.picker_scroll + list_h {
		ed.picker_scroll = ed.picker_sel - list_h + 1
	}
}

// picker_activate accepts the current name: directories are navigated into,
// files are opened (open mode) or saved to (save-as mode, with an overwrite
// warning when the file exists), like draw_file_picker_update_path.
fn (mut ed Editor) picker_activate() {
	if ed.picker_name == '' {
		return
	}
	path := picker_join(ed.picker_dir, ed.picker_name)
	if os.is_dir(path) {
		ed.picker_dir = path
		ed.picker_name = ''
		ed.picker_sel = 0
		ed.picker_scroll = 0
		ed.picker_refresh()
		return
	}
	if ed.picker_save_as {
		if os.exists(path) {
			ed.picker_overwrite = path
			return
		}
		ed.picker_do_save(path)
		return
	}
	ed.add_document(path) or {
		ed.status = 'open failed: ${err}'
		return
	}
	ed.picker = false
}

// picker_do_save saves the active document to the given path.
fn (mut ed Editor) picker_do_save(path string) {
	ed.docs[ed.active].path = path
	ed.docs[ed.active].buf.write_file(path) or {
		ed.status = 'save failed: ${err}'
		return
	}
	ed.docs[ed.active].buf.mark_as_clean()
	ed.status = 'saved ${path}'
	ed.picker = false
}

// handle_picker_key handles keys while the file picker is open. While the
// overwrite warning is up, only y/n/Escape get through.
fn (mut ed Editor) handle_picker_key(key InputKey) {
	mods := u32(key) & kbmod_mask
	vk := u32(key) & vk_mask

	if ed.picker_overwrite != '' {
		// Only Escape gets through as a key; y/n arrive as .text events
		// (printable keys are text in our input model) and are handled in
		// the .text branch of handle_event.
		if vk == vk_escape {
			ed.picker_overwrite = ''
		}
		return
	}

	match vk {
		vk_escape {
			ed.picker = false
		}
		vk_up {
			if mods == kbmod_alt {
				// Alt+Up goes to the parent directory (Rust original).
				ed.picker_name = '..'
				ed.picker_activate()
			} else if mods == kbmod_none || mods == kbmod_shift {
				if ed.picker_sel > 0 {
					ed.picker_sel--
				}
				ed.picker_sync_name()
			}
		}
		vk_down {
			if mods == kbmod_none || mods == kbmod_shift {
				if ed.picker_sel + 1 < ed.picker_entries.len {
					ed.picker_sel++
				}
				ed.picker_sync_name()
			}
		}
		vk_return {
			if mods == kbmod_none {
				ed.picker_activate()
			}
		}
		vk_back {
			if mods == kbmod_none || mods == kbmod_shift {
				if ed.picker_name.len > 0 {
					ed.picker_name = ed.picker_name[..ed.picker_name.len - 1]
				} else {
					// Backspace on an empty name goes up one directory.
					ed.picker_name = '..'
					ed.picker_activate()
				}
			}
		}
		else {}
	}
	ed.picker_clamp_scroll()
}

// handle_picker_mouse handles clicks inside the file picker: a click on an
// entry selects and activates it (directories open, files are accepted).
// Clicks elsewhere in the modal do nothing; the picker is only closed via
// Escape or a successful open/save, like a modal in the Rust original.
fn (mut ed Editor) handle_picker_mouse(mouse InputMouse) {
	if mouse.state != .left || mouse.drag || ed.picker_overwrite != '' {
		return
	}
	r := ed.picker_rect()
	list_top := r.top + 3
	if mouse.position.x < r.left || mouse.position.x >= r.right {
		return
	}
	if mouse.position.y < list_top || mouse.position.y >= r.bottom {
		return
	}
	idx := ed.picker_scroll + int(mouse.position.y - list_top)
	if idx >= 0 && idx < ed.picker_entries.len {
		ed.picker_sel = idx
		ed.picker_sync_name()
		ed.picker_activate()
	}
}

// draw_filepicker draws the picker modal, and the overwrite warning on top of
// it when a save would clobber an existing file.
fn (mut ed Editor) draw_filepicker() {
	r := ed.picker_rect()
	width := r.right - r.left

	mut row := Rect{
		left:   r.left
		top:    r.top
		right:  r.right
		bottom: r.top + 1
	}

	// Title, current directory, name editline.
	title := if ed.picker_save_as { ' Save As ' } else { ' Open ' }
	ed.fb.replace_text(r.top, r.left, r.right, title)
	ed.fb.reverse(mut row)
	row.top++
	row.bottom++
	path_line := picker_truncate('Path: ${ed.picker_dir}', width)
	ed.fb.replace_text(row.top, r.left, r.right, path_line)
	ed.fb.reverse(mut row)
	row.top++
	row.bottom++
	name_text := 'Name: ${ed.picker_name}'
	ed.fb.replace_text(row.top, r.left, r.right, name_text)
	ed.fb.reverse(mut row)

	// Directory listing.
	list_top := r.top + 3
	for i in ed.picker_scroll .. ed.picker_entries.len {
		y := list_top + CoordType(i - ed.picker_scroll)
		if y >= r.bottom {
			break
		}
		ed.fb.replace_text(y, r.left, r.right, picker_truncate(ed.picker_entries[i], width))
		mut item_row := Rect{
			left:   r.left
			top:    y
			right:  r.right
			bottom: y + 1
		}
		ed.fb.reverse(mut item_row)
		if i == ed.picker_sel {
			// Double reverse = normal colors, reads as a highlight.
			ed.fb.reverse(mut item_row)
		}
	}

	// The text cursor sits at the end of the name editline. name_text.len is
	// bytes, not terminal columns, so measure the display width like the
	// status-line prompt does.
	mut cfg := new_measurement_config(StringDocument{ text: name_text })
	cursor_x := cfg.goto_visual(Point{ x: coord_type_max, y: 0 }).visual_pos.x
	ed.fb.set_cursor(Point{ x: coord_min(r.left + cursor_x, r.right - 1), y: r.top + 2 }, false)

	if ed.picker_overwrite != '' {
		ed.draw_picker_overwrite()
	}
}

// draw_picker_overwrite draws the "file exists, overwrite?" warning (y/n),
// the red modal of the Rust original reduced to plain reversed rows.
fn (mut ed Editor) draw_picker_overwrite() {
	lines := [
		'File exists:',
		picker_truncate(ed.picker_overwrite, 46),
		'',
		'Overwrite? (y/n)',
	]
	box_w := CoordType(50)
	box_h := CoordType(lines.len)
	left := coord_max((ed.size.width - box_w) / 2, 0)
	top := coord_max((ed.size.height - box_h) / 2, 0)
	right := coord_min(left + box_w, ed.size.width)
	for i, text in lines {
		y := top + CoordType(i)
		mut line := text
		if line.len < int(box_w) {
			line += ' '.repeat(int(box_w) - line.len)
		}
		ed.fb.replace_text(y, left, right, line)
		mut row := Rect{
			left:   left
			top:    y
			right:  right
			bottom: y + 1
		}
		ed.fb.reverse(mut row)
	}
}

// picker_truncate keeps the tail of an over-wide path (the meaningful end),
// like Overflow::TruncateMiddle in spirit.
fn picker_truncate(s string, width CoordType) string {
	if s.len <= int(width) {
		return s
	}
	if width <= 3 {
		return s[s.len - int(width)..]
	}
	return '...' + s[s.len - int(width) + 3..]
}
