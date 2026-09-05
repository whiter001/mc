module main

// terminal_title.v — extracted from main.v.
//
// OSC 0 terminal-title sync. The main loop calls
// update_terminal_title() once per redraw; the function diff-checks
// the active document's filename and dirty flag against the last
// emitted title and writes the new value only on change, matching
// the diff-on-write pattern in Rust write_terminal_title.
//
// State lives on the Editor struct in main.v (title_filename,
// title_dirty); only the method moves here.

import os

// update_terminal_title emits OSC 0;... ST to set the terminal
// window title to "<dirty?● :><filename> - edit". It only writes
// when the active document's filename or dirty flag actually
// changes. Untracked docs use an empty filename (omitted from the
// payload); the title then reads just "edit".
fn (mut ed Editor) update_terminal_title() {
	filename := if ed.active < ed.docs.len && ed.docs[ed.active].path != '' {
		os.file_name(ed.docs[ed.active].path)
	} else {
		''
	}
	dirty := ed.active < ed.docs.len && ed.docs[ed.active].buf.is_dirty()
	if filename == ed.title_filename && dirty == ed.title_dirty {
		return
	}
	mut payload := '\x1b]0;'
	if dirty {
		payload += '\u25cf ' // ●
	}
	if filename != '' {
		payload += filename + ' - '
	}
	payload += 'edit\x1b\\'
	write_stdout(payload)
	ed.title_filename = filename
	ed.title_dirty = dirty
}
