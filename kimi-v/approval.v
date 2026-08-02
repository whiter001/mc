// approval.v — risky-tool permission flow.
//
// For self-use we want a minimal but real approval flow: bash / write_file /
// edit_file / web_fetch need a y/n prompt before they run. Read-only tools
// (read_file, glob, grep) are auto-allowed.
//
// The flow:
//   1. Agent loop hits a risky tool call.
//   2. It sends an ApprovalRequest on approval_ch.
//   3. TUI receives, renders a modal, captures y/n.
//   4. TUI sends an ApprovalDecision back on decision_ch.
//   5. Agent loop unblocks and either runs the tool or skips it.
//
// The agent loop is single-threaded (it's a goroutine but the run() method
// is sequential), so a blocking receive on decision_ch is safe. The TUI's
// render loop polls approval_ch alongside its other channels.

module main

// ApprovalRequest is sent by the agent when it wants to call a risky tool.
pub struct ApprovalRequest {
pub:
	id        u64    // monotonic, matches the response
	tool_name string
	args      string // raw JSON the model emitted
}

// ApprovalDecision is sent by the TUI after the user answers the modal.
pub struct ApprovalDecision {
pub:
	id         u64
	approved   bool
	// `remember` marks "always allow for the rest of the session": the
	// TUI sets it when the user presses 'a' in the approval modal. The
	// agent then adds the tool to its own approved_tools list (same-turn
	// effect), and the TUI persists the choice to <config_dir>/approved_tools
	// so future sessions load it at startup.
	remember   bool
}

// default_risky_tools is the hardcoded list of tools that always require
// approval. Configurable via `risky_tools` in config.toml /
// KIMI_RISKY_TOOLS env.
pub const default_risky_tools = ['bash', 'write_file', 'edit_file', 'web_fetch']

// sensitive_patterns is a small per-tool deny-list of argument patterns
// that should ALWAYS re-prompt, even after the user said "always allow
// this tool for the rest of the session". Catches the obvious foot-guns:
//
//   - bash: rm -rf, sudo, > overwrite, mkfs, dd, chmod 777, curl|sh
//   - write_file / edit_file: writing to known sensitive paths
//     (/etc/*, ~/.ssh/*, ~/.aws/*, /usr/*) — sandbox also blocks these
//     but defence in depth
//
// Self-use, so this is hand-curated. The match is plain substring (no
// regex) to keep `is_sensitive` cheap and avoid pulling in V's regex
// module from a hot path.
pub const sensitive_patterns = {
	'bash': [
		'rm -rf', 'rm -fr', 'rm -R', 'rm -r ', ':(){:|:&};:', 'mkfs',
		'dd if=', 'dd of=', 'chmod 777', 'chmod -R 777', '> /etc/', '> /usr/',
		'> ~/.ssh/', '> ~/.aws/', 'curl ', 'wget ', '| sh', '| bash',
		'sudo ', 'su -',
	]
	'write_file': ['/etc/', '/usr/', '~/.ssh/', '~/.aws/', '/private/etc/',
		'/System/']
	'edit_file':  ['/etc/', '/usr/', '~/.ssh/', '~/.aws/', '/private/etc/',
		'/System/']
	'web_fetch':  [] // web_fetch is already gated by URL; no extra deny
}

// is_sensitive returns true if the args for `tool_name` contain any
// pattern from the deny-list. Substring match (not regex) — false
// positives are acceptable (user gets one extra prompt) but false
// negatives are not (would silently allow a foot-gun).
pub fn is_sensitive(tool_name string, args string) bool {
	patterns := sensitive_patterns[tool_name] or { return false }
	for p in patterns {
		if p.len == 0 {
			continue
		}
		if args.contains(p) {
			return true
		}
	}
	return false
}

// needs_approval returns true if the named tool requires user confirmation
// before running. The agent loop calls this on every tool call; safe tools
// (read_file, glob, grep) return false and skip the modal entirely.
pub fn needs_approval(tool_name string, risky []string) bool {
	for r in risky {
		if r == tool_name {
			return true
		}
	}
	return false
}

// should_skip_approval returns true if the tool call can run without a
// prompt because the user previously chose "always allow" for the rest
// of the session AND the args don't trip the sensitive-pattern deny list.
//
// `approved` is the session-scoped list of tool names the user has
// remembered (config.approved_tools). `args` is the raw JSON the model
// emitted — we scan it as a flat string since sensitive_patterns are
// substring-based.
pub fn should_skip_approval(tool_name string, args string, approved []string) bool {
	// Sensitive args always re-prompt, even for approved tools.
	if is_sensitive(tool_name, args) {
		return false
	}
	for a in approved {
		if a == tool_name {
			return true
		}
	}
	return false
}

// next_request_id returns a monotonic id. Callers should keep the counter
// in their own `mut` field; this helper exists for testability and returns
// the new value (the caller assigns).
pub fn next_request_id(prev u64) u64 {
	return prev + 1
}
