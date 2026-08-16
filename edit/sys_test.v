module main

// sys_test.v — tests for the sys (Unix platform layer) port.
//
// Only headless-testable parts are covered: file_id() on real temp files and
// the pure incomplete_utf8_tail_len() helper. Raw mode, poll reads and
// SIGWINCH handling require a real TTY and are not unit tested (same as the
// Rust original, which has no tests for this module either).

import os

fn test_file_id_same_file() {
	path := os.join_path(os.temp_dir(), 'edit_sys_test_a.txt')
	os.write_file(path, 'hello')!
	defer { os.rm(path) or {} }

	a := file_id(path)!
	b := file_id(path)!
	assert a == b
	assert a.st_ino != 0
}

fn test_file_id_different_files() {
	path_a := os.join_path(os.temp_dir(), 'edit_sys_test_a.txt')
	path_b := os.join_path(os.temp_dir(), 'edit_sys_test_b.txt')
	os.write_file(path_a, 'hello')!
	os.write_file(path_b, 'world')!
	defer {
		os.rm(path_a) or {}
		os.rm(path_b) or {}
	}

	a := file_id(path_a)!
	b := file_id(path_b)!
	assert a != b
}

fn test_file_id_missing_file() {
	file_id('/nonexistent/edit_sys_test_nope.txt') or { return }
	assert false, 'expected error for missing file'
}

fn test_incomplete_utf8_tail_len_empty() {
	assert incomplete_utf8_tail_len([]) == 0
}

fn test_incomplete_utf8_tail_len_ascii() {
	assert incomplete_utf8_tail_len('hello'.bytes()) == 0
}

fn test_incomplete_utf8_tail_len_complete_multibyte() {
	// "日本" = 6 bytes, two complete 3-byte sequences.
	assert incomplete_utf8_tail_len('日本'.bytes()) == 0
	// Complete 4-byte sequence (🙂).
	assert incomplete_utf8_tail_len('🙂'.bytes()) == 0
}

fn test_incomplete_utf8_tail_len_partial() {
	e := '日'.bytes() // 3 bytes: E6 97 A5
	// 1 byte of a 3-byte sequence: incomplete, 1 pending.
	assert incomplete_utf8_tail_len([e[0]]) == 1
	// 2 bytes of a 3-byte sequence: 2 pending.
	assert incomplete_utf8_tail_len([e[0], e[1]]) == 2
	// ascii prefix + 2 bytes of a 3-byte sequence.
	mut buf := 'ab'.bytes()
	buf << e[0]
	buf << e[1]
	assert incomplete_utf8_tail_len(buf) == 2
	// 1 byte of a 4-byte sequence.
	f := '🙂'.bytes() // F0 9F 99 82
	assert incomplete_utf8_tail_len([f[0]]) == 1
	assert incomplete_utf8_tail_len([f[0], f[1], f[2]]) == 3
	// full sequence: nothing pending.
	assert incomplete_utf8_tail_len(f) == 0
}

fn test_incomplete_utf8_tail_len_lone_continuation() {
	// A lone continuation byte is not a valid lead: don't cache it.
	assert incomplete_utf8_tail_len([u8(0x80)]) == 0
	assert incomplete_utf8_tail_len([u8(0x61), 0x80]) == 0
}
