// config_loader_test.v — unit tests for config parsing.
//
// We don't exercise the full `load_config` end-to-end (it touches the
// real filesystem and env). Instead we drive `apply_toml` / `apply_env`
// directly against in-memory TOML, which is what the runtime merging
// does anyway.
module main

import os

// ---------- apply_toml: risky_tools ---------------------------------------

fn test_apply_toml_risky_tools_array() {
	mut cfg := default_config()
	apply_toml(mut cfg, 'risky_tools = ["bash", "write_file"]')
	assert cfg.risky_tools == ['bash', 'write_file']
}

fn test_apply_toml_risky_tools_missing_keeps_empty() {
	mut cfg := default_config()
	apply_toml(mut cfg, 'provider = "openai-compat"')
	assert cfg.risky_tools.len == 0
}

fn test_apply_toml_risky_tools_empty_array_keeps_empty() {
	// Empty array → empty slice (not "use default"; defaults are applied
	// at the call sites, not here). Lets the user disable approval
	// entirely by writing `risky_tools = []`.
	mut cfg := default_config()
	apply_toml(mut cfg, 'risky_tools = []')
	assert cfg.risky_tools.len == 0
}

fn test_apply_toml_other_fields_still_work() {
	// Sanity: adding risky_tools parsing didn't break the existing fields.
	mut cfg := default_config()
	apply_toml(mut cfg, 'provider = "openai-compat"\n' + 'api_base = "https://x.example/v1"\n' +
		'model = "kimi-k2"\n' + 'risky_tools = ["bash"]\n')
	assert cfg.provider == 'openai-compat'
	assert cfg.api_base == 'https://x.example/v1'
	assert cfg.model == 'kimi-k2'
	assert cfg.risky_tools == ['bash']
}

// ---------- apply_env: KIMI_RISKY_TOOLS -----------------------------------

fn test_apply_env_risky_tools_csv() {
	// KIMI_RISKY_TOOLS is the runtime escape hatch (e.g. for CI / one-off
	// experiments). Comma-separated; whitespace trimmed; empties dropped.
	os.setenv('KIMI_RISKY_TOOLS', 'bash , write_file, ,edit_file', true)
	defer { os.setenv('KIMI_RISKY_TOOLS', '', true) }
	mut cfg := default_config()
	apply_env(mut cfg)
	assert cfg.risky_tools == ['bash', 'write_file', 'edit_file']
}

fn test_apply_env_risky_tools_unset_keeps_empty() {
	os.setenv('KIMI_RISKY_TOOLS', '', true)
	mut cfg := default_config()
	apply_env(mut cfg)
	assert cfg.risky_tools.len == 0
}

// ---------- [loop_control] max_retries_per_step ----------------------------

fn test_apply_toml_loop_control_max_retries() {
	mut cfg := default_config()
	apply_toml(mut cfg, '[loop_control]\nmax_retries_per_step = 5\n')
	assert cfg.max_retries_per_step == 5
}

fn test_apply_toml_loop_control_missing_keeps_default() {
	mut cfg := default_config()
	apply_toml(mut cfg, 'provider = "openai-compat"')
	assert cfg.max_retries_per_step == 3
}

fn test_apply_env_max_retries_override() {
	os.setenv('KIMI_LOOP_MAX_RETRIES_PER_STEP', '7', true)
	defer { os.setenv('KIMI_LOOP_MAX_RETRIES_PER_STEP', '', true) }
	mut cfg := default_config()
	apply_env(mut cfg)
	assert cfg.max_retries_per_step == 7
}

fn test_apply_env_max_retries_invalid_keeps_default() {
	os.setenv('KIMI_LOOP_MAX_RETRIES_PER_STEP', 'not-a-number', true)
	defer { os.setenv('KIMI_LOOP_MAX_RETRIES_PER_STEP', '', true) }
	mut cfg := default_config()
	apply_env(mut cfg)
	assert cfg.max_retries_per_step == 3
}

// ---------- [permission.rules] ----------------------------------------------

fn test_apply_toml_permission_rules_array() {
	mut cfg := default_config()
	apply_toml(mut cfg, '[[permission.rules]]\n' +
		'decision = "deny"\n' +
		'pattern = "Bash(rm -rf *)"\n' +
		'reason = "protect against rm -rf"\n\n' +
		'[[permission.rules]]\n' +
		'decision = "allow"\n' +
		'pattern = "Write(/tmp/**)"\n\n' +
		'[[permission.rules]]\n' +
		'decision = "ask"\n' +
		'pattern = "Bash(pip install *)"\n')
	assert cfg.permission_rules.len == 3
	assert cfg.permission_rules[0].decision == 'deny'
	assert cfg.permission_rules[0].pattern == 'Bash(rm -rf *)'
	assert cfg.permission_rules[0].reason == 'protect against rm -rf'
	assert cfg.permission_rules[1].decision == 'allow'
	assert cfg.permission_rules[1].pattern == 'Write(/tmp/**)'
	assert cfg.permission_rules[2].decision == 'ask'
	assert cfg.permission_rules[2].pattern == 'Bash(pip install *)'
}

fn test_apply_toml_permission_rules_missing_keeps_empty() {
	mut cfg := default_config()
	apply_toml(mut cfg, 'provider = "openai-compat"')
	assert cfg.permission_rules.len == 0
}

fn test_apply_toml_permission_rules_bad_entries_skipped() {
	// Bad decision and bad pattern are skipped with a warning (fail-open):
	// a typo must never lock the user out or crash the config load.
	mut cfg := default_config()
	apply_toml(mut cfg, '[[permission.rules]]\n' +
		'decision = "maybe"\n' +
		'pattern = "Bash(*)"\n\n' +
		'[[permission.rules]]\n' +
		'decision = "deny"\n' +
		'pattern = "Bash("\n\n' +
		'[[permission.rules]]\n' +
		'decision = "deny"\n' +
		'pattern = "Bash(rm -rf *)"\n')
	assert cfg.permission_rules.len == 1
	assert cfg.permission_rules[0].decision == 'deny'
	assert cfg.permission_rules[0].pattern == 'Bash(rm -rf *)'
}
