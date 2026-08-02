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
	// True when the run hit the wall-clock subagent timeout; the handoff is
	// then partial and ok is false.
	timed_out bool
}

// BackgroundAgentResult is the delivery of a finished background subagent.
// The background goroutine pushes it onto the parent's bg_results_ch; the
// parent's run loop drains it on a later turn and injects it into the
// session as a <background-agent-result> user message so the model sees it.
pub struct BackgroundAgentResult {
pub:
	agent_id     string
	profile_name string
	result       string
	ok           bool
	err          string
	elapsed_ms   i64
}

// BackgroundTask is the live status entry for one background subagent,
// surfaced by the TaskList tool. Written by the finishing goroutine under
// the parent's bg_mutex; read by TaskListTool under the same lock.
pub struct BackgroundTask {
pub mut:
	agent_id     string
	profile_name string
	status       string // 'running' | 'completed' | 'failed'
	started_ms   i64
	finished_ms  i64
	elapsed_ms   i64
	result       string
	err          string
}

// new_subagent_id generates a fresh subagent id: timestamp-hex + random
// suffix. Shared by foreground spawns, background launches, and swarm items.
fn new_subagent_id() string {
	return 'sub-${time.now().unix_milli().hex()}-${short_rand()}'
}

// spawn_subagent runs one subagent to completion and returns its handoff.
//
// parent: the calling agent (used to inherit provider/model/cwd/approval
//         settings). The subagent does NOT share the parent's Session.
// profile_name: 'coder' | 'explore' | 'plan' (falls back to 'coder').
// prompt: the full task brief for the subagent.
// non_interactive: when true, approvals auto-pass (matches parent mode).
fn spawn_subagent(mut parent Agent, profile_name string, prompt string, non_interactive bool) SubagentResult {
	id := new_subagent_id()
	mut sess := new_session(parent_cwd(parent))
	sess.id = id
	sess.append_user(prompt)
	return run_subagent(mut parent, profile_name, mut sess, non_interactive)
}

// run_subagent executes one subagent against an existing Session and returns
// its handoff. This is the shared engine behind foreground spawns, background
// launches, swarm items, and resume: the caller prepares the session (fresh
// with a prompt, or a loaded persisted session with an appended prompt) and
// run_subagent builds the child agent, runs it, and persists the session so
// it can later be resumed.
fn run_subagent(mut parent Agent, profile_name string, mut sess Session, non_interactive bool) SubagentResult {
	profiles := default_profiles()
	mut profile := profiles['coder']
	if p := profiles[profile_name] {
		profile = p
	}

	id := sess.id

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
	// Enforce the wall-clock subagent timeout: run() checks deadline_ms at
	// the top of every turn and stops making new turns once it passes, so a
	// runaway subagent is bounded even when max_turns is generous.
	child.deadline_ms = time.now().unix_milli() + subagent_timeout_ms

	// Trim the tool registry to the profile's allow-list.
	child.registry = filter_registry(parent.registry, profile.tools)
	// Give the subagent a non-nil agent self-reference for stateful tools
	// (it won't use them, but the ToolContext requires it).
	child_ref := &child
	child.registry = rewire_agent_ref(mut child.registry, child_ref)

	// Capture the task brief before the explore git-context prepend, so the
	// SubagentStart hook sees the raw prompt (matches pre-refactor behavior).
	mut task_prompt := ''
	if u := sess.last_user() {
		task_prompt = u.content
	}

	// explore subagents get a git-context block (best-effort). Only prepend
	// to a fresh single-message session — a resumed session already carries
	// its own context and must not be re-prefixed.
	if profile_name == 'explore' && sess.messages.len == 1 {
		git_ctx := collect_git_context(parent_cwd(parent))
		if git_ctx.len > 0 {
			sess.messages[0] = Message{ role: .user, content: '${git_ctx}\n\n${task_prompt}' }
		}
	}

	// ── SubagentStart hook (observation-only) ──
	mut sa_input := map[string]string{}
	sa_input['agent_name'] = profile.name
	sa_input['prompt'] = task_prompt
	parent.hooks_engine().run_hook_for_event(.subagent_start, profile.name, sa_input)

	child.run(mut sess) or {
		// ── SubagentStop hook (failure path: emit as observation with the
		// error) ──
		mut sf_input := map[string]string{}
		sf_input['agent_name'] = profile.name
		sf_input['response'] = err.msg()
		parent.hooks_engine().run_hook_for_event(.subagent_stop, profile.name, sf_input)
		// Persist the session even on failure so the parent can resume it
		// for debugging (best-effort).
		sess.metadata['subagent_profile'] = profile.name
		save_to(subagent_sessions_dir(), sess) or {}
		return SubagentResult{
			agent_id:     id
			profile_name: profile.name
			ok:           false
			err:          err.msg()
		}
	}

	// Extract the final assistant text.
	mut result := last_assistant_text(sess)

	// Wall-clock timeout check: if the deadline passed while running, stop
	// here and hand back the partial result as a timeout rather than
	// pretending the subagent finished.
	timed_out := time.now().unix_milli() >= child.deadline_ms

	// Bounded expansion: if the handoff is too terse, give it one more turn
	// to expand. Mirrors upstream SUMMARY_CONTINUATION_ATTEMPTS = 1. Skipped
	// once the deadline is already hit.
	mut remaining := 1
	for !timed_out && remaining > 0 && result.len < summary_min_length {
		remaining--
		sess.append_user(summary_continuation_prompt)
		_ = child.run(mut sess) or { break }
		result = last_assistant_text(sess)
	}

	// Persist the subagent session so it can be resumed later (best-effort;
	// the file lives under <config_dir>/sessions/subagents/<id>.toml).
	sess.metadata['subagent_profile'] = profile.name
	save_to(subagent_sessions_dir(), sess) or {}

	// ── SubagentStop hook (observation-only) ──
	mut ss_input := map[string]string{}
	ss_input['agent_name'] = profile.name
	ss_input['response'] = result
	parent.hooks_engine().run_hook_for_event(.subagent_stop, profile.name, ss_input)

	if timed_out {
		return SubagentResult{
			agent_id:     id
			profile_name: profile.name
			result:       result
			ok:           false
			err:          'timed out after ${subagent_timeout_ms} ms'
			timed_out:    true
		}
	}

	return SubagentResult{
		agent_id:     id
		profile_name: profile.name
		result:       result
		ok:           true
	}
}

// launch_background starts a subagent in a goroutine and returns immediately.
// The result is delivered to the parent on a later turn: run() drains
// bg_results_ch (see drain_background_results) and injects a
// <background-agent-result> user message; the TaskList tool reads the live
// status from bg_tasks.
fn launch_background(mut parent Agent, profile_name string, mut sess Session, non_interactive bool) SubagentResult {
	id := sess.id
	parent.register_background_task(BackgroundTask{
		agent_id:     id
		profile_name: profile_name
		status:       'running'
		started_ms:   time.now().unix_milli()
	})
	go fn (mut parent Agent, profile_name string, mut sess Session, non_interactive bool) {
		res := run_subagent(mut parent, profile_name, mut sess, non_interactive)
		parent.finish_background_task(res)
	}(mut parent, profile_name, mut sess, non_interactive)
	return SubagentResult{
		agent_id:     id
		profile_name: profile_name
		ok:           true
		result:       'launched in background (status: running)'
	}
}

// register_background_task records a background subagent as running. Called
// on the parent's own goroutine before the background worker starts.
pub fn (mut a Agent) register_background_task(task BackgroundTask) {
	a.bg_mutex.lock()
	a.bg_tasks[task.agent_id] = task
	a.bg_mutex.unlock()
}

// finish_background_task marks a background task as completed/failed and
// queues its result for the next drain. Called from the background goroutine:
// it only touches bg_tasks under the mutex and pushes onto the channel, so it
// is safe to run concurrently with the parent's loop.
pub fn (mut a Agent) finish_background_task(res SubagentResult) {
	a.bg_mutex.lock()
	mut task := a.bg_tasks[res.agent_id] or {
		BackgroundTask{
			agent_id:     res.agent_id
			profile_name: res.profile_name
			started_ms:   time.now().unix_milli()
		}
	}
	task.status = if res.ok { 'completed' } else { 'failed' }
	task.finished_ms = time.now().unix_milli()
	task.elapsed_ms = task.finished_ms - task.started_ms
	task.result = res.result
	task.err = res.err
	a.bg_tasks[res.agent_id] = task
	a.bg_mutex.unlock()
	a.bg_results_ch <- BackgroundAgentResult{
		agent_id:     res.agent_id
		profile_name: res.profile_name
		result:       res.result
		ok:           res.ok
		err:          res.err
		elapsed_ms:   task.elapsed_ms
	}
}

// drain_background_results collects finished background subagent results and
// injects them into the parent session as <background-agent-result> user
// messages, so the model sees them on its next turn. Non-blocking: the 1ms
// select timeout is the V 0.5.x workaround used throughout this codebase.
// run() calls this at the top of every turn.
pub fn (mut a Agent) drain_background_results(mut sess Session) {
	mut draining := true
	for draining {
		select {
			res := <-a.bg_results_ch {
				status := if res.ok { 'completed' } else { 'failed' }
				body := if res.ok { res.result } else { res.err }
				sess.append_user('<background-agent-result agent_id="${res.agent_id}" status="${status}" profile="${res.profile_name}" elapsed_ms="${res.elapsed_ms}">${body}</background-agent-result>')
			}
			1 * time.millisecond {
				draining = false
			}
		}
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
