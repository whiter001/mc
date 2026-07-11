// tools_web_fetch.v — fetch a URL and return its content as plain text.
//
// Phase 2. HTML is converted to readable text via a small tag stripper
// (no external HTML parser). Good enough for documentation / blog posts
// / READMEs. For complex pages the model can fall back to bash+curl.

module main

import os
import net.http
import json
import strings

// =============================================================================
// web_fetch
// =============================================================================

pub struct WebFetchTool {
pub:
	// Reserved for future: proxy URL, custom UA, etc.
}

pub fn (t WebFetchTool) name() string {
	return 'web_fetch'
}

pub fn (t WebFetchTool) description() string {
	return 'Fetch a URL over HTTP(S) and return its content as plain text. ' +
		'HTML is converted to readable text (tags stripped, script/style removed, ' +
		'entities decoded, whitespace collapsed). Use for documentation, READMEs, ' +
		'blog posts, release notes. Response is capped at 1 MB by default.'
}

pub fn (t WebFetchTool) parameters_schema() string {
	return '{"type":"object","properties":{"url":{"type":"string","description":"HTTP or HTTPS URL to fetch"},' +
		'"max_bytes":{"type":"integer","description":"Optional cap on response size in bytes (default 1048576 = 1 MB)"}},' +
		'"required":["url"],"additionalProperties":false}'
}

pub fn (t WebFetchTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	args_map := json.decode(map[string]string, args.raw) or {
		return ToolResult{
			content:  'invalid arguments: ${err.msg()}'
			is_error: true
		}
	}
	url := args_map['url'] or {
		return ToolResult{
			content:  'missing required argument: url'
			is_error: true
		}
	}
	// Default 1 MB cap. Anything bigger is probably not what the model
	// needs in-context and just wastes tokens.
	max_bytes_str := args_map['max_bytes'] or { '1048576' }
	max_bytes := max_bytes_str.int()
	if max_bytes <= 0 || max_bytes > 10_000_000 {
		return ToolResult{
			content:  'max_bytes out of range: ${max_bytes_str} (must be 1..10000000)'
			is_error: true
		}
	}

	header := http.new_header(
		http.HeaderConfig{ key: .user_agent, value: 'kimi-v/0.1 (+https://github.com/whiter001/mc)' },
		http.HeaderConfig{ key: .accept, value: 'text/html, text/plain, application/xhtml+xml, */*' },
	)

	resp := http.fetch(http.FetchConfig{
		url:    url
		method: .get
		header: header
	}) or {
		return ToolResult{
			content:  'fetch failed: ${err.msg()}'
			is_error: true
		}
	}

	// 2xx success, 3xx (we don't follow but tell the user).
	if resp.status_code >= 300 && resp.status_code < 400 {
		loc := resp.header.get(.location) or { '' }
		return ToolResult{
			content:  'HTTP ${resp.status_code} redirect to: ${loc}\n(fetch does not follow redirects; pass the Location URL directly)'
			is_error: true
		}
	}
	if resp.status_code !in [200, 201, 202, 203, 204] {
		preview := if resp.body.len > 500 { resp.body[..500] + '...' } else { resp.body }
		return ToolResult{
			content:  'HTTP ${resp.status_code}: ${preview}'
			is_error: true
		}
	}

	body := if resp.body.len > max_bytes {
		resp.body[..max_bytes] + '\n[... truncated at ${max_bytes} bytes; full response is ${resp.body.len} bytes ...]'
	} else {
		resp.body
	}

	// Decide whether to convert HTML or pass through.
	ct := resp.header.get(.content_type) or { '' }
	lower_ct := ct.to_lower()
	text := if lower_ct.contains('text/html') || lower_ct.contains('application/xhtml') {
		html_to_text(body)
	} else {
		body
	}

	return ToolResult{ content: text }
}

// =============================================================================
// HTML → text
// =============================================================================

// html_to_text strips HTML tags and decodes common entities. The result is
// readable plain text suitable for the LLM. It's deliberately not a full
// HTML parser — for fidelity we'd need an external dep (html5ever, lol-html),
// and most of what the model cares about (paragraphs, headings, code blocks)
// is preserved by this simple state machine.
//
// Steps:
//   1. Strip <script>...</script> and <style>...</style> blocks entirely.
//   2. Insert newlines for block-level tags (<p>, <br>, <h1-6>, <li>, etc.).
//   3. Drop all other tags.
//   4. Decode named/numeric HTML entities.
//   5. Collapse runs of whitespace.
fn html_to_text(html string) string {
	// Phase 1: drop script/style content.
	cleaned := strip_blocks(html, ['script', 'style'])

	// Phase 2 + 3: walk char-by-char, inserting newlines at block tags
	// and dropping everything else inside tags.
	mut out := strings.new_builder(cleaned.len)
	// V's strings.Builder.str() returns a slice into the buffer, not a
	// copy — calling it mid-loop and then writing again corrupts prior
	// reads. So we track "last char was newline" with a flag, not by
	// inspecting the builder.
	mut prev_was_nl := false
	mut in_tag := false
	mut i := 0
	for i < cleaned.len {
		c := cleaned[i]
		if c == `<` {
			in_tag = true
			// Detect block-level start tag and inject a newline before it.
			rest := cleaned[i..]
			if is_block_start_tag(rest) {
				if !prev_was_nl {
					out.write_string('\n')
					prev_was_nl = true
				}
			}
			// Find end of tag.
			mut j := i + 1
			for j < cleaned.len && cleaned[j] != `>` {
				j++
			}
			if j < cleaned.len {
				// Detect block-level end tag and inject a newline after it.
				tag := cleaned[i..j + 1]
				if is_block_end_tag(tag) {
					if !prev_was_nl {
						out.write_string('\n')
					}
					prev_was_nl = true
				} else {
					prev_was_nl = false
				}
				i = j + 1
			} else {
				// Unterminated tag — emit literally and stop parsing tags.
				in_tag = false
				out.write_string(cleaned[i..])
				i = cleaned.len
				prev_was_nl = false
			}
			in_tag = false
			continue
		}
		if !in_tag {
			out.write_string(c.ascii_str())
			prev_was_nl = c == `\n`
		}
		i++
	}

	// Phase 4: decode entities.
	decoded := decode_html_entities(out.str())

	// Phase 5: collapse whitespace. 3+ newlines → 2 (paragraph break).
	return collapse_whitespace(decoded)
}

// strip_blocks removes <name>...</name> sections case-insensitively.
// Used to drop <script> and <style> content entirely.
fn strip_blocks(html string, names []string) string {
	mut out := html
	for name in names {
		open_lower := '<${name}'
		close_lower := '</${name}>'
		open_upper := '<${name.to_upper()}'
		close_upper := '</${name.to_upper()}>'
		// Iterate; there can be multiple blocks.
		for {
			mut start := index_of_ci(out, open_lower)
			if start < 0 {
				mut s2 := index_of_ci(out, open_upper)
				start = s2
			}
			if start < 0 {
				break
			}
			// Find the end of the opening tag's `>`.
			mut tag_end := start
			for tag_end < out.len && out[tag_end] != `>` {
				tag_end++
			}
			if tag_end >= out.len {
				break
			}
			// Find the matching closing tag.
			mut end := index_of_ci(out[tag_end + 1..], close_lower)
			mut end2 := index_of_ci(out[tag_end + 1..], close_upper)
			// Pick the earliest end.
			mut close_at := -1
			if end >= 0 && end2 >= 0 {
				close_at = if end < end2 { end } else { end2 }
			} else if end >= 0 {
				close_at = end
			} else if end2 >= 0 {
				close_at = end2
			}
			if close_at < 0 {
				break
			}
			// Remove from start..(tag_end + 1 + close_at + len(close))
			abs_end := tag_end + 1 + close_at
			close_tag_len := if end >= 0 && (end2 < 0 || end <= end2) {
				close_lower.len
			} else {
				close_upper.len
			}
			out = out[..start] + out[abs_end + close_tag_len..]
		}
	}
	return out
}

// index_of_ci returns the first case-insensitive occurrence of needle in
// haystack, or -1 if not found. V's built-in index is case-sensitive; this
// helper iterates by hand to keep us off the regex module.
fn index_of_ci(haystack string, needle string) int {
	if needle.len == 0 {
		return 0
	}
	if needle.len > haystack.len {
		return -1
	}
	mut i := 0
	for i <= haystack.len - needle.len {
		if eq_ci(haystack[i..i + needle.len], needle) {
			return i
		}
		i++
	}
	return -1
}

fn eq_ci(a string, b string) bool {
	if a.len != b.len {
		return false
	}
	for i in 0 .. a.len {
		ca := if a[i] >= `A` && a[i] <= `Z` { a[i] + 32 } else { a[i] }
		cb := if b[i] >= `A` && b[i] <= `Z` { b[i] + 32 } else { b[i] }
		if ca != cb {
			return false
		}
	}
	return true
}

const block_start_tags = ['<p ', '<p>', '<br', '<br/', '<br />', '<div', '<h1', '<h2', '<h3',
	'<h4', '<h5', '<h6', '<li', '<ul', '<ol', '<hr', '<hr/', '<hr />', '<pre', '<blockquote',
	'<tr', '<td', '<th', '<table']

const block_end_tags = ['</p>', '</div>', '</h1>', '</h2>', '</h3>', '</h4>', '</h5>', '</h6>',
	'</li>', '</ul>', '</ol>', '</pre>', '</blockquote>', '</tr>', '</td>', '</th>', '</table>']

fn is_block_start_tag(s string) bool {
	for t in block_start_tags {
		if s.starts_with(t) {
			return true
		}
	}
	return false
}

fn is_block_end_tag(s string) bool {
	for t in block_end_tags {
		if s.starts_with(t) {
			return true
		}
	}
	return false
}

// decode_html_entities handles the common named entities plus numeric ones.
// Not exhaustive — we cover what 99% of pages use.
fn decode_html_entities(s string) string {
	mut out := strings.new_builder(s.len)
	mut i := 0
	for i < s.len {
		if s[i] == `&` {
			// Try to find a `;` within the next 8 chars.
			mut end := i + 1
			for end < s.len && end - i < 8 && s[end] != `;` {
				end++
			}
			if end < s.len && s[end] == `;` {
				entity := s[i + 1..end]
				if decoded := decode_entity(entity) {
					out.write_string(decoded)
					i = end + 1
					continue
				}
			}
		}
		out.write_string(s[i].ascii_str())
		i++
	}
	return out.str()
}

fn decode_entity(entity string) ?string {
	match entity {
		'amp' { return '&' }
		'lt' { return '<' }
		'gt' { return '>' }
		'quot' { return '"' }
		'apos' { return "'" }
		'nbsp' { return ' ' }
		'copy' { return '(c)' }
		'reg' { return '(R)' }
		'hellip' { return '...' }
		'mdash' { return '--' }
		'ndash' { return '-' }
		'lsquo' { return "'" }
		'rsquo' { return "'" }
		'ldquo' { return '"' }
		'rdquo' { return '"' }
		else {
			// Numeric: &#NN; or &#xNN;
			if entity.len > 1 && entity[0] == `#` {
				rest := entity[1..]
				is_hex := rest.len > 1 && (rest[0] == `x` || rest[0] == `X`)
				num_str := if is_hex { rest[1..] } else { rest }
				code := parse_int_or_zero(num_str, is_hex)
				if code > 0 {
					return utf8_from_codepoint(code)
				}
			}
			return none
		}
	}
}

fn utf8_from_codepoint(cp int) ?string {
	if cp < 0 {
		return none
	}
	mut bytes := []u8{}
	if cp < 0x80 {
		bytes << u8(cp)
	} else if cp < 0x800 {
		bytes << u8(0xC0 | (cp >> 6))
		bytes << u8(0x80 | (cp & 0x3F))
	} else if cp < 0x10000 {
		bytes << u8(0xE0 | (cp >> 12))
		bytes << u8(0x80 | ((cp >> 6) & 0x3F))
		bytes << u8(0x80 | (cp & 0x3F))
	} else if cp < 0x110000 {
		bytes << u8(0xF0 | (cp >> 18))
		bytes << u8(0x80 | ((cp >> 12) & 0x3F))
		bytes << u8(0x80 | ((cp >> 6) & 0x3F))
		bytes << u8(0x80 | (cp & 0x3F))
	} else {
		return none
	}
	return bytes.bytestr()
}

// parse_int_or_zero parses a decimal or hex string as an int, returning
// 0 on any parse failure (used to skip malformed &#NN; entities silently).
fn parse_int_or_zero(s string, is_hex bool) int {
	mut result := 0
	mut i := 0
	for i < s.len {
		c := s[i]
		mut d := -1
		if c >= `0` && c <= `9` {
			d = int(c - `0`)
		} else if is_hex && c >= `a` && c <= `f` {
			d = int(c - `a`) + 10
		} else if is_hex && c >= `A` && c <= `F` {
			d = int(c - `A`) + 10
		}
		if d < 0 {
			return 0
		}
		if is_hex {
			result = result * 16 + d
		} else {
			result = result * 10 + d
		}
		i++
	}
	return result
}

// collapse_whitespace trims trailing whitespace per line and reduces
// runs of 3+ newlines down to 2 (one paragraph break).
//
// We buffer a single pending space rather than writing it immediately —
// that way "a   \n" becomes "a\n" instead of "a   \n". Same reason as
// html_to_text: avoiding mid-loop reads of the builder's underlying
// buffer, which V returns by reference (not by copy).
fn collapse_whitespace(s string) string {
	mut out := strings.new_builder(s.len)
	mut nl_run := 0
	mut pending_space := false
	for c in s {
		if c == `\n` {
			nl_run++
			pending_space = false
		} else if c == ` ` || c == `\t` {
			pending_space = true
		} else {
			// Flush pending newlines (capped at 2).
			if nl_run > 0 {
				n := if nl_run > 2 { 2 } else { nl_run }
				for _ in 0 .. n {
					out.write_string('\n')
				}
				nl_run = 0
			}
			// Flush pending space.
			if pending_space {
				out.write_string(' ')
				pending_space = false
			}
			out.write_string(c.ascii_str())
		}
	}
	if nl_run > 0 {
		n := if nl_run > 2 { 2 } else { nl_run }
		for _ in 0 .. n {
			out.write_string('\n')
		}
	}
	if pending_space {
		// Trailing space at end of input is dropped.
	}
	return out.str()
}
