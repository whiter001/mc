module main

// Pulls in vlib/term's Windows console declarations (C.HANDLE,
// C.CONSOLE_SCREEN_BUFFER_INFO, C.SMALL_RECT, C.COORD,
// C.GetConsoleScreenBufferInfo) via `import os` transitively. The
// import is unused as a module but its C declarations land in the
// `C.` namespace; the `_` alias silences the unused-import warning.
import term as _

// sys_windows.v — Windows platform layer.
//
// State and behavior here cover W2 (console modes), W3 (input via
// WaitForSingleObject + ReadConsoleW / ReadFile, plan A), W4 (output via
// WriteConsoleW / WriteFile), W5 (window size via GetConsoleScreenBufferInfo),
// W6 (file_id via CreateFileW + GetFileInformationByHandle).
// Plan and references in WINDOWS_PORT.md §3–§7, progress in TODO.md W1–W6.
//
// Platform notes (see AGENTS.md "Windows 原生构建" for the full story):
// * conhost's VT input (ENABLE_VIRTUAL_TERMINAL_INPUT) is complete on
//   Windows Terminal and Windows 11's conhost; older Win10 conhost has gaps
//   for some Ctrl/Alt combos and SGR mouse — recommend Windows Terminal.
// * Ctrl+C in a console opens the default Ctrl+C handler (process kill) when
//   ENABLE_PROCESSED_INPUT is set; we clear it in switch_modes so the editor
//   sees Ctrl+C as a regular key. Ctrl+Z likewise is processed by conhost.
// * AltGr (Right-Alt) on European keyboards produces Ctrl+Alt; our input.v
//   parser handles the kbmod_ctrl_alt bit and routes it through.

#include <windows.h>

fn C.GetStdHandle(n_std_handle u32) voidptr
fn C.GetConsoleMode(h_console_handle voidptr, lp_mode &u32) int
fn C.SetConsoleMode(h_console_handle voidptr, dw_mode u32) int
fn C.SetConsoleOutputCP(w_code_page_id u32) int
fn C.GetConsoleOutputCP() u32
fn C.WaitForSingleObject(h_handle voidptr, dw_milliseconds u32) u32
fn C.ReadConsoleW(h_console_input voidptr, lp_buffer &u16, n_number_of_chars_to_read u32,
	lp_number_of_chars_read &u32, lp_input_control voidptr) int
fn C.ReadFile(h_file voidptr, lp_buffer voidptr, n_number_of_bytes_to_read u32,
	lp_number_of_bytes_read &u32, lp_overlapped voidptr) int
fn C.WriteFile(h_file voidptr, lp_buffer voidptr, n_number_of_bytes_to_write u32,
	lp_number_of_bytes_written &u32, lp_overlapped voidptr) int
fn C.WriteConsoleW(h_console_output voidptr, lp_buffer &u16, n_number_of_chars_to_write u32,
	lp_number_of_chars_written &u32, lp_reserved voidptr) int
fn C.MultiByteToWideChar(code_page u32, dw_flags u32, lp_multi_byte_str &char,
	cb_multi_byte int, lp_wide_char_str &u16, cch_wide_char int) int
fn C.WideCharToMultiByte(code_page u32, dw_flags u32, lp_wide_char_str &u16,
	cch_wide_char int, lp_multi_byte_str &u8, cb_multi_byte int,
	lp_default_char &u8, lp_used_default_char &u32) int
fn C.GetLastError() u32
// C.GetConsoleScreenBufferInfo, C.HANDLE, C.CONSOLE_SCREEN_BUFFER_INFO,
// C.COORD, C.SMALL_RECT come from vlib/term/term_windows.c.v (pulled in via
// `import os` in main.v).
fn C.CreateFileW(lp_file_name &u16, dw_desired_access u32, dw_share_mode u32,
	lp_security_attributes voidptr, dw_creation_disposition u32,
	dw_flags_and_attributes u32, h_template_file voidptr) voidptr
fn C.CloseHandle(h_object voidptr) int
fn C.GetFileInformationByHandle(h_file voidptr,
	lp_file_information &C.BY_HANDLE_FILE_INFORMATION) int

// BY_HANDLE_FILE_INFORMATION layout (winbase.h). Fields we need:
// dwVolumeSerialNumber → st_dev, nFileIndexHigh/Low → st_ino.
// Unused fields are declared (in the right order/size, CamelCase names
// to match the C struct) so the struct stays ABI-compatible. FILETIME
// is inlined as two DWORDs to avoid a vlib C.FILETIME dependency.
@[typedef]
struct C.BY_HANDLE_FILE_INFORMATION {
mut:
	dwFileAttributes           u32
	ftCreationTime_dwLow       u32
	ftCreationTime_dwHigh      u32
	ftLastAccessTime_dwLow     u32
	ftLastAccessTime_dwHigh    u32
	ftLastWriteTime_dwLow      u32
	ftLastWriteTime_dwHigh     u32
	dwVolumeSerialNumber       u32
	nFileSizeHigh              u32
	nFileSizeLow               u32
	dwNumberOfLinks            u32
	nFileIndexHigh             u32
	nFileIndexLow              u32
}

// CreateFileW constants (winbase.h).
const k_generic_read    = u32(0x80000000)
const k_file_share_read = u32(0x00000001)
const k_open_existing   = u32(3)
const k_invalid_handle_value = voidptr(u64(0xFFFFFFFFFFFFFFFF))

// Win32 console constants. Prefixed `k_` to dodge vlib macro/identifier
// clashes (windows.h defines macros that look like plain identifiers —
// min/max etc.). See WINDOWS_PORT.md §4.2 / §11.

// GetStdHandle targets.
const k_std_input_handle  = u32(0xFFFFFFF6) // (DWORD)-10
const k_std_output_handle = u32(0xFFFFFFF5) // (DWORD)-11

// Input mode flags (wincon.h ENABLE_*).
const k_enable_processed_input         = u32(0x0001)
const k_enable_line_input              = u32(0x0002)
const k_enable_echo_input              = u32(0x0004)
const k_enable_window_input            = u32(0x0008)
const k_enable_mouse_input             = u32(0x0010)
const k_enable_insert_mode             = u32(0x0020)
const k_enable_quick_edit_mode         = u32(0x0040)
const k_enable_extended_flags          = u32(0x0080)
const k_enable_auto_position           = u32(0x0100)
const k_enable_virtual_terminal_input  = u32(0x0200)

// Output mode flags (wincon.h ENABLE_* / DISABLE_*).
const k_enable_processed_output            = u32(0x0001)
const k_enable_wrap_at_eol_output          = u32(0x0002)
const k_enable_virtual_terminal_processing = u32(0x0004)
const k_disable_newline_auto_return        = u32(0x0008)

// Code page.
const k_cp_utf8 = u32(65001)

// WaitForSingleObject return codes (winnt.h / winbase.h).
const k_wait_object_0  = u32(0x00000000)
const k_wait_timeout   = u32(0x00000102)
const k_wait_failed    = u32(0xFFFFFFFF)
const k_infinite       = u32(0xFFFFFFFF)

// Read errors (winerror.h). Treated as EOF for our purposes.
const k_error_handle_eof      = u32(38)
const k_error_broken_pipe     = u32(109)
const k_error_operation_aborted = u32(995)

// WinSysState holds Windows-specific state. Fields are populated by W2–W6;
// keeping them here means shared sys.v never needs a single Win32 typedef.
struct WinSysState {
mut:
	stdin_handle    voidptr
	stdout_handle   voidptr
	initial_in_mode u32
	initial_out_mode u32
	initial_output_cp u32
	has_initial     bool
	is_console      bool
}

__global (
	g_win_sys WinSysState
)

// sys_init initializes the Windows state: grab stdin/stdout handles and
// decide whether they back a real console (matters for W4's write_stdout
// branching). Safe to call before any other sys_* function.
pub fn sys_init() {
	g_win_sys.stdin_handle = C.GetStdHandle(k_std_input_handle)
	g_win_sys.stdout_handle = C.GetStdHandle(k_std_output_handle)

	mut mode := u32(0)
	g_win_sys.is_console = C.GetConsoleMode(g_win_sys.stdin_handle, voidptr(&mode)) != 0
}

// stdin_is_redirected reports whether stdin is not attached to a console.
// Probe the handle via GetConsoleMode: it returns 0 when stdin is a pipe
// or file. Mirrors the unix `isatty(stdin_fd) == 0` check.
pub fn stdin_is_redirected() bool {
	if g_win_sys.stdin_handle == voidptr(0) {
		return true
	}
	mut mode := u32(0)
	return C.GetConsoleMode(g_win_sys.stdin_handle, voidptr(&mode)) == 0
}

// read_all_stdin drains redirected stdin into a UTF-8 string. W3 replaces
// this with a ReadFile loop; the W1/W2 stub returns an empty string so the
// main loop's error handling stays exercised.
pub fn read_all_stdin() !string {
	g_sys.stdin_eof = true
	return ''
}

// reopen_stdin_if_redirected has no /dev/tty equivalent on Windows; piped
// input has already been drained by read_all_stdin(). Always returns false.
// (main.v:249 will be reworded in W7 to drop the /dev/tty mention.)
pub fn reopen_stdin_if_redirected() !bool {
	return false
}

// switch_modes enters raw mode on the console.
//
// On the input side: enable VT input, mouse, and window-resize events; clear
// line buffering, echo, processed-input (Ctrl+C = SIGINT etc.), and Quick
// Edit (without this, mouse drags fall into conhost's text selection and
// break the editor's mouse handling). On the output side: enable VT
// processing (ANSI) and disable the \n→\r\n auto-conversion so the frame
// renderer stays in charge. Also switch the output code page to UTF-8 so
// V's own println / eprintln don't mojibake.
//
// Saves the current in/out modes and output cp so restore_terminal can put
// the console back. If stdin is not a console (piped input), this is a
// no-op success — there's nothing to switch.
pub fn switch_modes() ! {
	if !g_win_sys.is_console {
		return
	}

	mut in_mode := u32(0)
	if C.GetConsoleMode(g_win_sys.stdin_handle, voidptr(&in_mode)) == 0 {
		return error('GetConsoleMode(stdin) failed')
	}
	g_win_sys.initial_in_mode = in_mode

	mut out_mode := u32(0)
	if C.GetConsoleMode(g_win_sys.stdout_handle, voidptr(&out_mode)) == 0 {
		return error('GetConsoleMode(stdout) failed')
	}
	g_win_sys.initial_out_mode = out_mode

	g_win_sys.initial_output_cp = C.GetConsoleOutputCP()
	g_win_sys.has_initial = true

	// Input: clear canonical/echo/processed/quick-edit; set VT, mouse,
	// window-resize, and ENABLE_EXTENDED_FLAGS (required to toggle
	// QUICK_EDIT_MODE per Microsoft docs).
	clear_in := u32(k_enable_line_input) | u32(k_enable_echo_input)
		| u32(k_enable_processed_input) | u32(k_enable_quick_edit_mode)
	set_in := u32(k_enable_virtual_terminal_input) | u32(k_enable_mouse_input)
		| u32(k_enable_window_input) | u32(k_enable_extended_flags)
	new_in := (in_mode & ~clear_in) | set_in
	if C.SetConsoleMode(g_win_sys.stdin_handle, new_in) == 0 {
		return error('SetConsoleMode(stdin) failed')
	}

	// Output: enable VT processing, disable \n→\r\n auto-append.
	set_out := u32(k_enable_virtual_terminal_processing)
		| u32(k_disable_newline_auto_return)
	new_out := out_mode | set_out
	if C.SetConsoleMode(g_win_sys.stdout_handle, new_out) == 0 {
		return error('SetConsoleMode(stdout) failed')
	}

	C.SetConsoleOutputCP(k_cp_utf8)
}

// restore_terminal restores the modes and code page saved by switch_modes().
// V has no destructors; main.v invokes this on every exit path.
// Idempotent: safe to call when no modes were saved (returns silently).
pub fn restore_terminal() {
	if !g_win_sys.has_initial {
		return
	}
	C.SetConsoleMode(g_win_sys.stdin_handle, g_win_sys.initial_in_mode)
	C.SetConsoleMode(g_win_sys.stdout_handle, g_win_sys.initial_out_mode)
	C.SetConsoleOutputCP(g_win_sys.initial_output_cp)
	g_win_sys.has_initial = false
}

// read_stdin reads from stdin with a vt-style timeout
// (-1 = block, 0 = non-blocking, >0 = ms).
//
// Plan A (VT passthrough): with ENABLE_VIRTUAL_TERMINAL_INPUT set in
// switch_modes(), conhost turns keystrokes and mouse events into VT/CSI
// sequences and pushes them into the console input buffer. ReadConsoleW
// reads those as UTF-16; we transcode to UTF-8 and feed the existing
// input.v VT parser. Window-resize events arrive pre-encoded as
// `ESC [ 8 ; h ; w t`, so no manual SIGWINCH injection is needed (g_sys.inject_resize
// from main.v:260 is consumed below).
//
// Plan B (ReadConsoleInputW) is held in reserve for any Plan-A gap the
// smoke test reveals (W9); see WINDOWS_PORT.md §5.3.
pub fn read_stdin(timeout_ms int) ?string {
	if g_win_sys.stdin_handle == voidptr(0) {
		return none
	}

	// Plan A: conhost emits the size sequence itself on resize events
	// (with ENABLE_WINDOW_INPUT). inject_resize from main.v:260 is handled
	// at the end of this function as a safety net.

	// Wait up to timeout_ms (or INFINITE). timeout_ms == 0 → probe only.
	win_timeout := if timeout_ms == vt_no_timeout {
		k_infinite
	} else {
		u32(timeout_ms)
	}
	wait_ret := C.WaitForSingleObject(g_win_sys.stdin_handle, win_timeout)
	if wait_ret == k_wait_timeout {
		return ''
	}
	if wait_ret != k_wait_object_0 {
		return none
	}

	// Restore any incomplete UTF-8 tail from the previous read.
	mut buf := []u8{cap: 4 * kibi}
	if g_sys.utf8_len != 0 {
		buf << g_sys.utf8_buf[..g_sys.utf8_len]
		g_sys.utf8_len = 0
	}

	// Null pointers for WideCharToMultiByte's optional out params.
	null_u8 := unsafe { &u8(nil) }
	null_u32 := unsafe { &u32(nil) }
	if g_win_sys.is_console {
		// ReadConsoleW returns UTF-16 (the wide console API).
		mut wide_buf := [2048]u16{}
		mut n_read := u32(0)
		rc := C.ReadConsoleW(g_win_sys.stdin_handle, &wide_buf[0], u32(wide_buf.len),
			voidptr(&n_read), voidptr(0))
		if rc == 0 || n_read == 0 {
			g_sys.stdin_eof = true
			return none
		}
		// First call: ask how many UTF-8 bytes we need.
		needed := C.WideCharToMultiByte(k_cp_utf8, 0, &wide_buf[0], int(n_read),
			null_u8, 0, null_u8, null_u32)
		if needed <= 0 {
			return none
		}
		mut utf8_bytes := []u8{len: int(needed)}
		utf8_ptr := unsafe { &utf8_bytes[0] }
		written := C.WideCharToMultiByte(k_cp_utf8, 0, &wide_buf[0], int(n_read),
			utf8_ptr, int(needed), null_u8, null_u32)
		if written <= 0 {
			return none
		}
		buf << utf8_bytes
	} else {
		// Redirected stdin (pipe / file) → raw UTF-8 bytes via ReadFile.
		mut tmp := [4096]u8{}
		mut n_read := u32(0)
		rc := C.ReadFile(g_win_sys.stdin_handle, &tmp[0], u32(tmp.len),
			voidptr(&n_read), voidptr(0))
		if rc == 0 || n_read == 0 {
			g_sys.stdin_eof = true
			return none
		}
		buf << tmp[..int(n_read)]
	}

	// Cache an incomplete trailing UTF-8 sequence for the next read.
	if buf.len > 0 {
		tail := incomplete_utf8_tail_len(buf)
		if tail > 0 {
			g_sys.utf8_len = tail
			unsafe { C.memcpy(&g_sys.utf8_buf[0], &buf[buf.len - tail], usize(tail)) }
			buf = unsafe { buf[..buf.len - tail] }
		}
	}

	mut result := utf8_lossy(buf)

	// Safety-net injection: if main.v:260 set inject_window_size_into_stdin()
	// before the first read, prepend a size report so the input parser sees
	// a usable window size even on terminals that don't emit one.
	if g_sys.inject_resize {
		g_sys.inject_resize = false
		w, h := get_window_size()
		if w > 0 && h > 0 {
			result = '\x1b[8;${h};${w}t' + result
		}
	}

	return result
}

// get_window_size returns the current console size as (cols, rows).
// Uses GetConsoleScreenBufferInfo's srWindow (the visible window, not the
// scroll-back buffer). Falls back to 80x24 when the handle is not a
// console or the call fails. Mirrors the unix TIOCGWINSZ path.
fn get_window_size() (u16, u16) {
	if !g_win_sys.is_console || g_win_sys.stdout_handle == voidptr(0) {
		return 80, 24
	}
	mut info := C.CONSOLE_SCREEN_BUFFER_INFO{}
	if !C.GetConsoleScreenBufferInfo(C.HANDLE(g_win_sys.stdout_handle), &info) {
		return 80, 24
	}
	cols := info.srWindow.Right - info.srWindow.Left + 1
	rows := info.srWindow.Bottom - info.srWindow.Top + 1
	if cols == 0 || rows == 0 {
		return 80, 24
	}
	return cols, rows
}

// write_stdout writes raw UTF-8 bytes (incl. VT sequences).
//
// Console output goes UTF-8 → UTF-16 (MultiByteToWideChar) → WriteConsoleW
// so the active output code page (CP_ACP, CP936, ...) is irrelevant for our
// frame rendering. Redirected output (pipe, file) writes the raw UTF-8 bytes
// via WriteFile. Both paths chunk the call (WriteConsoleW caps at once, and
// pipe writes can short-write) and silently bail on ERROR_BROKEN_PIPE — the
// downstream end has gone away and there's nothing useful to do.
pub fn write_stdout(text string) {
	if text.len == 0 {
		return
	}
	if g_win_sys.is_console && g_win_sys.stdout_handle != voidptr(0) {
		// UTF-8 → UTF-16. Probe size first.
		null_u16 := unsafe { &u16(nil) }
		needed := C.MultiByteToWideChar(k_cp_utf8, 0, &char(text.str), text.len,
			null_u16, 0)
		if needed <= 0 {
			return
		}
		mut wide_buf := []u16{len: int(needed)}
		wide_ptr := unsafe { &wide_buf[0] }
		written := C.MultiByteToWideChar(k_cp_utf8, 0, &char(text.str), text.len,
			wide_ptr, int(needed))
		if written <= 0 {
			return
		}
		mut n_written := u32(0)
		C.WriteConsoleW(g_win_sys.stdout_handle, wide_ptr, u32(written), voidptr(&n_written),
			voidptr(0))
		return
	}
	// Redirected: WriteFile raw UTF-8 bytes in a chunk loop.
	mut written := 0
	for written < text.len {
		chunk := text[written..]
		mut n_written := u32(0)
		ret := C.WriteFile(g_win_sys.stdout_handle, voidptr(chunk.str), u32(chunk.len),
			voidptr(&n_written), voidptr(0))
		if ret == 0 {
			// Pipe closed (e.g. `edit | head`) — nothing to do, return silently.
			return
		}
		if n_written == 0 {
			return
		}
		written += int(n_written)
	}
}

// file_id returns a unique identifier for the file at path.
//
// Identity = (VolumeSerialNumber, FileIndex). VolumeSerialNumber + FileIndex
// together uniquely identify a file on a given volume across hardlinks —
// equivalent to (st_dev, st_ino) semantics on unix, so the same test suite
// (sys_test.v) works on both platforms without changes.
//
// Implementation: CreateFileW (UTF-16 path), GetFileInformationByHandle for
// the BY_HANDLE_FILE_INFORMATION record. Both calls can fail with
// ERROR_FILE_NOT_FOUND / ERROR_ACCESS_DENIED; we propagate via `!`.
pub fn file_id(path string) !FileId {
	// UTF-8 path → UTF-16, null-terminated.
	null_u16 := unsafe { &u16(nil) }
	needed := C.MultiByteToWideChar(k_cp_utf8, 0, &char(path.str), path.len, null_u16, 0)
	if needed <= 0 {
		return error('file_id(${path}): MultiByteToWideChar probe failed')
	}
	mut wide_path := []u16{len: int(needed) + 1}
	wide_path[int(needed)] = u16(0)
	wide_ptr := unsafe { &wide_path[0] }
	converted := C.MultiByteToWideChar(k_cp_utf8, 0, &char(path.str), path.len, wide_ptr,
		int(needed))
	if converted <= 0 {
		return error('file_id(${path}): MultiByteToWideChar failed')
	}

	handle := C.CreateFileW(wide_ptr, k_generic_read, k_file_share_read, voidptr(0),
		k_open_existing, u32(0), voidptr(0))
	if handle == k_invalid_handle_value || handle == voidptr(0) {
		return error('file_id(${path}): CreateFileW failed')
	}
	defer { C.CloseHandle(handle) }

	mut info := C.BY_HANDLE_FILE_INFORMATION{}
	if C.GetFileInformationByHandle(handle, &info) == 0 {
		return error('file_id(${path}): GetFileInformationByHandle failed')
	}

	// Combine the two DWORD halves of nFileIndex into the 64-bit identity.
	hi := u64(info.nFileIndexHigh)
	lo := u64(info.nFileIndexLow)
	file_index := (hi << 32) | lo
	return FileId{
		st_dev: u64(info.dwVolumeSerialNumber)
		st_ino: file_index
	}
}
