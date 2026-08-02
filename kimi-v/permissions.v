// permissions.v — config-driven permission rule engine.
//
// On top of the built-in risky-tools list (approval.v), users can define
// explicit allow / deny / ask rules in config.toml:
//
//   [[permission.rules]]
//   decision = "deny"
//   pattern  = "Bash(rm -rf *)"
//   reason   = "protect against accidental rm -rf"
//
//   [[permission.rules]]
//   decision = "allow"
//   pattern  = "Write_file(/tmp/**)"
//
// Pattern syntax: `Tool(glob)` where glob uses the same match_glob rules
// as tools.v (`*` matches any run of chars, including `/`). A bare tool
// name (`Bash`) is shorthand for `Bash(*)`. Tool names are matched
// case-insensitively against the registry tool name (write_file, edit_file,
// web_fetch, bash — the config examples write `Bash` / `Write_file`, the
// registry names them lowercase).
//
// Evaluation (evaluate_permission): deny rules are scanned first and
// always win; then allow; then ask. A verdict of .none means "no rule
// matched" and the agent falls back to the built-in risky-tools logic.
//
// This file also owns on-disk persistence of the "always allow" list
// (`<config_dir>/approved_tools`, one tool name per line, override via
// KIMI_APPROVED_TOOLS_FILE). The TUI writes it when the user presses
// 'a' in the approval modal and loads it at startup; the agent refreshes
// its copy at the start of every turn.

module main

import os
import json

// PermissionVerdict is the outcome of evaluating the configured rules
// against a tool call.
pub enum PermissionVerdict {
	none  // no rule matched — caller falls back to built-in logic
	allow // an allow rule matched
	deny  // a deny rule matched (always wins)
	ask   // an ask rule matched — force the approval modal
}

// PermissionRule is one entry from `[[permission.rules]]` in config.toml.
// `decision` is allow | deny | ask; `pattern` is `Tool(glob)` (a bare
// tool name means `Tool(*)`); `reason` is optional text shown to the
// model when the rule fires.
pub struct PermissionRule {
pub:
	decision string // allow | deny | ask
	pattern  string // `Tool(glob)` or bare tool name
	reason   string // optional, surfaced to the model on a deny
}

// parse_permission_pattern splits a `Tool(glob)` pattern into the tool
// name and the glob. A bare tool name (no parens) means "every call of
// that tool" (glob `*`). Returns an error for malformed patterns (empty
// tool name, missing closing paren, empty glob).
pub fn parse_permission_pattern(pattern string) !(string, string) {
	p := pattern.trim_space()
	open := p.index('(') or { -1 }
	if open < 0 {
		if p.len == 0 {
			return error('permission pattern is empty')
		}
		return p, '*'
	}
	tool := p[..open].trim_space()
	if tool.len == 0 {
		return error('permission pattern "${p}" has no tool name before "("')
	}
	inner := p[open + 1..]
	if !inner.ends_with(')') {
		return error('permission pattern "${p}" is missing the closing ")"')
	}
	glob := inner[..inner.len - 1].trim_space()
	if glob.len == 0 {
		return error('permission pattern "${p}" has an empty glob')
	}
	return tool, glob
}

// permission_pattern_valid reports whether a pattern parses. The config
// loader uses it to skip malformed entries with a warning instead of
// failing the whole config.
pub fn permission_pattern_valid(pattern string) bool {
	_, _ := parse_permission_pattern(pattern) or { return false }
	return true
}

// permission_match_arg selects the string a rule's glob is matched
// against for a given tool call: the raw command for bash, the `path`
// argument for write_file / edit_file, the `url` argument for
// web_fetch, and the raw JSON args for everything else.
pub fn permission_match_arg(tool_name string, args string) string {
	match tool_name {
		'bash' { return args }
		'write_file', 'edit_file' { return tool_write_path(args) }
		'web_fetch' {
			m := json.decode(map[string]string, args) or { return args }
			return m['url'] or { args }
		}
		else { return args }
	}
}

// rule_matches reports whether a rule's pattern matches the tool call.
// `lower_tool` must already be lowercased; args are the raw JSON the
// model emitted.
fn rule_matches(r PermissionRule, lower_tool string, args string) bool {
	rt, glob := parse_permission_pattern(r.pattern) or { return false }
	if rt.to_lower() != lower_tool {
		return false
	}
	return match_glob(permission_match_arg(lower_tool, args), glob)
}

// evaluate_permission evaluates the configured rules against a tool call
// and returns the verdict plus the reason of the first matching rule
// ('' when the rule has no reason). Deny rules are scanned first and
// always win; within one decision, the first matching rule wins. Returns
// (.none, '') when no rule matches.
pub fn evaluate_permission(rules []PermissionRule, tool_name string, args string) (PermissionVerdict, string) {
	lower := tool_name.to_lower()
	// Pass 1: deny always wins — even in yolo / non-interactive sessions.
	for r in rules {
		if r.decision != 'deny' {
			continue
		}
		if rule_matches(r, lower, args) {
			return PermissionVerdict.deny, r.reason
		}
	}
	// Pass 2: allow.
	for r in rules {
		if r.decision != 'allow' {
			continue
		}
		if rule_matches(r, lower, args) {
			return PermissionVerdict.allow, r.reason
		}
	}
	// Pass 3: ask.
	for r in rules {
		if r.decision != 'ask' {
			continue
		}
		if rule_matches(r, lower, args) {
			return PermissionVerdict.ask, r.reason
		}
	}
	return PermissionVerdict.none, ''
}

// approved_tools_path returns the absolute path to the approved-tools
// file. Honors the KIMI_APPROVED_TOOLS_FILE override; otherwise falls
// back to `<config_dir>/approved_tools`.
pub fn approved_tools_path() string {
	override := os.getenv('KIMI_APPROVED_TOOLS_FILE')
	if override.len > 0 {
		return override
	}
	return os.join_path(config_dir(), 'approved_tools')
}

// load_approved_tools reads the on-disk approved-tools file (one tool
// name per line) and returns the list. A missing file is a normal
// first-run condition, so it yields an empty list (like load_history).
pub fn load_approved_tools() []string {
	path := approved_tools_path()
	if !os.exists(path) {
		return []string{}
	}
	data := os.read_file(path) or { return []string{} }
	mut out := []string{}
	for line in data.split_into_lines() {
		t := line.trim_space()
		if t.len > 0 {
			out << t
		}
	}
	return out
}

// save_approved_tools writes the given tool names to disk, one per
// line. Blank entries are dropped. Ensures the containing directory
// exists first (a fresh install may not have a config dir yet).
pub fn save_approved_tools(tools []string) ! {
	mut lines := []string{}
	for t in tools {
		tt := t.trim_space()
		if tt.len > 0 {
			lines << tt
		}
	}
	dir := os.dir(approved_tools_path())
	if dir.len > 0 {
		ensure_dir(dir)!
	}
	os.write_file(approved_tools_path(), lines.join('\n'))!
}

// append_approved_tool adds a tool name to the on-disk approved-tools
// file (dedup, order-preserving). No-op when already present.
pub fn append_approved_tool(tool string) ! {
	t := tool.trim_space()
	if t.len == 0 {
		return
	}
	mut tools := load_approved_tools()
	if t !in tools {
		tools << t
		save_approved_tools(tools)!
	}
}

// clear_approved_tools deletes the on-disk approved-tools file (if
// any). A missing file is not an error — nothing to clear.
pub fn clear_approved_tools() ! {
	path := approved_tools_path()
	if os.exists(path) {
		os.rm(path)!
	}
}
