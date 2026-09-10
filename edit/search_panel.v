module main

// Persistent search/replace panel (PLAN §6 stage B).
//
// The panel replaces the old dual-prompt sequence:
//   Ctrl+F   opens a Search panel
//   Ctrl+R   opens a Replace panel (Ctrl+R with a selection focuses the
//             replacement field directly)
//   Enter    executes the focused action and keeps the panel open
//   Esc      closes the panel but preserves last_search / last_replacement
//   Tab/S-Tab cycles focus inside the panel
//   F3/S-F3  next / previous match — works from any panel focus
//
// While the panel is open, normal editor keystrokes (←/→/Home/End/typing)
// only affect the focused widget; the textarea below does not receive input.

// search_panel_focus_items returns the tab-cycle order of focus items for a
// given panel kind (PLAN §6.2.1). The replacement item is omitted in search
// mode so the cycle skips it.
fn search_panel_focus_items(kind SearchPanelKind) []SearchPanelFocus {
	if kind == .replace {
		return [.needle, .replacement, .match_case, .whole_word, .regex, .replace_btn,
			.replace_all_btn, .close_btn]
	}
	return [.needle, .match_case, .whole_word, .regex, .close_btn]
}

// search_panel_index_of returns the index of `focus` in the cycle list, or
// -1 if the focus isn't part of the current kind (e.g. .replacement while
// in search mode).
fn search_panel_index_of(kind SearchPanelKind, focus SearchPanelFocus) int {
	items := search_panel_focus_items(kind)
	for i, item in items {
		if item == focus {
			return i
		}
	}
	return -1
}

// search_panel_normalize_focus snaps the current focus back to a valid item
// for the given kind. Used after switching panel kinds and on open.
fn search_panel_normalize_focus(mut p SearchPanel) {
	if search_panel_index_of(p.kind, p.focus) < 0 {
		p.focus = .needle
		p.focus_index = 0
	} else {
		p.focus_index = search_panel_index_of(p.kind, p.focus)
	}
}

// search_panel_cycle moves focus forward (positive) or backward (negative)
// within the current panel kind. The cycle wraps around.
fn search_panel_cycle(mut p SearchPanel, delta int) {
	items := search_panel_focus_items(p.kind)
	if items.len == 0 {
		return
	}
	search_panel_normalize_focus(mut p)
	mut idx := p.focus_index + delta
	// Modulo that handles negative results correctly.
	idx = ((idx % items.len) + items.len) % items.len
	p.focus = items[idx]
	p.focus_index = idx
}

// open_search_panel opens the search panel. Selection prefill matches the
// Rust behavior: a non-empty selection fills the needle.
fn (mut ed Editor) open_search_panel() {
	ed.search_panel.kind = .search
	ed.search_panel.visible = true
	ed.search_panel.error = ''
	// Needle prefills from selection, else from last_search.
	mut b := &ed.docs[ed.active].buf
	if b.has_selection() {
		if sel := b.extract_user_selection(false) {
			ed.search_panel.needle = sel.bytestr()
		}
	} else {
		ed.search_panel.needle = ed.last_search
	}
	ed.search_panel.replacement = ed.last_replacement
	ed.search_panel.focus = .needle
	ed.search_panel.needle_cursor = ed.search_panel.needle.len
	ed.search_panel.replacement_cursor = ed.search_panel.replacement.len
	ed.search_panel.needle_anchor = -1
	ed.search_panel.replacement_anchor = -1
	ed.search_panel.hit_index = 0
	ed.search_panel.hit_total = 0
	search_panel_normalize_focus(mut ed.search_panel)
	ed.needs_redraw = true
}

// open_replace_panel opens the replace panel. With a selection the focus
// jumps straight to the replacement field (Rust draw_editor.rs:59-62).
fn (mut ed Editor) open_replace_panel() {
	ed.search_panel.kind = .replace
	ed.search_panel.visible = true
	ed.search_panel.error = ''
	mut b := &ed.docs[ed.active].buf
	mut focus_replacement := false
	if b.has_selection() {
		if sel := b.extract_user_selection(false) {
			ed.search_panel.needle = sel.bytestr()
			ed.last_search = ed.search_panel.needle
			focus_replacement = true
		}
	} else {
		ed.search_panel.needle = ed.last_search
	}
	ed.search_panel.replacement = ed.last_replacement
	if focus_replacement {
		ed.search_panel.focus = .replacement
	} else {
		ed.search_panel.focus = .needle
	}
	ed.search_panel.needle_cursor = ed.search_panel.needle.len
	ed.search_panel.replacement_cursor = ed.search_panel.replacement.len
	ed.search_panel.needle_anchor = -1
	ed.search_panel.replacement_anchor = -1
	ed.search_panel.hit_index = 0
	ed.search_panel.hit_total = 0
	search_panel_normalize_focus(mut ed.search_panel)
	ed.needs_redraw = true
}

// close_search_panel closes the panel and preserves last_search /
// last_replacement so F3 still works after dismissal (PLAN §6.2 row "Esc /
// Close"). The current needle/replacement are committed to the memory
// fields so they survive across sessions.
fn (mut ed Editor) close_search_panel() {
	if !ed.search_panel.visible {
		return
	}
	if ed.search_panel.needle != '' {
		ed.last_search = ed.search_panel.needle
	}
	ed.last_replacement = ed.search_panel.replacement
	ed.search_panel.visible = false
	ed.search_panel.error = ''
	ed.needs_redraw = true
}

// search_panel_is_editing reports whether the current focus is a text field
// (needle or replacement). Used by the input router to decide whether a key
// is a character insertion vs. a panel control.
fn (ed &Editor) search_panel_is_editing() bool {
	if !ed.search_panel.visible {
		return false
	}
	return ed.search_panel.focus in [.needle, .replacement]
}

// search_panel_active_text returns the field currently being edited along
// with a mutable handle to its cursor. Empty string if not editing.
fn (mut ed Editor) search_panel_active_text() (string, &int) {
	match ed.search_panel.focus {
		.needle {
			return ed.search_panel.needle, &ed.search_panel.needle_cursor
		}
		.replacement {
			return ed.search_panel.replacement, &ed.search_panel.replacement_cursor
		}
		else {
			return '', &ed.search_panel.needle_cursor
		}
	}
}

// search_panel_active_byte_width returns the display width of the prefix up
// to the cursor. Used by draw_search_panel to position the terminal cursor.
fn (mut ed Editor) search_panel_active_byte_width(label string) CoordType {
	if !ed.search_panel.visible {
		return 0
	}
	mut text, cur_ref := ed.search_panel_active_text()
	off := if *cur_ref < 0 || *cur_ref > text.len { text.len } else { *cur_ref }
	mut cfg := new_measurement_config(StringDocument{ text: ' ${label}${text[..off]}' })
	return cfg.goto_visual(Point{ x: coord_type_max, y: 0 }).visual_pos.x
}

// search_panel_toggle_option flips one of the three search options and
// re-runs the incremental search so the result reflects the change.
fn (mut ed Editor) search_panel_toggle_option(kind SearchButtonKind) {
	match kind {
		.match_case {
			ed.search_options.match_case = !ed.search_options.match_case
		}
		.whole_word {
			ed.search_options.whole_word = !ed.search_options.whole_word
		}
		.use_regex {
			ed.search_options.use_regex = !ed.search_options.use_regex
		}
	}
	ed.run_panel_search()
	ed.needs_redraw = true
}

// run_panel_search is the panel equivalent of run_prompt_search: write the
// current needle into last_search and select the next match inline.
fn (mut ed Editor) run_panel_search() {
	if !ed.search_panel.visible {
		return
	}
	needle := ed.search_panel.needle
	if needle == '' {
		ed.last_search = needle
		ed.search_failed = false
		ed.search_panel.error = ''
		ed.search_panel.hit_index = 0
		ed.search_panel.hit_total = 0
		ed.move_cursor_to_selection_beg()
		return
	}
	if ed.search_options.use_regex {
		err := regex_error(needle)
		if err != '' {
			// Keep the previous successful query and selection intact while the
			// user is correcting an invalid pattern.
			ed.search_failed = true
			ed.search_panel.error = 'invalid regex: ${err}'
			return
		}
	}
	ed.last_search = needle
	mut b := &ed.docs[ed.active].buf
	b.find_and_select(needle, ed.search_options)
	b.make_cursor_visible()
	ed.search_failed = !b.has_selection()
	if !b.has_selection() {
		ed.search_panel.error = 'not found: ${needle}'
	} else {
		ed.search_panel.error = ''
	}
	ed.update_search_stats_for_panel()
}

// update_search_stats_for_panel refreshes the hit counter shown on the
// options row. Reuses TextBuffer.search_match_stats; only the panel fields
// are written.
fn (mut ed Editor) update_search_stats_for_panel() {
	if ed.docs.len == 0 || ed.last_search == '' {
		ed.search_panel.hit_index = 0
		ed.search_panel.hit_total = 0
		return
	}
	mut b := &ed.docs[ed.active].buf
	ed.search_panel.hit_index, ed.search_panel.hit_total = b.search_match_stats(ed.last_search, ed.search_options)
	ed.search_hit_index = ed.search_panel.hit_index
	ed.search_hit_total = ed.search_panel.hit_total
	ed.search_hit_generation = b.buffer.generation()
}

// panel_action_replace replaces the current match with the replacement
// string and selects the next hit. Empty needle or no active match are
// reported via search_panel.error.
fn (mut ed Editor) panel_action_replace() {
	needle := ed.search_panel.needle
	if needle == '' {
		ed.search_panel.error = 'no needle'
		return
	}
	if ed.search_options.use_regex {
		err := regex_error(needle)
		if err != '' {
			ed.search_panel.error = 'invalid regex: ${err}'
			return
		}
	}
	ed.last_search = needle
	mut b := &ed.docs[ed.active].buf
	b.find_and_replace(needle, ed.search_options, ed.search_panel.replacement.bytes())
	b.make_cursor_visible()
	if !b.has_selection() {
		ed.search_panel.error = 'not found: ${needle}'
	} else {
		ed.search_panel.error = ''
	}
	ed.update_search_stats_for_panel()
}

// panel_action_replace_all replaces every match in a single edit group
// (PLAN §6.3, mirroring find_and_replace_all).
fn (mut ed Editor) panel_action_replace_all() {
	needle := ed.search_panel.needle
	if needle == '' {
		ed.search_panel.error = 'no needle'
		return
	}
	if ed.search_options.use_regex {
		err := regex_error(needle)
		if err != '' {
			ed.search_panel.error = 'invalid regex: ${err}'
			return
		}
	}
	ed.last_search = needle
	ed.last_replacement = ed.search_panel.replacement
	mut b := &ed.docs[ed.active].buf
	count := b.find_and_replace_all(needle, ed.search_options, ed.search_panel.replacement.bytes())
	b.make_cursor_visible()
	ed.status = if count > 0 {
		'replaced ${count} occurrences'
	} else {
		'not found: ${needle}'
	}
	ed.search_panel.error = if count > 0 { '' } else { 'not found: ${needle}' }
	ed.update_search_stats_for_panel()
}

// panel_action_activate dispatches Enter to the right action depending on
// the current focus. Used by handle_search_panel_key and by mouse clicks.
fn (mut ed Editor) panel_action_activate() {
	match ed.search_panel.focus {
		.needle {
			ed.last_search = ed.search_panel.needle
			ed.run_panel_search()
		}
		.replacement {
			ed.panel_action_replace()
		}
		.replace_btn {
			ed.panel_action_replace()
		}
		.replace_all_btn {
			ed.panel_action_replace_all()
		}
		.close_btn {
			ed.close_search_panel()
		}
		else {
			match ed.search_panel.focus {
				.match_case { ed.search_panel_toggle_option(.match_case) }
				.whole_word { ed.search_panel_toggle_option(.whole_word) }
				.regex { ed.search_panel_toggle_option(.use_regex) }
				else { ed.run_panel_search() }
			}
		}
	}
	ed.needs_redraw = true
}

// search_panel_layout returns (top_row, has_replace_row). top_row is the
// row index where the needle is drawn; has_replace_row indicates whether
// the replacement row is visible (replace mode only, when there's room).
fn (ed &Editor) search_panel_layout() (CoordType, bool) {
	if ed.size.height >= 5 {
		return CoordType(1), ed.search_panel.kind == .replace
	}
	// Tiny terminals reserve the last row for the status bar. The panel is
	// reduced to a single needle row; keyboard focus still exposes all actions.
	return coord_max(ed.size.height - 3, 1), false
}

// draw_search_panel renders the persistent panel. Layout (PLAN §6.2.1):
//   Search:  <needle>       [Case] [Word] [Regex]   <hit>
//   Replace: <replacement>  [Replace] [Replace All] [Close]
// When `top=true` the block sits between the menu bar and the text area.
// When the terminal is too short, the block collapses to two/three rows
// right above the status bar.
fn (mut ed Editor) draw_search_panel() {
	if !ed.search_panel.visible {
		return
	}
	top_row, has_replace := ed.search_panel_layout()
	width := ed.size.width
	ed.search_buttons = []SearchButton{}
	ed.panel_buttons = []PanelButton{}

	// Row 1: needle.
	needle_text := ' Search: ${ed.search_panel.needle}'
	ed.fb.replace_text(top_row, 0, width, needle_text)
	ed.panel_buttons << PanelButton{
		focus: .needle
		row:   top_row
		left:  0
		right: width
	}

	// Row 2: option toggles + right-aligned hit counter.
	options_row := top_row + 1
	mut opt_text := ''
	mut bx := CoordType(0)
	option_specs := [
		SearchButtonKind.match_case,
		SearchButtonKind.whole_word,
		SearchButtonKind.use_regex,
	]
	for kind in option_specs {
		label := match kind {
			.match_case { ' ${if ed.search_options.match_case { '[x]' } else { '[ ]' }} Case ' }
			.whole_word { ' ${if ed.search_options.whole_word { '[x]' } else { '[ ]' }} Word ' }
			.use_regex { ' ${if ed.search_options.use_regex { '[x]' } else { '[ ]' }} Regex ' }
		}
		focus := match kind {
			.match_case { SearchPanelFocus.match_case }
			.whole_word { SearchPanelFocus.whole_word }
			.use_regex { SearchPanelFocus.regex }
		}
		ed.search_buttons << SearchButton{
			kind:  kind
			left:  bx
			right: bx + CoordType(label.len)
		}
		ed.panel_buttons << PanelButton{
			focus: focus
			row:   options_row
			left:  bx
			right: bx + CoordType(label.len)
		}
		opt_text += label
		bx += CoordType(label.len)
	}
	if options_row < ed.size.height - 1 {
		ed.fb.replace_text(options_row, 0, width, opt_text)
	}

	// Highlight the focused option, if any.
	for btn in ed.panel_buttons {
		if btn.row == options_row && btn.focus == ed.search_panel.focus && options_row < ed.size.height - 1 {
			mut fr := Rect{
				left:   btn.left
				top:    options_row
				right:  btn.right
				bottom: options_row + 1
			}
			ed.fb.reverse(mut fr)
			break
		}
	}

	// Right-aligned hit counter / soft error.
	mut right_text := ''
	if ed.search_panel.error != '' {
		right_text = ed.search_panel.error
	} else if ed.search_panel.hit_total > 0 {
		right_text = if ed.search_panel.hit_index > 0 {
			'${ed.search_panel.hit_index}/${ed.search_panel.hit_total}'
		} else {
			'${ed.search_panel.hit_total}'
		}
	}
	if right_text != '' && options_row < ed.size.height - 1 {
		reserved_right := if !has_replace { width - CoordType('[Close]'.len) - 2 } else { width }
		ctr_x := reserved_right - CoordType(right_text.len) - 1
		if ctr_x > bx {
			ed.fb.replace_text(options_row, ctr_x, reserved_right, right_text)
		}
	}
	// Search mode still exposes a visible Close action, aligned to the right
	// of the options row when there is room.
	if !has_replace && options_row < ed.size.height - 1 {
		close_label := '[Close]'
		close_x := width - CoordType(close_label.len) - 1
		if close_x >= bx {
			ed.fb.replace_text(options_row, close_x, width, close_label)
			ed.panel_buttons << PanelButton{ focus: .close_btn, row: options_row, left: close_x, right: close_x + CoordType(close_label.len) }
			if ed.search_panel.focus == .close_btn {
				mut fr := Rect{ left: close_x, top: options_row, right: close_x + CoordType(close_label.len), bottom: options_row + 1 }
				ed.fb.reverse(mut fr)
			}
		}
	}

	// Row 3: replacement field + action buttons (replace mode only).
	mut repl_row := options_row
	if has_replace {
		repl_row = top_row + 2
		repl_text := ' Replace: ${ed.search_panel.replacement}'
		ed.fb.replace_text(repl_row, 0, width, repl_text)
		ed.panel_buttons << PanelButton{
			focus: .replacement
			row:   repl_row
			left:  0
			right: width
		}
		actions := [
			SearchPanelFocus.replace_btn,
			SearchPanelFocus.replace_all_btn,
			SearchPanelFocus.close_btn,
		]
		labels := ['[Replace]', '[Replace All]', '[Close]']
		mut total := CoordType(0)
		for label in labels {
			total += CoordType(label.len) + 1
		}
		mut ax := width - total - 1
		if ax > CoordType(repl_text.len) {
			for i, label in labels {
				ed.fb.replace_text(repl_row, ax, width, label)
				ed.panel_buttons << PanelButton{
					focus: actions[i]
					row:   repl_row
					left:  ax
					right: ax + CoordType(label.len)
				}
				if ed.search_panel.focus == actions[i] {
					mut fr := Rect{
						left:   ax
						top:    repl_row
						right:  ax + CoordType(label.len)
						bottom: repl_row + 1
					}
					ed.fb.reverse(mut fr)
				}
				ax += CoordType(label.len) + 1
			}
		}
	}

	// Position the terminal cursor at the active editing field.
	if ed.search_panel.focus == .replacement && has_replace {
		ed.fb.set_cursor(Point{
			x: ed.search_panel_active_byte_width('Replace:')
			y: repl_row
		}, false)
	} else if ed.search_panel.focus == .needle {
		ed.fb.set_cursor(Point{
			x: ed.search_panel_active_byte_width('Search:')
			y: top_row
		}, false)
	}
}

// handle_search_panel_mouse routes a mouse event to the panel. Returns true
// when the event was consumed (a panel row was clicked); false lets the
// caller fall through to the text area.
fn (mut ed Editor) handle_search_panel_mouse(mouse InputMouse) bool {
	if !ed.search_panel.visible || mouse.drag || mouse.state != .left {
		return false
	}
	// The final row belongs to the status bar even in compact layouts.
	if mouse.position.y >= ed.size.height - 1 {
		return false
	}
	mut hit := PanelButton{
		focus: .needle
		row:   -1
	}
	for btn in ed.panel_buttons {
		if mouse.position.y == btn.row && mouse.position.x >= btn.left
			&& mouse.position.x < btn.right {
			// Full-width text-field rows come first in panel_buttons, so a
			// narrower button on the same row wins.
			if hit.row < 0 || (btn.right - btn.left) < (hit.right - hit.left) {
				hit = btn
			}
		}
	}
	if hit.row < 0 {
		// Consume clicks in the panel's occupied rows even when they land in
		// padding, so they cannot reposition the document cursor underneath.
		top_row, has_replace := ed.search_panel_layout()
		rows := if has_replace { CoordType(3) } else { CoordType(2) }
		panel_bottom := coord_min(top_row + rows, ed.size.height - 1)
		if mouse.position.y >= top_row && mouse.position.y < panel_bottom {
			return true
		}
		return false
	}
	ed.needs_redraw = true
	match hit.focus {
		.needle, .replacement {
			ed.search_panel.focus = hit.focus
			search_panel_normalize_focus(mut ed.search_panel)
		}
		.match_case {
			ed.search_panel.focus = hit.focus
			search_panel_normalize_focus(mut ed.search_panel)
			ed.search_panel_toggle_option(.match_case)
		}
		.whole_word {
			ed.search_panel.focus = hit.focus
			search_panel_normalize_focus(mut ed.search_panel)
			ed.search_panel_toggle_option(.whole_word)
		}
		.regex {
			ed.search_panel.focus = hit.focus
			search_panel_normalize_focus(mut ed.search_panel)
			ed.search_panel_toggle_option(.use_regex)
		}
		.replace_btn {
			ed.panel_action_replace()
		}
		.replace_all_btn {
			ed.panel_action_replace_all()
		}
		.close_btn {
			ed.close_search_panel()
		}
	}
	return true
}

// handle_search_panel_key routes a single key to the search panel. Returns
// true when the key was consumed. The caller in handle_event short-circuits
// the editor/textarea path on true.
fn (mut ed Editor) handle_search_panel_key(key InputKey) bool {
	if !ed.search_panel.visible {
		return false
	}
	mods := u32(key) & kbmod_mask
	vk := u32(key) & vk_mask

	match vk {
		vk_escape {
			ed.close_search_panel()
			return true
		}
		vk_tab {
			if mods == kbmod_none || mods == kbmod_shift {
				delta := if mods == kbmod_shift { -1 } else { 1 }
				search_panel_cycle(mut ed.search_panel, delta)
				ed.needs_redraw = true
				return true
			}
		}
		vk_return {
			if mods == kbmod_none {
				ed.panel_action_activate()
				return true
			}
			if mods == kbmod_ctrl_alt && ed.search_panel.kind == .replace {
				ed.panel_action_replace_all()
				return true
			}
		}
		vk_f3 {
			if mods == kbmod_none {
				needle := ed.search_panel.needle
				if needle != '' {
					ed.last_search = needle
				}
				ed.find_next()
				ed.update_search_stats_for_panel()
				return true
			}
			if mods == kbmod_shift {
				needle := ed.search_panel.needle
				if needle != '' {
					ed.last_search = needle
				}
				ed.find_previous()
				ed.update_search_stats_for_panel()
				return true
			}
		}
		vk_up, vk_down {
			if mods == kbmod_none {
				needle := ed.search_panel.needle
				if needle != '' {
					ed.last_search = needle
				}
				if vk == vk_up {
					ed.find_previous()
				} else {
					ed.find_next()
				}
				ed.update_search_stats_for_panel()
				return true
			}
		}
		vk_left {
			if mods == kbmod_none || mods == kbmod_shift {
				ed.search_panel_text_move_left(mods == kbmod_shift)
				return true
			}
		}
		vk_right {
			if mods == kbmod_none || mods == kbmod_shift {
				ed.search_panel_text_move_right(mods == kbmod_shift)
				return true
			}
		}
		vk_home {
			if mods == kbmod_none || mods == kbmod_shift {
				ed.search_panel_text_move_home(mods == kbmod_shift)
				return true
			}
		}
		vk_end {
			if mods == kbmod_none || mods == kbmod_shift {
				ed.search_panel_text_move_end(mods == kbmod_shift)
				return true
			}
		}
		vk_back {
			if mods == kbmod_none {
				ed.search_panel_text_backspace()
				return true
			}
		}
		vk_delete {
			if mods == kbmod_none {
				ed.search_panel_text_delete()
				return true
			}
		}
		vk_a {
			if mods == kbmod_ctrl {
				ed.search_panel_text_select_all()
				return true
			}
		}
		vk_k {
			if mods == kbmod_ctrl {
				ed.search_panel_text_kill_to_end()
				return true
			}
		}
		vk_u {
			if mods == kbmod_ctrl {
				ed.search_panel_text_kill_line()
				return true
			}
		}
		vk_c {
			if mods == kbmod_alt {
				ed.search_panel_toggle_option(.match_case)
				return true
			}
		}
		vk_w {
			if mods == kbmod_alt {
				ed.search_panel_toggle_option(.whole_word)
				return true
			}
		}
		vk_r {
			if mods == kbmod_alt {
				ed.search_panel_toggle_option(.use_regex)
				return true
			}
		}
		else {}
	}
	// While the panel is open, ordinary editor keys must not fall through to
	// the textarea. Keep only explicit global document/file commands alive.
	if mods == kbmod_ctrl && vk in [vk_f, vk_g, vk_n, vk_o, vk_p, vk_q, vk_r, vk_s, vk_w] {
		return false
	}
	return true
}

// handle_search_panel_text appends one or more printable bytes to the
// focused editing field, then re-runs the incremental search so the result
// reflects the new needle.
fn (mut ed Editor) handle_search_panel_text(text string) bool {
	if !ed.search_panel.visible {
		return false
	}
	if !ed.search_panel_is_editing() {
		return true
	}
	ed.search_panel_text_insert(text)
	if ed.search_panel.focus == .needle {
		ed.run_panel_search()
	}
	ed.needs_redraw = true
	return true
}

// search_panel_text_insert appends the given text at the cursor of the
// focused editing field. Newlines and tabs are stripped (single-line
// editline semantics, matching the old prompt behavior).
fn (mut ed Editor) search_panel_text_insert(text string) {
	mut sanitized := text.replace('\n', '').replace('\r', '').replace('\t', '')
	if sanitized.len == 0 {
		return
	}
	match ed.search_panel.focus {
		.needle {
			mut c := ed.search_panel.needle_cursor
			off := if c < 0 || c > ed.search_panel.needle.len {
				ed.search_panel.needle.len
			} else {
				c
			}
			beg, end := search_panel_selection(ed.search_panel.needle_anchor, off, ed.search_panel.needle.len)
			ed.search_panel.needle = ed.search_panel.needle[..beg] + sanitized + ed.search_panel.needle[end..]
			ed.search_panel.needle_cursor = beg + sanitized.len
			ed.search_panel.needle_anchor = -1
		}
		.replacement {
			mut c := ed.search_panel.replacement_cursor
			off := if c < 0 || c > ed.search_panel.replacement.len {
				ed.search_panel.replacement.len
			} else {
				c
			}
			beg, end := search_panel_selection(ed.search_panel.replacement_anchor, off, ed.search_panel.replacement.len)
			ed.search_panel.replacement = ed.search_panel.replacement[..beg] + sanitized + ed.search_panel.replacement[end..]
			ed.search_panel.replacement_cursor = beg + sanitized.len
			ed.search_panel.replacement_anchor = -1
		}
		else {}
	}
	ed.search_panel.error = ''
}

fn search_panel_selection(anchor int, cursor int, length int) (int, int) {
	c := if cursor < 0 { 0 } else if cursor > length { length } else { cursor }
	if anchor < 0 || anchor == c {
		return c, c
	}
	a := if anchor > length { length } else { anchor }
	return if a < c { a } else { c }, if a > c { a } else { c }
}

// search_panel_text_backspace removes one UTF-8 codepoint before the cursor.
fn (mut ed Editor) search_panel_text_backspace() {
	match ed.search_panel.focus {
		.needle {
			mut c := ed.search_panel.needle_cursor
			beg, end := search_panel_selection(ed.search_panel.needle_anchor, c, ed.search_panel.needle.len)
			if beg != end {
				ed.search_panel.needle = ed.search_panel.needle[..beg] + ed.search_panel.needle[end..]
				ed.search_panel.needle_cursor = beg
				ed.search_panel.needle_anchor = -1
				ed.search_panel.error = ''
				if ed.search_panel.focus == .needle { ed.run_panel_search() }
				return
			}
			if c <= 0 {
				return
			}
			if c > ed.search_panel.needle.len {
				c = ed.search_panel.needle.len
			}
			prev := prompt_prev_codepoint(ed.search_panel.needle, c)
			ed.search_panel.needle = ed.search_panel.needle[..prev] + ed.search_panel.needle[c..]
			ed.search_panel.needle_cursor = prev
			ed.search_panel.needle_anchor = -1
		}
		.replacement {
			mut c := ed.search_panel.replacement_cursor
			beg, end := search_panel_selection(ed.search_panel.replacement_anchor, c, ed.search_panel.replacement.len)
			if beg != end {
				ed.search_panel.replacement = ed.search_panel.replacement[..beg] + ed.search_panel.replacement[end..]
				ed.search_panel.replacement_cursor = beg
				ed.search_panel.replacement_anchor = -1
				ed.search_panel.error = ''
				return
			}
			if c <= 0 {
				return
			}
			if c > ed.search_panel.replacement.len {
				c = ed.search_panel.replacement.len
			}
			prev := prompt_prev_codepoint(ed.search_panel.replacement, c)
			ed.search_panel.replacement = ed.search_panel.replacement[..prev] + ed.search_panel.replacement[c..]
			ed.search_panel.replacement_cursor = prev
			ed.search_panel.replacement_anchor = -1
		}
		else {}
	}
	ed.search_panel.error = ''
	if ed.search_panel.focus == .needle { ed.run_panel_search() }
}

// search_panel_text_delete removes one UTF-8 codepoint at the cursor.
fn (mut ed Editor) search_panel_text_delete() {
	match ed.search_panel.focus {
		.needle {
			c := ed.search_panel.needle_cursor
			beg, end := search_panel_selection(ed.search_panel.needle_anchor, c, ed.search_panel.needle.len)
			if beg != end {
				ed.search_panel.needle = ed.search_panel.needle[..beg] + ed.search_panel.needle[end..]
				ed.search_panel.needle_cursor = beg
				ed.search_panel.needle_anchor = -1
				ed.search_panel.error = ''
				ed.run_panel_search()
				return
			}
			if c >= ed.search_panel.needle.len {
				return
			}
			nxt := prompt_next_codepoint(ed.search_panel.needle, c)
			ed.search_panel.needle = ed.search_panel.needle[..c] + ed.search_panel.needle[nxt..]
		}
		.replacement {
			c := ed.search_panel.replacement_cursor
			beg, end := search_panel_selection(ed.search_panel.replacement_anchor, c, ed.search_panel.replacement.len)
			if beg != end {
				ed.search_panel.replacement = ed.search_panel.replacement[..beg] + ed.search_panel.replacement[end..]
				ed.search_panel.replacement_cursor = beg
				ed.search_panel.replacement_anchor = -1
				ed.search_panel.error = ''
				return
			}
			if c >= ed.search_panel.replacement.len {
				return
			}
			nxt := prompt_next_codepoint(ed.search_panel.replacement, c)
			ed.search_panel.replacement = ed.search_panel.replacement[..c] + ed.search_panel.replacement[nxt..]
		}
		else {}
	}
	ed.search_panel.error = ''
	if ed.search_panel.focus == .needle { ed.run_panel_search() }
}

fn (mut ed Editor) search_panel_text_move_left(extend bool) {
	match ed.search_panel.focus {
		.needle {
			if !extend { ed.search_panel.needle_anchor = -1 } else if ed.search_panel.needle_anchor < 0 { ed.search_panel.needle_anchor = ed.search_panel.needle_cursor }
			c := ed.search_panel.needle_cursor
			if c > 0 {
				ed.search_panel.needle_cursor = prompt_prev_codepoint(ed.search_panel.needle, c)
			}
		}
		.replacement {
			if !extend { ed.search_panel.replacement_anchor = -1 } else if ed.search_panel.replacement_anchor < 0 { ed.search_panel.replacement_anchor = ed.search_panel.replacement_cursor }
			c := ed.search_panel.replacement_cursor
			if c > 0 {
				ed.search_panel.replacement_cursor = prompt_prev_codepoint(ed.search_panel.replacement, c)
			}
		}
		else {}
	}
}

fn (mut ed Editor) search_panel_text_move_right(extend bool) {
	match ed.search_panel.focus {
		.needle {
			if !extend { ed.search_panel.needle_anchor = -1 } else if ed.search_panel.needle_anchor < 0 { ed.search_panel.needle_anchor = ed.search_panel.needle_cursor }
			c := ed.search_panel.needle_cursor
			if c < ed.search_panel.needle.len {
				ed.search_panel.needle_cursor = prompt_next_codepoint(ed.search_panel.needle, c)
			}
		}
		.replacement {
			if !extend { ed.search_panel.replacement_anchor = -1 } else if ed.search_panel.replacement_anchor < 0 { ed.search_panel.replacement_anchor = ed.search_panel.replacement_cursor }
			c := ed.search_panel.replacement_cursor
			if c < ed.search_panel.replacement.len {
				ed.search_panel.replacement_cursor = prompt_next_codepoint(ed.search_panel.replacement, c)
			}
		}
		else {}
	}
}

fn (mut ed Editor) search_panel_text_move_home(extend bool) {
	match ed.search_panel.focus {
		.needle {
			if !extend { ed.search_panel.needle_anchor = -1 } else if ed.search_panel.needle_anchor < 0 { ed.search_panel.needle_anchor = ed.search_panel.needle_cursor }
			ed.search_panel.needle_cursor = 0
		}
		.replacement {
			if !extend { ed.search_panel.replacement_anchor = -1 } else if ed.search_panel.replacement_anchor < 0 { ed.search_panel.replacement_anchor = ed.search_panel.replacement_cursor }
			ed.search_panel.replacement_cursor = 0
		}
		else {}
	}
}

fn (mut ed Editor) search_panel_text_move_end(extend bool) {
	match ed.search_panel.focus {
		.needle {
			if !extend { ed.search_panel.needle_anchor = -1 } else if ed.search_panel.needle_anchor < 0 { ed.search_panel.needle_anchor = ed.search_panel.needle_cursor }
			ed.search_panel.needle_cursor = ed.search_panel.needle.len
		}
		.replacement {
			if !extend { ed.search_panel.replacement_anchor = -1 } else if ed.search_panel.replacement_anchor < 0 { ed.search_panel.replacement_anchor = ed.search_panel.replacement_cursor }
			ed.search_panel.replacement_cursor = ed.search_panel.replacement.len
		}
		else {}
	}
}

fn (mut ed Editor) search_panel_text_kill_to_end() {
	match ed.search_panel.focus {
		.needle {
			c := ed.search_panel.needle_cursor
			if c < ed.search_panel.needle.len {
				ed.search_panel.needle = ed.search_panel.needle[..c]
			}
			ed.search_panel.needle_anchor = -1
		}
		.replacement {
			c := ed.search_panel.replacement_cursor
			if c < ed.search_panel.replacement.len {
				ed.search_panel.replacement = ed.search_panel.replacement[..c]
			}
			ed.search_panel.replacement_anchor = -1
		}
		else {}
	}
	if ed.search_panel.focus == .needle { ed.run_panel_search() }
}

fn (mut ed Editor) search_panel_text_kill_line() {
	match ed.search_panel.focus {
		.needle {
			ed.search_panel.needle = ''
			ed.search_panel.needle_cursor = 0
			ed.search_panel.needle_anchor = -1
		}
		.replacement {
			ed.search_panel.replacement = ''
			ed.search_panel.replacement_cursor = 0
			ed.search_panel.replacement_anchor = -1
		}
		else {}
	}
	if ed.search_panel.focus == .needle { ed.run_panel_search() }
}

fn (mut ed Editor) search_panel_text_select_all() {
	match ed.search_panel.focus {
		.needle {
			ed.search_panel.needle_anchor = 0
			ed.search_panel.needle_cursor = ed.search_panel.needle.len
		}
		.replacement {
			ed.search_panel.replacement_anchor = 0
			ed.search_panel.replacement_cursor = ed.search_panel.replacement.len
		}
		else {}
	}
}
