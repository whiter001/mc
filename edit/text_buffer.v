module main

// Port of crates/edit/src/buffer/mod.rs (microsoft/edit).
//
// A text buffer for a text editor, built on top of GapBuffer.
//
// Scope differences from the Rust original (first-version cut):
// * No Rc/TextBufferCell sharing: callers use TextBuffer by value
//   (`mut tb := new_text_buffer(false)`).
// * lsh syntax highlighting is integrated via `HighlighterCache` (lsh VM in
//   lsh_runtime.v, tables in lsh_tables.v generated offline by
//   tools/lsh_tables_to_v.py; the lsh compiler itself is not ported).
//   `language` is an index into `lsh_languages` (-1 = none).
// * No ICU regex: find_and_select/find_and_replace/find_and_replace_all are
//   pure byte-substring searches. SearchOptions.use_regex is kept for API
//   compatibility but ignored; whole_word uses ASCII word boundaries;
//   match_case=false folds ASCII letters only.
// * read_file/write_file read/write in 64KiB chunks (Rust uses SIMD scans +
//   virtual-memory gap allocation) and have no progress callbacks.
// * Rust's simd::lines_fwd/lines_bwd are replaced with plain byte scans.
// * The `small` parameter of Rust's GapBuffer::new is accepted for API
//   parity but ignored; V's GapBuffer uses one malloc'd backing for all sizes.

import os

// margin_template provides whitespace that doubles as tab-to-space expansion.
const margin_template = '                    │ '
// tab_whitespace is just whitespace you can use for turning tabs into spaces.
const tab_whitespace = ' '.repeat(24)
const visual_space = '･'
const visual_space_prefix_add = 2 // '･'.len_utf8() - 1
const visual_tab = '￫       '
const visual_tab_prefix_add = 2 // '￫'.len_utf8() - 1

// bom_max_len is the max. number of bytes we read to detect a BOM.
const bom_max_len = 4

// TextBufferStatistics stores statistics about the whole document.
pub struct TextBufferStatistics {
pub mut:
	logical_lines CoordType
	visual_lines  CoordType
}

// OptSelection is V's stand-in for Rust's Option<TextBufferSelection>.
// The two points are not sorted: `beg` is where the selection started
// being made and `end` is the currently updated position.
struct OptSelection {
mut:
	valid bool
	beg   Point
	end   Point
}

// HistoryType groups actions into a single undo step.
enum HistoryType {
	other
	write
	delete
}

// HistoryEntry is an undo/redo entry.
struct HistoryEntry {
mut:
	// cursor position before the change was made.
	cursor_before Point
	// selection before the change was made.
	selection_before OptSelection
	// stats before the change was made.
	stats_before TextBufferStatistics
	// buffer generation before the change was made.
	// NOTE: entries with the same generation are grouped together.
	generation_before u32
	// logical cursor position where the change took place.
	cursor Point
	// text that was deleted from the buffer.
	deleted []u8
	// text that was added to the buffer.
	added []u8
}

// ActiveSearch caches a search operation.
struct ActiveSearch {
mut:
	valid                bool // false = no active search
	// The search pattern.
	pattern              string
	// The search options.
	options              SearchOptions
	// Buffer generation when the search was created, used to detect
	// whether the cached state needs a refresh.
	buffer_generation    u32
	// selection generation when the search was created.
	selection_generation u32
	// Text buffer offset to resume searching from.
	next_search_offset   int
	// If we know there were no hits, we can skip searching.
	no_matches           bool
}

// SearchOptions are the options for a search operation.
pub struct SearchOptions {
pub mut:
	// If true, the search is case-sensitive.
	match_case bool
	// If true, the search matches whole words.
	whole_word bool
	// Reserved for API compatibility. Regex is NOT supported by this port:
	// the search is always a literal byte-substring search.
	use_regex bool
}

// ActiveEditLineInfo caches the start and length of the active edit line for
// a single edit, helping us avoid remeasuring the buffer after an edit.
struct ActiveEditLineInfo {
mut:
	valid                  bool
	// Points to the start of the currently being edited line.
	safe_start             Cursor
	// Number of visual rows of the line that starts at safe_start.
	line_height_in_rows    CoordType
	// Byte distance from safe_start to the next line start.
	distance_next_line_start int
}

// ActiveEditGroupInfo stores undo-grouping overrides applied in edit_begin().
struct ActiveEditGroupInfo {
mut:
	valid             bool
	cursor_before     Point
	selection_before  OptSelection
	stats_before      TextBufferStatistics
	generation_before u32
}

// CursorMovement selects char- or word-wise navigation.
pub enum CursorMovement {
	grapheme
	word
}

// MoveLineDirection is used by move_selected_lines.
pub enum MoveLineDirection {
	up
	down
}

// RenderResult is the result of a call to render().
pub struct RenderResult {
pub mut:
	// The maximum visual X position we encountered during rendering.
	visual_pos_x_max CoordType
}

// TextBuffer is a text buffer for a text editor.
pub struct TextBuffer {
mut:
	buffer               GapBuffer

	undo_stack           []HistoryEntry
	redo_stack           []HistoryEntry
	last_history_type    HistoryType
	last_save_generation u32

	active_edit_group     ActiveEditGroupInfo
	active_edit_line_info ActiveEditLineInfo
	active_edit_depth     int
	active_edit_off       int

	stats                     TextBufferStatistics
	cursor                    Cursor
	cursor_for_rendering_valid bool
	cursor_for_rendering      Cursor
	selection                 OptSelection
	selection_generation      u32
	search                    ActiveSearch

	width                   CoordType
	margin_width            CoordType
	margin_enabled          bool
	word_wrap_column        CoordType
	word_wrap_enabled       bool
	tab_size                CoordType
	indent_with_tabs        bool
	line_highlight_enabled  bool
	language                int // index into lsh_languages, -1 = none
	highlighter_cache       HighlighterCache
	ruler                   CoordType
	encoding                string
	newlines_are_crlf       bool
	insert_final_newline    bool
	overtype                bool

	wants_cursor_visibility bool
}

// new_text_buffer creates a new text buffer.
// The `small` parameter (Rust: optimize for <1MiB contents) is accepted for
// API parity but ignored by this port.
pub fn new_text_buffer(small bool) TextBuffer {
	return TextBuffer{
		buffer:              new_gap_buffer()
		last_history_type:   HistoryType.other
		stats:               TextBufferStatistics{
			logical_lines: 1
			visual_lines:  1
		}
		tab_size:            4
		encoding:            'UTF-8'
		language:            -1 // no highlighting until set_language() is called
		// Windows users want CRLF; macOS/Linux default to LF.
		newlines_are_crlf:    false
		// NOTE: Even with POSIX, single-line buffers need this to be false.
		insert_final_newline: false
	}
}

// ---- Byte/coordinate helpers ------------------------------------------------

// clamp_coord is defined in input.v.

// minmax_coords returns the two coordinates in ascending order.
fn minmax_coords(a CoordType, b CoordType) (CoordType, CoordType) {
	if a <= b {
		return a, b
	}
	return b, a
}

// minmax_points returns the two points sorted by (y, x).
fn minmax_points(a Point, b Point) (Point, Point) {
	if a.compare(b) <= 0 {
		return a, b
	}
	return b, a
}

// ilog10 computes the floor of the base-10 logarithm (Rust's ilog10).
// Assumes n >= 1.
fn ilog10(n CoordType) CoordType {
	mut m := n
	mut result := CoordType(0)
	for m >= 10 {
		m /= 10
		result++
	}
	return result
}

// lines_fwd ports simd::lines_fwd: starting from `offset` in `text` with a
// current line index of `line`, seek to the `line_stop`-th line and return
// the new offset (past the newline) and the line index at that point.
// If `line` is already at or past `line_stop`, it returns immediately.
fn lines_fwd(text []u8, offset int, line CoordType, line_stop CoordType) (int, CoordType) {
	mut off := offset
	mut ln := line
	if ln < line_stop {
		for off < text.len {
			c := text[off]
			off++
			if c == `\n` {
				ln++
				if ln == line_stop {
					break
				}
			}
		}
	}
	return off, ln
}

// lines_bwd ports simd::lines_bwd: seeks backwards even if `line` is already
// at `line_stop`, so you can test whether `offset` is at a line start.
// Returns an offset past a newline and thus at the start of a line.
fn lines_bwd(text []u8, offset int, line CoordType, line_stop CoordType) (int, CoordType) {
	mut off := offset
	mut ln := line
	for off > 0 {
		c := text[off - 1]
		if c == `\n` {
			if ln <= line_stop {
				break
			}
			ln--
		}
		off--
	}
	return off, ln
}

// read_all concatenates read_forward() chunks into a single byte slice.
fn (b TextBuffer) read_all() []u8 {
	mut out := []u8{}
	mut off := 0
	for off < b.buffer.len() {
		chunk := b.buffer.read_forward(off)
		if chunk.len == 0 {
			break
		}
		out << chunk
		off += chunk.len
	}
	return out
}

// ---- Basic accessors ---------------------------------------------------------

// text_length returns the length of the document in bytes.
pub fn (b TextBuffer) text_length() int {
	return b.buffer.len()
}

// logical_line_count returns the number of logical lines in the document,
// that is, lines separated by newlines.
pub fn (b TextBuffer) logical_line_count() CoordType {
	return b.stats.logical_lines
}

// visual_line_count returns the number of visual lines in the document,
// that is, the number of lines after layout.
pub fn (b TextBuffer) visual_line_count() CoordType {
	return b.stats.visual_lines
}

// is_dirty returns whether the buffer needs to be saved.
pub fn (b TextBuffer) is_dirty() bool {
	return b.last_save_generation != b.buffer.generation()
}

// generation returns the buffer generation, which changes on every edit.
pub fn (b TextBuffer) generation() u32 {
	return b.buffer.generation()
}

// mark_as_dirty forces the buffer to be dirty (needs saving to disk).
pub fn (mut b TextBuffer) mark_as_dirty() {
	b.last_save_generation = b.buffer.generation() - 1
}

// mark_as_clean forces the buffer to be clean (has been saved to disk).
// Called automatically on write().
pub fn (mut b TextBuffer) mark_as_clean() {
	b.last_save_generation = b.buffer.generation()
}

// encoding returns the encoding used during reading/writing.
// "UTF-8" is the default.
pub fn (b TextBuffer) encoding() string {
	return b.encoding
}

// set_encoding sets the encoding used during reading/writing.
pub fn (mut b TextBuffer) set_encoding(encoding string) {
	if b.encoding != encoding {
		b.encoding = encoding
		b.mark_as_dirty()
	}
}

// is_crlf returns the newline type used in the document. LF or CRLF.
pub fn (b TextBuffer) is_crlf() bool {
	return b.newlines_are_crlf
}

// set_crlf changes the newline type without normalizing the document.
pub fn (mut b TextBuffer) set_crlf(crlf bool) {
	b.newlines_are_crlf = crlf
}

// normalize_newlines changes the newline type used in the document.
//
// NOTE: Cannot be undone.
pub fn (mut b TextBuffer) normalize_newlines(crlf bool) {
	target := if crlf { [u8(13), 10] } else { [u8(10)] }
	text := b.read_all()

	mut cursor_offset := b.cursor.offset
	mut cursor_for_rendering_offset := cursor_offset
	if b.cursor_for_rendering_valid {
		cursor_for_rendering_offset = b.cursor_for_rendering.offset
	}

	mut out := []u8{cap: text.len + 16}
	mut off := 0
	for off < text.len {
		if text[off] == `\n` {
			// Determine the length of the existing newline.
			cur_len := if off > 0 && text[off - 1] == `\r` { 2 } else { 1 }
			newline_end := off + 1
			if cur_len == target.len {
				// Newline already matches the target: copy it as-is.
				out << text[newline_end - cur_len..newline_end]
			} else {
				// Adjust the cursor offsets for newlines at or before the
				// cursor (same condition as the Rust original).
				delta := target.len - cur_len
				if newline_end <= cursor_offset {
					cursor_offset += delta
				}
				if newline_end <= cursor_for_rendering_offset {
					cursor_for_rendering_offset += delta
				}
				out << target
			}
			off = newline_end
		} else {
			// Skip the '\r' of a CRLF pair here; it is handled together
			// with the '\n' on the next iteration. A lone '\r' is copied.
			if text[off] == `\r` && off + 1 < text.len && text[off + 1] == `\n` {
				off++
				continue
			}
			out << text[off]
			off++
		}
	}

	b.buffer.clear()
	b.buffer.replace(0, 0, out)
	b.cursor.offset = cursor_offset
	if b.cursor_for_rendering_valid {
		b.cursor_for_rendering.offset = cursor_for_rendering_offset
	}
	b.newlines_are_crlf = crlf
}

// set_insert_final_newline enables/disables automatically inserting a final
// newline when typing at the end of the file.
pub fn (mut b TextBuffer) set_insert_final_newline(enabled bool) {
	b.insert_final_newline = enabled
}

// is_overtype returns whether text is inserted or overtyped when writing.
pub fn (b TextBuffer) is_overtype() bool {
	return b.overtype
}

// set_overtype sets the overtype mode.
pub fn (mut b TextBuffer) set_overtype(overtype bool) {
	b.overtype = overtype
}

// cursor_logical_pos returns the logical cursor position, that is, the
// position in lines and graphemes per line.
pub fn (b TextBuffer) cursor_logical_pos() Point {
	return b.cursor.logical_pos
}

// cursor_visual_pos returns the visual cursor position, that is, the
// position in laid out rows and columns.
pub fn (b TextBuffer) cursor_visual_pos() Point {
	return b.cursor.visual_pos
}

// margin_width returns the width of the left margin.
pub fn (b TextBuffer) margin_width() CoordType {
	return b.margin_width
}

// set_margin_enabled enables/disables the left margin. Returns whether the
// setting actually changed.
pub fn (mut b TextBuffer) set_margin_enabled(enabled bool) bool {
	if b.margin_enabled == enabled {
		return false
	}
	b.margin_enabled = enabled
	b.reflow()
	return true
}

// text_width returns the width of the text contents for layout.
pub fn (b TextBuffer) text_width() CoordType {
	return b.width - b.margin_width
}

// make_cursor_visible asks the TUI system to scroll the buffer and make the
// cursor visible.
pub fn (mut b TextBuffer) make_cursor_visible() {
	b.wants_cursor_visibility = true
}

// take_cursor_visibility_request retrieves a prior make_cursor_visible()
// request.
pub fn (mut b TextBuffer) take_cursor_visibility_request() bool {
	req := b.wants_cursor_visibility
	b.wants_cursor_visibility = false
	return req
}

// is_word_wrap_enabled returns whether word-wrap is enabled.
pub fn (b TextBuffer) is_word_wrap_enabled() bool {
	return b.word_wrap_enabled
}

// set_word_wrap enables or disables word-wrap.
// NOTE: The TUI code is expected to call set_width() sometime after this,
// which then triggers the actual cursor recalculation.
pub fn (mut b TextBuffer) set_word_wrap(enabled bool) {
	if b.word_wrap_enabled != enabled {
		b.word_wrap_enabled = enabled
		b.width = 0 // Force a reflow.
		b.make_cursor_visible()
	}
}

// set_width sets the width available for layout. Returns whether it changed.
pub fn (mut b TextBuffer) set_width(width CoordType) bool {
	if width <= 0 || width == b.width {
		return false
	}
	b.width = width
	b.reflow()
	return true
}

// tab_size returns the tab width.
pub fn (b TextBuffer) tab_size() CoordType {
	return b.tab_size
}

// set_tab_size sets the tab width, clamped to 1-8. Returns whether it changed.
pub fn (mut b TextBuffer) set_tab_size(width CoordType) bool {
	w := clamp_coord(width, 1, 8)
	if w == b.tab_size {
		return false
	}
	b.tab_size = w
	b.reflow()
	return true
}

// tab_size_eval calculates the amount of spaces a tab key press would insert
// at the given column. This also equals the visual width of an actual tab.
fn (b TextBuffer) tab_size_eval(column CoordType) CoordType {
	return b.tab_size - column % b.tab_size
}

// tab_size_prev_column returns the column to which a backspace key press
// would delete to, given a cursor at an indentation of `column`.
fn (b TextBuffer) tab_size_prev_column(column CoordType) CoordType {
	mut x := column - 1
	if x < 0 {
		x = 0
	}
	return x / b.tab_size * b.tab_size
}

// indent_with_tabs returns whether tabs are used for indentation.
pub fn (b TextBuffer) indent_with_tabs() bool {
	return b.indent_with_tabs
}

// set_indent_with_tabs sets whether tabs or spaces are used for indentation.
pub fn (mut b TextBuffer) set_indent_with_tabs(indent_with_tabs bool) {
	b.indent_with_tabs = indent_with_tabs
}

// set_line_highlight_enabled sets whether the line the cursor is on should be
// highlighted.
pub fn (mut b TextBuffer) set_line_highlight_enabled(enabled bool) {
	b.line_highlight_enabled = enabled
}

// language returns the lsh language index (into lsh_languages), -1 if none.
pub fn (b TextBuffer) language() int {
	return b.language
}

// set_language sets the lsh language (index into lsh_languages, -1 = none)
// and invalidates the highlighter cache (Rust TextBuffer::set_language).
pub fn (mut b TextBuffer) set_language(language int) {
	b.language = language
	b.highlighter_cache.invalidate_from(0)
}

// set_ruler sets a ruler column, e.g. 80.
pub fn (mut b TextBuffer) set_ruler(column CoordType) {
	b.ruler = column
}

// ---- GapBuffer helpers (ported in-place, since gap_buffer.v doesn't expose
// copy_from/copy_into/extract_raw) --------------------------------------------

// gap_buffer_extract_raw ports GapBuffer::extract_raw: extracts the byte range
// [start, end) and inserts it into `out` at `out_off`.
// `out_off` of 0 prepends; a value >= out.len appends.
fn gap_buffer_extract_raw(gb GapBuffer, start int, end int, mut out []u8, out_off int) {
	text_len := gb.len()
	mut e := end
	if e > text_len {
		e = text_len
	}
	mut b := start
	if b < 0 {
		b = 0
	}
	if b > e {
		b = e
	}
	mut off := out_off
	if off < 0 {
		off = 0
	}
	if off > out.len {
		off = out.len
	}
	if b >= e {
		return
	}

	mut beg := b
	for beg < e {
		chunk := gb.read_forward(beg)
		mut chunk_end := chunk.len
		if chunk_end > e - beg {
			chunk_end = e - beg
		}
		// V 的公有 API 没有数组-插入-数组（insert 只插单个元素且有 codegen
		// bug，insert_many 是私有的），[]u8 也没有 + 运算，手动拼接 splice。
		mut merged := out[..off].clone()
		merged << chunk[..chunk_end]
		merged << out[off..]
		out = merged.clone()
		beg += chunk_end
		off += chunk_end
	}
}

// gap_buffer_copy_from ports GapBuffer::copy_from. Replaces the entire buffer
// contents with the given document; returns true if the contents changed.
fn gap_buffer_copy_from(mut gb GapBuffer, src ReadableDocument) bool {
	mut off := 0

	// Find the position at which the contents change.
	for {
		dst_chunk := gb.read_forward(off)
		src_chunk := src.read_forward(off)
		dst_len := dst_chunk.len
		src_len := src_chunk.len
		mut len := dst_len
		if src_len < len {
			len = src_len
		}
		if dst_chunk[..len] != src_chunk[..len] {
			break // The contents differ.
		}
		if len == 0 {
			if dst_len == src_len {
				return false // Both done simultaneously. -> Done.
			}
			break // One of the two is shorter.
		}
		off += len
	}

	// Update the buffer starting at `off`.
	for {
		chunk := src.read_forward(off)
		gb.replace(off, offset_target_max, chunk)
		off += chunk.len

		// No more data to copy -> Done. Checking _after_ replace() ensures
		// the initial `off..MAX` range is deleted (buffer becoming empty).
		if chunk.len == 0 {
			return true
		}
	}
	return true
}

// gap_buffer_copy_into ports GapBuffer::copy_into. Copies the contents of the
// buffer into the destination document.
fn gap_buffer_copy_into(gb GapBuffer, mut dst WriteableDocument) {
	mut beg := 0
	mut off := 0
	for {
		chunk := gb.read_forward(off)

		// The first write will be 0..MAX and effectively clears the
		// destination; every subsequent write appends.
		dst.replace(beg, offset_target_max, chunk)
		beg = offset_target_max

		off += chunk.len
		if off >= gb.len() {
			break
		}
	}
}

// ---- Content swapping & file I/O ---------------------------------------------

// copy_from_str replaces the entire buffer contents with the given document.
// The source can have any number of lines; gap_buffer_copy_from() truncates
// or extends the existing buffer to match the source exactly, so no
// post-trim step is needed here (the earlier line-count assumption has been
// removed — see `recalc_after_content_swap` for the new line-count update).
pub fn (mut b TextBuffer) copy_from_str(text ReadableDocument) {
	if gap_buffer_copy_from(mut b.buffer, text) {
		b.recalc_after_content_swap()
	}
}

fn (mut b TextBuffer) recalc_after_content_swap() {
	// If the buffer was changed, nothing we previously saved can be relied upon.
	b.undo_stack = []HistoryEntry{}
	b.redo_stack = []HistoryEntry{}
	b.last_history_type = HistoryType.other
	b.cursor = Cursor{}
	b.set_selection(OptSelection{})
	b.mark_as_clean()

	// Recount logical lines from the new content. Without this, copy_from_str
	// (used for redirected-stdin loading) would leave stats.logical_lines at
	// the empty-buffer default of 1 regardless of how many \n were inserted,
	// and the gutter / cursor would render as if the document had only one
	// line. logical_lines = (\n count) + 1, matching the file-load path
	// (see read_initial) and Rust's split('\n') semantics: a trailing \n
	// produces one extra empty line.
	text := b.read_all()
	mut newlines := CoordType(0)
	for c in text {
		if c == `\n` {
			newlines++
		}
	}
	if text.len == 0 {
		b.stats.logical_lines = 1
		b.stats.visual_lines = 1
	} else {
		b.stats.logical_lines = newlines + 1
		b.stats.visual_lines = newlines + 1
	}

	b.reflow()
	b.highlighter_cache.invalidate_from(0)
}

// save_as_string copies the contents of the buffer into the destination
// document and marks the buffer as clean.
pub fn (mut b TextBuffer) save_as_string(mut dst WriteableDocument) {
	gap_buffer_copy_into(b.buffer, mut dst)
	b.mark_as_clean()
}

// detect_bom returns the encoding name indicated by the given BOM bytes, or
// an empty string if there is no BOM.
fn detect_bom(bytes []u8) string {
	if bytes.len >= 4 {
		if bytes[0] == 0xFF && bytes[1] == 0xFE && bytes[2] == 0x00 && bytes[3] == 0x00 {
			return 'UTF-32LE'
		}
		if bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0xFE && bytes[3] == 0xFF {
			return 'UTF-32BE'
		}
		if bytes[0] == 0x84 && bytes[1] == 0x31 && bytes[2] == 0x95 && bytes[3] == 0x33 {
			return 'GB18030'
		}
	}
	if bytes.len >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
		return 'UTF-8'
	}
	if bytes.len >= 2 {
		if bytes[0] == 0xFF && bytes[1] == 0xFE {
			return 'UTF-16LE'
		}
		if bytes[0] == 0xFE && bytes[1] == 0xFF {
			return 'UTF-16BE'
		}
	}
	return ''
}

// read_file reads a file from disk into the text buffer, detecting encoding
// and BOM.
//
// Difference from the Rust original: the Rust version takes a `&mut File`,
// transcodes non-UTF-8 encodings via ICU and reads with SIMD-accelerated gap
// allocation. This port takes a path, reads in 64KiB chunks and only handles
// UTF-8 (with BOM); other encodings are read as raw bytes without transcoding.
pub fn (mut b TextBuffer) read_file(path string) ! {
	mut f := os.open(path) or { return err }
	defer { f.close() }

	// Read enough bytes to detect the BOM.
	// NOTE: V's os.File.read() returns os.Eof at end of file; treat it
	// like a short read of 0 bytes (Rust's read() returns Ok(0)).
	mut first := []u8{ len: bom_max_len }
	first_chunk_len := f.read(mut first) or {
		if err is os.Eof {
			0
		} else {
			return err
		}
	}

	// Determine the encoding.
	detected := detect_bom(first[..first_chunk_len])
	if detected.len > 0 {
		b.encoding = detected
	} else {
		b.encoding = 'UTF-8'
	}

	b.buffer.clear()

	done := first_chunk_len == 0
	mut chunk := first[0..first_chunk_len].clone()

	// Strip the UTF-8 BOM, if this is a UTF-8 file.
	if b.encoding == 'UTF-8' && chunk.len >= 3 && chunk[0] == 0xEF && chunk[1] == 0xBB
		&& chunk[2] == 0xBF {
		b.encoding = 'UTF-8 BOM'
		chunk = chunk[3..].clone()
	}
	if chunk.len > 0 {
		b.buffer.replace(0, 0, chunk)
	}

	if !done {
		// Read the rest of the file in 64KiB chunks (Rust: SIMD + gap reads).
		mut buf := []u8{ len: 64 * kibi }
		for {
			n := f.read(mut buf) or {
				if err is os.Eof {
					0
				} else {
					return err
				}
			}
			if n == 0 {
				break
			}
			off := b.buffer.len()
			b.buffer.replace(off, off, buf[..n])
		}
	}

	// Figure out
	// * the logical line count
	// * the newline type (LF or CRLF)
	// * the indentation type (tabs or spaces)
	// * whether there's a final newline
	text := b.read_all()
	mut offset := 0
	mut lines := CoordType(0)
	// Number of lines ending in CRLF.
	mut crlf_count := 0
	// Number of lines starting with a tab.
	mut tab_indentations := 0
	// Number of lines starting with a space.
	mut space_indentations := 0
	// Histogram of the indentation depth of lines starting with 2..=8 spaces.
	mut space_indentation_sizes := [7]int{}

	for {
		// Check if the line starts with a tab.
		if offset < text.len && text[offset] == `\t` {
			tab_indentations++
		} else {
			// Otherwise, count how many spaces the line starts with.
			// Searching for >8 spaces allows us to reject lines that have
			// more than 1 level of indentation.
			mut space_indentation := 0
			for space_indentation < 9 && offset + space_indentation < text.len
				&& text[offset + space_indentation] == ` ` {
				space_indentation++
			}

			// Reject lines starting with 0 or 1 spaces, too fickle as heuristics.
			if space_indentation >= 2 && space_indentation <= 8 {
				space_indentations++

				// An indentation depth of 6 may be two 3-space indentations
				// or three 2-space indentations; 4 may be two 2-space ones;
				// 8 may be two 4- or four 2-space ones. Increment all possible
				// histogram slots.
				space_indentation_sizes[space_indentation - 2]++
				if space_indentation & 4 != 0 {
					space_indentation_sizes[0]++
				}
				if space_indentation == 6 || space_indentation == 8 {
					space_indentation_sizes[space_indentation / 2 - 2]++
				}
			}
		}

		offset, lines = lines_fwd(text, offset, lines, lines + 1)

		// Check if the preceding line ended in CRLF.
		if offset >= 2 && text[offset - 2] == `\r` && text[offset - 1] == `\n` {
			crlf_count++
		}

		// We'll limit our heuristics to the first 1000 lines.
		if offset >= text.len || lines >= 1000 {
			break
		}
	}

	// Assume CRLF if more than half of the lines end in CRLF. If there is
	// only a single line, use the platform default (LF on macOS/Linux).
	newlines_are_crlf := if lines == 0 { false } else { crlf_count > lines / 2 }

	// Assume tabs if there are more lines starting with tabs than with spaces.
	indent_with_tabs := tab_indentations > space_indentations
	mut tab_size := CoordType(4)
	if indent_with_tabs {
		// Tabs will get a visual size of 4 spaces by default.
		tab_size = 4
	} else {
		// Otherwise, assume the most common indentation depth. If there are
		// conflicting depths, prefer the maximum (we incremented the 2-space
		// histogram slot when encountering 4-space indentation and so on).
		mut max := 0
		tab_size = 4
		for i in 0..7 {
			count := space_indentation_sizes[i]
			if count >= max {
				max = count
				tab_size = CoordType(i) + 2
			}
		}
	}

	// If the file has more than 1000 lines, count how many are remaining.
	if offset < text.len {
		_, lines = lines_fwd(text, offset, lines, coord_type_max)
	}

	final_newline := text.len > 0 && text[text.len - 1] == `\n`

	// Add 1, because the last line doesn't end in a newline.
	b.stats.logical_lines = lines + 1
	b.stats.visual_lines = b.stats.logical_lines
	b.newlines_are_crlf = newlines_are_crlf
	b.insert_final_newline = final_newline
	b.indent_with_tabs = indent_with_tabs
	b.tab_size = tab_size

	b.recalc_after_content_swap()
}

// write_file writes the text buffer contents to a file, handling BOM and
// encoding.
//
// Difference from the Rust original: takes a path instead of a `&mut File`
// and doesn't transcode non-UTF-8 encodings (UTF-8 only in this port).
pub fn (mut b TextBuffer) write_file(path string) ! {
	mut f := os.create(path) or { return err }
	defer { f.close() }

	if b.encoding == 'UTF-8 BOM' {
		f.write([u8(0xEF), 0xBB, 0xBF]) or { return err }
	}

	mut offset := 0
	for offset < b.buffer.len() {
		chunk := b.buffer.read_forward(offset)
		if chunk.len == 0 {
			break
		}
		f.write(chunk) or { return err }
		offset += chunk.len
	}

	b.mark_as_clean()
}

// reflow recalculates the margin width, word wrap column and cursor position.
pub fn (mut b TextBuffer) reflow() {
	b.reflow_internal(true)
}

fn (mut b TextBuffer) recalc_after_content_changed() {
	b.reflow_internal(false)
}

fn (mut b TextBuffer) reflow_internal(force bool) {
	word_wrap_column_before := b.word_wrap_column

	// +4: the digit count of the largest line number (1-based) plus " │ ".
	b.margin_width = if b.margin_enabled {
		ilog10(b.stats.logical_lines) + 4
	} else {
		0
	}

	text_width := b.text_width()
	// 2 columns are required, because otherwise wide glyphs wouldn't ever fit.
	b.word_wrap_column = if b.word_wrap_enabled && text_width >= 2 {
		text_width
	} else {
		0
	}

	b.cursor_for_rendering_valid = false

	if force || b.word_wrap_column != word_wrap_column_before {
		// Recalculate the cursor position.
		start := if b.word_wrap_column > 0 {
			Cursor{}
		} else {
			b.goto_line_start(b.cursor, b.cursor.logical_pos.y)
		}
		b.cursor = b.cursor_move_to_logical_internal(start, b.cursor.logical_pos)

		// Recalculate the line statistics.
		if b.word_wrap_column > 0 {
			end := b.cursor_move_to_logical_internal(b.cursor, point_max())
			b.stats.visual_lines = end.visual_pos.y + 1
		} else {
			b.stats.visual_lines = b.stats.logical_lines
		}
	}
}

// ---- Coordinate helpers ------------------------------------------------------

fn coord_max(a CoordType, b CoordType) CoordType {
	return if a > b { a } else { b }
}

fn coord_min(a CoordType, b CoordType) CoordType {
	return if a < b { a } else { b }
}

fn coord_abs(a CoordType) CoordType {
	return if a < 0 { -a } else { a }
}

fn coord_sign(a CoordType) int {
	if a < 0 {
		return -1
	}
	if a > 0 {
		return 1
	}
	return 0
}

// ---- Selection ----------------------------------------------------------------

// has_selection returns whether there's a current selection.
pub fn (b TextBuffer) has_selection() bool {
	return b.selection.valid
}

// set_selection sets the current selection, discarding empty selections.
// Returns the new selection generation.
fn (mut b TextBuffer) set_selection(sel OptSelection) u32 {
	if sel.valid && sel.beg.compare(sel.end) == 0 {
		b.selection = OptSelection{}
	} else {
		b.selection = sel
	}
	b.selection_generation++
	return b.selection_generation
}

// selection_update_offset moves the cursor by `offset` and updates the
// selection to contain it.
pub fn (mut b TextBuffer) selection_update_offset(offset int) {
	b.set_cursor_for_selection(b.cursor_move_to_offset_internal(b.cursor, offset))
}

// selection_update_visual moves the cursor to `visual_pos` and updates the
// selection to contain it.
pub fn (mut b TextBuffer) selection_update_visual(visual_pos Point) {
	b.set_cursor_for_selection(b.cursor_move_to_visual_internal(b.cursor, visual_pos))
}

// selection_update_logical moves the cursor to `logical_pos` and updates the
// selection to contain it.
pub fn (mut b TextBuffer) selection_update_logical(logical_pos Point) {
	b.set_cursor_for_selection(b.cursor_move_to_logical_internal(b.cursor, logical_pos))
}

// selection_update_delta moves the cursor by `delta` and updates the
// selection to contain it.
pub fn (mut b TextBuffer) selection_update_delta(granularity CursorMovement, delta CoordType) {
	b.set_cursor_for_selection(b.cursor_move_delta_internal(b.cursor, granularity, delta))
}

// select_word selects the current word.
pub fn (mut b TextBuffer) select_word() {
	beg, end := word_select(ReadableDocument(b.buffer), b.cursor.offset)
	mut beg_cursor := b.cursor_move_to_offset_internal(b.cursor, beg)
	mut end_cursor := b.cursor_move_to_offset_internal(beg_cursor, end)
	b.set_cursor(end_cursor)
	b.set_selection(OptSelection{
		valid: true
		beg:   beg_cursor.logical_pos
		end:   end_cursor.logical_pos
	})
}

// select_line selects the current line.
pub fn (mut b TextBuffer) select_line() {
	beg_cursor := b.cursor_move_to_logical_internal(b.cursor,
		Point{ x: 0, y: b.cursor.logical_pos.y })
	end_cursor := b.cursor_move_to_logical_internal(beg_cursor,
		Point{ x: 0, y: b.cursor.logical_pos.y + 1 })
	b.set_cursor(end_cursor)
	b.set_selection(OptSelection{
		valid: true
		beg:   beg_cursor.logical_pos
		end:   end_cursor.logical_pos
	})
}

// select_all selects the entire document.
pub fn (mut b TextBuffer) select_all() {
	beg_cursor := Cursor{}
	end_cursor := b.cursor_move_to_logical_internal(beg_cursor, point_max())
	b.set_cursor(end_cursor)
	b.set_selection(OptSelection{
		valid: true
		beg:   beg_cursor.logical_pos
		end:   end_cursor.logical_pos
	})
}

// start_selection starts a new selection, if there's none already.
// NOTE: like the Rust original, set_selection() discards zero-length
// selections, so this only "arms" the selection until the cursor moves.
pub fn (mut b TextBuffer) start_selection() {
	if !b.selection.valid {
		b.set_selection(OptSelection{
			valid: true
			beg:   b.cursor.logical_pos
			end:   b.cursor.logical_pos
		})
	}
}

// clear_selection destroys the current selection. Returns whether there was
// a selection to clear.
pub fn (mut b TextBuffer) clear_selection() bool {
	had_selection := b.selection.valid
	b.set_selection(OptSelection{})
	return had_selection
}

// ---- Cursor movement -----------------------------------------------------------

fn (b TextBuffer) measurement_config() MeasurementConfig {
	return new_measurement_config(b.buffer).with_word_wrap_column(b.word_wrap_column).with_tab_size(b.tab_size)
}

// goto_line_start moves the cursor to the start of the line with the given
// logical `y` coordinate, using the fast line-seeking pass.
fn (b TextBuffer) goto_line_start(cursor Cursor, y CoordType) Cursor {
	mut result := cursor
	mut seek_to_line_start := true

	if y > result.logical_pos.y {
		for y > result.logical_pos.y {
			chunk := b.buffer.read_forward(result.offset)
			if chunk.len == 0 {
				break
			}

			delta, line := lines_fwd(chunk, 0, result.logical_pos.y, y)
			result.offset += delta
			result.logical_pos.y = line
		}

		// If we're at the end of the buffer, we could either be there because
		// the last character in the buffer is genuinely a newline, or because
		// the buffer ends in a line of text without trailing newline. The only
		// way to make sure is to seek backwards to the line start again.
		seek_to_line_start = result.offset == b.text_length() && result.offset != cursor.offset
	}

	if seek_to_line_start {
		for {
			chunk := b.buffer.read_backward(result.offset)
			if chunk.len == 0 {
				break
			}

			delta, line := lines_bwd(chunk, chunk.len, result.logical_pos.y, y)
			result.offset -= chunk.len - delta
			result.logical_pos.y = line
			if delta > 0 {
				break
			}
		}
	}

	if result.offset == cursor.offset {
		return result
	}

	result.logical_pos.x = 0
	result.visual_pos.x = 0
	result.visual_pos.y = result.logical_pos.y
	result.column = 0
	result.wrap_opp = false

	if b.word_wrap_column > 0 {
		upward := result.offset < cursor.offset
		top, bottom := if upward { result, cursor } else { cursor, result }

		mut cfg := b.measurement_config().with_cursor(top)
		mut bottom_remeasured := cfg.goto_logical(bottom.logical_pos)

		// Visual positions can be ambiguous: a single logical position can map
		// to two visual positions (one at the end of the preceding line in
		// front of a wrap, another at the start of the next line after the
		// same wrap). This only applies when going upwards.
		if upward {
			a := bottom_remeasured.visual_pos.x
			bx := bottom.visual_pos.x
			mut adj := CoordType(0)
			if a != 0 && bx == 0 {
				adj = 1
			} else if a == 0 && bx != 0 {
				adj = -1
			}
			bottom_remeasured.visual_pos.y += adj
		}

		mut delta := bottom_remeasured.visual_pos.y - top.visual_pos.y
		if upward {
			delta = -delta
		}

		result.visual_pos.y = cursor.visual_pos.y + delta
	}

	return result
}

// cursor_move_to_offset_internal navigates **forward or backward** to the
// given absolute offset.
fn (b TextBuffer) cursor_move_to_offset_internal(cursor Cursor, offset int) Cursor {
	mut cur := cursor
	if offset == cur.offset {
		return cur
	}

	// goto_line_start() is fast for seeking across lines _if_ line wrapping is
	// disabled. For backward seeking we have to use it either way.
	if b.word_wrap_column <= 0 && offset - cur.offset > 1024 {
		for {
			next := b.goto_line_start(cur, cur.logical_pos.y + 1)
			// Stop when we either ran past the target offset, or when we hit
			// the end of the buffer and goto_line_start backtracked to the
			// line start.
			if next.offset > offset || next.offset <= cur.offset {
				break
			}
			cur = next
		}
	}

	for offset < cur.offset {
		cur = b.goto_line_start(cur, cur.logical_pos.y - 1)
	}

	mut cfg := b.measurement_config().with_cursor(cur)
	return cfg.goto_offset(offset)
}

// cursor_move_to_logical_internal navigates **forward** to the given logical
// position.
fn (b TextBuffer) cursor_move_to_logical_internal(cursor Cursor, pos Point) Cursor {
	mut cur := cursor
	clamped := Point{ x: coord_max(pos.x, 0), y: coord_max(pos.y, 0) }

	if clamped.compare(cur.logical_pos) == 0 {
		return cur
	}

	// goto_line_start() is the fastest way for seeking across lines. We always
	// use it if the requested `.y` position is different, and also if `.x` is
	// smaller, because goto_logical() cannot seek backwards.
	if clamped.y != cur.logical_pos.y || clamped.x < cur.logical_pos.x {
		cur = b.goto_line_start(cur, clamped.y)
	}

	mut cfg := b.measurement_config().with_cursor(cur)
	return cfg.goto_logical(clamped)
}

// cursor_move_to_visual_internal navigates **forward** to the given visual
// position.
fn (b TextBuffer) cursor_move_to_visual_internal(cursor Cursor, pos Point) Cursor {
	mut cur := cursor
	clamped := Point{ x: coord_max(pos.x, 0), y: coord_max(pos.y, 0) }

	if clamped.compare(cur.visual_pos) == 0 {
		return cur
	}

	if b.word_wrap_column <= 0 {
		// Identical to the fast-pass in cursor_move_to_logical_internal().
		if clamped.y != cur.visual_pos.y || clamped.x < cur.visual_pos.x {
			cur = b.goto_line_start(cur, clamped.y)
		}
	} else {
		// goto_visual() can only seek forward, so we need to seek backward
		// here if needed.
		for clamped.y < cur.visual_pos.y {
			cur = b.goto_line_start(cur, cur.logical_pos.y - 1)
		}
		if clamped.y == cur.visual_pos.y && clamped.x < cur.visual_pos.x {
			cur = b.goto_line_start(cur, cur.logical_pos.y)
		}
	}

	mut cfg := b.measurement_config().with_cursor(cur)
	return cfg.goto_visual(clamped)
}

// cursor_move_delta_internal moves the cursor by the given delta.
fn (b TextBuffer) cursor_move_delta_internal(cursor Cursor, granularity CursorMovement, delta_in CoordType) Cursor {
	mut cur := cursor
	mut delta := delta_in
	if delta == 0 {
		return cur
	}

	sign := if delta > 0 { 1 } else { -1 }

	match granularity {
		.grapheme {
			start_x := if delta > 0 { CoordType(0) } else { coord_type_max }

			for {
				target_x := cur.logical_pos.x + delta

				cur = b.cursor_move_to_logical_internal(cur,
					Point{ x: target_x, y: cur.logical_pos.y })

				// We can stop if we ran out of remaining delta (or perhaps ran
				// past the goal; in either case the sign would've changed), or
				// if we hit the beginning or end of the buffer.
				delta = target_x - cur.logical_pos.x
				if coord_sign(delta) != sign || (delta < 0 && cur.offset == 0)
					|| (delta > 0 && cur.offset >= b.text_length()) {
					break
				}

				cur = b.cursor_move_to_logical_internal(cur,
					Point{ x: start_x, y: cur.logical_pos.y + sign })

				// We crossed a newline which counts for 1 grapheme cluster.
				// So, we also need to run the same check again.
				delta -= sign
				if coord_sign(delta) != sign || cur.offset == 0
					|| cur.offset >= b.text_length() {
					break
				}
			}
		}
		.word {
			doc := ReadableDocument(b.buffer)
			mut offset := b.cursor.offset

			for delta != 0 {
				if delta < 0 {
					offset = word_backward(doc, offset)
				} else {
					offset = word_forward(doc, offset)
				}
				delta -= sign
			}

			cur = b.cursor_move_to_offset_internal(cur, offset)
		}
	}

	return cur
}

// cursor_move_to_offset moves the cursor to the given offset.
pub fn (mut b TextBuffer) cursor_move_to_offset(offset int) {
	b.set_cursor(b.cursor_move_to_offset_internal(b.cursor, offset))
}

// cursor_move_to_logical moves the cursor to the given logical position.
pub fn (mut b TextBuffer) cursor_move_to_logical(pos Point) {
	b.set_cursor(b.cursor_move_to_logical_internal(b.cursor, pos))
}

// cursor_move_to_visual moves the cursor to the given visual position.
pub fn (mut b TextBuffer) cursor_move_to_visual(pos Point) {
	b.set_cursor(b.cursor_move_to_visual_internal(b.cursor, pos))
}

// cursor_move_delta moves the cursor by the given delta.
pub fn (mut b TextBuffer) cursor_move_delta(granularity CursorMovement, delta CoordType) {
	b.set_cursor(b.cursor_move_delta_internal(b.cursor, granularity, delta))
}

// set_cursor sets the cursor to the given position and clears the selection.
// NOTE: this function performs no checks that the cursor is valid. "Valid"
// means the TextBuffer has not been modified since you received the cursor.
pub fn (mut b TextBuffer) set_cursor(cursor Cursor) {
	b.set_cursor_internal(cursor)
	b.last_history_type = HistoryType.other
	b.set_selection(OptSelection{})
}

fn (mut b TextBuffer) set_cursor_for_selection(cursor Cursor) {
	beg := if b.selection.valid { b.selection.beg } else { b.cursor.logical_pos }

	b.set_cursor_internal(cursor)
	b.last_history_type = HistoryType.other

	end := b.cursor.logical_pos
	if beg.compare(end) == 0 {
		b.set_selection(OptSelection{})
	} else {
		b.set_selection(OptSelection{ valid: true, beg: beg, end: end })
	}
}

fn (mut b TextBuffer) set_cursor_internal(cursor Cursor) {
	assert cursor.offset <= b.text_length()
	assert cursor.logical_pos.x >= 0
	assert cursor.logical_pos.y >= 0
	assert cursor.logical_pos.y <= b.stats.logical_lines
	assert cursor.visual_pos.x >= 0
	assert b.word_wrap_column <= 0 || cursor.visual_pos.x <= b.word_wrap_column
	assert cursor.visual_pos.y >= 0
	assert cursor.visual_pos.y <= b.stats.visual_lines
	b.cursor = cursor
}

// ---- Byte helpers -------------------------------------------------------------

// memchr2 finds the first occurrence of either `a` or `b` in `text` starting
// at `start`. Returns text.len if neither occurs.
fn memchr2(a u8, b u8, text []u8, start int) int {
	for i := start; i < text.len; i++ {
		c := text[i]
		if c == a || c == b {
			return i
		}
	}
	return text.len
}

// find_crlf finds the first CR or LF byte at or after `start`.
fn find_crlf(text []u8, start int) int {
	return memchr2(`\r`, `\n`, text, start)
}

// bytes_end_with_nl reports whether the byte slice ends with a LF byte.
fn bytes_end_with_nl(text []u8) bool {
	return text.len > 0 && text[text.len - 1] == `\n`
}

// ---- Clipboard -----------------------------------------------------------------

// cut cuts the selection (or the current line) into the clipboard.
pub fn (mut b TextBuffer) cut(mut clipboard Clipboard) {
	b.cut_copy(mut clipboard, true)
}

// copy copies the selection (or the current line) into the clipboard.
pub fn (mut b TextBuffer) copy(mut clipboard Clipboard) {
	b.cut_copy(mut clipboard, false)
}

fn (mut b TextBuffer) cut_copy(mut clipboard Clipboard, cut bool) {
	line_copy := !b.has_selection()
	selection := b.extract_selection(cut)
	clipboard.write(selection)
	clipboard.write_was_line_copy(line_copy)
}

// paste pastes the clipboard contents at the cursor. With `single_line`, only
// the first line is pasted.
pub fn (mut b TextBuffer) paste(clipboard Clipboard, single_line bool) {
	mut data := clipboard.read()

	if single_line {
		// Bracketed paste uses CR instead of LF/CRLF, so we can't use
		// skip_newline(); find the first CR or LF directly.
		off := find_crlf(data, 0)
		data = strip_newline(data[..off])
	}

	if data.len == 0 {
		return
	}

	pos := b.cursor_logical_pos()
	mut at := if clipboard.is_line_copy() {
		b.goto_line_start(b.cursor, pos.y)
	} else {
		b.cursor
	}

	b.write(data, at, true)

	if clipboard.is_line_copy() {
		b.cursor_move_to_logical(Point{ x: pos.x, y: pos.y + 1 })
	}
}

// ---- Writing --------------------------------------------------------------------

// write_canon inserts the user input `text` at the current cursor position,
// replacing tabs with whitespace if needed, etc.
pub fn (mut b TextBuffer) write_canon(text []u8) {
	b.write(text, b.cursor, false)
}

// write_raw inserts `text` as-is at the current cursor position. The only
// transformation applied is that newlines are normalized.
pub fn (mut b TextBuffer) write_raw(text []u8) {
	b.write(text, b.cursor, true)
}

fn (mut b TextBuffer) write(text []u8, at Cursor, raw bool) {
	history_type := if raw { HistoryType.other } else { HistoryType.write }
	mut edit_begun := false

	// If we have an active selection, writing an empty `text` will still
	// delete the selection. As such, we check this first.
	sel_ok, sel_beg, sel_end := b.selection_range_internal(false)
	if sel_ok {
		b.edit_begin(history_type, sel_beg)
		b.edit_delete(sel_end)
		b.set_selection(OptSelection{})
		edit_begun = true
	}

	// If the text is empty the remaining code won't do anything, allowing us
	// to exit early.
	if text.len == 0 {
		// ...we still need to end any active edit session though.
		if edit_begun {
			b.edit_end()
		}
		return
	}

	if !edit_begun {
		b.edit_begin(history_type, at)
	}

	mut offset := 0
	mut newline_buffer := []u8{}

	for {
		// Bracketed paste uses CR instead of LF/CRLF, so we can't use
		// skip_newline() here.
		offset_next := find_crlf(text, offset)
		line := text[offset..offset_next]
		column_before := b.cursor.logical_pos.x

		// Write the contents of the line into the buffer.
		mut line_off := 0
		for line_off < line.len {
			// Split the line into chunks of non-tabs and tabs.
			mut plain := line.clone()
			if !raw && !b.indent_with_tabs {
				end := memchr2(`\t`, `\t`, line, line_off)
				plain = line[line_off..end].clone()
			}

			// Non-tabs are written as-is; the outer loop already handles
			// newline translation.
			b.edit_write(plain)
			line_off += plain.len

			// Now replace tabs with spaces.
			for line_off < line.len && line[line_off] == `\t` {
				spaces := b.tab_size_eval(b.cursor.column)
				b.edit_write(tab_whitespace[..int(spaces)].bytes())
				line_off++
			}
		}

		if !raw && b.overtype {
			delete_count := b.cursor.logical_pos.x - column_before
			end := b.cursor_move_to_logical_internal(b.cursor,
				Point{ x: b.cursor.logical_pos.x + delete_count, y: b.cursor.logical_pos.y })
			b.edit_delete(end)
		}

		offset += line.len
		if offset >= text.len {
			break
		}

		// First, write the newline.
		newline_buffer = if b.newlines_are_crlf { [u8(13), 10] } else { [u8(10)] }

		if !raw {
			// We'll give the next line the same indentation as the previous
			// one. This block figures out how much that is.
			line_beg := b.goto_line_start(b.cursor, b.cursor.logical_pos.y)
			limit := b.cursor.offset
			mut off := line_beg.offset
			mut newline_indentation := CoordType(0)

			outer: for off < limit {
				mut chunk := b.buffer.read_forward(off)
				chunk = chunk[0..coord_min(CoordType(chunk.len), CoordType(limit - off))].clone()

				for c in chunk {
					if c == ` ` {
						newline_indentation++
					} else if c == `\t` {
						newline_indentation += b.tab_size_eval(newline_indentation)
					} else {
						break outer
					}
				}

				off += chunk.len
			}

			// If tabs are enabled, add as many tabs as we can.
			if b.indent_with_tabs {
				tab_count := newline_indentation / b.tab_size
				for _ in 0..int(tab_count) {
					newline_buffer << `\t`
				}
				newline_indentation -= tab_count * b.tab_size
			}

			// If tabs are disabled, or if the indentation wasn't a multiple of
			// the tab size, add spaces to make up the difference.
			for _ in 0..int(newline_indentation) {
				newline_buffer << ` `
			}
		}

		b.edit_write(newline_buffer)

		// Skip one CR/LF/CRLF.
		if offset >= text.len {
			break
		}
		if text[offset] == `\r` {
			offset++
		}
		if offset >= text.len {
			break
		}
		if text[offset] == `\n` {
			offset++
		}
		if offset >= text.len {
			break
		}
	}

	// POSIX mandates that all valid lines end in a newline. In order to not
	// annoy people with this, we only add a newline if you just edited the
	// very end of the buffer.
	if b.insert_final_newline && b.cursor.offset > 0 && b.cursor.offset == b.text_length()
		&& b.cursor.logical_pos.x > 0 {
		saved_cursor := b.cursor
		b.edit_write(if b.newlines_are_crlf { [u8(13), 10] } else { [u8(10)] })
		// Can't use set_cursor_internal here, because we haven't updated the
		// line stats yet.
		b.cursor = saved_cursor
	}

	b.edit_end()
}

// delete deletes grapheme clusters from the buffer. `delta` is expected to be
// -1 for backspace and 1 for delete. If there's a current selection, it will
// be deleted and `delta` ignored. The selection is cleared after the call.
pub fn (mut b TextBuffer) delete(granularity CursorMovement, delta CoordType) {
	if delta == 0 {
		return
	}

	mut beg := Cursor{}
	mut end := Cursor{}

	sel_ok, sel_beg, sel_end := b.selection_range_internal(false)
	if sel_ok {
		beg = sel_beg
		end = sel_end
	} else {
		if (delta < 0 && b.cursor.offset == 0)
			|| (delta > 0 && b.cursor.offset >= b.text_length()) {
			// Nothing to delete.
			return
		}

		beg = b.cursor
		end = b.cursor_move_delta_internal(beg, granularity, delta)
		if beg.offset == end.offset {
			return
		}
		if beg.offset > end.offset {
			tmp := beg
			beg = end
			end = tmp
		}
	}

	b.edit_begin(HistoryType.delete, beg)
	b.edit_delete(end)
	b.edit_end()

	b.set_selection(OptSelection{})
}

// ---- Indentation -----------------------------------------------------------------

// indent_end_logical_pos returns the logical position of the first character
// on this line. Returns `.x == 0` if there are no non-whitespace characters.
pub fn (b TextBuffer) indent_end_logical_pos() Point {
	cursor := b.goto_line_start(b.cursor, b.cursor.logical_pos.y)
	chars, _ := b.measure_indent_internal(cursor.offset, coord_type_max)
	return Point{ x: chars, y: cursor.logical_pos.y }
}

// indent_change indents/unindents the current selection or line.
pub fn (mut b TextBuffer) indent_change(direction CoordType) {
	selection := b.selection
	mut selection_beg := b.cursor.logical_pos
	mut selection_end := selection_beg

	if selection.valid {
		selection_beg = selection.beg
		selection_end = selection.end
	}

	if direction >= 0 && (!selection.valid || selection.beg.y == selection.end.y) {
		b.write_canon([u8(9)])
		return
	}

	b.edit_begin_grouping()

	beg_y := coord_min(selection_beg.y, selection_end.y)
	end_y := coord_max(selection_beg.y, selection_end.y)

	for yi in int(beg_y)..int(end_y) + 1 {
		y := CoordType(yi)
		b.cursor_move_to_logical(Point{ x: 0, y: y })

		line_start_offset := b.cursor.offset
		curr_chars, curr_columns := b.measure_indent_internal(line_start_offset,
			coord_type_max)

		b.cursor_move_to_logical(Point{ x: curr_chars, y: b.cursor.logical_pos.y })

		mut delta := CoordType(0)

		if direction < 0 {
			// Unindent the line. If there's no indentation, skip.
			if curr_columns <= 0 {
				continue
			}

			prev_chars, _ := b.measure_indent_internal(line_start_offset,
				b.tab_size_prev_column(curr_columns))

			delta = prev_chars - curr_chars
			b.delete(CursorMovement.grapheme, delta)
		} else {
			// Indent the line. `self.cursor` is already at the level of
			// indentation.
			delta = b.tab_size_eval(curr_columns)
			b.write_canon([u8(9)])
		}

		// As the lines get unindented, the selection should shift with them.
		if y == selection_beg.y {
			selection_beg.x += delta
		}
		if y == selection_end.y {
			selection_end.x += delta
		}
	}
	b.edit_end_grouping()

	// Move the cursor to the new end of the selection.
	b.set_cursor_internal(b.cursor_move_to_logical_internal(b.cursor, selection_end))

	// NOTE: If the selection was previously `None`, it should continue to be
	// `None` after this.
	if selection.valid {
		b.set_selection(OptSelection{ valid: true, beg: selection_beg, end: selection_end })
	} else {
		b.set_selection(OptSelection{})
	}
}

// measure_indent_internal measures the indentation at `offset`, returning the
// number of characters and the number of columns (tabs expanded) consumed.
fn (b TextBuffer) measure_indent_internal(offset int, max_columns CoordType) (CoordType, CoordType) {
	mut off := offset
	mut chars := CoordType(0)
	mut columns := CoordType(0)

	outer: for {
		chunk := b.buffer.read_forward(off)
		if chunk.len == 0 {
			break
		}

		for c in chunk {
			mut next := CoordType(0)
			match c {
				` ` {
					next = columns + 1
				}
				`\t` {
					next = columns + b.tab_size_eval(columns)
				}
				else {
					break outer
				}
			}
			if next > max_columns {
				break outer
			}
			chars++
			columns = next
		}

		off += chunk.len

		// No need to do another round if we already got the exact amount.
		if columns >= max_columns {
			break
		}
	}

	return chars, columns
}

// ---- Moving lines -----------------------------------------------------------------

// move_selected_lines displaces the current cursor or selection line(s) in the
// given direction.
pub fn (mut b TextBuffer) move_selected_lines(direction MoveLineDirection) {
	selection := b.selection
	cursor := b.cursor

	// If there's no selection, we move the line the cursor is on instead.
	mut beg := CoordType(0)
	mut end := CoordType(0)
	if selection.valid {
		beg, end = minmax_coords(selection.beg.y, selection.end.y)
	} else {
		beg = cursor.logical_pos.y
		end = cursor.logical_pos.y
	}

	// Check if this would be a no-op.
	mut noop := false
	if direction == .up {
		noop = beg <= 0
	} else {
		noop = end >= b.stats.logical_lines - 1
	}
	if noop {
		return
	}

	mut delta := CoordType(0)
	mut cut_line := CoordType(0)
	mut paste_line := CoordType(0)
	if direction == .up {
		delta = -1
		cut_line = beg - 1
		paste_line = end
	} else {
		delta = 1
		cut_line = end + 1
		paste_line = beg
	}

	b.edit_begin_grouping()
	{
		// Let's say this is `up`: we cut (remove) the line above the selection
		// here...
		b.cursor_move_to_logical(Point{ x: 0, y: cut_line })
		line := b.extract_selection(true)

		// ...and paste it below the selection. This will then appear to the
		// user as if the selection was moved up. The extract_selection call
		// can return an empty slice if the `cut` line was at the end of the
		// file; similarly, if the `paste` line is at the end of the file and
		// there's no trailing newline, we'll have failed to reach that end.
		b.cursor_move_to_logical(Point{ x: 0, y: paste_line })
		b.edit_begin(HistoryType.write, b.cursor)
		if line.len == 0 || b.cursor.logical_pos.y != paste_line {
			b.write_canon([u8(10)])
		}
		if line.len > 0 {
			b.write_raw(line)
		}
		b.edit_end()
	}
	b.edit_end_grouping()

	// Shift the cursor and selection together with the moved lines.
	b.cursor_move_to_logical(Point{ x: cursor.logical_pos.x, y: cursor.logical_pos.y + delta })
	if selection.valid {
		mut sel := selection
		sel.beg.y += delta
		sel.end.y += delta
		b.set_selection(sel)
	} else {
		b.set_selection(OptSelection{})
	}
}

// ---- Extracting -----------------------------------------------------------------

// extract_selection extracts the contents of the current selection, optionally
// deleting them. This is meant to be used for Ctrl+X.
fn (mut b TextBuffer) extract_selection(delete bool) []u8 {
	line_copy := !b.has_selection()
	sel_ok, sel_beg, sel_end := b.selection_range_internal(true)
	if !sel_ok {
		return []u8{}
	}

	mut out := []u8{}
	gap_buffer_extract_raw(b.buffer, sel_beg.offset, sel_end.offset, mut out,
		offset_target_max)

	if delete && out.len > 0 {
		b.edit_begin(HistoryType.delete, sel_beg)
		b.edit_delete(sel_end)
		b.edit_end()
		b.set_selection(OptSelection{})
	}

	// Line copies (= Ctrl+C when there's no selection) always end with a
	// newline.
	if line_copy && !bytes_end_with_nl(out) {
		if b.newlines_are_crlf {
			out << [u8(13), 10]
		} else {
			out << [u8(10)]
		}
	}

	return out
}

// extract_user_selection extracts the contents of the current selection the
// user made. This differs from extract_selection() in that it does nothing if
// the selection was made by searching.
pub fn (mut b TextBuffer) extract_user_selection(delete bool) ?[]u8 {
	if !b.has_selection() {
		return none
	}

	// A selection that was created by a search is not a user selection.
	if b.search.valid && b.search.selection_generation == b.selection_generation {
		return none
	}

	return b.extract_selection(delete)
}

// selection_range returns the current selection anchors, or `ok == false` if
// there is no selection. The returned logical positions are sorted.
pub fn (b TextBuffer) selection_range() (bool, Cursor, Cursor) {
	return b.selection_range_internal(false)
}

// selection_range_internal returns the current selection anchors. If there's
// no selection and `line_fallback` is true, the start/end of the current line
// are returned. This is meant to be used for Ctrl+C / Ctrl+X.
fn (b TextBuffer) selection_range_internal(line_fallback bool) (bool, Cursor, Cursor) {
	mut beg := Point{}
	mut end := Point{}
	if b.selection.valid {
		beg, end = minmax_points(b.selection.beg, b.selection.end)
	} else if line_fallback {
		beg = Point{ x: 0, y: b.cursor.logical_pos.y }
		end = Point{ x: 0, y: b.cursor.logical_pos.y + 1 }
	} else {
		return false, Cursor{}, Cursor{}
	}

	beg_cursor := b.cursor_move_to_logical_internal(b.cursor, beg)
	end_cursor := b.cursor_move_to_logical_internal(beg_cursor, end)

	if beg_cursor.offset < end_cursor.offset {
		return true, beg_cursor, end_cursor
	}
	return false, Cursor{}, Cursor{}
}

// ---- Undo/redo -------------------------------------------------------------------

// edit_begin_grouping starts a group of edits that share a common
// generation_before and can be undone/redone together.
fn (mut b TextBuffer) edit_begin_grouping() {
	b.active_edit_group = ActiveEditGroupInfo{
		valid:             true
		cursor_before:     b.cursor.logical_pos
		selection_before:  b.selection
		stats_before:      b.stats
		generation_before: b.buffer.generation()
	}
}

// edit_end_grouping ends a group of edits.
fn (mut b TextBuffer) edit_end_grouping() {
	b.active_edit_group = ActiveEditGroupInfo{}
}

// edit_begin starts a new edit operation, used for tracking undo/redo history.
fn (mut b TextBuffer) edit_begin(history_type HistoryType, cursor Cursor) {
	b.active_edit_depth++
	if b.active_edit_depth > 1 {
		return
	}

	cursor_before := b.cursor
	b.set_cursor_internal(cursor)

	// If both the last and this are a Write/Delete operation, we skip
	// allocating a new undo history item.
	if history_type != b.last_history_type
		|| (history_type != HistoryType.write && history_type != HistoryType.delete) {
		b.redo_stack = []HistoryEntry{}
		if b.undo_stack.len > 1000 {
			// Keep only the most recent 1000 entries.
			b.undo_stack = b.undo_stack[b.undo_stack.len - 1000..]
		}

		b.last_history_type = history_type
		b.undo_stack << HistoryEntry{
			cursor_before:     cursor_before.logical_pos
			selection_before:  b.selection
			stats_before:      b.stats
			generation_before: b.buffer.generation()
			cursor:            cursor.logical_pos
			deleted:           []u8{}
			added:             []u8{}
		}

		if b.active_edit_group.valid && b.undo_stack.len > 0 {
			info := b.active_edit_group
			b.undo_stack[b.undo_stack.len - 1].cursor_before = info.cursor_before
			b.undo_stack[b.undo_stack.len - 1].selection_before = info.selection_before
			b.undo_stack[b.undo_stack.len - 1].stats_before = info.stats_before
			b.undo_stack[b.undo_stack.len - 1].generation_before = info.generation_before
		}
	}

	b.active_edit_off = cursor.offset
	// The VM state at and after this line may now be stale.
	b.highlighter_cache.invalidate_from(cursor.logical_pos.y)

	// If word-wrap is enabled, the visual layout of all logical lines affected
	// by the write may have changed. Cache the start of the currently-being-
	// edited line so we can remeasure cheaply in edit_end().
	if b.word_wrap_column > 0 {
		safe_start := b.goto_line_start(cursor, cursor.logical_pos.y)
		next_line := b.cursor_move_to_logical_internal(cursor,
			Point{ x: 0, y: cursor.logical_pos.y + 1 })
		b.active_edit_line_info = ActiveEditLineInfo{
			valid:                    true
			safe_start:               safe_start
			line_height_in_rows:      next_line.visual_pos.y - safe_start.visual_pos.y
			distance_next_line_start: next_line.offset - cursor.offset
		}
	}
}

// edit_write writes `text` into the buffer at the current cursor position,
// recording the change in the undo stack.
fn (mut b TextBuffer) edit_write(text []u8) {
	logical_y_before := b.cursor.logical_pos.y

	// Copy the written portion into the undo entry.
	if b.undo_stack.len > 0 {
		b.undo_stack[b.undo_stack.len - 1].added << text
	}

	// Write!
	b.buffer.replace(b.active_edit_off, b.active_edit_off, text)

	// Move self.cursor to the end of the newly written text. Can't use
	// set_cursor_internal, because we're still recalculating the line stats.
	b.active_edit_off += text.len
	b.cursor = b.cursor_move_to_offset_internal(b.cursor, b.active_edit_off)
	b.stats.logical_lines += b.cursor.logical_pos.y - logical_y_before
}

// edit_delete deletes the text between the current cursor position and `to`,
// recording the change in the undo stack.
fn (mut b TextBuffer) edit_delete(to Cursor) {
	logical_y_before := b.cursor.logical_pos.y
	off := b.active_edit_off
	mut out_off := offset_target_max

	if b.undo_stack.len > 0 {
		// If this is a continued backspace operation, we need to prepend the
		// deleted portion to the undo entry.
		if b.cursor.logical_pos.compare(b.undo_stack[b.undo_stack.len - 1].cursor) < 0 {
			out_off = 0
			b.undo_stack[b.undo_stack.len - 1].cursor = b.cursor.logical_pos
		}

		// Copy the deleted portion into the undo entry.
		gap_buffer_extract_raw(b.buffer, off, to.offset,
			mut b.undo_stack[b.undo_stack.len - 1].deleted, out_off)
	}

	// Delete the portion from the buffer by enlarging the gap.
	// NOTE: allocate_gap_impl takes an exact byte count to delete (the public
	// allocate_gap only supports "delete to end").
	b.buffer.allocate_gap_impl(off, 0, to.offset - off)

	b.stats.logical_lines += logical_y_before - to.logical_pos.y
}

// edit_end finalizes the current edit operation and recalculates the line
// statistics.
fn (mut b TextBuffer) edit_end() {
	b.active_edit_depth--
	assert b.active_edit_depth >= 0
	if b.active_edit_depth > 0 {
		return
	}

	if b.active_edit_line_info.valid {
		info := b.active_edit_line_info
		mut deleted_count := 0
		if b.undo_stack.len > 0 {
			deleted_count = b.undo_stack[b.undo_stack.len - 1].deleted.len
		}
		target := b.cursor.logical_pos

		// From our safe position we can measure the actual visual position of
		// the cursor.
		b.set_cursor_internal(b.cursor_move_to_logical_internal(info.safe_start, target))

		// If content is added at the insertion position, that's not a problem:
		// we can just remeasure the height of this one line and calculate the
		// delta. `deleted_count` is 0 in this case.
		//
		// The problem is when content is deleted, because it may affect lines
		// beyond the end of the `next_line`. In that case we have to measure
		// the entire buffer contents until the end to compute visual_lines.
		if deleted_count < info.distance_next_line_start {
			// Now we can measure how many more visual rows this logical line
			// spans.
			mut cfg := b.measurement_config().with_cursor(b.cursor)
			next_line := cfg.goto_logical(Point{ x: 0, y: target.y + 1 })
			lines_before := info.line_height_in_rows
			lines_after := next_line.visual_pos.y - info.safe_start.visual_pos.y
			b.stats.visual_lines += lines_after - lines_before
		} else {
			mut cfg := b.measurement_config().with_cursor(b.cursor)
			end := cfg.goto_logical(point_max())
			b.stats.visual_lines = end.visual_pos.y + 1
		}

		b.active_edit_line_info = ActiveEditLineInfo{}
	} else {
		// If word-wrap is disabled the visual line count always matches the
		// logical one.
		b.stats.visual_lines = b.stats.logical_lines
	}

	b.recalc_after_content_changed()
}

// undo undoes the last edit operation.
pub fn (mut b TextBuffer) undo() {
	b.undo_redo(true)
}

// redo redoes the last undo operation.
pub fn (mut b TextBuffer) redo() {
	b.undo_redo(false)
}

fn (mut b TextBuffer) undo_redo(undo bool) {
	buffer_generation := b.buffer.generation()
	mut entry_buffer_generation_ok := false
	mut entry_buffer_generation := u32(0)
	mut damage_start := coord_type_max

	for {
		// Transfer the last entry from the undo stack to the redo stack or
		// vice versa. Only pop the entry if its buffer generation matches the
		// previously popped one (this groups consecutive edits).
		mut change := HistoryEntry{}
		mut popped := false
		if undo {
			if b.undo_stack.len == 0 {
				break
			}
			last := b.undo_stack[b.undo_stack.len - 1]
			if entry_buffer_generation_ok
				&& last.generation_before != entry_buffer_generation {
				break
			}
			b.undo_stack.delete(b.undo_stack.len - 1)
			b.redo_stack << last
			change = last
			popped = true
		} else {
			if b.redo_stack.len == 0 {
				break
			}
			last := b.redo_stack[b.redo_stack.len - 1]
			if entry_buffer_generation_ok
				&& last.generation_before != entry_buffer_generation {
				break
			}
			b.redo_stack.delete(b.redo_stack.len - 1)
			b.undo_stack << last
			change = last
			popped = true
		}
		if !popped {
			break
		}

		// Remember the buffer generation of the change so we can stop popping
		// undos/redos. Also, move to the point where the modification took
		// place.
		entry_buffer_generation = change.generation_before
		entry_buffer_generation_ok = true
		cursor := b.cursor_move_to_logical_internal(b.cursor, change.cursor)

		safe_cursor := if b.word_wrap_column > 0 {
			b.goto_line_start(cursor, cursor.logical_pos.y)
		} else {
			cursor
		}

		damage_start = coord_min(damage_start, cursor.logical_pos.y)

		mut ch := change

		// Undo: whatever was deleted is now added and vice versa.
		tmp := ch.deleted
		ch.deleted = ch.added
		ch.added = tmp

		// Delete the inserted portion.
		b.buffer.allocate_gap_impl(cursor.offset, 0, ch.deleted.len)

		// Reinsert the deleted portion.
		{
			added := ch.added
			mut beg := 0
			mut offset := cursor.offset

			for beg < added.len {
				end, line := lines_fwd(added, beg, 0, 1)
				has_newline := line != 0
				link := added[beg..end]
				line_clean := strip_newline(link)
				mut written := 0

				{
					mut gap := b.buffer.allocate_gap(offset, line_clean.len + 2,
						false)
					written = copy(mut gap, line_clean)

					if has_newline {
						if b.newlines_are_crlf && written < gap.len {
							gap[written] = `\r`
							written++
						}
						if written < gap.len {
							gap[written] = `\n`
							written++
						}
					}

					b.buffer.commit_gap(written)
				}

				beg = end
				offset += written
			}
		}

		// Restore the previous line statistics.
		stat_tmp := b.stats
		b.stats = ch.stats_before
		ch.stats_before = stat_tmp

		// Restore the previous selection.
		sel_tmp := b.selection
		b.selection = ch.selection_before
		ch.selection_before = sel_tmp

		// Pretend as if the buffer was never modified.
		b.buffer.set_generation(ch.generation_before)
		ch.generation_before = buffer_generation

		// Restore the previous cursor.
		cursor_before := b.cursor_move_to_logical_internal(safe_cursor, ch.cursor_before)
		ch.cursor_before = b.cursor.logical_pos
		// Can't use set_cursor_internal here, because we haven't updated the
		// line stats yet.
		b.cursor = cursor_before

		// Write the modified entry back into the destination stack.
		if undo {
			b.redo_stack[b.redo_stack.len - 1] = ch
		} else {
			b.undo_stack[b.undo_stack.len - 1] = ch
		}

		if b.undo_stack.len == 0 {
			b.last_history_type = HistoryType.other
		}
	}

	if damage_start == coord_type_max {
		// There weren't any undo/redo entries.
		return
	}

	b.highlighter_cache.invalidate_from(damage_start)

	if entry_buffer_generation_ok {
		b.recalc_after_content_changed()
	}
}

// ---- Searching -------------------------------------------------------------------
//
// NOTE: the Rust original uses ICU regular expressions. This port implements a
// pure byte-substring search. SearchOptions.use_regex is kept for API
// compatibility but ignored; whole_word uses ASCII word boundaries; with
// match_case=false only ASCII letters are folded.

// is_word_byte reports whether the byte is an ASCII word character
// ([A-Za-z0-9_], same as regex `\b`).
fn is_word_byte(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)
		|| c == `_`
}

// fold_ascii lowercases ASCII letters in-place in a new slice.
fn fold_ascii(text []u8) []u8 {
	if text.len == 0 {
		return []u8{}
	}
	mut out := []u8{ len: text.len }
	for i in 0..text.len {
		c := text[i]
		if c >= `A` && c <= `Z` {
			out[i] = c + 32
		} else {
			out[i] = c
		}
	}
	return out
}

// find_substring_match finds the next match of `pattern` in `text` at or after
// `start`. Returns (-1, -1) if there's no match.
fn find_substring_match(text []u8, pattern []u8, start int, options SearchOptions) (int, int) {
	if pattern.len == 0 || start > text.len {
		return -1, -1
	}
	mut s := start
	if s < 0 {
		s = 0
	}

	mut text_folded := text.clone()
	mut pattern_folded := pattern.clone()
	if !options.match_case {
		text_folded = fold_ascii(text)
		pattern_folded = fold_ascii(pattern)
	}

	last := text_folded.len - pattern_folded.len
	for off := s; off <= last; off++ {
		mut matched := true
		for i in 0..pattern_folded.len {
			if text_folded[off + i] != pattern_folded[i] {
				matched = false
				break
			}
		}
		if !matched {
			continue
		}
		// Whole-word check: the character before and after the match must not
		// be an ASCII word character.
		if options.whole_word {
			if off > 0 && is_word_byte(text_folded[off - 1]) {
				continue
			}
			end := off + pattern_folded.len
			if end < text_folded.len && is_word_byte(text_folded[end]) {
				continue
			}
		}
		return off, off + pattern.len
	}
	return -1, -1
}

// find_construct_search builds a cached search state for the given pattern.
fn (b TextBuffer) find_construct_search(pattern string, options SearchOptions) ActiveSearch {
	return ActiveSearch{
		valid:                true
		pattern:              pattern
		options:              options
		buffer_generation:    b.buffer.generation()
		selection_generation: 0
		next_search_offset:   0
		no_matches:           false
	}
}

// find_select_next finds the next match at or after `offset` and selects it.
// With `wrap`, the search wraps around to the beginning of the buffer.
// Returns whether a match was found.
fn (mut b TextBuffer) find_select_next(mut search ActiveSearch, offset int, wrap bool) bool {
	// Refresh the search start offset if the buffer changed or the offset
	// moved.
	if search.buffer_generation != b.buffer.generation() {
		search.buffer_generation = b.buffer.generation()
		search.next_search_offset = offset
	} else if search.next_search_offset != offset {
		search.next_search_offset = offset
	}

	mut range_beg := -1
	mut range_end := 0
	text := b.read_all()

	range_beg, range_end = find_substring_match(text, search.pattern.bytes(),
		search.next_search_offset, search.options)

	// If we hit the end of the buffer, and we know that there's something to
	// find, start the search again from the beginning (= wrap around).
	if range_beg < 0 && wrap && search.next_search_offset != 0 {
		search.next_search_offset = 0
		range_beg, range_end = find_substring_match(text, search.pattern.bytes(), 0,
			search.options)
	}

	if range_beg >= 0 {
		// Now the search offset is no more at the start of the buffer.
		search.next_search_offset = range_end

		beg_cursor := b.cursor_move_to_offset_internal(b.cursor, range_beg)
		end_cursor := b.cursor_move_to_offset_internal(beg_cursor, range_end)

		b.set_cursor(end_cursor)
		b.make_cursor_visible()

		search.selection_generation = b.set_selection(OptSelection{
			valid: true
			beg:   beg_cursor.logical_pos
			end:   end_cursor.logical_pos
		})
		return true
	}

	// Avoid searching through the entire document again if we know there's
	// nothing to find.
	search.no_matches = true
	search.selection_generation = b.set_selection(OptSelection{})
	return false
}

// find_advance_past_zero_width computes the offset to resume searching from
// after replacing a zero-width match. Returns 0 if we're at the end of the
// buffer.
fn (b TextBuffer) find_advance_past_zero_width(offset int) int {
	cursor := b.cursor_move_to_offset_internal(b.cursor, offset)
	next := b.cursor_move_delta_internal(cursor, CursorMovement.grapheme, 1)
	if next.offset > offset {
		return next.offset
	}
	return 0
}

// find_and_select finds the next occurrence of the given `pattern` and selects
// it.
pub fn (mut b TextBuffer) find_and_select(pattern string, options SearchOptions) {
	// When the search input changes we must reset the search.
	if b.search.valid && (b.search.pattern != pattern || b.search.options != options) {
		b.search = ActiveSearch{}
	}

	// When transitioning from some search to no search, we must clear the
	// selection.
	if pattern.len == 0 {
		if b.selection.valid {
			b.cursor_move_to_logical(b.selection.beg)
		}
		return
	}

	if !b.search.valid {
		b.search = b.find_construct_search(pattern, options)
	}

	// If we previously searched through the entire document and found 0
	// matches, then we can avoid searching again.
	if b.search.no_matches {
		return
	}

	// If the user moved the cursor since the last search, but the needle
	// remained the same, we still need to move the start of the search to the
	// new cursor position.
	mut next_search_offset := b.search.next_search_offset
	if b.search.selection_generation != b.selection_generation {
		if b.selection.valid {
			beg, _ := minmax_points(b.selection.beg, b.selection.end)
			next_search_offset = b.cursor_move_to_logical_internal(b.cursor, beg).offset
		} else {
			next_search_offset = b.cursor.offset
		}
	}

	b.find_select_next(mut b.search, next_search_offset, true)
}

// find_and_replace finds the next occurrence of the given `pattern` and
// replaces it with `replacement`.
pub fn (mut b TextBuffer) find_and_replace(pattern string, options SearchOptions, replacement []u8) {
	// Editors traditionally replace the previous search hit, not the next
	// possible one.
	if b.search.valid && b.search.selection_generation == b.selection_generation {
		zero_width := !b.selection.valid
		b.write_raw(replacement)

		// After replacing a zero-width match, advance past it so that
		// find_and_select wraps to the next match rather than finding the same
		// anchor again.
		if zero_width {
			b.search.next_search_offset = b.find_advance_past_zero_width(b.active_edit_off)
		}
	}

	b.find_and_select(pattern, options)
}

// find_and_replace_all finds all occurrences of the given `pattern` and
// replaces them with `replacement`. Returns the number of replacements made.
pub fn (mut b TextBuffer) find_and_replace_all(pattern string, options SearchOptions, replacement []u8) int {
	if pattern.len == 0 {
		return 0
	}

	b.edit_begin_grouping()

	mut count := 0
	mut offset := 0
	for {
		range_beg, range_end := find_substring_match(b.read_all(), pattern.bytes(),
			offset, options)
		if range_beg < 0 {
			break
		}

		// Select the match and replace it via write_raw().
		beg_cursor := b.cursor_move_to_offset_internal(b.cursor, range_beg)
		end_cursor := b.cursor_move_to_offset_internal(beg_cursor, range_end)
		b.set_cursor(end_cursor)
		b.set_selection(OptSelection{
			valid: true
			beg:   beg_cursor.logical_pos
			end:   end_cursor.logical_pos
		})
		b.write_raw(replacement)

		// The `active_edit_off` points to the end of the last edit made by
		// write_raw(). This differs from self.cursor.offset, if write_raw()
		// did an insert_final_newline.
		offset = b.active_edit_off

		// Avoid infinite loops when hitting zero-length matches by advancing
		// past the zero-length match location.
		if range_end == range_beg {
			offset = b.find_advance_past_zero_width(offset)
		}
		count++
	}

	b.edit_end_grouping()
	return count
}

// ---- Rendering -------------------------------------------------------------------

// point_min is Rust's Point::MIN.
fn point_min() Point {
	return Point{ x: coord_type_min, y: coord_type_min }
}

// margin_number formats a line number right-aligned in `width` columns, plus
// the " │ " separator.
fn margin_number(n CoordType, width int) []u8 {
	mut out := []u8{}
	num := n.str()
	if num.len < width {
		out << ' '.repeat(width - num.len).bytes()
	}
	out << num.bytes()
	out << ' │ '.bytes()
	return out
}

// render extracts a rectangular region of the text buffer and writes it to the
// framebuffer. The `destination` rect is in framebuffer coordinates; the
// extracted region within this text buffer has the given `origin` and the same
// size as the `destination` rect.
pub fn (mut b TextBuffer) render(origin Point, destination Rect, focused bool, mut fb Framebuffer) ?RenderResult {
	if destination.is_empty() {
		return none
	}

	width := destination.width()
	height := destination.height()
	line_number_width := int(coord_max(b.margin_width, 3)) - 3
	text_width := width - b.margin_width
	mut visual_pos_x_max := CoordType(0)

	// Pick the cursor closer to the `origin.y`.
	mut cursor := b.cursor
	if b.cursor_for_rendering_valid {
		a := b.cursor
		c := b.cursor_for_rendering
		da := coord_abs(a.visual_pos.y - origin.y)
		db := coord_abs(c.visual_pos.y - origin.y)
		if da >= db {
			cursor = c
		}
	}

	mut selection_beg := point_min()
	mut selection_end := point_min()
	if b.selection.valid {
		selection_beg, selection_end = minmax_points(b.selection.beg, b.selection.end)
	}

	for yi in 0..int(height) {
		y := CoordType(yi)
		mut line := []u8{}

		visual_line := origin.y + y
		mut cursor_beg := b.cursor_move_to_visual_internal(cursor,
			Point{ x: origin.x, y: visual_line })
		cursor_end := b.cursor_move_to_visual_internal(cursor_beg,
			Point{ x: origin.x + text_width, y: visual_line })

		// Accelerate the next render pass by remembering where we started off.
		if y == 0 {
			b.cursor_for_rendering_valid = true
			b.cursor_for_rendering = cursor_beg
		}

		if line_number_width != 0 {
			if visual_line >= b.stats.visual_lines {
				// Past the end of the buffer? Place "    | " in the margin.
				// Since we know that we won't see line numbers greater than
				// i64::MAX any time soon, we can use the static template and
				// slice it, because `line_number_width` can't be larger than 19.
				off := 19 - line_number_width
				line << margin_template[off..].bytes()
			} else if b.word_wrap_column <= 0 || cursor_beg.logical_pos.x == 0 {
				// Regular line? Place "123 | " in the margin.
				line << margin_number(cursor_beg.logical_pos.y + 1, line_number_width)
			} else {
				// Wrapped line? Place " ... | " in the margin.
				number_width := int(ilog10(cursor_beg.logical_pos.y + 1)) + 1
				line << ' '.repeat(line_number_width - number_width).bytes()
				line << '∙'.repeat(number_width).bytes()
				line << ' │ '.bytes()
				// Blending in the background color will "dim" the indicator
				// dots.
				mut mrect := Rect{
					left:   destination.left
					top:    destination.top + y
					right:  destination.left + CoordType(line_number_width)
					bottom: destination.top + y + 1
				}
				fb.blend_fg(mut mrect, fb.indexed_alpha(IndexedColor.background, 1, 2))
			}
		}

		mut selection_off_start := 0
		mut selection_off_end := 0

		// Figure out the selection range on this line, if any.
		if cursor_beg.visual_pos.y == visual_line
			&& selection_beg.compare(cursor_end.logical_pos) <= 0
			&& selection_end.compare(cursor_beg.logical_pos) >= 0 {
			mut sel_cursor := cursor_beg

			// By default, we assume the entire line is selected.
			mut selection_pos_beg := CoordType(0)
			mut selection_pos_end := coord_type_safe_max
			selection_off_start = cursor_beg.offset
			selection_off_end = cursor_end.offset

			// The start of the selection is within this line.
			if selection_beg.compare(cursor_end.logical_pos) <= 0
				&& selection_beg.compare(cursor_beg.logical_pos) >= 0 {
				sel_cursor = b.cursor_move_to_logical_internal(sel_cursor, selection_beg)
				selection_off_start = sel_cursor.offset
				selection_pos_beg = sel_cursor.visual_pos.x
			}

			// The end of the selection is within this line.
			if selection_end.compare(cursor_end.logical_pos) <= 0
				&& selection_end.compare(cursor_beg.logical_pos) >= 0 {
				sel_cursor = b.cursor_move_to_logical_internal(sel_cursor, selection_end)
				selection_off_end = sel_cursor.offset
				selection_pos_end = sel_cursor.visual_pos.x
			}

			left := destination.left + b.margin_width - origin.x
			top := destination.top + y
			mut rect := Rect{
				left:   left + coord_max(selection_pos_beg, origin.x)
				top:    top
				right:  left + coord_min(selection_pos_end, origin.x + text_width)
				bottom: top + 1
			}

			mut bg := fb.indexed(IndexedColor.foreground).oklab_blend(fb.indexed_alpha(IndexedColor.bright_blue,
				1, 2))
			if !focused {
				bg = bg.oklab_blend(fb.indexed_alpha(IndexedColor.background, 1, 2))
			}
			fg := fb.contrasted(bg)
			fb.blend_bg(mut rect, bg)
			fb.blend_fg(mut rect, fg)
		}

		// Nothing to do if the entire line is empty.
		if cursor_beg.offset != cursor_end.offset {
			// If we couldn't reach the left edge, we may have stopped short due
			// to a wide glyph. In that case we'll try to find the next character
			// and then compute by how many columns it overlaps the left edge.
			if cursor_beg.visual_pos.x < origin.x {
				cursor_next := b.cursor_move_to_logical_internal(cursor_beg,
					Point{ x: cursor_beg.logical_pos.x + 1, y: cursor_beg.logical_pos.y })
				if cursor_next.visual_pos.x > origin.x {
					overlap := cursor_next.visual_pos.x - origin.x
					line << tab_whitespace[..int(overlap)].bytes()
					cursor_beg = cursor_next
				}
			}

			mut global_off := cursor_beg.offset
			mut cursor_line := cursor_beg

			for global_off < cursor_end.offset {
				chunk_raw := b.buffer.read_forward(global_off)
				chunk_len := if chunk_raw.len > cursor_end.offset - global_off {
					cursor_end.offset - global_off
				} else {
					chunk_raw.len
				}
				// Slice the chunk to the line end first (like the Rust
				// original), so memchr2() below cannot run past it.
				chunk := chunk_raw[..chunk_len]
				mut off := 0

				for off < chunk.len {
					beg := off
					off = memchr2(` `, `\t`, chunk, off)

					// Anything that isn't whitespace is copied as-is.
					// The framebuffer takes care of sanitizing it.
					line << chunk[beg..off]

					for off < chunk.len && (chunk[off] == ` ` || chunk[off] == `\t`) {
						is_tab := chunk[off] == `\t`
						glyph_off := global_off + off
						is_visualized := glyph_off >= selection_off_start
							&& glyph_off < selection_off_end
						mut whitespace := tab_whitespace
						mut prefix_add := 0

						if is_tab || is_visualized {
							// We need the character's visual position in order
							// to either compute the tab size, or set the
							// foreground color of the visualizer.
							cursor_line = b.cursor_move_to_offset_internal(cursor_line,
								glyph_off)
						}

						mut tab_size := CoordType(1)
						if is_tab {
							tab_size = b.tab_size_eval(cursor_line.column)
						}

						if is_visualized {
							// If the whitespace is part of the selection, we
							// replace " " with "･" and "\t" with "￫".
							if is_tab {
								whitespace = visual_tab
								prefix_add = visual_tab_prefix_add
							} else {
								whitespace = visual_space
								prefix_add = visual_space_prefix_add
							}

							// Make the visualized characters slightly gray.
						visualizer_left := destination.left + b.margin_width
							+ cursor_line.visual_pos.x - origin.x
						visualizer_top := destination.top + cursor_line.visual_pos.y - origin.y
						mut vrect := Rect{
								left:   visualizer_left
								top:    visualizer_top
								right:  visualizer_left + 1
								bottom: visualizer_top + 1
							}
							fb.blend_fg(mut vrect, fb.indexed_alpha(IndexedColor.foreground,
								1, 2))
						}

						line << whitespace[..prefix_add + int(tab_size)].bytes()
						off++
					}
				}

				global_off += chunk_len
			}

			visual_pos_x_max = coord_max(visual_pos_x_max, cursor_end.visual_pos.x)
		}

		fb.replace_text(destination.top + y, destination.left, destination.right,
			line.bytestr())

		cursor = cursor_end
	}

	logical_y_beg := b.cursor_for_rendering.logical_pos.y
	logical_y_end := cursor.logical_pos.y + 1
	b.render_apply_highlights(origin, destination, logical_y_beg, logical_y_end, mut fb)

	// Colorize the margin that we wrote above.
	if b.margin_width > 0 {
		mut margin := Rect{
			left:   destination.left
			top:    destination.top
			right:  destination.left + b.margin_width
			bottom: destination.bottom
		}
		fb.blend_fg(mut margin, straight_rgba_from_rgba(0x7f7f7f7f))
	}

	if b.ruler > 0 {
		left := destination.left + b.margin_width + coord_max(b.ruler - origin.x, 0)
		right := destination.right
		if left < right {
			mut rrect := Rect{
				left:   left
				top:    destination.top
				right:  right
				bottom: destination.bottom
			}
			fb.blend_bg(mut rrect, fb.indexed_alpha(IndexedColor.bright_red, 1, 4))
		}
	}

	if focused {
		mut x := b.cursor.visual_pos.x
		mut y := b.cursor.visual_pos.y

		if b.word_wrap_column > 0 && x >= b.word_wrap_column {
			// The line the cursor is on wraps exactly on the word wrap column
			// which means the cursor is invisible. Move it to the next line.
			x = 0
			y++
		}

		// Move the cursor into screen space.
		x += destination.left - origin.x + b.margin_width
		y += destination.top - origin.y

		cpos := Point{ x: x, y: y }
		mut text_rect := Rect{
			left:   destination.left + b.margin_width
			top:    destination.top
			right:  destination.right
			bottom: destination.bottom
		}

		if text_rect.contains(cpos) {
			fb.set_cursor(cpos, b.overtype)

			if b.line_highlight_enabled && selection_beg.compare(selection_end) >= 0 {
				mut hrect := Rect{
					left:   destination.left
					top:    cpos.y
					right:  destination.right
					bottom: cpos.y + 1
				}
				fb.blend_bg(mut hrect, straight_rgba_from_rgba(0x7f7f7f7f))
			}
		}
	}

	return RenderResult{ visual_pos_x_max: visual_pos_x_max }
}

// render_apply_highlights applies lsh syntax highlighting to the visible
// logical lines (Rust buffer/mod.rs render_apply_highlights). Returns early
// when no language is set.
fn (mut b TextBuffer) render_apply_highlights(origin Point, destination Rect, logical_y_beg CoordType, logical_y_end CoordType, mut fb Framebuffer) {
	if b.language < 0 {
		return
	}

	mut highlighter := highlighter_new(&b.buffer, lsh_languages[b.language])

	// Track cursor position for efficient offset-to-position conversions.
	// Start from the rendering cursor which is at the beginning of the
	// visible area.
	mut cursor := b.cursor_for_rendering

	// Visible vertical range in visual coordinates.
	visible_top := origin.y
	visible_bottom := origin.y + destination.height()

	// Text area boundaries in screen coordinates (excluding margin).
	text_left := destination.left + b.margin_width
	text_right := destination.right

	for logical_y_int in int(logical_y_beg) .. int(logical_y_end) {
		logical_y := CoordType(logical_y_int)
		// Seek cursor to the start of this logical line for efficient lookups.
		// This is important because highlights are sorted by offset within
		// each logical line.
		cursor = b.goto_line_start(cursor, logical_y)

		highlights := b.highlighter_cache.parse_line(mut highlighter, logical_y)
		if highlights.len < 2 {
			continue
		}

		for i in 0 .. highlights.len - 1 {
			curr := highlights[i]
			next := highlights[i + 1]

			// Skip highlights with no visual effect.
			if curr.kind == lsh_kind_other {
				continue
			}

			// Convert byte offsets to cursor positions. Since highlights are
			// sorted by offset, we chain from cursor -> beg -> end for
			// efficiency.
			beg := b.cursor_move_to_offset_internal(cursor, curr.start)
			end := b.cursor_move_to_offset_internal(beg, next.start)
			cursor = end

			color := lsh_highlight_color(curr.kind)
			attr := lsh_highlight_attr(curr.kind)

			// Handle the case where the highlight spans multiple visual lines
			// due to word wrapping. The range is [beg, end) in terms of
			// offsets, which maps to visual lines
			// [beg.visual_pos.y, end.visual_pos.y]. A span ending exactly at
			// position 0 of a new visual line ends at the previous line.
			visual_y_end := if end.visual_pos.x == 0 && end.visual_pos.y > beg.visual_pos.y {
				end.visual_pos.y - 1
			} else {
				end.visual_pos.y
			}

			// Use min/max to skip visual lines outside the visible range.
			for visual_y_int in int(coord_max(beg.visual_pos.y, visible_top)) .. int(coord_min(visual_y_end + 1,
				visible_bottom)) {
				visual_y := CoordType(visual_y_int)
				vis_left := if visual_y == beg.visual_pos.y {
					beg.visual_pos.x
				} else {
					CoordType(0)
				}
				vis_right := if visual_y == end.visual_pos.y {
					end.visual_pos.x
				} else {
					coord_type_safe_max
				}

				// Convert to screen coordinates.
				screen_left := text_left + vis_left - origin.x
				screen_right := coord_min(text_left + vis_right - origin.x, text_right)
				screen_y := destination.top + visual_y - origin.y

				// Create the target rectangle, clamped to the text area.
				mut rect := Rect{
					left:   coord_max(screen_left, text_left)
					top:    screen_y
					right:  screen_right
					bottom: screen_y + 1
				}

				// Skip empty or invalid rectangles.
				if rect.left >= rect.right {
					continue
				}

				if color >= 0 {
					fb.blend_fg(mut rect, fb.indexed(unsafe { IndexedColor(color) }))
				}
				if attr != attr_none {
					fb.replace_attr(mut rect, attr_all, attr)
				}
			}
		}
	}
}

// ---- ReadableDocument implementation ----------------------------------------------

// read_forward implements ReadableDocument for TextBuffer.
pub fn (b TextBuffer) read_forward(off int) []u8 {
	return b.buffer.read_forward(off)
}

// read_backward implements ReadableDocument for TextBuffer.
pub fn (b TextBuffer) read_backward(off int) []u8 {
	return b.buffer.read_backward(off)
}
