// doctor_test.v — unit tests for the offline config checks.
//
// We only test the pure validation functions (no filesystem, no network):
// each failure scenario plus the all-pass path. The orchestration in
// run_doctor() (which loads config + builds a registry) is exercised
// manually via `bin/kimi doctor`, not here.
module main

// ---------- toml_parse_ok -------------------------------------------------

fn test_toml_parse_ok_valid() {
	ok, msg := toml_parse_ok('provider = "openai-compat"\nmodel = "k2"')
	assert ok
	assert msg.len == 0
}

fn test_toml_parse_ok_invalid() {
	ok, msg := toml_parse_ok('provider = "openai-compat\nmodel = ') // unterminated string + bad line
	assert !ok
	assert msg.len > 0
}

// ---------- check_provider ------------------------------------------------

fn test_check_provider_valid() {
	r := check_provider(Config{ provider: 'anthropic' })
	assert r.status == 'PASS'
	r2 := check_provider(Config{ provider: 'openai-responses' })
	assert r2.status == 'PASS'
	r3 := check_provider(Config{ provider: 'openai-compat' })
	assert r3.status == 'PASS'
}

fn test_check_provider_unknown() {
	r := check_provider(Config{ provider: 'gemini' })
	assert r.status == 'FAIL'
	assert r.advice.len > 0
}

// ---------- check_model ---------------------------------------------------

fn test_check_model_set() {
	r := check_model(Config{ model: 'kimi-k2' })
	assert r.status == 'PASS'
}

fn test_check_model_empty() {
	r := check_model(Config{ model: '' })
	assert r.status == 'FAIL'
	assert r.advice.len > 0
}

// ---------- check_api_base ------------------------------------------------

fn test_check_api_base_https_pass() {
	r := check_api_base(Config{ api_base: 'https://api.example.com/v1' })
	assert r.status == 'PASS'
}

fn test_check_api_base_http_warn() {
	r := check_api_base(Config{ api_base: 'http://localhost:8080' })
	assert r.status == 'WARN'
}

fn test_check_api_base_empty_fail() {
	r := check_api_base(Config{ api_base: '' })
	assert r.status == 'FAIL'
}

fn test_check_api_base_bad_fail() {
	r := check_api_base(Config{ api_base: 'ftp://nope' })
	assert r.status == 'FAIL'
}

// ---------- check_api_key -------------------------------------------------

fn test_check_api_key_set() {
	r := check_api_key(Config{ api_key: 'sk-xyz' })
	assert r.status == 'PASS'
}

fn test_check_api_key_empty() {
	r := check_api_key(Config{ api_key: '' })
	assert r.status == 'FAIL'
}

// ---------- check_risky_tools ---------------------------------------------

fn test_check_risky_tools_empty_pass() {
	r := check_risky_tools([], ['bash', 'write_file'])
	assert r.status == 'PASS'
}

fn test_check_risky_tools_all_known_pass() {
	r := check_risky_tools(['bash', 'write_file'], ['bash', 'write_file', 'read_file'])
	assert r.status == 'PASS'
}

fn test_check_risky_tools_unknown_fail() {
	r := check_risky_tools(['bash', 'bosh'], ['bash', 'write_file', 'read_file'])
	assert r.status == 'FAIL'
	assert r.detail.contains('bosh')
}

// ---------- check_permission_rules ---------------------------------------

fn test_check_permission_rules_empty_pass() {
	r := check_permission_rules([])
	assert r.status == 'PASS'
}

fn test_check_permission_rules_valid_pass() {
	rules := [
		PermissionRule{ decision: 'allow', pattern: 'Tool(read_file)' },
		PermissionRule{ decision: 'deny', pattern: 'Tool(bash)' },
	]
	r := check_permission_rules(rules)
	assert r.status == 'PASS'
}

fn test_check_permission_rules_bad_decision_fail() {
	rules := [PermissionRule{ decision: 'maybe', pattern: 'Tool(read_file)' }]
	r := check_permission_rules(rules)
	assert r.status == 'FAIL'
}

fn test_check_permission_rules_bad_pattern_fail() {
	// 'Bash(unclosed' is missing the closing ')' — rejected by
	// parse_permission_pattern. ('Tool(***)' would parse fine: the glob is
	// non-empty, and glob semantics are not doctor's job.)
	rules := [PermissionRule{ decision: 'allow', pattern: 'Bash(unclosed' }]
	r := check_permission_rules(rules)
	assert r.status == 'FAIL'
}

// ---------- check_numeric -------------------------------------------------

fn test_check_numeric_all_good_pass() {
	r := check_numeric(Config{ max_turns: 32, compact_threshold: 0.6, max_retries_per_step: 10 })
	assert r.status == 'PASS'
}

fn test_check_numeric_max_turns_zero_fail() {
	r := check_numeric(Config{ max_turns: 0, compact_threshold: 0.6, max_retries_per_step: 10 })
	assert r.status == 'FAIL'
}

fn test_check_numeric_compact_threshold_oob_fail() {
	r := check_numeric(Config{ max_turns: 32, compact_threshold: 1.5, max_retries_per_step: 10 })
	assert r.status == 'FAIL'
	r2 := check_numeric(Config{ max_turns: 32, compact_threshold: 0.0, max_retries_per_step: 10 })
	assert r2.status == 'FAIL'
}

fn test_check_numeric_retries_negative_fail() {
	r := check_numeric(Config{ max_turns: 32, compact_threshold: 0.6, max_retries_per_step: -1 })
	assert r.status == 'FAIL'
}

// ---------- all-pass scenario ---------------------------------------------

fn test_doctor_all_pass() {
	builtin := ['bash', 'write_file', 'read_file', 'edit_file']
	cfg := Config{
		provider: 'openai-compat'
		api_base: 'https://api.openai.com'
		api_key: 'sk-test'
		model: 'kimi-k2'
		max_turns: 32
		compact_threshold: 0.6
		max_retries_per_step: 10
		risky_tools: ['bash']
		permission_rules: [PermissionRule{ decision: 'allow', pattern: 'Tool(read_file)' }]
	}
	assert check_provider(cfg).status == 'PASS'
	assert check_model(cfg).status == 'PASS'
	assert check_api_base(cfg).status == 'PASS'
	assert check_api_key(cfg).status == 'PASS'
	assert check_risky_tools(cfg.risky_tools, builtin).status == 'PASS'
	assert check_permission_rules(cfg.permission_rules).status == 'PASS'
	assert check_numeric(cfg).status == 'PASS'
}
