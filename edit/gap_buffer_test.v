module main

// gap_buffer_test.v — tests for the GapBuffer port.
//
// Note: the Rust reference (crates/edit/src/buffer/gap_buffer.rs) carries no
// #[cfg(test)] module of its own, so the basic tests below are written
// against the Rust API's documented semantics. On top of that they cover:
// repeated growth across 64KiB allocation chunks, read consistency after
// moving the gap back and forth, replace() out-of-bounds clamping,
// monotonic generation increments, and a seeded random differential test
// against StringDocument (same insert/delete/replace sequence on both,
// full-text comparison via chunked reads).

// gap_buffer_read_all concatenates read_forward chunks into the full text.
fn gap_buffer_read_all(b GapBuffer) []u8 {
	mut out := []u8{cap: b.len()}
	mut off := 0
	for off < b.len() {
		chunk := b.read_forward(off)
		if chunk.len == 0 {
			break
		}
		out << chunk
		off += chunk.len
	}
	return out
}

fn test_gap_buffer_new_empty() {
	mut b := new_gap_buffer()
	defer { b.free() }
	assert b.len() == 0
	assert b.text_length() == 0
	assert b.generation() == 0
	assert b.read_forward(0) == []u8{}
	assert b.read_backward(0) == []u8{}
}

fn test_gap_buffer_allocate_and_commit() {
	mut b := new_gap_buffer()
	defer { b.free() }
	mut gap := b.allocate_gap(0, 5, false)
	assert gap.len >= 5
	len := copy(mut gap, 'hello'.bytes())
	b.commit_gap(len)
	assert b.len() == 5
	assert gap_buffer_read_all(b) == 'hello'.bytes()
	assert b.generation() == 1
}

fn test_gap_buffer_replace_basic() {
	mut b := new_gap_buffer()
	defer { b.free() }
	b.replace(0, 0, 'hello world'.bytes())
	assert gap_buffer_read_all(b) == 'hello world'.bytes()
	// Insert in the middle.
	b.replace(5, 5, ' dear'.bytes())
	assert gap_buffer_read_all(b) == 'hello dear world'.bytes()
	// Delete a range.
	b.replace(5, 10, []u8{})
	assert gap_buffer_read_all(b) == 'hello world'.bytes()
	// Overwrite a range with a shorter and a longer string.
	b.replace(0, 5, 'goodbye'.bytes())
	assert gap_buffer_read_all(b) == 'goodbye world'.bytes()
	b.replace(7, 13, 'V'.bytes())
	assert gap_buffer_read_all(b) == 'goodbyeV'.bytes()
}

fn test_gap_buffer_clear() {
	mut b := new_gap_buffer()
	defer { b.free() }
	b.replace(0, 0, 'hello'.bytes())
	gen := b.generation()
	b.clear()
	assert b.len() == 0
	assert gap_buffer_read_all(b) == []u8{}
	assert b.generation() == gen + 1
	// Buffer still usable after clear.
	b.replace(0, 0, 'again'.bytes())
	assert gap_buffer_read_all(b) == 'again'.bytes()
}

fn test_gap_buffer_read_chunks_do_not_cross_gap() {
	mut b := new_gap_buffer()
	defer { b.free() }
	b.replace(0, 0, 'ABCDEFGHIJ'.bytes())
	// Insert in the middle, moving the gap there. After committing the
	// 3 inserted bytes the gap sits right after "xyz", at offset 8.
	b.replace(5, 5, 'xyz'.bytes())
	// Reading forward from 0 must stop at the gap instead of crossing it.
	assert b.read_forward(0) == 'ABCDExyz'.bytes()
	assert b.read_forward(5) == 'xyz'.bytes()
	assert b.read_forward(8) == 'FGHIJ'.bytes()
	// Backward reads similarly stop at the gap.
	assert b.read_backward(13) == 'FGHIJ'.bytes()
	assert b.read_backward(8) == 'ABCDExyz'.bytes()
	assert b.read_backward(5) == 'ABCDE'.bytes()
	// Full text is the concatenation of the chunks.
	assert gap_buffer_read_all(b) == 'ABCDExyzFGHIJ'.bytes()
}

fn test_gap_buffer_read_clamping() {
	mut b := new_gap_buffer()
	defer { b.free() }
	b.replace(0, 0, 'hello'.bytes())
	// Offsets past the end are clamped to the end: empty forward read.
	assert b.read_forward(5) == []u8{}
	assert b.read_forward(1000) == []u8{}
	// Negative offsets are clamped to 0 (V ints, unlike Rust's usize).
	assert b.read_forward(-1) == 'hello'.bytes()
	assert b.read_backward(-1) == []u8{}
	assert b.read_backward(0) == []u8{}
	// Backward reads past the end clamp to the full text.
	assert b.read_backward(1000) == 'hello'.bytes()
	// Non-empty for every in-bounds offset (ReadableDocument contract).
	for off in 0 .. 5 {
		assert b.read_forward(off).len > 0
	}
	for off in 1 .. 6 {
		assert b.read_backward(off).len > 0
	}
}

fn test_gap_buffer_replace_clamping() {
	mut b := new_gap_buffer()
	defer { b.free() }
	b.replace(0, 0, 'hello'.bytes())
	// End beyond the text is clamped.
	b.replace(3, 1000, 'p'.bytes())
	assert gap_buffer_read_all(b) == 'help'.bytes()
	// Negative start is clamped to 0; end < start deletes nothing.
	b.replace(-10, -5, '>>'.bytes())
	assert gap_buffer_read_all(b) == '>>help'.bytes()
	b.replace(2, 1, '!'.bytes())
	assert gap_buffer_read_all(b) == '>>!help'.bytes()
	// Both out of bounds entirely.
	b.replace(1000, 2000, 'end'.bytes())
	assert gap_buffer_read_all(b) == '>>!helpend'.bytes()
}

fn test_gap_buffer_generation_increments() {
	mut b := new_gap_buffer()
	defer { b.free() }
	assert b.generation() == 0
	mut prev := u32(0)
	for i in 0 .. 10 {
		b.replace(i, i, 'x'.bytes())
		assert b.generation() == prev + 1
		prev = b.generation()
	}
	// Pure allocate_gap also counts as a modification (same as Rust).
	gap := b.allocate_gap(0, 1, false)
	assert gap.len >= 1
	assert b.generation() == prev + 1
	b.commit_gap(0)
	// set_generation overrides (used when reloading a file).
	b.set_generation(42)
	assert b.generation() == 42
}

fn test_gap_buffer_multiple_growth() {
	mut b := new_gap_buffer()
	defer { b.free() }
	// Insert 100 x 8KiB = 800KiB at the end, crossing many 64KiB
	// allocation chunks (and forcing several reallocs).
	mut expected := []u8{cap: 100 * 8 * kibi}
	for i in 0 .. 100 {
		mut chunk := []u8{len: 8 * kibi, init: u8(33 + i % 90)}
		b.replace(b.len(), b.len(), chunk)
		expected << chunk
	}
	assert b.len() == 100 * 8 * kibi
	// Capacity is always a multiple of the 64KiB alloc chunk.
	assert b.capacity % gap_buffer_alloc_chunk == 0
	assert b.capacity >= b.len()
	assert gap_buffer_read_all(b) == expected
}

fn test_gap_buffer_gap_move_consistency() {
	mut b := new_gap_buffer()
	defer { b.free() }
	b.replace(0, 0, '0123456789'.bytes())
	// Bounce the gap back and forth with inserts; the surrounding text
	// must survive every move intact.
	mut expected := '0123456789'
	positions := [10, 0, 7, 3, 9, 1, 5, 10, 0, 5]
	for i, pos in positions {
		s := '(${i})'
		b.replace(pos, pos, s.bytes())
		expected = expected[..pos] + s + expected[pos..]
		assert gap_buffer_read_all(b).bytestr() == expected
	}
	// Now delete alternating ranges, again moving the gap across text.
	for b.len() > 4 {
		pos := b.len() / 2
		end := if pos + 2 > b.len() { b.len() } else { pos + 2 }
		b.replace(pos, end, []u8{})
		expected = expected[..pos] + expected[end..]
		assert gap_buffer_read_all(b).bytestr() == expected
	}
}

// Splitmix64 is a tiny deterministic PRNG so the differential test is
// reproducible without depending on rand's seeding API.
struct Splitmix64 {
mut:
	state u64
}

fn (mut r Splitmix64) next() u64 {
	r.state += 0x9e3779b97f4a7c15
	mut z := r.state
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ^ (z >> 27)) * 0x94d049bb133111eb
	return z ^ (z >> 31)
}

// intn returns a value in [0, n); n must be > 0.
fn (mut r Splitmix64) intn(n int) int {
	return int(r.next() % u64(n))
}

fn test_gap_buffer_differential_vs_string_document() {
	mut b := new_gap_buffer()
	defer { b.free() }
	mut sd := StringDocument{}
	mut rng := Splitmix64{
		state: 0x123456789abcdef0 // fixed seed: reproducible
	}
	// All valid UTF-8, so StringDocument's lossy sanitization is a no-op
	// and both implementations must behave identically.
	pieces := ['', 'a', 'bc', 'xyz', ' ', '\n', 'foo bar', '日本', '🙂', '0']
	for i in 0 .. 2000 {
		text_len := sd.text.len
		assert b.len() == text_len
		op := rng.intn(3)
		start := rng.intn(text_len + 1)
		mut end := start
		if op != 0 && text_len > 0 {
			// delete/replace a range of up to 16 bytes
			end = start + rng.intn(17)
		}
		repl := pieces[rng.intn(pieces.len)]
		b.replace(start, end, repl.bytes())
		sd.replace(start, end, repl.bytes())
		assert gap_buffer_read_all(b).bytestr() == sd.text
		// Every 50 ops also cross-check backward reads at random offsets.
		// The offset must be within the *current* text length: read_backward
		// clamps out-of-bounds offsets, and stepping back by chunk length from
		// an unclamped offset would re-read the same chunk.
		if i % 50 == 0 && b.len() > 0 {
			off := rng.intn(b.len() + 1)
			mut gb_back := []u8{}
			mut bend := off
			for bend > 0 {
				chunk := b.read_backward(bend)
				if chunk.len == 0 {
					break
				}
				gb_back.prepend(chunk)
				bend -= chunk.len
			}
			assert gb_back == sd.read_backward(off)
		}
	}
}
