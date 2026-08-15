// diff.v — minimal line-level diff for approval previews.
//
// vlib ships no diff module, so we implement the smallest thing that
// works: a longest-common-subsequence (LCS) diff over lines. It exists
// purely to render a preview in the approval modal — correctness for
// pathological inputs (e.g. a 100KB rewrite) is handled by degrading to
// whole-block del + add instead of running O(n*m).
module main

import os
import json2

// diff_max_lines caps the LCS table size. Beyond this, diff_lines
// degrades to a single del block + a single add block (no interleaving).
const diff_max_lines = 2000

// diff_context_lines is how many unchanged (eq) lines are kept around
// each change block in the rendered preview; longer runs are collapsed.
const diff_context_lines = 2

// diff_preview_max_rows caps the number of diff rows shown in the modal.
const diff_preview_max_rows = 12

// DiffOp describes what happened to a single line of the diff.
pub enum DiffOp {
	eq  // unchanged — shown as gray context
	del // present only in the old text
	add // present only in the new text
}

// DiffLine is one line of the diff output.
pub struct DiffLine {
pub:
	op   DiffOp
	text string
}

// split_lines splits text into diffable lines. A trailing newline is a
// line terminator, not an extra empty line; an empty string has no lines.
fn split_lines(s string) []string {
	if s.len == 0 {
		return []
	}
	mut t := s
	if t.ends_with('\n') {
		t = t[..t.len - 1]
	}
	if t.len == 0 {
		return []
	}
	return t.split('\n')
}

// diff_lines computes a line-level diff between old_text and new_text
// using a longest-common-subsequence (LCS) dynamic program. The result
// is the edit script in order: unchanged lines (eq), then deletions
// (del) and insertions (add) interleaved to turn old into new.
//
// Empty inputs short-circuit to all-add / all-del. When either side has
// more than diff_max_lines lines, the O(n*m) table would be too large,
// so we degrade to a single whole-block del + a single whole-block add.
pub fn diff_lines(old_text string, new_text string) []DiffLine {
	old := split_lines(old_text)
	new := split_lines(new_text)

	// Degenerate case: whole-block del + add. Both halves stay ordered.
	if old.len > diff_max_lines || new.len > diff_max_lines {
		mut out := []DiffLine{}
		for o in old {
			out << DiffLine{op: .del, text: o}
		}
		for l in new {
			out << DiffLine{op: .add, text: l}
		}
		return out
	}

	n := old.len
	m := new.len
	// LCS lengths, packed into a single flat array (row stride m+1).
	stride := m + 1
	mut dp := []int{len: (n + 1) * stride}
	for i := n - 1; i >= 0; i-- {
		for j := m - 1; j >= 0; j-- {
			if old[i] == new[j] {
				dp[i * stride + j] = dp[(i + 1) * stride + (j + 1)] + 1
			} else {
				a := dp[(i + 1) * stride + j]
				b := dp[i * stride + (j + 1)]
				dp[i * stride + j] = if a > b { a } else { b }
			}
		}
	}

	// Walk back through the table to emit the edit script.
	mut out := []DiffLine{}
	mut i := 0
	mut j := 0
	for i < n && j < m {
		if old[i] == new[j] {
			out << DiffLine{op: .eq, text: old[i]}
			i++
			j++
		} else if dp[(i + 1) * stride + j] >= dp[i * stride + (j + 1)] {
			out << DiffLine{op: .del, text: old[i]}
			i++
		} else {
			out << DiffLine{op: .add, text: new[j]}
			j++
		}
	}
	for i < n {
		out << DiffLine{op: .del, text: old[i]}
		i++
	}
	for j < m {
		out << DiffLine{op: .add, text: new[j]}
		j++
	}
	return out
}

// approval_diff_lines builds the diff preview shown in the approval
// modal for a risky tool call.
//
//   - edit_file:  diffs the args' old_text against new_text.
//   - write_file: diffs the current on-disk file (empty when the file
//     does not exist yet) against the args' content.
//
// Any other tool name, a missing field, or unparseable JSON yields an
// empty slice (no preview).
pub fn approval_diff_lines(tool_name string, args_json string) []DiffLine {
	if tool_name == 'edit_file' {
		args := json2.decode[map[string]string](args_json) or { return []DiffLine{} }
		old_text := args['old_text'] or { return []DiffLine{} }
		new_text := args['new_text'] or { return []DiffLine{} }
		return diff_lines(old_text, new_text)
	}
	if tool_name == 'write_file' {
		args := json2.decode[map[string]string](args_json) or { return []DiffLine{} }
		path := args['path'] or { return []DiffLine{} }
		content := args['content'] or { return []DiffLine{} }
		// A missing target file reads as empty → the preview is all add.
		old_text := os.read_file(path) or { '' }
		return diff_lines(old_text, content)
	}
	return []DiffLine{}
}

// approval_args_path extracts the target file path from a tool call's
// raw JSON args (edit_file / write_file). Returns '' when the tool has
// no path field or the JSON does not parse.
fn approval_args_path(tool_name string, args_json string) string {
	if tool_name != 'edit_file' && tool_name != 'write_file' {
		return ''
	}
	args := json2.decode[map[string]string](args_json) or { return '' }
	return args['path'] or { '' }
}

// compact_diff trims a raw diff for display: eq runs longer than
// diff_context_lines are collapsed to their first/last few lines plus a
// single "..." marker, and the result is capped at diff_preview_max_rows
// (an overflow tail line reports how many lines were hidden).
fn compact_diff(diff []DiffLine) []DiffLine {
	mut out := []DiffLine{}
	mut i := 0
	for i < diff.len {
		if diff[i].op != .eq {
			out << diff[i]
			i++
			continue
		}
		mut j := i
		for j < diff.len && diff[j].op == .eq {
			j++
		}
		run := j - i
		if run <= 2 * diff_context_lines {
			out << diff[i..j]
		} else {
			out << diff[i..i + diff_context_lines]
			out << DiffLine{op: .eq, text: '...'}
			out << diff[j - diff_context_lines..j]
		}
		i = j
	}
	if out.len > diff_preview_max_rows {
		more := out.len - (diff_preview_max_rows - 1)
		out = out[..diff_preview_max_rows - 1].clone()
		out << DiffLine{op: .eq, text: '… (${more} more lines)'}
	}
	return out
}
