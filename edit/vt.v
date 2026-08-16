module main

// Port of crates/edit/src/vt.rs (microsoft/edit): the VT escape sequence parser.
// Scalar implementation (the Rust original uses SIMD memchr2; we use a plain loop).
//
// Usage: feed the parser chunks of bytes with feed() and pull tokens one by one
// with next(), or use parse() to get all tokens of a chunk at once. The parser
// keeps its state between chunks, so escape sequences may span multiple feeds.

// vt_esc_timeout_ms is the read timeout suggested while a trailing ESC byte is
// pending: it may either start an escape sequence or be a literal Escape keypress.
// 100ms is an upper ceiling for a responsive feel.
pub const vt_esc_timeout_ms = 100

// vt_no_timeout is returned by read_timeout_ms() when the caller may block
// indefinitely (the Rust original returns Duration::MAX).
pub const vt_no_timeout = -1

// VtState stores the state of the parser.
enum VtState {
	ground
	esc
	ss3
	csi
	osc
	dcs
	osc_esc
	dcs_esc
}

// TokenKind mirrors the variants of Rust's vt::Token enum.
pub enum TokenKind {
	text // A bunch of text. Doesn't contain any control characters.
	ctrl // A single control character, like backspace or return.
	esc  // We encountered `ESC x` and ch contains `x` (0 for a lone, timed-out ESC).
	ss3  // We encountered `ESC O x` and ch contains `x`.
	csi  // A CSI sequence started with `ESC [`. See the csi field.
	osc  // An OSC sequence started with `ESC ]`. See text/partial.
	dcs  // A DCS sequence started with `ESC P`. See text/partial.
}

// Csi is a single CSI sequence, parsed for your convenience.
pub struct Csi {
pub mut:
	// The parameters of the CSI sequence.
	params [32]u16
	// The number of parameters stored in params.
	param_count int
	// The private byte, if any. 0 if none.
	//
	// The private byte is the first character right after the
	// `ESC [` sequence. It is usually a `?` or `<`.
	private_byte u8
	// The final byte of the CSI sequence.
	//
	// This is the last character of the sequence, e.g. `m` or `H`.
	final_byte u8
}

// Token is the output of the VT parser. Which fields are set depends on kind:
// text: text; ctrl/esc/ss3: ch; csi: csi; osc/dcs: text + partial.
//
// The Rust original is a borrowing enum; this port is a self-contained struct.
pub struct Token {
pub:
	kind TokenKind
	// The character for ctrl/esc/ss3 tokens.
	ch rune
	// The payload for text/osc/dcs tokens.
	text string
	// For osc/dcs tokens: true if the sequence is split across chunks
	// and continues in the next input.
	partial bool
	// The parsed CSI sequence for csi tokens.
	csi Csi
}

// VtParser stores the state of the VT parser.
pub struct VtParser {
mut:
	state VtState
	// csi is not part of VtState, because it allows us
	// to more quickly erase and reuse the struct.
	csi   Csi
	input string
	off   int
}

// new_vt_parser creates a new VT parser.
// Keep the instance alive for the lifetime of the input stream.
pub fn new_vt_parser() VtParser {
	return VtParser{}
}

// read_timeout_ms suggests a timeout in milliseconds for the next read().
//
// We need this because of the ambiguity of whether a trailing escape
// character in an input is starting another escape sequence or is just the
// result of the user literally pressing the Escape key.
//
// Returns vt_esc_timeout_ms (100) while an ESC is pending, or vt_no_timeout
// (-1) when the caller may block indefinitely.
pub fn (p VtParser) read_timeout_ms() int {
	return if p.state == .esc { vt_esc_timeout_ms } else { vt_no_timeout }
}

// feed hands the next chunk of input to the parser.
//
// You should call this even if your read() had a timeout
// (pass an empty string in that case), so that a pending
// ESC can be resolved as a literal Escape keypress.
pub fn (mut p VtParser) feed(input string) {
	p.input = input
	p.off = 0
}

// parse feeds a chunk and returns all tokens it contains.
pub fn (mut p VtParser) parse(input string) []Token {
	p.feed(input)
	mut tokens := []Token{}
	for {
		token := p.next() or { break }
		tokens << token
	}
	return tokens
}

// done returns true if the current input has been fully parsed.
pub fn (p VtParser) done() bool {
	return p.off >= p.input.len
}

// offset returns the current parser offset within the current input.
pub fn (p VtParser) offset() int {
	return p.off
}

// next_char decodes and consumes the next UTF-8 character from the input.
// Invalid or truncated sequences are consumed as U+FFFD, one byte at a time.
pub fn (mut p VtParser) next_char() rune {
	if p.off >= p.input.len {
		return rune(0)
	}
	b := p.input[p.off]
	if b < 0x80 {
		p.off++
		return rune(b)
	}
	mut len := 0
	mut cp := u32(0)
	if b >= 0xc2 && b < 0xe0 {
		len = 2
		cp = u32(b & 0x1f)
	} else if b >= 0xe0 && b < 0xf0 {
		len = 3
		cp = u32(b & 0x0f)
	} else if b >= 0xf0 && b < 0xf5 {
		len = 4
		cp = u32(b & 0x07)
	} else {
		// Invalid lead byte.
		p.off++
		return rune(0xfffd)
	}
	if p.off + len > p.input.len {
		// Truncated sequence.
		p.off++
		return rune(0xfffd)
	}
	for i in 1 .. len {
		c := p.input[p.off + i]
		if c & 0xc0 != 0x80 {
			p.off++
			return rune(0xfffd)
		}
		cp = (cp << 6) | u32(c & 0x3f)
	}
	p.off += len
	return rune(cp)
}

// next parses the next VT sequence from the previously fed input.
pub fn (mut p VtParser) next() ?Token {
	input := p.input

	// If the previous input ended with an escape character, read_timeout_ms()
	// returned a timeout, and if the caller did everything correctly and there
	// was indeed a timeout, we should be called with an empty input. In that
	// case we'll return the escape as its own token.
	if input.len == 0 && p.state == .esc {
		p.state = .ground
		return Token{
			kind: .esc
			ch:   0
		}
	}

	for p.off < input.len {
		match p.state {
			.ground {
				c := input[p.off]
				if c == 0x1b {
					p.state = .esc
					p.off++
				} else if c < 0x20 || c == 0x7f {
					p.off++
					return Token{
						kind: .ctrl
						ch:   rune(c)
					}
				} else {
					beg := p.off
					for {
						p.off++
						if !(p.off < input.len && input[p.off] >= 0x20 && input[p.off] != 0x7f) {
							break
						}
					}
					return Token{
						kind: .text
						text: input[beg..p.off]
					}
				}
			}
			.esc {
				c := p.next_char()
				if c == `[` {
					p.state = .csi
					p.csi.private_byte = 0
					p.csi.final_byte = 0
					for p.csi.param_count > 0 {
						p.csi.param_count--
						p.csi.params[p.csi.param_count] = 0
					}
				} else if c == `]` {
					p.state = .osc
				} else if c == `O` {
					p.state = .ss3
				} else if c == `P` {
					p.state = .dcs
				} else {
					p.state = .ground
					return Token{
						kind: .esc
						ch:   c
					}
				}
			}
			.ss3 {
				p.state = .ground
				return Token{
					kind: .ss3
					ch:   p.next_char()
				}
			}
			.csi {
				for {
					// If we still have slots left, parse the parameter.
					if p.csi.param_count < p.csi.params.len {
						mut dst := u32(p.csi.params[p.csi.param_count])
						for p.off < input.len && input[p.off] >= `0` && input[p.off] <= `9` {
							dst = dst * 10 + u32(input[p.off] - `0`)
							if dst > 65535 {
								dst = 65535
							}
							p.off++
						}
						p.csi.params[p.csi.param_count] = u16(dst)
					} else {
						// ...otherwise, skip the parameters until we find the final byte.
						for p.off < input.len && input[p.off] >= `0` && input[p.off] <= `9` {
							p.off++
						}
					}

					// Encountered the end of the input before finding the final byte.
					if p.off >= input.len {
						return none
					}

					c := input[p.off]
					p.off++

					if c >= 0x40 && c <= 0x7e {
						p.state = .ground
						p.csi.final_byte = c
						if p.csi.param_count != 0 || p.csi.params[0] != 0 {
							p.csi.param_count++
						}
						return Token{
							kind: .csi
							csi:  p.csi
						}
					} else if c == `;` {
						p.csi.param_count++
					} else if c >= `<` && c <= `?` {
						p.csi.private_byte = c
					}
					// Anything else is ignored.
				}
			}
			.osc, .dcs {
				// Capture the kind at entry: the state may change to
				// osc_esc/dcs_esc while scanning for the terminator.
				is_osc := p.state == .osc
				beg := p.off
				mut end := p.off
				mut partial := false

				for {
					// Find any indication for the end of the OSC/DCS sequence.
					// Scalar equivalent of the Rust original's SIMD memchr2.
					for p.off < input.len && input[p.off] != 0x07 && input[p.off] != 0x1b {
						p.off++
					}

					end = p.off
					partial = p.off >= input.len

					// Encountered the end of the input before finding the terminator.
					if partial {
						break
					}

					c := input[p.off]
					p.off++

					if c == 0x1b {
						// It's only a string terminator if it's followed by \.
						// We're at the end so we're saving the state and will continue next time.
						if p.off >= input.len {
							p.state = if is_osc { VtState.osc_esc } else { VtState.dcs_esc }
							partial = true
							break
						}

						// False alarm: not a string terminator.
						if input[p.off] != `\\` {
							continue
						}

						p.off++
					}

					break
				}

				if !partial {
					p.state = .ground
				}
				return Token{
					kind:    if is_osc { TokenKind.osc } else { TokenKind.dcs }
					text:    input[beg..end]
					partial: partial
				}
			}
			.osc_esc, .dcs_esc {
				is_osc := p.state == .osc_esc
				// We were processing an OSC/DCS sequence and the last byte was an
				// escape character. It's only a string terminator if it's followed
				// by \ (= "\x1b\\").
				if input[p.off] == `\\` {
					// It was indeed a string terminator and we can now tell the caller
					// about it. Consume the terminator (one byte in the previous input
					// and this byte).
					p.state = .ground
					p.off++
					return Token{
						kind:    if is_osc { TokenKind.osc } else { TokenKind.dcs }
						text:    ''
						partial: false
					}
				}
				// False alarm: not a string terminator.
				// We'll return the escape character as a separate token.
				// Processing will continue from the current state (input[p.off]).
				p.state = if is_osc { VtState.osc } else { VtState.dcs }
				return Token{
					kind:    if is_osc { TokenKind.osc } else { TokenKind.dcs }
					text:    '\x1b'
					partial: true
				}
			}
		}
	}

	return none
}
