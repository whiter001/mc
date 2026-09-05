module main

// dirty_modal.v — extracted from main.v.
//
// Three-button modal that pops up when Ctrl+W (close) or Ctrl+Q
// (quit) is pressed on a dirty document. Buttons: Save / Don't
// Save / Cancel. The keyboard handler (left/right arrows, Enter,
// S/N/Esc accelerators) stays in main.v's handle_event() because
// it has to interleave with the rest of the input loop; this
// file owns only the modal's draw pass and the action resolution.
//
// State lives on the Editor struct in main.v (dirty_modal,
// dirty_action, dirty_for_quit).

// resolve_dirty_modal performs the action chosen in the dirty
// modal and returns true so the caller can return early from
// handle_event.
fn (mut ed Editor) resolve_dirty_modal() bool {
	action := ed.dirty_action
	ed.dirty_modal = false
	match action {
		0 {
			// Save then continue with close/quit. If save opens the
			// file picker (path is empty), the picker takes over the
			// input loop and the modal is already closed.
			ed.save_active()
			if ed.dirty_for_quit {
				ed.quit = true
			} else {
				ed.docs.delete(ed.active)
				if ed.docs.len == 0 {
					ed.quit = true
					return true
				}
				if ed.active >= ed.docs.len {
					ed.active = ed.docs.len - 1
				}
				ed.reset_view_state()
			}
		}
		1 {
			// Discard changes.
			if ed.dirty_for_quit {
				ed.quit = true
			} else {
				ed.docs.delete(ed.active)
				if ed.docs.len == 0 {
					ed.quit = true
					return true
				}
				if ed.active >= ed.docs.len {
					ed.active = ed.docs.len - 1
				}
				ed.reset_view_state()
			}
		}
		2 {
			// Cancel: do nothing.
		}
		else {}
	}
	return true
}

// draw_dirty_modal draws the centered "Save / Don't Save / Cancel"
// panel. The currently-selected button is highlighted by being
// rendered with the normal (double-reverse) colors while the
// others stay reversed, matching the rest of the editor's modal
// styling.
fn (mut ed Editor) draw_dirty_modal() {
	lines := [
		if ed.dirty_for_quit { 'Quit: unsaved changes' } else { 'Close: unsaved changes' },
		'',
		" Save   Don't Save   Cancel ",
	]
	box_w := CoordType(36)
	box_h := CoordType(lines.len)
	left := coord_max((ed.size.width - box_w) / 2, 0)
	top := coord_max((ed.size.height - box_h) / 2, 0)
	right := coord_min(left + box_w, ed.size.width)
	for i, text in lines {
		y := top + CoordType(i)
		if y >= ed.size.height {
			break
		}
		ed.fb.replace_text(y, left, right, picker_fit_line(text, box_w))
		mut row := Rect{
			left:   left
			top:    y
			right:  right
			bottom: y + 1
		}
		ed.fb.reverse(mut row)
	}
	// Highlight the focused button by rendering a thinner row on top of it.
	btn_y := top + 2
	if btn_y < ed.size.height {
		// Layout: " Save   Don't Save   Cancel " — columns 1, 8, 19
		// within the 36-wide box, with the focused label spanning its
		// column.
		btn_cols := [CoordType(1), CoordType(8), CoordType(19)]
		btn_widths := [CoordType(4), CoordType(11), CoordType(6)]
		if ed.dirty_action >= 0 && ed.dirty_action < 3 {
			bx := left + btn_cols[ed.dirty_action]
			mut btn_row := Rect{
				left:   bx
				top:    btn_y
				right:  bx + btn_widths[ed.dirty_action]
				bottom: btn_y + 1
			}
			ed.fb.reverse(mut btn_row)
		}
	}
}
