module main

// Minimal runnable editor loop, modeled after crates/edit/src/bin/edit/main.rs
// (microsoft/edit). Scope: multiple documents, a status-line prompt for
// open/save-as/search/goto, mouse click/scroll, and a menu bar with an
// About dialog (see menubar.v).
//
// Exit paths MUST call restore_terminal(): V has no destructors, so the
// RestoreModes guard of the Rust original is replicated manually here.

import os
import encoding.base64

// Terminal setup/teardown sequences, same as the Rust original (main.rs).
const term_init_seq = '\x1b[?1049h\x1b[?1002;1006;2004h\x1b[?1036h'
const term_exit_seq = '\x1b[0 q\x1b[?25h\x1b]0;\x07\x1b[?1002;1006;2004l\x1b[?1049l'

const kbmod_mask = u32(0xff000000)
const vk_mask = u32(0x00ffffff)

// PromptKind identifies what the status-line prompt is for.
enum PromptKind {
	search
	replace
	replace_with
	goto_line
}

// EditMode is the top-level input mode of the editor.
enum EditMode {
	edit
	prompt
}

// Document is a single open file (or untitled buffer).
struct Document {
mut:
	buf  TextBuffer
	path string
}

struct Editor {
mut:
	docs             []Document
	active           int
	clipboard        Clipboard
	parser           InputParser
	fb               Framebuffer
	size             Size
	scroll           Point
	scroll_x_max     CoordType
	preferred_column CoordType
	needs_redraw     bool
	quit             bool
	status           string
	// Mode & prompt state.
	mode             EditMode
	prompt_kind      PromptKind
	prompt_text      string
	// Last search, for F3 (= find next).
	last_search      string
	// Last replacement text; persists across Ctrl+R invocations like Rust's
	// state.search_replacement, so a repeat Enter repeats the same replace
	// instead of deleting the match with an empty replacement.
	last_replacement string
	// The needle collected by the first Ctrl+R prompt, used by the second.
	replace_needle   string
	// Dirty-quit protection: the first Ctrl+W/Ctrl+Q on a dirty document
	// only warns; a second one within the same warning forces the action.
	close_armed      bool
	quit_armed       bool
	// Menu bar state (menubar.v): menu_focus = bar highlighted via F10,
	// menu_open = a dropdown is open, menu_idx/menu_item_idx = selection.
	menu_focus       bool
	menu_open        bool
	menu_idx         int
	menu_item_idx    int
	about_open       bool
	// Set when the replace prompt pair collects a needle for
	// find_and_replace_all (Edit > Replace All) instead of a single replace.
	replace_all      bool
	// File picker state (filepicker.v).
	picker           bool
	picker_save_as   bool
	picker_dir       string
	picker_name      string
	picker_entries   []string
	picker_sel       int
	picker_scroll    int
	picker_overwrite string
}

fn main() {
	mut paths := os.args[1..]
	if paths.len > 0 && (paths[0] == '-h' || paths[0] == '--help') {
		println('usage: edit [file...]')
		return
	}

	sys_init()

	mut ed := Editor{
		parser:       new_input_parser()
		fb:           framebuffer_new()
		needs_redraw: true
	}

	if paths.len == 0 {
		paths = ['']
	}
	for path in paths {
		ed.add_document(path) or {
			eprintln('edit: ${path}: ${err}')
			exit(1)
		}
	}

	// If stdin was redirected (e.g. `edit < file`), read keys from /dev/tty.
	// Unlike Rust's handle_stdin, the piped stdin content is NOT read into a
	// new document here (deliberate scope trim).
	reopen_stdin_if_redirected() or {}

	switch_modes() or {
		eprintln('edit: cannot switch terminal to raw mode: ${err}')
		exit(1)
	}
	write_stdout(term_init_seq)
	// Make the first read_stdin() report the window size as a resize event.
	inject_window_size_into_stdin()

	for !ed.quit {
		if ed.needs_redraw {
			ed.draw()
			ed.needs_redraw = false
		}
		ed.process_input()
	}

	write_stdout(term_exit_seq)
	restore_terminal()
}

// add_document opens a file (or an untitled buffer for '') and makes it active.
fn (mut ed Editor) add_document(path string) ! {
	mut doc := Document{
		buf:  new_text_buffer(false)
		path: path
	}
	doc.buf.set_margin_enabled(true)
	doc.buf.set_insert_final_newline(true)
	doc.buf.set_width(ed.text_width())
	if path != '' {
		doc.buf.read_file(path) or { return err }
		doc.buf.set_language(lsh_language_for_path(path))
	}
	ed.docs << doc
	ed.active = ed.docs.len - 1
	ed.reset_view_state()
}

// reset_view_state clears per-document view state after a document switch.
fn (mut ed Editor) reset_view_state() {
	ed.scroll = Point{}
	ed.scroll_x_max = 0
	ed.preferred_column = 0
	ed.close_armed = false
	ed.quit_armed = false
	ed.mode = .edit
	ed.prompt_text = ''
}

// cur returns the active document. Use `ed.docs[ed.active]` for mutation.
fn (ed &Editor) cur() &Document {
	return &ed.docs[ed.active]
}

// text_width returns the width available for text (excluding the margin).
fn (ed &Editor) text_width() CoordType {
	if ed.docs.len == 0 {
		return ed.size.width
	}
	return ed.size.width - ed.cur().buf.margin_width()
}

// any_dirty reports whether any document has unsaved changes.
fn (ed &Editor) any_dirty() bool {
	// Index loop: `for doc in ed.docs` would copy each Document (TextBuffer
	// included) into the loop variable.
	for i in 0 .. ed.docs.len {
		if ed.docs[i].buf.is_dirty() {
			return true
		}
	}
	return false
}

// process_input reads one chunk of stdin and applies all events it contains.
fn (mut ed Editor) process_input() {
	// While a lone ESC byte is pending, read_timeout_ms() suggests a short
	// timeout so it can resolve into an Escape keypress; otherwise we block
	// indefinitely instead of busy-polling.
	input := read_stdin(ed.parser.vt.read_timeout_ms()) or {
		if stdin_hit_eof() {
			// EOF: the terminal went away. Break the main loop, like the EOF
			// break in Rust main.rs.
			ed.quit = true
			return
		}
		''
	}
	events := ed.parser.parse(input)
	for ev in events {
		ed.handle_event(ev)
		ed.needs_redraw = true
		if ed.quit {
			break
		}
	}
	// Sync the internal clipboard to the host terminal via OSC 52.
	if ed.clipboard.wants_host_sync() {
		data := ed.clipboard.read()
		if data.len > 0 {
			write_stdout('\x1b]52;c;' + base64.encode(data) + '\x1b\\')
		}
		ed.clipboard.mark_as_synchronized()
	}
}

fn (mut ed Editor) handle_event(ev Input) {
	// Any event other than the Ctrl+W / Ctrl+Q keypresses themselves disarms
	// the dirty-close / quit warnings.
	is_arm_key := ev.kind == .keyboard
		&& (ev.key == kbmod_ctrl | vk_w || ev.key == kbmod_ctrl | vk_q)
	if !is_arm_key {
		ed.close_armed = false
		ed.quit_armed = false
	}

	// Resize always applies, even while a modal (About / file picker) is open.
	if ev.kind == .resize {
		ed.size = ev.size
		for i in 0 .. ed.docs.len {
			ed.docs[i].buf.set_width(ed.size.width - ed.docs[i].buf.margin_width())
		}
		return
	}

	// Any event dismisses the About dialog.
	if ed.about_open {
		ed.about_open = false
		return
	}

	// The file picker is modal: it swallows all input while open.
	if ed.picker {
		match ev.kind {
			.keyboard {
				ed.handle_picker_key(ev.key)
			}
			.text, .paste {
				// The name field is single-line: strip everything from the
				// first newline on.
				mut s := if ev.kind == .text { ev.text } else { ev.data.bytestr() }
				idx := s.index_any('\r\n')
				if idx >= 0 {
					s = s[..idx]
				}
				if ed.picker_overwrite != '' {
					// Overwrite warning: y confirms, n cancels (Rust:
					// consume_shortcut(vk::Y/N)); anything else is ignored.
					if s == 'y' || s == 'Y' {
						path := ed.picker_overwrite
						ed.picker_overwrite = ''
						ed.picker_do_save(path)
					} else if s == 'n' || s == 'N' {
						ed.picker_overwrite = ''
					}
				} else {
					ed.picker_name += s
				}
			}
			.mouse {
				ed.handle_picker_mouse(ev.mouse)
			}
			else {}
		}
		return
	}

	match ev.kind {
		.text, .paste {
			// While the menu bar is active, ignore text input and close it.
			if ed.menu_open || ed.menu_focus {
				ed.menu_open = false
				ed.menu_focus = false
				return
			}
			if ed.mode == .prompt {
				// The prompt is single-line: strip everything from the first
				// newline on (like strip_newline in the Rust editline).
				mut s := if ev.kind == .text { ev.text } else { ev.data.bytestr() }
				idx := s.index_any('\r\n')
				if idx >= 0 {
					s = s[..idx]
				}
				ed.prompt_text += s
			} else {
				data := if ev.kind == .text { ev.text.bytes() } else { ev.data }
				ed.docs[ed.active].buf.write_canon(data)
				ed.preferred_column = ed.docs[ed.active].buf.cursor_visual_pos().x
				ed.docs[ed.active].buf.make_cursor_visible()
			}
		}
		.keyboard {
			if ed.menu_open || ed.menu_focus {
				// A consumed key ends here; an unconsumed one has closed the
				// menu state and falls through to normal handling.
				if ed.handle_menu_key(ev.key) {
					return
				}
			}
			if ed.mode == .prompt {
				ed.handle_prompt_key(ev.key)
			} else {
				ed.handle_key(ev.key)
			}
		}
		.mouse {
			ed.handle_mouse(ev.mouse)
		}
		// .resize was already handled above, before the modal guards.
		.resize {}
	}
}

// ---- Prompt mode --------------------------------------------------------------

fn (mut ed Editor) start_prompt(kind PromptKind) {
	ed.mode = .prompt
	ed.prompt_kind = kind
	ed.prompt_text = match kind {
		// Prefill replace with the last search, replace_with with the last
		// replacement (Rust keeps both in state across invocations).
		.replace { ed.last_search }
		.replace_with { ed.last_replacement }
		else { '' }
	}
}

fn (mut ed Editor) cancel_prompt() {
	ed.mode = .edit
	ed.prompt_text = ''
}

fn (mut ed Editor) handle_prompt_key(key InputKey) {
	mods := u32(key) & kbmod_mask
	vk := u32(key) & vk_mask

	match vk {
		vk_escape {
			ed.cancel_prompt()
		}
		vk_return {
			if mods == kbmod_none {
				ed.confirm_prompt()
			}
		}
		vk_back {
			if mods == kbmod_none && ed.prompt_text.len > 0 {
				// Drop the last UTF-8 codepoint.
				mut n := 1
				for n < ed.prompt_text.len && n < 4
					&& (ed.prompt_text[ed.prompt_text.len - n] & 0xC0) == 0x80 {
					n++
				}
				ed.prompt_text = ed.prompt_text[..ed.prompt_text.len - n]
			}
		}
		else {}
	}
}

fn (mut ed Editor) confirm_prompt() {
	text := ed.prompt_text
	kind := ed.prompt_kind
	ed.cancel_prompt()

	match kind {
		.search {
			if text == '' {
				return
			}
			ed.last_search = text
			ed.find_next()
		}
		.replace {
			if text == '' {
				return
			}
			// Collect the needle, then ask for the replacement.
			ed.replace_needle = text
			ed.start_prompt(.replace_with)
		}
		.replace_with {
			// Remember the replacement so the next Ctrl+R can repeat it.
			ed.last_replacement = text
			if ed.replace_all {
				// Edit > Replace All: replace every occurrence in one edit
				// group and report the count (Rust SearchAction::ReplaceAll).
				ed.replace_all = false
				needle := ed.replace_needle
				if needle == '' {
					return
				}
				ed.last_search = needle
				mut b := &ed.docs[ed.active].buf
				count := b.find_and_replace_all(needle, SearchOptions{}, text.bytes())
				b.make_cursor_visible()
				ed.status = if count > 0 {
					'replaced ${count} occurrences'
				} else {
					'not found: ${needle}'
				}
			} else {
				ed.replace_active(text)
			}
		}
		.goto_line {
			n := text.int()
			if n > 0 {
				ed.docs[ed.active].buf.cursor_move_to_logical(Point{ x: 0, y: CoordType(n - 1) })
				ed.docs[ed.active].buf.make_cursor_visible()
			}
		}
	}
}

// find_next selects the next occurrence of the last search term (F3).
fn (mut ed Editor) find_next() {
	if ed.last_search == '' {
		return
	}
	mut b := &ed.docs[ed.active].buf
	// find_and_select() already advances past the previous hit via its
	// internal next_search_offset, as long as the selection is untouched.
	b.find_and_select(ed.last_search, SearchOptions{})
	b.make_cursor_visible()
	if !b.has_selection() {
		ed.status = 'not found: ${ed.last_search}'
	}
}

// replace_active replaces the current search hit (if the selection is one) and
// selects the next hit, like search_execute(SearchAction::Replace) in the Rust
// original. The first Ctrl+R on a fresh search just selects the first hit.
fn (mut ed Editor) replace_active(replacement string) {
	needle := ed.replace_needle
	if needle == '' {
		return
	}
	ed.last_search = needle
	mut b := &ed.docs[ed.active].buf
	b.find_and_replace(needle, SearchOptions{}, replacement.bytes())
	b.make_cursor_visible()
	if !b.has_selection() {
		ed.status = 'not found: ${needle}'
	}
}

// ---- Document management --------------------------------------------------------

// save_active saves the active document, opening the file picker in save-as
// mode if it has no path yet (Rust draw_handle_save).
fn (mut ed Editor) save_active() {
	if ed.docs[ed.active].path == '' {
		ed.open_picker(true)
		return
	}
	path := ed.docs[ed.active].path
	ed.docs[ed.active].buf.write_file(path) or {
		ed.status = 'save failed: ${err}'
		return
	}
	ed.docs[ed.active].buf.mark_as_clean()
	ed.status = 'saved ${path}'
}

// close_active closes the active document (Ctrl+W). Dirty documents require a
// second Ctrl+W to confirm.
fn (mut ed Editor) close_active() {
	if ed.docs[ed.active].buf.is_dirty() && !ed.close_armed {
		ed.close_armed = true
		ed.status = 'unsaved changes; press Ctrl+W again to discard'
		return
	}
	ed.docs.delete(ed.active)
	if ed.docs.len == 0 {
		ed.quit = true
		return
	}
	if ed.active >= ed.docs.len {
		ed.active = ed.docs.len - 1
	}
	ed.reset_view_state()
}

// next_document cycles to the next document (Ctrl+P).
fn (mut ed Editor) next_document() {
	if ed.docs.len > 1 {
		ed.active = (ed.active + 1) % ed.docs.len
		ed.reset_view_state()
	}
}

// request_exit quits, warning once if there are unsaved changes (Ctrl+Q).
fn (mut ed Editor) request_exit() {
	if ed.any_dirty() && !ed.quit_armed {
		ed.quit_armed = true
		ed.status = 'unsaved changes; press Ctrl+Q again to quit anyway'
		return
	}
	ed.quit = true
}

// ---- Editing keys ---------------------------------------------------------------

fn (mut ed Editor) handle_key(key InputKey) {
	mods := u32(key) & kbmod_mask
	vk := u32(key) & vk_mask

	// handled tracks whether the keypress was actually consumed; the shared
	// tail below only runs for consumed keys (aligns with Rust's
	// input_consumed / make_cursor_visible logic in tui.rs).
	mut handled := false
	// make_visible is suppressed for keys that only scroll the view
	// (Ctrl+Up/Down) or for an Escape that had no selection to clear.
	mut make_visible := true

	match vk {
		vk_back {
			// Any modifier deletes (Rust tui.rs vk::BACK).
			granularity := if mods == kbmod_ctrl { CursorMovement.word } else { CursorMovement.grapheme }
			ed.docs[ed.active].buf.delete(granularity, -1)
			handled = true
		}
		vk_insert {
			if mods == kbmod_shift {
				ed.docs[ed.active].buf.paste(ed.clipboard, false)
			} else if mods == kbmod_ctrl {
				ed.docs[ed.active].buf.copy(mut ed.clipboard)
			} else if mods == kbmod_none {
				ed.docs[ed.active].buf.set_overtype(!ed.docs[ed.active].buf.is_overtype())
			}
			handled = true
		}
		vk_delete {
			if mods == kbmod_shift {
				ed.docs[ed.active].buf.cut(mut ed.clipboard)
			} else if mods == kbmod_ctrl {
				ed.docs[ed.active].buf.delete(CursorMovement.word, 1)
			} else {
				ed.docs[ed.active].buf.delete(CursorMovement.grapheme, 1)
			}
			handled = true
		}
		vk_tab {
			// Any modifier indents/dedents (Rust tui.rs vk::TAB).
			ed.docs[ed.active].buf.indent_change(if mods == kbmod_shift {
				CoordType(-1)
			} else {
				CoordType(1)
			})
			handled = true
		}
		vk_return {
			// Any modifier inserts a newline (Rust tui.rs vk::RETURN).
			ed.docs[ed.active].buf.write_canon([u8(10)])
			handled = true
		}
		vk_escape {
			// Only keep the cursor visible if a selection was actually
			// cleared (Rust tui.rs vk::ESCAPE).
			make_visible = ed.docs[ed.active].buf.clear_selection()
			handled = true
		}
		vk_up, vk_down {
			make_visible = ed.handle_up_down(vk, mods)
			handled = true
		}
		vk_left, vk_right {
			ed.handle_left_right(vk, mods)
			handled = true
		}
		vk_home, vk_end {
			ed.handle_home_end(vk, mods)
			handled = true
		}
		vk_prior, vk_next {
			if mods == kbmod_ctrl {
				// Ctrl+PageUp/Down: switch documents. NOTE: in the Rust
				// original Ctrl+PgUp/PgDn are still plain paging keys;
				// using them for document switching here is a deliberate
				// design difference of this minimal version.
				if vk == vk_next {
					ed.next_document()
				} else if ed.docs.len > 1 {
					ed.active = (ed.active + ed.docs.len - 1) % ed.docs.len
					ed.reset_view_state()
				}
			} else {
				ed.handle_page(vk, mods)
			}
			handled = true
		}
		vk_a {
			if mods == kbmod_ctrl {
				ed.docs[ed.active].buf.select_all()
				handled = true
			}
		}
		vk_b {
			// macOS terminals emit ESC b for Alt+Left (Emacs style).
			$if macos {
				if mods == kbmod_alt {
					ed.docs[ed.active].buf.cursor_move_delta(CursorMovement.word, -1)
					handled = true
				}
			}
		}
		vk_c {
			if mods == kbmod_ctrl {
				ed.docs[ed.active].buf.copy(mut ed.clipboard)
				handled = true
			}
		}
		vk_f {
			if mods == kbmod_ctrl {
				ed.start_prompt(.search)
				handled = true
			} else {
				// macOS terminals emit ESC f for Alt+Right (Emacs style).
				$if macos {
					if mods == kbmod_alt {
						ed.docs[ed.active].buf.cursor_move_delta(CursorMovement.word, 1)
						handled = true
					}
				}
			}
		}
		vk_g {
			if mods == kbmod_ctrl {
				ed.start_prompt(.goto_line)
				handled = true
			}
		}
		vk_h {
			if mods == kbmod_ctrl {
				ed.docs[ed.active].buf.delete(CursorMovement.word, -1)
				handled = true
			}
		}
		vk_l {
			if mods == kbmod_ctrl {
				ed.docs[ed.active].buf.select_line()
				handled = true
			}
		}
		vk_n {
			if mods == kbmod_ctrl {
				ed.add_document('') or {}
				handled = true
			}
		}
		vk_o {
			if mods == kbmod_ctrl {
				ed.open_picker(false)
				handled = true
			}
		}
		vk_p {
			if mods == kbmod_ctrl {
				// NOTE: in the Rust original Ctrl+P opens the go-to-file
				// picker; using it for document switching here is a
				// deliberate design difference of this minimal version.
				ed.next_document()
				handled = true
			}
		}
		vk_q {
			if mods == kbmod_ctrl {
				ed.request_exit()
				handled = true
			}
		}
		vk_r {
			if mods == kbmod_ctrl {
				// Plain Ctrl+R is one-at-a-time replace; Edit > Replace All
				// sets ed.replace_all instead.
				ed.replace_all = false
				ed.start_prompt(.replace)
				handled = true
			}
		}
		vk_s {
			if mods == kbmod_ctrl {
				ed.save_active()
				handled = true
			} else if mods == kbmod_ctrl_shift {
				ed.open_picker(true)
				handled = true
			}
		}
		vk_v {
			if mods == kbmod_ctrl {
				ed.docs[ed.active].buf.paste(ed.clipboard, false)
				handled = true
			}
		}
		vk_w {
			if mods == kbmod_ctrl {
				ed.close_active()
				handled = true
			}
		}
		vk_x {
			if mods == kbmod_ctrl {
				ed.docs[ed.active].buf.cut(mut ed.clipboard)
				handled = true
			}
		}
		vk_y {
			if mods == kbmod_ctrl {
				ed.docs[ed.active].buf.redo()
				handled = true
			}
		}
		vk_z {
			if mods == kbmod_ctrl {
				ed.docs[ed.active].buf.undo()
				handled = true
			} else if mods == kbmod_ctrl_shift {
				ed.docs[ed.active].buf.redo()
				handled = true
			} else if mods == kbmod_alt {
				ed.docs[ed.active].buf.set_word_wrap(!ed.docs[ed.active].buf.is_word_wrap_enabled())
				handled = true
			}
		}
		vk_f3 {
			if mods == kbmod_none {
				ed.find_next()
				handled = true
			}
		}
		vk_f10 {
			if mods == kbmod_none {
				// F10 toggles menu bar focus (no dropdown yet).
				ed.menu_focus = !ed.menu_focus
				ed.menu_open = false
				handled = true
			}
		}
		else {}
	}

	// Closing the last document (or quitting) above must not be followed by
	// any access to ed.docs[ed.active].
	if ed.quit || ed.docs.len == 0 {
		return
	}

	if handled {
		// Any key other than vertical navigation resets the preferred column.
		if vk != vk_up && vk != vk_down && vk != vk_prior && vk != vk_next {
			ed.preferred_column = ed.docs[ed.active].buf.cursor_visual_pos().x
		}
		// The dirty-close/quit disarm lives in handle_event() now.
		if make_visible {
			ed.docs[ed.active].buf.make_cursor_visible()
		}
	}
}

// handle_up_down returns whether the caller should make the cursor visible
// afterwards: Ctrl+Up/Down only scrolls the view and must not be undone by
// make_cursor_visible() (Rust tui.rs vk::UP / vk::DOWN).
fn (mut ed Editor) handle_up_down(vk u32, mods u32) bool {
	delta := if vk == vk_up { CoordType(-1) } else { CoordType(1) }

	if mods == kbmod_alt {
		ed.docs[ed.active].buf.move_selected_lines(if vk == vk_up {
			MoveLineDirection.up
		} else {
			MoveLineDirection.down
		})
		return true
	}
	if mods == kbmod_ctrl {
		ed.scroll.y += delta
		ed.clamp_scroll()
		return false
	}
	if mods != kbmod_none && mods != kbmod_shift {
		return true
	}

	mut b := &ed.docs[ed.active].buf
	mut x := ed.preferred_column
	mut y := b.cursor_visual_pos().y + delta

	// If there's a selection, jump above/below it first.
	sel_ok, sel_beg, sel_end := b.selection_range()
	if sel_ok && mods == kbmod_none {
		if vk == vk_up {
			x = sel_beg.visual_pos.x
			y = sel_beg.visual_pos.y - 1
		} else {
			x = sel_end.visual_pos.x
			y = sel_end.visual_pos.y + 1
		}
		ed.preferred_column = x
	}

	// Moving past the first/last line goes to the start/end of the buffer.
	if y < 0 {
		x = 0
		ed.preferred_column = 0
	} else if y >= b.visual_line_count() {
		x = coord_type_max
	}

	if mods == kbmod_shift {
		b.selection_update_visual(Point{ x: x, y: y })
	} else {
		b.cursor_move_to_visual(Point{ x: x, y: y })
	}

	if x == coord_type_max {
		ed.preferred_column = b.cursor_visual_pos().x
	}
	return true
}

fn (mut ed Editor) handle_left_right(vk u32, mods u32) {
	delta := if vk == vk_left { CoordType(-1) } else { CoordType(1) }
	granularity := if mods == kbmod_ctrl || mods == kbmod_ctrl_shift {
		CursorMovement.word
	} else {
		CursorMovement.grapheme
	}

	mut b := &ed.docs[ed.active].buf
	if mods == kbmod_shift || mods == kbmod_ctrl_shift {
		b.selection_update_delta(granularity, delta)
	} else if mods == kbmod_none || mods == kbmod_ctrl {
		// With an active selection, collapse it to its near/far end.
		sel_ok, beg, end := b.selection_range()
		if sel_ok {
			b.set_cursor(if vk == vk_left { beg } else { end })
		} else {
			b.cursor_move_delta(granularity, delta)
		}
	}
}

// NOTE: the Rust original (tui.rs vk::HOME / vk::END) has a two-stage
// behavior — with word wrap, the first press moves within the visual line and
// the second press to the logical line start/end; likewise Home first stops
// at the indentation. That is deliberately trimmed here (scope cut).
fn (mut ed Editor) handle_home_end(vk u32, mods u32) {
	mut b := &ed.docs[ed.active].buf
	mut destination := if vk == vk_home {
		Point{ x: 0, y: b.cursor_visual_pos().y }
	} else {
		Point{ x: coord_type_max, y: b.cursor_visual_pos().y }
	}
	if mods == kbmod_ctrl || mods == kbmod_ctrl_shift {
		destination = if vk == vk_home { Point{} } else { point_max() }
	}

	if mods == kbmod_shift || mods == kbmod_ctrl_shift {
		b.selection_update_visual(destination)
	} else {
		b.cursor_move_to_visual(destination)
	}
}

fn (mut ed Editor) handle_page(vk u32, mods u32) {
	height := CoordType(if ed.size.height > 2 { ed.size.height - 2 } else { 1 })
	delta := if vk == vk_prior { -height } else { height }
	mut b := &ed.docs[ed.active].buf

	// If the cursor is already on the first/last visual line, PageUp/PageDown
	// moves to the very start/end of the buffer (Rust tui.rs vk::PRIOR/NEXT).
	if vk == vk_prior && b.cursor_visual_pos().y == 0 {
		ed.preferred_column = 0
	} else if vk == vk_next && b.cursor_visual_pos().y >= b.visual_line_count() - 1 {
		ed.preferred_column = coord_type_max
	}

	y := b.cursor_visual_pos().y + delta

	if mods == kbmod_shift {
		b.selection_update_visual(Point{ x: ed.preferred_column, y: y })
	} else if mods == kbmod_none {
		b.cursor_move_to_visual(Point{ x: ed.preferred_column, y: y })
	}
	if ed.preferred_column == coord_type_max {
		ed.preferred_column = b.cursor_visual_pos().x
	}
}

// ---- Mouse ------------------------------------------------------------------------

// handle_mouse implements click-to-position, wheel scrolling, drag selection
// and menu bar interaction (title clicks toggle dropdowns, item clicks
// activate, clicks elsewhere close an open menu).
fn (mut ed Editor) handle_mouse(mouse InputMouse) {
	// Mouse input only applies to the text area, not to the status-line prompt.
	if ed.mode != .edit {
		return
	}
	if mouse.state == .scroll {
		// The ×3 multiplier is a deliberate acceleration (scope trim; the
		// Rust original accumulates fractional scroll deltas instead).
		ed.scroll.y += mouse.scroll.y * 3
		ed.scroll.x += mouse.scroll.x * 3
		ed.clamp_scroll()
		return
	}
	if mouse.state != .left {
		return
	}

	menus := ed.build_menus()
	// Clicks on the menu bar row toggle the corresponding dropdown.
	if mouse.position.y == 0 && !mouse.drag {
		rects := ed.menu_title_rects(menus)
		mut hit := -1
		for i, r in rects {
			if mouse.position.x >= r.left && mouse.position.x < r.right {
				hit = i
				break
			}
		}
		if hit >= 0 {
			if ed.menu_open && ed.menu_idx == hit {
				ed.menu_open = false
			} else {
				ed.menu_open = true
				ed.menu_idx = hit
				ed.menu_item_idx = 0
			}
		} else {
			ed.menu_open = false
			ed.menu_focus = false
		}
		return
	}
	// With a dropdown open, clicks either activate an item or close the menu.
	if ed.menu_open {
		if !mouse.drag {
			rect := ed.menu_dropdown_rect(menus)
			if mouse.position.x >= rect.left && mouse.position.x < rect.right
				&& mouse.position.y >= rect.top && mouse.position.y < rect.bottom {
				idx := int(mouse.position.y - rect.top)
				ed.activate_menu_item(menus[ed.menu_idx].items[idx].action)
			} else {
				ed.menu_open = false
				ed.menu_focus = false
			}
		}
		return
	}
	if ed.menu_focus && !mouse.drag {
		// A click elsewhere just drops the menu bar focus.
		ed.menu_focus = false
	}

	// Clicks on the status line are not handled.
	if mouse.position.y >= ed.size.height - 1 {
		return
	}

	// Click into the text area: position the cursor. Row 0 is the menu bar,
	// so the text area starts one row lower.
	mut b := &ed.docs[ed.active].buf
	x := coord_max(mouse.position.x - b.margin_width() + ed.scroll.x, 0)
	y := coord_max(mouse.position.y - 1 + ed.scroll.y, 0)
	if mouse.drag {
		// Drag with the button held: anchor a selection at the click point
		// (set by the preceding non-drag click) and extend it to here.
		if !b.has_selection() {
			b.start_selection()
		}
		b.selection_update_visual(Point{ x: x, y: y })
	} else {
		b.clear_selection()
		b.cursor_move_to_visual(Point{ x: x, y: y })
	}
	b.make_cursor_visible()
}

// ---- View ---------------------------------------------------------------------------

// clamp_scroll keeps the scroll offset inside the document, like
// textarea_adjust_scroll_offset() in the Rust original (tui.rs).
fn (mut ed Editor) clamp_scroll() {
	if ed.docs.len == 0 {
		return
	}
	mut b := &ed.docs[ed.active].buf
	mut x := ed.scroll.x
	mut y := ed.scroll.y
	x = coord_min(x, coord_max(ed.scroll_x_max, b.cursor_visual_pos().x) - 10)
	x = coord_max(x, 0)
	y = coord_clamp(y, 0, b.visual_line_count() - 1)
	if b.is_word_wrap_enabled() {
		x = 0
	}
	ed.scroll.x = x
	ed.scroll.y = y
}

// make_cursor_visible scrolls so the cursor is inside the viewport, like
// textarea_make_cursor_visible() in the Rust original (tui.rs).
fn (mut ed Editor) make_cursor_visible() {
	mut b := &ed.docs[ed.active].buf
	cursor := b.cursor_visual_pos()
	text_width := ed.text_width()
	viewport_height := ed.size.height - 2 // minus the menu bar and status line

	mut x := ed.scroll.x
	mut y := ed.scroll.y
	x = coord_min(x, cursor.x - 10)
	x = coord_max(x, cursor.x - text_width + 10)
	y = coord_min(y, cursor.y)
	y = coord_max(y, cursor.y - viewport_height + 1)
	ed.scroll.x = x
	ed.scroll.y = y
	ed.clamp_scroll()
}

fn (mut ed Editor) draw() {
	if ed.size.width <= 0 || ed.size.height <= 0 || ed.docs.len == 0 {
		return
	}

	mut b := &ed.docs[ed.active].buf

	if b.take_cursor_visibility_request() {
		ed.make_cursor_visible()
	}
	ed.clamp_scroll()

	ed.fb.flip(ed.size)

	// The text area covers everything but the menu bar (row 0) and the
	// last (status) line.
	destination := Rect{
		left:   0
		top:    1
		right:  ed.size.width
		bottom: ed.size.height - 1
	}
	if res := b.render(ed.scroll, destination, true, mut ed.fb) {
		ed.scroll_x_max = res.visual_pos_x_max
	}

	// Status line / prompt.
	status_y := ed.size.height - 1
	if ed.mode == .prompt {
		label := match ed.prompt_kind {
			.search { 'search: ' }
			.replace { if ed.replace_all { 'replace all: ' } else { 'replace: ' } }
			.replace_with { 'with: ' }
			.goto_line { 'go to line: ' }
		}
		text := ' ${label}${ed.prompt_text}'
		ed.fb.replace_text(status_y, 0, ed.size.width, text)
		ed.fb.reverse(mut Rect{
			left:   0
			top:    status_y
			right:  ed.size.width
			bottom: ed.size.height
		})
		// text.len is bytes, not terminal columns (wide glyphs count double),
		// so measure the display width via MeasurementConfig.
		mut cfg := new_measurement_config(StringDocument{ text: text })
		cursor_x := cfg.goto_visual(Point{ x: coord_type_max, y: 0 }).visual_pos.x
		ed.fb.set_cursor(Point{ x: cursor_x, y: status_y }, false)
	} else {
		name := if ed.cur().path == '' { '[untitled]' } else { ed.cur().path }
		dirty := if b.is_dirty() { ' [modified]' } else { '' }
		pos := b.cursor_logical_pos()
		mut status := ' [${ed.active + 1}/${ed.docs.len}] ${name}${dirty}  Ln ${pos.y + 1}, Col ${pos.x + 1}'
		if ed.status != '' {
			status += '  |  ${ed.status}'
		}
		status += '  |  ^S save ^O open ^F find ^Q quit'
		ed.fb.replace_text(status_y, 0, ed.size.width, status)
		ed.fb.reverse(mut Rect{
			left:   0
			top:    status_y
			right:  ed.size.width
			bottom: ed.size.height
		})
	}

	// The menu bar sits on row 0; dropdown, file picker and About dialog
	// layer on top.
	ed.draw_menubar()
	if ed.menu_open {
		ed.draw_menu_dropdown(ed.build_menus())
	}
	if ed.picker {
		ed.draw_filepicker()
	}
	if ed.about_open {
		ed.draw_about()
	}

	write_stdout(ed.fb.render())
	ed.status = ''
}
