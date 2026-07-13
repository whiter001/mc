// tools_web_search.v — web search via DuckDuckGo's HTML endpoint.
//
// Phase 2 (parity with upstream `WebSearch` tool). Unlike web_fetch we
// don't need a real API key: DuckDuckGo's html.duckduckgo.com endpoint
// returns a results page we can scrape. We reuse the HTML→text pipeline
// from tools_web_fetch.v (same `main` module) and then pick out the
// result links + snippets with a tiny tag-aware extractor.

module main

import net.http
import json
import strings

// =============================================================================
// web_search
// =============================================================================

pub struct WebSearchTool {
pub:
	// Reserved for future: region, safe-search, custom UA.
}

pub fn (t WebSearchTool) name() string {
	return 'web_search'
}

pub fn (t WebSearchTool) description() string {
	return 'Search the web via DuckDuckGo and return a numbered list of results ' +
		'(title, URL, snippet). Use when you need up-to-date information, docs, or ' +
		'links the user might want to open. For fetching a specific page\'s full ' +
		'content, prefer web_fetch.'
}

pub fn (t WebSearchTool) parameters_schema() string {
	return '{"type":"object","properties":{"query":{"type":"string","description":"Search query"},' +
		'"max_results":{"type":"integer","description":"Optional cap on number of results (default 8)"}},' +
		'"required":["query"],"additionalProperties":false}'
}

pub fn (t WebSearchTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	args_map := json.decode(map[string]string, args.raw) or {
		return ToolResult{
			content:  'invalid arguments: ${err.msg()}'
			is_error: true
		}
	}
	query := args_map['query'] or {
		return ToolResult{
			content:  'missing required argument: query'
			is_error: true
		}
	}
	max_results_str := args_map['max_results'] or { '8' }
	mut max_results := max_results_str.int()
	if max_results <= 0 || max_results > 30 {
		max_results = 8
	}

	// Build the DuckDuckGo HTML request. We POST a form so long queries
	// survive; the endpoint returns a results page.
	header := http.new_header(
		http.HeaderConfig{ key: .user_agent, value: 'kimi-v/0.1 (+https://github.com/whiter001/mc)' },
		http.HeaderConfig{ key: .accept, value: 'text/html, application/xhtml+xml, */*' },
		http.HeaderConfig{ key: .content_type, value: 'application/x-www-form-urlencoded' },
	)

	body := 'q=' + url_encode(query)
	resp := http.fetch(http.FetchConfig{
		url:    'https://html.duckduckgo.com/html/'
		method: .post
		header: header
		data:   body
	}) or {
		return ToolResult{
			content:  'search request failed: ${err.msg()}'
			is_error: true
		}
	}
	if resp.status_code !in [200, 201, 202, 203, 204] {
		return ToolResult{
			content:  'search failed: HTTP ${resp.status_code}'
			is_error: true
		}
	}

	results := parse_ddg_results(resp.body, max_results)
	if results.len == 0 {
		return ToolResult{
			content: '(no results found for "${query}")'
		}
	}

	mut out := strings.new_builder(1024)
	for i, r in results {
		out.write_string('${i + 1}. ${r.title}\n')
		out.write_string('   ${r.url}\n')
		if r.snippet.len > 0 {
			out.write_string('   ${r.snippet}\n')
		}
		out.write_string('\n')
	}
	return ToolResult{ content: out.str().trim_space() }
}

struct SearchResult {
	title   string
	url     string
	snippet string
}

// parse_ddg_results extracts results from DuckDuckGo's HTML. Each result is
// a <a class="result__a" href="...">title</a> followed by a snippet in
// <a class="result__snippet">...</a>. We walk the HTML pulling these out in
// order and zip them up. This is intentionally tiny — no full parser.
fn parse_ddg_results(html string, max_results int) []SearchResult {
	mut results := []SearchResult{}
	mut i := 0
	for i < html.len && results.len < max_results {
		// Find the next result title anchor.
		idx := find_tag_with_class(html, i, 'a', 'result__a')
		if idx < 0 {
			break
		}
		// Extract href.
		href := extract_attr(html, idx, 'href')
		if href.len == 0 {
			i = idx + 1
			continue
		}
		// Walk to the > that closes the opening tag, then read the title
		// text until the matching </a>.
		tag_end := html.index_after_('>', idx)
		if tag_end < 0 {
			i = idx + 1
			continue
		}
		close := html.index_after_('<', tag_end)
		title := if close > tag_end { html_to_text(html[tag_end + 1..close]).trim_space() } else { '' }

		// Look ahead for the snippet anchor.
		snip_idx := find_tag_with_class(html, close, 'a', 'result__snippet')
		mut snippet := ''
		if snip_idx >= 0 {
			s_tag_end := html.index_after_('>', snip_idx)
			s_close := html.index_after_('<', s_tag_end)
			if s_close > s_tag_end {
				snippet = html_to_text(html[s_tag_end + 1..s_close]).trim_space()
			}
		}

		results << SearchResult{
			title:   title
			url:     ddg_decode_url(href)
			snippet: snippet
		}
		i = close + 1
	}
	return results
}

// find_tag_with_class locates the next `<tag class="...cls..."` starting at
// `from`. Returns the index of the opening `<` or -1.
fn find_tag_with_class(html string, from int, tag string, cls string) int {
	open := '<${tag} '
	lower := html.to_lower()
	mut pos := from
	for pos < html.len {
		idx := lower.index_after_(open, pos)
		if idx < 0 {
			return -1
		}
		// Check that a class attribute containing cls appears before the
		// closing `>` of this opening tag.
		gt := lower.index_after_('>', idx)
		if gt < 0 {
			return -1
		}
		seg := lower[idx..gt]
		if seg.contains('class=') && seg.contains(cls) {
			return idx
		}
		pos = gt
	}
	return -1
}

// extract_attr reads the value of `attr` from the tag starting at `at`
// (which points at the `<` of the opening tag).
fn extract_attr(html string, at int, attr string) string {
	lower := html.to_lower()
	key := '${attr}='
	idx := lower.index_after_(key, at)
	if idx < 0 {
		return ''
	}
	// Skip past `attr=`.
	mut p := idx + key.len
	// Optional quote (single or double).
	mut quote := u8(0)
	if p < html.len && (html[p] == `"` || html[p] == `'`) {
		quote = html[p]
		p++
	}
	mut end := p
	if quote != 0 {
		for end < html.len && html[end] != quote {
			end++
		}
	} else {
		for end < html.len && html[end] != ` ` && html[end] != `>` && html[end] != `\n` && html[end] != `\t` {
			end++
		}
	}
	return html[p..end]
}

// ddg_decode_url converts DuckDuckGo's redirect wrapper
// (//duckduckgo.com/l/?uddg=<url>&...) back into the real URL. If it's not
// a wrapper, returns the href unchanged.
fn ddg_decode_url(href string) string {
	marker := 'uddg='
	idx := href.index_after_(marker, 0)
	if idx < 0 {
		return href
	}
	start := idx + marker.len
	mut end := start
	for end < href.len && href[end] != `&` {
		end++
	}
	enc := href[start..end]
	return url_decode(enc)
}

// url_encode percent-encodes a query string for the form body.
fn url_encode(s string) string {
	mut out := strings.new_builder(s.len)
	for c in s {
		if (c >= `A` && c <= `Z`) || (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`)
			|| c == `-` || c == `_` || c == `.` || c == `~` {
			out.write_string(c.ascii_str())
		} else if c == ` ` {
			out.write_string('+')
		} else {
			out.write_string('%${u8(c).hex()}')
		}
	}
	return out.str()
}

// url_decode decodes a percent-encoded string (and `+` → space).
fn url_decode(s string) string {
	mut out := strings.new_builder(s.len)
	mut i := 0
	for i < s.len {
		c := s[i]
		if c == `+` {
			out.write_string(' ')
			i++
		} else if c == `%` && i + 2 < s.len {
			hi := hex_digit(s[i + 1])
			lo := hex_digit(s[i + 2])
			if hi >= 0 && lo >= 0 {
				val := u8(hi * 16 + lo)
				out.write_string(val.ascii_str())
				i += 3
			} else {
				out.write_string('%')
				i++
			}
		} else {
			out.write_string(c.ascii_str())
			i++
		}
	}
	return out.str()
}

// hex_digit returns the numeric value of a hex digit character, or -1 if
// it isn't a valid hex digit.
fn hex_digit(c u8) int {
	match c {
		`0`...`9` { return int(c - `0`) }
		`a`...`f` { return int(c - `a`) + 10 }
		`A`...`F` { return int(c - `A`) + 10 }
		else { return -1 }
	}
}
