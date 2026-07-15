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
import term

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

// clear_screen wipes the visible screen.
fn clear_screen() string {
	return '${esc}[2J${esc}[H'
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

// enable_bracketed_paste / disable_bracketed_paste wrap the terminal in
// bracketed-paste mode. While enabled, the terminal encloses pasted text
// (including multi-line text and binary data sent by the terminal emulator)
// with ESC[200~ ... ESC[201~, so the input layer can treat the whole chunk
// atomically instead of line-by-line.
fn enable_bracketed_paste() string {
	return '${esc}[?2004h'
}

fn disable_bracketed_paste() string {
	return '${esc}[?2004l'
}

// ---------- Terminal size -------------------------------------------------

// term_size queries the terminal size via V's standard library
// `term.get_terminal_size()` (which uses ioctl(TIOCGWINSZ)). This is more
// reliable than forking `stty size` and avoids shell/exec overhead.
//
// Falls back to env vars COLUMNS/LINES or 80x24 when stdout is not a TTY.
fn term_size() (int, int) {
	cols, rows := term.get_terminal_size()
	if cols > 0 && rows > 0 {
		return rows, cols
	}
	// Fallback: env vars.
	mut fcols := 80
	mut frows := 24
	cols_str := os.getenv('COLUMNS')
	rows_str := os.getenv('LINES')
	if cols_str.len > 0 { fcols = cols_str.int() }
	if rows_str.len > 0 { frows = rows_str.int() }
	if fcols <= 0 { fcols = 80 }
	if frows <= 0 { frows = 24 }
	return frows, fcols
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
	// Currently-streaming assistant text for the latest turn. Grows
	// chunk-by-chunk as the LLM emits tokens; promoted to a permanent
	// `.assistant` block when the turn finishes.
	streaming   string
	// Currently-streaming reasoning/thinking text (k1.5 / R1 style). Same
	// lifecycle as `streaming` but rendered separately (dim, 💭 prefix)
	// above the eventual answer.
	streaming_thinking string
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
	// Pending approval request. When set, the render loop draws a modal
	// overlay and the key loop routes y/n to the agent's decision
	// channel instead of the input buffer.
	pending_approval ?ApprovalRequest
	// Pending AskUserQuestion request. When set, the render loop draws a
	// question modal and the key loop routes digit keys to a choice.
	pending_ask ?AskRequest
	// Pending ExitPlanMode request. When set, the render loop draws a
	// plan-review modal and the key loop routes y/n/r to a decision.
	pending_exit_plan ?ExitPlanRequest
	// Names of MCP servers currently connected (populated by run_tui after
	// the agent is built). Used by /mcp to show live connection state.
	mcp_connected []string
	// Whether plan mode is currently active (drives the banner). Set by
	// the .plan_mode status handler and the exit-plan modal flow.
	plan_mode_active bool
	// dirty is set whenever the visible state changes (new block,
	// streaming chunk, input edit, resize, modal). The render loop only
	// repaints when dirty is true (or streaming is in progress), which
	// avoids re-clearing + re-drawing the whole screen ~30×/sec when
	// nothing changed. Reset to false after each successful render.
	dirty bool
}

// Block kinds for the conversation display.
pub enum BlockKind {
	user
	assistant
	thinking
	tool_call
	tool_result
	system
}

// Block is one rendered item in the conversation scrollback.
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
pub mut:
	// When true and kind == .tool_result, the render shows a single
	// folded summary line ("<tool>: N lines collapsed — Ctrl-O to
	// expand") instead of the full result body. Toggled by the Ctrl-O
	// hotkey in handle_key. Ignored for other block kinds.
	collapsed bool
}

// new_tui_state creates an initial TuiState with the current terminal size
// and an empty block list. The state starts dirty so the first frame is
// painted immediately.
pub fn new_tui_state() TuiState {
	rows, cols := term_size()
	return TuiState{
		blocks: []Block{}
		rows: rows
		cols: cols
		dirty: true
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
	write_stdout(clear_screen())
	// Enable bracketed paste so multi-line / image-path pastes arrive as a
	// single atomic chunk wrapped in ESC[200~ ... ESC[201~.
	write_stdout(enable_bracketed_paste())
	// Initial size sync.
	rows, _ := term_size()
	_ = rows
	return true
}

// leave_tui restores the terminal. Always call this when leaving TUI mode.
// Idempotent — safe to call from multiple paths because the underlying
// `leave_raw_mode()` and the ANSI escape sequences are no-ops on an
// already-restored terminal.
pub fn leave_tui() {
	write_stdout(disable_bracketed_paste())
	write_stdout(cursor_show())
	write_stdout(alt_screen_off())
	leave_raw_mode()
}

// request_shutdown pushes a single byte into a channel; the TUI main loop
// selects on it and exits cleanly. Use this from signal handlers instead
// of calling os.exit() directly (which would skip leave_tui).
pub fn request_shutdown(ch chan int) {
	ch <- 1 or {}
}

// refresh_size re-queries the terminal size (call this from the render
// loop to handle SIGWINCH-equivalent resize).
pub fn (mut s TuiState) refresh_size() {
	s.rows, s.cols = term_size()
}