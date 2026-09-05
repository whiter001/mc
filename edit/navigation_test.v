module main

// navigation_test.v — tests for the word navigation port.
//
// The Rust original (crates/edit/src/buffer/navigation.rs) has a
// #[cfg(test)] module; the cases below are ported verbatim, using
// StringDocument as the ReadableDocument.
// word_select is tested separately against documented VS Code-like behavior.

fn test_word_navigation() {
	assert word_forward(StringDocument{ text: 'Hello World' }, 0) == 5
	assert word_forward(StringDocument{ text: 'Hello,World' }, 0) == 5
	assert word_forward(StringDocument{ text: '   Hello' }, 0) == 8
	assert word_forward(StringDocument{ text: '\n\nHello' }, 0) == 1

	assert word_backward(StringDocument{ text: 'Hello World' }, 11) == 6
	assert word_backward(StringDocument{ text: 'Hello,World' }, 10) == 6
	assert word_backward(StringDocument{ text: 'Hello   ' }, 7) == 0
	assert word_backward(StringDocument{ text: 'Hello\n\n' }, 7) == 6
}

fn test_word_select() {
	// Inside a word: selects the whole word.
	beg, end := word_select(StringDocument{ text: 'Hello World' }, 2)
	assert beg == 0
	assert end == 5

	// On a separator: selects the separator run.
	beg2, end2 := word_select(StringDocument{ text: 'foo,,bar' }, 3)
	assert beg2 == 3
	assert end2 == 5

	// On whitespace between words: selects the whitespace run.
	beg3, end3 := word_select(StringDocument{ text: 'foo  bar' }, 4)
	assert beg3 == 3
	assert end3 == 5

	// Does not cross newlines.
	beg4, end4 := word_select(StringDocument{ text: 'foo\nbar' }, 4)
	assert beg4 == 4
	assert end4 == 7

	// At end of document: selects the last word.
	beg5, end5 := word_select(StringDocument{ text: 'Hello World' }, 11)
	assert beg5 == 6
	assert end5 == 11
}

// ---- classify (navigation.v) ----------------------------------------------
//
// classify is the per-byte lookup the word navigation uses to decide
// which kind of run a cursor sits on. It must agree with the Rust table
// exactly so word_forward / word_backward / word_select stay correct.

fn test_classify_whitespace() {
	assert classify(` `) == .whitespace
	assert classify(`\t`) == .whitespace
}

fn test_classify_newline() {
	assert classify(`\n`) == .newline
	assert classify(`\r`) == .newline
}

fn test_classify_separator() {
	// One entry from each end of the word_separators string.
	assert classify(`\``) == .separator
	assert classify(`?`) == .separator
	assert classify(`,`) == .separator
	assert classify(`/`) == .separator
}

fn test_classify_word() {
	// ASCII letters and digits are word bytes.
	assert classify(`a`) == .word
	assert classify(`Z`) == .word
	assert classify(`0`) == .word
	assert classify(`9`) == .word
	// Non-ASCII high bytes default to .word (UTF-8 continuation/start).
	assert classify(0x80) == .word
	assert classify(0xff) == .word
}
