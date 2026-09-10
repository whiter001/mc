module main

import encoding.iconv

// EncodingInfo is the deliberately small, portable encoding set exposed by
// the first-version picker. iconv supplies the conversion backend on macOS and
// Linux; the editor core continues to store only valid UTF-8.
struct EncodingInfo {
	label     string
	canonical string
}

const editor_encodings = [
	EncodingInfo{ label: 'UTF-8', canonical: 'UTF-8' },
	EncodingInfo{ label: 'UTF-8 BOM', canonical: 'UTF-8 BOM' },
	EncodingInfo{ label: 'UTF-16 LE', canonical: 'UTF-16LE' },
	EncodingInfo{ label: 'UTF-16 BE', canonical: 'UTF-16BE' },
	EncodingInfo{ label: 'UTF-32 LE', canonical: 'UTF-32LE' },
	EncodingInfo{ label: 'UTF-32 BE', canonical: 'UTF-32BE' },
	EncodingInfo{ label: 'GB18030', canonical: 'GB18030' },
]!

fn encoding_is_supported(name string) bool {
	for enc in editor_encodings {
		if enc.canonical == name {
			return true
		}
	}
	return false
}

// detect_file_encoding returns the BOM-selected encoding, or UTF-8 when no
// supported BOM is present. UTF-16/32 and GB18030 are only auto-detected by
// BOM; files without one can still be opened explicitly through Reopen.
fn detect_file_encoding(bytes []u8) string {
	if bytes.len >= 4 {
		if bytes[0] == 0xff && bytes[1] == 0xfe && bytes[2] == 0 && bytes[3] == 0 {
			return 'UTF-32LE'
		}
		if bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0xfe && bytes[3] == 0xff {
			return 'UTF-32BE'
		}
		if bytes[0] == 0x84 && bytes[1] == 0x31 && bytes[2] == 0x95 && bytes[3] == 0x33 {
			return 'GB18030'
		}
	}
	if bytes.len >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf {
		return 'UTF-8 BOM'
	}
	if bytes.len >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe {
		return 'UTF-16LE'
	}
	if bytes.len >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff {
		return 'UTF-16BE'
	}
	return 'UTF-8'
}

fn encoding_payload(bytes []u8, encoding string) []u8 {
	mut skip := 0
	match encoding {
		'UTF-8 BOM' {
			if bytes.len >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf {
				skip = 3
			}
		}
		'UTF-16LE' {
			if bytes.len >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe {
				skip = 2
			}
		}
		'UTF-16BE' {
			if bytes.len >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff {
				skip = 2
			}
		}
		'UTF-32LE' {
			if bytes.len >= 4 && bytes[0] == 0xff && bytes[1] == 0xfe && bytes[2] == 0
				&& bytes[3] == 0 {
				skip = 4
			}
		}
		'UTF-32BE' {
			if bytes.len >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0xfe
				&& bytes[3] == 0xff {
				skip = 4
			}
		}
		'GB18030' {
			if bytes.len >= 4 && bytes[0] == 0x84 && bytes[1] == 0x31 && bytes[2] == 0x95
				&& bytes[3] == 0x33 {
				skip = 4
			}
		}
		else {}
	}
	return bytes[skip..].clone()
}

// decode_file converts file bytes to strict UTF-8 and removes a recognized
// BOM. Conversion errors are returned to the caller; lossy decoding is never
// used for disk input.
fn decode_file(bytes []u8, encoding string) !string {
	if !encoding_is_supported(encoding) {
		return error('unsupported encoding: ${encoding}')
	}
	payload := encoding_payload(bytes, encoding)
	source := if encoding == 'UTF-8 BOM' { 'UTF-8' } else { encoding }
	return iconv.encoding_to_vstring(payload, source) or {
		return error('invalid ${encoding} input: ${err}')
	}
}

fn encoding_bom(encoding string) []u8 {
	return match encoding {
		'UTF-8 BOM' { [u8(0xef), 0xbb, 0xbf] }
		'UTF-16LE' { [u8(0xff), 0xfe] }
		'UTF-16BE' { [u8(0xfe), 0xff] }
		'UTF-32LE' { [u8(0xff), 0xfe, 0, 0] }
		'UTF-32BE' { [u8(0), 0, 0xfe, 0xff] }
		'GB18030' { [u8(0x84), 0x31, 0x95, 0x33] }
		else { []u8{} }
	}
}

// encode_text converts valid editor UTF-8 to the selected on-disk encoding.
// The non-UTF-8 formats include their conventional BOM, matching the Rust
// implementation's write policy and making subsequent auto-detection safe.
fn encode_text(text string, encoding string) ![]u8 {
	if !encoding_is_supported(encoding) {
		return error('unsupported encoding: ${encoding}')
	}
	mut payload := if encoding.starts_with('UTF-8') {
		text.bytes()
	} else {
		iconv.vstring_to_encoding(text, encoding) or {
			return error('cannot encode as ${encoding}: ${err}')
		}
	}
	mut out := encoding_bom(encoding)
	out << payload
	return out
}
