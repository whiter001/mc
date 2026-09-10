module main

// Tests for the ported regex engine (regex.v) and for the replacement
// templates wired into TextBuffer.find_and_replace / find_and_replace_all.
// The template semantics follow Rust's find_parse_replacement /
// find_fill_replacement in crates/edit/src/buffer/mod.rs.

// The buffer helpers live in text_buffer_test.v, which `v test` compiles as a
// separate unit, so this file keeps its own (identical) copies.
fn rx_wr(mut b TextBuffer, s string) {
	b.write_raw(s.bytes())
}

fn rx_buf_text(mut b TextBuffer) string {
	mut sd := StringDocument{
		text: ''
	}
	b.save_as_string(mut sd)
	return sd.text
}

fn rx_compile(pattern string) Regex {
	re := regex_compile(pattern.bytes()) or { panic('failed to compile ${pattern}') }
	return re
}

fn rx_find_at(pattern string, text string, options SearchOptions, start int) RegexMatch {
	re := rx_compile(pattern)
	return regex_find(&re, text.bytes(), start, options)
}

// rx_bounds returns the first match range of a case-sensitive search, or
// (-1, -1) when there is none.
fn rx_bounds(pattern string, text string) (int, int) {
	m := rx_find_at(pattern, text, SearchOptions{
		match_case: true
	}, 0)
	return m.beg, m.end
}

fn rx_text(pattern string, text string) string {
	beg, end := rx_bounds(pattern, text)
	if beg < 0 {
		return '<no match>'
	}
	return text[beg..end]
}

// ---------------------------------------------------------------------------
// Literals, wildcards, classes
// ---------------------------------------------------------------------------

fn test_regex_literal_and_dot() {
	mut beg, mut end := rx_bounds('ell', 'hello')
	assert beg == 1
	assert end == 4

	beg, end = rx_bounds('a.c', 'abc')
	assert beg == 0
	assert end == 3

	// `.` must not cross a line boundary.
	beg, _ = rx_bounds('a.c', 'a\nc')
	assert beg == -1
}

fn test_regex_classes_and_case_insensitive() {
	assert rx_text('[a-z]+', 'ABC abc') == 'abc'
	assert rx_text('[a-zA-Z]+', '12abc34') == 'abc'
	assert rx_text('[^0-9]+', '12abc34') == 'abc'
	assert rx_text('\\d+', 'x42y') == '42'
	assert rx_text('\\w+', '  ab_1  ') == 'ab_1'
	assert rx_text('\\s+', 'a \t b') == ' \t '

	// A trailing dash stays literal instead of opening a range.
	assert rx_text('[a-]+', 'x-a-b') == '-a-'

	ci := SearchOptions{
		match_case: false
	}
	m := rx_find_at('hello', 'HeLLo world', ci, 0)
	assert m.beg == 0
	assert m.end == 5
}

// ---------------------------------------------------------------------------
// Quantifiers
// ---------------------------------------------------------------------------

fn test_regex_quantifiers() {
	assert rx_text('a+', 'baaad') == 'aaa'
	assert rx_text('ca?b', 'cb') == 'cb'
	assert rx_text('ca?b', 'cab') == 'cab'

	// `a*` matches empty, so the leftmost hit is zero-width at offset 0.
	beg, end := rx_bounds('a*', 'bbb')
	assert beg == 0
	assert end == 0
}

fn test_regex_bounded_repeats() {
	assert rx_text('a{2}', 'aaa') == 'aa'
	assert rx_text('a{2,}', 'baaa') == 'aaa'
	assert rx_text('a{2,3}', 'aaaa') == 'aaa' // greedy takes the maximum
	assert rx_text('a{2,3}?', 'aaaa') == 'aa' // lazy takes the minimum
	assert rx_text('a+?', 'aaa') == 'a'
	assert rx_text('a{3}', 'aa') == '<no match>'
}

fn test_regex_empty_loop_terminates() {
	// `(a*)*` must not spin: the empty-iteration guard refuses to loop again
	// once an iteration consumed nothing.
	assert rx_text('(a*)*b', 'aab') == 'aab'
	assert rx_text('(a*)*', 'bbb') == ''
}

fn test_regex_no_catastrophic_backtracking() {
	// (a+)+b is the classic pathological pattern; the step budget has to turn
	// it into a bounded "no match" instead of hanging.
	mut text := 'a'.repeat(4000)
	text += 'c'
	beg, _ := rx_bounds('(a+)+b', text)
	assert beg == -1
}

// ---------------------------------------------------------------------------
// Groups, alternation, captures
// ---------------------------------------------------------------------------

fn test_regex_groups_and_alternation() {
	assert rx_text('(ab)+', 'xababy') == 'abab'
	assert rx_text('(a|b)+', 'zab') == 'ab'
	assert rx_text('(?:ab)+', 'xababy') == 'abab'

	// The leftmost alternative wins at each position.
	assert rx_text('foo|foobar', 'foobar') == 'foo'
	assert rx_text('(?:foo|bar)+', 'xxfoobar') == 'foobar'

	// An empty alternative makes the whole group optional.
	assert rx_text('(a|)b', 'b') == 'b'
}

fn test_regex_captures() {
	re := rx_compile('(\\w+)@(\\w+)')
	m := regex_find(&re, 'hi user@host!'.bytes(), 0, SearchOptions{
		match_case: true
	})
	assert m.beg == 3
	assert m.end == 12
	// Slot 0 is the whole match, groups 1..2 follow.
	assert m.caps.len == 6
	assert m.caps[0] == 3
	assert m.caps[1] == 12
	assert m.caps[2] == 3
	assert m.caps[3] == 7
	assert m.caps[4] == 8
	assert m.caps[5] == 12
}

fn test_regex_captures_last_iteration_wins() {
	re := rx_compile('(a|b)+')
	m := regex_find(&re, 'zab'.bytes(), 0, SearchOptions{
		match_case: true
	})
	assert m.beg == 1
	assert m.end == 3
	// The group holds the last repetition, like ICU's regex iterator.
	assert m.caps[2] == 2
	assert m.caps[3] == 3
}

fn test_regex_unset_capture_stays_unset() {
	re := rx_compile('(a)(b)?')
	m := regex_find(&re, 'a'.bytes(), 0, SearchOptions{
		match_case: true
	})
	assert m.beg == 0
	assert m.end == 1
	assert m.caps[2] == 0
	assert m.caps[3] == 1
	assert m.caps[4] == -1
	assert m.caps[5] == -1
}

// ---------------------------------------------------------------------------
// Anchors and whole-word
// ---------------------------------------------------------------------------

fn test_regex_anchors_and_boundaries() {
	mut beg, mut end := rx_bounds('^', 'ab\ncd')
	assert beg == 0
	assert end == 0

	// `^` also matches after a newline.
	m := rx_find_at('^c', 'ab\ncd', SearchOptions{
		match_case: true
	}, 0)
	assert m.beg == 3
	assert m.end == 4

	beg, end = rx_bounds('$', 'ab')
	assert beg == 2
	assert end == 2

	assert rx_text('\\bcat\\b', 'concat cat') == 'cat'
	beg, _ = rx_bounds('\\bcat\\b', 'concat')
	assert beg == -1
}

fn test_regex_whole_word_option() {
	opts := SearchOptions{
		match_case: true
		whole_word: true
	}
	m := rx_find_at('foo', 'a foo b foobar', opts, 0)
	assert m.beg == 2
	assert m.end == 5
}

fn test_regex_unicode_case_and_word_boundaries() {
	m := rx_find_at('καλη', 'ΚΑΛΗμέρα', SearchOptions{
		match_case: false
	}, 0)
	assert m.beg == 0
	assert m.end == 'ΚΑΛΗ'.len
	assert rx_find_at('猫', '🙂猫🙂', SearchOptions{
		match_case: true
		whole_word: true
	}, 0).beg == 4

	// Combining marks remain part of a word, while emoji are punctuation for
	// boundary purposes.
	mut word := SearchOptions{
		match_case: true
		whole_word: true
	}
	assert rx_find_at('e', 'é', word, 0).beg == -1
	assert rx_find_at('cat', '🙂cat🙂', word, 0).beg == 4
	// A CJK ideograph adjacent to another ideograph has no word boundary.
	assert rx_find_at('猫', '猫咪', word, 0).beg == -1
}

// ---------------------------------------------------------------------------
// Invalid patterns
// ---------------------------------------------------------------------------

fn test_regex_invalid_patterns_report_errors() {
	assert regex_error('(') != ''
	assert regex_error(')') != ''
	assert regex_error('[') != ''
	assert regex_error('[a-') != ''
	assert regex_error('*a') != ''
	assert regex_error('a{2,1}') != ''
	assert regex_error('a{1001}') != ''
	assert regex_error('\\') != ''
	assert regex_error('(?=a)') != ''
	assert regex_error(')a(') != ''
}

fn test_regex_valid_patterns_have_no_error() {
	assert regex_error('a+b*c?') == ''
	assert regex_error('(\\w+)@(\\w+)') == ''
	assert regex_error('[a-z]{2,4}') == ''
	assert regex_error('(?:a|b)+?') == ''
}

fn test_invalid_regex_yields_no_match() {
	// A bad pattern must degrade to "no hits", never to a wrong hit.
	beg, end := find_regex_match('abc'.bytes(), '(a'.bytes(), 0, SearchOptions{
		match_case: true
	})
	assert beg == -1
	assert end == -1
}

// ---------------------------------------------------------------------------
// Replacement templates
// ---------------------------------------------------------------------------

fn test_parse_replacement_templates() {
	// `$$` is a literal dollar sign.
	mut parts := parse_replacement('a$$b'.bytes(), 2, true)
	assert parts.len == 1
	assert parts[0].kind == .text
	assert parts[0].text.bytestr() == 'a$b'

	// `\n`, `\r`, `\t` are control characters; an unknown escape keeps the
	// character itself.
	parts = parse_replacement('x\\ny\\q'.bytes(), 0, true)
	assert parts.len == 1
	assert parts[0].text.bytestr() == 'x\nyq'

	// Group references split the text runs.
	parts = parse_replacement('<$1>'.bytes(), 1, true)
	assert parts.len == 3
	assert parts[1].kind == .group
	assert parts[1].group == 1

	// An out-of-range group number is plain text.
	parts = parse_replacement('$7'.bytes(), 1, true)
	assert parts.len == 1
	assert parts[0].kind == .text
	assert parts[0].text.bytestr() == '$7'

	// A trailing lone `$` is plain text too.
	parts = parse_replacement('a$'.bytes(), 1, true)
	assert parts.len == 1
	assert parts[0].text.bytestr() == 'a$'

	// Without use_regex the template is one literal run, so `$1` is inert.
	parts = parse_replacement('$1'.bytes(), 1, false)
	assert parts.len == 1
	assert parts[0].kind == .text
	assert parts[0].text.bytestr() == '$1'
}

fn test_expand_replacement_with_missing_group() {
	mut parts := parse_replacement('[$2]'.bytes(), 2, true)
	out := expand_replacement(parts, 'a'.bytes(), [0, 1, 0, 1, -1, -1])
	assert out.bytestr() == '[]'
}

fn test_find_and_replace_all_with_captures() {
	mut b := new_text_buffer(false)
	rx_wr(mut b, 'user@host\nbot@serv\n')
	opts := SearchOptions{
		use_regex:  true
		match_case: true
	}
	n := b.find_and_replace_all('(\\w+)@(\\w+)', opts, '$2@$1'.bytes())
	assert n == 2
	assert rx_buf_text(mut b) == 'host@user\nserv@bot\n'
}

fn test_find_and_replace_all_escapes_dollar_dollar() {
	mut b := new_text_buffer(false)
	rx_wr(mut b, 'ab ab')
	opts := SearchOptions{
		use_regex:  true
		match_case: true
	}
	n := b.find_and_replace_all('(a)(b)', opts, '$$'.bytes())
	assert n == 2
	assert rx_buf_text(mut b) == '$ $'
}

fn test_find_and_replace_all_expands_group_zero() {
	mut b := new_text_buffer(false)
	rx_wr(mut b, 'x aa y')
	opts := SearchOptions{
		use_regex:  true
		match_case: true
	}
	n := b.find_and_replace_all('a+', opts, '[$0]'.bytes())
	assert n == 1
	assert rx_buf_text(mut b) == 'x [aa] y'
}

fn test_find_and_replace_all_with_control_escapes() {
	mut b := new_text_buffer(false)
	rx_wr(mut b, 'a,b')
	opts := SearchOptions{
		use_regex:  true
		match_case: true
	}
	n := b.find_and_replace_all(',', opts, '\\n\\t'.bytes())
	assert n == 1
	assert rx_buf_text(mut b) == 'a\n\tb'
}

fn test_find_and_replace_all_ignores_templates_without_regex() {
	mut b := new_text_buffer(false)
	rx_wr(mut b, 'ab')
	n := b.find_and_replace_all('ab', SearchOptions{
		match_case: true
	}, '$1'.bytes())
	assert n == 1
	assert rx_buf_text(mut b) == '$1'
}

fn test_find_and_replace_single_hit_with_captures() {
	mut b := new_text_buffer(false)
	rx_wr(mut b, 'a1 b2')
	opts := SearchOptions{
		use_regex:  true
		match_case: true
	}
	// The first call only selects; the second replaces that hit and advances.
	b.find_and_select('(\\w)(\\d)', opts)
	b.find_and_replace('(\\w)(\\d)', opts, '$2$1'.bytes())
	assert rx_buf_text(mut b) == '1a b2'

	b.find_and_replace('(\\w)(\\d)', opts, '$2$1'.bytes())
	assert rx_buf_text(mut b) == '1a 2b'
}

fn test_find_and_replace_all_zero_width_with_captures() {
	// A zero-width pattern has no capture text; the template still has to
	// render, and the scan must still advance.
	mut b := new_text_buffer(false)
	rx_wr(mut b, 'ab\ncd')
	opts := SearchOptions{
		use_regex:  true
		match_case: true
	}
	n := b.find_and_replace_all('^', opts, '>'.bytes())
	assert n == 2
	assert rx_buf_text(mut b) == '>ab\n>cd'
}
