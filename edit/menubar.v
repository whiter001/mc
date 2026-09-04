module main

// Menu bar, dropdown menus and the About dialog, a heavily simplified take
// on the Rust original's menubar (tui.rs draw_menubar / state.rs About).
//
// Highlighting works like the status line: the whole row is reverse-videoed,
// and the active title/item is reversed a second time (= back to normal),
// which reads as a highlight against the inverted background.

// MenuAction identifies what a menu item does when activated.
enum MenuAction {
	file_new
	file_open
	file_save
	file_save_as
	file_close
	file_exit
	edit_undo
	edit_redo
	edit_cut
	edit_copy
	edit_paste
	edit_find
	edit_replace
	edit_replace_all
	edit_select_all
	view_goto_file
	view_goto_line
	view_word_wrap
	help_about
}

struct MenuItem {
	label   string
	accel   string
	action  MenuAction
	checked bool
}

struct MenuBarMenu {
	title string
	items []MenuItem
}

// build_menus constructs the menu tree. It is rebuilt every frame so the
// Word Wrap checkbox always reflects the current buffer state.
fn (ed &Editor) build_menus() []MenuBarMenu {
	wrap := ed.cur().buf.is_word_wrap_enabled()
	return [
		MenuBarMenu{
			title: 'File'
			items: [
				MenuItem{ label: 'New', accel: 'Ctrl+N', action: .file_new },
				MenuItem{ label: 'Open...', accel: 'Ctrl+O', action: .file_open },
				MenuItem{ label: 'Save', accel: 'Ctrl+S', action: .file_save },
				MenuItem{ label: 'Save As...', accel: 'Ctrl+Shift+S', action: .file_save_as },
				MenuItem{ label: 'Close', accel: 'Ctrl+W', action: .file_close },
				MenuItem{ label: 'Exit', accel: 'Ctrl+Q', action: .file_exit },
			]
		},
		MenuBarMenu{
			title: 'Edit'
			items: [
				MenuItem{ label: 'Undo', accel: 'Ctrl+Z', action: .edit_undo },
				MenuItem{ label: 'Redo', accel: 'Ctrl+Y', action: .edit_redo },
				MenuItem{ label: 'Cut', accel: 'Ctrl+X', action: .edit_cut },
				MenuItem{ label: 'Copy', accel: 'Ctrl+C', action: .edit_copy },
				MenuItem{ label: 'Paste', accel: 'Ctrl+V', action: .edit_paste },
				MenuItem{ label: 'Find...', accel: 'Ctrl+F', action: .edit_find },
				MenuItem{ label: 'Replace...', accel: 'Ctrl+R', action: .edit_replace },
				MenuItem{ label: 'Replace All', action: .edit_replace_all },
				MenuItem{ label: 'Select All', accel: 'Ctrl+A', action: .edit_select_all },
			]
		},
		MenuBarMenu{
			title: 'View'
			items: [
				MenuItem{ label: 'Go to File', accel: 'Ctrl+P', action: .view_goto_file },
				MenuItem{ label: 'Go to Line...', accel: 'Ctrl+G', action: .view_goto_line },
				MenuItem{ label: 'Word Wrap', accel: 'Alt+Z', action: .view_word_wrap, checked: wrap },
			]
		},
		MenuBarMenu{
			title: 'Help'
			items: [
				MenuItem{ label: 'About...', action: .help_about },
			]
		},
	]
}

// menu_title_rects returns the on-screen Rect of each menu title on row 0.
// Titles render as ` Title ` with two blank columns between them. Shared by
// the drawing code and the mouse hit-testing.
fn (ed &Editor) menu_title_rects(menus []MenuBarMenu) []Rect {
	mut rects := []Rect{cap: menus.len}
	mut x := CoordType(0)
	for menu in menus {
		w := CoordType(menu.title.len + 2)
		rects << Rect{
			left:   x
			top:    0
			right:  x + w
			bottom: 1
		}
		x += w + 2
	}
	return rects
}

// menu_item_prefix returns the checkbox prefix for checkable items
// (only Word Wrap is one).
fn menu_item_prefix(item MenuItem) string {
	if item.action == .view_word_wrap {
		return if item.checked { '[x] ' } else { '[ ] ' }
	}
	return ''
}

// menu_dropdown_rect returns the screen Rect of the open dropdown. Shared by
// the drawing code and the mouse hit-testing.
fn (ed &Editor) menu_dropdown_rect(menus []MenuBarMenu) Rect {
	titles := ed.menu_title_rects(menus)
	menu := menus[ed.menu_idx]
	// 1 column of left padding, >= 2 columns between label and accelerator,
	// 1 column of right padding.
	mut width := CoordType(0)
	for item in menu.items {
		w := CoordType(1 + menu_item_prefix(item).len + item.label.len + 2 + item.accel.len + 1)
		width = coord_max(width, w)
	}
	x0 := titles[ed.menu_idx].left
	return Rect{
		left:   x0
		top:    1
		right:  x0 + width
		bottom: 1 + CoordType(menu.items.len)
	}
}

// draw_menubar draws the menu titles on row 0.
fn (mut ed Editor) draw_menubar() {
	menus := ed.build_menus()
	rects := ed.menu_title_rects(menus)
	mut line := ''
	for i, menu in menus {
		if i > 0 {
			line += '  '
		}
		line += ' ${menu.title} '
	}
	ed.fb.replace_text(0, 0, ed.size.width, line)
	ed.fb.reverse(mut Rect{
		left:   0
		top:    0
		right:  ed.size.width
		bottom: 1
	})
	if ed.menu_open || ed.menu_focus {
		mut r := rects[ed.menu_idx]
		ed.fb.reverse(mut r)
	}
}

// draw_menu_dropdown draws the open dropdown below its menu title.
fn (mut ed Editor) draw_menu_dropdown(menus []MenuBarMenu) {
	menu := menus[ed.menu_idx]
	rect := ed.menu_dropdown_rect(menus)
	right := coord_min(rect.right, ed.size.width)
	for i, item in menu.items {
		y := CoordType(1 + i)
		if y >= ed.size.height - 1 {
			break
		}
		mut line := ' ' + menu_item_prefix(item) + item.label
		gap := (rect.right - rect.left) - CoordType(line.len + item.accel.len + 1)
		line += ' '.repeat(int(gap)) + item.accel + ' '
		ed.fb.replace_text(y, rect.left, right, line)
		mut item_rect := Rect{
			left:   rect.left
			top:    y
			right:  right
			bottom: y + 1
		}
		ed.fb.reverse(mut item_rect)
		if i == ed.menu_item_idx {
			ed.fb.reverse(mut item_rect)
		}
	}
}

// draw_about draws the centered About dialog on top of everything else.
fn (mut ed Editor) draw_about() {
	lines := [
		'',
		'Microsoft Edit (V port)',
		'version 0.1',
		'Copyright (c) Microsoft Corporation',
		'',
		'[ OK ]',
		'',
	]
	box_w := CoordType(44)
	box_h := CoordType(lines.len)
	left := coord_max((ed.size.width - box_w) / 2, 0)
	top := coord_max((ed.size.height - box_h) / 2, 0)
	right := coord_min(left + box_w, ed.size.width)
	for i, text in lines {
		y := top + CoordType(i)
		// Pad to the full box width so no underlying text shows through.
		mut line := ' '.repeat(int(box_w))
		if text != '' {
			pad := (int(box_w) - text.len) / 2
			line = ' '.repeat(pad) + text + ' '.repeat(int(box_w) - pad - text.len)
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

// handle_menu_key handles keys while the menu bar is focused or a dropdown
// is open. Returns true if the key was consumed; false means the menu state
// was closed and the key should continue through normal processing.
fn (mut ed Editor) handle_menu_key(key InputKey) bool {
	vk := u32(key) & vk_mask

	if vk == vk_escape || vk == vk_f10 {
		ed.menu_open = false
		ed.menu_focus = false
		return true
	}

	menus := ed.build_menus()
	if ed.menu_open {
		items := menus[ed.menu_idx].items
		match vk {
			vk_up {
				ed.menu_item_idx = (ed.menu_item_idx + items.len - 1) % items.len
				return true
			}
			vk_down {
				ed.menu_item_idx = (ed.menu_item_idx + 1) % items.len
				return true
			}
			vk_left {
				ed.menu_idx = (ed.menu_idx + menus.len - 1) % menus.len
				ed.menu_item_idx = 0
				return true
			}
			vk_right {
				ed.menu_idx = (ed.menu_idx + 1) % menus.len
				ed.menu_item_idx = 0
				return true
			}
			vk_return {
				ed.activate_menu_item(items[ed.menu_item_idx].action)
				return true
			}
			else {
				ed.menu_open = false
				ed.menu_focus = false
				return false
			}
		}
	}

	// Only the menu bar itself is focused (no dropdown open).
	match vk {
		vk_left {
			ed.menu_idx = (ed.menu_idx + menus.len - 1) % menus.len
			return true
		}
		vk_right {
			ed.menu_idx = (ed.menu_idx + 1) % menus.len
			return true
		}
		vk_down, vk_return {
			ed.menu_open = true
			ed.menu_item_idx = 0
			return true
		}
		else {
			ed.menu_focus = false
			return false
		}
	}
}

// activate_menu_item executes a menu item and closes the menu. The actions
// mirror the corresponding Ctrl+key bindings in handle_key().
fn (mut ed Editor) activate_menu_item(action MenuAction) {
	ed.menu_open = false
	ed.menu_focus = false
	match action {
		.file_new {
			ed.add_document('') or { ed.status = 'new file failed: ${err}' }
		}
		.file_open {
			ed.open_picker(false)
		}
		.file_save {
			ed.save_active()
		}
		.file_save_as {
			ed.open_picker(true)
		}
		.file_close {
			ed.close_active()
		}
		.file_exit {
			ed.request_exit()
		}
		.edit_undo {
			ed.docs[ed.active].buf.undo()
		}
		.edit_redo {
			ed.docs[ed.active].buf.redo()
		}
		.edit_cut {
			ed.docs[ed.active].buf.cut(mut ed.clipboard)
		}
		.edit_copy {
			ed.docs[ed.active].buf.copy(mut ed.clipboard)
		}
		.edit_paste {
			ed.docs[ed.active].buf.paste(ed.clipboard, false)
		}
		.edit_find {
			ed.start_prompt(.search)
		}
		.edit_replace {
			ed.replace_all = false
			ed.start_prompt(.replace)
		}
		.edit_replace_all {
			// Replace All reuses the replace prompt pair; the flag makes the
			// second prompt run find_and_replace_all (Rust SearchAction::ReplaceAll).
			ed.replace_all = true
			ed.start_prompt(.replace)
		}
		.edit_select_all {
			ed.docs[ed.active].buf.select_all()
		}
		.view_goto_file {
			ed.open_goto_file()
		}
		.view_goto_line {
			ed.start_prompt(.goto_line)
		}
		.view_word_wrap {
			ed.docs[ed.active].buf.set_word_wrap(!ed.docs[ed.active].buf.is_word_wrap_enabled())
		}
		.help_about {
			ed.about_open = true
		}
	}
}
