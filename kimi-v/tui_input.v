// tui_input.v — keyboard handling for the input box.
//
// We do NOT use any heavyweight input library. In raw mode stdin delivers
// one byte at a time; we accumulate bytes into a buffer and parse special
// sequences (escape codes for arrow keys, ctrl-letter combos, etc.).
//
// Supported key bindings:
//
//   printable characters          insert at cursor
//   Enter                         submit input
//   Ctrl-J                        also submit (alternative to Enter)
//   Backspace / Ctrl-H            delete char before cursor
//   Delete                        delete char at cursor
//   Ctrl-A / Home                 cursor to start of line
//   Ctrl-E / End                  cursor to end of line
//   Ctrl-B / Left arrow            cursor one char left
//   Ctrl-F / Right arrow           cursor one char right
//   Ctrl-N / Down arrow            history next
//   Ctrl-P / Up arrow              history prev
//   Ctrl-K                        kill to end of line
//   Ctrl-U                        kill to start of line
//   Ctrl-W                        kill previous word
//   Ctrl-C                        signal interrupt (handled by main loop)
//   Ctrl-L                        clear screen (handled by render loop)
//   Esc, Esc                      exit TUI
//
// The input box is multi-line: Shift+Enter or literal newlines (we treat
// Ctrl-J as submit, raw \n from paste also submits).
//
// All cursor movement and edit operations walk by Unicode codepoint, not
// by byte — so multi-byte characters (CJK, emoji, accented Latin) are
// deleted and navigated as a single unit. See prev_codepoint_start and
// codepoint_len below.

module main

import os

// ---------- Special key codes --------------------------------------------

pub const key_enter     = 13
pub const key_esc       = 27
pub const key_backspace = 127
pub const key_tab       = 9
pub const ctrl_a        = 1
pub const ctrl_b        = 2
pub const ctrl_c        = 3
pub const ctrl_d        = 4
pub const ctrl_e        = 5
pub const ctrl_f        = 6
pub const ctrl_h        = 8
pub const ctrl_j        = 10
pub const ctrl_k        = 11
pub const ctrl_l        = 12
pub const ctrl_n        = 14
pub const ctrl_p        = 16
pub const ctrl_s        = 19
pub const ctrl_u        = 21
pub const ctrl_w        = 23

// KeyEvent is what the input loop emits. `text` is non-empty only for
// printable characters and pasted multi-byte sequences.
pub struct KeyEvent {
pub:
	kind KeyKind
	text string
}

pub enum KeyKind {
	none
	char
	enter
	backspace
	delete
	left
	right
	up
	down
	home
	end
	kill_to_end
	kill_to_start
	kill_word
	interrupt
	clear_screen
	insert_newline  // Shift+Enter / Alt+Enter — insert literal \n into the buffer
	submit_other    // Ctrl-J — alternative submit (same as Enter)
	esc
	steer           // Ctrl-S — inject the current input into a running turn
	                // (the agent sees it at the next interruptible point,
	                // without waiting for the current turn to finish)
	stdin_eof       // sentinel pushed by the reader when stdin closes
	                // (pipe broken, TTY disconnected, etc.). The TUI
	                // main loop sees this and exits cleanly.
}

// read_key reads one byte at a time from `r` and assembles a KeyEvent.
// Handles ESC-prefixed sequences (arrow keys, etc.). Returns
// KeyKind.stdin_eof on EOF / error so the caller can distinguish "stream
// closed" from "we got an unrecognized byte" (KeyKind.none).
pub fn (mut r StdinReader) read_key() KeyEvent {
	b := r.read_byte() or { return KeyEvent{ kind: .stdin_eof } }
	match b {
		key_enter {
			return KeyEvent{ kind: .enter }
		}
		ctrl_j {
			return KeyEvent{ kind: .enter }
		}
		key_esc {
			return r.read_esc_sequence()
		}
		key_backspace {
			return KeyEvent{ kind: .backspace }
		}
		ctrl_h {
			return KeyEvent{ kind: .backspace }
		}
		ctrl_a {
			return KeyEvent{ kind: .home }
		}
		ctrl_e {
			return KeyEvent{ kind: .end }
		}
		ctrl_b {
			return KeyEvent{ kind: .left }
		}
		ctrl_f {
			return KeyEvent{ kind: .right }
		}
		ctrl_p {
			return KeyEvent{ kind: .up }
		}
		ctrl_n {
			return KeyEvent{ kind: .down }
		}
		ctrl_k {
			return KeyEvent{ kind: .kill_to_end }
		}
		ctrl_u {
			return KeyEvent{ kind: .kill_to_start }
		}
		ctrl_w {
			return KeyEvent{ kind: .kill_word }
		}
		ctrl_c {
			return KeyEvent{ kind: .interrupt }
		}
		ctrl_l {
			return KeyEvent{ kind: .clear_screen }
		}
		ctrl_s {
			return KeyEvent{ kind: .steer }
		}
		ctrl_d {
			// Ctrl-D on empty input = EOF; we treat it as interrupt to be safe.
			return KeyEvent{ kind: .interrupt }
		}
		else {
			if b >= 32 && b < 127 {
				return KeyEvent{
					kind: .char
					text: b.ascii_str()
				}
			}
			if b >= 128 {
				// High-bit byte: start of a multi-byte UTF-8 sequence. Read
				// continuation bytes (10xxxxxx) until done.
				mut seq := [b]
				for seq.len < 4 && (b & 0x80) != 0 {
					if seq.len >= 2 && (b & (1 << (7 - seq.len))) == 0 {
						break
					}
					cb := r.read_byte() or { break }
					seq << cb
				}
				return KeyEvent{
					kind: .char
					text: seq.bytestr()
				}
			}
			return KeyEvent{ kind: .none }
		}
	}
}

// StdinReader reads bytes directly from fd 0 via os.fd_read, which bypasses
// C stdio buffering. We need the unbuffered path because in raw mode each
// keystroke is one byte — but os.get_raw_stdin() goes through stdio's
// internal buffer and blocks waiting for ~512 bytes or EOF.
pub struct StdinReader {
pub mut:
	carry []u8
}

pub fn new_stdin_reader() StdinReader {
	return StdinReader{ carry: []u8{} }
}

// read_byte pulls one byte from the buffered input.
fn (mut r StdinReader) read_byte() !u8 {
	if r.carry.len > 0 {
		b := r.carry[0]
		r.carry = r.carry[1..]
		return b
	}
	// os.fd_read(fd, max_n) returns (string, err). It blocks until at
	// least 1 byte is available. In raw mode (ICANON off, no echo) the
	// terminal delivers bytes one at a time, so this returns as soon as
	// the user presses a key.
	bytes, _ := os.fd_read(0, 64)
	if bytes.len == 0 {
		return error('eof')
	}
	if bytes.len > 1 {
		// Buffer the excess for subsequent reads.
		r.carry = bytes[1..].bytes()
	}
	return bytes[0]
}

// read_esc_sequence handles ESC followed by `[` (CSI sequences) or single
// letter ESC sequences. Returns KeyEvent based on the sequence.
fn (mut r StdinReader) read_esc_sequence() KeyEvent {
	b := r.read_byte() or { return KeyEvent{ kind: .esc } }
	match b {
		`[` {
			// CSI: \e[X or \e[X~ or \e[X;Y~ (modified keys)
			c := r.read_byte() or { return KeyEvent{ kind: .esc } }
			match c {
				`A` { return KeyEvent{ kind: .up } }
				`B` { return KeyEvent{ kind: .down } }
				`C` { return KeyEvent{ kind: .right } }
				`D` { return KeyEvent{ kind: .left } }
				`H` { return KeyEvent{ kind: .home } }
				`F` { return KeyEvent{ kind: .end } }
				`3` {
					// Delete key: ESC [ 3 ~
					tilde := r.read_byte() or { return KeyEvent{ kind: .esc } }
					if tilde == `~` {
						return KeyEvent{ kind: .delete }
					}
					return KeyEvent{ kind: .esc }
				}
				`1` {
					// Modified Enter keys: ESC [ 13 ; <modifier> ~
					// e.g. 13;2~ = Shift+Enter, 13;5~ = Ctrl+Enter.
					// We only treat Shift+Enter (modifier 2) as a literal
					// newline; Ctrl+Enter would clash with Ctrl-J submit.
					semi := r.read_byte() or { return KeyEvent{ kind: .esc } }
					if semi != `;` {
						return KeyEvent{ kind: .esc }
					}
					// Read the modifier digit and trailing ~.
					mod1 := r.read_byte() or { return KeyEvent{ kind: .esc } }
					tilde := r.read_byte() or { return KeyEvent{ kind: .esc } }
					if tilde == `~` && mod1 == `2` {
						return KeyEvent{ kind: .insert_newline }
					}
					return KeyEvent{ kind: .esc }
				}
				else {
					return KeyEvent{ kind: .esc }
				}
			}
		}
		key_enter {
			// ESC + Enter byte = Alt+Enter. Treat as literal newline so
			// users on terminals that don't send CSI 13;2~ still have
			// a way to break the line.
			return KeyEvent{ kind: .insert_newline }
		}
		else {
			// Single ESC, or ESC + letter (Alt-key chord). We treat any
			// unknown ESC sequence as just ESC for simplicity.
			return KeyEvent{ kind: .esc }
		}
	}
}

// ---------- Input buffer -------------------------------------------------

pub struct InputBuf {
pub mut:
	// Current line of text being edited.
	text      string
	// Cursor position (byte offset, 0..text.len).
	cursor    int
	// History (most recent last).
	history   []string
	// Index into history when navigating (-1 = current line).
	hist_idx  int
	// Saved current text when navigating into history (so we can restore
	// when navigating back).
	saved     string
}

pub fn new_input_buf() InputBuf {
	return InputBuf{
		history: []string{}
		hist_idx: -1
	}
}

// prev_codepoint_start returns the byte offset of the codepoint ending at
// (or containing) `pos` — i.e. the boundary we land on when stepping one
// character to the left. Walks back over UTF-8 continuation bytes
// (0b10xxxxxx) to find the start of the codepoint. Returns 0 for pos <= 0.
fn prev_codepoint_start(s string, pos int) int {
	if pos <= 0 {
		return 0
	}
	mut p := pos - 1
	for p > 0 && (s[p] & 0xC0) == 0x80 {
		p--
	}
	return p
}

// codepoint_len returns the byte length of the codepoint starting at `pos`.
// For invalid lead bytes, returns 1 so callers always make progress.
fn codepoint_len(s string, pos int) int {
	if pos >= s.len {
		return 0
	}
	b0 := s[pos]
	if (b0 & 0x80) == 0 {
		return 1
	} else if (b0 & 0xE0) == 0xC0 {
		return 2
	} else if (b0 & 0xF0) == 0xE0 {
		return 3
	} else if (b0 & 0xF8) == 0xF0 {
		return 4
	}
	return 1
}

// SubmitKind tells the main loop what to do with a finished input
// buffer. `.agent` is the normal path (push to the LLM); `.shell`
// means the user typed a `!`-prefixed command and wants it run as a
// shell command without going through the agent.
pub enum SubmitKind {
	none
	agent
	shell
}

// apply mutates the buffer according to a KeyEvent. Returns a SubmitKind
// indicating what the caller should do with the (committed) buffer.
// `.none` means "no submit; keep editing". `.agent` is the normal
// submission path. `.shell` means the input was `!…` and should be run
// as a shell command instead of sent to the agent.
//
// `!` shell mode rules (matches upstream kimi-code):
//   - input starts with `!` (whitespace prefix ignored) → run as shell
//   - input starts with `!` then is empty (e.g. user just hit Enter on
//     a bare `!`) → also shell (an empty command line just opens the
//     shell prompt; we still treat it as a no-op and fall back to
//     agent-mode submit, since there's nothing to run)
//   - input has a literal `!` in the middle (e.g. `echo !`) → still
//     shell; the user clearly meant "I want this run as a command"
pub fn (mut b InputBuf) apply(ev KeyEvent) SubmitKind {
	match ev.kind {
		.char {
			b.insert(ev.text)
		}
		.insert_newline {
			// Multi-line: insert a literal \n at the cursor. Submit is
			// reserved for plain Enter / Ctrl-J.
			b.insert('\n')
		}
		.backspace {
			b.backspace()
		}
		.delete {
			b.delete_forward()
		}
		.left {
			if b.cursor > 0 {
				b.cursor = prev_codepoint_start(b.text, b.cursor)
			}
		}
		.right {
			if b.cursor < b.text.len {
				b.cursor += codepoint_len(b.text, b.cursor)
			}
		}
		.home {
			b.cursor = 0
		}
		.end {
			b.cursor = b.text.len
		}
		.up {
			b.history_prev()
		}
		.down {
			b.history_next()
		}
		.kill_to_end {
			b.text = b.text[..b.cursor]
		}
		.kill_to_start {
			b.text = b.text[b.cursor..]
			b.cursor = 0
		}
		.kill_word {
			b.kill_word()
		}
		.enter, .submit_other {
			// Commit current text to history (unless empty).
			if b.text.len > 0 {
				b.history << b.text
			}
			b.hist_idx = -1
			b.saved = ''
			kind := if b.text.starts_with('!') { SubmitKind.shell } else { SubmitKind.agent }
			b.text = ''
			b.cursor = 0
			return kind
		}
		else {
			// ignore: esc, interrupt, clear_screen, none
		}
	}
	return .none
}

// insert inserts a string at the cursor.
fn (mut b InputBuf) insert(s string) {
	b.text = b.text[..b.cursor] + s + b.text[b.cursor..]
	b.cursor += s.len
}

// backspace removes the codepoint before the cursor (UTF-8 aware: deletes
// all bytes of one character, not just one byte).
fn (mut b InputBuf) backspace() {
	if b.cursor == 0 {
		return
	}
	start := prev_codepoint_start(b.text, b.cursor)
	b.text = b.text[..start] + b.text[b.cursor..]
	b.cursor = start
}

// delete_forward removes the codepoint at the cursor (UTF-8 aware).
fn (mut b InputBuf) delete_forward() {
	if b.cursor >= b.text.len {
		return
	}
	n := codepoint_len(b.text, b.cursor)
	b.text = b.text[..b.cursor] + b.text[b.cursor + n..]
}

// kill_word removes the word before the cursor (Ctrl-W). Walks by codepoint
// so multi-byte characters are treated as single units.
fn (mut b InputBuf) kill_word() {
	if b.cursor == 0 {
		return
	}
	mut end := b.cursor
	// First skip trailing whitespace (ASCII — byte-walk is fine).
	for end > 0 && b.text[end - 1] in [` `, `\t`] {
		end--
	}
	// Then skip word codepoints backwards.
	for end > 0 {
		start := prev_codepoint_start(b.text, end)
		cb := b.text[start]
		if cb == ` ` || cb == `\t` {
			break
		}
		end = start
	}
	b.text = b.text[..end] + b.text[b.cursor..]
	b.cursor = end
}

// history_prev navigates to an older history entry.
fn (mut b InputBuf) history_prev() {
	if b.history.len == 0 {
		return
	}
	if b.hist_idx == -1 {
		// Save current text first.
		b.saved = b.text
		b.hist_idx = b.history.len - 1
	} else if b.hist_idx > 0 {
		b.hist_idx--
	}
	b.text = b.history[b.hist_idx]
	b.cursor = b.text.len
}

// history_next navigates to a newer history entry (or back to current).
fn (mut b InputBuf) history_next() {
	if b.hist_idx == -1 {
		return
	}
	if b.hist_idx < b.history.len - 1 {
		b.hist_idx++
		b.text = b.history[b.hist_idx]
	} else {
		// Back at the bottom — restore saved text.
		b.hist_idx = -1
		b.text = b.saved
		b.saved = ''
	}
	b.cursor = b.text.len
}