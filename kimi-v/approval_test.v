// approval_test.v — unit tests for the risky-tool approval flow.
//
// The end-to-end channel protocol (agent sends request, TUI sends back
// decision) is exercised manually via the TUI; V's test framework has
// trouble with goroutines spawned from test functions (the test process
// hangs on the spawned goroutine even after the test function returns).
// The pure helpers (needs_approval, next_request_id) cover the policy
// logic and are the bits most likely to break in a regression.
module main

// ---------- needs_approval ------------------------------------------------

fn test_needs_approval_in_risky_list() {
	risky := default_risky_tools
	assert needs_approval('bash', risky)
	assert needs_approval('write_file', risky)
	assert needs_approval('edit_file', risky)
	assert needs_approval('web_fetch', risky)
}

fn test_needs_approval_not_in_risky_list() {
	risky := default_risky_tools
	assert !needs_approval('read_file', risky)
	assert !needs_approval('glob', risky)
	assert !needs_approval('grep', risky)
}

fn test_needs_approval_custom_risky_list() {
	// User has tightened their config: only bash is risky.
	risky := ['bash']
	assert needs_approval('bash', risky)
	assert !needs_approval('write_file', risky)
	assert !needs_approval('web_fetch', risky)
}

fn test_needs_approval_empty_list_allows_everything() {
	// Empty risky list = permissive mode. TUI can set this to skip
	// approval entirely.
	risky := []string{}
	assert !needs_approval('bash', risky)
	assert !needs_approval('write_file', risky)
	assert !needs_approval('rm_rf', risky)
}

// ---------- next_request_id -----------------------------------------------

fn test_next_request_id_monotonic() {
	assert next_request_id(0) == 1
	assert next_request_id(1) == 2
	assert next_request_id(99) == 100
	assert next_request_id(1_000_000) == 1_000_001
}

// ---------- default_risky_tools constant ---------------------------------

fn test_default_risky_tools_matches_plan() {
	// Matches the upstream-aligned default from the design: bash, write,
	// edit, web_fetch. Read-only tools (read_file, glob, grep) are
	// auto-allowed for self-use.
	assert default_risky_tools.len == 4
	assert 'bash' in default_risky_tools
	assert 'write_file' in default_risky_tools
	assert 'edit_file' in default_risky_tools
	assert 'web_fetch' in default_risky_tools
}
