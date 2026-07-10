// tui.v — terminal control primitives.
//
// We deliberately do NOT use ncurses or any heavyweight TUI library. The
// surface area we need is small enough that raw mode + ANSI escapes are
// simpler and produce a smaller binary.
//
// What lives here:
//   - Alternate screen buffer entry/exit (so the user's terminal is
//     preserved when the TUI exits)
//   - Raw mode + restore (turn off echo + line buffering)
//   - ANSI escape helpers (cursor, color, clear)
//   - Terminal size query (so the layout adapts)
//
// What lives elsewhere:
//   - tui_render.v: content rendering (text / code blocks / tool calls)
//   - tui_input.v: keyboard input handling
//   - main.v: orchestration (spawns the agent goroutine + render loop)

module main

import os

// ---------- ANSI helpers --------------------------------------------------

pub const esc          = '\x1b'
pub const esc_reset    = '\x1b[0m'
pub const esc_bold     = '\x1b[1m'
pub const esc_dim      = '\x1b[2m'
pub const esc_red      = '\x1b[31m'
pub const esc_green    = '\x1b[32m'
pub const esc_yellow   = '\x1b[33m'
pub const esc_blue     = '\x1b[34m'
pub const esc_magenta  = '\x1b[35m'
pub const esc_cyan     = '\x1b[36m'
pub const esc_gray     = '\x1b[90m'
pub const esc_bg_blue  = '\x1b[44m'
pub const esc_bg_gray  = '\x1b[100m'

// move_cursor moves the cursor to (row, col), 1-based.
fn move_cursor(row int, col int) string {
	return '${esc}[${row};${col}H'
}

// clear_screen wipes the visible screen.
fn clear_screen() string {
	return '${esc}[2J${esc}[H'
}

// clear_line erases from cursor to end of the current line.
fn clear_line() string {
	return '${esc}[K'
}

// alt_screen_on switches to the alternate screen buffer.
fn alt_screen_on() string {
	return '${esc}[?1049h'
}

// alt_screen_off switches back to the primary screen buffer.
fn alt_screen_off() string {
	return '${esc}[?1049l'
}

// cursor_hide / cursor_show toggle cursor visibility.
fn cursor_hide() string {
	return '${esc}[?25l'
}

fn cursor_show() string {
	return '${esc}[?25h'
}

// cursor_to puts the cursor at absolute (row, col), 1-based.
fn cursor_to(row int, col int) string {
	return '${esc}[${row};${col}H'
}

// ---------- Terminal size -------------------------------------------------

// term_size queries the terminal size via `stty size` (POSIX) or the
// `COLUMNS` / `LINES` env vars (commonly set by shells).
//
// We can't easily use ioctl(TIOCGWINSZ) from V without C bindings; stty is
// universally available on macOS and Linux. On Windows we'd fall back to
// env vars.
fn term_size() (int, int) {
	out := os.execute('stty size 2>/dev/null')
	if out.exit_code == 0 {
		parts := out.output.split(' ')
		if parts.len >= 2 {
			rows := parts[0].trim_space().int()
			cols := parts[1].trim_space().int()
			if rows > 0 && cols > 0 {
				return rows, cols
			}
		}
	}
	// Fallback: env vars.
	mut cols := 80
	mut rows := 24
	cols_str := os.getenv('COLUMNS')
	rows_str := os.getenv('LINES')
	if cols_str.len > 0 { cols = cols_str.int() }
	if rows_str.len > 0 { rows = rows_str.int() }
	if cols <= 0 { cols = 80 }
	if rows <= 0 { rows = 24 }
	return rows, cols
}

// ---------- Raw mode ------------------------------------------------------

// enter_raw_mode disables echo and line buffering on stdin so we get one
// byte at a time (needed for hot-keys, multi-line editing, etc.).
//
// We do this with `stty raw -echo` which is portable on macOS and Linux.
// On Windows, the same flag set is exposed via different commands; we
// detect platform via $if windows.
//
// Returns true on success, false if the TTY isn't interactive (e.g.
// piped input).
pub fn enter_raw_mode() bool {
	if os.is_atty(0) == 0 {
		return false
	}
	res := os.execute('stty raw -echo 2>/dev/null')
	return res.exit_code == 0
}

// leave_raw_mode restores the terminal to cooked mode. ALWAYS call this on
// exit, even on error paths.
pub fn leave_raw_mode() {
	os.execute('stty sane 2>/dev/null')
}

// ---------- Write helpers -------------------------------------------------

// write_stdout writes bytes directly to stdout bypassing any V buffering.
// Important for TUI: every frame must be flushed before the next frame
// starts, otherwise the user sees tearing.
fn write_stdout(s string) {
	mut out := os.stdout()
	out.write_string(s) or {}
	out.flush()
}

// ---------- TUI lifecycle -------------------------------------------------

// TuiState is the shared mutable state the render loop reads and the
// input loop writes.
pub struct TuiState {
pub mut:
	// Conversation: a list of message "blocks" for display.
	// Each block is a self-contained chunk (user text, assistant text
	// being streamed, tool call + result, etc.).
	blocks      []Block
	// Currently-streaming assistant text for the latest block (so we can
	// re-render mid-stream without committing to a final block).
	streaming   string
	// Stream has finished for the current block (allows render loop to
	// promote `streaming` into a permanent block).
	streaming_done bool
	// Last status line content (e.g. "thinking...", "running read_file", ...).
	status      string
	// Token tally for the session.
	input_tokens  int
	output_tokens int
	// Cached terminal size (refreshed each frame).
	rows int
	cols int
	// Whether the user requested exit.
	should_exit bool
	// Whether the user requested interrupt of the current turn.
	should_interrupt bool
}

// Block kinds for the conversation display.
pub enum BlockKind {
	user
	assistant
	tool_call
	tool_result
	system
}

pub struct Block {
pub:
	kind BlockKind
	// For assistant / user / system: the message text.
	text string
	// For tool_call: name + args (pretty-printed JSON).
	tool_name string
	tool_args string
	// For tool_result: the result content.
	tool_result string
	// For tool_result: was it an error?
	tool_is_error bool
}

pub fn new_tui_state() TuiState {
	rows, cols := term_size()
	return TuiState{
		blocks: []Block{}
		rows: rows
		cols: cols
	}
}

// enter_tui switches to alt screen + raw mode + hidden cursor. Returns
// true on success. On failure (non-TTY), returns false so the caller can
// fall back to plain stdout.
pub fn enter_tui() bool {
	if !enter_raw_mode() {
		return false
	}
	write_stdout(alt_screen_on())
	write_stdout(cursor_hide())
	clear()
	// Initial size sync.
	rows, _ := term_size()
	_ = rows
	return true
}

// leave_tui restores the terminal. Always call this when leaving TUI mode.
pub fn leave_tui() {
	write_stdout(cursor_show())
	write_stdout(alt_screen_off())
	leave_raw_mode()
}

fn clear() string {
	return clear_screen()
}

// refresh_size re-queries the terminal size (call this from the render
// loop to handle SIGWINCH-equivalent resize).
pub fn (mut s TuiState) refresh_size() {
	s.rows, s.cols = term_size()
}