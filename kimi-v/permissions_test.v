// permissions_test.v — unit tests for the permission rule engine and the
// approved-tools persistence (permissions.v).
//
// Like approval_test.v, we only test the pure helpers: pattern parsing,
// verdict evaluation, glob matching against tool args, and the on-disk
// round-trip of the "always allow" list. The channel-based approval flow is
// exercised manually via the TUI. Persistence tests redirect writes via
// KIMI_APPROVED_TOOLS_FILE to a temp file so they never touch the real
// <config_dir>/approved_tools.
module main

import os

// ---------- parse_permission_pattern ----------------------------------------

fn test_parse_permission_pattern_bare_tool_means_star() {
	tool, glob := parse_permission_pattern('Bash')!
	assert tool == 'Bash'
	assert glob == '*'
}

fn test_parse_permission_pattern_tool_glob() {
	tool, glob := parse_permission_pattern('Bash(rm -rf *)')!
	assert tool == 'Bash'
	assert glob == 'rm -rf *'
}

fn test_parse_permission_pattern_tool_glob_paths() {
	tool, glob := parse_permission_pattern('Write(/etc/**)')!
	assert tool == 'Write'
	assert glob == '/etc/**'
}

fn test_parse_permission_pattern_trims_whitespace() {
	tool, glob := parse_permission_pattern('  bash (ls *)  ')!
	assert tool == 'bash'
	assert glob == 'ls *'
}

fn test_parse_permission_pattern_rejects_bad() {
	bad := ['', 'Bash(', '(x)', 'Bash()', 'Bash(x']
	mut rejected := 0
	for p in bad {
		parse_permission_pattern(p) or {
			rejected++
			continue
		}
		assert false, 'pattern "${p}" should not parse'
	}
	assert rejected == bad.len
}

// ---------- permission_pattern_valid ----------------------------------------

fn test_permission_pattern_valid_accepts_good() {
	assert permission_pattern_valid('Bash')
	assert permission_pattern_valid('bash(ls *)')
	assert permission_pattern_valid('Write(/etc/**)')
}

fn test_permission_pattern_valid_rejects_bad() {
	assert !permission_pattern_valid('')
	assert !permission_pattern_valid('Bash(')
	assert !permission_pattern_valid('(x)')
	assert !permission_pattern_valid('Bash()')
}

// ---------- permission_match_arg --------------------------------------------

fn test_permission_match_arg_bash_is_raw_args() {
	assert permission_match_arg('bash', 'ls -la') == 'ls -la'
}

fn test_permission_match_arg_write_file_is_path() {
	assert permission_match_arg('write_file', '{"path":"./a.v","content":"x"}') == './a.v'
}

fn test_permission_match_arg_edit_file_is_path() {
	assert permission_match_arg('edit_file', '{"path":"./a.v","old":"a","new":"b"}') == './a.v'
}

fn test_permission_match_arg_web_fetch_is_url() {
	assert permission_match_arg('web_fetch', '{"url":"https://example.com","method":"GET"}') == 'https://example.com'
}

fn test_permission_match_arg_web_fetch_bad_json_falls_back_to_args() {
	// Malformed JSON can't be decoded — match against the raw args instead.
	assert permission_match_arg('web_fetch', 'not-json') == 'not-json'
}

fn test_permission_match_arg_other_tools_raw_args() {
	assert permission_match_arg('read_file', '{"path":"./a.v"}') == '{"path":"./a.v"}'
}

// ---------- evaluate_permission ---------------------------------------------

fn test_evaluate_permission_deny_match() {
	rules := [PermissionRule{ decision: 'deny', pattern: 'Bash(rm -rf *)' }]
	v, _ := evaluate_permission(rules, 'Bash', 'rm -rf /tmp/x')
	assert v == PermissionVerdict.deny
}

fn test_evaluate_permission_deny_wins_over_allow() {
	// allow listed first, deny second — deny still wins because deny is
	// scanned first.
	rules := [
		PermissionRule{ decision: 'allow', pattern: 'Bash(*)' },
		PermissionRule{ decision: 'deny', pattern: 'Bash(rm -rf *)' },
	]
	v, _ := evaluate_permission(rules, 'Bash', 'rm -rf /tmp/x')
	assert v == PermissionVerdict.deny
	// the same rule set lets a harmless command through
	v2, _ := evaluate_permission(rules, 'Bash', 'ls -la')
	assert v2 == PermissionVerdict.allow
}

fn test_evaluate_permission_allow_match() {
	// Patterns use the registry tool name (write_file, not "Write").
	rules := [PermissionRule{ decision: 'allow', pattern: 'Write_file(/tmp/**)' }]
	v, _ := evaluate_permission(rules, 'write_file', '{"path":"/tmp/x.txt","content":"hi"}')
	assert v == PermissionVerdict.allow
}

fn test_evaluate_permission_allow_no_match() {
	rules := [PermissionRule{ decision: 'allow', pattern: 'Write_file(/tmp/**)' }]
	v, _ := evaluate_permission(rules, 'write_file', '{"path":"./src/a.v","content":"hi"}')
	assert v == PermissionVerdict.none
}

fn test_evaluate_permission_ask_match() {
	rules := [PermissionRule{ decision: 'ask', pattern: 'Bash(pip install *)' }]
	v, _ := evaluate_permission(rules, 'Bash', 'pip install requests')
	assert v == PermissionVerdict.ask
}

fn test_evaluate_permission_no_match_is_none() {
	rules := [PermissionRule{ decision: 'deny', pattern: 'Bash(rm -rf *)' }]
	v, _ := evaluate_permission(rules, 'Bash', 'ls -la')
	assert v == PermissionVerdict.none
}

fn test_evaluate_permission_tool_name_case_insensitive() {
	// Config examples write `Bash`; the registry names tools lowercase.
	rules := [PermissionRule{ decision: 'allow', pattern: 'Bash(*)' }]
	v, _ := evaluate_permission(rules, 'bash', 'ls -la')
	assert v == PermissionVerdict.allow
}

fn test_evaluate_permission_write_file_path_argument() {
	// The glob matches the decoded `path` argument, not the raw JSON.
	rules := [PermissionRule{ decision: 'deny', pattern: 'Write_file(/etc/**)' }]
	v, _ := evaluate_permission(rules, 'write_file', '{"path":"/etc/hosts","content":"x"}')
	assert v == PermissionVerdict.deny
}

fn test_evaluate_permission_reason_passthrough() {
	rules := [PermissionRule{ decision: 'deny', pattern: 'Bash(rm -rf *)', reason: 'protect the box' }]
	v, reason := evaluate_permission(rules, 'Bash', 'rm -rf /tmp/x')
	assert v == PermissionVerdict.deny
	assert reason == 'protect the box'
	// rules without a reason yield ''
	rules2 := [PermissionRule{ decision: 'deny', pattern: 'Bash(rm -rf *)' }]
	_, reason2 := evaluate_permission(rules2, 'Bash', 'rm -rf /tmp/x')
	assert reason2 == ''
}

// ---------- approved-tools persistence --------------------------------------

// approved_tools_test_path returns a unique temp path for a test case, so
// concurrent/sequential test runs never collide with the real file.
fn approved_tools_test_path(tag string) string {
	return os.join_path(os.temp_dir(), 'kimi_approved_tools_${tag}_${os.getpid()}.txt')
}

fn test_save_load_approved_tools_roundtrip() {
	path := approved_tools_test_path('roundtrip')
	os.setenv('KIMI_APPROVED_TOOLS_FILE', path, true)
	defer {
		os.setenv('KIMI_APPROVED_TOOLS_FILE', '', true)
		os.rm(path) or {}
	}
	save_approved_tools(['bash', 'write_file'])!
	assert load_approved_tools() == ['bash', 'write_file']
}

fn test_save_approved_tools_trims_and_drops_blanks() {
	path := approved_tools_test_path('trim')
	os.setenv('KIMI_APPROVED_TOOLS_FILE', path, true)
	defer {
		os.setenv('KIMI_APPROVED_TOOLS_FILE', '', true)
		os.rm(path) or {}
	}
	save_approved_tools([' bash ', '', '  write_file  '])!
	assert load_approved_tools() == ['bash', 'write_file']
}

fn test_load_approved_tools_missing_file_is_empty() {
	// First run: no file yet → empty list, not an error.
	path := approved_tools_test_path('missing')
	os.setenv('KIMI_APPROVED_TOOLS_FILE', path, true)
	defer {
		os.setenv('KIMI_APPROVED_TOOLS_FILE', '', true)
		os.rm(path) or {}
	}
	assert load_approved_tools().len == 0
}

fn test_append_approved_tool_dedup_order() {
	path := approved_tools_test_path('append')
	os.setenv('KIMI_APPROVED_TOOLS_FILE', path, true)
	defer {
		os.setenv('KIMI_APPROVED_TOOLS_FILE', '', true)
		os.rm(path) or {}
	}
	append_approved_tool('bash')!
	append_approved_tool('write_file')!
	append_approved_tool('bash')! // already there → no-op
	assert load_approved_tools() == ['bash', 'write_file']
}

fn test_append_approved_tool_blank_is_noop() {
	path := approved_tools_test_path('blank')
	os.setenv('KIMI_APPROVED_TOOLS_FILE', path, true)
	defer {
		os.setenv('KIMI_APPROVED_TOOLS_FILE', '', true)
		os.rm(path) or {}
	}
	append_approved_tool('   ')!
	assert load_approved_tools().len == 0
}

fn test_clear_approved_tools() {
	path := approved_tools_test_path('clear')
	os.setenv('KIMI_APPROVED_TOOLS_FILE', path, true)
	defer {
		os.setenv('KIMI_APPROVED_TOOLS_FILE', '', true)
		os.rm(path) or {}
	}
	save_approved_tools(['bash'])!
	clear_approved_tools()!
	assert load_approved_tools().len == 0
	// Clearing again (file already gone) is not an error.
	clear_approved_tools()!
}
