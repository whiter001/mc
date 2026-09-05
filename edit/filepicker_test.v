module main

fn test_picker_normalize() {
	assert picker_normalize('/a/b/c') == '/a/b/c'
	assert picker_normalize('/a/b/../c') == '/a/c'
	assert picker_normalize('/a/./b') == '/a/b'
	assert picker_normalize('/') == '/'
	// '..' at the root clamps to the root.
	assert picker_normalize('/..') == '/'
	assert picker_normalize('/a/../../b') == '/b'
	// Relative paths stay relative.
	assert picker_normalize('a/b/../c') == 'a/c'
	assert picker_normalize('..') == '.'
	assert picker_normalize('') == '.'
	// Trailing and duplicate slashes collapse.
	assert picker_normalize('/a/b/') == '/a/b'
	assert picker_normalize('/a//b') == '/a/b'
}

fn test_picker_join() {
	assert picker_join('/tmp', 'x.txt') == '/tmp/x.txt'
	// An absolute name replaces the directory.
	assert picker_join('/tmp', '/etc/y') == '/etc/y'
	// Directory entries carry a trailing '/'.
	assert picker_join('/tmp', 'sub/') == '/tmp/sub'
	assert picker_join('/tmp/a', '..') == '/tmp'
	assert picker_join('/', 'etc') == '/etc'
}

fn test_picker_utf8_trim_and_truncate() {
	assert picker_trim_last_utf8_char('a中') == 'a'
	assert picker_trim_last_utf8_char('中') == ''
	assert picker_truncate('ab中d', 4) == '...d'
	assert picker_truncate('ab中d', 3) == '中d'
	assert picker_fit_line('a中', 4) == 'a中 '
}

fn test_picker_autocomplete_prefix() {
	entries := ['..', 'aardvark.txt', 'apple.txt', 'apricot.txt', 'avocado.txt', 'banana.txt', 'sub/']
	assert picker_autocomplete_collect(entries, 'a') == ['aardvark.txt', 'apple.txt', 'apricot.txt',
		'avocado.txt']
	assert picker_autocomplete_collect(entries, 'ap') == ['apple.txt', 'apricot.txt']
	assert picker_autocomplete_collect(entries, 'b') == ['banana.txt']
	assert picker_autocomplete_collect(entries, 'sub') == ['sub/']
	// Cap at 5: more than 5 matches returns only the first 5.
	many := ['..', 'alpha.txt', 'alphabet.txt', 'also.txt', 'amber.txt', 'ambient.txt', 'among.txt', 'ample.txt']
	assert picker_autocomplete_collect(many, 'a').len == 5
}

fn test_picker_autocomplete_directory_with_slash() {
	entries := ['..', 'subdir/', 'submodule/', 'super.txt']
	assert picker_autocomplete_collect(entries, 'sub') == ['subdir/', 'submodule/']
	assert picker_autocomplete_match('subdir/', 'sub') == true
	assert picker_autocomplete_match('super.txt', 'sub') == false
}

fn test_picker_autocomplete_skips_dotdot() {
	entries := ['..', '.hidden', 'aa.txt']
	assert picker_autocomplete_collect(entries, '.') == ['.hidden']
}

fn test_picker_autocomplete_empty_name() {
	entries := ['aardvark.txt', 'apple.txt']
	assert picker_autocomplete_collect(entries, '') == []
	assert picker_autocomplete_match('apple.txt', '') == false
}

fn test_picker_autocomplete_match_basics() {
	assert picker_autocomplete_match('apple.txt', 'a') == true
	assert picker_autocomplete_match('apple.txt', 'app') == true
	assert picker_autocomplete_match('apple.txt', 'apple') == true
	assert picker_autocomplete_match('apple.txt', 'apples') == false
	assert picker_autocomplete_match('apple.txt', 'b') == false
	assert picker_autocomplete_match('', 'a') == false
	assert picker_autocomplete_match('sub/', 'sub') == true
	assert picker_autocomplete_match('sub/', 's') == true
	assert picker_autocomplete_match('sub/', 'subdir') == false
}
