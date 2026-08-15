// doctor.v — offline configuration validation (parity with kimi-code's
// `kimi doctor`).
//
// Runs a battery of local checks against the resolved configuration: TOML
// parseability, provider/model/api_key sanity, URL validity, risky-tools
// names, permission-rule syntax, and numeric ranges. No network calls are
// made — doctor never probes the provider.
//
// Exit code: any FAIL → 1, otherwise 0. WARN never fails the run.

module main

import os
import toml

// DoctorCheck is one line of doctor output.
pub struct DoctorCheck {
pub:
	name    string // short label, e.g. 'provider valid'
	status  string // 'PASS' | 'WARN' | 'FAIL'
	detail  string // what we found
	advice  string // one-line fix hint (only shown on FAIL)
}

// toml_parse_ok returns whether `raw` is valid TOML. Pure helper so the
// parse check is unit-testable without touching the filesystem.
pub fn toml_parse_ok(raw string) (bool, string) {
	toml.parse_text(raw) or {
		return false, err.msg()
	}
	return true, ''
}

// check_provider verifies the provider is one of the three supported values.
pub fn check_provider(c Config) DoctorCheck {
	if c.provider in ['openai-compat', 'anthropic', 'openai-responses'] {
		return DoctorCheck{
			name:   'provider valid'
			status: 'PASS'
			detail: 'provider = ${c.provider}'
		}
	}
	return DoctorCheck{
		name:   'provider valid'
		status: 'FAIL'
		detail: 'unknown provider "${c.provider}"'
		advice: 'set provider to one of: openai-compat, anthropic, openai-responses'
	}
}

// check_model verifies a non-empty model is configured.
pub fn check_model(c Config) DoctorCheck {
	if c.model.len > 0 {
		return DoctorCheck{
			name:   'model set'
			status: 'PASS'
			detail: 'model = ${c.model}'
		}
	}
	return DoctorCheck{
		name:   'model set'
		status: 'FAIL'
		detail: 'model is empty'
		advice: 'set model in config.toml or via KIMI_MODEL'
	}
}

// check_api_base verifies api_base is a valid http(s) URL. Plain http:// is
// accepted but flagged as insecure (WARN); anything else fails.
pub fn check_api_base(c Config) DoctorCheck {
	if c.api_base.len == 0 {
		return DoctorCheck{
			name:   'api_base valid'
			status: 'FAIL'
			detail: 'api_base is empty'
			advice: 'set api_base to an http(s) URL'
		}
	}
	if c.api_base.starts_with('https://') {
		return DoctorCheck{
			name:   'api_base valid'
			status: 'PASS'
			detail: 'api_base = ${c.api_base}'
		}
	}
	if c.api_base.starts_with('http://') {
		return DoctorCheck{
			name:   'api_base valid'
			status: 'WARN'
			detail: 'api_base = ${c.api_base} (insecure)'
			advice: 'use https:// when possible'
		}
	}
	return DoctorCheck{
		name:   'api_base valid'
		status: 'FAIL'
		detail: 'api_base "${c.api_base}" is not an http(s) URL'
		advice: 'use a URL starting with http:// or https://'
	}
}

// check_api_key reports only presence (the value is never printed). For the
// anthropic provider, load_config() already folded in the ANTHROPIC_API_KEY
// env fallback, so a non-empty api_key here means it is set one way or another.
pub fn check_api_key(c Config) DoctorCheck {
	if c.api_key.len > 0 {
		return DoctorCheck{
			name:   'api_key set'
			status: 'PASS'
			detail: 'api_key is set (value hidden)'
		}
	}
	return DoctorCheck{
		name:   'api_key set'
		status: 'FAIL'
		detail: 'api_key is not set'
		advice: 'set api_key in config.toml or KIMI_API_KEY; for provider=anthropic also set ANTHROPIC_API_KEY; or run `kimi login`'
	}
}

// check_risky_tools verifies every risky_tools name is a registered built-in
// tool (so a typo cannot silently no-op). `builtin` is the registry name set.
pub fn check_risky_tools(risky []string, builtin []string) DoctorCheck {
	if risky.len == 0 {
		return DoctorCheck{
			name:   'risky_tools valid'
			status: 'PASS'
			detail: 'no risky_tools configured (defaults apply)'
		}
	}
	mut unknown := []string{}
	for t in risky {
		if t !in builtin {
			unknown << t
		}
	}
	if unknown.len > 0 {
		return DoctorCheck{
			name:   'risky_tools valid'
			status: 'FAIL'
			detail: 'unknown tool(s): ${unknown.join(', ')}'
			advice: 'risky_tools must name built-in tools; check for typos'
		}
	}
	return DoctorCheck{
		name:   'risky_tools valid'
		status: 'PASS'
		detail: '${risky.len} risky tool(s) all recognised'
	}
}

// check_permission_rules verifies each [[permission.rules]] entry has a valid
// decision and a syntactically valid Tool(glob) pattern.
pub fn check_permission_rules(rules []PermissionRule) DoctorCheck {
	if rules.len == 0 {
		return DoctorCheck{
			name:   'permission rules valid'
			status: 'PASS'
			detail: 'no permission rules configured'
		}
	}
	mut bad := []string{}
	for r in rules {
		if r.decision !in ['allow', 'deny', 'ask'] {
			bad << 'decision "${r.decision}" is invalid'
		}
		if !permission_pattern_valid(r.pattern) {
			bad << 'pattern "${r.pattern}" is invalid'
		}
	}
	if bad.len > 0 {
		return DoctorCheck{
			name:   'permission rules valid'
			status: 'FAIL'
			detail: bad.join('; ')
			advice: 'each rule needs decision (allow|deny|ask) and a valid Tool(glob) pattern'
		}
	}
	return DoctorCheck{
		name:   'permission rules valid'
		status: 'PASS'
		detail: '${rules.len} rule(s) parse OK'
	}
}

// check_numeric verifies the configured numeric ranges:
//   max_turns > 0, compact_threshold ∈ (0,1], max_retries_per_step >= 0
pub fn check_numeric(c Config) DoctorCheck {
	mut issues := []string{}
	if c.max_turns <= 0 {
		issues << 'max_turns must be > 0 (got ${c.max_turns})'
	}
	if !(c.compact_threshold > 0 && c.compact_threshold <= 1) {
		issues << 'compact_threshold must be in (0,1] (got ${c.compact_threshold})'
	}
	if c.max_retries_per_step < 0 {
		issues << 'max_retries_per_step must be >= 0 (got ${c.max_retries_per_step})'
	}
	if issues.len > 0 {
		return DoctorCheck{
			name:   'numeric ranges'
			status: 'FAIL'
			detail: issues.join('; ')
			advice: 'fix the values in config.toml ([loop_control] / compaction settings)'
		}
	}
	return DoctorCheck{
		name:   'numeric ranges'
		status: 'PASS'
		detail: 'max_turns=${c.max_turns} compact_threshold=${c.compact_threshold} max_retries_per_step=${c.max_retries_per_step}'
	}
}

// check_config_toml verifies the on-disk config files parse as TOML. A missing
// config.toml is not a failure (built-in defaults are used); only a present
// but unparseable file fails.
fn check_config_toml() DoctorCheck {
	mut paths := []string{}
	user_path := os.join_path(config_dir(), 'config.toml')
	if os.exists(user_path) {
		paths << user_path
	}
	proj := find_project_config(os.getwd())
	if proj != '' && proj !in paths {
		paths << proj
	}
	if paths.len == 0 {
		return DoctorCheck{
			name:   'config.toml parseable'
			status: 'PASS'
			detail: 'no config.toml found; using built-in defaults'
		}
	}
	mut bad := []string{}
	for p in paths {
		raw := os.read_file(p) or {
			bad << '${p}: cannot read file'
			continue
		}
		ok, msg := toml_parse_ok(raw)
		if !ok {
			bad << '${p}: ${msg}'
		}
	}
	if bad.len > 0 {
		return DoctorCheck{
			name:   'config.toml parseable'
			status: 'FAIL'
			detail: bad.join('\n  ')
			advice: 'fix the TOML syntax errors above so config.toml can be parsed'
		}
	}
	return DoctorCheck{
		name:   'config.toml parseable'
		status: 'PASS'
		detail: '${paths.len} config file(s) parsed OK'
	}
}

// run_doctor loads the configuration, runs every check, prints the report,
// and returns the process exit code (1 if any FAIL, else 0).
pub fn run_doctor() int {
	mut cfg := load_config(Config{}) or {
		println('FAIL  config load — ${err.msg()}')
		return 1
	}

	// Built-in tool names for the risky_tools check. We build a fresh
	// registry from a throwaway agent with NO MCP servers — doctor stays
	// offline: default_registry would otherwise eagerly connect every
	// configured MCP server (network + process spawns).
	mut probe := new_agent(OpenAICompatProvider{}, '')
	reg := default_registry(mut probe, cfg.cwd, [], cfg.web_search)
	builtin := reg.names()

	checks := [
		check_config_toml(),
		check_provider(cfg),
		check_model(cfg),
		check_api_base(cfg),
		check_api_key(cfg),
		check_risky_tools(cfg.risky_tools, builtin),
		check_permission_rules(cfg.permission_rules),
		check_numeric(cfg),
	]

	mut n_fail := 0
	mut n_warn := 0
	println('kimi doctor — offline configuration check')
	println('config dir: ${config_dir()}')
	println('')
	for c in checks {
		tag := if c.status == 'PASS' {
			'PASS'
		} else if c.status == 'WARN' {
			'WARN'
		} else {
			'FAIL'
		}
		println('${tag}  ${c.name} — ${c.detail}')
		if c.status == 'FAIL' {
			n_fail++
			if c.advice.len > 0 {
				println('        fix: ${c.advice}')
			}
		} else if c.status == 'WARN' {
			n_warn++
			if c.advice.len > 0 {
				println('        note: ${c.advice}')
			}
		}
	}
	println('')
	if n_fail > 0 {
		println('${n_fail} FAIL, ${n_warn} WARN — fix the above and re-run `kimi doctor`')
		return 1
	}
	if n_warn > 0 {
		println('${n_warn} WARN — configuration looks good (warnings are non-fatal)')
	} else {
		println('all checks passed — configuration looks good')
	}
	return 0
}
