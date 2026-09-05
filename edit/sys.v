module main

// Port of crates/edit/src/sys/unix.rs (microsoft/edit), macOS/Linux only.
//
// Unix platform layer: raw terminal mode, stdin reads with poll timeouts,
// window size queries and SIGWINCH injection, stdout writes, file identity.
//
// Differences from the Rust original:
// * ICU loading (load_icu, get_proc_address, renaming suffix) and
//   preferred_languages are out of scope for this rewrite (no ICU / i18n).
// * Rust's `Deinit` Drop guard becomes an explicit `restore_terminal()`;
//   the caller must invoke it on every exit path.
// * Arena/BString optimizations are dropped in favor of plain V strings.
// * C constants (IGNBRK, TIOCGWINSZ, ...) are passed through from the system
//   headers instead of being hardcoded per platform.

#include <termios.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <signal.h>

fn C.tcgetattr(fd int, termios &C.termios) int
fn C.tcsetattr(fd int, action int, termios &C.termios) int
fn C.fcntl(fd int, cmd int, flags int) int
fn C.poll(fds &C.pollfd, nfds u32, timeout int) int
fn C.ioctl(fd i32, request u64, args ...voidptr) i32
fn C.open(&char, i32, ...int) i32
fn C.fstat(fd int, buf voidptr) int

$if macos {
	fn C.__error() &int
} $else {
	fn C.__errno_location() &int
}

// struct termios layouts. The kernel writes the full struct via tcgetattr,
// so the declarations must match the platform ABI exactly.
$if macos {
	// darwin arm64: tcflag_t = unsigned long, speed_t = unsigned long, NCCS = 20
	struct C.termios {
	mut:
		c_iflag  u64
		c_oflag  u64
		c_cflag  u64
		c_lflag  u64
		c_cc     [20]u8
		c_ispeed u64
		c_ospeed u64
	}
} $else {
	// linux asm-generic (aarch64): tcflag_t = unsigned int, NCCS = 19
	struct C.termios {
	mut:
		c_iflag  u32
		c_oflag  u32
		c_cflag  u32
		c_lflag  u32
		c_line   u8
		c_cc     [19]u8
		c_ispeed u32
		c_ospeed u32
	}
}

struct C.pollfd {
mut:
	fd      int
	events  i16
	revents i16
}

struct C.winsize {
mut:
	ws_row    u16
	ws_col    u16
	ws_xpixel u16
	ws_ypixel u16
}

// Only the leading fields we actually read are declared; the trailing
// padding keeps the buffer large enough for the kernel's full struct stat.
$if macos {
	// darwin arm64: dev_t = i32, then mode/nlink (u16 each), ino_t = u64
	struct C.stat {
		st_dev   i32
		st_mode  u16
		st_nlink u16
		st_ino   u64
		pad      [128]u8
	}
} $else {
	// linux aarch64: dev_t = u64, ino_t = u64
	struct C.stat {
		st_dev u64
		st_ino u64
		pad    [128]u8
	}
}

struct SysState {
mut:
	stdin_fd               int
	stdin_flags            int
	stdout_fd              int
	stdout_initial_termios C.termios
	has_initial_termios    bool
	inject_resize          bool
	stdin_eof              bool
	// Buffer for incomplete UTF-8 sequences (max 3 bytes can be pending:
	// a 4-byte sequence splits at most into 1+3).
	utf8_buf [4]u8
	utf8_len int
}

__global (
	g_sys SysState
)

// errno_value returns the current errno.
fn errno_value() int {
	unsafe {
		$if macos {
			return *C.__error()
		} $else {
			return *C.__errno_location()
		}
	}
}

// sys_init initializes the global state with the standard fds.
// Rust: sys::init() (which returns the Deinit guard).
pub fn sys_init() {
	g_sys.stdin_fd = C.STDIN_FILENO
	g_sys.stdout_fd = C.STDOUT_FILENO
}

// sigwinch_handler sets a flag so the next read_stdin() injects a window
// size report. Async-signal-safe: it only sets a flag, like the Rust version.
fn sigwinch_handler(_ int) {
	g_sys.inject_resize = true
}

// reopen_stdin_if_redirected reopens stdin via /dev/tty if it was redirected
// (= piped input). Returns true if stdin was reopened.
pub fn reopen_stdin_if_redirected() !bool {
	if C.isatty(g_sys.stdin_fd) == 0 {
		old_fd := g_sys.stdin_fd
		fd := C.open(c'/dev/tty', C.O_RDONLY)
		if fd < 0 {
			return error('open(/dev/tty) failed')
		}
		if old_fd != fd {
			C.close(old_fd)
		}
		g_sys.stdin_fd = fd
		g_sys.stdin_eof = false
		g_sys.utf8_len = 0
		return true
	}
	return false
}

// stdin_is_redirected reports whether stdin is not attached to a tty.
pub fn stdin_is_redirected() bool {
	return C.isatty(g_sys.stdin_fd) == 0
}

// read_all_stdin drains redirected stdin into a UTF-8 string.
pub fn read_all_stdin() !string {
	mut buf := []u8{cap: 64 * kibi}
	mut tmp := [64 * kibi]u8{}
	for {
		ret := C.read(g_sys.stdin_fd, &tmp[0], usize(tmp.len))
		if ret > 0 {
			buf << tmp[..int(ret)]
			continue
		}
		if ret == 0 {
			g_sys.stdin_eof = true
			break
		}
		if errno_value() == C.EINTR {
			continue
		}
		return error('read(stdin) failed')
	}
	return utf8_lossy(buf)
}

// switch_modes saves the current terminal modes and switches to raw mode.
// Call restore_terminal() on exit to undo this.
pub fn switch_modes() ! {
	// Store the stdin flags so we can more easily toggle O_NONBLOCK later on.
	g_sys.stdin_flags = C.fcntl(g_sys.stdin_fd, C.F_GETFL, 0)
	if g_sys.stdin_flags < 0 {
		return error('fcntl(F_GETFL) failed')
	}

	// Set inject_resize whenever we get a SIGWINCH.
	unsafe { C.signal(C.SIGWINCH, voidptr(sigwinch_handler)) }

	// Get the original terminal modes so we can disable raw mode on exit.
	if C.tcgetattr(g_sys.stdout_fd, &g_sys.stdout_initial_termios) < 0 {
		return error('tcgetattr failed')
	}
	g_sys.has_initial_termios = true

	mut termios := g_sys.stdout_initial_termios

	$if macos {
		// V 编译器在 import os 时对 `u64(C.A | C.B)` 的组合表达式有 bug，
		// 逐项单独转换再或运算可以绕开。
		iflag_mask := u64(C.IGNBRK) | u64(C.BRKINT) | u64(C.PARMRK) | u64(C.INPCK) | u64(C.ISTRIP) | u64(C.INLCR) | u64(C.IGNCR) | u64(C.ICRNL) | u64(C.IXON)
		oflag_mask := u64(C.OPOST)
		cflag_mask := u64(C.CSIZE) | u64(C.PARENB)
		lflag_mask := u64(C.ISIG) | u64(C.ICANON) | u64(C.ECHO) | u64(C.ECHONL) | u64(C.IEXTEN)
		cs8 := u64(C.CS8)

		termios.c_iflag &= ~iflag_mask
		// Disable output processing.
		termios.c_oflag &= ~oflag_mask
		// Reset character size mask; disable parity generation; set CS8.
		termios.c_cflag &= ~cflag_mask
		termios.c_cflag |= cs8
		// Disable signal generation, canonical mode, echo, echonl, extended input.
		termios.c_lflag &= ~lflag_mask
	} $else {
		iflag_mask := u32(C.IGNBRK) | u32(C.BRKINT) | u32(C.PARMRK) | u32(C.INPCK) | u32(C.ISTRIP) | u32(C.INLCR) | u32(C.IGNCR) | u32(C.ICRNL) | u32(C.IXON)
		oflag_mask := u32(C.OPOST)
		cflag_mask := u32(C.CSIZE) | u32(C.PARENB)
		lflag_mask := u32(C.ISIG) | u32(C.ICANON) | u32(C.ECHO) | u32(C.ECHONL) | u32(C.IEXTEN)
		cs8 := u32(C.CS8)

		termios.c_iflag &= ~iflag_mask
		termios.c_oflag &= ~oflag_mask
		termios.c_cflag &= ~cflag_mask
		termios.c_cflag |= cs8
		termios.c_lflag &= ~lflag_mask
	}

	if C.tcsetattr(g_sys.stdout_fd, C.TCSANOW, &termios) < 0 {
		return error('tcsetattr failed')
	}
}

// restore_terminal restores the terminal modes saved by switch_modes().
// Rust does this in the Drop impl of the Deinit guard; V has no destructors,
// so the caller must invoke this on every exit path (normal or error).
pub fn restore_terminal() {
	if g_sys.has_initial_termios {
		C.tcsetattr(g_sys.stdout_fd, C.TCSANOW, &g_sys.stdout_initial_termios)
		g_sys.has_initial_termios = false
	}
}

// inject_window_size_into_stdin makes the next read_stdin() prepend a fake
// window size report sequence, as if the terminal had answered a query.
pub fn inject_window_size_into_stdin() {
	g_sys.inject_resize = true
}

// tiocgwinsz is the TIOCGWINSZ ioctl request code. It is defined via a C
// macro expression (involving sizeof) that V cannot pass through, so we
// hardcode the stable ABI values per platform instead.
fn tiocgwinsz() u64 {
	$if macos {
		return u64(0x40087468)
	} $else {
		return u64(0x5413)
	}
}

// get_window_size queries the terminal size via TIOCGWINSZ, retrying up to
// 10 times (some terminals are bad emulators and don't report it immediately).
// Falls back to 80x24.
fn get_window_size() (u16, u16) {
	mut winsz := C.winsize{}

	for attempt in 1 .. 11 {
		ret := C.ioctl(g_sys.stdout_fd, tiocgwinsz(), &winsz)
		if ret == -1 || (winsz.ws_col != 0 && winsz.ws_row != 0) {
			break
		}
		if attempt == 10 {
			winsz.ws_col = 80
			winsz.ws_row = 24
			break
		}
		// 10ms * attempt, like the Rust version.
		C.usleep(u32(10_000 * attempt))
	}

	return winsz.ws_col, winsz.ws_row
}

// split_incomplete_utf8_tail finds the length of the trailing, potentially
// incomplete UTF-8 sequence at the end of buf. Returns 0 if the buffer ends
// on a complete boundary (or the lead byte found isn't actually one, in which
// case utf8_lossy will replace it with U+FFFD).
// Factored out of read_stdin() for testability.
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

// read_stdin reads from stdin.
//
// timeout_ms follows vt.v's convention: vt_no_timeout (-1) blocks
// indefinitely, 0 returns immediately, >0 waits up to that many ms.
//
// Returns none on error or EOF, '' if the timeout was reached,
// otherwise the read, non-empty string.
pub fn read_stdin(timeout_ms int) ?string {
	mut timeout := timeout_ms
	if g_sys.inject_resize {
		timeout = 0
	}

	read_poll := timeout != vt_no_timeout
	mut buf := []u8{cap: 4 * kibi}

	// We got some leftover broken UTF-8 from a previous read? Prepend it.
	if g_sys.utf8_len != 0 {
		buf << g_sys.utf8_buf[..g_sys.utf8_len]
		g_sys.utf8_len = 0
	}

	mut tmp := [4096]u8{}
	for {
		if timeout != vt_no_timeout {
			mut pollfd := C.pollfd{
				fd:      g_sys.stdin_fd
				events:  i16(C.POLLIN)
				revents: 0
			}
			ret := C.poll(&pollfd, 1, timeout)
			if ret < 0 {
				return none // Error? Let's assume it's an EOF.
			}
			if ret == 0 {
				break // Timeout? We can stop reading.
			}
		}

		// If we're asked for a non-blocking read we need
		// to manipulate O_NONBLOCK and vice versa.
		set_tty_nonblocking(read_poll)

		// Read from stdin.
		ret := C.read(g_sys.stdin_fd, &tmp[0], usize(tmp.len))
		if ret > 0 {
			buf << tmp[..int(ret)]
			break
		}
		if ret == 0 {
			g_sys.stdin_eof = true
			return none // EOF
		}
		// ret < 0
		err := errno_value()
		if err == C.EINTR && g_sys.inject_resize {
			break
		}
		if err == C.EAGAIN && timeout == 0 {
			break
		}
		if err == C.EINTR || err == C.EAGAIN {
			continue
		}
		return none
	}

	if buf.len > 0 {
		// Cache an incomplete trailing UTF-8 sequence for the next read.
		tail := incomplete_utf8_tail_len(buf)
		if tail > 0 {
			g_sys.utf8_len = tail
			unsafe { C.memcpy(&g_sys.utf8_buf[0], &buf[buf.len - tail], usize(tail)) }
			buf = unsafe { buf[..buf.len - tail] }
		}
	}

	mut result := utf8_lossy(buf)

	// We received a SIGWINCH? Add a fake window size sequence for our input
	// parser. Prepend it, so that on startup the TUI system gets initialized
	// with a size first.
	if g_sys.inject_resize {
		g_sys.inject_resize = false
		w, h := get_window_size()
		if w > 0 && h > 0 {
			result = '\x1b[8;${h};${w}t' + result
		}
	}

	return result
}

// stdin_hit_eof reports whether the last read_stdin() hit end-of-file.
pub fn stdin_hit_eof() bool {
	return g_sys.stdin_eof
}

// write_stdout writes the given text to stdout.
pub fn write_stdout(text string) {
	if text.len == 0 {
		return
	}

	// If we don't set the TTY to blocking mode,
	// the write will potentially fail with EAGAIN.
	set_tty_nonblocking(false)

	mut written := 0
	for written < text.len {
		chunk := text[written..]
		n := C.write(g_sys.stdout_fd, chunk.str, usize(chunk.len))
		if n >= 0 {
			written += int(n)
			continue
		}
		if errno_value() != C.EINTR {
			return
		}
	}
}

// set_tty_nonblocking sets/resets O_NONBLOCK on the TTY handle.
//
// Note that setting this flag applies to both stdin and stdout, because the
// TTY is a bidirectional device and both handles refer to the same thing.
fn set_tty_nonblocking(nonblock bool) {
	is_nonblock := (g_sys.stdin_flags & C.O_NONBLOCK) != 0
	if is_nonblock != nonblock {
		g_sys.stdin_flags ^= C.O_NONBLOCK
		C.fcntl(g_sys.stdin_fd, C.F_SETFL, g_sys.stdin_flags)
	}
}

// FileId uniquely identifies a file by device and inode.
pub struct FileId {
	st_dev u64
	st_ino u64
}

pub fn (a FileId) == (b FileId) bool {
	return a.st_dev == b.st_dev && a.st_ino == b.st_ino
}

// file_id returns a unique identifier for the file at the given path.
pub fn file_id(path string) !FileId {
	fd := C.open(&char(path.str), C.O_RDONLY)
	if fd < 0 {
		return error('open(${path}) failed')
	}
	defer { C.close(fd) }

	stat := C.stat{}
	if C.fstat(fd, &stat) < 0 {
		return error('fstat(${path}) failed')
	}
	return FileId{
		st_dev: u64(stat.st_dev)
		st_ino: stat.st_ino
	}
}
