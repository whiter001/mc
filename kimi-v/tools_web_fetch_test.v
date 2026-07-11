// tools_web_fetch_test.v — unit tests for HTML-to-text conversion.
//
// The web_fetch tool's network code is hard to test without a server, so
// we focus on the pure parsing/transform helpers (html_to_text,
// decode_html_entities, collapse_whitespace). These are what determine
// the quality of fetched documentation pages.
module main

import json

// ---------- html_to_text --------------------------------------------------

fn test_html_to_text_strips_simple_tags() {
	inp := '<p>hello world</p>'
	out := html_to_text(inp)
	assert out.contains('hello world')
	assert !out.contains('<p>')
}

fn test_html_to_text_block_tags_produce_newlines() {
	inp := '<p>first paragraph</p><p>second paragraph</p>'
	out := html_to_text(inp)
	// Newlines should separate paragraphs.
	assert out.contains('first paragraph\n') || out.contains('\nfirst paragraph')
	assert out.contains('second paragraph')
}

fn test_html_to_text_strips_script_content() {
	inp := '<p>before</p><script>alert("xss")</script><p>after</p>'
	out := html_to_text(inp)
	assert out.contains('before')
	assert out.contains('after')
	assert !out.contains('alert')
	assert !out.contains('xss')
}

fn test_html_to_text_strips_style_content() {
	inp := '<p>visible</p><style>body { color: red; }</style><p>also visible</p>'
	out := html_to_text(inp)
	assert out.contains('visible')
	assert out.contains('also visible')
	assert !out.contains('color: red')
	assert !out.contains('body {')
}

fn test_html_to_text_br_produces_newline() {
	inp := 'line one<br>line two<br/>line three'
	out := html_to_text(inp)
	assert out.contains('line one')
	assert out.contains('line two')
	assert out.contains('line three')
	// Each <br> should produce a newline.
	assert out.split('\n').len >= 3
}

fn test_html_to_text_collapses_runs_of_newlines() {
	inp := '<p>a</p>\n\n\n\n\n<p>b</p>'
	out := html_to_text(inp)
	// 3+ newlines should become 2 (single paragraph break).
	assert !out.contains('\n\n\n')
}

fn test_html_to_text_handles_headings() {
	inp := '<h1>Title</h1><p>body</p>'
	out := html_to_text(inp)
	assert out.contains('Title')
	assert out.contains('body')
}

fn test_html_to_text_realistic_page() {
	inp := '<!DOCTYPE html><html><head><title>T</title></head>
	<body>
	<h1>Getting Started</h1>
	<p>This is a <strong>bold</strong> intro.</p>
	<ul>
	<li>First item</li>
	<li>Second item with <em>emphasis</em></li>
	</ul>
	<script>console.log("hi")</script>
	<style>p { margin: 0 }</style>
	</body></html>'
	out := html_to_text(inp)
	assert out.contains('Getting Started')
	assert out.contains('This is a')
	assert out.contains('bold')
	assert out.contains('First item')
	assert out.contains('Second item')
	assert out.contains('emphasis')
	assert !out.contains('console.log')
	assert !out.contains('margin: 0')
}

// ---------- decode_html_entities ------------------------------------------

fn test_decode_named_entities() {
	assert decode_html_entities('a &amp; b') == 'a & b'
	assert decode_html_entities('&lt;tag&gt;') == '<tag>'
	assert decode_html_entities('&quot;hi&quot;') == '"hi"'
	assert decode_html_entities('it&apos;s') == "it's"
	assert decode_html_entities('a&nbsp;b') == 'a b'
}

fn test_decode_numeric_entities() {
	// é = U+00E9 = &#233;
	assert decode_html_entities('caf&#233;') == 'café'
	// 中 = U+4E2D = &#20013;
	assert decode_html_entities('&#20013;') == '中'
}

fn test_decode_hex_entities() {
	// é = U+00E9 = &#xE9;
	assert decode_html_entities('caf&#xE9;') == 'café'
}

fn test_decode_passthrough_for_unknown() {
	// Unknown entities pass through literally (we only handle the common
	// ones; exotic entities would be replaced with utf8 char by browsers,
	// but we don't have a full lookup table).
	v := decode_html_entities('&foo;')
	assert v == '&foo;'
}

fn test_decode_ampersand_without_semicolon() {
	// & without trailing ; is a literal &.
	assert decode_html_entities('A & B') == 'A & B'
}

// ---------- collapse_whitespace -------------------------------------------

fn test_collapse_preserves_single_newlines() {
	assert collapse_whitespace('a\nb') == 'a\nb'
}

fn test_collapse_caps_consecutive_newlines_at_2() {
	assert collapse_whitespace('a\n\n\n\n\nb') == 'a\n\nb'
}

fn test_collapse_drops_leading_trailing_whitespace_per_line() {
	// Trailing space before \n is dropped.
	assert collapse_whitespace('a   \nb') == 'a\nb'
}

fn test_collapse_handles_empty() {
	assert collapse_whitespace('') == ''
}

// ---------- parse_int_or_zero ---------------------------------------------

fn test_parse_decimal() {
	assert parse_int_or_zero('123', false) == 123
	assert parse_int_or_zero('0', false) == 0
}

fn test_parse_hex() {
	assert parse_int_or_zero('ff', true) == 255
	assert parse_int_or_zero('E9', true) == 233
	assert parse_int_or_zero('0', true) == 0
}

fn test_parse_invalid_returns_zero() {
	assert parse_int_or_zero('12x', false) == 0
	assert parse_int_or_zero('', false) == 0
	assert parse_int_or_zero('xyz', true) == 0
}

// ---------- end-to-end: tool argument validation --------------------------
//
// We can't easily test execute() (it hits the network), but we can verify
// the parameter schema is well-formed JSON with the required fields.

fn test_webfetch_schema_is_valid_json() {
	tool := WebFetchTool{}
	schema := tool.parameters_schema()
	// Lightweight sanity check: the schema should parse and look like an
	// object schema. We don't pull in a full JSON AST here.
	parsed := json.decode(map[string]string, schema) or {
		assert false, 'schema is not valid JSON: ${err.msg()}'
		return
	}
	assert parsed['type'] == 'object'
}

fn test_webfetch_schema_requires_url() {
	tool := WebFetchTool{}
	schema := tool.parameters_schema()
	assert schema.contains('"url"')
	assert schema.contains('"required"')
}
