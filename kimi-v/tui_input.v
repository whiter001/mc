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
//   Ctrl-O                        toggle collapse of all tool result blocks
//   Ctrl-V                        paste system clipboard (macOS pbpaste /
//                                   Linux wl-paste|xclip / Windows PowerShell)
//   Ctrl-X                        clear pending image attachments
//   Esc, Esc                      exit TUI
//
// Image attachments (P0.7):
//   When a `.char` event delivers a single-line string that looks like
//   a file path (absolute, ~/..., ./..., ../...) AND the resolved file
//   exists with a recognized image extension, the TUI consumes the
//   text and adds it to InputBuf.attachments instead of inserting it.
//   Same for data: URL pastes (data:image/...;base64,...). Attached
//   files are sent as image_url content parts on the next submit and
//   cleared from the buffer afterwards. See InputBuf.attach_file and
//   attach_data_url for the rules.
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
import encoding.base64

// ---------- Special key codes --------------------------------------------

pub const key_enter = 13
pub const key_esc = 27
pub const key_backspace = 127
pub const ctrl_a = 1
pub const ctrl_b = 2
pub const ctrl_c = 3
pub const ctrl_d = 4
pub const ctrl_e = 5
pub const ctrl_f = 6
pub const ctrl_h = 8
pub const ctrl_j = 10
pub const ctrl_k = 11
pub const ctrl_l = 12
pub const ctrl_n = 14
pub const ctrl_o = 15
pub const ctrl_p = 16
pub const ctrl_s = 19
pub const ctrl_u = 21
pub const ctrl_v = 22
pub const ctrl_w = 23
pub const ctrl_x = 24

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
	insert_newline // Shift+Enter / Alt+Enter — insert literal \n into the buffer
	submit_other   // Ctrl-J — alternative submit (same as Enter)
	esc
	steer // Ctrl-S — inject the current input into a running turn
	// (the agent sees it at the next interruptible point,
	// without waiting for the current turn to finish)
	collapse // Ctrl-O — toggle collapse of all tool_result blocks
	// in the conversation scrollback. First press collapses
	// all to a one-line summary; second press expands.
	clear_attachments // Ctrl-X — drop all pending image attachments from
	// the input buffer. A no-op (with a status hint) when
	// no attachments are pending.
	paste // Bracketed-paste content: a chunk of text pasted by
	// the terminal (wrapped in ESC[200~...ESC[201~). The
	// TUI handles it atomically instead of char-by-char.
	focus_in // Terminal focus-in report (ESC I): the TUI window
	// regained focus. Used to refresh clipboard hints.
	focus_out // Terminal focus-out report (ESC O): the TUI window
	// lost focus. Mostly ignored; hint state is reset.
	stdin_eof // sentinel pushed by the reader when stdin closes
	// (pipe broken, TTY disconnected, etc.). The TUI
	// main loop sees this and exits cleanly.
}

// read_key reads one byte at a time from `r` and assembles a KeyEvent.
// Handles ESC-prefixed sequences (arrow keys, etc.). Returns
// KeyKind.stdin_eof on EOF / error so the caller can distinguish "stream
// closed" from "we got an unrecognized byte" (KeyKind.none).
pub fn (mut r StdinReader) read_key() KeyEvent {
	b := r.read_byte() or { return KeyEvent{
		kind: .stdin_eof
	} }
	match b {
		key_enter {
			return KeyEvent{
				kind: .enter
			}
		}
		ctrl_j {
			return KeyEvent{
				kind: .enter
			}
		}
		key_esc {
			return r.read_esc_sequence()
		}
		key_backspace {
			return KeyEvent{
				kind: .backspace
			}
		}
		ctrl_h {
			return KeyEvent{
				kind: .backspace
			}
		}
		ctrl_a {
			return KeyEvent{
				kind: .home
			}
		}
		ctrl_e {
			return KeyEvent{
				kind: .end
			}
		}
		ctrl_b {
			return KeyEvent{
				kind: .left
			}
		}
		ctrl_f {
			return KeyEvent{
				kind: .right
			}
		}
		ctrl_p {
			return KeyEvent{
				kind: .up
			}
		}
		ctrl_n {
			return KeyEvent{
				kind: .down
			}
		}
		ctrl_k {
			return KeyEvent{
				kind: .kill_to_end
			}
		}
		ctrl_u {
			return KeyEvent{
				kind: .kill_to_start
			}
		}
		ctrl_w {
			return KeyEvent{
				kind: .kill_word
			}
		}
		ctrl_c {
			return KeyEvent{
				kind: .interrupt
			}
		}
		ctrl_l {
			return KeyEvent{
				kind: .clear_screen
			}
		}
		ctrl_s {
			return KeyEvent{
				kind: .steer
			}
		}
		ctrl_o {
			return KeyEvent{
				kind: .collapse
			}
		}
		ctrl_x {
			return KeyEvent{
				kind: .clear_attachments
			}
		}
		ctrl_v {
			// Ctrl+V: read the system clipboard and treat the result as a
			// bracketed-paste event. This matches upstream's "paste from
			// clipboard" shortcut on Unix-like terminals where Ctrl+V is
			// not already converted into bracketed paste by the emulator.
			content := read_clipboard()
			if content.len > 0 {
				return KeyEvent{
					kind: .paste
					text: content
				}
			}
			return KeyEvent{
				kind: .none
			}
		}
		ctrl_d {
			// Ctrl-D on empty input = EOF; we treat it as interrupt to be safe.
			return KeyEvent{
				kind: .interrupt
			}
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
			return KeyEvent{
				kind: .none
			}
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

// new_stdin_reader creates an unbuffered stdin reader for raw-mode input.
pub fn new_stdin_reader() StdinReader {
	return StdinReader{
		carry: []u8{}
	}
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
	b := r.read_byte() or { return KeyEvent{
		kind: .esc
	} }
	match b {
		`[` {
			// CSI: \e[X or \e[X~ or \e[X;Y~ (modified keys)
			c := r.read_byte() or { return KeyEvent{
				kind: .esc
			} }
			match c {
				`A` {
					return KeyEvent{
						kind: .up
					}
				}
				`B` {
					return KeyEvent{
						kind: .down
					}
				}
				`C` {
					return KeyEvent{
						kind: .right
					}
				}
				`D` {
					return KeyEvent{
						kind: .left
					}
				}
				`H` {
					return KeyEvent{
						kind: .home
					}
				}
				`F` {
					return KeyEvent{
						kind: .end
					}
				}
				`2` {
					// Bracketed paste: ESC [ 2 0 0 ~ starts a paste,
					// ESC [ 2 0 1 ~ ends it. We only handle the start
					// here; the end is consumed by read_bracketed_paste.
					d := r.read_byte() or { return KeyEvent{
						kind: .esc
					} }
					if d == `0` {
						e := r.read_byte() or { return KeyEvent{
							kind: .esc
						} }
						if e == `0` {
							tilde := r.read_byte() or {
								return KeyEvent{
									kind: .esc
								}
							}
							if tilde == `~` {
								return r.read_bracketed_paste()
							}
						}
					}
					return KeyEvent{
						kind: .esc
					}
				}
				`3` {
					// Delete key: ESC [ 3 ~
					tilde := r.read_byte() or { return KeyEvent{
						kind: .esc
					} }
					if tilde == `~` {
						return KeyEvent{
							kind: .delete
						}
					}
					return KeyEvent{
						kind: .esc
					}
				}
				`1` {
					// Modified Enter keys: ESC [ 13 ; <modifier> ~
					// e.g. 13;2~ = Shift+Enter, 13;5~ = Ctrl+Enter.
					// We only treat Shift+Enter (modifier 2) as a literal
					// newline; Ctrl+Enter would clash with Ctrl-J submit.
					semi := r.read_byte() or { return KeyEvent{
						kind: .esc
					} }
					if semi != `;` {
						return KeyEvent{
							kind: .esc
						}
					}
					// Read the modifier digit and trailing ~.
					mod1 := r.read_byte() or { return KeyEvent{
						kind: .esc
					} }
					tilde := r.read_byte() or { return KeyEvent{
						kind: .esc
					} }
					if tilde == `~` && mod1 == `2` {
						return KeyEvent{
							kind: .insert_newline
						}
					}
					return KeyEvent{
						kind: .esc
					}
				}
				else {
					return KeyEvent{
						kind: .esc
					}
				}
			}
		}
		key_enter {
			// ESC + Enter byte = Alt+Enter. Treat as literal newline so
			// users on terminals that don't send CSI 13;2~ still have
			// a way to break the line.
			return KeyEvent{
				kind: .insert_newline
			}
		}
		`I` {
			// Focus-in report: terminal window regained focus.
			return KeyEvent{
				kind: .focus_in
			}
		}
		`O` {
			// Focus-out report: terminal window lost focus.
			return KeyEvent{
				kind: .focus_out
			}
		}
		else {
			// Single ESC, or ESC + letter (Alt-key chord). We treat any
			// unknown ESC sequence as just ESC for simplicity.
			return KeyEvent{
				kind: .esc
			}
		}
	}
}

// read_bracketed_paste consumes bytes until the terminal sends the
// end-of-paste sequence ESC [ 2 0 1 ~. Returns the pasted content as a
// single .paste KeyEvent. If stdin closes mid-paste, returns whatever
// was accumulated up to that point.
fn (mut r StdinReader) read_bracketed_paste() KeyEvent {
	end_seq := '\x1b[201~'
	mut buf := []u8{}
	for {
		b := r.read_byte() or { break }
		buf << b
		if buf.len >= end_seq.len {
			if buf[buf.len - end_seq.len..].bytestr() == end_seq {
				content := buf[..buf.len - end_seq.len].bytestr()
				return KeyEvent{
					kind: .paste
					text: content
				}
			}
		}
	}
	return KeyEvent{
		kind: .paste
		text: buf.bytestr()
	}
}

// read_clipboard returns the current system clipboard contents as text.
// Best-effort across macOS / Linux / Windows; returns an empty string if
// no clipboard reader is available or the clipboard is empty.
fn read_clipboard() string {
	$if macos {
		res := os.execute('pbpaste')
		if res.exit_code == 0 {
			return res.output
		}
	} $else $if linux {
		// Prefer Wayland, fall back to X11.
		mut res := os.execute('wl-paste 2>/dev/null')
		if res.exit_code != 0 {
			res = os.execute('xclip -selection clipboard -o 2>/dev/null')
		}
		if res.exit_code == 0 {
			return res.output
		}
	} $else $if windows {
		res := os.execute('powershell -command "Get-Clipboard"')
		if res.exit_code == 0 {
			return res.output
		}
	}
	return ''
}

// clipboard_has_image returns true when the system clipboard currently
// holds an image. Used to show the "Ctrl+V to paste image" hint when the
// TUI window regains focus.
fn clipboard_has_image() bool {
	$if macos {
		// `clipboard info` returns a list of available types; look for
		// common image format class names (PNG, JPEG, TIFF, PICT, GIF).
		res := os.execute("osascript -e 'clipboard info'")
		if res.exit_code == 0 {
			info := res.output.to_lower()
			return info.contains('pngf') || info.contains('jpeg') || info.contains('tiff')
				|| info.contains('pict') || info.contains('gif') || info.contains('image')
		}
	}
	return false
}

// ---------- Input buffer -------------------------------------------------

pub struct InputBuf {
pub mut:
	// Current line of text being edited.
	text string
	// Cursor position (byte offset, 0..text.len).
	cursor int
	// History (most recent last).
	history []string
	// Index into history when navigating (-1 = current line).
	hist_idx int
	// Saved current text when navigating into history (so we can restore
	// when navigating back).
	saved string
	// Pending image attachments. Filled by the TUI when the user
	// pastes a path to a recognized image file or a data: URL.
	// Consumed (and cleared) at submit time. Not in the text buffer
	// so cursor movement / backspace don't touch them — clear them
	// explicitly with Ctrl-X.
	attachments []Attachment
}

// new_input_buf creates an empty input buffer with an empty history.
pub fn new_input_buf() InputBuf {
	return InputBuf{
		history:  []string{}
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

// ---------- Attachments (P0.7) -------------------------------------------
//
// Image attachments are stored alongside the text buffer but not
// inside it. The TUI auto-attaches when the user pastes something
// that looks like a file path to a recognized image, or a data:
// URL. The helpers below are the only way attachments enter the
// buffer; the TUI main loop calls them after a `.char` event before
// the same event reaches `apply` (see tui_loop.v:handle_key).
//
// Recognized image extensions: png, jpg, jpeg, gif, webp, bmp.
// Max file size: 10 MB. Anything larger is rejected (silently —
// the TUI falls through to inserting the text, which the user can
// then backspace if they don't want it). We do this because base64
// inflates ~33% and a 50MB screenshot would balloon the request
// to ~67MB and likely time out at the provider.

// max_attachment_bytes is the per-file size cap for pasted images.
// 10 MB is well under OpenAI's 20 MB vision-image cap (after
// base64) and well within what local / proxy providers accept.
pub const max_attachment_bytes = 10 * 1024 * 1024

// max_image_long_side is the longest edge we allow for attached images
// before downscaling. 2000px keeps request sizes reasonable while
// preserving enough detail for screenshots and photos.
pub const max_image_long_side = 2000

// max_attachment_bytes_after_compress is the size cap applied after
// compression. 5 MB leaves headroom under the OpenAI 20 MB vision
// limit (base64 inflates ~33%, so 5 MB raw ≈ 6.7 MB on the wire).
pub const max_attachment_bytes_after_compress = 5 * 1024 * 1024

// compress_image now lives in image_compress.v (cross-platform stbi
// implementation, with a macOS sips fallback for formats stb_image
// cannot decode). Return semantics are unchanged: the original path
// means the caller has nothing to clean up; a temp path means the
// caller must delete the file after reading.

// attach_file attempts to attach the file at `path` (resolved
// against `cwd` when relative). Returns true on success — the file
// was read, base64-encoded, and pushed onto the attachment list.
// Returns false if the path doesn't exist, has an unrecognized
// extension, is too large, or the active `model` cannot ingest
// images. Callers should fall through to inserting the text on
// false so the user doesn't lose what they typed.
pub fn (mut b InputBuf) attach_file(cwd string, path string, model string) bool {
	// Attachment capability gate: refuse image attachments when the active
	// model cannot ingest images (per the capability registry). When the
	// model is unknown (model == '') the registry returns its lenient
	// default (image_in=true), so existing behavior is preserved. The caller
	// falls through to inserting the path as plain text on false, which is
	// the intended "rejected" signal for this provider constraint.
	if !lookup_capability(model).image_in {
		return false
	}
	resolved := resolve_attach_path(cwd, path)
	if !os.exists(resolved) {
		return false
	}
	ext := attachment_ext(path)
	mime := mime_for_image_ext(ext)
	if mime.len == 0 {
		return false
	}
	// Downscale oversized images before reading them into memory.
	compressed_path := compress_image(resolved)
	defer {
		if compressed_path != resolved {
			os.rm(compressed_path) or {}
		}
	}
	size := os.file_size(compressed_path)
	if size < 0 || size > max_attachment_bytes {
		return false
	}
	data := os.read_file(compressed_path) or { return false }
	b64 := base64.encode(data.bytes())
	name := attachment_basename(path)
	b.attachments << Attachment{
		mime: mime
		b64:  b64
		name: name
	}
	return true
}

// attach_data_url handles a pasted data: URL of the form
// `data:image/<sub>;base64,<b64>`. Returns true on success. The
// mime and base64 are extracted from the URL directly — we do not
// re-encode (the data is already base64). Display name is
// synthesized from the mime subtype (e.g. `pasted.png`).
pub fn (mut b InputBuf) attach_data_url(data_url string, model string) bool {
	// Same capability gate as attach_file: block image data: URLs when the
	// active model has no image input (see the note there).
	if !lookup_capability(model).image_in {
		return false
	}
	if !data_url.starts_with('data:image/') {
		return false
	}
	comma := data_url.index(',') or { return false }
	if comma < 0 {
		return false
	}
	header := data_url[..comma] // e.g. "data:image/png;base64"
	payload := data_url[comma + 1..]
	if !header.ends_with(';base64') {
		return false
	}
	mime := header[5..header.len - 7] // strip "data:" prefix and ";base64" suffix
	if mime.len == 0 {
		return false
	}
	ext := mime.all_after('/')
	if ext.len == 0 {
		return false
	}
	name := 'pasted.${ext}'
	b.attachments << Attachment{
		mime: mime
		b64:  payload
		name: name
	}
	return true
}

// clear_attachments removes all pending attachments. Wired to
// Ctrl-X by the TUI main loop. Returns the count that was cleared
// so the caller can surface a status hint.
pub fn (mut b InputBuf) clear_attachments() int {
	n := b.attachments.len
	b.attachments = []Attachment{}
	return n
}

// has_attachments is true when the buffer has at least one pending
// attachment. Used by the render layer to decide whether to draw
// the attachment row above the input prompt.
pub fn (b InputBuf) has_attachments() bool {
	return b.attachments.len > 0
}

// ---------- Attachment helpers (also used by tests) -----------------------

// resolve_attach_path normalizes a user-pasted path string:
//   absolute (/foo/bar)        → as-is
//   home-relative (~/foo)      → expanded against $HOME
//   relative (./ or ../ or bare) → joined against `cwd`
fn resolve_attach_path(cwd string, path string) string {
	if path.starts_with('~/') {
		return os.join_path(os.home_dir(), path[2..])
	}
	if path.starts_with('/') {
		return path
	}
	return os.join_path(cwd, path)
}

// attachment_ext returns the lowercase extension (without the
// leading dot) of a path. Empty string if there is no extension
// or the only dot is a leading dot in a dotfile (".bashrc" has no
// extension; ".config.png" is "png").
fn attachment_ext(path string) string {
	// Walk to the last '/' so dotfiles in a directory path are not
	// confused for an extension. ".config/foo.png" → check the
	// "foo.png" segment.
	slash := path.last_index('/') or { -1 }
	seg := if slash >= 0 { path[slash + 1..] } else { path }
	// If the basename starts with a dot, it's a dotfile — no ext.
	if seg.len > 0 && seg[0] == `.` {
		return ''
	}
	idx := seg.last_index('.') or { return '' }
	if idx < 0 || idx + 1 >= seg.len {
		return ''
	}
	return seg[idx + 1..].to_lower()
}

// attachment_basename returns the last path segment as a display
// name. For "/foo/bar/baz.png" returns "baz.png". kimi-v is
// POSIX-only (see config_paths.v), so we don't need to handle
// Windows backslashes.
fn attachment_basename(path string) string {
	idx := path.last_index('/') or { return path }
	return path[idx + 1..]
}

// mime_for_image_ext returns the MIME type for a recognized image
// extension, or empty string if the extension is not a supported
// image type. The same map is used by attach_file and by the test
// suite (so a regression in one breaks the other).
fn mime_for_image_ext(ext string) string {
	match ext {
		'png' { return 'image/png' }
		'jpg', 'jpeg' { return 'image/jpeg' }
		'gif' { return 'image/gif' }
		'webp' { return 'image/webp' }
		'bmp' { return 'image/bmp' }
		else { return '' }
	}
}

// looks_like_attach_candidate is the cheap pre-filter the TUI runs
// on every `.char` event before attempting an attach. It rejects
// anything with whitespace, anything too short, and anything too
// long — so natural language typing ("hi", "ls -la", "你好") and
// real paste of large text never trigger the attach path. The
// actual path resolution / file read happens in attach_file (which
// can still return false on a candidate that passes this filter).
pub fn looks_like_attach_candidate(text string) bool {
	if text.len < 4 {
		return false
	}
	if text.len > 4096 {
		return false
	}
	// No whitespace — paths and data URLs are single tokens.
	if text.contains_any(' \t\n\r') {
		return false
	}
	// data: URLs are an explicit opt-in.
	if text.starts_with('data:image/') {
		return true
	}
	// Path-style: must start with one of the recognized prefixes.
	if text.starts_with('/') || text.starts_with('~/') {
		return true
	}
	if text.starts_with('./') || text.starts_with('../') {
		return true
	}
	return false
}
