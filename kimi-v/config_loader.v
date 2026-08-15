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

// Config holds all user-configurable settings for the agent.
pub struct Config {
pub mut:
	// ---- Provider ----
	provider string = 'openai-compat' // 'openai-compat' (default) | 'anthropic' | 'openai-responses'
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
	// Retries per agent step on transient provider errors (HTTP 429 / 5xx /
	// connection failures). Parity with kimi-code's
	// `[loop_control] max_retries_per_step`. Overridable via config.toml or
	// the KIMI_LOOP_MAX_RETRIES_PER_STEP env var.
	max_retries_per_step int = 10

	// ---- Compaction ----
	// Model context window (tokens) and the fraction of it above which the
	// agent triggers compaction. Populated from config.toml; the agent
	// defaults (128k / 0.6, see compaction.v) are used when unset.
	context_window    int = default_context_window
	compact_threshold f32 = default_compact_threshold

	// ---- Permissions ----
	// Names of tools that always require user approval before running.
	// If empty, falls back to `default_risky_tools` from approval.v.
	// Populated from config.toml (`risky_tools = [...]`) and the
	// `KIMI_RISKY_TOOLS` env var (comma-separated).
	risky_tools []string
	// Names of tools the user has chosen "always allow" for. Combines
	// with `risky_tools`: a tool is gated if it's in `risky_tools` AND
	// not in `approved_tools` (and not matching a sensitive pattern).
	// Loaded from `<config_dir>/approved_tools` at startup and persisted
	// when the user presses 'a' in the approval modal.
	approved_tools []string
	// Permission rules from config.toml `[[permission.rules]]`. Each
	// entry pairs a decision (allow | deny | ask) with a `Tool(glob)`
	// pattern. Evaluated before the built-in risky-tools logic: deny
	// always wins, allow short-circuits the modal, ask forces it.
	permission_rules []PermissionRule
	// YOLO mode: skip approval entirely. Equivalent to "every tool is
	// in approved_tools" but stronger — also bypasses the modal UI.
	// Toggled at runtime via `/yolo` slash. Sensitive patterns are
	// still honoured (rm -rf, sudo, /etc/* still re-prompt) so the
	// deny-list provides a backstop against the most obvious foot-guns
	// even in yolo mode. Initial value from `--yolo` CLI flag or
	// `KIMI_YOLO=1` env var.
	yolo bool

	// Output format for `-p` mode. "text" (default) prints plain
	// stdout; "stream-json" emits one JSON object per line (JSONL) so
	// scripts / CI can parse the transcript. The CLI flag --output-format
	// is the only legitimate source for this field.
	output_format string

	// ---- Hooks ----
	// Lifecycle hooks (parity with kimi-code's [[hooks]]). Each entry is a
	// HookDef; populated from config.toml. Empty means "no hooks".
	hooks []HookDef

	// ---- MCP servers ----
	// External Model Context Protocol servers to connect at startup
	// (parity with kimi-code's [[mcp]]). Each entry is an McpServerConfig;
	// populated from config.toml. Empty means "no MCP servers".
	mcp_servers []McpServerConfig

	// ---- Web search ----
	// Backend provider for the web_search tool (parity with kimi-code's
	// MoonshotWebSearchProvider). 'duckduckgo' (default) is key-free and
	// scrapes the HTML endpoint; 'moonshot' calls the hosted search API and
	// needs an api_key. Populated from the [web_search] table and the
	// KIMI_WEB_SEARCH_* env vars.
	web_search WebSearchConfig

	// ---- Misc ----
	cwd string
}

// WebSearchConfig configures the web_search tool's backend provider.
pub struct WebSearchConfig {
pub mut:
	// 'duckduckgo' (default) | 'moonshot'. Unknown values are rejected
	// with a warning and fall back to 'duckduckgo' (fail-open).
	provider string = 'duckduckgo'
	// Endpoint for the 'moonshot' provider (POST, JSON body).
	base_url string = 'https://api.moonshot.cn/v1/search'
	// Bearer key for the 'moonshot' provider. When empty, the tool falls
	// back to the main provider api_key.
	api_key string
}

// default_config returns the built-in default configuration.
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

	// 5. Provider-specific fallbacks (e.g. ANTHROPIC_API_KEY for anthropic)
	apply_provider_fallbacks(mut cfg)

	// 6. OAuth credentials: if no api_key was configured anywhere, inject a
	// saved OAuth access token (refreshing it when expired).
	resolve_oauth_credentials(mut cfg)!

	cfg.cwd = cwd
	return cfg
}

// apply_provider_fallbacks fills in provider-specific defaults after all
// normal config sources (toml, KIMI_*, CLI) have been merged. Currently only
// the Anthropic provider needs this: when it is selected and no api_key /
// api_base was set anywhere, fall back to the standard ANTHROPIC_API_KEY /
// ANTHROPIC_BASE_URL environment variables and the official Anthropic
// endpoint (the generic defaults point at OpenAI).
fn apply_provider_fallbacks(mut cfg Config) {
	if cfg.provider != 'anthropic' {
		return
	}
	if cfg.api_key.len == 0 {
		cfg.api_key = os.getenv('ANTHROPIC_API_KEY')
	}
	if cfg.api_base.len == 0 || cfg.api_base == 'https://api.openai.com' {
		base := os.getenv('ANTHROPIC_BASE_URL')
		cfg.api_base = if base.len > 0 { base } else { 'https://api.anthropic.com' }
	}
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
	// [loop_control] nested table (parity with kimi-code). vlib/toml's
	// value() supports dotted keys.
	vl := doc.value('loop_control.max_retries_per_step')
	if vl !is toml.Null { cfg.max_retries_per_step = vl.int() }
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

	// Permission rules: parse [[permission.rules]] array-of-tables. Each
	// entry has decision (allow|deny|ask, required), pattern (`Tool(glob)`
	// or bare tool name, required), reason (string, optional). Malformed
	// entries are skipped with a warning — fail-open, a typo must never
	// lock the user out or crash the config load.
	vp := doc.value('permission.rules')
	if vp !is toml.Null {
		pr_arr := vp.array()
		mut rules := []PermissionRule{cap: pr_arr.len}
		for item in pr_arr {
			decision := item.value('decision').string()
			pattern := item.value('pattern').string()
			if decision.len == 0 || pattern.len == 0 {
				eprintln('warning: skipping [[permission.rules]] entry without decision+pattern')
				continue
			}
			if decision != 'allow' && decision != 'deny' && decision != 'ask' {
				eprintln('warning: skipping [[permission.rules]] entry with unknown decision "${decision}"')
				continue
			}
			if !permission_pattern_valid(pattern) {
				eprintln('warning: skipping [[permission.rules]] entry with invalid pattern "${pattern}"')
				continue
			}
			rules << PermissionRule{
				decision: decision
				pattern:  pattern
				reason:   item.value('reason').string()
			}
		}
		cfg.permission_rules = rules
	}

	// Hooks: parse [[hooks]] array-of-tables. Each entry has event
	// (string), matcher? (regex), command (string), timeout? (int),
	// cwd? (string). Unknown events are skipped with a warning.
	vh := doc.value('hooks')
	if vh !is toml.Null {
		hooks_arr := vh.array()
		mut hooks := []HookDef{cap: hooks_arr.len}
		for item in hooks_arr {
			ev := item.value('event').string()
			cmd := item.value('command').string()
			if ev.len == 0 || cmd.len == 0 {
				eprintln('warning: skipping [[hooks]] entry without event+command')
				continue
			}
			et := hook_event_from_name(ev)
			if et == none {
				eprintln('warning: skipping [[hooks]] entry with unknown event "${ev}"')
				continue
			}
			matcher := item.value('matcher').string()
			timeout := item.value('timeout').int()
			hcwd := item.value('cwd').string()
			event_val := et or { HookEventType.notification }
			hooks << HookDef{
				event:   event_val
				matcher: matcher
				command: cmd
				timeout: timeout
				cwd:     hcwd
			}
		}
		cfg.hooks = hooks
	}

	// MCP servers: parse [[mcp]] array-of-tables. Each entry has name
	// (string, required), command? (string), args? (array of string),
	// url? (string), required? (bool), and headers? (table of string→string).
	// Exactly one of command/url must be set; validation happens at connect
	// time. Unknown or malformed entries are skipped with a warning.
	vm := doc.value('mcp')
	if vm !is toml.Null {
		mcp_arr := vm.array()
		mut servers := []McpServerConfig{cap: mcp_arr.len}
		for item in mcp_arr {
			name_val := item.value('name')
			if name_val is toml.Null {
				eprintln('warning: skipping [[mcp]] entry without name')
				continue
			}
			raw_name := name_val.string()
			cmd_val := item.value('command')
			cmd := if cmd_val is toml.Null { '' } else { cmd_val.string() }
			mut args := []string{}
			if cmd.len > 0 {
				args_val := item.value('args')
				if args_val !is toml.Null {
					for a in args_val.array() {
						s := a.string()
						if s.len > 0 {
							args << s
						}
					}
				}
			}
			url_val := item.value('url')
			url_str := if url_val is toml.Null { '' } else { url_val.string() }
			req := item.value('required')
			required := req !is toml.Null && req.bool()
			mut headers := map[string]string{}
			hdr := item.value('headers')
			if hdr !is toml.Null {
				for hk, hv in hdr.as_map() {
					headers[hk] = hv.string()
				}
			}
			if cmd.len == 0 && url_str.len == 0 {
				eprintln('warning: skipping [[mcp]] "${raw_name}" with neither command nor url')
				continue
			}
			servers << McpServerConfig{
				name:     raw_name
				command:  cmd
				args:     args
				url:      url_str
				required: required
				headers:  headers
			}
		}
		cfg.mcp_servers = servers
	}

	// Web search: [web_search] nested table. Unknown provider values are
	// rejected with a warning and fall back to the default (fail-open), so
	// a typo can never break the tool.
	wsp := doc.value('web_search.provider')
	if wsp !is toml.Null { cfg.web_search.provider = normalize_web_search_provider(wsp.string()) }
	wsb := doc.value('web_search.base_url')
	if wsb !is toml.Null { cfg.web_search.base_url = wsb.string() }
	wsk := doc.value('web_search.api_key')
	if wsk !is toml.Null { cfg.web_search.api_key = wsk.string() }
}

// normalize_web_search_provider maps a configured web_search provider onto
// the supported set. Anything unknown logs a warning and falls back to the
// key-free default 'duckduckgo' — fail-open, matching the rest of the
// loader.
fn normalize_web_search_provider(raw string) string {
	if raw == 'duckduckgo' || raw == 'moonshot' {
		return raw
	}
	eprintln('warning: unknown web_search provider "${raw}"; falling back to "duckduckgo"')
	return 'duckduckgo'
}

// apply_env overrides cfg with values from KIMI_* environment variables.
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
	v8 := os.getenv('KIMI_YOLO')
	if v8.len > 0 && v8 in ['1', 'true', 'yes', 'on'] {
		cfg.yolo = true
	}
	v9 := os.getenv('KIMI_LOOP_MAX_RETRIES_PER_STEP')
	if v9.len > 0 && v9.int() > 0 {
		cfg.max_retries_per_step = v9.int()
	}
	// Web search provider overrides (same validation as the toml path).
	ws1 := os.getenv('KIMI_WEB_SEARCH_PROVIDER')
	if ws1.len > 0 { cfg.web_search.provider = normalize_web_search_provider(ws1) }
	ws2 := os.getenv('KIMI_WEB_SEARCH_BASE_URL')
	if ws2.len > 0 { cfg.web_search.base_url = ws2 }
	ws3 := os.getenv('KIMI_WEB_SEARCH_API_KEY')
	if ws3.len > 0 { cfg.web_search.api_key = ws3 }
}

// apply_cli copies non-empty fields from cli into cfg.
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

// validate checks that the configuration has the minimum required fields.
pub fn (c Config) validate() ! {
	if c.provider != 'openai-compat' && c.provider != 'anthropic' && c.provider != 'openai-responses' {
		return error('unknown provider "${c.provider}"; supported providers: openai-compat, anthropic, openai-responses')
	}
	if c.api_key.len == 0 {
		return error('api_key is not set; pass --api-key, set KIMI_API_KEY, run `kimi login`, or run `kimi login --oauth`')
	}
	if c.model.len == 0 {
		return error('model is not set; pass --model or set KIMI_MODEL')
	}
}

// Suppress unused import warning if util isn't directly used here.
// (removed: const unused = ...)
