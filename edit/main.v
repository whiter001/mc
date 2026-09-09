module main

// Minimal runnable editor loop, modeled after crates/edit/src/bin/edit/main.rs
// (microsoft/edit). Scope: multiple documents, a status-line prompt for
// open/save-as/search/goto, mouse click/scroll, and a menu bar with an
// About dialog (see menubar.v).
//
// Exit paths MUST call restore_terminal(): V has no destructors, so the
// RestoreModes guard of the Rust original is replicated manually here.

import os
import time
import encoding.base64

// Terminal setup/teardown sequences, same as the Rust original (main.rs).
const term_init_seq = '\x1b[?1049h\x1b[?1002;1006;2004h\x1b[?1036h'
const term_exit_seq = '\x1b[0 q\x1b[?25h\x1b]0;\x07\x1b[?1002;1006;2004l\x1b[?1049l'

const kbmod_mask = u32(0xff000000)
const vk_mask = u32(0x00ffffff)

// scrollbar_width is the number of columns reserved on the right edge of the
// text area for the scrollbar. Rust reserves the same space inside its
// scrollarea widget, so the text never runs underneath the scrollbar.
const scrollbar_width = CoordType(1)

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

// StatusButtonKind identifies a clickable button on the status line.
enum StatusButtonKind {
	// Toggles CRLF/LF (Rust draw_statusbar "newline").
	newline
	// Opens the indentation picker (Rust "indentation").
	indentation
	// Opens the language picker (Rust "language").
	language
	// Opens the Go to File modal (Rust "filename" button).
	filename
}

// SearchButtonKind identifies a clickable search option toggle.
enum SearchButtonKind {
	match_case
	whole_word
	use_regex
}

// StatusButton is a clickable region on the status line. The columns are
// rebuilt every frame while drawing, so hit-testing uses the same numbers
// the user just saw.
struct StatusButton {
	kind  StatusButtonKind
	left  CoordType
	right CoordType
}

// SearchButton is a clickable region on the search prompt options row.
struct SearchButton {
	kind  SearchButtonKind
	left  CoordType
	right CoordType
}

// Document is a single open file (or untitled buffer).
struct Document {
mut:
	buf         TextBuffer
	path        string
	file_id     FileId
	has_file_id bool
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
	settings         UserSettings
	// Mode & prompt state.
	mode             EditMode
	prompt_kind      PromptKind
	prompt_text      string
	// Cursor within prompt_text, as a byte offset (0..len). Clamped at the
	// bounds by every handler. Out-of-range values are tolerated and treated
	// as "at end" by the insert/delete paths. Used for ←/→/Home/End/Delete
	// line editing inside the prompt (Rust editline is a full TextBuffer).
	prompt_cursor    int = -1
	// Selection anchor (byte offset) within prompt_text.
	prompt_sel       int = -1
	// Last search, for F3 (= find next).
	last_search      string
	// Last replacement text; persists across Ctrl+R invocations like Rust's
	// state.search_replacement, so a repeat Enter repeats the same replace
	// instead of deleting the match with an empty replacement.
	last_replacement string
	// Search options mirror the Rust search panel toggles.
	search_options   SearchOptions
	// search_failed mirrors Rust's state.search_success (inverted): true when
	// the current prompt needle has no match, used to paint the prompt line red.
	search_failed    bool
	// Hit counter for the last search ("3/17"), refreshed by update_search_stats
	// after every find navigation. search_hit_generation invalidates the pair
	// when the buffer is edited. search_hit_index is 0 when the selection is
	// not on a hit (e.g. a zero-width regex match, which stores no selection).
	search_hit_index      int
	search_hit_total      int
	search_hit_generation u32
	// The needle collected by the first Ctrl+R prompt, used by the second.
	replace_needle   string
	// Dirty-quit modal: pops up when Ctrl+W/Ctrl+Q is pressed on a dirty
	// document. dirty_action encodes the focused button:
	//   0=Save, 1=Discard, 2=Cancel (default). dirty_for_quit is true for
	//   Ctrl+Q and false for Ctrl+W.
	dirty_modal     bool
	dirty_action    int
	dirty_for_quit  bool
	// Menu bar state (menubar.v): menu_focus = bar highlighted via F10,
	// menu_open = a dropdown is open, menu_idx/menu_item_idx = selection.
	menu_focus       bool
	menu_open        bool
	menu_idx         int
	menu_item_idx    int
	// Go to File modal (goto_file.v).
	goto_file            bool
	goto_file_sel        int       // index into goto_file_filtered (not ed.docs)
	goto_file_scroll     int
	goto_file_filter     string    // 过滤字符串，空 = 不过滤
	goto_file_filtered   []int     // 匹配过滤的文档 index 列表（按 ed.docs 顺序）
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
	picker_overwrite        string
	picker_autocomplete     []string
	picker_autocomplete_sel int
	// Status-line buttons, rebuilt every frame (see draw_statusbar).
	status_buttons   []StatusButton
	// Search prompt buttons, rebuilt every frame while the search panel is visible.
	search_buttons   []SearchButton
	// Mouse multi-click tracking (Rust tui.rs mouse_click_counter): counts
	// consecutive presses at the same spot within 500ms to drive word/line/all
	// selection on double/triple/quadruple click. drag_anchor_* is the screen
	// position of the press that began the current drag (used by auto-scroll).
	click_count      CoordType
	last_click_x     CoordType
	last_click_y     CoordType
	last_click_ms    i64
	drag_anchor_x    CoordType
	drag_anchor_y    CoordType
	// Whether the indentation picker popup above the status line is open
	// (Rust state.wants_indentation_picker).
	indent_picker    bool
	// Left screen column of the indentation popup, recomputed each frame.
	indent_popup_left CoordType
	// Language picker modal (Rust draw_dialog_language_change). Selection
	// encoding: -2 = Auto Detect, -1 = Plain Text, >= 0 = lsh_languages index.
	// Sticky override: while -2 the picker (and `set_language`) reflect the
	// file-extension auto-detection; any other value is an explicit override.
	language_picker        bool
	language_picker_sel    int
	language_picker_scroll int
	language_picker_explicit int = -2 // -2 sentinel: auto-detect
	// Large clipboard warning modal (Rust state.wants_large_clipboard_warning).
	// Triggered by process_input() when the OSC 52 payload crosses the
	// threshold; while set, all input is routed to the warning handler.
	clipboard_large_pending bool
	// Error log: ring buffer of recent error messages.
	error_log       []string
	error_log_count int
	error_log_index int
	error_log_open  bool
	// OSC 0 title cache: only emit when filename or dirty flag actually changes.
	title_filename  string
	title_dirty     bool
}

fn main() {
	// Parse argv before doing anything terminal-related so --help / --version
	// can print and exit without ever touching raw mode (Rust main.rs).
	cwd := os.getwd()
	opts := parse_cli_args(os.args[1..], cwd) or {
		eprintln('edit: ${err}')
		exit(2)
	}
	match opts.action {
		.help {
			print(cli_help_text())
			return
		}
		.version {
			print(cli_version_text())
			return
		}
		.run {}
	}

	sys_init()

	mut ed := Editor{
		parser:       new_input_parser()
		fb:           framebuffer_new()
		needs_redraw: true
	}
	mut settings_errors := []string{}
	ed.settings = load_settings(mut settings_errors)
	for msg in settings_errors {
		ed.error_log_add(msg)
	}

	mut initial_picker_dir := ''
	for entry in opts.paths {
		// Directories become picker initial dirs; non-existent paths become
		// empty documents that point at the requested target (matches Rust
		// main.rs path handling).
		if os.is_dir(entry.path) {
			initial_picker_dir = entry.path
			continue
		}
		ed.add_document(entry.path) or {
			eprintln('edit: ${entry.path}: ${err}')
			exit(1)
		}
		if entry.has_goto {
			mut doc := &ed.docs[ed.active]
			target_y := goto_line_index(entry.goto.line, doc.buf.logical_line_count() - 1)
			target_x := coord_max(CoordType(entry.goto.column - 1), CoordType(0))
			doc.buf.cursor_move_to_logical(Point{ x: target_x, y: target_y })
			doc.buf.make_cursor_visible()
		}
	}

	// A literal '-' clears file arguments, but stdin is only consumed when it
	// is actually redirected. This avoids blocking on a terminal waiting for
	// EOF when `edit -` is launched interactively.
	stdin_redirected := stdin_is_redirected()
	if stdin_redirected && opts.stdin_input {
		stdin_text := read_all_stdin() or {
			eprintln('edit: failed to read stdin: ${err}')
			exit(1)
		}
		if ed.docs.len == 0 {
			ed.add_document('') or {
				eprintln('edit: cannot create stdin document: ${err}')
				exit(1)
			}
		}
		mut doc := &ed.docs[ed.active]
		doc.buf.copy_from_str(StringDocument{ text: stdin_text })
		doc.buf.mark_as_dirty()
	} else if stdin_redirected {
		stdin_text := read_all_stdin() or {
			eprintln('edit: failed to read stdin: ${err}')
			exit(1)
		}
		ed.add_document('') or {
			eprintln('edit: cannot create stdin document: ${err}')
			exit(1)
		}
		mut doc := &ed.docs[ed.active]
		doc.buf.copy_from_str(StringDocument{ text: stdin_text })
		doc.buf.mark_as_dirty()
	} else if ed.docs.len == 0 {
		ed.add_document('') or {
			eprintln('edit: cannot create untitled document: ${err}')
			exit(1)
		}
	}
	if initial_picker_dir != '' {
		ed.open_picker(false)
		ed.picker_dir = initial_picker_dir
		ed.picker_refresh()
	}

	if stdin_redirected {
		reopen_stdin_if_redirected() or {
			eprintln('edit: cannot reopen /dev/tty: ${err}')
			exit(1)
		}
	}

	switch_modes() or {
		eprintln('edit: cannot switch terminal to raw mode: ${err}')
		exit(1)
	}
	write_stdout(term_init_seq)
	// Make the first read_stdin() report the window size as a resize event.
	inject_window_size_into_stdin()

	for !ed.quit {
		if ed.needs_redraw {
			ed.update_terminal_title()
			ed.draw()
			ed.needs_redraw = false
		}
		ed.process_input()
	}

	write_stdout(term_exit_seq)
	restore_terminal()
}

// draw_prompt_line renders the active status-line prompt.
fn (mut ed Editor) draw_prompt_line(status_y CoordType) {
	label := match ed.prompt_kind {
		.search { 'search: ' }
		.replace { if ed.replace_all { 'replace all: ' } else { 'replace: ' } }
		.replace_with { 'with: ' }
		.goto_line { 'go to line: ' }
	}
	// Clamp the cursor to a usable offset so a stray value from earlier code
	// paths doesn't make us slice past the end of prompt_text below.
	off := ed.prompt_effective_cursor()
	text := ' ${label}${ed.prompt_text}'
	ed.fb.replace_text(status_y, 0, ed.size.width, text)

	// On a failed needle search, paint the whole prompt line red with bright
	// white text (Rust draw_editor.rs:84-87, state.search_success).
	failed := ed.search_failed && (ed.prompt_kind == .search || ed.prompt_kind == .replace)
	if failed {
		mut rect := Rect{
			left:   0
			top:    status_y
			right:  ed.size.width
			bottom: status_y + 1
		}
		ed.fb.blend_bg(mut rect, ed.fb.indexed(IndexedColor.red))
		ed.fb.blend_fg(mut rect, ed.fb.indexed(IndexedColor.bright_white))
	} else {
		mut rect := Rect{
			left:   0
			top:    status_y
			right:  ed.size.width
			bottom: status_y + 1
		}
		ed.fb.reverse(mut rect)
	}
	// Highlight the active in-prompt selection, if any. The prompt text
	// starts at column (1 + label.len) and column widths use byte offsets
	// (same approximation as the terminal cursor above; wide-glyph
	// alignment is not pixel-precise, matching the existing cursor math).
	beg, end := ed.prompt_selection()
	if beg >= 0 {
		x1 := CoordType(1 + label.len + beg)
		x2 := CoordType(1 + label.len + end)
		mut sel_rect := Rect{
			left:   x1
			top:    status_y
			right:  x2
			bottom: status_y + 1
		}
		ed.fb.reverse(mut sel_rect)
	}
	// Position the terminal cursor at the prompt-text cursor (not always at
	// end-of-text now that the prompt supports ←/→/Home/End). text.len is
	// bytes, not terminal columns (wide glyphs count double), so measure the
	// display width via MeasurementConfig.
	cursor_text := ' ${label}${ed.prompt_text[..off]}'
	mut cfg := new_measurement_config(StringDocument{ text: cursor_text })
	cursor_x := cfg.goto_visual(Point{ x: coord_type_max, y: 0 }).visual_pos.x
	ed.fb.set_cursor(Point{ x: cursor_x, y: status_y }, false)
}

// draw_search_prompt_options renders the search option toggles above the prompt.
fn (mut ed Editor) draw_search_prompt_options(options_y CoordType) {
	ed.search_buttons = []SearchButton{}
	if options_y < 0 {
		return
	}

	mut text := ''
	mut x := CoordType(0)
	mut segment := ' ${if ed.search_options.match_case { '[x]' } else { '[ ]' }} Match case '
	ed.search_buttons << SearchButton{
		kind:  .match_case
		left:  x
		right: x + CoordType(segment.len)
	}
	text += segment + ' '
	x += CoordType(segment.len + 1)

	segment = ' ${if ed.search_options.whole_word { '[x]' } else { '[ ]' }} Whole word '
	ed.search_buttons << SearchButton{
		kind:  .whole_word
		left:  x
		right: x + CoordType(segment.len)
	}
	text += segment + ' '
	x += CoordType(segment.len + 1)

	segment = ' ${if ed.search_options.use_regex { '[x]' } else { '[ ]' }} Regex '
	ed.search_buttons << SearchButton{
		kind:  .use_regex
		left:  x
		right: x + CoordType(segment.len)
	}
	text += segment + ' '

	ed.fb.replace_text(options_y, 0, ed.size.width, text)
	// Hit counter, right-aligned ("3/17"; bare total when the selection is
	// not on a hit, e.g. a zero-width regex match).
	if ed.search_hit_total > 0 {
		mut b := &ed.docs[ed.active].buf
		if ed.search_hit_generation == b.buffer.generation() {
			ctr := if ed.search_hit_index > 0 {
				'${ed.search_hit_index}/${ed.search_hit_total}'
			} else {
				'${ed.search_hit_total}'
			}
			ctr_x := ed.size.width - CoordType(ctr.len) - 1
			if ctr_x > CoordType(text.len) {
				ed.fb.replace_text(options_y, ctr_x, ed.size.width, ctr)
			}
		}
	}
	mut opt_rect := Rect{
		left:   0
		top:    options_y
		right:  ed.size.width
		bottom: options_y + 1
	}
	ed.fb.reverse(mut opt_rect)
	for btn in ed.search_buttons {
		mut btn_rect := Rect{
			left:   btn.left
			top:    options_y
			right:  btn.right
			bottom: options_y + 1
		}
		ed.fb.reverse(mut btn_rect)
	}
}

// add_document opens a file (or an untitled buffer for '') and makes it active.
fn (mut ed Editor) add_document(path string) ! {
	mut normalized_path := path
	if path != '' {
		normalized_path = os.abs_path(path)
	}
	mut doc := Document{
		buf:  new_text_buffer(false)
		path: normalized_path
	}
	doc.buf.set_margin_enabled(true)
	doc.buf.set_insert_final_newline(true)
	doc.buf.set_line_highlight_enabled(true)
	doc.buf.set_width(ed.width_for_margin(doc.buf.margin_width()))
	if normalized_path != '' {
		mut existing_id := FileId{}
		mut has_existing_id := false
		if os.exists(normalized_path) {
			existing_id = file_id(normalized_path) or { return err }
			has_existing_id = true
		}
		for i in 0 .. ed.docs.len {
			d := &ed.docs[i]
			if (has_existing_id && d.has_file_id && d.file_id == existing_id)
				|| (!has_existing_id && !d.has_file_id && d.path == normalized_path) {
				ed.active = i
				ed.reset_view_state()
				return
			}
		}
		if has_existing_id {
			doc.buf.read_file(normalized_path) or { return err }
			doc.buf.set_language(ed.language_for_path(normalized_path))
			doc.file_id = existing_id
			doc.has_file_id = true
		} else {
			// Rust creates an empty document for a missing path so it can be
			// edited and saved without an intermediate Save As operation.
			doc.buf.set_language(ed.language_for_path(normalized_path))
		}
		// Git commit messages conventionally wrap at 72 columns
		// (Rust documents.rs applies the same special case).
		if os.base(normalized_path) == 'COMMIT_EDITMSG' {
			doc.buf.set_ruler(72)
		}
	}
	if ed.docs.len > 0 {
		last := ed.docs.len - 1
		if ed.docs[last].path == '' && !ed.docs[last].buf.is_dirty() {
			ed.docs.delete(last)
		}
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
	ed.mode = .edit
	ed.prompt_text = ''
}

// cur returns the active document. Use `ed.docs[ed.active]` for mutation.
fn (ed &Editor) cur() &Document {
	return &ed.docs[ed.active]
}

// width_for_margin returns the width available for text, given a margin width.
// Reserves scrollbar_width columns for the scrollbar.
fn (ed &Editor) width_for_margin(margin_width CoordType) CoordType {
	return coord_max(ed.size.width - margin_width - scrollbar_width, 1)
}

// text_width returns the width available for text (excluding the margin).
fn (ed &Editor) text_width() CoordType {
	if ed.docs.len == 0 {
		return coord_max(ed.size.width - scrollbar_width, 1)
	}
	return ed.width_for_margin(ed.cur().buf.margin_width())
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
	// Sync the internal clipboard to the host terminal via OSC 52. Large
	// payloads (>= 128 KiB) get gated through a confirmation modal unless
	// the user has previously opted in with "Always".
	if ed.clipboard.wants_host_sync() {
		if ed.clipboard.clipboard_wants_warning() {
			// Pause the sync; the warning modal will resolve it.
			ed.clipboard.large_pending = true
			ed.needs_redraw = true
		} else {
			data := ed.clipboard.read()
			if data.len > 0 {
				write_stdout('\x1b]52;c;' + base64.encode(data) + '\x1b\\')
			}
			ed.clipboard.mark_as_synchronized()
		}
	}
}

fn (mut ed Editor) handle_event(ev Input) {
	// Resize always applies, even while a modal (About / file picker) is open.
	if ev.kind == .resize {
		ed.size = ev.size
		for i in 0 .. ed.docs.len {
			ed.docs[i].buf.set_width(ed.width_for_margin(ed.docs[i].buf.margin_width()))
		}
		return
	}

	// The large clipboard warning is internal — it pops up while the user
	// is doing something else, so it intercepts input ahead of every
	// user-opened modal (About, file picker, etc.).
	if ed.clipboard_large_pending {
		match ev.kind {
			.keyboard { ed.handle_clipboard_warning_key(ev.key) }
			.text { ed.handle_clipboard_warning_text(ev.text) }
			.mouse { ed.handle_clipboard_warning_mouse(ev.mouse) }
			else {}
		}
		return
	}

	// Error log modal: any key dismisses it.
	if ed.error_log_count > 0 && ed.error_log_open {
		if ev.kind == .keyboard || ev.kind == .text {
			ed.error_log_close()
			return
		}
	}

	// Dirty-close / dirty-quit modal.
	if ed.dirty_modal {
		match ev.kind {
			.keyboard {
				vk := u32(ev.key) & vk_mask
				match vk {
					vk_left  { ed.dirty_action = (ed.dirty_action + 3 - 1) % 3 }
					vk_right { ed.dirty_action = (ed.dirty_action + 1) % 3 }
					vk_return { ed.resolve_dirty_modal() }
					vk_escape { ed.dirty_modal = false }
					else {}
				}
			}
			.text {
				if ev.text == 's' || ev.text == 'S' {
					ed.dirty_action = 0
					ed.resolve_dirty_modal()
				} else if ev.text == 'n' || ev.text == 'N' {
					ed.dirty_action = 1
					ed.resolve_dirty_modal()
				} else if ev.text == 'c' || ev.text == 'C' || ev.text == '\x1b' {
					ed.dirty_modal = false
				}
			}
			else {}
		}
		return
	}

	// The About dialog is dismissed by any user event, except the mouse
	// release that pairs with the click that opened it. In SGR mouse mode
	// that release arrives as state=none with drag=false; swallowing it
	// keeps the dialog visible until the user actually does something.
	if ed.about_open {
		if ev.kind == .mouse && ev.mouse.state == .none && !ev.mouse.drag {
			return
		}
		ed.about_open = false
		return
	}

	// The language picker is modal: it swallows all input while open.
	if ed.language_picker {
		match ev.kind {
			.keyboard { ed.handle_language_picker_key(ev.key) }
			.mouse { ed.handle_language_picker_mouse(ev.mouse) }
			else {}
		}
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
				// first newline on. Tab triggers autocomplete-apply.
				mut s := if ev.kind == .text { ev.text } else { ev.data.bytestr() }
				idx := s.index_any('\r\n')
				if idx >= 0 {
					s = s[..idx]
				}
				if s == '\t' {
					// Tab in the picker applies the current autocomplete suggestion.
					ed.picker_autocomplete_apply()
				} else if ed.picker_overwrite != '' {
					// Overwrite warning: y confirms, n cancels (Rust:
					// consume_shortcut(vk::Y/N)); anything else is ignored.
					if s == 'y' || s == 'Y' {
						path := ed.picker_overwrite
						ed.picker_overwrite = ''
						ed.picker_do_save(path)
					} else if s == 'n' || s == 'N' {
						ed.picker_overwrite = ''
					}
				} else if s.len > 0 {
					ed.picker_name += s
					ed.picker_autocomplete_update()
				}
			}
			.mouse {
				ed.handle_picker_mouse(ev.mouse)
			}
			else {}
		}
		return
	}
	if ed.goto_file {
		match ev.kind {
			.keyboard {
				ed.handle_goto_file_key(ev.key)
			}
			.mouse {
				ed.handle_goto_file_mouse(ev.mouse)
			}
			.text, .paste {
				mut s := if ev.kind == .text { ev.text } else { ev.data.bytestr() }
				idx := s.index_any('\r\n')
				if idx >= 0 {
					s = s[..idx]
				}
				ed.handle_goto_file_text(s)
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
			if s.len > 0 {
				ed.prompt_insert(s)
			}
			// Incremental search: re-run the search as the needle changes
			// (Rust editline change -> SearchAction::Search, draw_editor.rs:81).
			if ed.prompt_kind == .search || ed.prompt_kind == .replace {
				ed.run_prompt_search()
			}
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
		// Rust has a single needle input shared by the search and replace
		// panels (state.search_needle), so both reopen with the last needle
		// and Enter keeps finding the next hit.
		.search, .replace { ed.last_search }
		.replace_with { ed.last_replacement }
		else { '' }
	}
	// If the active document has a user selection, prefill the needle with it
	// (Rust draw_editor.rs:59-62). This applies to the search and replace
	// prompts, which both collect a needle.
	if kind == .search || kind == .replace {
		mut b := &ed.docs[ed.active].buf
		if b.has_selection() {
			if sel := b.extract_user_selection(false) {
				ed.prompt_text = sel.bytestr()
			}
		}
	}
	// New cursor sits at end of the prefilled text, ready for edits.
	ed.prompt_cursor = ed.prompt_text.len
	ed.prompt_sel = -1
	// A freshly opened prompt starts in the "not failed" state.
	ed.search_failed = false
}

// start_replace opens the replace prompt pair. With a selection, Rust fills
// the needle from it and puts the focus on the replacement field right away
// (draw_editor.rs:59-62), so here the second prompt opens directly.
fn (mut ed Editor) start_replace() {
	mut b := &ed.docs[ed.active].buf
	if b.has_selection() {
		if sel := b.extract_user_selection(false) {
			ed.replace_needle = sel.bytestr()
			ed.last_search = ed.replace_needle
			ed.start_prompt(.replace_with)
			return
		}
	}
	ed.start_prompt(.replace)
}

fn (mut ed Editor) cancel_prompt() {
	ed.mode = .edit
	ed.prompt_text = ''
	ed.prompt_cursor = -1
	ed.prompt_sel = -1
	ed.search_buttons = []
	ed.search_failed = false
}

// restart_prompt_with_error re-opens the given prompt keeping the typed
// text and shows a status-bar error so the user can correct the input.
// Used by Ctrl+G when the line/column string is malformed.
fn (mut ed Editor) restart_prompt_with_error(kind PromptKind, text string, msg string) {
	ed.start_prompt(kind)
	ed.prompt_text = text
	ed.prompt_cursor = text.len
	ed.prompt_sel = -1
	ed.status = msg
}

// prompt_effective_cursor returns the prompt cursor clamped to a usable byte
// offset inside prompt_text. Out-of-range values are treated as the end, which
// is the natural "append" position when no cursor has been set yet.
fn (ed &Editor) prompt_effective_cursor() int {
	c := ed.prompt_cursor
	if c < 0 || c > ed.prompt_text.len {
		return ed.prompt_text.len
	}
	return c
}

// prompt_prev_codepoint returns the byte offset one UTF-8 codepoint before
// `off`, or 0 if `off` is at or past the start of `text`. Continuation bytes
// (0x80-0xBF) are skipped; an invalid lead is treated as one byte.
fn prompt_prev_codepoint(text string, off int) int {
	mut i := off
	if i > text.len {
		i = text.len
	}
	for i > 0 && (text[i - 1] & 0xC0) == 0x80 {
		i--
	}
	if i > 0 {
		i--
	}
	return i
}

// prompt_next_codepoint returns the byte offset one UTF-8 codepoint after
// `off`, or `text.len` if `off` is at or past the end. A lead byte is followed
// by all its continuation bytes (up to 3); an invalid lead is treated as one
// byte.
fn prompt_next_codepoint(text string, off int) int {
	if off < 0 {
		return 0
	}
	if off >= text.len {
		return text.len
	}
	mut i := off
	c := text[i]
	if c < 0x80 {
		return i + 1
	}
	if c >= 0xF0 {
		return i + 4
	}
	if c >= 0xE0 {
		return i + 3
	}
	return i + 2
}

fn (ed &Editor) prompt_search_needle() string {
	return match ed.prompt_kind {
		.search, .replace { ed.prompt_text }
		.replace_with { ed.replace_needle }
		else { '' }
	}
}

// prompt_insert inserts `s` at the current prompt cursor and advances the cursor
// past it. Mirrors Rust's TextBuffer::insert at the editline cursor. When a
// selection is active the selection is replaced by `s`.
fn (mut ed Editor) prompt_insert(s string) {
	beg, end := ed.prompt_selection()
	if beg >= 0 {
		ed.prompt_text = ed.prompt_text[..beg] + s + ed.prompt_text[end..]
		ed.prompt_cursor = beg + s.len
		ed.prompt_sel = -1
		return
	}
	off := ed.prompt_effective_cursor()
	ed.prompt_text = ed.prompt_text[..off] + s + ed.prompt_text[off..]
	ed.prompt_cursor = off + s.len
}

// prompt_selection returns the active byte-offset range [beg, end) of the
// in-prompt selection, or (-1, -1) when there is none. A zero-width
// selection (anchor == cursor) is not highlighted.
fn (ed &Editor) prompt_selection() (int, int) {
	if ed.prompt_sel < 0 || ed.prompt_sel == ed.prompt_cursor {
		return -1, -1
	}
	if ed.prompt_sel < ed.prompt_cursor {
		return ed.prompt_sel, ed.prompt_cursor
	}
	return ed.prompt_cursor, ed.prompt_sel
}

// prompt_backspace deletes one UTF-8 codepoint before the prompt cursor, if
// any. When a selection is active it deletes the whole selection instead.
fn (mut ed Editor) prompt_backspace() {
	beg, end := ed.prompt_selection()
	if beg >= 0 {
		ed.prompt_text = ed.prompt_text[..beg] + ed.prompt_text[end..]
		ed.prompt_cursor = beg
		ed.prompt_sel = -1
		return
	}
	off := ed.prompt_effective_cursor()
	if off <= 0 {
		return
	}
	prev := prompt_prev_codepoint(ed.prompt_text, off)
	ed.prompt_text = ed.prompt_text[..prev] + ed.prompt_text[off..]
	ed.prompt_cursor = prev
}

// prompt_delete deletes one UTF-8 codepoint at the prompt cursor, if any.
// When a selection is active it deletes the whole selection instead.
fn (mut ed Editor) prompt_delete() {
	beg, end := ed.prompt_selection()
	if beg >= 0 {
		ed.prompt_text = ed.prompt_text[..beg] + ed.prompt_text[end..]
		ed.prompt_cursor = beg
		ed.prompt_sel = -1
		return
	}
	off := ed.prompt_effective_cursor()
	if off >= ed.prompt_text.len {
		return
	}
	nxt := prompt_next_codepoint(ed.prompt_text, off)
	ed.prompt_text = ed.prompt_text[..off] + ed.prompt_text[nxt..]
}

// prompt_kill_to_end deletes from the cursor to the end of the prompt.
fn (mut ed Editor) prompt_kill_to_end() {
	off := ed.prompt_effective_cursor()
	if off >= ed.prompt_text.len {
		ed.prompt_sel = -1
		return
	}
	ed.prompt_text = ed.prompt_text[..off]
	ed.prompt_cursor = off
	ed.prompt_sel = -1
}

// prompt_kill_line empties the prompt text entirely.
fn (mut ed Editor) prompt_kill_line() {
	ed.prompt_text = ''
	ed.prompt_cursor = 0
	ed.prompt_sel = -1
}

// prompt_move_home moves the cursor to offset 0.
fn (mut ed Editor) prompt_move_home() {
	ed.prompt_cursor = 0
}

// prompt_move_end moves the cursor past the end of the text.
fn (mut ed Editor) prompt_move_end() {
	ed.prompt_cursor = ed.prompt_text.len
}

// prompt_move_left moves the cursor one UTF-8 codepoint backward.
fn (mut ed Editor) prompt_move_left() {
	off := ed.prompt_effective_cursor()
	ed.prompt_cursor = prompt_prev_codepoint(ed.prompt_text, off)
}

// prompt_move_right moves the cursor one UTF-8 codepoint forward.
fn (mut ed Editor) prompt_move_right() {
	off := ed.prompt_effective_cursor()
	ed.prompt_cursor = prompt_next_codepoint(ed.prompt_text, off)
}

fn (mut ed Editor) run_prompt_search() {
	needle := ed.prompt_search_needle()
	// The Rust editline writes state.search_needle as you type, so the needle
	// stays active even if the prompt is dismissed with Escape.
	ed.last_search = needle
	if needle == '' {
		ed.search_failed = false
		return
	}
	mut b := &ed.docs[ed.active].buf
	b.find_and_select(needle, ed.search_options)
	b.make_cursor_visible()
	ed.search_failed = !b.has_selection()
	if !b.has_selection() {
		ed.status = 'not found: ${needle}'
	}
	ed.update_search_stats()
}

// update_search_stats refreshes the hit counter (index/total) shown on the
// search options row and the status bar.
fn (mut ed Editor) update_search_stats() {
	if ed.docs.len == 0 || ed.last_search == '' {
		ed.search_hit_index = 0
		ed.search_hit_total = 0
		return
	}
	b := &ed.docs[ed.active].buf
	ed.search_hit_index, ed.search_hit_total = b.search_match_stats(ed.last_search,
		ed.search_options)
	ed.search_hit_generation = b.buffer.generation()
}

fn (mut ed Editor) toggle_search_option(kind SearchButtonKind) {
	match kind {
		.match_case { ed.search_options.match_case = !ed.search_options.match_case }
		.whole_word { ed.search_options.whole_word = !ed.search_options.whole_word }
		.use_regex { ed.search_options.use_regex = !ed.search_options.use_regex }
	}
	ed.run_prompt_search()
}

fn (mut ed Editor) handle_search_prompt_mouse(mouse InputMouse) bool {
	if mouse.drag || mouse.state != .left {
		return false
	}
	options_y := if ed.search_panel_top() { CoordType(2) } else { ed.size.height - 2 }
	if mouse.position.y != options_y {
		return false
	}
	for btn in ed.search_buttons {
		if mouse.position.x >= btn.left && mouse.position.x < btn.right {
			ed.toggle_search_option(btn.kind)
			return true
		}
	}
	return true
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
			} else if mods == kbmod_ctrl_alt {
				// Ctrl+Alt+Enter in the replacement field replaces every
				// occurrence (Rust draw_editor.rs:109, SearchAction::ReplaceAll).
				// The needle field only handles plain Enter in Rust, so this
				// stays limited to the second prompt.
				if ed.prompt_kind == .replace_with {
					ed.replace_all = true
					ed.confirm_prompt()
				}
			}
		}
		vk_f3 {
			// F3 works from inside the prompt as well (Rust main.rs:410 runs
			// search_execute globally), using the needle currently in the
			// prompt, which the Rust editline edits in place.
			if mods == kbmod_none {
				needle := ed.prompt_search_needle()
				if needle != '' {
					ed.last_search = needle
				}
				ed.find_next()
			} else if mods == kbmod_shift {
				needle := ed.prompt_search_needle()
				if needle != '' {
					ed.last_search = needle
				}
				ed.find_previous()
			}
		}
		vk_up, vk_down {
			// ↑/↓ step through hits without the F-keys: Mac keyboards need
			// fn+F3 unless the system "standard function keys" toggle is on,
			// and terminals can't distinguish Shift+Enter without the kitty
			// keyboard protocol.
			if mods == kbmod_none && ed.prompt_kind != .goto_line {
				needle := ed.prompt_search_needle()
				if needle != '' {
					ed.last_search = needle
				}
				if vk == vk_up {
					ed.find_previous()
				} else {
					ed.find_next()
				}
			}
		}
		vk_back {
			if mods == kbmod_none {
				ed.prompt_backspace()
			}
		}
		vk_delete {
			if mods == kbmod_none {
				ed.prompt_delete()
			}
		}
		vk_left {
			// No-Shift ← clears the selection first, Shift+← extends it
			// (Rust editline: arrow keys move, Shift+arrow extends).
			if mods == kbmod_none {
				ed.prompt_sel = -1
				ed.prompt_move_left()
			} else if mods == kbmod_shift {
				if ed.prompt_sel < 0 {
					ed.prompt_sel = ed.prompt_cursor
				}
				ed.prompt_move_left()
			}
		}
		vk_right {
			if mods == kbmod_none {
				ed.prompt_sel = -1
				ed.prompt_move_right()
			} else if mods == kbmod_shift {
				if ed.prompt_sel < 0 {
					ed.prompt_sel = ed.prompt_cursor
				}
				ed.prompt_move_right()
			}
		}
		vk_home {
			if mods == kbmod_none {
				ed.prompt_sel = -1
				ed.prompt_move_home()
			} else if mods == kbmod_shift {
				if ed.prompt_sel < 0 {
					ed.prompt_sel = ed.prompt_cursor
				}
				ed.prompt_move_home()
			}
		}
		vk_end {
			if mods == kbmod_none {
				ed.prompt_sel = -1
				ed.prompt_move_end()
			} else if mods == kbmod_shift {
				if ed.prompt_sel < 0 {
					ed.prompt_sel = ed.prompt_cursor
				}
				ed.prompt_move_end()
			}
		}
		vk_a {
			if mods == kbmod_ctrl {
				// Ctrl+A in Rust's editline is Select All (tui.rs:2734):
				// anchor at 0, cursor at end, so any subsequent typing
				// replaces the whole field.
				ed.prompt_sel = 0
				ed.prompt_cursor = ed.prompt_text.len
			}
		}
		vk_k {
			if mods == kbmod_ctrl {
				ed.prompt_kill_to_end()
			}
		}
		vk_u {
			if mods == kbmod_ctrl {
				ed.prompt_kill_line()
			}
		}
		vk_c {
			if mods == kbmod_alt {
				ed.toggle_search_option(.match_case)
			}
		}
		vk_w {
			if mods == kbmod_alt {
				ed.toggle_search_option(.whole_word)
			}
		}
		vk_r {
			if mods == kbmod_alt {
				ed.toggle_search_option(.use_regex)
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
				ed.move_cursor_to_selection_beg()
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
				count := b.find_and_replace_all(needle, ed.search_options, text.bytes())
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
			point := parse_prompt_goto(text) or {
				ed.restart_prompt_with_error(.goto_line, text, err.msg())
				return
			}
			mut b := &ed.docs[ed.active].buf
			// logical_line_count is always >= 1 (an empty document still has
			// a single empty line), so last_line is non-negative.
			last_line := b.logical_line_count() - 1
			target_y := goto_line_index(point.line, last_line)
			// Column 1 is the start of the line; logical_pos.x is 0-based.
			target_x := coord_max(CoordType(point.column - 1), CoordType(0))
			// cursor_move_to_logical clamps at line end via measure_forward,
			// so an out-of-range column naturally snaps to the line tail.
			b.cursor_move_to_logical(Point{ x: target_x, y: target_y })
			b.make_cursor_visible()
		}
	}
}

// move_cursor_to_selection_beg drops the cursor at the start of the selection.
// Rust's find_and_select("") does exactly this and nothing else
// (buffer/mod.rs:1126-1130): an empty needle clears no selection, it just
// rewinds the cursor.
fn (mut ed Editor) move_cursor_to_selection_beg() {
	mut b := &ed.docs[ed.active].buf
	if b.has_selection() {
		b.cursor_move_to_logical(b.selection.beg)
		b.make_cursor_visible()
	}
}

// find_next selects the next occurrence of the last search term (F3).
fn (mut ed Editor) find_next() {
	if ed.last_search == '' {
		ed.move_cursor_to_selection_beg()
		return
	}
	mut b := &ed.docs[ed.active].buf
	// find_and_select() already advances past the previous hit via its
	// internal next_search_offset, as long as the selection is untouched.
	b.find_and_select(ed.last_search, ed.search_options)
	b.make_cursor_visible()
	// Mirror Rust's state.search_success, so an F3 from inside the search
	// prompt also paints the prompt line red when it misses.
	ed.search_failed = !b.has_selection()
	if !b.has_selection() {
		ed.status = 'not found: ${ed.last_search}'
	}
	ed.update_search_stats()
}

// find_previous selects the previous occurrence of the last search term
// (Shift+F3; V-only addition, the Rust original has no reverse search).
fn (mut ed Editor) find_previous() {
	if ed.last_search == '' {
		ed.move_cursor_to_selection_beg()
		return
	}
	mut b := &ed.docs[ed.active].buf
	b.find_and_select_prev(ed.last_search, ed.search_options)
	b.make_cursor_visible()
	ed.search_failed = !b.has_selection()
	if !b.has_selection() {
		ed.status = 'not found: ${ed.last_search}'
	}
	ed.update_search_stats()
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
	b.find_and_replace(needle, ed.search_options, replacement.bytes())
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
	// Mirror Rust's open_for_writing: create missing parent directories so
	// saving into a fresh nested path doesn't require mkdir -p up front.
	dir := os.dir(path)
	if dir != '' && dir != '.' && !os.exists(dir) {
		os.mkdir_all(dir) or {
			ed.error_log_add('save failed: cannot create ${dir}: ${err}')
			return
		}
	}
	ed.docs[ed.active].buf.write_file(path) or {
		ed.error_log_add('save failed: ${path}: ${err}')
		return
	}
	if fid := file_id(path) {
		ed.docs[ed.active].file_id = fid
		ed.docs[ed.active].has_file_id = true
	}
	ed.docs[ed.active].buf.mark_as_clean()
	ed.status = 'saved ${path}'
}

// close_active closes the active document (Ctrl+W). Dirty documents pop up
// the dirty_modal instead.
fn (mut ed Editor) close_active() {
	if ed.docs[ed.active].buf.is_dirty() {
		ed.dirty_modal = true
		ed.dirty_for_quit = false
		ed.dirty_action = 2 // default focus: Cancel
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

// next_document cycles to the next document (Ctrl+PageDown).
fn (mut ed Editor) next_document() {
	if ed.docs.len > 1 {
		ed.active = (ed.active + 1) % ed.docs.len
		ed.reset_view_state()
	}
}

// request_exit quits, showing the dirty modal if there are unsaved changes.
fn (mut ed Editor) request_exit() {
	if ed.any_dirty() {
		ed.dirty_modal = true
		ed.dirty_for_quit = true
		ed.dirty_action = 2
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
			// Esc closes the indentation popup if it's open.
			if ed.indent_picker {
				ed.indent_picker = false
			}
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
				ed.open_goto_file()
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
			} else if mods == kbmod_shift {
				ed.find_previous()
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
//
// Two-stage behavior (Rust tui.rs 2519-2588):
//  - End (word-wrap): first → visual line end; second (if logical didn't
//    change) → logical line end.
//  - Home (indentation-aware): first → visual x=0; if already at logical line
//    start and line has indent → indent_end; otherwise if at x=0 → indent_end.
fn (mut ed Editor) handle_home_end(vk u32, mods u32) {
	mut b := &ed.docs[ed.active].buf
	if vk == vk_home {
		logical_before := b.cursor_logical_pos()
		mut destination := Point{ x: 0, y: b.cursor_visual_pos().y }
		if mods == kbmod_ctrl || mods == kbmod_ctrl_shift {
			destination = Point{}
		}
		if mods == kbmod_shift || mods == kbmod_ctrl_shift {
			b.selection_update_visual(destination)
		} else {
			b.cursor_move_to_visual(destination)
		}
		// Second stage: word-wrap two-stage + indentation-aware Home.
		if mods != kbmod_ctrl && mods != kbmod_ctrl_shift {
			mut logical_after := b.cursor_logical_pos()
			// Word-wrap two-stage: if visual move didn't change logical pos,
			// the cursor was at the logical line start — a second press goes
			// to the true start of the logical line.
			if b.is_word_wrap_enabled() && logical_after == logical_before {
				if mods == kbmod_shift {
					b.selection_update_logical(Point{ x: 0, y: logical_after.y })
				} else {
					b.cursor_move_to_logical(Point{ x: 0, y: logical_after.y })
				}
				logical_after = b.cursor_logical_pos()
			}
			// Indentation-aware: if now at x=0 and the line has meaningful
			// indentation (or we started at x=0), Home → indent_end.
			// This is the "first stop at indentation" behavior of Rust.
			indent_end := b.indent_end_logical_pos()
			if logical_after.x == 0
				&& (logical_before.x == 0 || logical_before.y != logical_after.y
					|| logical_before.x >= indent_end.x) {
				if mods == kbmod_shift {
					b.selection_update_logical(indent_end)
				} else {
					b.cursor_move_to_logical(indent_end)
				}
			}
		}
	} else { // vk_end
		logical_before := b.cursor_logical_pos()
		mut destination := Point{ x: coord_type_max, y: b.cursor_visual_pos().y }
		if mods == kbmod_ctrl || mods == kbmod_ctrl_shift {
			destination = point_max()
		}
		if mods == kbmod_shift || mods == kbmod_ctrl_shift {
			b.selection_update_visual(destination)
		} else {
			b.cursor_move_to_visual(destination)
		}
		// Word-wrap two-stage: if visual move didn't change logical position,
		// the cursor was at the logical line end — a second press goes to the
		// true end of the logical line.
		if mods != kbmod_ctrl && mods != kbmod_ctrl_shift {
			mut logical_after := b.cursor_logical_pos()
			if b.is_word_wrap_enabled() && logical_after == logical_before {
				if mods == kbmod_shift {
					b.selection_update_logical(Point{ x: coord_type_max, y: logical_after.y })
				} else {
					b.cursor_move_to_logical(Point{ x: coord_type_max, y: logical_after.y })
				}
			}
		}
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
		if ed.mode == .prompt && (ed.prompt_kind == .search || ed.prompt_kind == .replace
			|| ed.prompt_kind == .replace_with) {
			if ed.handle_search_prompt_mouse(mouse) {
				return
			}
		}
		return
	}

	// While the indentation picker is open, swallow all mouse input: clicks
	// inside the popup act on it, everything else just closes it.
	if ed.indent_picker {
		if mouse.drag || mouse.state != .left {
			ed.indent_picker = false
			return
		}
		status_y := ed.size.height - 1
		if mouse.position.y == status_y - 1 || mouse.position.y == status_y - 2 {
			ed.handle_indent_popup_click(mouse.position.x, mouse.position.y - (status_y - 2))
		} else {
			ed.indent_picker = false
		}
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

	// Clicks on the status line activate its buttons.
	status_y := ed.size.height - 1
	if mouse.position.y == status_y && !mouse.drag {
		ed.handle_status_click(mouse.position.x)
		return
	}
	if mouse.position.y >= status_y {
		return
	}

	// Click into the text area. Row 0 is the menu bar, so the text area
	// starts one row lower. The line-number gutter (left margin) is handled
	// separately: a click there selects the whole line (Rust tui.rs selects
	// the line when the down-position is outside the text rect).
	mut b := &ed.docs[ed.active].buf
	margin := b.margin_width()
	if !mouse.drag && mouse.position.x < margin {
		visual_y := coord_max(mouse.position.y - 1 + ed.scroll.y, 0)
		// Resolve the clicked visual row to its logical line, then select it.
		b.cursor_move_to_visual(Point{ x: 0, y: visual_y })
		logical_y := b.cursor_logical_pos().y
		b.cursor_move_to_logical(Point{ x: 0, y: logical_y })
		b.select_line()
		b.make_cursor_visible()
		return
	}

	// Visual position under the cursor, in document coordinates.
	pos := Point{
		x: coord_max(mouse.position.x - margin + ed.scroll.x, 0)
		y: coord_max(mouse.position.y - 1 + ed.scroll.y, 0)
	}

	if mouse.drag {
		// Drag with the button held: anchor a selection at the press point
		// and extend it to here, auto-scrolling if we reach the edge.
		if !b.has_selection() {
			b.start_selection()
		}
		b.selection_update_visual(pos)
		ed.autoscroll_drag(mouse, status_y)
	} else {
		// Multi-click: consecutive presses at the same spot within 500ms
		// escalate to word/line/all selection (Rust tui.rs click counter).
		ed.update_click_count(mouse.position)
		match ed.click_count {
			2 {
				b.cursor_move_to_visual(pos)
				b.select_word()
			}
			3 {
				b.cursor_move_to_visual(pos)
				b.select_line()
			}
			4 {
				b.cursor_move_to_visual(pos)
				b.select_all()
			}
			else {
				if mouse.modifiers & kbmod_shift != 0 {
					// Shift+Click extends the selection to the cursor.
					b.selection_update_visual(pos)
				} else {
					b.clear_selection()
					b.cursor_move_to_visual(pos)
				}
			}
		}
	}
	b.make_cursor_visible()
}

// update_click_count maintains the multi-click counter used for word/line/all
// selection. A press within 500ms of, and at the same position as, the previous
// one increments the counter; otherwise it resets to 1 (Rust tui.rs).
fn (mut ed Editor) update_click_count(pos Point) {
	now := time.now().unix_milli()
	if pos.x == ed.last_click_x && pos.y == ed.last_click_y
		&& now - ed.last_click_ms <= 500 {
		ed.click_count++
	} else {
		ed.click_count = 1
	}
	ed.last_click_x = pos.x
	ed.last_click_y = pos.y
	ed.last_click_ms = now
	ed.drag_anchor_x = pos.x
	ed.drag_anchor_y = pos.y
}

// autoscroll_drag scrolls the view when a drag reaches the top/bottom edge of
// the text area, extending the selection to the visible edge (Rust tui.rs
// calc()/read_timeout auto-scroll). Mirrors the zone-based speed table.
fn (mut ed Editor) autoscroll_drag(mouse InputMouse, status_y CoordType) {
	mut b := &ed.docs[ed.active].buf
	text_top := CoordType(1)
	text_bottom := status_y - 1
	height := text_bottom - text_top
	if height < 2 {
		return
	}
	zone := coord_min(height / 2, 3)
	// Bound the scroll zones by the drag anchor, like Rust's down.min/max.
	scroll_min := coord_min(ed.drag_anchor_y, text_top + zone)
	scroll_max := coord_max(ed.drag_anchor_y, text_bottom - zone - 1)
	delta_min := coord_clamp(mouse.position.y - scroll_min, -zone, 0)
	delta_max := coord_clamp(mouse.position.y - scroll_max, 0, zone)
	idx := coord_clamp(3 + delta_min + delta_max, 0, 6)
	speeds := [CoordType(-9), -3, -1, 0, 1, 3, 9]
	dy := speeds[idx]
	if dy == 0 {
		return
	}
	ed.scroll.y += dy
	ed.clamp_scroll()
	// Re-extend the selection to the visible edge so it grows with the scroll.
	edge_y := coord_clamp(mouse.position.y - 1 + ed.scroll.y, ed.scroll.y,
		ed.scroll.y + height - 1)
	x := coord_max(mouse.position.x - b.margin_width() + ed.scroll.x, 0)
	b.selection_update_visual(Point{ x: x, y: edge_y })
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
	// ...minus the menu bar and status line.
	mut viewport_height := ed.size.height - 2
	// While a search prompt is open the panel sits above the textarea (rows
	// 1-2 in Rust's layout, just below the menu bar), so one more row is
	// not usable. Rust drops the same row via height_reduction
	// (draw_editor.rs:21-25).
	if ed.mode == .prompt && ed.prompt_kind != .goto_line {
		viewport_height--
	}

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

// search_kind_prompt reports whether the active prompt is a search/replace
// prompt (which Rust draws as a panel above the textarea), as opposed to the
// goto-line prompt (a plain status-line input).
fn (ed Editor) search_kind_prompt() bool {
	return ed.mode == .prompt
		&& match ed.prompt_kind {
			.search, .replace, .replace_with { true }
			else { false }
		}
}

// search_panel_top reports whether the search UI is drawn as a top panel
// (rows 1-2, below the menu bar, like the Rust original). On tiny terminals
// (< 5 rows) it falls back to the bottom rows.
fn (ed Editor) search_panel_top() bool {
	return ed.search_kind_prompt() && ed.size.height >= 5
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

	// The text area covers everything but the menu bar (row 0), the
	// last (status) line, and the scrollbar column on the right. When a
	// search/replace prompt is open the panel sits above the textarea
	// (rows 1-2 below the menu bar, like the Rust original), so the top
	// edge jumps to row 3 in that mode.
	destination := Rect{
		left:   0
		top:    if ed.search_panel_top() { CoordType(3) } else { CoordType(1) }
		right:  ed.size.width - scrollbar_width
		bottom: ed.size.height - 1
	}
	if res := b.render(ed.scroll, destination, true, mut ed.fb) {
		ed.scroll_x_max = res.visual_pos_x_max
	}

	// Scrollbar along the right edge of the text area.
	if ed.size.width > scrollbar_width {
		ed.fb.draw_scrollbar(ed.size.as_rect(), Rect{
			left:   ed.size.width - scrollbar_width
			top:    destination.top
			right:  ed.size.width
			bottom: destination.bottom
		}, ed.scroll.y, b.visual_line_count())
	}

	// Status line / prompt.
	status_y := ed.size.height - 1
	if ed.mode == .prompt {
		match ed.prompt_kind {
			.search, .replace, .replace_with {
				if ed.search_panel_top() {
					// Rust layout: search panel above the textarea — input on
					// row 1, options (with the hit counter) on row 2. The
					// status bar stays put at the bottom.
					ed.draw_prompt_line(1)
					ed.draw_search_prompt_options(2)
					ed.draw_statusbar(status_y)
				} else {
					if status_y > 0 {
						ed.draw_search_prompt_options(status_y - 1)
					}
					ed.draw_prompt_line(status_y)
				}
			}
			else {
				ed.draw_prompt_line(status_y)
			}
		}
	} else {
		ed.draw_statusbar(status_y)
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
	if ed.goto_file {
		ed.draw_goto_file()
	}
	if ed.about_open {
		ed.draw_about()
	}
	if ed.indent_picker {
		ed.draw_indent_picker(status_y)
	}
	if ed.language_picker {
		ed.draw_language_picker(status_y)
	}
	if ed.clipboard_large_pending {
		ed.draw_clipboard_warning()
	}
	if ed.dirty_modal {
		ed.draw_dirty_modal()
	}
	if ed.error_log_count > 0 && ed.error_log_open {
		ed.draw_error_log()
	}

	write_stdout(ed.fb.render())
	ed.status = ''
}

// draw_statusbar renders the status line: clickable buttons on the left, the
// file name on the right, and a status message or key hints in between. It
// also records the button hit-rects (ed.status_buttons) for mouse handling,
// mirroring the left button group of Rust's draw_statusbar.rs.
fn (mut ed Editor) draw_statusbar(status_y CoordType) {
	ed.status_buttons = ed.compute_status_buttons()
	mut b := &ed.docs[ed.active].buf

	mut text := ' [${ed.active + 1}/${ed.docs.len}] '
	mut x := CoordType(text.len)

	// Language name (Rust "language"): a clickable button that opens the
	// language picker. The label is the resolved name — Auto Detect when the
	// buffer has no explicit override, otherwise the chosen name.
	lang := ed.statusbar_lang_label()
	ed.status_buttons << StatusButton{ kind: .language, left: x, right: x + CoordType(lang.len) }
	text += lang + '  '
	x += CoordType(lang.len + 2)

	// Newline button (Rust "newline"): click toggles CRLF/LF.
	nl := if b.is_crlf() { 'CRLF' } else { 'LF' }
	ed.status_buttons << StatusButton{ kind: .newline, left: x, right: x + CoordType(nl.len) }
	text += nl + '  '
	x += CoordType(nl.len + 2)

	// Indentation button (Rust "indentation"): click opens the picker popup.
	ind := (if b.indent_with_tabs() { 'Tabs' } else { 'Spaces' }) + ':${b.tab_size()}'
	ed.status_buttons << StatusButton{ kind: .indentation, left: x, right: x + CoordType(ind.len) }
	text += ind + '  '
	x += CoordType(ind.len + 2)

	pos := b.cursor_logical_pos()
	pos_str := 'Ln ${pos.y + 1}, Col ${pos.x + 1}'
	text += pos_str
	x += CoordType(pos_str.len)
	// Hit counter of the active search ("3/17"), dropped as soon as the
	// buffer is edited (generation no longer matches).
	if ed.search_hit_total > 0 && ed.last_search != ''
		&& ed.search_hit_generation == b.buffer.generation() {
		hits := if ed.search_hit_index > 0 {
			'${ed.search_hit_index}/${ed.search_hit_total}'
		} else {
			'${ed.search_hit_total}'
		}
		text += '  ' + hits
		x += CoordType(hits.len + 2)
	}
	if b.is_overtype() {
		text += '  OVR'
		x += 6
	}

	name := if ed.cur().path == '' { '[untitled]' } else { ed.cur().path }
	right := (if b.is_dirty() { '* ' } else { '' }) + name

	// Filename button (Rust "filename"): right-aligned clickable region that
	// opens the Go to File modal; aligns with Rust draw_statusbar.rs:196.
	right_text := right
	right_start := ed.size.width - CoordType(right_text.len) - 1
	ed.status_buttons << StatusButton{ kind: .filename, left: right_start, right: right_start + CoordType(right_text.len) }

	// Middle: a status message when there is one, otherwise the key hints.
	mut mid := ed.status
	if mid == '' {
		mid = '^S save ^O open ^F find ^Q quit'
	}
	mut avail := ed.size.width - x - CoordType(right.len) - 1
	if avail < 0 {
		avail = 0
	}
	if CoordType(mid.len) > avail {
		if avail > 3 {
			mid = mid[..int(avail) - 3] + '...'
		} else {
			mid = ''
		}
	}
	mut pad := ed.size.width - x - CoordType(mid.len) - CoordType(right.len)
	if pad < 1 {
		pad = 1
	}
	text += ' '.repeat(int(pad)) + mid + ' ' + right

	ed.fb.replace_text(status_y, 0, ed.size.width, text)
	mut rect := Rect{ left: 0, top: status_y, right: ed.size.width, bottom: status_y + 1 }
	ed.fb.reverse(mut rect)
	// Buttons are highlighted by reversing their own rect a second time
	// (same trick as the menu bar), reading as raised against the inverted row.
	for btn in ed.status_buttons {
		mut btn_rect := Rect{ left: btn.left, top: status_y, right: btn.right, bottom: status_y + 1 }
		ed.fb.reverse(mut btn_rect)
	}
}

// draw_indent_picker renders the indentation popup above the status line: a
// Tabs/Spaces row and a width 1-8 row, with the current selection highlighted.
fn (mut ed Editor) draw_indent_picker(status_y CoordType) {
	b := &ed.docs[ed.active].buf
	width := CoordType(20)
	mut left := CoordType(0)
	for btn in ed.compute_status_buttons() {
		if btn.kind == .indentation {
			left = btn.right - width
		}
	}
	if left < 0 {
		left = 0
	}
	ed.indent_popup_left = left

	mut top := status_y - 2
	if top < 1 {
		top = 1
	}

	// Reverse the whole block first so it reads as a floating panel.
	mut rect := Rect{ left: left, top: top, right: left + width, bottom: top + 2 }
	ed.fb.reverse(mut rect)

	r1 := ' Tabs        Spaces '
	mid := left + width / 2
	ed.fb.replace_text(top, left, left + width, r1)
	if b.indent_with_tabs() {
		mut tabs_rect := Rect{ left: left, top: top, right: mid, bottom: top + 1 }
		ed.fb.reverse(mut tabs_rect)
	} else {
		mut spaces_rect := Rect{ left: mid, top: top, right: left + width, bottom: top + 1 }
		ed.fb.reverse(mut spaces_rect)
	}

	mut r2 := ' '
	for w in 1 .. 9 {
		r2 += '${w} '
	}
	if r2.len < int(width) {
		r2 += ' '.repeat(int(width) - r2.len)
	}
	ed.fb.replace_text(top + 1, left, left + width, r2)
	for w in 1 .. 9 {
		if b.tab_size() == w {
			col := left + CoordType(2 * (w - 1)) + 1
			mut col_rect := Rect{ left: col, top: top + 1, right: col + 2, bottom: top + 2 }
			ed.fb.reverse(mut col_rect)
		}
	}
}

// handle_status_click dispatches a click on the status line to its buttons.
// compute_status_buttons returns the clickable status-line button rectangles
// for the active document, computed live from the buffer state. This avoids
// depending on ed.status_buttons (which is only filled during draw()), so a
// click is always handled correctly even before the first redraw.
fn (ed &Editor) compute_status_buttons() []StatusButton {
	b := &ed.docs[ed.active].buf
	mut x := CoordType(0)
	mut res := []StatusButton{}

	idx := ' [${ed.active + 1}/${ed.docs.len}] '
	x += CoordType(idx.len)
	lang := ed.statusbar_lang_label()
	res << StatusButton{ kind: .language, left: x, right: x + CoordType(lang.len) }
	x += CoordType(lang.len + 2)

	nl := if b.is_crlf() { 'CRLF' } else { 'LF' }
	res << StatusButton{ kind: .newline, left: x, right: x + CoordType(nl.len) }
	x += CoordType(nl.len + 2)

	ind := (if b.indent_with_tabs() { 'Tabs' } else { 'Spaces' }) + ':${b.tab_size()}'
	res << StatusButton{ kind: .indentation, left: x, right: x + CoordType(ind.len) }
	return res
}

// statusbar_lang_label returns the language label rendered on the status
// line for the active buffer. With the explicit-override sentinel at -2 the
// label shows "Auto Detect" (mirrors Rust draw_dialog_language_change).
fn (ed &Editor) statusbar_lang_label() string {
	if ed.language_picker_explicit == -2 {
		return 'Auto Detect'
	}
	b := &ed.docs[ed.active].buf
	lang := b.language()
	if lang < 0 {
		return 'Plain Text'
	}
	return lsh_languages[lang].name
}

// handle_status_click dispatches a click on the status line to its buttons.
fn (mut ed Editor) handle_status_click(x CoordType) {
	for btn in ed.compute_status_buttons() {
		if x >= btn.left && x < btn.right {
			mut b := &ed.docs[ed.active].buf
			match btn.kind {
				.newline {
					b.normalize_newlines(!b.is_crlf())
				}
				.indentation {
					ed.indent_picker = true
				}
				.language {
					ed.open_language_picker()
				}
				.filename {
					ed.open_goto_file()
				}
			}
			return
		}
	}
	// Filename button lives outside compute_status_buttons (it's right-aligned
	// in draw_statusbar, not in the left group). Test it after the main loop
	// so a click in either group is routed exactly once.
	for btn in ed.status_buttons {
		if btn.kind == .filename && x >= btn.left && x < btn.right {
			ed.open_goto_file()
			return
		}
	}
}

// handle_indent_popup_click handles a click inside the indentation popup.
// `row` is 0 for the Tabs/Spaces row and 1 for the width row.
fn (mut ed Editor) handle_indent_popup_click(x CoordType, row CoordType) {
	mut b := &ed.docs[ed.active].buf
	left := ed.indent_popup_left
	if row == 0 {
		// Left half selects Tabs, right half selects Spaces.
		b.set_indent_with_tabs(x < left + 10)
	} else {
		// Widths 1-8, each 2 columns wide starting at left+1.
		col := x - (left + 1)
		if col >= 0 && col < 16 {
			b.set_tab_size(col / 2 + 1)
		}
	}
}


// ---- Large clipboard warning ------------------------------------------------------
//
// Centered modal that gates OSC 52 sync of payloads >= 128 KiB. Three actions:
// Always (sets the sticky preference and sends), Yes (sends once), No (drops).

// clipboard_size_label formats a byte count as a human-readable KiB/MiB string.
fn clipboard_size_label(size int) string {
	if size >= 1024 * 1024 {
		mib := size / (1024 * 1024)
		dec := (size % (1024 * 1024)) * 10 / (1024 * 1024)
		if dec == 0 {
			return '${mib} MiB'
		}
		return '${mib}.${dec} MiB'
	}
	kib := size / 1024
	dec := (size % 1024) * 10 / 1024
	if dec == 0 {
		return '${kib} KiB'
	}
	return '${kib}.${dec} KiB'
}

// draw_clipboard_warning renders the centered "send to terminal?" modal.
fn (mut ed Editor) draw_clipboard_warning() {
	box_w := CoordType(56)
	lines := [
		'Large clipboard data (~${clipboard_size_label(ed.clipboard.clipboard_size())}) —',
		'send to terminal?',
		'',
		'[ Always ]  [ Yes ]  [ No ]',
	]
	box_h := CoordType(lines.len)
	left := coord_max((ed.size.width - box_w) / 2, 0)
	top := coord_max((ed.size.height - box_h) / 2, 0)
	right := coord_min(left + box_w, ed.size.width)
	for i, text in lines {
		y := top + CoordType(i)
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

// handle_clipboard_warning_key processes keyboard input for the warning.
// y/Enter = Yes, n/Esc = No, a = Always (also sends).
fn (mut ed Editor) handle_clipboard_warning_key(key InputKey) {
	mods := u32(key) & kbmod_mask
	vk := u32(key) & vk_mask
	match vk {
		vk_escape {
			ed.resolve_clipboard_warning(false, false)
		}
		vk_return {
			if mods == kbmod_none {
				ed.resolve_clipboard_warning(true, false)
			}
		}
		vk_y {
			ed.resolve_clipboard_warning(true, false)
		}
		vk_n {
			ed.resolve_clipboard_warning(false, false)
		}
		vk_a {
			ed.resolve_clipboard_warning(true, true)
		}
		else {}
	}
}

// handle_clipboard_warning_text accepts printable text (y/n/a/Enter arrive via
// text events too in some terminal configurations).
fn (mut ed Editor) handle_clipboard_warning_text(text string) {
	for c in text {
		match c {
			`y`, `Y` { ed.resolve_clipboard_warning(true, false); return }
			`n`, `N` { ed.resolve_clipboard_warning(false, false); return }
			`a`, `A` { ed.resolve_clipboard_warning(true, true); return }
			`\n`, `\r` { ed.resolve_clipboard_warning(true, false); return }
			else {}
		}
	}
}

// handle_clipboard_warning_mouse dispatches a click on one of the three
// inline buttons at the bottom of the warning modal.
fn (mut ed Editor) handle_clipboard_warning_mouse(mouse InputMouse) {
	if mouse.state != .left || mouse.drag {
		return
	}
	box_w := CoordType(56)
	box_h := CoordType(4)
	left := coord_max((ed.size.width - box_w) / 2, 0)
	top := coord_max((ed.size.height - box_h) / 2, 0)
	right := coord_min(left + box_w, ed.size.width)
	bottom := coord_min(top + box_h, ed.size.height)
	// Rust modal_end semantics: click outside dismisses (equivalent to "N").
	if mouse.position.x < left || mouse.position.x >= right
		|| mouse.position.y < top || mouse.position.y >= bottom {
		ed.resolve_clipboard_warning(false, false)
		return
	}
	// Buttons live on the 4th (last) row of the modal; the rect math mirrors
	// the inline label '[ Always ]  [ Yes ]  [ No ]'.
	if mouse.position.y != top + 3 {
		return
	}
	if mouse.position.x < left || mouse.position.x >= right {
		return
	}
	// Cell boundaries, computed live: each "[ Label ]" is 10 columns wide and
	// separated from its neighbor by 2 columns.
	cell_w := CoordType(10)
	// Three cells at offsets 0, 12, 24 within the 56-column box.
	cell_offsets := [CoordType(0), CoordType(12), CoordType(24)]
	labels := [0, 1, 2]! // 0 = Always, 1 = Yes, 2 = No
	for j, off in cell_offsets {
		cell_left := left + off
		if mouse.position.x >= cell_left && mouse.position.x < cell_left + cell_w {
			match labels[j] {
				0 { ed.resolve_clipboard_warning(true, true) }
				1 { ed.resolve_clipboard_warning(true, false) }
				2 { ed.resolve_clipboard_warning(false, false) }
				else {}
			}
			return
		}
	}
}

// resolve_clipboard_warning closes the warning modal and either sends the
// OSC 52 payload (`send=true`) or drops it. When `always=true` the sticky
// preference is also flipped, so future large-clipboard syncs skip the prompt.
fn (mut ed Editor) resolve_clipboard_warning(send bool, always bool) {
	if always {
		ed.clipboard.large_always_send = true
	}
	if send {
		data := ed.clipboard.read()
		if data.len > 0 {
			write_stdout('\x1b]52;c;' + base64.encode(data) + '\x1b\\')
		}
		ed.clipboard.resolve_large_pending(true)
	} else {
		ed.clipboard.resolve_large_pending(false)
	}
	ed.clipboard_large_pending = false
}
