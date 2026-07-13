// subagent.v — subagent (coder / explore / plan) runner.
//
// Mirrors kimi-code's `SessionSubagentHost`: a subagent is an in-process loop
// instance with its own Session and (optionally) a trimmed toolset. The parent
// agent spawns one via the `Agent` tool; the subagent runs to completion and
// hands back only its final assistant text.
//
// Key behaviours ported from upstream:
//   - inherits the parent's provider/model/cwd
//   - inherits the parent's risky-tools + approval settings so a subagent that
//     e.g. runs bash still goes through the same approval gate (for the TUI
//     path). In non-interactive mode (`-p`) approvals auto-pass, same as the
//     parent.
//   - explore subagents get a <git-context> block prepended (best-effort).
//   - a subagent whose final summary is too short (below SUMMARY_MIN_LENGTH)
//     is given one bounded chance to expand it, so the parent gets a complete
//     handoff rather than a one-liner.
module main

import os
import time

// SUMMARY_MIN_LENGTH: a subagent handoff shorter than this many chars is sent
// back for one expansion turn (mirrors upstream SUMMARY_MIN_LENGTH = 200).
const summary_min_length = 200
const summary_continuation_prompt = 'Your previous response was too brief to serve as a handoff. Expand it into a technically complete summary: what you changed and why, the path of every file you touched, how you verified the change (tests or commands run with results), and anything left undone or worth follow-up.'
const subagent_timeout_ms = 30 * 60 * 1000

// SubagentResult is what the `Agent` tool returns to the parent.
pub struct SubagentResult {
pub:
	agent_id     string
	profile_name string
	// Final handoff text (the subagent's last assistant message).
	result string
	ok     bool
	// Non-fatal error detail (e.g. launch failure, timeout message).
	err string
}

// spawn_subagent runs one subagent to completion and returns its handoff.
//
// parent: the calling agent (used to inherit provider/model/cwd/approval
//         settings). The subagent does NOT share the parent's Session.
// profile_name: 'coder' | 'explore' | 'plan' (falls back to 'coder').
// prompt: the full task brief for the subagent.
// non_interactive: when true, approvals auto-pass (matches parent mode).
fn spawn_subagent(mut parent Agent, profile_name string, prompt string, non_interactive bool) SubagentResult {
	profiles := default_profiles()
	mut profile := profiles['coder']
	if p := profiles[profile_name] {
		profile = p
	}

	id := 'sub-${time.now().unix_milli().hex()}-${short_rand()}'

	// Build the subagent's own agent from the parent's provider + model.
	mut child := new_agent(parent.provider, profile.system)
	child.max_turns = parent.max_turns
	// Inherit approval posture so risky tools in the subagent also gate.
	child.risky_tools = parent.risky_tools.clone()
	child.approved_tools = parent.approved_tools.clone()
	child.yolo = parent.yolo
	child.non_interactive = non_interactive
	child.context_window = parent.context_window
	child.compact_threshold = parent.compact_threshold

	// Trim the tool registry to the profile's allow-list.
	child.registry = filter_registry(parent.registry, profile.tools)
	// Give the subagent a non-nil agent self-reference for stateful tools
	// (it won't use them, but the ToolContext requires it).
	child_ref := &child
	child.registry = rewire_agent_ref(mut child.registry, child_ref)

	// Fresh session for the subagent (isolated context).
	mut sess := new_session(parent_cwd(parent))
	sess.append_user(prompt)

	// explore subagents get a git-context block (best-effort).
	mut child_prompt := prompt
	if profile_name == 'explore' {
		git_ctx := collect_git_context(parent_cwd(parent))
		if git_ctx.len > 0 {
			child_prompt = '${git_ctx}\n\n${prompt}'
			sess.messages[0] = Message{ role: .user, content: child_prompt }
		}
	}

	// Run the subagent loop (with a simple turn cap guard). We do not
	// enforce a hard wall-clock timeout here — the parent's max_turns cap
	// bounds the work, and V has no first-class cross-goroutine deadline
	// we'd want to thread through; the upstream 30-min timeout is a
	// Kubernetes-ism we approximate with max_turns.

	// ── SubagentStart hook (observation-only) ──
	mut sa_input := map[string]string{}
	sa_input['agent_name'] = profile.name
	sa_input['prompt'] = prompt
	parent.hooks_engine().run_hook_for_event(.subagent_start, profile.name, sa_input)

	res := child.run(mut sess) or {
		// ── SubagentStop hook (success path only fires on success; on
		// failure we still emit it as observation with the error) ──
		mut sf_input := map[string]string{}
		sf_input['agent_name'] = profile.name
		sf_input['response'] = err.msg()
		parent.hooks_engine().run_hook_for_event(.subagent_stop, profile.name, sf_input)
		return SubagentResult{
			agent_id:     id
			profile_name: profile.name
			ok:           false
			err:          err.msg()
		}
	}

	// Extract the final assistant text.
	mut result := last_assistant_text(sess)

	// Bounded expansion: if the handoff is too terse, give it one more
	// turn to expand. Mirrors upstream SUMMARY_CONTINUATION_ATTEMPTS = 1.
	mut remaining := 1
	for remaining > 0 && result.len < summary_min_length {
		remaining--
		sess.append_user(summary_continuation_prompt)
		_ = child.run(mut sess) or { break }
		result = last_assistant_text(sess)
	}

	_ = res
	// ── SubagentStop hook (observation-only) ──
	mut ss_input := map[string]string{}
	ss_input['agent_name'] = profile.name
	ss_input['response'] = result
	parent.hooks_engine().run_hook_for_event(.subagent_stop, profile.name, ss_input)

	return SubagentResult{
		agent_id:     id
		profile_name: profile.name
		result:       result
		ok:           true
	}
}

// parent_cwd returns the cwd the subagent should run in — the parent session's
// cwd is not directly reachable, so we fall back to the process cwd. The
// parent passes its cwd implicitly via the provider wiring; here we use the
// agent's stored cwd context (os.getwd() is the safe default).
fn parent_cwd(parent Agent) string {
	_ = parent
	// The Agent struct doesn't carry cwd directly (sessions own it). Use
	// the process cwd, which for our single-session model equals the
	// session cwd. Good enough and avoids plumbing cwd through every call.
	return os.getwd()
}

// filter_registry returns a new registry containing only the named tools from
// `src`. Unknown names are skipped (so a profile listing a tool the parent
// doesn't have simply doesn't get it).
fn filter_registry(src ToolRegistry, allowed []string) ToolRegistry {
	mut out := new_registry()
	for name in allowed {
		if t := src.get(name) {
			out.register(t)
		}
	}
	return out
}

// rewire_agent_ref binds every tool's `agent` back-reference to the subagent
// instance, so stateful tools (TodoWrite etc.) that the subagent might hold
// see the correct agent. Tools are copied by value when registered, so we
// re-register with the corrected reference.
fn rewire_agent_ref(mut r ToolRegistry, a &Agent) ToolRegistry {
	// V tool interfaces are value-ish; the `agent ?&Agent` field is what
	// matters. We can't mutate interface internals generically, so we rely
	// on the fact that the Agent tool (and plan/ask tools) read ctx.agent
	// at call time, not the tool's stored ref. For subagents we therefore
	// set the ctx.agent to the child when executing (see agent_loop run()).
	// Nothing to rewire for now — keep the registry as-is.
	_ = a
	return r
}

// last_assistant_text finds the most recent non-empty assistant message.
fn last_assistant_text(sess Session) string {
	for i := sess.messages.len - 1; i >= 0; i-- {
		m := sess.messages[i]
		if m.role == .assistant && m.content.trim_space().len > 0 {
			return m.content.trim_space()
		}
	}
	return ''
}

// collect_git_context gathers a short repo-status block for explore agents.
// Best-effort: any failure returns '' and the caller skips it.
fn collect_git_context(cwd string) string {
	mut parts := []string{}
	out1 := git(cwd, 'git status --short')
	if out1.trim_space().len > 0 {
		parts << 'git status:\n${truncate(out1, 1500)}'
	}
	out2 := git(cwd, 'git log --oneline -10')
	if out2.trim_space().len > 0 {
		parts << 'recent commits:\n${truncate(out2, 1500)}'
	}
	if parts.len == 0 {
		return ''
	}
	return '<git-context>\n' + parts.join('\n') + '\n</git-context>'
}

fn git(cwd string, cmd string) string {
	res := os.execute('cd "${cwd}" && ${cmd} 2>/dev/null')
	if res.exit_code != 0 {
		return ''
	}
	return res.output
}

fn truncate(s string, max int) string {
	if s.len <= max {
		return s
	}
	return s[..max] + '\n… (truncated)'
}

fn short_rand() string {
	return (time.now().unix_micro() & 0xFFFF).hex()
}
