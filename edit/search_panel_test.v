module main

fn panel_ed(text string) Editor {
	mut ed := Editor{
		fb:   framebuffer_new()
		size: Size{
			width:  80
			height: 24
		}
	}
	ed.add_document('') or { panic('add_document: ${err}') }
	ed.docs[ed.active].buf.write_raw(text.bytes())
	return ed
}

fn test_open_search_panel_prefills_needle_from_selection() {
	mut ed := panel_ed('hello world')
	mut b := &ed.docs[ed.active].buf
	b.set_selection(OptSelection{ valid: true, beg: Point{ x: 6, y: 0 }, end: Point{ x: 11, y: 0 } })

	ed.open_search_panel()
	assert ed.search_panel.visible
	assert ed.search_panel.kind == .search
	assert ed.search_panel.needle == 'world'
	assert ed.search_panel.focus == .needle

	// Without a selection the needle falls back to last_search.
	ed.close_search_panel()
	ed.docs[ed.active].buf.set_selection(OptSelection{ valid: false })
	ed.last_search = 'foo'
	ed.open_search_panel()
	assert ed.search_panel.needle == 'foo'
}

fn test_open_replace_panel_with_selection_focuses_replacement() {
	mut ed := panel_ed('hello world')
	mut b := &ed.docs[ed.active].buf
	b.set_selection(OptSelection{ valid: true, beg: Point{ x: 0, y: 0 }, end: Point{ x: 5, y: 0 } })

	ed.open_replace_panel()
	assert ed.search_panel.kind == .replace
	assert ed.search_panel.needle == 'hello'
	assert ed.search_panel.focus == .replacement
}

fn test_search_panel_tab_cycles_focus() {
	// Search mode cycles 5 items and skips .replacement.
	items := search_panel_focus_items(.search)
	assert items.len == 5
	assert SearchPanelFocus.replacement !in items

	mut p := SearchPanel{
		visible: true
		kind:    .search
		focus:   .needle
	}
	search_panel_cycle(mut p, 1)
	assert p.focus == .match_case
	search_panel_cycle(mut p, 1)
	assert p.focus == .whole_word
	search_panel_cycle(mut p, 1)
	assert p.focus == .regex
	search_panel_cycle(mut p, 1)
	assert p.focus == .close_btn
	// Wraps around.
	search_panel_cycle(mut p, 1)
	assert p.focus == .needle
	// Shift+Tab walks backwards.
	search_panel_cycle(mut p, -1)
	assert p.focus == .close_btn

	// Replace mode adds the replacement field and the two action buttons.
	ritems := search_panel_focus_items(.replace)
	assert ritems.len == 8
	assert SearchPanelFocus.replacement in ritems
	assert SearchPanelFocus.replace_all_btn in ritems
}

fn test_search_panel_normalize_focus_snaps_invalid_focus() {
	// .replacement is not part of the search-mode cycle; normalizing must
	// snap it back to .needle instead of leaving a dangling index.
	mut p := SearchPanel{
		kind:  .search
		focus: .replacement
	}
	search_panel_normalize_focus(mut p)
	assert p.focus == .needle
	assert p.focus_index == 0
}

fn test_search_panel_enter_keeps_panel_open() {
	mut ed := panel_ed('foo\nbaz foo\nfoo\n')
	ed.open_search_panel()
	ed.search_panel.needle = 'foo'
	ed.search_panel.needle_cursor = 3

	assert ed.handle_search_panel_key(InputKey(vk_return))
	assert ed.search_panel.visible
	mut b := &ed.docs[ed.active].buf
	assert b.has_selection()
	assert b.selection.beg.y == 0

	// Repeated Enter advances to the next hit without closing the panel.
	assert ed.handle_search_panel_key(InputKey(vk_return))
	assert ed.search_panel.visible
	assert ed.docs[ed.active].buf.selection.beg.y == 1
}

fn test_search_panel_escape_closes_and_preserves_needle() {
	mut ed := panel_ed('hello world')
	ed.open_search_panel()
	ed.search_panel.needle = 'world'
	ed.search_panel.needle_cursor = 5

	assert ed.handle_search_panel_key(InputKey(vk_escape))
	assert !ed.search_panel.visible
	// The needle survives so F3 / a reopened panel keep working.
	assert ed.last_search == 'world'

	ed.open_search_panel()
	assert ed.search_panel.needle == 'world'
}

fn test_search_panel_empty_needle_does_not_fail() {
	mut ed := panel_ed('hello world')
	ed.open_search_panel()
	ed.search_panel.needle = ''
	ed.run_panel_search()
	assert !ed.search_failed
	assert ed.search_panel.hit_total == 0
	assert !ed.docs[ed.active].buf.has_selection()
}

fn test_search_panel_missing_needle_sets_search_failed() {
	mut ed := panel_ed('hello world')
	ed.open_search_panel()
	ed.search_panel.needle = 'zzz'
	ed.run_panel_search()
	assert ed.search_failed

	ed.search_panel.needle = 'world'
	ed.run_panel_search()
	assert !ed.search_failed
}

fn test_search_panel_invalid_regex_preserves_previous_match() {
	mut ed := panel_ed('foo bar foo')
	ed.open_search_panel()
	ed.search_options.use_regex = true
	ed.search_panel.needle = 'foo'
	ed.run_panel_search()
	assert !ed.search_failed
	assert ed.last_search == 'foo'
	previous := ed.docs[ed.active].buf.selection.beg

	ed.search_panel.needle = '('
	ed.run_panel_search()
	assert ed.search_failed
	assert ed.search_panel.error.starts_with('invalid regex:')
	assert ed.last_search == 'foo'
	assert ed.docs[ed.active].buf.selection.beg == previous
}

fn test_search_panel_toggle_option_reruns_search() {
	mut ed := panel_ed('Foo foo')
	ed.open_search_panel()
	ed.search_panel.needle = 'foo'
	ed.run_panel_search()
	assert !ed.search_failed
	assert ed.search_panel.hit_total == 2

	// Match case narrows the hit set to the lowercase occurrence only.
	ed.search_panel_toggle_option(.match_case)
	assert ed.search_options.match_case
	assert ed.search_panel.hit_total == 1
}

fn test_search_panel_replace_all_is_one_undo_group() {
	mut ed := panel_ed('foo foo foo')
	ed.open_replace_panel()
	ed.search_panel.needle = 'foo'
	ed.search_panel.replacement = 'bar'
	ed.panel_action_replace_all()

	mut b := &ed.docs[ed.active].buf
	assert b.read_all().bytestr() == 'bar bar bar\n'
	// A single undo restores the whole document (Rust ReplaceAll semantics).
	b.undo()
	assert b.read_all().bytestr() == 'foo foo foo\n'
}

fn test_search_panel_replace_all_keeps_panel_open() {
	mut ed := panel_ed('foo foo')
	ed.open_replace_panel()
	ed.search_panel.needle = 'foo'
	ed.search_panel.replacement = 'bar'
	ed.panel_action_replace_all()
	assert ed.search_panel.visible
	assert ed.last_search == 'foo'
	assert ed.last_replacement == 'bar'
}

fn test_search_panel_ctrl_alt_enter_replaces_all() {
	mut ed := panel_ed('foo foo')
	ed.open_replace_panel()
	ed.search_panel.needle = 'foo'
	ed.search_panel.replacement = 'bar'
	ed.search_panel.focus = .replacement

	assert ed.handle_search_panel_key(InputKey(u32(vk_return) | kbmod_ctrl | kbmod_alt))
	assert ed.docs[ed.active].buf.read_all().bytestr() == 'bar bar\n'
	assert ed.search_panel.visible
}

fn test_search_panel_text_editing_targets_focused_field() {
	mut ed := panel_ed('hello')
	ed.open_replace_panel()
	ed.search_panel.focus = .needle
	ed.search_panel_text_insert('ab')
	assert ed.search_panel.needle == 'ab'

	ed.search_panel.focus = .replacement
	ed.search_panel_text_insert('xy')
	assert ed.search_panel.replacement == 'xy'
	assert ed.search_panel.needle == 'ab'

	ed.search_panel_text_backspace()
	assert ed.search_panel.replacement == 'x'
	assert ed.search_panel.needle == 'ab'
}

fn test_search_panel_layout_top_vs_bottom() {
	mut ed := panel_ed('hello')
	ed.open_search_panel()
	// Tall terminal: the panel sits right under the menu bar.
	ed.size = Size{
		width:  80
		height: 24
	}
	top, has_repl := ed.search_panel_layout()
	assert top == 1
	assert !has_repl

	// Replace mode in a tall terminal exposes the replacement row.
	ed.open_replace_panel()
	top2, has_repl2 := ed.search_panel_layout()
	assert top2 == 1
	assert has_repl2

	// Short terminal: fall back to the bottom block.
	ed.size = Size{
		width:  80
		height: 4
	}
	top3, _ := ed.search_panel_layout()
	assert top3 < 1 || top3 == ed.size.height - 3
}

fn test_replacement_edit_does_not_advance_match() {
	mut ed := panel_ed('foo foo')
	ed.open_replace_panel()
	ed.search_panel.needle = 'foo'
	ed.search_panel.needle_cursor = 3
	ed.run_panel_search()
	first := ed.docs[ed.active].buf.selection.beg
	ed.search_panel.focus = .replacement
	ed.search_panel.replacement_cursor = 0
	assert ed.handle_search_panel_text('bar')
	assert ed.search_panel.replacement == 'bar'
	assert ed.docs[ed.active].buf.selection.beg == first
}

fn test_panel_non_text_focus_consumes_text_without_editing_document() {
	mut ed := panel_ed('foo')
	ed.open_search_panel()
	ed.search_panel.focus = .match_case
	before := ed.docs[ed.active].buf.read_all().bytestr()
	ed.handle_event(Input{ kind: .text, text: 'X' })
	assert ed.docs[ed.active].buf.read_all().bytestr() == before
}

fn test_search_panel_selection_replaces_with_typing() {
	mut ed := panel_ed('hello')
	ed.open_search_panel()
	ed.search_panel.needle = 'abcd'
	ed.search_panel.needle_cursor = 4
	ed.search_panel_text_move_left(true)
	ed.search_panel_text_move_left(true)
	assert ed.search_panel.needle_anchor == 4
	assert ed.search_panel.needle_cursor == 2
	ed.search_panel_text_insert('X')
	assert ed.search_panel.needle == 'abX'
	assert ed.search_panel.needle_cursor == 3
	ed.search_panel_text_select_all()
	ed.search_panel_text_insert('ok')
	assert ed.search_panel.needle == 'ok'
}

fn test_search_panel_ctrl_a_selects_and_highlights_active_input() {
	mut ed := panel_ed('hello')
	ed.open_search_panel()
	ed.search_panel.needle = 'abc'
	ed.search_panel.needle_cursor = ed.search_panel.needle.len

	assert ed.handle_search_panel_key(InputKey(vk_a | kbmod_ctrl))
	assert ed.search_panel.needle_anchor == 0
	assert ed.search_panel.needle_cursor == 3

	ed.fb.flip(ed.size)
	ed.draw_search_panel()
	idx := int(ed.fb.frame_counter & 1)
	row, _ := ed.search_panel_layout()
	selected := int(row) * int(ed.size.width) + 9 // leading space + "Search: "
	outside := selected - 1
	assert ed.fb.buffers[idx].bg_bitmap.data[selected].to_rgba() == ed.fb.buffers[idx].fg_bitmap.data[outside].to_rgba()
	assert ed.fb.buffers[idx].fg_bitmap.data[selected].to_rgba() == ed.fb.buffers[idx].bg_bitmap.data[outside].to_rgba()
}

fn test_search_panel_enter_toggles_option_focus() {
	mut ed := panel_ed('Foo foo')
	ed.open_search_panel()
	ed.search_panel.focus = .match_case
	assert ed.handle_search_panel_key(InputKey(vk_return))
	assert ed.search_options.match_case
}

fn test_search_panel_mouse_click_toggles_option() {
	mut ed := panel_ed('Foo foo')
	ed.open_search_panel()
	ed.search_panel.needle = 'foo'
	ed.run_panel_search()
	ed.draw_search_panel()
	assert ed.panel_buttons.len > 0

	mut case_btn := PanelButton{
		row: -1
	}
	for btn in ed.panel_buttons {
		if btn.focus == .match_case {
			case_btn = btn
			break
		}
	}
	assert case_btn.row >= 0

	handled := ed.handle_search_panel_mouse(InputMouse{
		state:    .left
		position: Point{
			x: case_btn.left
			y: case_btn.row
		}
	})
	assert handled
	assert ed.search_options.match_case
	assert ed.search_panel.focus == .match_case
}

fn test_search_panel_mouse_click_close_button_closes() {
	mut ed := panel_ed('foo')
	ed.open_replace_panel()
	ed.draw_search_panel()

	mut close_btn := PanelButton{
		row: -1
	}
	for btn in ed.panel_buttons {
		if btn.focus == .close_btn {
			close_btn = btn
			break
		}
	}
	assert close_btn.row >= 0

	handled := ed.handle_search_panel_mouse(InputMouse{
		state:    .left
		position: Point{
			x: close_btn.left
			y: close_btn.row
		}
	})
	assert handled
	assert !ed.search_panel.visible
}

fn test_search_panel_mouse_outside_panel_is_not_consumed() {
	mut ed := panel_ed('foo')
	ed.open_search_panel()
	ed.draw_search_panel()
	handled := ed.handle_search_panel_mouse(InputMouse{
		state:    .left
		position: Point{
			x: 5
			y: 12
		}
	})
	assert !handled
}
