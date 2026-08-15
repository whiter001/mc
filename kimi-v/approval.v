// approval.v — risky-tool permission flow.
//
// For self-use we want a minimal but real approval flow: bash / write_file /
// edit_file / web_fetch need a y/n prompt before they run. Read-only tools
// (read_file, glob, grep) are auto-allowed.
//
// The decision of whether a call runs, asks, or is denied lives in one pure
// function, evaluate_approval, which walks an ordered policy chain (mirroring
// kimi-code's permissionPolicyService):
//
//   1.  user-configured deny rule   → deny (reason fed back to the model)
//   2.  plan-mode guard             → deny (write_file/edit_file may only
//                                      target the plan file; cron / task-stop
//                                      tools are banned while planning)
//   3.  sensitive pattern           → ask (always re-prompt, even under allow
//                                      rules / yolo / session-approval)
//   4.  user-configured ask rule    → ask
//   5.  plan mode + risky tool      → ask (session always-allow is disabled
//                                      while planning; yolo is exempt)
//   6.  user-configured allow rule  → run
//   7.  yolo                        → run
//   8.  session always-allow        → run
//   9.  built-in risky list         → ask
//   10. default                     → run
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
//   - bash: rm -rf, sudo, > overwrite, mkfs, dd, chmod 777, curl|sh,
//     git write operations (commit/push/reset/merge/… — substring match,
//     so a few false positives are acceptable; read-only git commands like
//     status/log/diff/clone stay free)
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
		'git commit', 'git push', 'git reset', 'git rebase', 'git merge',
		'git pull', 'git checkout --', 'git restore', 'git clean',
		'git branch -D', 'git branch -d', 'git tag -d', 'git stash drop',
		'git stash clear', 'git cherry-pick', 'git revert', 'git am ',
		'git update-ref', 'git filter-branch', 'git reflog expire',
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

// ApprovalAction is the outcome of evaluating the approval policy chain.
pub enum ApprovalAction {
	run  // execute the tool without a prompt
	ask  // show the approval modal before running
	deny // reject the call outright; the reason is fed back to the model
}

// ApprovalVerdict is the result of running the full policy chain. `reason`
// carries the deny message for .deny verdicts (permission-rule reason or
// plan-mode guard text); it's empty for .run / .ask.
pub struct ApprovalVerdict {
pub:
	action ApprovalAction
	reason string
}

// ApprovalContext bundles the agent state the policy chain needs, so
// evaluate_approval stays a pure function (no Agent dependency) and is
// trivially testable. The agent loop fills it from its own fields.
pub struct ApprovalContext {
pub:
	risky_tools      []string
	approved_tools   []string
	permission_rules []PermissionRule
	yolo             bool
	plan_active      bool
	plan_file_path   string
}

// evaluate_approval runs the ordered policy chain (see the file header) and
// returns the verdict. The first step that matches decides; every earlier
// step short-circuits the ones below it.
pub fn evaluate_approval(tool_name string, args string, ctx ApprovalContext) ApprovalVerdict {
	// 1. User-configured deny rules always win — no modal, no bypass.
	verdict, rule_reason := evaluate_permission(ctx.permission_rules, tool_name, args)
	if verdict == .deny {
		msg := if rule_reason.trim_space().len > 0 {
			'[denied by permission rule: ${rule_reason}]'
		} else {
			'[denied by permission rule]'
		}
		return ApprovalVerdict{
			action: .deny
			reason: msg
		}
	}

	// 2. Plan-mode guard. While plan mode is active, write_file / edit_file
	// may ONLY target the current plan file; cron / task-stop tools are
	// banned outright (the model must ExitPlanMode first). bash is NOT
	// blocked here — it follows the normal approval path below.
	if ctx.plan_active {
		if tool_name == 'write_file' || tool_name == 'edit_file' {
			target := tool_write_path(args)
			plan_path := ctx.plan_file_path
			if plan_path.len == 0 || target != plan_path {
				msg := if plan_path.len > 0 {
					'Plan mode is active. You may only write to the current plan file: ${plan_path}. Call ExitPlanMode to exit plan mode before editing other files.'
				} else {
					'Plan mode is active. No plan file is available in this mode. Call ExitPlanMode to exit plan mode before editing files.'
				}
				return ApprovalVerdict{
					action: .deny
					reason: msg
				}
			}
		} else if tool_name == 'CronCreate' || tool_name == 'CronDelete' || tool_name == 'TaskStop' {
			return ApprovalVerdict{
				action: .deny
				reason: 'Plan mode is active. ${tool_name} is not allowed in plan mode. Call ExitPlanMode to exit plan mode first.'
			}
		}
	}

	// 3. Sensitive patterns always re-prompt. No allow rule, yolo flag, or
	// session approval can skip the modal for a foot-gun (rm -rf, sudo,
	// /etc/* writes, git writes, …).
	if is_sensitive(tool_name, args) {
		return ApprovalVerdict{
			action: .ask
		}
	}

	// 4. User-configured ask rules force the modal, even for tools that
	// aren't otherwise risky.
	if verdict == .ask {
		return ApprovalVerdict{
			action: .ask
		}
	}

	// 5. Plan mode re-arms the modal for risky tools: session always-allow
	// is deliberately disabled while planning (bash etc. must re-prompt).
	// yolo is exempt and still skips approval in plan mode.
	if ctx.plan_active && !ctx.yolo && needs_approval(tool_name, ctx.risky_tools) {
		return ApprovalVerdict{
			action: .ask
		}
	}

	// 6. User-configured allow rules short-circuit the modal.
	if verdict == .allow {
		return ApprovalVerdict{
			action: .run
		}
	}

	// 7. yolo mode skips approval for everything.
	if ctx.yolo {
		return ApprovalVerdict{
			action: .run
		}
	}

	// 8. Session always-allow (approved_tools) skips the modal — unless the
	// args tripped a sensitive pattern (caught at step 3).
	if should_skip_approval(tool_name, args, ctx.approved_tools) {
		return ApprovalVerdict{
			action: .run
		}
	}

	// 9. Built-in risky list → ask.
	if needs_approval(tool_name, ctx.risky_tools) {
		return ApprovalVerdict{
			action: .ask
		}
	}

	// 10. Default: run.
	return ApprovalVerdict{
		action: .run
	}
}

// next_request_id returns a monotonic id. Callers should keep the counter
// in their own `mut` field; this helper exists for testability and returns
// the new value (the caller assigns).
pub fn next_request_id(prev u64) u64 {
	return prev + 1
}
