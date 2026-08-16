module main

// Port of crates/edit/src/lsh/{highlighter,cache,mod}.rs (microsoft/edit):
// the adapter between the LSH bytecode VM (lsh_runtime.v) and TextBuffer.
//
// - Highlighter reads lines off a ReadableDocument and runs the VM on each.
// - HighlighterCache snapshots the VM state every lsh_checkpoint_interval
//   logical lines so random-access repaints don't reparse from line 0.
// - lsh_language_for_path maps a filename to a language via glob matching
//   (stdext::glob port).

// lsh_max_line_len: lines longer than this are not highlighted (Rust
// MAX_LINE_LEN, a guard against pathological minified files).
const lsh_max_line_len = 32 * 1024

// lsh_checkpoint_interval: lines between cached VM snapshots (Rust INTERVAL,
// the release value).
const lsh_checkpoint_interval = CoordType(1024)

// LshAssociation maps a filename glob to a lsh_languages index
// (Rust FILE_ASSOCIATIONS entries are (pattern, &Language) pairs).
struct LshAssociation {
	pattern string
	lang    int
}

// ---- glob matching (stdext::glob port) --------------------------------------

// lsh_glob_match matches a path against a glob with '*' and '**' wildcards,
// case-insensitively (the original is case-insensitive on all platforms here).
fn lsh_glob_match(pattern string, name string) bool {
	p := pattern.bytes()
	n := name.bytes()
	if r := lsh_glob_fast_path(p, n) {
		return r
	}
	return lsh_glob_slow_path(p, n)
}

// Fast path for the common '**/*.ext' and '**/filename' patterns.
fn lsh_glob_fast_path(pattern []u8, name []u8) ?bool {
	if pattern.len < 4 || pattern[0] != `*` || pattern[1] != `*` || pattern[2] != `/` {
		return none
	}
	mut suffix := pattern[3..]
	mut needs_dir_anchor := true
	if suffix.len > 0 && suffix[0] == `*` {
		suffix = suffix[1..]
		needs_dir_anchor = false
	}
	if suffix.len == 0 || suffix.contains(`*`) {
		return none
	}
	if !lsh_match_path_suffix(name, suffix) {
		return false
	}
	if !needs_dir_anchor {
		return true
	}
	// '**/filename' requires the name to be exactly 'filename' or '.../filename'.
	return name.len == suffix.len || name[name.len - suffix.len - 1] == `/`
}

fn lsh_match_path_suffix(path []u8, suffix []u8) bool {
	if path.len < suffix.len {
		return false
	}
	tail := path[path.len - suffix.len..]
	for i in 0 .. suffix.len {
		if !lsh_eq_ignore_ascii_case(tail[i], suffix[i]) {
			return false
		}
	}
	return true
}

@[inline]
fn lsh_eq_ignore_ascii_case(a u8, b u8) bool {
	return lsh_ascii_lower(a) == lsh_ascii_lower(b)
}

@[inline]
fn lsh_ascii_lower(c u8) u8 {
	return if c >= `A` && c <= `Z` { c + 32 } else { c }
}

// Slow path: backtracking glob match, based on https://research.swtch.com/glob.go
// like the original.
fn lsh_glob_slow_path(pattern []u8, name []u8) bool {
	mut px := 0
	mut nx := 0
	mut next_px := 0
	mut next_nx := 0
	mut is_double_star := false

	for px < pattern.len || nx < name.len {
		if px < pattern.len {
			c := pattern[px]
			if c == `*` {
				// Try to match at nx; on failure restart at nx+1.
				next_px = px
				next_nx = nx + 1
				px++
				is_double_star = false
				if px < pattern.len && pattern[px] == `*` {
					px++
					is_double_star = true
					// For convenience, '**/' also matches '/'.
					if px >= 3 && px < pattern.len && pattern[px] == `/` && pattern[px - 3] == `/` {
						px++
					}
				}
				continue
			}
			if nx < name.len && lsh_eq_ignore_ascii_case(name[nx], c) {
				px++
				nx++
				continue
			}
		}

		// Mismatch. Maybe restart.
		if next_nx > 0 && next_nx <= name.len
			&& (is_double_star || name[next_nx - 1] != `/`) {
			px = next_px
			nx = next_nx
			continue
		}
		return false
	}
	return true
}

// lsh_language_for_path returns the lsh_languages index for the given path,
// or -1 (Rust process_file_associations).
fn lsh_language_for_path(path string) int {
	for a in lsh_file_associations {
		if lsh_glob_match(a.pattern, path) {
			return a.lang
		}
	}
	return -1
}

// ---- Highlighter ------------------------------------------------------------

// Highlighter runs the LSH VM over successive lines of a document
// (Rust highlighter.rs).
struct Highlighter {
	doc &ReadableDocument
mut:
	offset        int
	logical_pos_y CoordType
	runtime       LshRuntime
}

// HighlighterState is a restorable snapshot of the highlighter.
struct HighlighterState {
	offset        int
	logical_pos_y CoordType
	state         LshRuntimeState
}

fn highlighter_new(doc &ReadableDocument, lang LshLanguage) Highlighter {
	return Highlighter{
		doc:     unsafe { doc }
		runtime: lsh_runtime_new(lsh_assembly, lsh_strings, lsh_charsets, lang.entrypoint)
	}
}

fn (h &Highlighter) snapshot() HighlighterState {
	return HighlighterState{
		offset:        h.offset
		logical_pos_y: h.logical_pos_y
		state:         h.runtime.snapshot()
	}
}

fn (mut h Highlighter) restore(s &HighlighterState) {
	h.offset = s.offset
	h.logical_pos_y = s.logical_pos_y
	h.runtime.restore(&s.state)
}

// parse_next_line highlights the next line, returning spans with absolute
// document offsets. Empty or over-long lines yield no spans.
fn (mut h Highlighter) parse_next_line() []LshHighlight {
	line_off, line := h.read_next_line()
	if line.len == 0 || line.len >= lsh_max_line_len {
		return []
	}
	mut res := h.runtime.parse_next_line(line)
	for i in 0 .. res.len {
		clamped := if res[i].start < line.len { res[i].start } else { line.len }
		res[i].start = line_off + clamped
	}
	return res
}

// read_next_line reads the next logical line (without the newline), across
// chunk boundaries if necessary. Lines beyond lsh_max_line_len are truncated:
// the remainder is skipped without being stored (the caller won't highlight
// it anyway).
fn (mut h Highlighter) read_next_line() (int, []u8) {
	h.logical_pos_y++

	line_beg := h.offset
	mut buf := []u8{}
	for {
		chunk := h.doc.read_forward(h.offset)
		if chunk.len == 0 {
			break
		}
		nl := chunk.index(u8(`\n`))
		line_end := if nl >= 0 { nl } else { chunk.len }
		room := lsh_max_line_len - buf.len
		take := if line_end < room { line_end } else { room }
		if take > 0 {
			buf << chunk[..take]
		}
		if nl >= 0 {
			// Consumed a full line including its newline.
			h.offset += nl + 1
			break
		}
		h.offset += chunk.len
	}
	return line_beg, buf
}

// ---- HighlightKind → 颜色/属性映射 -------------------------------------------

// lsh_highlight_color maps a HighlightKind to its IndexedColor, -1 = no color
// change (Rust buffer/mod.rs render_apply_highlights, color match).
fn lsh_highlight_color(kind u32) int {
	return match kind {
		lsh_kind_comment { int(IndexedColor.green) }
		lsh_kind_method { int(IndexedColor.bright_yellow) }
		lsh_kind_string { int(IndexedColor.bright_red) }
		lsh_kind_variable { int(IndexedColor.bright_cyan) }
		lsh_kind_constant_language { int(IndexedColor.bright_blue) }
		lsh_kind_constant_numeric { int(IndexedColor.bright_green) }
		lsh_kind_keyword_control { int(IndexedColor.bright_magenta) }
		lsh_kind_keyword_other { int(IndexedColor.bright_blue) }
		lsh_kind_keyword_preprocessor { int(IndexedColor.bright_blue) }
		lsh_kind_markup_changed { int(IndexedColor.bright_blue) }
		lsh_kind_markup_deleted { int(IndexedColor.bright_red) }
		lsh_kind_markup_heading { int(IndexedColor.bright_blue) }
		lsh_kind_markup_inserted { int(IndexedColor.bright_green) }
		lsh_kind_markup_list { int(IndexedColor.bright_blue) }
		lsh_kind_meta_header { int(IndexedColor.bright_blue) }
		lsh_kind_storage_annotation { int(IndexedColor.cyan) }
		lsh_kind_storage_type { int(IndexedColor.cyan) }
		else { -1 }
	}
}

// lsh_highlight_attr maps a HighlightKind to a text attribute, attr_none = no
// attribute change (Rust render_apply_highlights, attr match).
fn lsh_highlight_attr(kind u32) Attributes {
	return match kind {
		lsh_kind_markup_bold { attr_bold }
		lsh_kind_markup_italic { attr_italic }
		lsh_kind_markup_link { attr_underlined }
		lsh_kind_markup_strikethrough { attr_strikethrough }
		else { attr_none }
	}
}

// ---- HighlighterCache --------------------------------------------------------

// HighlighterCache caches VM snapshots every lsh_checkpoint_interval lines so
// repaints can seek instead of reparsing from line 0 (Rust cache.rs). The
// cache is append-only; edits invalidate from the first changed line.
struct HighlighterCache {
mut:
	checkpoints []HighlighterState
}

// invalidate_from drops cached states at and after the given logical line.
fn (mut c HighlighterCache) invalidate_from(line CoordType) {
	n := int((line + lsh_checkpoint_interval - 1) / lsh_checkpoint_interval)
	if n < c.checkpoints.len {
		c.checkpoints.trim(n)
	}
}

// parse_line returns the highlight spans for the given logical line.
fn (mut c HighlighterCache) parse_line(mut h Highlighter, line CoordType) []LshHighlight {
	// Random seek: restore the nearest preceding checkpoint, then parse
	// forward line by line.
	if line != h.logical_pos_y {
		if c.checkpoints.len > 0 {
			mut n := int(line / lsh_checkpoint_interval)
			if n > c.checkpoints.len - 1 {
				n = c.checkpoints.len - 1
			}
			h.restore(&c.checkpoints[n])
		}
		for h.logical_pos_y < line {
			c.parse_line_impl(mut h)
		}
	}
	return c.parse_line_impl(mut h)
}

fn (mut c HighlighterCache) parse_line_impl(mut h Highlighter) []LshHighlight {
	// Store a checkpoint for the start of the next line if due.
	if int(h.logical_pos_y / lsh_checkpoint_interval) == c.checkpoints.len {
		c.checkpoints << h.snapshot()
	}
	return h.parse_next_line()
}
