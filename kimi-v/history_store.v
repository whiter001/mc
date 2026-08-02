// history_store.v — persist the TUI input history across sessions.
//
// Format: each prompt is one chunk of UTF-8 text. Chunks are separated
// by the ASCII Record Separator (0x1E) — chosen because it's a control
// character that never appears in real prompts, so embedded newlines
// (from multi-line input) round-trip cleanly without escaping.
//
// Save semantics: dedup (keep the most recent occurrence of each
// unique prompt) and cap at `history_max_entries` so the file doesn't
// grow unbounded. Load semantics: split on 0x1E, drop empty entries
// (trailing separator), preserve chronological order (oldest first,
// newest last — matches the order InputBuf.history expects).
//
// Path: `<config_dir>/history`, override via `KIMI_HISTORY_FILE` env.

module main

import os

// history_separator is the byte (0x1E = RS) that delimits prompts in
// the on-disk file. Never appears in user-typed text, so prompts can
// contain arbitrary newlines without escaping.
const history_separator = `\x1e`

// history_max_entries caps the saved history to keep the file small.
// The InputBuf itself has no cap; we trim at write time.
const history_max_entries = 500

// history_path returns the absolute path to the history file. Honors
// KIMI_HISTORY_FILE override; otherwise falls back to
// `<config_dir>/history`.
pub fn history_path() string {
	override := os.getenv('KIMI_HISTORY_FILE')
	if override.len > 0 {
		return override
	}
	return os.join_path(config_dir(), 'history')
}

// load_history reads the on-disk history file and returns the entries
// in chronological order (oldest first, newest last). Returns an empty
// slice if the file doesn't exist or can't be read — a missing history
// file is a normal first-run condition, not an error.
pub fn load_history() []string {
	path := history_path()
	if !os.exists(path) {
		return []string{}
	}
	data := os.read_file(path) or { return []string{} }
	if data.len == 0 {
		return []string{}
	}
	mut out := []string{}
	mut start := 0
	for i := 0; i < data.len; i++ {
		if data[i] == history_separator {
			// Drop empty segments (e.g. leading separator, or a run
			// of separators from a corrupt file).
			if i > start {
				out << data[start..i]
			}
			start = i + 1
		}
	}
	// Trailing segment after the last separator. May be empty if the
	// file ends with a separator (which `save_history` does not write,
	// but a hand-edited file might).
	if start < data.len {
		out << data[start..data.len]
	}
	return out
}

// save_history writes the given history to disk. Dedups (keeping the
// most recent occurrence of each unique prompt) and caps at
// `history_max_entries`. Returns an error if the write fails; the
// caller (TUI shutdown path) is expected to log and continue rather
// than crash, since a failed save is non-fatal.
pub fn save_history(history []string) ! {
	// Dedup: walk newest-to-oldest, keep the first occurrence of each
	// unique prompt. The result is in reverse-chronological order.
	mut seen := map[string]bool{}
	mut kept_rev := []string{}
	for i := history.len - 1; i >= 0; i-- {
		p := history[i]
		if p.len == 0 {
			continue
		}
		if p in seen {
			continue
		}
		seen[p] = true
		kept_rev << p
	}
	if kept_rev.len == 0 {
		return
	}
	// Cap to the most recent N entries.
	if kept_rev.len > history_max_entries {
		kept_rev = kept_rev[..history_max_entries].clone()
	}
	// Reverse to chronological order (oldest first, newest last) for
	// nicer on-disk format and to match the order load_history returns.
	mut kept := kept_rev.reverse()

	// Ensure the config directory exists before writing. We don't want
	// a fresh install to fail because ~/.config/kimi/ hasn't been
	// created yet.
	ensure_dir(config_dir()) or {
		return error('cannot create config dir ${config_dir()}: ${err.msg()}')
	}

	// Build the file bytes: prompts joined by RS. Append a trailing
	// RS so subsequent appends don't need to re-encode the prior
	// content (helps if we ever switch to O(1) appends).
	mut buf := []u8{}
	for i, p in kept {
		if i > 0 {
			buf << history_separator
		}
		buf << p.bytes()
	}
	os.write_file(history_path(), buf.bytestr())!
}
