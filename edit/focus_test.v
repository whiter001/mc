module main

fn test_focus_cycle_wraps_in_both_directions() {
	assert focus_cycle_index(2, 3, false) == 0
	assert focus_cycle_index(0, 3, true) == 2
	assert focus_cycle_index(1, 0, false) == 0
}

fn test_focus_manager_steal_pop_and_request() {
	mut f := FocusManager{}
	f.steal(.search_panel, 2)
	f.steal(.dirty_modal, 1)
	assert f.target == .dirty_modal
	assert f.index == 1
	f.pop()
	assert f.target == .search_panel
	assert f.index == 2
	f.request(.statusbar)
	assert f.take_request() == .statusbar
	assert f.take_request() == .none
}
