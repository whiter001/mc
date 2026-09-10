module main

// ---- Regular expressions ---------------------------------------------------
//
// The Rust original uses ICU regular expressions. This port ships a small
// self-contained engine instead: a recursive-descent parser that builds an
// AST, a compiler that lowers the AST to a flat instruction list, and a
// backtracking VM. The VM keeps its backtracking stack on the heap rather
// than on the C stack, so `.*` over a long line can't overflow it.
//
// Supported syntax:
//
//	literals, `.`, `^`, `$`, `\b`, `\B`
//	`\w` `\W` `\s` `\S` `\d` `\D`, `\n` `\r` `\t` `\f` `\v` `\a` `\e`,
//	    and `\` + any other byte as a literal
//	`[...]` classes with ranges, negation and the class escapes above
//	`*` `+` `?` `{n}` `{n,}` `{n,m}`, each optionally followed by `?` (lazy)
//	`(...)`, `(?:...)`, `|`
//
// Deliberately unsupported (reported as compile errors): backreferences,
// look-around, possessive quantifiers, inline flags and `\x`/`\u` escapes.
// Unsupported patterns must never silently match the wrong thing — see
// regex_compile, which is the single place that decides validity.

// re_max_repeat caps `{n,m}` expansion so a pathological pattern can't blow
// up the instruction list.
const re_max_repeat = 1000

enum ReOp {
	op_lit
	op_dot
	op_cls
	op_bol
	op_eol
	op_wb
	op_nwb
	op_split
	op_jump
	op_cap_beg
	op_cap_end
	op_loop_back
	op_match
}

// ReClassItem is one element of a `[...]` class: either a codepoint range
// (`esc == 0`, `lo..hi` inclusive) or a class escape such as `\w` (`esc` holds
// the escape byte, `lo`/`hi` unused).
struct ReClassItem {
	lo  rune
	hi  rune
	esc u8
}

struct ReInst {
mut:
	op    ReOp
	cp    rune
	neg   bool
	items []ReClassItem
	// Continuation for the "normal" (non-branching) instructions.
	next int
	// Branch target: split's preferred branch, jump's target, loop_back's head.
	x int
	// split's fallback branch.
	y int
	// Capture group index for cap_beg/cap_end. 1-based; 0 is the whole match.
	grp int
	// Empty-loop guard slot for loop_back.
	slot int
}

// Regex is a compiled pattern. It is read-only once compiled; per-search state
// lives in ReVm.
struct Regex {
mut:
	insts       []ReInst
	entry       int
	group_count int
	loop_slots  int
}

enum ReAstKind {
	ast_lit
	ast_dot
	ast_cls
	ast_bol
	ast_eol
	ast_wb
	ast_nwb
	ast_empty
	ast_cat
	ast_alt
	ast_rep
	ast_group
}

struct ReAst {
mut:
	kind    ReAstKind
	cp      rune
	neg     bool
	items   []ReClassItem
	a       int
	b_      int
	rep_min int
	rep_max int // -1 = unbounded
	greedy  bool
	grp     int // -1 = non-capturing group
}

struct ReParser {
mut:
	pat         []u8
	pos         int
	ast         []ReAst
	insts       []ReInst
	group_count int
	loop_slots  int
}

fn (mut p ReParser) push_ast(node ReAst) int {
	p.ast << node
	return p.ast.len - 1
}

fn (mut p ReParser) push_inst(inst ReInst) int {
	p.insts << inst
	return p.insts.len - 1
}

// ---- Parsing ---------------------------------------------------------------

fn (mut p ReParser) parse_alt() !int {
	mut branches := []int{}
	branches << p.parse_seq()!
	for p.pos < p.pat.len && p.pat[p.pos] == `|` {
		p.pos++
		branches << p.parse_seq()!
	}
	// Fold right-to-left so the last branch becomes the fallback of a chain of
	// splits; that makes the first branch the preferred (leftmost) one.
	mut res := branches[branches.len - 1]
	for i := branches.len - 2; i >= 0; i-- {
		res = p.push_ast(ReAst{
			kind: .ast_alt
			a:    branches[i]
			b_:   res
		})
	}
	return res
}

fn (mut p ReParser) parse_seq() !int {
	mut items := []int{}
	for p.pos < p.pat.len && p.pat[p.pos] != `|` && p.pat[p.pos] != `)` {
		items << p.parse_repeat()!
	}
	if items.len == 0 {
		return p.push_ast(ReAst{
			kind: .ast_empty
		})
	}
	mut res := items[items.len - 1]
	for i := items.len - 2; i >= 0; i-- {
		res = p.push_ast(ReAst{
			kind: .ast_cat
			a:    items[i]
			b_:   res
		})
	}
	return res
}

fn (mut p ReParser) parse_repeat() !int {
	atom := p.parse_atom()!
	mut min := 0
	mut max := -1
	mut greedy := true
	mut quantified := false

	for p.pos < p.pat.len {
		c := p.pat[p.pos]
		if c == `*` {
			min = 0
			max = -1
			p.pos++
		} else if c == `+` {
			min = 1
			max = -1
			p.pos++
		} else if c == `?` {
			min = 0
			max = 1
			p.pos++
		} else if c == `{` {
			lo, hi, ok := p.try_parse_counted()
			if !ok {
				break
			}
			min = lo
			max = hi
		} else {
			break
		}
		quantified = true

		if p.pos < p.pat.len && p.pat[p.pos] == `?` {
			greedy = false
			p.pos++
		} else if p.pos < p.pat.len && p.pat[p.pos] == `+` {
			return error('possessive quantifiers are not supported')
		}
	}

	if !quantified {
		return atom
	}
	if max >= 0 && max < min {
		return error('invalid repeat range')
	}
	if min > re_max_repeat || (max >= 0 && max > re_max_repeat) {
		return error('repeat count too large')
	}
	return p.push_ast(ReAst{
		kind:    .ast_rep
		a:       atom
		rep_min: min
		rep_max: max
		greedy:  greedy
	})
}

// try_parse_counted consumes `{n}` / `{n,}` / `{n,m}` and returns
// (min, max, matched). A `{` that doesn't form a valid quantifier is left
// alone so parse_atom can treat it as a literal.
fn (mut p ReParser) try_parse_counted() (int, int, bool) {
	mut i := p.pos + 1
	mut lo := 0
	mut digits := 0
	for i < p.pat.len && p.pat[i] >= `0` && p.pat[i] <= `9` {
		lo = lo * 10 + int(p.pat[i] - `0`)
		i++
		digits++
	}
	if digits == 0 {
		return 0, 0, false
	}
	mut hi := lo
	if i < p.pat.len && p.pat[i] == `,` {
		i++
		hi = -1
		mut acc := 0
		mut hi_digits := 0
		for i < p.pat.len && p.pat[i] >= `0` && p.pat[i] <= `9` {
			acc = acc * 10 + int(p.pat[i] - `0`)
			i++
			hi_digits++
		}
		if hi_digits > 0 {
			hi = acc
		}
	}
	if i >= p.pat.len || p.pat[i] != `}` {
		return 0, 0, false
	}
	p.pos = i + 1
	return lo, hi, true
}

fn (mut p ReParser) parse_atom() !int {
	if p.pos >= p.pat.len {
		return error('unexpected end of pattern')
	}
	c := p.pat[p.pos]
	if c == `(` {
		p.pos++
		mut grp := -1
		if p.pos + 1 < p.pat.len && p.pat[p.pos] == `?` && p.pat[p.pos + 1] == `:` {
			p.pos += 2
		} else if p.pos < p.pat.len && p.pat[p.pos] == `?` {
			return error('unsupported group syntax')
		} else {
			p.group_count++
			grp = p.group_count
		}
		inner := p.parse_alt()!
		if p.pos >= p.pat.len || p.pat[p.pos] != `)` {
			return error('missing closing parenthesis')
		}
		p.pos++
		return p.push_ast(ReAst{
			kind: .ast_group
			a:    inner
			grp:  grp
		})
	}
	if c == `[` {
		return p.parse_class()!
	}
	if c == `\\` {
		return p.parse_escape()!
	}
	if c == `.` {
		p.pos++
		return p.push_ast(ReAst{
			kind: .ast_dot
		})
	}
	if c == `^` {
		p.pos++
		return p.push_ast(ReAst{
			kind: .ast_bol
		})
	}
	if c == `$` {
		p.pos++
		return p.push_ast(ReAst{
			kind: .ast_eol
		})
	}
	if c == `*` || c == `+` || c == `?` {
		return error('nothing to repeat')
	}
	if c == `)` {
		return error('unexpected )')
	}
	cp, n := utf8_decode(p.pat, p.pos)
	p.pos += n
	return p.push_ast(ReAst{
		kind: .ast_lit
		cp:   cp
	})
}

// re_escape_codepoints maps the escapes that stand for a control character.
// Anything else is a literal (so `\*` is a literal asterisk).
fn re_escape_codepoint(c u8) ?rune {
	return match c {
		`n` { rune(0x0a) }
		`r` { rune(0x0d) }
		`t` { rune(0x09) }
		`f` { rune(0x0c) }
		`v` { rune(0x0b) }
		`a` { rune(0x07) }
		`e` { rune(0x1b) }
		else { none }
	}
}

fn (mut p ReParser) parse_escape() !int {
	p.pos++ // consume the backslash
	if p.pos >= p.pat.len {
		return error('trailing backslash')
	}
	e := p.pat[p.pos]
	p.pos++
	if e == `b` {
		return p.push_ast(ReAst{
			kind: .ast_wb
		})
	}
	if e == `B` {
		return p.push_ast(ReAst{
			kind: .ast_nwb
		})
	}
	if e == `w` || e == `W` || e == `s` || e == `S` || e == `d` || e == `D` {
		return p.push_ast(ReAst{
			kind:  .ast_cls
			items: [ReClassItem{
				esc: e
			}]
		})
	}
	if cp := re_escape_codepoint(e) {
		return p.push_ast(ReAst{
			kind: .ast_lit
			cp:   cp
		})
	}
	// Any other escaped byte (or multi-byte codepoint) is a literal.
	cp, n := utf8_decode(p.pat, p.pos - 1)
	p.pos = p.pos - 1 + n
	return p.push_ast(ReAst{
		kind: .ast_lit
		cp:   cp
	})
}

fn (mut p ReParser) parse_class() !int {
	mut i := p.pos + 1
	mut neg := false
	mut items := []ReClassItem{}
	if i < p.pat.len && p.pat[i] == `^` {
		neg = true
		i++
	}
	for i < p.pat.len && p.pat[i] != `]` {
		if p.pat[i] == `\\` {
			i++
			if i >= p.pat.len {
				return error('unterminated character class')
			}
			e := p.pat[i]
			i++
			items << ReClassItem{
				esc: e
			}
			continue
		}
		lo, n := utf8_decode(p.pat, i)
		i += n
		// A `-` is a range operator only when something follows it other than
		// the closing bracket, so `[-a]` and `[a-]` keep it literal.
		if i < p.pat.len && p.pat[i] == `-` && i + 1 < p.pat.len && p.pat[i + 1] != `]` {
			i++
			hi, hn := utf8_decode(p.pat, i)
			i += hn
			items << ReClassItem{
				lo: lo
				hi: hi
			}
		} else {
			items << ReClassItem{
				lo: lo
				hi: lo
			}
		}
	}
	if i >= p.pat.len {
		return error('unterminated character class')
	}
	p.pos = i + 1 // consume `]`
	return p.push_ast(ReAst{
		kind:  .ast_cls
		neg:   neg
		items: items
	})
}

// ---- Compiling -------------------------------------------------------------

// emit lowers the AST node `ni` into instructions whose continuation is
// `next`, and returns the entry instruction index. Continuation-passing keeps
// the emitter allocation-free w.r.t. patch lists: every instruction knows its
// successor up front.
fn (mut p ReParser) emit(ni int, next int) !int {
	n := p.ast[ni]
	match n.kind {
		.ast_empty {
			return next
		}
		.ast_lit {
			return p.push_inst(ReInst{
				op:   .op_lit
				cp:   n.cp
				next: next
			})
		}
		.ast_dot {
			return p.push_inst(ReInst{
				op:   .op_dot
				next: next
			})
		}
		.ast_cls {
			return p.push_inst(ReInst{
				op:    .op_cls
				neg:   n.neg
				items: n.items
				next:  next
			})
		}
		.ast_bol {
			return p.push_inst(ReInst{
				op:   .op_bol
				next: next
			})
		}
		.ast_eol {
			return p.push_inst(ReInst{
				op:   .op_eol
				next: next
			})
		}
		.ast_wb {
			return p.push_inst(ReInst{
				op:   .op_wb
				next: next
			})
		}
		.ast_nwb {
			return p.push_inst(ReInst{
				op:   .op_nwb
				next: next
			})
		}
		.ast_cat {
			tail := p.emit(n.b_, next)!
			return p.emit(n.a, tail)!
		}
		.ast_alt {
			prefer := p.emit(n.a, next)!
			fallback := p.emit(n.b_, next)!
			return p.push_inst(ReInst{
				op: .op_split
				x:  prefer
				y:  fallback
			})
		}
		.ast_group {
			if n.grp < 0 {
				return p.emit(n.a, next)!
			}
			end := p.push_inst(ReInst{
				op:   .op_cap_end
				grp:  n.grp
				next: next
			})
			body := p.emit(n.a, end)!
			return p.push_inst(ReInst{
				op:   .op_cap_beg
				grp:  n.grp
				next: body
			})
		}
		.ast_rep {
			mut cur := next
			if n.rep_max < 0 {
				// Unbounded: mandatory copies followed by a loop.
				//   L:  split(body, next)
				//   body ... loop_back L
				slot := p.loop_slots
				p.loop_slots++
				head := p.push_inst(ReInst{
					op:   .op_split
					slot: slot
				})
				back := p.push_inst(ReInst{
					op:   .op_loop_back
					x:    head
					slot: slot
				})
				body := p.emit(n.a, back)!
				if n.greedy {
					p.insts[head].x = body
					p.insts[head].y = next
				} else {
					p.insts[head].x = next
					p.insts[head].y = body
				}
				cur = head
			} else {
				// Bounded: `min` mandatory copies plus `max - min` optional
				// ones, nested so that greedy tries the longest first.
				for _ in 0 .. (n.rep_max - n.rep_min) {
					body := p.emit(n.a, cur)!
					if n.greedy {
						cur = p.push_inst(ReInst{
							op: .op_split
							x:  body
							y:  cur
						})
					} else {
						cur = p.push_inst(ReInst{
							op: .op_split
							x:  cur
							y:  body
						})
					}
				}
			}
			for _ in 0 .. n.rep_min {
				cur = p.emit(n.a, cur)!
			}
			return cur
		}
	}
	return error('internal error: unhandled AST node')
}

// regex_compile parses and compiles `pattern`.
pub fn regex_compile(pattern []u8) !Regex {
	mut p := ReParser{
		pat: pattern
	}
	root := p.parse_alt()!
	if p.pos < p.pat.len {
		return error('unexpected ${p.pat[p.pos].ascii_str()} at offset ${p.pos}')
	}
	accept := p.push_inst(ReInst{
		op: .op_match
	})
	entry := p.emit(root, accept)!
	return Regex{
		insts:       p.insts
		entry:       entry
		group_count: p.group_count
		loop_slots:  p.loop_slots
	}
}

// regex_error returns the compile error for `pattern`, or '' when it is valid.
// Used by the search UI to surface bad patterns instead of silently reporting
// "no matches".
pub fn regex_error(pattern string) string {
	regex_compile(pattern.bytes()) or { return err.msg() }
	return ''
}

// ---- Matching --------------------------------------------------------------

struct ReThread {
	pc int
	t  int
}

// ReUndo reverts a capture slot (or an empty-loop guard slot) once the
// backtracking stack shrinks below `depth`, i.e. once the branch that set it
// has been abandoned.
struct ReUndo {
	slot   int
	val    int
	depth  int
	is_loop bool
}

struct ReVm {
mut:
	text       []u8
	match_case bool
	caps       []int
	loop_pos   []int
	stack      []ReThread
	undo       []ReUndo
	steps      int
	budget     int
}

fn (mut vm ReVm) set_slot(slot int, val int, is_loop bool) {
	old := if is_loop { vm.loop_pos[slot] } else { vm.caps[slot] }
	if old == val {
		return
	}
	vm.undo << ReUndo{
		slot:    slot
		val:     old
		depth:   vm.stack.len
		is_loop: is_loop
	}
	if is_loop {
		vm.loop_pos[slot] = val
	} else {
		vm.caps[slot] = val
	}
}

fn (mut vm ReVm) reset(re &Regex, start int) {
	vm.stack.clear()
	vm.undo.clear()
	for i in 0 .. vm.caps.len {
		vm.caps[i] = -1
	}
	for i in 0 .. vm.loop_pos.len {
		vm.loop_pos[i] = -1
	}
	vm.stack << ReThread{
		pc: re.entry
		t:  start
	}
}

// exec runs the program from `start` and returns the end offset of the
// leftmost-preferred match, or -1. `vm.caps` holds the capture slots of the
// accepted match (slot 0/1 are filled in by the caller, which knows the start).
fn (mut vm ReVm) exec(re &Regex) int {
	for vm.stack.len > 0 {
		vm.steps++
		if vm.steps > vm.budget {
			return -1
		}
		th := vm.stack[vm.stack.len - 1]
		vm.stack.delete_last()
		for vm.undo.len > 0 && vm.undo[vm.undo.len - 1].depth > vm.stack.len {
			u := vm.undo[vm.undo.len - 1]
			vm.undo.delete_last()
			if u.is_loop {
				vm.loop_pos[u.slot] = u.val
			} else {
				vm.caps[u.slot] = u.val
			}
		}
		mut pc := th.pc
		mut t := th.t
		for {
			inst := re.insts[pc]
			match inst.op {
				.op_match {
					return t
				}
				.op_jump {
					pc = inst.x
				}
				.op_split {
					vm.stack << ReThread{
						pc: inst.y
						t:  t
					}
					pc = inst.x
				}
				.op_lit {
					if t >= vm.text.len {
						break
					}
					tcp, tn := utf8_decode(vm.text, t)
					mut ok := false
					if vm.match_case {
						ok = tcp == inst.cp
					} else {
						ok = fold_rune(tcp) == fold_rune(inst.cp)
					}
					if !ok {
						break
					}
					t += tn
					pc = inst.next
				}
				.op_dot {
					if t >= vm.text.len {
						break
					}
					cp, n := utf8_decode(vm.text, t)
					if cp == rune(`\n`) {
						break
					}
					t += n
					pc = inst.next
				}
				.op_cls {
					if t >= vm.text.len {
						break
					}
					cp, n := utf8_decode(vm.text, t)
					if !re_class_matches(inst, cp, vm.match_case) {
						break
					}
					t += n
					pc = inst.next
				}
				.op_bol {
					if !(t == 0 || vm.text[t - 1] == `\n`) {
						break
					}
					pc = inst.next
				}
				.op_eol {
					if !(t == vm.text.len || vm.text[t] == `\n`) {
						break
					}
					pc = inst.next
				}
				.op_wb {
					if !is_word_boundary(vm.text, t) {
						break
					}
					pc = inst.next
				}
				.op_nwb {
					if is_word_boundary(vm.text, t) {
						break
					}
					pc = inst.next
				}
				.op_cap_beg {
					vm.set_slot(inst.grp * 2, t, false)
					pc = inst.next
				}
				.op_cap_end {
					vm.set_slot(inst.grp * 2 + 1, t, false)
					pc = inst.next
				}
				.op_loop_back {
					// Refuse an iteration that consumed nothing, which is what
					// would otherwise spin forever on `(a*)*`.
					if vm.loop_pos[inst.slot] == t {
						break
					}
					vm.set_slot(inst.slot, t, true)
					pc = inst.x
				}
			}
		}
	}
	return -1
}

// re_class_matches tests whether `cp` is a member of the class `inst`.
fn re_class_matches(inst ReInst, cp rune, match_case bool) bool {
	mut found := false
	for it in inst.items {
		if it.esc != 0 {
			if re_class_char_matches(it.esc, cp, SearchOptions{
				match_case: match_case
			}) {
				found = true
			}
			continue
		}
		lo := if match_case { it.lo } else { fold_rune(it.lo) }
		hi := if match_case { it.hi } else { fold_rune(it.hi) }
		fc := if match_case { cp } else { fold_rune(cp) }
		if fc >= lo && fc <= hi {
			found = true
		}
	}
	return found != inst.neg
}

// re_class_char_matches tests whether codepoint `cp` satisfies the class
// escape `e` (used inside `[...]` and for `\w`-style escapes).
fn re_class_char_matches(e u8, cp rune, options SearchOptions) bool {
	match e {
		`w` {
			return is_word_rune(cp)
		}
		`W` {
			return !is_word_rune(cp)
		}
		`s` {
			return is_space_rune(cp)
		}
		`S` {
			return !is_space_rune(cp)
		}
		`d` {
			return cp >= `0` && cp <= `9`
		}
		`D` {
			return !(cp >= `0` && cp <= `9`)
		}
		`n` {
			return cp == `\n`
		}
		`t` {
			return cp == `\t`
		}
		`r` {
			return cp == `\r`
		}
		else {
			pcp, _ := utf8_decode([e], 0)
			if options.match_case {
				return cp == pcp
			}
			return fold_rune(cp) == fold_rune(pcp)
		}
	}
}

// RegexMatch is a match found by regex_find. `caps` holds `(group_count + 1)`
// begin/end pairs: index 0 is the whole match, group g lives at 2g/2g+1.
// Unset slots are -1.
struct RegexMatch {
mut:
	beg  int
	end  int
	caps []int
}

// regex_find returns the first match of `re` at or after `start`.
// `whole_word` is applied here (as a boundary check around the match) rather
// than by wrapping the pattern, so it composes with the caller's offsets.
fn regex_find(re &Regex, text []u8, start int, options SearchOptions) RegexMatch {
	mut s := start
	if s < 0 {
		s = 0
	}
	// The budget bounds catastrophic backtracking: enough for a linear scan
	// plus generous slack for nested alternations.
	budget := 1_000_000 + 16 * text.len
	mut vm := ReVm{
		text:       text
		match_case: options.match_case
		caps:       []int{len: (re.group_count + 1) * 2, init: -1}
		loop_pos:   []int{len: re.loop_slots + 1, init: -1}
		budget:     budget
	}
	for off := s; off <= text.len; off++ {
		vm.reset(re, off)
		end := vm.exec(re)
		if end < 0 {
			continue
		}
		if options.whole_word {
			if is_word_before(text, off) {
				continue
			}
			if is_word_after(text, end) {
				continue
			}
		}
		vm.caps[0] = off
		vm.caps[1] = end
		return RegexMatch{
			beg:  off
			end:  end
			caps: copy_int(vm.caps)
		}
	}
	return RegexMatch{
		beg: -1
		end: -1
	}
}

// ---- Small helpers ---------------------------------------------------------

fn copy_u8(src []u8) []u8 {
	mut out := []u8{cap: src.len}
	out << src
	return out
}

fn copy_int(src []int) []int {
	mut out := []int{cap: src.len}
	out << src
	return out
}

// ---- Replacement templates -------------------------------------------------

enum ReplPartKind {
	text
	group
}

struct ReplPart {
	kind  ReplPartKind
	text  []u8
	group int
}

// parse_replacement splits a replacement template into literal runs and
// capture references. It mirrors Rust's find_parse_replacement:
//
//	$$            a literal `$`
//	$0 .. $N      capture group N (whole match for 0); out-of-range numbers
//	              and a trailing `$` are kept as literal text
//	\n \r \t      control characters; any other `\x` is a literal `x`, and a
//	              trailing backslash stays a backslash
//
// With `use_regex` false the template is returned as a single literal run,
// which is what makes `$1` inert for plain-text replacements.
fn parse_replacement(replacement []u8, group_count int, use_regex bool) []ReplPart {
	mut res := []ReplPart{}
	if !use_regex {
		if replacement.len > 0 {
			res << ReplPart{
				kind: .text
				text: copy_u8(replacement)
			}
		}
		return res
	}

	mut text := []u8{}
	mut text_beg := 0
	for {
		// Scan to the next `$` or `\`.
		mut off := text_beg
		for off < replacement.len && replacement[off] != `$` && replacement[off] != `\\` {
			off++
		}
		if text_beg < off {
			text << replacement[text_beg..off]
		}

		// Unescape runs of backslashes.
		for off < replacement.len && replacement[off] == `\\` {
			off += 2
			ch := if off - 1 < replacement.len { replacement[off - 1] } else { u8(`\\`) }
			decoded := match ch {
				`n` { u8(0x0a) }
				`r` { u8(0x0d) }
				`t` { u8(0x09) }
				else { ch }
			}
			text << decoded
		}

		mut group := -1
		if off < replacement.len && replacement[off] == `$` {
			mut beg := off
			mut end := off + 1
			mut acc := 0
			mut acc_bad := true
			if end < replacement.len {
				ch := replacement[end]
				if ch == `$` {
					beg += 1
					end += 1
				} else if ch >= `0` && ch <= `9` {
					acc_bad = false
					for {
						acc = acc * 10 + int(replacement[end] - `0`)
						if acc > group_count {
							acc_bad = true
						}
						end += 1
						if !(end < replacement.len && replacement[end] >= `0`
							&& replacement[end] <= `9`) {
							break
						}
					}
				}
			}
			if !acc_bad {
				group = acc
			} else {
				text << replacement[beg..end]
			}
			off = end
		}

		if text.len > 0 {
			// Adjacent literal runs can arise when an escape is decoded before
			// the next scan iteration. Keep them as one part so callers do not
			// have to distinguish parser implementation details.
			if res.len > 0 && res[res.len - 1].kind == .text {
				mut merged := copy_u8(res[res.len - 1].text)
				merged << text
				res[res.len - 1] = ReplPart{
					kind: .text
					text: merged
				}
			} else {
				res << ReplPart{
					kind: .text
					text: copy_u8(text)
				}
			}
			text.clear()
		}
		if group >= 0 {
			res << ReplPart{
				kind:  .group
				group: group
			}
		}

		text_beg = off
		if text_beg >= replacement.len {
			break
		}
	}
	return res
}

// expand_replacement renders a parsed template against the match text and
// capture slots. Group slots that never participated in the match contribute
// nothing, matching Rust's `regex.group(g)` returning None.
fn expand_replacement(parts []ReplPart, text []u8, caps []int) []u8 {
	mut out := []u8{}
	for part in parts {
		if part.kind == .text {
			out << part.text
			continue
		}
		slot := part.group * 2
		if slot + 1 >= caps.len {
			continue
		}
		beg := caps[slot]
		end := caps[slot + 1]
		if beg < 0 || end < 0 || end < beg {
			continue
		}
		out << text[beg..end]
	}
	return out
}
