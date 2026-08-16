module main

// Port of crates/edit/src/buffer/gap_buffer.rs (microsoft/edit).
//
// A gap buffer is like a Vec<T>, but the spare capacity ("gap") can be
// anywhere in the buffer, which makes edits near the gap O(1).
//
// Differences from the Rust original:
// * The Rust version reserves 4GiB of address space up front and commits
//   pages lazily (virtual memory). This port uses plain C.malloc/C.realloc
//   and grows the allocation in 64KiB chunks (Rust's commit granularity),
//   so there is no separate reserve/commit split, just a single `capacity`.
// * The small-buffer specialization (Vec backing) does not exist here;
//   all sizes share the same malloc'd backing.
// * `allocate_gap` takes `delete bool` (delete everything from `off` to the
//   end of the buffer) instead of Rust's `delete usize` byte count. The
//   full-count variant is kept as the private `allocate_gap_impl`.
//
// All raw pointer operations are confined to unsafe blocks. The backing
// memory is allocated with C.malloc/C.realloc and is NOT tracked by the GC;
// the owner MUST call `free()` when done with the buffer.

// Capacity grows in multiples of this (Rust: LARGE_ALLOC_CHUNK, the commit
// granularity of the virtual-memory version).
pub const gap_buffer_alloc_chunk = 64 * kibi
// The gap itself is rounded up to multiples of this (Rust: LARGE_GAP_CHUNK).
pub const gap_buffer_gap_chunk = 4 * kibi

// GapBuffer stores text as [before-gap | gap | after-gap] in one allocation.
pub struct GapBuffer {
mut:
	// Raw malloc'd buffer (may be nil before the first allocation).
	// Not a GC pointer; freed exclusively by `free()`.
	text        &u8 = unsafe { nil }
	// Allocated size of the buffer, including gap (multiple of 64KiB).
	capacity    int
	// Length of the stored text, NOT including the gap.
	text_length int
	// Gap offset within the logical text.
	gap_off     int
	// Gap length in bytes.
	gap_len     int
	// Increments (wrapping) every time the buffer is modified.
	generation  u32
}

// new_gap_buffer creates an empty gap buffer.
// The caller owns the result and must call `free()` on it.
pub fn new_gap_buffer() GapBuffer {
	return GapBuffer{}
}

// free releases the backing allocation. The buffer must not be used
// afterwards (this is the manual Drop; V has no destructors).
pub fn (mut b GapBuffer) free() {
	unsafe {
		C.free(b.text)
		b.text = nil
	}
	b.capacity = 0
	b.text_length = 0
	b.gap_off = 0
	b.gap_len = 0
}

// len returns the length of the stored text in bytes (NOT including the gap).
pub fn (b GapBuffer) len() int {
	return b.text_length
}

// text_length returns the length of the stored text in bytes.
pub fn (b GapBuffer) text_length() int {
	return b.text_length
}

// generation increments every time the buffer is modified.
pub fn (b GapBuffer) generation() u32 {
	return b.generation
}

// set_generation sets the generation counter (used when reloading a file).
pub fn (mut b GapBuffer) set_generation(generation u32) {
	b.generation = generation
}

// allocate_gap moves the gap to `off`, optionally deletes all text from
// `off` to the end of the buffer, enlarges the gap to hold at least `len`
// bytes, and returns a writable view of the gap for the caller to fill.
// The caller MUST then call `commit_gap` with the number of bytes written.
//
// WARNING: the returned slice aliases the raw backing memory. It may be
// shorter than `len` on allocation failure, and it is invalidated by any
// further call that moves or enlarges the gap (which may realloc).
pub fn (mut b GapBuffer) allocate_gap(off int, len int, delete bool) []u8 {
	// Rust callers pass usize::MAX to mean "delete to end".
	delete_count := if delete { b.text_length - clamp_offset(off, b.text_length) } else { 0 }
	return b.allocate_gap_impl(off, len, delete_count)
}

// allocate_gap_impl is allocate_gap with an explicit delete byte count,
// matching Rust's `allocate_gap(off, len, delete: usize)`.
fn (mut b GapBuffer) allocate_gap_impl(off int, len int, delete int) []u8 {
	// Sanitize parameters (Rust uses usize; V ints can be negative, so we
	// clamp both sides, same as the other document implementations).
	clamped_off := clamp_offset(off, b.text_length)
	mut clamped_delete := delete
	if clamped_delete < 0 {
		clamped_delete = 0
	}
	if clamped_delete > b.text_length - clamped_off {
		clamped_delete = b.text_length - clamped_off
	}

	// Move the existing gap if it exists
	if clamped_off != b.gap_off {
		b.move_gap(clamped_off)
	}

	// Delete the text
	if clamped_delete > 0 {
		b.delete_text(clamped_delete)
	}

	// Enlarge the gap if needed
	if len > b.gap_len {
		b.enlarge_gap(len)
	}

	b.generation += 1
	// Return a writable view of the gap. The caller may write up to
	// gap_len bytes and must commit_gap() the actual amount.
	return unsafe { (b.text + b.gap_off).vbytes(b.gap_len) }
}

// move_gap relocates the gap to `off` with a single memmove.
fn (mut b GapBuffer) move_gap(off int) {
	if b.gap_len > 0 {
		//
		//                       v gap_off
		// left:  |ABCDEFGHIJKLMN   OPQRSTUVWXYZ|
		//        |ABCDEFGHI   JKLMNOPQRSTUVWXYZ|
		//                  ^ off
		//        move: JKLMN
		//
		//                       v gap_off
		// !left: |ABCDEFGHIJKLMN   OPQRSTUVWXYZ|
		//        |ABCDEFGHIJKLMNOPQRS   TUVWXYZ|
		//                            ^ off
		//        move: OPQRS
		//
		left := off < b.gap_off
		move_src := if left { off } else { b.gap_off + b.gap_len }
		move_dst := if left { off + b.gap_len } else { b.gap_off }
		move_len := if left { b.gap_off - off } else { off - b.gap_off }

		unsafe {
			// memmove (not memcpy): src and dst may overlap.
			C.memmove(b.text + move_dst, b.text + move_src, usize(move_len))
		}
	}

	b.gap_off = off
}

// delete_text deletes `delete` bytes starting right after the gap,
// i.e. it simply grows the gap over them.
fn (mut b GapBuffer) delete_text(delete int) {
	b.gap_len += delete
	b.text_length -= delete
}

// enlarge_gap grows the gap to hold at least `len` bytes, growing the
// backing allocation in 64KiB chunks if necessary (realloc may move it).
fn (mut b GapBuffer) enlarge_gap(len int) {
	gap_len_old := b.gap_len
	// Round up len + one extra gap chunk of slack to a gap-chunk multiple.
	gap_len_new := (len + gap_buffer_gap_chunk + gap_buffer_gap_chunk - 1) & ~(gap_buffer_gap_chunk - 1)

	bytes_old := b.capacity
	bytes_new := b.text_length + gap_len_new

	if bytes_new > bytes_old {
		new_cap := (bytes_new + gap_buffer_alloc_chunk - 1) & ~(gap_buffer_alloc_chunk - 1)
		unsafe {
			// C.realloc(nil, n) behaves like C.malloc(n), so this also
			// covers the first allocation. On failure the old pointer
			// stays valid; we keep the old gap and the caller's
			// allocate_gap() returns a shorter slice (same as Rust's OOM
			// path which bails out without committing more pages).
			new_ptr := &u8(C.realloc(b.text, usize(new_cap)))
			if isnil(new_ptr) {
				return
			}
			b.text = new_ptr
		}
		b.capacity = new_cap
	}

	// Move the text after the gap to the right, opening up the new gap.
	unsafe {
		gap_beg := b.text + b.gap_off
		C.memmove(gap_beg + gap_len_new, gap_beg + gap_len_old, usize(b.text_length - b.gap_off))
	}

	b.gap_len = gap_len_new
}

// commit_gap marks the first `len` bytes of the gap as written text.
// Must be called after filling the slice returned by allocate_gap.
pub fn (mut b GapBuffer) commit_gap(len int) {
	assert len <= b.gap_len
	b.text_length += len
	b.gap_off += len
	b.gap_len -= len
}

// replace replaces the range `start..end` with `src`
// (allocate_gap + copy + commit_gap combined).
// Implements WriteableDocument.replace.
pub fn (mut b GapBuffer) replace(start int, end int, src []u8) {
	// Clamp start first, then derive the delete count from the clamped
	// offset (Rust: allocate_gap does off.min(len) and
	// delete.min(len - off); document.v's StringDocument does the same).
	off := clamp_offset(start, b.text_length)
	mut del := end - off
	if del < 0 {
		del = 0
	}
	mut gap := b.allocate_gap_impl(off, src.len, del)
	// copy() is Rust's slice_copy_safe: it copies min(gap.len, src.len),
	// which can be less than src.len only on allocation failure.
	len := copy(mut gap, src)
	b.commit_gap(len)
}

// clear removes all text (the gap simply covers the whole buffer).
pub fn (mut b GapBuffer) clear() {
	b.gap_off = 0
	b.gap_len += b.text_length
	b.generation += 1
	b.text_length = 0
}

// read_forward reads some bytes starting at (including) `off`.
// The returned chunk never crosses the gap, so it may be shorter than the
// remaining text; it is empty only at/after the end of the text.
// The chunk ends at the gap boundary; the gap only ever sits at edit
// offsets, which higher layers keep on grapheme boundaries (same guarantee
// the Rust version relies on).
// Implements ReadableDocument.read_forward.
pub fn (b GapBuffer) read_forward(off int) []u8 {
	clamped := clamp_offset(off, b.text_length)

	beg, len := if clamped < b.gap_off {
		// Cursor is before the gap: We can read until the start of the gap.
		clamped, b.gap_off - clamped
	} else {
		// Cursor is after the gap: We can read until the end of the buffer.
		clamped + b.gap_len, b.text_length - clamped
	}

	if len == 0 {
		return []u8{}
	}
	// Read-only view into the raw backing memory; invalidated by any
	// mutation of the buffer.
	return unsafe { (b.text + beg).vbytes(len) }
}

// read_backward reads some bytes before (but not including) `off`.
// The returned chunk never crosses the gap; it is empty only at offset 0.
// Implements ReadableDocument.read_backward.
pub fn (b GapBuffer) read_backward(off int) []u8 {
	clamped := clamp_offset(off, b.text_length)

	beg, len := if clamped <= b.gap_off {
		// Cursor is before the gap: We can read until the beginning of the buffer.
		0, clamped
	} else {
		// Cursor is after the gap: We can read until the end of the gap.
		b.gap_off + b.gap_len, clamped - b.gap_off
	}

	if len == 0 {
		return []u8{}
	}
	// Read-only view into the raw backing memory; invalidated by any
	// mutation of the buffer.
	return unsafe { (b.text + beg).vbytes(len) }
}

// Compile-time check that GapBuffer implements both document interfaces.
fn gap_buffer_implements_interfaces(mut gb GapBuffer) {
	_ := ReadableDocument(gb)
	_ := WriteableDocument(gb)
}
