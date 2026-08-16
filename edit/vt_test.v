module main

fn test_vt_text() {
	mut p := new_vt_parser()
	tokens := p.parse('hello')
	assert tokens.len == 1
	assert tokens[0].kind == .text
	assert tokens[0].text == 'hello'
}

fn test_vt_text_and_ctrl() {
	mut p := new_vt_parser()
	tokens := p.parse('a\x01b\x7fc')
	assert tokens.len == 5
	assert tokens[0].kind == .text && tokens[0].text == 'a'
	assert tokens[1].kind == .ctrl && tokens[1].ch == 0x01
	assert tokens[2].kind == .text && tokens[2].text == 'b'
	assert tokens[3].kind == .ctrl && tokens[3].ch == 0x7f
	assert tokens[4].kind == .text && tokens[4].text == 'c'
}

fn test_vt_csi_arrow_keys() {
	mut p := new_vt_parser()
	for seq in ['\x1b[A', '\x1b[B', '\x1b[C', '\x1b[D'] {
		tokens := p.parse(seq)
		assert tokens.len == 1
		assert tokens[0].kind == .csi
		assert tokens[0].csi.final_byte == seq[2]
		assert tokens[0].csi.param_count == 0
		assert tokens[0].csi.private_byte == 0
	}
}

fn test_vt_csi_params() {
	mut p := new_vt_parser()
	tokens := p.parse('\x1b[1;5H')
	assert tokens.len == 1
	assert tokens[0].kind == .csi
	assert tokens[0].csi.final_byte == `H`
	assert tokens[0].csi.param_count == 2
	assert tokens[0].csi.params[0] == 1
	assert tokens[0].csi.params[1] == 5
	assert tokens[0].csi.private_byte == 0
}

fn test_vt_csi_private_byte() {
	mut p := new_vt_parser()
	tokens := p.parse('\x1b[<0;10;5M')
	assert tokens.len == 1
	assert tokens[0].kind == .csi
	assert tokens[0].csi.private_byte == `<`
	assert tokens[0].csi.final_byte == `M`
	assert tokens[0].csi.param_count == 3
	assert tokens[0].csi.params[0] == 0
	assert tokens[0].csi.params[1] == 10
	assert tokens[0].csi.params[2] == 5
}

fn test_vt_csi_param_clamping() {
	mut p := new_vt_parser()
	tokens := p.parse('\x1b[999999999H')
	assert tokens.len == 1
	assert tokens[0].csi.params[0] == 65535
}

fn test_vt_ss3() {
	mut p := new_vt_parser()
	tokens := p.parse('\x1bOA')
	assert tokens.len == 1
	assert tokens[0].kind == .ss3
	assert tokens[0].ch == `A`
}

fn test_vt_esc_char() {
	mut p := new_vt_parser()
	tokens := p.parse('\x1ba')
	assert tokens.len == 1
	assert tokens[0].kind == .esc
	assert tokens[0].ch == `a`
}

fn test_vt_esc_timeout() {
	mut p := new_vt_parser()
	// A lone ESC is ambiguous: no token yet, but a read timeout is suggested.
	assert p.parse('\x1b').len == 0
	assert p.read_timeout_ms() == vt_esc_timeout_ms
	// After a timeout the caller feeds an empty string:
	// the ESC is resolved as a literal Escape keypress.
	tokens := p.parse('')
	assert tokens.len == 1
	assert tokens[0].kind == .esc
	assert tokens[0].ch == 0
	assert p.read_timeout_ms() == vt_no_timeout
}

fn test_vt_osc_bel_terminated() {
	mut p := new_vt_parser()
	tokens := p.parse('\x1b]0;title\x07')
	assert tokens.len == 1
	assert tokens[0].kind == .osc
	assert tokens[0].text == '0;title'
	assert !tokens[0].partial
}

fn test_vt_osc_st_terminated() {
	mut p := new_vt_parser()
	tokens := p.parse('\x1b]8;;http://x\x1b\\')
	assert tokens.len == 1
	assert tokens[0].kind == .osc
	assert tokens[0].text == '8;;http://x'
	assert !tokens[0].partial
}

fn test_vt_osc_partial_across_chunks() {
	mut p := new_vt_parser()
	tokens1 := p.parse('\x1b]0;ti')
	assert tokens1.len == 1
	assert tokens1[0].kind == .osc
	assert tokens1[0].text == '0;ti'
	assert tokens1[0].partial
	tokens2 := p.parse('tle\x07')
	assert tokens2.len == 1
	assert tokens2[0].kind == .osc
	assert tokens2[0].text == 'tle'
	assert !tokens2[0].partial
}

fn test_vt_osc_esc_split_across_chunks() {
	mut p := new_vt_parser()
	// The ST terminator (\x1b\) is split across two chunks.
	tokens1 := p.parse('\x1b]0;ab\x1b')
	assert tokens1.len == 1
	assert tokens1[0].kind == .osc
	assert tokens1[0].text == '0;ab'
	assert tokens1[0].partial
	tokens2 := p.parse('\\')
	assert tokens2.len == 1
	assert tokens2[0].kind == .osc
	assert tokens2[0].text == ''
	assert !tokens2[0].partial
}

fn test_vt_dcs() {
	mut p := new_vt_parser()
	tokens := p.parse('\x1bPq123\x1b\\')
	assert tokens.len == 1
	assert tokens[0].kind == .dcs
	assert tokens[0].text == 'q123'
	assert !tokens[0].partial
}

fn test_vt_csi_split_across_chunks() {
	mut p := new_vt_parser()
	// An escape sequence spanning two parse() calls.
	assert p.parse('\x1b[1;').len == 0
	tokens := p.parse('2H')
	assert tokens.len == 1
	assert tokens[0].kind == .csi
	assert tokens[0].csi.final_byte == `H`
	assert tokens[0].csi.param_count == 2
	assert tokens[0].csi.params[0] == 1
	assert tokens[0].csi.params[1] == 2
}

fn test_vt_streaming_multiple_sequences() {
	mut p := new_vt_parser()
	assert p.parse('foo\x1b[').len == 1 // text 'foo', CSI pending
	tokens := p.parse('A') // completes the pending CSI
	assert tokens.len == 1
	assert tokens[0].kind == .csi
	assert tokens[0].csi.final_byte == `A`
}
