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
