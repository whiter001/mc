module main

// Tests for the lsh port: glob matching (stdext/glob.rs), language detection,
// the LSH VM (runtime.rs), and the Highlighter/HighlighterCache.

// ---- glob -----------------------------------------------------------------

fn test_glob_fast_path_extension() {
	// '**/*.ext' matches by suffix in any directory depth.
	assert lsh_glob_match('**/*.rs', 'main.rs')
	assert lsh_glob_match('**/*.rs', 'a/b/c.rs')
	assert !lsh_glob_match('**/*.rs', 'a/b.rs.bak')
	assert !lsh_glob_match('**/*.rs', 'a/b.c')
	// Case-insensitive.
	assert lsh_glob_match('**/*.RS', 'a/b.rs')
	assert lsh_glob_match('**/*.rs', 'A/B.Rs')
}

fn test_glob_fast_path_filename() {
	// '**/filename' anchors to the full file name.
	assert lsh_glob_match('**/Cargo.toml', 'Cargo.toml')
	assert lsh_glob_match('**/Cargo.toml', 'a/b/Cargo.toml')
	assert !lsh_glob_match('**/Cargo.toml', 'a/b/xCargo.toml')
	assert !lsh_glob_match('**/Cargo.toml', 'Cargo.tomlx')
}

fn test_glob_slow_path() {
	// Patterns the fast path rejects fall back to backtracking.
	// '*' does not cross '/'.
	assert lsh_glob_match('*.rs', 'x.rs')
	assert !lsh_glob_match('*.rs', 'a/x.rs')
	assert lsh_glob_match('a/*/c', 'a/b/c')
	assert !lsh_glob_match('a/*/c', 'a/b/d/c')
	// '**' crosses directories; '/**/' also matches '/'.
	assert lsh_glob_match('a/**/c', 'a/b/d/c')
	assert lsh_glob_match('a/**/c', 'a/c')
	assert !lsh_glob_match('a/**/c', 'a/b/d')
}

// ---- language detection -----------------------------------------------------

fn test_language_for_path() {
	assert lsh_language_for_path('foo/main.c') == 0
	assert lsh_languages[lsh_language_for_path('a/b.rs')].id == 'rust'
	assert lsh_languages[lsh_language_for_path('x.py')].id == 'python'
	assert lsh_languages[lsh_language_for_path('a/b/Cargo.toml')].id == 'toml'
	// Unknown extensions yield no language.
	assert lsh_language_for_path('a/b.zzz') == -1
	assert lsh_language_for_path('') == -1
}

// ---- VM smoke ---------------------------------------------------------------

// span_kinds returns (start, kind) pairs for assertions.
fn span_kinds(spans []LshHighlight) string {
	mut s := ''
	for sp in spans {
		s += '${sp.start}:${sp.kind} '
	}
	return s
}

fn test_vm_c_line() {
	mut rt := lsh_runtime_new(lsh_assembly, lsh_strings, lsh_charsets, lsh_languages[0].entrypoint)
	line := 'int x; // hi'
	spans := rt.parse_next_line(line.bytes())
	// Expected: 'int' = storage_type (21), then other, then comment at '//'.
	assert spans.len >= 3, span_kinds(spans)
	assert spans[0].start == 0
	assert spans[0].kind == lsh_kind_storage_type, span_kinds(spans)
	comment_at := line.index('//') or { -1 }
	mut found_comment := false
	for sp in spans {
		if sp.start == comment_at && sp.kind == lsh_kind_comment {
			found_comment = true
		}
	}
	assert found_comment, span_kinds(spans)
	// Sentinel span at the end of the line.
	assert spans.last().start == line.len, span_kinds(spans)
}

fn test_vm_multiline_comment_state() {
	// The VM keeps state across parse_next_line calls: a block comment opened
	// on line 1 continues on line 2.
	mut rt := lsh_runtime_new(lsh_assembly, lsh_strings, lsh_charsets, lsh_languages[0].entrypoint)
	rt.parse_next_line('/* open'.bytes())
	spans := rt.parse_next_line('still comment'.bytes())
	assert spans[0].kind == lsh_kind_comment, span_kinds(spans)
}

// ---- Highlighter / cache ----------------------------------------------------

fn test_highlighter_and_cache() {
	doc := StringDocument{ text: 'int a;\n// c\nint b;\n' }
	mut h := highlighter_new(&doc, lsh_languages[0])
	mut cache := HighlighterCache{}

	// Random access to line 2 parses forward from the start.
	spans2 := cache.parse_line(mut h, 2)
	assert spans2.len >= 2
	assert spans2[0].kind == lsh_kind_storage_type
	// Absolute document offsets: line 2 starts at byte 12.
	assert spans2[0].start == 12

	// Line 1 is a comment.
	spans1 := cache.parse_line(mut h, 1)
	assert spans1.len >= 2
	assert spans1[0].start == 7
	assert spans1[0].kind == lsh_kind_comment
}

fn test_highlighter_long_line_skipped() {
	doc := StringDocument{ text: 'x'.repeat(lsh_max_line_len + 1) + '\nint y;\n' }
	mut h := highlighter_new(&doc, lsh_languages[0])
	mut cache := HighlighterCache{}
	// The over-long line yields no spans but does not wedge the highlighter.
	assert cache.parse_line(mut h, 0).len == 0
	spans := cache.parse_line(mut h, 1)
	assert spans.len >= 2
	assert spans[0].kind == lsh_kind_storage_type
}

// ---- ASCII case-insensitive helpers (highlighter.v) -----------------------
//
// lsh_ascii_lower / lsh_eq_ignore_ascii_case are the per-byte primitives
// the glob matcher uses to fold ASCII letter case without paying for a
// full locale-aware lowercase.

fn test_lsh_ascii_lower_uppercase_to_lowercase() {
	// A-Z → a-z (add 32).
	assert lsh_ascii_lower(`A`) == `a`
	assert lsh_ascii_lower(`Z`) == `z`
	assert lsh_ascii_lower(`M`) == `m`
}

fn test_lsh_ascii_lower_passthrough() {
	// Lowercase letters, digits, and non-ASCII bytes pass through unchanged.
	assert lsh_ascii_lower(`a`) == `a`
	assert lsh_ascii_lower(`z`) == `z`
	assert lsh_ascii_lower(`0`) == `0`
	assert lsh_ascii_lower(`9`) == `9`
	assert lsh_ascii_lower(` `) == ` `
	assert lsh_ascii_lower(0x7f) == 0x7f
	assert lsh_ascii_lower(0x80) == 0x80 // non-ASCII high byte
}

fn test_lsh_eq_ignore_ascii_case_matches() {
	// Same letter, different case → true.
	assert lsh_eq_ignore_ascii_case(`A`, `a`)
	assert lsh_eq_ignore_ascii_case(`a`, `A`)
	assert lsh_eq_ignore_ascii_case(`M`, `m`)
}

fn test_lsh_eq_ignore_ascii_case_rejects_different() {
	// Different letters → false.
	assert !lsh_eq_ignore_ascii_case(`A`, `B`)
	assert !lsh_eq_ignore_ascii_case(`a`, `z`)
	// Same case but different bytes → false.
	assert !lsh_eq_ignore_ascii_case(`A`, `1`)
	assert !lsh_eq_ignore_ascii_case(`0`, `1`)
	// Non-ASCII bytes compared by their actual value (not folded).
	assert !lsh_eq_ignore_ascii_case(0x80, 0x80 + 32)
}

// ---- lsh_match_path_suffix (highlighter.v) -----------------------------
//
// Case-insensitive suffix match used by lsh_glob_match's fast path.

fn test_lsh_match_path_suffix_basic() {
	assert lsh_match_path_suffix('main.rs'.bytes(), '.rs'.bytes())
	assert lsh_match_path_suffix('a/b/c.txt'.bytes(), '.txt'.bytes())
	assert !lsh_match_path_suffix('main.rs'.bytes(), '.txt'.bytes())
}

fn test_lsh_match_path_suffix_case_insensitive() {
	assert lsh_match_path_suffix('Main.RS'.bytes(), '.rs'.bytes())
	assert lsh_match_path_suffix('main.rs'.bytes(), '.RS'.bytes())
}

fn test_lsh_match_path_suffix_too_short() {
	// path shorter than suffix → no match.
	assert !lsh_match_path_suffix('a.rs'.bytes(), 'main.rs'.bytes())
	assert !lsh_match_path_suffix(''.bytes(), 'x'.bytes())
}

fn test_lsh_match_path_suffix_empty_suffix() {
	// Empty suffix matches any path (vacuously).
	assert lsh_match_path_suffix('main.rs'.bytes(), ''.bytes())
	assert lsh_match_path_suffix(''.bytes(), ''.bytes())
}

// ---- lsh_highlight_color / lsh_highlight_attr (highlighter.v) ----------
//
// Pure mappings from HighlightKind to (IndexedColor, Attributes). The
// color match covers all the kinds the highlighter emits; the attr
// match only fires for the four markup kinds, everything else attr_none.

fn test_lsh_highlight_color_basic_kinds() {
	assert lsh_highlight_color(lsh_kind_comment) == int(IndexedColor.green)
	assert lsh_highlight_color(lsh_kind_method) == int(IndexedColor.bright_yellow)
	assert lsh_highlight_color(lsh_kind_string) == int(IndexedColor.bright_red)
	assert lsh_highlight_color(lsh_kind_variable) == int(IndexedColor.bright_cyan)
	assert lsh_highlight_color(lsh_kind_constant_language) == int(IndexedColor.bright_blue)
	assert lsh_highlight_color(lsh_kind_constant_numeric) == int(IndexedColor.bright_green)
	assert lsh_highlight_color(lsh_kind_keyword_control) == int(IndexedColor.bright_magenta)
}

fn test_lsh_highlight_color_storage() {
	// Storage kinds share the cyan palette.
	assert lsh_highlight_color(lsh_kind_storage_annotation) == int(IndexedColor.cyan)
	assert lsh_highlight_color(lsh_kind_storage_type) == int(IndexedColor.cyan)
}

fn test_lsh_highlight_color_unknown_returns_minus_one() {
	// A kind outside the match returns -1; renderers use that to
	// skip the color change and keep the default foreground.
	assert lsh_highlight_color(9999) == -1
}

fn test_lsh_highlight_attr_markup_kinds() {
	assert lsh_highlight_attr(lsh_kind_markup_bold) == attr_bold
	assert lsh_highlight_attr(lsh_kind_markup_italic) == attr_italic
	assert lsh_highlight_attr(lsh_kind_markup_link) == attr_underlined
	assert lsh_highlight_attr(lsh_kind_markup_strikethrough) == attr_strikethrough
}

fn test_lsh_highlight_attr_non_markup_returns_attr_none() {
	// Non-markup kinds do not set an attribute; the renderer keeps
	// whatever was in effect for that cell.
	assert lsh_highlight_attr(lsh_kind_comment) == attr_none
	assert lsh_highlight_attr(lsh_kind_method) == attr_none
	assert lsh_highlight_attr(lsh_kind_string) == attr_none
	assert lsh_highlight_attr(lsh_kind_variable) == attr_none
	assert lsh_highlight_attr(lsh_kind_keyword_control) == attr_none
	// Unknown kind also returns attr_none.
	assert lsh_highlight_attr(9999) == attr_none
}
