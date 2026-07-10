// history_store_test.v — unit tests for the history persistence layer.
//
// Run with: v test history_store
// (or v test . from the project root)
module main

import os

// with_temp_history sets KIMI_HISTORY_FILE to a unique temp path so
// the test doesn't clobber the user's real history. Returns a cleanup
// closure that the test should call at the end.
fn with_temp_history(fn_body fn (path string)) {
	old_env := os.getenv('KIMI_HISTORY_FILE')
	tmp_dir := os.join_path(os.temp_dir(), 'kimi-v-history-test')
	os.mkdir_all(tmp_dir) or { panic(err.msg()) }
	tmp_path := os.join_path(tmp_dir, 'history.${os.getpid()}')
	os.setenv('KIMI_HISTORY_FILE', tmp_path, true)
	defer {
		// Restore env and remove the temp file.
		if old_env.len > 0 {
			os.setenv('KIMI_HISTORY_FILE', old_env, true)
		} else {
			os.unsetenv('KIMI_HISTORY_FILE')
		}
		os.rm(tmp_path) or {}
	}
	fn_body(tmp_path)
}

fn test_load_history_returns_empty_when_file_missing() {
	with_temp_history(fn (path string) {
		// File shouldn't exist yet.
		assert !os.exists(path)
		got := load_history()
		assert got.len == 0, 'expected empty, got ${got.len} entries'
	})
}

fn test_save_and_load_roundtrip() {
	with_temp_history(fn (path string) {
		original := ['hello world', 'second prompt', 'third one']
		save_history(original) or { panic('save failed: ${err.msg()}') }
		assert os.exists(path), 'file should exist after save'
		got := load_history()
		assert got == original, 'roundtrip mismatch:\n  saved: ${original}\n   read: ${got}'
	})
}

fn test_save_dedups_keeping_most_recent() {
	with_temp_history(fn (_ string) {
		// 'a' is typed 3 times, 'b' twice, 'c' once. After dedup
		// (keeping the most recent), order should be: a, b, c.
		original := ['a', 'b', 'a', 'c', 'b', 'a']
		save_history(original) or { panic('save failed: ${err.msg()}') }
		got := load_history()
		// Most-recent occurrence: a (idx 5), b (idx 4), c (idx 3).
		// Walking newest-to-oldest yields [a, b, c] in that order,
		// which load returns reversed to chronological: [c, b, a].
		assert got == ['c', 'b', 'a'], 'dedup order wrong: got ${got}'
	})
}

fn test_save_drops_empty_entries() {
	with_temp_history(fn (_ string) {
		original := ['', 'real prompt', '', 'another', '']
		save_history(original) or { panic('save failed: ${err.msg()}') }
		got := load_history()
		assert got == ['real prompt', 'another'], 'empty entries should be dropped: got ${got}'
	})
}

fn test_save_preserves_embedded_newlines() {
	with_temp_history(fn (_ string) {
		// Multi-line prompts (from Shift+Enter input) must round-trip
		// cleanly. The RS separator (0x1E) keeps them distinct.
		original := ['line 1\nline 2\nline 3', 'single line', 'multi\nline\ntoo']
		save_history(original) or { panic('save failed: ${err.msg()}') }
		got := load_history()
		assert got == original, 'multi-line roundtrip failed:\n  saved: ${original}\n   read: ${got}'
	})
}

fn test_save_caps_to_max_entries() {
	with_temp_history(fn (_ string) {
		// Build a history of 600 unique prompts; expect the saved
		// file to be capped at history_max_entries (500), keeping
		// the most recent 500.
		mut hist := []string{}
		for i in 0 .. 600 {
			hist << 'prompt-${i}'
		}
		save_history(hist) or { panic('save failed: ${err.msg()}') }
		got := load_history()
		assert got.len == 500, 'expected cap to 500, got ${got.len}'
		// Oldest kept should be 'prompt-100' (since 0..99 are dropped);
		// newest kept should be 'prompt-599'.
		assert got[0] == 'prompt-100', 'oldest kept wrong: ${got[0]}'
		assert got[got.len - 1] == 'prompt-599', 'newest kept wrong: ${got[got.len - 1]}'
	})
}
