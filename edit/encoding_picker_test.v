module main

import os

fn encoding_picker_test_editor(path string) Editor {
	mut ed := Editor{
		fb: framebuffer_new()
		size: Size{
			width: 100
			height: 24
		}
	}
	ed.add_document(path) or { panic('add_document: ${err}') }
	return ed
}

fn encoding_picker_write_bytes(path string, data []u8) {
	mut f := os.create(path) or { panic('create ${path}: ${err}') }
	defer { f.close() }
	f.write(data) or { panic('write ${path}: ${err}') }
}

fn encoding_picker_select(mut ed Editor, canonical string) {
	for result_pos, encoding_idx in ed.encoding_picker_results {
		if editor_encodings[encoding_idx].canonical == canonical {
			ed.encoding_picker_sel = result_pos
			return
		}
	}
	panic('encoding not in picker results: ${canonical}')
}

fn test_encoding_picker_fuzzy_filter_and_text_routing() {
	mut ed := encoding_picker_test_editor('')
	ed.open_encoding_picker(.convert)
	assert ed.encoding_picker_results.len == editor_encodings.len

	// Text is consumed by the modal instead of reaching the document.
	ed.handle_event(Input{ kind: .text, text: '16be' })
	assert ed.encoding_picker_needle == '16be'
	assert ed.encoding_picker_results.len == 1
	idx := ed.encoding_picker_results[0]
	assert editor_encodings[idx].canonical == 'UTF-16BE'
	assert ed.docs[ed.active].buf.read_all().bytestr() == ''
}

fn test_encoding_status_button_order_and_untitled_action() {
	mut ed := encoding_picker_test_editor('')
	buttons := ed.compute_status_buttons()
	assert buttons.len == 4
	assert buttons[0].kind == .language
	assert buttons[1].kind == .newline
	assert buttons[2].kind == .encoding
	assert buttons[3].kind == .indentation

	ed.open_encoding_actions()
	assert !ed.encoding_action_picker
	assert ed.encoding_picker
	assert ed.encoding_picker_action == .convert
}

fn test_encoding_convert_marks_document_dirty() {
	mut ed := encoding_picker_test_editor('')
	assert !ed.docs[ed.active].buf.is_dirty()
	ed.open_encoding_picker(.convert)
	encoding_picker_select(mut ed, 'UTF-16LE')
	ed.encoding_picker_apply()

	assert !ed.encoding_picker
	assert ed.docs[ed.active].buf.encoding() == 'UTF-16LE'
	assert ed.docs[ed.active].buf.is_dirty()
	assert ed.status == 'encoding: UTF-16LE'
}

fn test_encoding_reopen_reads_selected_encoding() {
	path := os.join_path(os.temp_dir(), 'edit_v_encoding_reopen.txt')
	os.rm(path) or {}
	defer { os.rm(path) or {} }
	os.write_file(path, 'old') or { panic(err) }
	mut ed := encoding_picker_test_editor(path)
	encoded := encode_text('new 世界\n', 'UTF-16LE') or { panic(err) }
	encoding_picker_write_bytes(path, encoded)

	ed.open_encoding_picker(.reopen)
	encoding_picker_select(mut ed, 'UTF-16LE')
	ed.encoding_picker_apply()

	assert !ed.encoding_picker
	assert ed.docs[ed.active].buf.read_all().bytestr() == 'new 世界\n'
	assert ed.docs[ed.active].buf.encoding() == 'UTF-16LE'
	assert !ed.docs[ed.active].buf.is_dirty()
}

fn test_encoding_reopen_saves_dirty_document_first() {
	path := os.join_path(os.temp_dir(), 'edit_v_encoding_reopen_dirty.txt')
	os.rm(path) or {}
	defer { os.rm(path) or {} }
	os.write_file(path, 'old') or { panic(err) }
	mut ed := encoding_picker_test_editor(path)
	ed.docs[ed.active].buf.write_raw(' changed'.bytes())
	assert ed.docs[ed.active].buf.is_dirty()

	ed.open_encoding_picker(.reopen)
	encoding_picker_select(mut ed, 'UTF-8')
	ed.encoding_picker_apply()

	assert ed.docs[ed.active].buf.read_all().bytestr() == ' changedold'
	assert os.read_file(path) or { panic(err) } == ' changedold'
	assert !ed.docs[ed.active].buf.is_dirty()
}

fn test_encoding_reopen_error_preserves_document_and_logs_path() {
	path := os.join_path(os.temp_dir(), 'edit_v_encoding_reopen_invalid.txt')
	os.rm(path) or {}
	defer { os.rm(path) or {} }
	os.write_file(path, 'keep') or { panic(err) }
	mut ed := encoding_picker_test_editor(path)
	encoding_picker_write_bytes(path, [u8(0xff)])

	ed.open_encoding_picker(.reopen)
	encoding_picker_select(mut ed, 'UTF-16LE')
	ed.encoding_picker_apply()

	assert ed.encoding_picker
	assert ed.docs[ed.active].buf.read_all().bytestr() == 'keep'
	assert ed.docs[ed.active].buf.encoding() == 'UTF-8'
	assert ed.error_log_count == 1
	assert ed.error_log_open
	assert ed.error_log[0].contains('reopen failed: ${path} as UTF-16LE')
}
