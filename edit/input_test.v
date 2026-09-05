module main

fn test_input_text() {
	mut p := new_input_parser()
	inputs := p.parse('hello')
	assert inputs.len == 1
	assert inputs[0].kind == .text
	assert inputs[0].text == 'hello'
}

fn test_input_arrow_keys_csi() {
	mut p := new_input_parser()
	expected := [vk_up, vk_down, vk_right, vk_left]
	for i, seq in ['\x1b[A', '\x1b[B', '\x1b[C', '\x1b[D'] {
		inputs := p.parse(seq)
		assert inputs.len == 1
		assert inputs[0].kind == .keyboard
		assert inputs[0].key == expected[i]
	}
}

fn test_input_arrow_keys_ss3() {
	mut p := new_input_parser()
	expected := [vk_up, vk_down, vk_right, vk_left]
	for i, seq in ['\x1bOA', '\x1bOB', '\x1bOC', '\x1bOD'] {
		inputs := p.parse(seq)
		assert inputs.len == 1
		assert inputs[0].kind == .keyboard
		assert inputs[0].key == expected[i]
	}
}

fn test_input_ss3_function_keys() {
	mut p := new_input_parser()
	expected := [vk_f1, vk_f2, vk_f3, vk_f4]
	for i, seq in ['\x1bOP', '\x1bOQ', '\x1bOR', '\x1bOS'] {
		inputs := p.parse(seq)
		assert inputs.len == 1
		assert inputs[0].kind == .keyboard
		assert inputs[0].key == expected[i]
	}
}

fn test_input_ctrl_letters() {
	mut p := new_input_parser()
	// \x01 = Ctrl+A .. \x1a = Ctrl+Z (excluding \t \n \r handled separately)
	inputs := p.parse('\x01')
	assert inputs.len == 1
	assert inputs[0].kind == .keyboard
	assert inputs[0].key == kbmod_ctrl | vk_a

	inputs2 := p.parse('\x1a')
	assert inputs2.len == 1
	assert inputs2[0].key == kbmod_ctrl | vk_z

	// Ctrl+Space / Ctrl+Shift+2 produce \0; we map it to Ctrl+Space.
	inputs3 := p.parse('\x00')
	assert inputs3.len == 1
	assert inputs3[0].key == kbmod_ctrl | vk_space
}

fn test_input_special_ctrl_chars() {
	mut p := new_input_parser()
	assert p.parse('\t')[0].key == vk_tab
	assert p.parse('\r')[0].key == vk_return
	assert p.parse('\n')[0].key == kbmod_ctrl | vk_return
	assert p.parse('\x7f')[0].key == vk_back
}

fn test_input_alt_combos() {
	mut p := new_input_parser()
	// Alt+a
	inputs := p.parse('\x1ba')
	assert inputs.len == 1
	assert inputs[0].kind == .keyboard
	assert inputs[0].key == kbmod_alt | vk_a

	// Alt+Shift+A (terminal sends ESC + 'A')
	inputs2 := p.parse('\x1bA')
	assert inputs2.len == 1
	assert inputs2[0].key == kbmod_alt_shift | vk_a

	// Ctrl+Alt+Return (terminal sends ESC + \n)
	inputs3 := p.parse('\x1b\n')
	assert inputs3.len == 1
	assert inputs3[0].key == kbmod_ctrl_alt | vk_return
}

fn test_input_escape_key() {
	mut p := new_input_parser()
	// A lone ESC is ambiguous: nothing yet.
	assert p.parse('\x1b').len == 0
	assert p.vt.read_timeout_ms() == vt_esc_timeout_ms
	// Read timed out: resolve the ESC as a literal Escape keypress.
	inputs := p.parse('')
	assert inputs.len == 1
	assert inputs[0].kind == .keyboard
	assert inputs[0].key == vk_escape
}

fn test_input_csi_modifiers() {
	mut p := new_input_parser()
	// Modifier parameter: 2 = Shift, 3 = Alt, 5 = Ctrl, 6 = Shift+Ctrl ...
	assert p.parse('\x1b[1;2A')[0].key == kbmod_shift | vk_up
	assert p.parse('\x1b[1;3A')[0].key == kbmod_alt | vk_up
	assert p.parse('\x1b[1;5A')[0].key == kbmod_ctrl | vk_up
	assert p.parse('\x1b[1;6A')[0].key == kbmod_ctrl_shift | vk_up
}

fn test_input_csi_tilde_keys() {
	mut p := new_input_parser()
	assert p.parse('\x1b[1~')[0].key == vk_home
	assert p.parse('\x1b[2~')[0].key == vk_insert
	assert p.parse('\x1b[3~')[0].key == vk_delete
	assert p.parse('\x1b[4~')[0].key == vk_end
	assert p.parse('\x1b[5~')[0].key == vk_prior
	assert p.parse('\x1b[6~')[0].key == vk_next
	assert p.parse('\x1b[15~')[0].key == vk_f5
	assert p.parse('\x1b[17~')[0].key == vk_f6
	assert p.parse('\x1b[21~')[0].key == vk_f10
	assert p.parse('\x1b[24~')[0].key == vk_f12
	// With modifiers.
	assert p.parse('\x1b[3;2~')[0].key == kbmod_shift | vk_delete
	assert p.parse('\x1b[5;5~')[0].key == kbmod_ctrl | vk_prior
}

fn test_input_shift_tab() {
	mut p := new_input_parser()
	inputs := p.parse('\x1b[Z')
	assert inputs.len == 1
	assert inputs[0].kind == .keyboard
	assert inputs[0].key == kbmod_shift | vk_tab
}

fn test_input_sgr_mouse_press_release() {
	mut p := new_input_parser()
	// Button 0 (left) pressed at column 10, row 5 (1-based).
	inputs := p.parse('\x1b[<0;10;5M')
	assert inputs.len == 1
	assert inputs[0].kind == .mouse
	mouse := inputs[0].mouse
	assert mouse.state == .left
	assert mouse.position.x == 9
	assert mouse.position.y == 4
	assert !mouse.drag
	assert mouse.modifiers == kbmod_none

	// Release ('m' final byte): no buttons held => state .none.
	inputs2 := p.parse('\x1b[<0;10;5m')
	assert inputs2.len == 1
	mouse2 := inputs2[0].mouse
	assert mouse2.state == .none
	assert mouse2.position.x == 9
	assert mouse2.position.y == 4
}

fn test_input_sgr_mouse_modifiers() {
	mut p := new_input_parser()
	// btn = 20 = 0b10100: Shift(0x04) + Ctrl(0x10), kind = left button.
	inputs := p.parse('\x1b[<20;1;1M')
	assert inputs.len == 1
	mouse := inputs[0].mouse
	assert mouse.state == .left
	assert mouse.modifiers == kbmod_shift | kbmod_ctrl
	assert mouse.position.x == 0
	assert mouse.position.y == 0
}

fn test_input_sgr_mouse_drag() {
	mut p := new_input_parser()
	// btn = 32 = MOTION + left button.
	inputs := p.parse('\x1b[<32;10;5M')
	assert inputs.len == 1
	mouse := inputs[0].mouse
	assert mouse.state == .left
	assert mouse.drag
}

fn test_input_sgr_mouse_scroll() {
	mut p := new_input_parser()
	// btn = 64: wheel up (delta -1 in y).
	inputs := p.parse('\x1b[<64;10;5M')
	assert inputs.len == 1
	mouse := inputs[0].mouse
	assert mouse.state == .scroll
	assert mouse.scroll.y == -1
	assert mouse.scroll.x == 0

	// btn = 65: wheel down (delta +1 in y).
	inputs2 := p.parse('\x1b[<65;10;5M')
	assert inputs2.len == 1
	mouse2 := inputs2[0].mouse
	assert mouse2.state == .scroll
	assert mouse2.scroll.y == 1
}

fn test_input_x10_mouse() {
	mut p := new_input_parser()
	// X10: CSI M followed by 3 bytes (btn, x, y) each offset by 0x20.
	inputs := p.parse('\x1b[M !!')
	assert inputs.len == 1
	assert inputs[0].kind == .mouse
	mouse := inputs[0].mouse
	assert mouse.state == .left
	assert mouse.position.x == 0
	assert mouse.position.y == 0
}

fn test_input_x10_mouse_split_across_chunks() {
	mut p := new_input_parser()
	// The 3 X10 coordinate bytes arrive one chunk at a time.
	assert p.parse('\x1b[M').len == 0
	assert p.parse(' !').len == 0
	inputs := p.parse('!')
	assert inputs.len == 1
	assert inputs[0].kind == .mouse
	assert inputs[0].mouse.state == .left
}

fn test_input_resize() {
	mut p := new_input_parser()
	inputs := p.parse('\x1b[8;24;80t')
	assert inputs.len == 1
	assert inputs[0].kind == .resize
	assert inputs[0].size.width == 80
	assert inputs[0].size.height == 24
}

fn test_input_bracketed_paste() {
	mut p := new_input_parser()
	inputs := p.parse('\x1b[200~hello\x1b[201~')
	assert inputs.len == 1
	assert inputs[0].kind == .paste
	assert inputs[0].data == 'hello'.bytes()
}

fn test_input_bracketed_paste_with_escape_sequences() {
	mut p := new_input_parser()
	// Pasted content must be taken literally, including escape sequences.
	inputs := p.parse('\x1b[200~a\x1b[Ab\x1b[201~')
	assert inputs.len == 1
	assert inputs[0].kind == .paste
	assert inputs[0].data == 'a\x1b[Ab'.bytes()
}

fn test_input_bracketed_paste_split_across_chunks() {
	mut p := new_input_parser()
	assert p.parse('\x1b[200~hel').len == 0
	inputs := p.parse('lo\x1b[201~')
	assert inputs.len == 1
	assert inputs[0].kind == .paste
	assert inputs[0].data == 'hello'.bytes()
}

fn test_input_bracketed_paste_terminator_split() {
	mut p := new_input_parser()
	// The end marker \x1b[201~ itself is split across two chunks.
	assert p.parse('\x1b[200~text\x1b[20').len == 0
	inputs := p.parse('1~')
	assert inputs.len == 1
	assert inputs[0].kind == .paste
	assert inputs[0].data == 'text'.bytes()
}

fn test_input_mixed_stream() {
	mut p := new_input_parser()
	inputs := p.parse('hi\x1b[A\x01')
	assert inputs.len == 3
	assert inputs[0].kind == .text && inputs[0].text == 'hi'
	assert inputs[1].kind == .keyboard && inputs[1].key == vk_up
	assert inputs[2].kind == .keyboard && inputs[2].key == kbmod_ctrl | vk_a
}

// ---- clamp_coord (input.v) -------------------------------------------------

fn test_clamp_coord_in_range() {
	// In-range values pass through unchanged.
	assert clamp_coord(5, 0, 10) == 5
	assert clamp_coord(0, 0, 10) == 0
	assert clamp_coord(10, 0, 10) == 10
}

fn test_clamp_coord_below_min() {
	// Below the minimum clamps up to min.
	assert clamp_coord(-3, 0, 10) == 0
	assert clamp_coord(-100, -50, 50) == -50
}

fn test_clamp_coord_above_max() {
	// Above the maximum clamps down to max.
	assert clamp_coord(15, 0, 10) == 10
	assert clamp_coord(100, -50, 50) == 50
}

fn test_clamp_coord_degenerate_range() {
	// When min == max the value is forced to that single point.
	assert clamp_coord(7, 5, 5) == 5
	assert clamp_coord(0, 5, 5) == 5
}
