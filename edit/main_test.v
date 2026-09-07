module main

// main_test.v — tests for the small set of pure helpers in main.v.
//
// main.v mostly hosts the Editor + its methods (which need a full
// Framebuffer to instantiate), but a couple of byte-count formatters are
// pure. Keeping them here keeps `cpulimit -l 200 -z -- ./build.sh test`
// honest without dragging in the rest of the editor.

// wr writes a string into a buffer. Each _test.v is compiled on its own, so
// the helper in text_buffer_test.v is not visible here.
fn wr(mut b TextBuffer, s string) {
	b.write_raw(s.bytes())
}

fn test_run_prompt_search_sets_search_failed() {
	mut ed := Editor{ fb: framebuffer_new() }
	ed.add_document('') or { panic('add_document: ${err}') }
	wr(mut ed.docs[ed.active].buf, 'hello world')

	// A needle with no match flips the failed flag (drives the red prompt line).
	ed.mode = .prompt
	ed.prompt_kind = .search
	ed.prompt_text = 'zzz'
	ed.run_prompt_search()
	assert ed.search_failed == true

	// A present needle clears the failed flag.
	ed.prompt_text = 'world'
	ed.run_prompt_search()
	assert ed.search_failed == false
}

fn test_start_prompt_prefills_needle_from_selection() {
	mut ed := Editor{ fb: framebuffer_new() }
	ed.add_document('') or { panic('add_document: ${err}') }
	wr(mut ed.docs[ed.active].buf, 'hello world')
	mut b := &ed.docs[ed.active].buf
	// Select 'world' (offset 6..11 on line 0).
	b.set_selection(OptSelection{ valid: true, beg: Point{ x: 6, y: 0 }, end: Point{ x: 11, y: 0 } })

	// Ctrl+F/Ctrl+R with a selection prefills the needle with it.
	ed.start_prompt(.search)
	assert ed.prompt_text == 'world'
	ed.start_prompt(.replace)
	assert ed.prompt_text == 'world'

	// With no selection, the needle falls back to last_search.
	ed.last_search = 'foo'
	b.set_selection(OptSelection{ valid: false })
	ed.start_prompt(.search)
	assert ed.prompt_text == 'foo'
}

fn test_prompt_f3_finds_next_hit() {
	mut ed := Editor{ fb: framebuffer_new() }
	ed.add_document('') or { panic('add_document: ${err}') }
	wr(mut ed.docs[ed.active].buf, 'foo\nbaz foo\nfoo\n')

	ed.start_prompt(.search)
	ed.prompt_text = 'foo'
	ed.run_prompt_search()

	mut b := &ed.docs[ed.active].buf
	assert b.has_selection()
	assert b.selection.beg.y == 0

	// F3 works from inside the prompt, using the needle currently in it
	// (Rust main.rs:410 runs search_execute with state.search_needle).
	ed.handle_prompt_key(InputKey(vk_f3))
	assert b.selection.beg.y == 1
	ed.handle_prompt_key(InputKey(vk_f3))
	assert b.selection.beg.y == 2
	assert ed.search_failed == false
	assert ed.last_search == 'foo'
}

fn test_clipboard_size_label_bytes() {
	// Below 1 KiB is still formatted in KiB with one decimal.
	assert clipboard_size_label(0) == '0 KiB'
	assert clipboard_size_label(512) == '0.5 KiB'
	assert clipboard_size_label(1023) == '0.9 KiB'
}

fn test_clipboard_size_label_kib_exact() {
	// Exact KiB values drop the decimal.
	assert clipboard_size_label(1024) == '1 KiB'
	assert clipboard_size_label(2 * 1024) == '2 KiB'
	assert clipboard_size_label(127 * 1024) == '127 KiB'
}

fn test_clipboard_size_label_kib_decimal() {
	// The function rounds to one decimal place via integer math:
	// dec = (size % 1024) * 10 / 1024. To get dec == 2 we need
	// (size % 1024) in [205, 307] (so 205*10/1024 = 2).
	assert clipboard_size_label(1024 + 256) == '1.2 KiB'
	// For dec == 5: (size % 1024) in [512, 614]. 512*10/1024 = 5.
	assert clipboard_size_label(1024 + 512) == '1.5 KiB'
	// 100 KiB + 512 bytes → kib=100, dec=512*10/1024=5 → "100.5 KiB".
	assert clipboard_size_label(100 * 1024 + 512) == '100.5 KiB'
}

fn test_clipboard_size_label_mib_exact() {
	// Exact MiB values drop the decimal.
	assert clipboard_size_label(1024 * 1024) == '1 MiB'
	assert clipboard_size_label(2 * 1024 * 1024) == '2 MiB'
	assert clipboard_size_label(8 * 1024 * 1024) == '8 MiB'
}

fn test_clipboard_size_label_mib_decimal() {
	// 1.5 MiB: mib=1, dec = 512*1024*10 / (1024*1024) = 5 → "1.5 MiB".
	assert clipboard_size_label(1024 * 1024 + 512 * 1024) == '1.5 MiB'
	// 2.3 MiB: mib=2, dec = 314573 * 10 / 1048576 = 3 (3145730/1048576=3).
	assert clipboard_size_label(2 * 1024 * 1024 + 314573) == '2.3 MiB'
}
