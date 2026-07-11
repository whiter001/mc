// internal/config/loader.v
// Loads and merges configuration from multiple sources (lower precedence first):
//
//   defaults < user config (~/.config/kimi/config.toml) < project config
//   (<cwd>/.kimi/config.toml) < environment variables (KIMI_*) < CLI flags
//
// All knobs are exposed as fields on Config; merging is a plain field copy.
module main

import os
import toml

pub struct Config {
pub mut:
	// ---- Provider ----
	provider string = 'openai-compat' // 'openai-compat' (default) | future: 'anthropic'
	api_base string = 'https://api.openai.com'
	api_key  string
	model    string

	// ---- Agent ----
	system_prompt string

	// ---- Logging ----
	log_level string = 'info'

	// ---- Limits ----
	max_turns  int = 32
	max_tokens int = 4096

	// ---- Permissions ----
	// Names of tools that always require user approval before running.
	// If empty, falls back to `default_risky_tools` from approval.v.
	// Populated from config.toml (`risky_tools = [...]`) and the
	// `KIMI_RISKY_TOOLS` env var (comma-separated).
	risky_tools []string

	// ---- Misc ----
	cwd string
}

pub fn default_config() Config {
	return Config{
		api_base: 'https://api.openai.com'
		provider: 'openai-compat'
	}
}

// load builds a Config by layering all sources. CLI overrides win last.
pub fn load_config(cli_overrides Config) !Config {
	mut cfg := default_config()

	// 1. User config
	user_path := os.join_path(config_dir(), 'config.toml')
	if os.exists(user_path) {
		raw := os.read_file(user_path)!
		apply_toml(mut cfg, raw)
	}

	// 2. Project config (.kimi/config.toml in cwd or any ancestor)
	cwd := os.getwd()
	project_path := find_project_config(cwd)
	if project_path != '' {
		raw := os.read_file(project_path)!
		apply_toml(mut cfg, raw)
	}

	// 3. Environment variables
	apply_env(mut cfg)

	// 4. CLI overrides (only non-empty fields)
	apply_cli(mut cfg, cli_overrides)

	cfg.cwd = cwd
	return cfg
}

pub fn apply_toml(mut cfg Config, raw string) {
	// Parse the TOML document. `toml.parse_text` returns Doc; we use
	// `.value(key)` for each known field. Missing keys yield `Null` and
	// are skipped.
	doc := toml.parse_text(raw) or {
		eprintln('warning: failed to parse config toml: ${err.msg()}')
		return
	}
	v := doc.value('provider')
	if v !is toml.Null { cfg.provider = v.string() }
	v2 := doc.value('api_base')
	if v2 !is toml.Null { cfg.api_base = v2.string() }
	v3 := doc.value('api_key')
	if v3 !is toml.Null { cfg.api_key = v3.string() }
	v4 := doc.value('model')
	if v4 !is toml.Null { cfg.model = v4.string() }
	v5 := doc.value('system_prompt')
	if v5 !is toml.Null { cfg.system_prompt = v5.string() }
	v6 := doc.value('log_level')
	if v6 !is toml.Null { cfg.log_level = v6.string() }
	v7 := doc.value('max_turns')
	if v7 !is toml.Null { cfg.max_turns = v7.int() }
	v8 := doc.value('max_tokens')
	if v8 !is toml.Null { cfg.max_tokens = v8.int() }
	v9 := doc.value('risky_tools')
	if v9 !is toml.Null {
		// TOML arrays land as []toml.Any; coerce each element to a string.
		// Non-string elements (e.g. numbers) fall back to `.str()` so we
		// still produce something usable instead of silently dropping the
		// whole list.
		arr := v9.array()
		mut risky := []string{cap: arr.len}
		for item in arr {
			s := item.string()
			if s.len > 0 {
				risky << s
			}
		}
		cfg.risky_tools = risky
	}
}

pub fn apply_env(mut cfg Config) {
	v := os.getenv('KIMI_PROVIDER')
	if v.len > 0 { cfg.provider = v }
	v2 := os.getenv('KIMI_API_BASE')
	if v2.len > 0 { cfg.api_base = v2 }
	v3 := os.getenv('KIMI_API_KEY')
	if v3.len > 0 { cfg.api_key = v3 }
	v4 := os.getenv('KIMI_MODEL')
	if v4.len > 0 { cfg.model = v4 }
	v5 := os.getenv('KIMI_SYSTEM_PROMPT')
	if v5.len > 0 { cfg.system_prompt = v5 }
	v6 := os.getenv('KIMI_LOG_LEVEL')
	if v6.len > 0 { cfg.log_level = v6 }
	v7 := os.getenv('KIMI_RISKY_TOOLS')
	if v7.len > 0 {
		// Comma-separated; trim whitespace and drop empties.
		mut risky := []string{}
		for raw in v7.split(',') {
			s := raw.trim_space()
			if s.len > 0 {
				risky << s
			}
		}
		cfg.risky_tools = risky
	}
}

fn apply_cli(mut cfg Config, cli Config) {
	if cli.provider.len > 0 { cfg.provider = cli.provider }
	if cli.api_base.len > 0 { cfg.api_base = cli.api_base }
	if cli.api_key.len > 0 { cfg.api_key = cli.api_key }
	if cli.model.len > 0 { cfg.model = cli.model }
	if cli.system_prompt.len > 0 { cfg.system_prompt = cli.system_prompt }
	if cli.log_level.len > 0 { cfg.log_level = cli.log_level }
	if cli.max_turns > 0 { cfg.max_turns = cli.max_turns }
	if cli.max_tokens > 0 { cfg.max_tokens = cli.max_tokens }
}

// find_project_config walks up from `start` looking for `.kimi/config.toml`.
// Returns '' if not found.
fn find_project_config(start string) string {
	mut dir := start
	for {
		candidate := os.join_path(dir, '.kimi', 'config.toml')
		if os.exists(candidate) {
			return candidate
		}
		parent := os.dir(dir)
		if parent == dir || parent == '' {
			return ''
		}
		dir = parent
	}
	return ''
}

pub fn (c Config) validate() ! {
	if c.api_key.len == 0 {
		return error('api_key is not set; pass --api-key, set KIMI_API_KEY, or run `kimi login`')
	}
	if c.model.len == 0 {
		return error('model is not set; pass --model or set KIMI_MODEL')
	}
}

// Suppress unused import warning if util isn't directly used here.
// (removed: const unused = ...)
