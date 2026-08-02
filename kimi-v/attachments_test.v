// attachments_test.v — unit tests for the image-attachment wire format
// and the path / mime helpers used by InputBuf.attach_file.
//
// These tests are the regression guard for the OpenAI-compatible
// content-parts array shape. The shape is the contract with every
// provider we talk to (Kimi, DeepSeek, OpenRouter, OpenAI itself),
// so a change here that breaks even one provider silently — we want
// loud failures, not "the assistant just said it couldn't see the
// image".
module main

import json2
import os

// ---------- mime_for_image_ext (table-driven) ----------------------------

fn test_mime_for_image_ext_recognized() {
	// All the image extensions we accept. Add a new one here when
	// extending mime_for_image_ext — keeps the map and the test in
	// lock-step.
	assert mime_for_image_ext('png') == 'image/png'
	assert mime_for_image_ext('jpg') == 'image/jpeg'
	assert mime_for_image_ext('jpeg') == 'image/jpeg'
	assert mime_for_image_ext('gif') == 'image/gif'
	assert mime_for_image_ext('webp') == 'image/webp'
	assert mime_for_image_ext('bmp') == 'image/bmp'
}

fn test_mime_for_image_ext_unknown_returns_empty() {
	// Unknown extensions must return '' so attach_file treats them
	// as a rejection (not as a "trust the user" pass-through).
	assert mime_for_image_ext('txt') == ''
	assert mime_for_image_ext('pdf') == ''
	assert mime_for_image_ext('svg') == ''
	assert mime_for_image_ext('') == ''
}

// ---------- attachment_ext / attachment_basename -------------------------

fn test_attachment_ext_lowercases() {
	// PNG / Png / pNg all map to the same extension so the mime
	// lookup is case-insensitive (macOS HFS+ is case-insensitive
	// by default; users routinely have mixed-case suffixes).
	assert attachment_ext('foo.PNG') == 'png'
	assert attachment_ext('foo.Png') == 'png'
	assert attachment_ext('foo.png') == 'png'
}

fn test_attachment_ext_no_extension() {
	// No dot → no extension. The filter should not synthesize one.
	assert attachment_ext('foo') == ''
	assert attachment_ext('/foo/bar') == ''
}

fn test_attachment_ext_dotfile() {
	// A leading dot is the basename, not an extension. ".bashrc" is
	// a file named ".bashrc" with no extension.
	assert attachment_ext('.bashrc') == ''
}

fn test_attachment_basename_strips_directories() {
	// For display, only the last path segment matters. kimi-v is
	// POSIX-only, so a single split on '/' is correct.
	assert attachment_basename('/foo/bar/baz.png') == 'baz.png'
	assert attachment_basename('baz.png') == 'baz.png'
	assert attachment_basename('/foo/') == ''
}

// ---------- resolve_attach_path -----------------------------------------

fn test_resolve_attach_path_absolute_passthrough() {
	// Absolute paths bypass cwd / home expansion.
	assert resolve_attach_path('/anywhere', '/etc/hosts') == '/etc/hosts'
}

fn test_resolve_attach_path_home_relative_expands() {
	// "~/foo" should expand against the user's home dir.
	resolved := resolve_attach_path('/anywhere', '~/foo.png')
	expected := os.join_path(os.home_dir(), 'foo.png')
	assert resolved == expected
}

fn test_resolve_attach_path_relative_joins_cwd() {
	// "./foo" and "../foo" both resolve against cwd.
	assert resolve_attach_path('/tmp', './foo.png') == '/tmp/foo.png'
	assert resolve_attach_path('/tmp', '../foo.png') == '/tmp/../foo.png'
}

// ---------- build_content_parts (wire shape) -----------------------------

fn test_build_content_parts_text_only() {
	// A text-only message should produce exactly one text part with
	// the original content. This is the common case — every chat
	// message that doesn't carry an image.
	parts := build_content_parts(Message{
		role:    .user
		content: 'hello world'
	})
	assert parts.len == 1
	assert parts[0].typ == 'text'
	assert parts[0].text or { '' } == 'hello world'
	if _ := parts[0].image_url {
		assert false, 'text part must not have image_url set'
	}
}

fn test_build_content_parts_with_image() {
	// A multimodal message: one text part + one image_url part, in
	// that order. The data URL is data:<mime>;base64,<b64> as
	// required by the OpenAI spec.
	parts := build_content_parts(Message{
		role:    .user
		content: 'look at this'
		attachments: [
			Attachment{ mime: 'image/png', b64: 'AAAA', name: 'shot.png' },
		]
	})
	assert parts.len == 2
	assert parts[0].typ == 'text'
	assert parts[0].text or { '' } == 'look at this'
	assert parts[1].typ == 'image_url'
	if _ := parts[1].text {
		assert false, 'image_url part must not have text set'
	}
	url := (parts[1].image_url or { return }).url
	assert url == 'data:image/png;base64,AAAA'
}

fn test_build_content_parts_empty_falls_back_to_empty_text() {
	// Empty text + no attachments is a degenerate case (the user
	// submitted without typing anything). The OpenAI API rejects
	// `content: []` so we emit a single empty text part as a
	// graceful fallback. The model will see an empty user turn.
	parts := build_content_parts(Message{
		role:    .user
		content: ''
	})
	assert parts.len == 1
	assert parts[0].typ == 'text'
	assert parts[0].text or { '' } == ''
}

fn test_build_content_parts_image_only_no_text() {
	// The user attached an image without any text — common in
	// vision workflows ("what's in this screenshot?"). The text
	// part is omitted; only the image_url part appears.
	parts := build_content_parts(Message{
		role:    .user
		content: ''
		attachments: [
			Attachment{ mime: 'image/jpeg', b64: 'BBBB', name: 'a.jpg' },
		]
	})
	assert parts.len == 1
	assert parts[0].typ == 'image_url'
	url := (parts[0].image_url or { return }).url
	assert url == 'data:image/jpeg;base64,BBBB'
}

fn test_build_content_parts_wire_json_shape() {
	// End-to-end: encode the parts list and confirm the JSON shape
	// matches the OpenAI multimodal spec. This is the contract with
	// every provider we talk to — a regression here breaks the
	// feature for all of them silently.
	parts := build_content_parts(Message{
		role:    .user
		content: 'hi'
		attachments: [
			Attachment{ mime: 'image/png', b64: 'AAAA', name: 'a.png' },
		]
	})
	wire := json2.encode(parts)
	// Expected: [{"type":"text","text":"hi"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]
	// The text part is first; image_url is second; both have their
	// own field set and the other's field absent (V's json encoder
	// omits `?T` fields set to `none`).
	assert wire.contains('"type":"text"')
	assert wire.contains('"text":"hi"')
	assert wire.contains('"type":"image_url"')
	assert wire.contains('"url":"data:image/png;base64,AAAA"')
	// And the text part has no image_url field at all.
	text_end := wire.index('"text":"hi"') or { return }
	image_start := wire.index('"type":"image_url"') or { return }
	slice := wire[text_end..image_start]
	assert !slice.contains('image_url'), 'text part should not carry image_url: ${slice}'
}

// ---------- b64_decoded_size / human_bytes (render hints) ----------------

fn test_b64_decoded_size_basic() {
	// 4 base64 chars → 3 bytes. "AAAA" decodes to 3 zero bytes.
	assert b64_decoded_size('AAAA') == 3
	// 8 base64 chars → 6 bytes.
	assert b64_decoded_size('AAAAAAAA') == 6
	// Padding-aware: "QQ==" decodes to 1 byte ('A'), not 3.
	assert b64_decoded_size('QQ==') == 1
	// Empty string → 0 bytes.
	assert b64_decoded_size('') == 0
}

fn test_human_bytes_chooses_unit() {
	// Below 1KB → B. 1KB-1MB → KB. Above 1MB → MB. We never see
	// GB in practice (10MB cap) but it's covered for completeness.
	assert human_bytes(0) == '0 B'
	assert human_bytes(512) == '512 B'
	assert human_bytes(1024) == '1 KB'
	assert human_bytes(1536) == '1 KB'
	assert human_bytes(1024 * 1024) == '1 MB'
	assert human_bytes(2 * 1024 * 1024) == '2 MB'
}
