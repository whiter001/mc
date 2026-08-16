module main

// Port of crates/lsh/src/runtime.rs (microsoft/edit): the LSH bytecode
// interpreter for syntax highlighting. The bytecode tables (assembly,
// strings, charsets, languages) are generated into lsh_tables.v by
// tools/lsh_tables_to_v.py from the output of `lsh-bin compile`.
//
// Instruction encoding (variable length, 1-9 bytes, u32 LE operands):
//   0  Mov              dst/src reg pair byte
//   1  Add              dst/src reg pair
//   2  Sub              dst/src reg pair
//   3  MovImm           dst reg byte, u32 imm
//   4  AddImm           dst reg byte, u32 imm
//   5  SubImm           dst reg byte, u32 imm
//   6  Call             u32 tgt
//   7  Return
//   8  JumpEQ           lhs/rhs pair, u32 tgt
//   9  JumpNE           lhs/rhs pair, u32 tgt
//   10 JumpLT           lhs/rhs pair, u32 tgt
//   11 JumpLE           lhs/rhs pair, u32 tgt
//   12 JumpGT           lhs/rhs pair, u32 tgt
//   13 JumpGE           lhs/rhs pair, u32 tgt
//   14 JumpIfEndOfLine  u32 tgt
//   15 JumpIfMatchCharset u32 idx, u32 min, u32 max, u32 tgt
//   16 JumpIfMatchPrefix  u32 idx, u32 tgt
//   17 JumpIfMatchPrefixInsensitive u32 idx, u32 tgt
//   18 FlushHighlight   kind reg byte
//   19 AwaitInput
// The instruction stream is padded with 0xff bytes at the end.
//
// Gotchas inherited from the original:
// - Return with an empty stack resets the VM to the entrypoint and breaks the
//   parse loop; this is how the DSL returns to the idle state between tokens.
// - AwaitInput only breaks the loop when off >= line.len; otherwise no-op.
// - The result always has a sentinel span at line.len.

// lsh_reg_off / lsh_reg_hs / lsh_reg_pc name the three special registers;
// x3..x15 (3..=15) are caller-saved scratch registers.
const lsh_reg_off = 0
const lsh_reg_hs = 1
const lsh_reg_pc = 2
const lsh_reg_count = 16

// LshLanguage is a compiled language definition with its bytecode entrypoint
// (Rust lsh::runtime::Language). The table lives in lsh_tables.v.
struct LshLanguage {
	id         string
	name       string
	entrypoint u32
}

// LshHighlight marks that text from `start` to the next span's start has the
// given highlight kind (a u32 indexing the HighlightKind enum in
// lsh_tables.v). Spans are half-open: [start, next.start).
struct LshHighlight {
pub mut:
	start int
	kind  u32
}

// LshRegisters are the 16 VM registers. Kept as a flat array so get/set by
// decoded nibble is cheap.
struct LshRegisters {
mut:
	r [16]u32
}

// LshRuntime is the bytecode interpreter. The tables are shared references
// into the generated constants; stack/regs are the mutable machine state.
struct LshRuntime {
	assembly   []u8
	strings    []string
	charsets   []u16 // flat: 16 u16 per charset, indexed by idx*16
	entrypoint u32
mut:
	stack []u32
	regs  LshRegisters
}

// LshRuntimeState is a snapshot for incremental re-highlighting.
struct LshRuntimeState {
	stack []u32
	regs  LshRegisters
}

fn lsh_runtime_new(assembly []u8, strings []string, charsets []u16, entrypoint u32) LshRuntime {
	mut rt := LshRuntime{
		assembly:   assembly
		strings:    strings
		charsets:   charsets
		entrypoint: entrypoint
	}
	rt.regs.r[lsh_reg_pc] = entrypoint
	return rt
}

fn (rt &LshRuntime) snapshot() LshRuntimeState {
	return LshRuntimeState{
		stack: rt.stack.clone()
		regs:  rt.regs
	}
}

fn (mut rt LshRuntime) restore(state &LshRuntimeState) {
	rt.stack = state.stack.clone()
	rt.regs = state.regs
}

@[inline]
fn lsh_dec_u32(b []u8, off int) u32 {
	return u32(b[off]) | (u32(b[off + 1]) << 8) | (u32(b[off + 2]) << 16) | (u32(b[off + 3]) << 24)
}

// lsh_reg_as_off converts an offset register to an index. The DSL uses huge
// values (e.g. u32 max) as a "past the end" sentinel; Rust reads the register
// as usize where such values still compare >= line.len. V's int cast would
// wrap them negative, so clamp instead. Lines are < lsh_max_line_len, so any
// clamped value behaves identically.
@[inline]
fn lsh_reg_as_off(v u32) int {
	return if v > u32(0x7fffffff) { 0x7fffffff } else { int(v) }
}

@[inline]
fn lsh_in_set(charsets []u16, idx u32, byte u8) bool {
	lo := int(byte & 0xf)
	hi := u16(byte >> 4)
	bitset := charsets[int(idx) * 16 + lo]
	return (bitset & (u16(1) << hi)) != 0
}

// charset_gobble consumes up to `max` bytes in the set, requiring at least
// `min`; returns the new offset or -1.
fn (rt &LshRuntime) charset_gobble(line []u8, off int, idx u32, min int, max int) int {
	mut i := 0
	for i < max {
		p := off + i
		if p >= line.len || !lsh_in_set(rt.charsets, idx, line[p]) {
			break
		}
		i++
	}
	if i >= min {
		return off + i
	}
	return -1
}

@[inline]
fn lsh_memcmp(line []u8, off int, needle []u8) bool {
	if off >= line.len || line.len - off < needle.len {
		return false
	}
	for i in 0 .. needle.len {
		if line[off + i] != needle[i] {
			return false
		}
	}
	return true
}

// lsh_memicmp is lsh_memcmp case-insensitively; needles are expected to be
// lowercase printable ASCII.
@[inline]
fn lsh_memicmp(line []u8, off int, needle []u8) bool {
	if off >= line.len || line.len - off < needle.len {
		return false
	}
	for i in 0 .. needle.len {
		mut a := line[off + i]
		if a >= `A` && a <= `Z` {
			a += 32
		}
		if a != needle[i] {
			return false
		}
	}
	return true
}

// parse_next_line executes the bytecode for one line and returns the
// highlight spans partitioning it. Always contains at least the spans at
// offset 0 and line.len (sentinel).
fn (mut rt LshRuntime) parse_next_line(line []u8) []LshHighlight {
	mut res := []LshHighlight{cap: 8}

	rt.regs.r[lsh_reg_off] = 0
	rt.regs.r[lsh_reg_hs] = 0

	// By default any line starts with HighlightKind::Other (0).
	res << LshHighlight{
		start: 0
		kind:  0
	}

	code := rt.assembly
	mut done := false
	for !done {
		pc := int(rt.regs.r[lsh_reg_pc])
		op := code[pc]
		match op {
			0 { // Mov
				rt.regs.r[lsh_reg_pc] += 2
				b := code[pc + 1]
				rt.regs.r[b & 0xf] = rt.regs.r[b >> 4]
			}
			1 { // Add
				rt.regs.r[lsh_reg_pc] += 2
				b := code[pc + 1]
				dst := b & 0xf
				rt.regs.r[dst] = sat_add_u32(rt.regs.r[dst], rt.regs.r[b >> 4])
			}
			2 { // Sub
				rt.regs.r[lsh_reg_pc] += 2
				b := code[pc + 1]
				dst := b & 0xf
				rt.regs.r[dst] = sat_sub_u32(rt.regs.r[dst], rt.regs.r[b >> 4])
			}
			3 { // MovImm
				rt.regs.r[lsh_reg_pc] += 6
				rt.regs.r[code[pc + 1] & 0xf] = lsh_dec_u32(code, pc + 2)
			}
			4 { // AddImm
				rt.regs.r[lsh_reg_pc] += 6
				dst := code[pc + 1] & 0xf
				rt.regs.r[dst] = sat_add_u32(rt.regs.r[dst], lsh_dec_u32(code, pc + 2))
			}
			5 { // SubImm
				rt.regs.r[lsh_reg_pc] += 6
				dst := code[pc + 1] & 0xf
				rt.regs.r[dst] = sat_sub_u32(rt.regs.r[dst], lsh_dec_u32(code, pc + 2))
			}
			6 { // Call (pc already points at the next instruction)
				tgt := lsh_dec_u32(code, pc + 1)
				rt.regs.r[lsh_reg_pc] += 5
				// save_registers: push pc..x15 (14 values)
				for i in lsh_reg_pc .. lsh_reg_count {
					rt.stack << rt.regs.r[i]
				}
				rt.regs.r[lsh_reg_pc] = tgt
			}
			7 { // Return
				rt.regs.r[lsh_reg_pc] += 1
				// load_registers: pop 14 values into pc..x15; empty stack
				// resets the VM to the entrypoint and ends the line.
				if rt.stack.len < 14 {
					rt.regs = LshRegisters{}
					rt.regs.r[lsh_reg_pc] = rt.entrypoint
					done = true
				} else {
					base := rt.stack.len - 14
					for i in 0 .. 14 {
						rt.regs.r[lsh_reg_pc + i] = rt.stack[base + i]
					}
					rt.stack.trim(base)
				}
			}
			8, 9, 10, 11, 12, 13 { // JumpEQ/NE/LT/LE/GT/GE
				rt.regs.r[lsh_reg_pc] += 6
				b := code[pc + 1]
				lhs := rt.regs.r[b & 0xf]
				rhs := rt.regs.r[b >> 4]
				taken := match op {
					8 { lhs == rhs }
					9 { lhs != rhs }
					10 { lhs < rhs }
					11 { lhs <= rhs }
					12 { lhs > rhs }
					else { lhs >= rhs }
				}
				if taken {
					rt.regs.r[lsh_reg_pc] = lsh_dec_u32(code, pc + 2)
				}
			}
			14 { // JumpIfEndOfLine
				rt.regs.r[lsh_reg_pc] += 5
				if lsh_reg_as_off(rt.regs.r[lsh_reg_off]) >= line.len {
					rt.regs.r[lsh_reg_pc] = lsh_dec_u32(code, pc + 1)
				}
			}
			15 { // JumpIfMatchCharset
				rt.regs.r[lsh_reg_pc] += 17
				idx := lsh_dec_u32(code, pc + 1)
				min := int(lsh_dec_u32(code, pc + 5))
				max := int(lsh_dec_u32(code, pc + 9))
				off := lsh_reg_as_off(rt.regs.r[lsh_reg_off])
				new_off := rt.charset_gobble(line, off, idx, min, max)
				if new_off >= 0 {
					rt.regs.r[lsh_reg_off] = u32(new_off)
					rt.regs.r[lsh_reg_pc] = lsh_dec_u32(code, pc + 13)
				}
			}
			16 { // JumpIfMatchPrefix
				rt.regs.r[lsh_reg_pc] += 9
				idx := lsh_dec_u32(code, pc + 1)
				needle := rt.strings[idx].bytes()
				off := lsh_reg_as_off(rt.regs.r[lsh_reg_off])
				if lsh_memcmp(line, off, needle) {
					rt.regs.r[lsh_reg_off] = u32(off + needle.len)
					rt.regs.r[lsh_reg_pc] = lsh_dec_u32(code, pc + 5)
				}
			}
			17 { // JumpIfMatchPrefixInsensitive
				rt.regs.r[lsh_reg_pc] += 9
				idx := lsh_dec_u32(code, pc + 1)
				needle := rt.strings[idx].bytes()
				off := lsh_reg_as_off(rt.regs.r[lsh_reg_off])
				if lsh_memicmp(line, off, needle) {
					rt.regs.r[lsh_reg_off] = u32(off + needle.len)
					rt.regs.r[lsh_reg_pc] = lsh_dec_u32(code, pc + 5)
				}
			}
			18 { // FlushHighlight
				rt.regs.r[lsh_reg_pc] += 2
				kind := rt.regs.r[code[pc + 1] & 0xf]
				start := if lsh_reg_as_off(rt.regs.r[lsh_reg_hs]) < line.len {
					lsh_reg_as_off(rt.regs.r[lsh_reg_hs])
				} else {
					line.len
				}
				if res.len > 0 && (res.last().start == start || res.last().kind == kind) {
					res[res.len - 1].kind = kind
				} else {
					res << LshHighlight{
						start: start
						kind:  kind
					}
				}
				rt.regs.r[lsh_reg_hs] = rt.regs.r[lsh_reg_off]
			}
			19 { // AwaitInput
				rt.regs.r[lsh_reg_pc] += 1
				if lsh_reg_as_off(rt.regs.r[lsh_reg_off]) >= line.len {
					done = true
				}
			}
			else {
				// 0xff padding or corrupt bytecode: stop instead of looping.
				done = true
			}
		}
	}

	// Ensure that there's a past-the-end highlight.
	if res.len == 0 || res.last().start < line.len {
		res << LshHighlight{
			start: line.len
			kind:  0
		}
	}

	return res
}

@[inline]
fn sat_add_u32(a u32, b u32) u32 {
	sum := u64(a) + u64(b)
	return if sum > u64(max_u32) { max_u32 } else { u32(sum) }
}

@[inline]
fn sat_sub_u32(a u32, b u32) u32 {
	return if a > b { a - b } else { u32(0) }
}
