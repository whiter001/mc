module main

// FocusTarget is the small set of focus wells used by the editor.  The
// individual widgets keep their own rich selection state; this manager only
// owns which widget receives keyboard focus and a one-shot focus request.
enum FocusTarget {
	none
	search_panel
	menu
	file_picker
	language_picker
	encoding_action
	encoding_picker
	dirty_modal
	statusbar
}

struct FocusManager {
mut:
	target FocusTarget
	index int
	previous_target FocusTarget
	previous_index int
	focus_request FocusTarget
}

fn (mut f FocusManager) steal(target FocusTarget, index int) {
	if f.target != target {
		f.previous_target = f.target
		f.previous_index = f.index
	}
	f.target = target
	f.index = index
}

fn (mut f FocusManager) pop() {
	f.target = f.previous_target
	f.index = f.previous_index
	f.previous_target = .none
	f.previous_index = 0
}

fn (mut f FocusManager) request(target FocusTarget) {
	f.focus_request = target
}

fn (mut f FocusManager) take_request() FocusTarget {
	target := f.focus_request
	f.focus_request = .none
	return target
}

fn focus_cycle_index(index int, count int, backwards bool) int {
	if count <= 0 {
		return 0
	}
	mut next := index
	if backwards {
		next = (next + count - 1) % count
	} else {
		next = (next + 1) % count
	}
	return next
}

// focus_sync keeps the manager aligned with the modal state.  It is called
// before routing an event, so a newly-opened modal captures focus immediately.
fn (mut ed Editor) focus_sync() {
	focus_request := ed.focus.take_request()
	if focus_request != .none {
		ed.focus.steal(focus_request, 0)
		if focus_request == .statusbar {
			ed.statusbar_focus_index = 0
		}
	}
	mut active := FocusTarget.none
	if ed.dirty_modal {
		active = .dirty_modal
	} else if ed.encoding_action_picker {
		active = .encoding_action
	} else if ed.encoding_picker {
		active = .encoding_picker
	} else if ed.language_picker {
		active = .language_picker
	} else if ed.picker {
		active = .file_picker
	} else if ed.menu_open || ed.menu_focus {
		active = .menu
	} else if ed.search_panel.visible {
		active = .search_panel
	} else if ed.focus.target == .statusbar {
		active = .statusbar
	}
	if active != .none {
		mut idx := ed.focus.index
		if active == .dirty_modal { idx = ed.dirty_action }
		if active == .search_panel { idx = ed.search_panel.focus_index }
		if active == .statusbar { idx = ed.statusbar_focus_index }
		ed.focus.steal(active, idx)
	} else if ed.focus.target != .none {
		ed.focus.pop()
	}
}

fn (mut ed Editor) focus_tab(backwards bool) bool {
	ed.focus_sync()
	match ed.focus.target {
		.dirty_modal {
			ed.dirty_action = focus_cycle_index(ed.dirty_action, 3, backwards)
			ed.focus.index = ed.dirty_action
			return true
		}
		.encoding_action {
			ed.encoding_action_sel = focus_cycle_index(ed.encoding_action_sel, 2, backwards)
			ed.focus.index = ed.encoding_action_sel
			return true
		}
		.encoding_picker {
			// The picker effectively has a single focus well: typing always
			// filters the needle and arrow keys always move the list
			// selection, so focus.index is never observed. Consuming Tab
			// keeps focus trapped inside the modal instead of leaking to
			// the editor — same rationale as .language_picker.
			return true
		}
		.language_picker {
			// A single list has no additional controls, but consuming Tab keeps
			// focus inside the modal instead of leaking to the editor.
			return true
		}
		.statusbar {
			count := ed.statusbar_focus_count()
			ed.statusbar_focus_index = focus_cycle_index(ed.statusbar_focus_index, count, backwards)
			ed.focus.index = ed.statusbar_focus_index
			return true
		}
		else {}
	}
	return false
}
