module main

fn test_detect_file_encoding_boms() {
	assert detect_file_encoding([u8(0xef), 0xbb, 0xbf, 0x61]) == 'UTF-8 BOM'
	assert detect_file_encoding([u8(0xff), 0xfe, 0x61, 0]) == 'UTF-16LE'
	assert detect_file_encoding([u8(0xfe), 0xff, 0, 0x61]) == 'UTF-16BE'
	assert detect_file_encoding([u8(0xff), 0xfe, 0, 0, 0x61, 0, 0, 0]) == 'UTF-32LE'
	assert detect_file_encoding([u8(0), 0, 0xfe, 0xff, 0, 0, 0, 0x61]) == 'UTF-32BE'
	assert detect_file_encoding([u8(0x84), 0x31, 0x95, 0x33]) == 'GB18030'
	assert detect_file_encoding('plain'.bytes()) == 'UTF-8'
}

fn test_encoding_round_trips_supported_formats() {
	// This corpus is representable by the platform GB18030 converter too;
	// conversion of unrepresentable codepoints is intentionally an error.
	text := 'Hello, 世界\n'
	for enc in editor_encodings {
		bytes := encode_text(text, enc.canonical) or { panic('${enc.canonical}: ${err}') }
		assert decode_file(bytes, enc.canonical) or { panic('${enc.canonical}: ${err}') } == text
	}
}

fn test_encoding_output_boms() {
	for enc in editor_encodings {
		bytes := encode_text('x', enc.canonical) or { panic(err) }
		bom := encoding_bom(enc.canonical)
		assert bytes.len >= bom.len
		assert bytes[..bom.len] == bom
	}
}

fn test_decode_file_rejects_invalid_input() {
	if _ := decode_file([u8(0xff), 0xff], 'UTF-8') {
		assert false, 'invalid UTF-8 unexpectedly decoded'
	}
	if _ := decode_file([u8(0x61)], 'UTF-16LE') {
		assert false, 'truncated UTF-16 unexpectedly decoded'
	}
}

fn test_encoding_rejects_unknown_name() {
	if _ := decode_file('x'.bytes(), 'UNKNOWN') {
		assert false, 'unknown encoding unexpectedly decoded'
	}
	if _ := encode_text('x', 'UNKNOWN') {
		assert false, 'unknown encoding unexpectedly encoded'
	}
}
