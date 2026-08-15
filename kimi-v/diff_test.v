// diff_test.v — tests for the minimal line-level diff used by the
// approval-preview modal.
module main

import os

// count_ops tallies how many diff lines carry each DiffOp.
fn count_ops(diff []DiffLine) (int, int, int) {
	mut eq := 0
	mut del := 0
	mut add := 0
	for dl in diff {
		match dl.op {
			.eq { eq++ }
			.del { del++ }
			.add { add++ }
		}
	}
	return eq, del, add
}

fn test_diff_lines_identical() {
	// Same text on both sides → everything is an eq line, nothing changed.
	old := 'line1\nline2\nline3'
	diff := diff_lines(old, old)
	eq, del, add := count_ops(diff)
	assert eq == 3 && del == 0 && add == 0, 'identical text should be all-eq'
}

fn test_diff_lines_all_different() {
	// Disjoint texts → all old lines deleted, all new lines added, no eq.
	old := 'a\nb'
	new := 'c\nd'
	diff := diff_lines(old, new)
	eq, del, add := count_ops(diff)
	assert eq == 0, 'disjoint texts must have no eq line'
	assert del == 2, 'expected 2 del, got ${del}'
	assert add == 2, 'expected 2 add, got ${add}'
}

fn test_diff_lines_middle_insertion() {
	// Inserting one line in the middle keeps the neighbours as eq.
	old := 'a\nb\nc'
	new := 'a\nX\nb\nc'
	diff := diff_lines(old, new)
	assert diff.len == 4, 'expected 4 diff lines, got ${diff.len}'
	assert diff[0].op == .eq && diff[0].text == 'a', 'first line should stay eq'
	assert diff[1].op == .add && diff[1].text == 'X', 'inserted line should be add'
	assert diff[2].op == .eq && diff[2].text == 'b', 'second orig line should stay eq'
	assert diff[3].op == .eq && diff[3].text == 'c', 'third orig line should stay eq'
}

fn test_diff_lines_deletion() {
	// Removing the middle line should show it as del, neighbours as eq.
	old := 'a\nb\nc'
	new := 'a\nc'
	diff := diff_lines(old, new)
	assert diff.len == 3, 'expected 3 diff lines, got ${diff.len}'
	assert diff[0].op == .eq && diff[0].text == 'a'
	assert diff[1].op == .del && diff[1].text == 'b', 'removed line should be del'
	assert diff[2].op == .eq && diff[2].text == 'c'
}

fn test_diff_lines_modify_one_line() {
	// Changing one line yields a del + add pair, neighbours untouched.
	old := 'a\nb\nc'
	new := 'a\nB\nc'
	diff := diff_lines(old, new)
	assert diff.len == 4, 'expected 4 diff lines, got ${diff.len}'
	assert diff[0].op == .eq && diff[0].text == 'a'
	assert diff[1].op == .del && diff[1].text == 'b', 'old line should be del'
	assert diff[2].op == .add && diff[2].text == 'B', 'new line should be add'
	assert diff[3].op == .eq && diff[3].text == 'c'
}

fn test_diff_lines_degrades_on_huge_input() {
	// Either side over diff_max_lines (2000) must skip the O(n*m) table
	// and degrade to whole-block del + whole-block add.
	mut old_lines := []string{}
	for i in 0 .. 2500 {
		old_lines << 'old ${i}'
	}
	new := 'only one new line'
	diff := diff_lines(old_lines.join('\n'), new)
	// Degraded form: all old lines first (del), then the single new line (add).
	assert diff.len == 2501, 'degraded diff should have 2501 lines, got ${diff.len}'
	for i in 0 .. 2500 {
		assert diff[i].op == .del, 'degraded prefix must be all del at ${i}'
	}
	assert diff[2500].op == .add && diff[2500].text == 'only one new line', 'last line must be add'
}

fn test_approval_diff_lines_edit_file() {
	// edit_file: diff old_text vs new_text from the args JSON.
	// Newlines are JSON-escaped as \n.
	args := '{"old_text":"a\\nb\\nc","new_text":"a\\nB\\nc"}'
	diff := approval_diff_lines('edit_file', args)
	assert diff.len == 4, 'expected 4 diff lines, got ${diff.len}'
	assert diff[1].op == .del && diff[2].op == .add, 'edit should be del+add pair'
}

fn test_approval_diff_lines_write_file_new_file() {
	// write_file targeting a file that does not exist → reads as empty,
	// so the preview is entirely added lines.
	args := '{"path":"/no/such/file/should/exist/kimi-v-test-xyz","content":"fresh\\ncontent\\nhere"}'
	diff := approval_diff_lines('write_file', args)
	eq, del, add := count_ops(diff)
	assert eq == 0 && del == 0, 'new file should have no eq/del lines'
	assert add == 3, 'new file should be all add, got ${add}'
}

fn test_approval_diff_lines_write_file_existing_file() {
	// write_file against a real on-disk file diffs its current contents.
	path := os.temp_dir() + '/kimi-v-diff-test.txt'
	os.write_file(path, 'alpha\nbeta\ngamma') or { assert false, 'temp file write failed' }
	defer {
		os.rm(path) or {}
	}
	args := '{"path":"${path}","content":"alpha\\nBETA\\ngamma"}'
	diff := approval_diff_lines('write_file', args)
	eq, del, add := count_ops(diff)
	assert del == 1 && add == 1, 'one line changed → 1 del + 1 add, got ${del}/${add}'
	assert eq == 2, 'two lines unchanged → 2 eq, got ${eq}'
	assert diff.any(it.op == .del && it.text == 'beta'), 'old line beta must be deleted'
	assert diff.any(it.op == .add && it.text == 'BETA'), 'new line BETA must be added'
}

fn test_approval_diff_lines_invalid_json() {
	// Unparseable args → no preview (empty slice).
	diff := approval_diff_lines('edit_file', 'this is not json')
	assert diff.len == 0, 'invalid JSON must yield empty diff'
}

fn test_approval_diff_lines_unknown_tool() {
	// Tools without a preview (e.g. bash) return an empty diff.
	diff := approval_diff_lines('bash', '{"command":"echo hi"}')
	assert diff.len == 0, 'non-file tools must yield empty diff'
}
