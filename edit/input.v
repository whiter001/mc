module main

// Port of crates/edit/src/input.rs (microsoft/edit):
// parses VT sequences into input events.
//
// In the future this allows us to take apart the application and
// support input schemes that aren't VT, such as UEFI, or GUI.

// InputKey represents a key/modifier combination.
// The low 24 bits are the key code (the vk_* constants below, matching the
// VK_* constants on Windows), the high 8 bits are the kbmod_* modifier flags.
pub type InputKey = u32

// Keyboard keys.
//
// The codes defined here match the VK_* constants on Windows.
// It's a convenient way to handle keyboard input, even on other platforms.
pub const vk_null = u32(0x00)
pub const vk_back = u32(0x08)
pub const vk_tab = u32(0x09)
pub const vk_return = u32(0x0d)
pub const vk_escape = u32(0x1b)
pub const vk_space = u32(0x20)
pub const vk_prior = u32(0x21)
pub const vk_next = u32(0x22)

pub const vk_end = u32(0x23)
pub const vk_home = u32(0x24)

pub const vk_left = u32(0x25)
pub const vk_up = u32(0x26)
pub const vk_right = u32(0x27)
pub const vk_down = u32(0x28)

pub const vk_insert = u32(0x2d)
pub const vk_delete = u32(0x2e)

pub const vk_n0 = u32(0x30)
pub const vk_n1 = u32(0x31)
pub const vk_n2 = u32(0x32)
pub const vk_n3 = u32(0x33)
pub const vk_n4 = u32(0x34)
pub const vk_n5 = u32(0x35)
pub const vk_n6 = u32(0x36)
pub const vk_n7 = u32(0x37)
pub const vk_n8 = u32(0x38)
pub const vk_n9 = u32(0x39)

pub const vk_a = u32(0x41)
pub const vk_b = u32(0x42)
pub const vk_c = u32(0x43)
pub const vk_d = u32(0x44)
pub const vk_e = u32(0x45)
pub const vk_f = u32(0x46)
pub const vk_g = u32(0x47)
pub const vk_h = u32(0x48)
pub const vk_i = u32(0x49)
pub const vk_j = u32(0x4a)
pub const vk_k = u32(0x4b)
pub const vk_l = u32(0x4c)
pub const vk_m = u32(0x4d)
pub const vk_n = u32(0x4e)
pub const vk_o = u32(0x4f)
pub const vk_p = u32(0x50)
pub const vk_q = u32(0x51)
pub const vk_r = u32(0x52)
pub const vk_s = u32(0x53)
pub const vk_t = u32(0x54)
pub const vk_u = u32(0x55)
pub const vk_v = u32(0x56)
pub const vk_w = u32(0x57)
pub const vk_x = u32(0x58)
pub const vk_y = u32(0x59)
pub const vk_z = u32(0x5a)

pub const vk_numpad0 = u32(0x60)
pub const vk_numpad1 = u32(0x61)
pub const vk_numpad2 = u32(0x62)
pub const vk_numpad3 = u32(0x63)
pub const vk_numpad4 = u32(0x64)
pub const vk_numpad5 = u32(0x65)
pub const vk_numpad6 = u32(0x66)
pub const vk_numpad7 = u32(0x67)
pub const vk_numpad8 = u32(0x68)
pub const vk_numpad9 = u32(0x69)
pub const vk_multiply = u32(0x6a)
pub const vk_add = u32(0x6b)
pub const vk_separator = u32(0x6c)
pub const vk_subtract = u32(0x6d)
pub const vk_decimal = u32(0x6e)
pub const vk_divide = u32(0x6f)

pub const vk_f1 = u32(0x70)
pub const vk_f2 = u32(0x71)
pub const vk_f3 = u32(0x72)
pub const vk_f4 = u32(0x73)
pub const vk_f5 = u32(0x74)
pub const vk_f6 = u32(0x75)
pub const vk_f7 = u32(0x76)
pub const vk_f8 = u32(0x77)
pub const vk_f9 = u32(0x78)
pub const vk_f10 = u32(0x79)
pub const vk_f11 = u32(0x7a)
pub const vk_f12 = u32(0x7b)
pub const vk_f13 = u32(0x7c)
pub const vk_f14 = u32(0x7d)
pub const vk_f15 = u32(0x7e)
pub const vk_f16 = u32(0x7f)
pub const vk_f17 = u32(0x80)
pub const vk_f18 = u32(0x81)
pub const vk_f19 = u32(0x82)
pub const vk_f20 = u32(0x83)
pub const vk_f21 = u32(0x84)
pub const vk_f22 = u32(0x85)
pub const vk_f23 = u32(0x86)
pub const vk_f24 = u32(0x87)

// Keyboard modifiers. Ctrl/Alt/Shift.
pub const kbmod_none = u32(0x00000000)
pub const kbmod_ctrl = u32(0x01000000)
pub const kbmod_alt = u32(0x02000000)
pub const kbmod_shift = u32(0x04000000)

pub const kbmod_ctrl_alt = u32(0x03000000)
pub const kbmod_ctrl_shift = u32(0x05000000)
pub const kbmod_alt_shift = u32(0x06000000)
pub const kbmod_ctrl_alt_shift = u32(0x07000000)

// InputMouseState is the mouse input state. Up/Down, Left/Right, etc.
pub enum InputMouseState {
	none
	// These 3 carry their state between frames.
	left
	middle
	right
	// These 2 get reset to none on the next frame.
	release
	scroll
}

// InputMouse is a mouse input event.
pub struct InputMouse {
pub mut:
	// The state of the mouse. Up/Down, Left/Right, etc.
	state InputMouseState
	// Any keyboard modifiers that are held down (kbmod_* flags).
	modifiers u32
	// Position of the mouse in the viewport.
	position Point
	// Scroll delta.
	scroll Point
	// Whether the mouse is being dragged with a button held down.
	drag bool
}

// InputKind mirrors the variants of Rust's input::Input enum.
pub enum InputKind {
	resize   // Window resize event. See size.
	text     // Text input. Note that keyboard events can also be text. See text.
	paste    // A clipboard paste. See data.
	keyboard // Keyboard input. See key.
	mouse    // Mouse input. See mouse.
}

// Input is the primary result type of the parser.
// Which fields are set depends on kind.
pub struct Input {
pub:
	kind  InputKind
	size  Size       // resize: the new window size
	text  string     // text: the text input
	data  []u8       // paste: the pasted bytes
	key   InputKey   // keyboard: the key/modifier combination
	mouse InputMouse // mouse: the mouse event
}

// InputParser parses VT sequences into input events.
// It owns the underlying VT parser.
pub struct InputParser {
mut:
	vt                  VtParser
	bracketed_paste     bool
	bracketed_paste_buf []u8
	x10_mouse_want      bool
	x10_mouse_buf       [3]rune
	x10_mouse_len       int
}

// new_input_parser creates a new parser that turns VT sequences into input events.
// Keep the instance alive for the lifetime of the input stream.
pub fn new_input_parser() InputParser {
	return InputParser{}
}

// parse feeds a chunk of raw terminal input and returns all input events it contains.
//
// You should call this even if your read() had a timeout (pass an empty string
// in that case), so that a pending ESC can be resolved as a literal Escape keypress.
// Use vt.read_timeout_ms() to determine the timeout.
pub fn (mut p InputParser) parse(input string) []Input {
	p.vt.feed(input)
	mut inputs := []Input{}
	for {
		ev := p.next() or { break }
		inputs << ev
	}
	return inputs
}

// next parses the next input event from the previously fed input.
fn (mut p InputParser) next() ?Input {
	// Maps SS3/CSI final bytes A-H to vk_* key codes (0 = unmapped).
	keypad_lut := [u8(vk_up), u8(vk_down), u8(vk_right), u8(vk_left), u8(0), u8(vk_end), u8(0),
		u8(vk_home)]

	for {
		if p.bracketed_paste {
			return p.handle_bracketed_paste()
		}

		if p.x10_mouse_want {
			return p.parse_x10_mouse_coordinates()
		}

		token := p.vt.next() or { return none }

		match token.kind {
			.text {
				return Input{
					kind: .text
					text: token.text
				}
			}
			.ctrl {
				ch := token.ch
				if ch == 0 {
					// Both Ctrl+Space and Ctrl+Shift+2 produce \0, and
					// Ctrl+Space is probably the more common of the two.
					return Input{
						kind: .keyboard
						key:  kbmod_ctrl | vk_space
					}
				}
				if ch == `\t` || ch == `\r` {
					return Input{
						kind: .keyboard
						key:  InputKey(u32(ch))
					}
				}
				if ch == `\n` {
					return Input{
						kind: .keyboard
						key:  kbmod_ctrl | vk_return
					}
				}
				if ch <= 0x1a {
					// Shift control code to A-Z.
					return Input{
						kind: .keyboard
						key:  kbmod_ctrl | InputKey(u32(ch) | 0x40)
					}
				}
				if ch == 0x7f {
					return Input{
						kind: .keyboard
						key:  vk_back
					}
				}
			}
			.esc {
				ch := token.ch
				if ch == 0 {
					return Input{
						kind: .keyboard
						key:  vk_escape
					}
				}
				if ch == `\n` {
					return Input{
						kind: .keyboard
						key:  kbmod_ctrl_alt | vk_return
					}
				}
				if ch >= ` ` && ch <= `~` {
					c := u32(ch)
					key := c & ~u32(0x20) // Shift a-z to A-Z
					modifiers := if (c & 0x20) != 0 { kbmod_alt } else { kbmod_alt_shift }
					return Input{
						kind: .keyboard
						key:  modifiers | InputKey(key)
					}
				}
			}
			.ss3 {
				ch := token.ch
				if ch >= `A` && ch <= `H` {
					vk := keypad_lut[int(ch - `A`)]
					if vk != 0 {
						return Input{
							kind: .keyboard
							key:  InputKey(vk)
						}
					}
				} else if ch >= `P` && ch <= `S` {
					key := vk_f1 + u32(ch - `P`)
					return Input{
						kind: .keyboard
						key:  InputKey(key)
					}
				}
			}
			.csi {
				csi := token.csi
				fb := csi.final_byte
				if fb >= `A` && fb <= `H` {
					vk := keypad_lut[int(fb - `A`)]
					if vk != 0 {
						return Input{
							kind: .keyboard
							key:  InputKey(vk) | parse_modifiers(csi)
						}
					}
				} else if fb == `Z` {
					return Input{
						kind: .keyboard
						key:  kbmod_shift | vk_tab
					}
				} else if fb == `~` {
					// Maps CSI ~ parameters to vk_* key codes (0 = unmapped).
					lut := [
						u8(0),
						u8(vk_home), // 1
						u8(vk_insert), // 2
						u8(vk_delete), // 3
						u8(vk_end), // 4
						u8(vk_prior), // 5
						u8(vk_next), // 6
						u8(0),
						u8(0),
						u8(0),
						u8(0),
						u8(0),
						u8(0),
						u8(0),
						u8(0),
						u8(vk_f5), // 15
						u8(0),
						u8(vk_f6), // 17
						u8(vk_f7), // 18
						u8(vk_f8), // 19
						u8(vk_f9), // 20
						u8(vk_f10), // 21
						u8(0),
						u8(vk_f11), // 23
						u8(vk_f12), // 24
						u8(vk_f13), // 25
						u8(vk_f14), // 26
						u8(0),
						u8(vk_f15), // 28
						u8(vk_f16), // 29
						u8(0),
						u8(vk_f17), // 31
						u8(vk_f18), // 32
						u8(vk_f19), // 33
						u8(vk_f20), // 34
					]
					p0 := csi.params[0]
					if p0 < lut.len {
						vk := lut[int(p0)]
						if vk != 0 {
							return Input{
								kind: .keyboard
								key:  InputKey(vk) | parse_modifiers(csi)
							}
						}
					} else if p0 == 200 {
						p.bracketed_paste = true
					}
				} else if (fb == `m` || fb == `M`) && csi.private_byte == `<` {
					return parse_xterm_mouse(csi.params[..csi.param_count], fb)
				} else if fb == `M` && csi.param_count == 0 {
					p.x10_mouse_want = true
				} else if fb == `t` && csi.params[0] == 8 {
					// Window size report.
					width := clamp_coord(CoordType(csi.params[2]), 1, 32767)
					height := clamp_coord(CoordType(csi.params[1]), 1, 32767)
					return Input{
						kind: .resize
						size: Size{
							width:  width
							height: height
						}
					}
				}
			}
			else {}
		}
	}
	return none // unreachable; satisfies the V checker's return analysis
}

// handle_bracketed_paste seeks to the end of a bracketed paste.
//
// A bracketed paste is basically:
// ```text
// <ESC>[200~    lots of text    <ESC>[201~
// ```
//
// That in-between text is then expected to be taken literally.
// It can be in between anything though, including other escape sequences.
// This is the reason why this is a separate method.
fn (mut p InputParser) handle_bracketed_paste() ?Input {
	beg := p.vt.off
	mut end := beg

	for {
		token := p.vt.next() or { break }
		if token.kind == .csi && token.csi.final_byte == `~` && token.csi.params[0] == 201 {
			p.bracketed_paste = false
			break
		}
		end = p.vt.off
	}

	if end != beg {
		p.bracketed_paste_buf << p.vt.input[beg..end].bytes()
	}

	if !p.bracketed_paste {
		data := p.bracketed_paste_buf.clone()
		p.bracketed_paste_buf = []u8{}
		return Input{
			kind: .paste
			data: data
		}
	}
	return none
}

// parse_x10_mouse_coordinates implements the X10 mouse protocol via `CSI M CbCxCy`.
//
// You want to send numeric mouse coordinates.
// You have CSI sequences with numeric parameters.
// So, of course you put the coordinates as shifted ASCII characters after
// the end of the sequence. Limited coordinate range and complicated parsing!
fn (mut p InputParser) parse_x10_mouse_coordinates() ?Input {
	for p.x10_mouse_len < 3 && !p.vt.done() {
		p.x10_mouse_buf[p.x10_mouse_len] = p.vt.next_char()
		p.x10_mouse_len++
	}
	if p.x10_mouse_len < 3 {
		return none
	}

	b := u16(p.x10_mouse_buf[0]) - 0x20
	x := u16(p.x10_mouse_buf[1]) - 0x20
	y := u16(p.x10_mouse_buf[2]) - 0x20

	p.x10_mouse_want = false
	p.x10_mouse_len = 0

	return parse_xterm_mouse([b, x, y], `M`)
}

fn parse_modifiers(csi Csi) u32 {
	mut modifiers := kbmod_none
	// saturating_sub(1): an absent second parameter means no modifiers.
	p1 := if csi.params[1] > 0 { csi.params[1] - 1 } else { u16(0) }
	if (p1 & 0x01) != 0 {
		modifiers |= kbmod_shift
	}
	if (p1 & 0x02) != 0 {
		modifiers |= kbmod_alt
	}
	if (p1 & 0x04) != 0 {
		modifiers |= kbmod_ctrl
	}
	return modifiers
}

fn parse_xterm_mouse(params []u16, final_byte u8) ?Input {
	shift := u16(0x04)
	alt := u16(0x08)
	ctrl := u16(0x10)
	motion := u16(0x20)
	wheel := u16(0x40)
	modifiers_mask := shift | alt | ctrl

	if params.len < 3 {
		return none
	}
	btn := params[0]
	x := CoordType(params[1]) - 1
	y := CoordType(params[2]) - 1

	kind := btn & ~modifiers_mask
	mut mouse := InputMouse{
		state:     .none
		modifiers: kbmod_none
		position:  Point{
			x: x
			y: y
		}
		drag:      false
	}

	if final_byte == `m` {
		// M = down, m = release.
		// input.rs indicates release by the absence of buttons being held,
		// which is InputMouseState::None. This makes it more reliable.
	} else if kind >= wheel && kind < wheel + 4 {
		delta := if (btn & 0x01) != 0 { CoordType(1) } else { CoordType(-1) }
		idx := if (btn & (0x02 | shift)) != 0 { 0 } else { 1 }
		if idx == 0 {
			mouse.scroll.x += delta
		} else {
			mouse.scroll.y += delta
		}
		mouse.state = .scroll
	} else if (kind & ~motion) < 3 {
		match kind & 3 {
			0 { mouse.state = .left }
			1 { mouse.state = .middle }
			2 { mouse.state = .right }
			else {}
		}
		mouse.drag = (kind & motion) != 0
	}

	mut mods := kbmod_none
	if (btn & shift) != 0 {
		mods |= kbmod_shift
	}
	if (btn & alt) != 0 {
		mods |= kbmod_alt
	}
	if (btn & ctrl) != 0 {
		mods |= kbmod_ctrl
	}
	mouse.modifiers = mods

	return Input{
		kind:  .mouse
		mouse: mouse
	}
}

fn clamp_coord(v CoordType, min CoordType, max CoordType) CoordType {
	if v < min {
		return min
	}
	if v > max {
		return max
	}
	return v
}
