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
