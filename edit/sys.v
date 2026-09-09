module main

// sys.v — shared platform-abstraction layer.
//
// Types and helpers usable on every platform live here. Per-platform
// implementations live in sys_nix.v (unix) or sys_windows.v (windows);
// V picks one by filename suffix (vlib/v/pref/should_compile.v:266-270).
// See WINDOWS_PORT.md §3 for the file split rationale.

// SysState holds state shared across platforms (EOF flag, UTF-8 tail cache,
// resize-injection flag). Platform-specific state lives in NixSysState
// (sys_nix.v) and WinSysState (sys_windows.v).
struct SysState {
mut:
	inject_resize bool
	stdin_eof     bool
	// Buffer for incomplete UTF-8 sequences across reads (max 3 bytes
	// pending: a 4-byte sequence splits at most into 1+3).
	utf8_buf [4]u8
	utf8_len int
}

__global (
	g_sys SysState
)

// FileId uniquely identifies a file. The (st_dev, st_ino) pair is the
// canonical POSIX identity; on Windows file_id() substitutes
// (volume_serial, file_index) to preserve the same uniqueness semantics.
// See sys_nix.v / sys_windows.v.
pub struct FileId {
	st_dev u64
	st_ino u64
}

pub fn (a FileId) == (b FileId) bool {
	return a.st_dev == b.st_dev && a.st_ino == b.st_ino
}

// inject_window_size_into_stdin makes the next read_stdin() prepend a fake
// window size report sequence, as if the terminal had answered a query.
// Pure flag flip; same behavior on both platforms.
pub fn inject_window_size_into_stdin() {
	g_sys.inject_resize = true
}

// stdin_hit_eof reports whether the last read_stdin() hit end-of-file.
pub fn stdin_hit_eof() bool {
	return g_sys.stdin_eof
}

// incomplete_utf8_tail_len finds the length of the trailing, potentially
// incomplete UTF-8 sequence at the end of buf. Returns 0 if the buffer ends
// on a complete boundary (or the lead byte found isn't actually one, in which
// case utf8_lossy will replace it with U+FFFD).
// Factored out of read_stdin() for testability; called from both platforms.
fn incomplete_utf8_tail_len(buf []u8) int {
	if buf.len == 0 {
		return 0
	}
	// We only need to check the last 3 bytes for UTF-8 continuation bytes,
	// because we can assume that any 4 byte sequence is complete.
	lim := if buf.len >= 3 { buf.len - 3 } else { 0 }
	mut off := buf.len - 1

	// Find the start of the last potentially incomplete UTF-8 sequence.
	for off > lim && buf[off] & 0b1100_0000 == 0b1000_0000 {
		off--
	}

	b := buf[off]
	mut seq_len := 0
	if b & 0b1000_0000 == 0 {
		seq_len = 1
	} else if b & 0b1110_0000 == 0b1100_0000 {
		seq_len = 2
	} else if b & 0b1111_0000 == 0b1110_0000 {
		seq_len = 3
	} else if b & 0b1111_1000 == 0b1111_0000 {
		seq_len = 4
	}
	// If the lead byte we found isn't actually one, we don't cache it
	// (seq_len stays 0); utf8_lossy will replace it with U+FFFD.

	if seq_len > 0 && off + seq_len > buf.len {
		return buf.len - off
	}
	return 0
}
