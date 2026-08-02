// tools_parity_test.v — offline unit tests for the parity tools' pure logic.
// These don't touch the network or TTY, so they run anywhere.

module main

fn test_parse_selection_single() {
	got := parse_selection('2', 4, false)
	assert got == [2]
}

fn test_parse_selection_multi_dedup() {
	got := parse_selection('1,3,1', 4, true)
	assert got == [1, 3]
}

fn test_parse_selection_out_of_range_dropped() {
	got := parse_selection('1,9,2', 4, true)
	assert got == [1, 2]
}

fn test_parse_selection_single_mode_keeps_first() {
	// Multi-select syntax but single mode → keep only the first choice.
	got := parse_selection('1,3', 4, false)
	assert got == [1]
}

fn test_parse_selection_comma_spaces() {
	got := parse_selection(' 2 , 4 ', 4, true)
	assert got == [2, 4]
}

fn test_parse_selection_empty() {
	got := parse_selection('', 4, true)
	assert got.len == 0
}

fn test_normalize_status() {
	assert normalize_status('IN_PROGRESS') == 'in_progress'
	assert normalize_status('done') == 'completed'
	assert normalize_status('weird') == 'pending'
}

fn test_url_encode_decode_roundtrip() {
	original := 'hello world?q=1&x=foo bar'
	enc := url_encode(original)
	dec := url_decode(enc)
	assert dec == original
}

fn test_url_decode_plus_becomes_space() {
	// DuckDuckGo form bodies encode spaces as '+'.
	assert url_decode('a+b') == 'a b'
}

fn test_url_decode_hex() {
	// %20 is a space; %2F is '/'.
	assert url_decode('a%20b%2Fc') == 'a b/c'
}

fn test_todos_to_markdown() {
	items := [
		TodoItem{ content: 'first', status: 'completed' },
		TodoItem{ content: 'second', status: 'in_progress' },
		TodoItem{ content: 'third', status: 'pending' },
	]
	md := todos_to_markdown(items)
	assert md.contains('[x] first')
	assert md.contains('[~] second')
	assert md.contains('[ ] third')
	assert md.contains('1/3 completed')
}

fn test_todos_to_markdown_empty() {
	assert todos_to_markdown([]) == '(todo list is empty)'
}
