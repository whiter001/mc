module main

// Port of crates/edit/src/buffer/navigation.rs (microsoft/edit).
// Word navigation (VS Code behavior) over a ReadableDocument.
//
// Differences from the Rust original:
// * Rust builds a 256-entry const classifier table; V has no const fn, so
//   classification is a plain function (equally branch-cheap).
// * usize offsets become V ints; the document interfaces already clamp.
// * word_select returns (beg, end) instead of Range<usize>.

// CharClass categorizes bytes for word navigation.
enum CharClass {
	whitespace
	newline
	separator
	word
}

// word_separators are the ASCII bytes classified as separators.
// Rust: the `separators` argument of construct_classifier.
const word_separators = '`~!@#\$%^&*()-=+[{]}\\|;:\'",.<>/?'

// classify maps a byte to its CharClass.
// Rust: WORD_CLASSIFIER lookup. Non-ASCII bytes (>= 128, e.g. UTF-8
// continuation bytes) default to .word, same as the Rust table.
fn classify(b u8) CharClass {
	if b == ` ` || b == `\t` {
		return .whitespace
	}
	if b == `\n` || b == `\r` {
		return .newline
	}
	if b < 128 && word_separators.index_u8(b) >= 0 {
		return .separator
	}
	return .word
}

// WordNavigator abstracts the direction-specific parts of word navigation.
// Rust: the WordNavigation trait.
interface WordNavigator {
mut:
	read()
	skip_newline()
	skip_class(class CharClass)
	peek(fallback CharClass) CharClass
	next()
	offset() int
}

// word_forward finds the next word boundary given a document cursor offset.
pub fn word_forward(doc ReadableDocument, offset int) int {
	mut nav := WordForward{
		doc: doc
		offset: offset
	}
	return word_navigation(mut nav)
}

// word_backward is the backward version of word_forward.
pub fn word_backward(doc ReadableDocument, offset int) int {
	mut nav := WordBackward{
		doc: doc
		offset: offset
	}
	return word_navigation(mut nav)
}

// word_navigation is the shared word navigation implementation.
// Matches the behavior of VS Code.
fn word_navigation(mut nav WordNavigator) int {
	// First, fill the chunk with at least 1 grapheme.
	nav.read()

	// Skip one newline, if any.
	nav.skip_newline()

	// Skip any whitespace.
	nav.skip_class(.whitespace)

	// Skip one word or separator and take note of the class.
	class := nav.peek(.whitespace)
	if class == .separator || class == .word {
		nav.next()

		off := nav.offset()

		// Continue skipping the same class.
		nav.skip_class(class)

		// If the class was a separator and we only moved one character,
		// continue skipping characters of the word class.
		if off == nav.offset() && class == .separator {
			nav.skip_class(.word)
		}
	}

	return nav.offset()
}

struct WordForward {
	doc ReadableDocument
mut:
	offset    int
	chunk     []u8
	chunk_off int
}

fn (mut n WordForward) read() {
	n.chunk = n.doc.read_forward(n.offset)
	n.chunk_off = 0
}

fn (mut n WordForward) skip_newline() {
	// We can rely on the fact that the document does not split graphemes
	// across chunks = if there's a newline it's wholly contained in this
	// chunk. Unlike with WordBackward, we can't check for CR and LF
	// separately as only a CR followed by a LF is a newline. A lone CR in
	// the document is just a regular control character.
	if n.chunk_off < n.chunk.len {
		if n.chunk[n.chunk_off] == `\n` {
			n.chunk_off++
		} else if n.chunk[n.chunk_off] == `\r` && n.chunk_off + 1 < n.chunk.len
			&& n.chunk[n.chunk_off + 1] == `\n` {
			n.chunk_off += 2
		}
	}
}

fn (mut n WordForward) skip_class(class CharClass) {
	for n.chunk.len > 0 {
		for n.chunk_off < n.chunk.len {
			if classify(n.chunk[n.chunk_off]) != class {
				return
			}
			n.chunk_off++
		}

		n.offset += n.chunk.len
		n.chunk = n.doc.read_forward(n.offset)
		n.chunk_off = 0
	}
}

fn (n WordForward) peek(fallback CharClass) CharClass {
	if n.chunk_off < n.chunk.len {
		return classify(n.chunk[n.chunk_off])
	}
	return fallback
}

fn (mut n WordForward) next() {
	n.chunk_off++
}

fn (n WordForward) offset() int {
	return n.offset + n.chunk_off
}

struct WordBackward {
	doc ReadableDocument
mut:
	offset    int
	chunk     []u8
	chunk_off int
}

fn (mut n WordBackward) read() {
	n.chunk = n.doc.read_backward(n.offset)
	n.chunk_off = n.chunk.len
}

fn (mut n WordBackward) skip_newline() {
	// We can rely on the fact that the document does not split graphemes
	// across chunks = if there's a newline it's wholly contained in this
	// chunk.
	if n.chunk_off > 0 && n.chunk[n.chunk_off - 1] == `\n` {
		n.chunk_off--
	}
	if n.chunk_off > 0 && n.chunk[n.chunk_off - 1] == `\r` {
		n.chunk_off--
	}
}

fn (mut n WordBackward) skip_class(class CharClass) {
	for n.chunk.len > 0 {
		for n.chunk_off > 0 {
			if classify(n.chunk[n.chunk_off - 1]) != class {
				return
			}
			n.chunk_off--
		}

		n.offset -= n.chunk.len
		n.chunk = n.doc.read_backward(n.offset)
		n.chunk_off = n.chunk.len
	}
}

fn (n WordBackward) peek(fallback CharClass) CharClass {
	if n.chunk_off > 0 {
		return classify(n.chunk[n.chunk_off - 1])
	}
	return fallback
}

fn (mut n WordBackward) next() {
	n.chunk_off--
}

fn (n WordBackward) offset() int {
	return n.offset - n.chunk.len + n.chunk_off
}

// word_select returns the offset range (beg, end) of the "word" at the given
// offset. Does not cross newlines. Works similar to VS Code.
pub fn word_select(doc ReadableDocument, offset int) (int, int) {
	mut beg := offset
	mut end := offset
	mut class := CharClass.newline

	mut chunk := doc.read_forward(end)
	if chunk.len > 0 {
		// Not at the end of the document? Great!
		// We default to using the next char as the class, because in terminals
		// the cursor is usually always to the left of the cell you clicked on.
		class = classify(chunk[0])

		mut chunk_off := 0

		// Select the word, unless we hit a newline.
		if class != .newline {
			for {
				chunk_off++
				end++

				if chunk_off >= chunk.len {
					chunk = doc.read_forward(end)
					chunk_off = 0
					if chunk.len == 0 {
						break
					}
				}

				if classify(chunk[chunk_off]) != class {
					break
				}
			}
		}
	}

	chunk = doc.read_backward(beg)
	if chunk.len > 0 {
		mut chunk_off := chunk.len

		// If we failed to determine the class, because we hit the end of the
		// document or a newline, we fall back to using the previous character.
		if class == .newline {
			class = classify(chunk[chunk_off - 1])
		}

		// Select the word, unless we hit a newline.
		if class != .newline {
			for {
				if classify(chunk[chunk_off - 1]) != class {
					break
				}

				chunk_off--
				beg--

				if chunk_off == 0 {
					chunk = doc.read_backward(beg)
					chunk_off = chunk.len
					if chunk.len == 0 {
						break
					}
				}
			}
		}
	}

	return beg, end
}
