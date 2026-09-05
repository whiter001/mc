module main

// error_log.v — extracted from main.v.
//
// Ring buffer of recent error messages plus the centered modal that
// surfaces them. State lives on the Editor struct in main.v; only
// the methods and the capacity constant move here so main.v stays
// focused on the main loop and event dispatch.
//
// Wire-up lives in main.v:
//   - draw() calls draw_error_log() when the ring is non-empty and
//     error_log_open is true.
//   - handle_event() dismisses the modal on any keyboard / text
//     event before doing anything else.

// error_log_capacity is the size of the circular error log buffer
// (matches the Rust reference's fixed-size ring).
const error_log_capacity = 8

// error_log_add records a new error in the ring buffer and pops the
// modal open. Empty messages are ignored (mirrors Rust `add_error`).
fn (mut ed Editor) error_log_add(msg string) {
	if msg == '' {
		return
	}
	if ed.error_log.len < error_log_capacity {
		// Grow to capacity the first few calls so the ring can wrap.
		for ed.error_log.len < error_log_capacity {
			ed.error_log << ''
		}
	}
	ed.error_log[ed.error_log_index] = msg
	ed.error_log_index = (ed.error_log_index + 1) % error_log_capacity
	if ed.error_log_count < error_log_capacity {
		ed.error_log_count++
	}
	ed.error_log_open = true
	ed.needs_redraw = true
}

// error_log_close dismisses the modal; the underlying entries stay
// around until overwritten so we can show them again on demand.
fn (mut ed Editor) error_log_close() {
	ed.error_log_open = false
	ed.needs_redraw = true
}

// draw_error_log draws the red error modal centered on the screen.
// Layout mirrors the Rust original: a title row, then one row per
// queued message (truncated from the right), then a dismiss hint.
// Any key dismisses the modal — both Enter/Escape and printable
// characters (the dismiss itself lives in handle_event()).
fn (mut ed Editor) draw_error_log() {
	mut lines := []string{}
	lines << 'Error'
	beg := (ed.error_log_index + error_log_capacity - ed.error_log_count) % error_log_capacity
	for i in 0 .. ed.error_log_count {
		idx := (beg + i) % error_log_capacity
		lines << ed.error_log[idx]
	}
	lines << ''
	lines << 'Press Enter or Esc to close'

	box_w := CoordType(60)
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
}
