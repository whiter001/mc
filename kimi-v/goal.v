// goal.v — Goal state, budgets, and the goal-driver helpers.
//
// Mirrors kimi-code's Goal system: the model creates a goal (CreateGoal),
// and the agent loop keeps the run going until the model adjudicates the
// goal complete/blocked (UpdateGoal) or a configured budget
// (SetGoalBudget) is reached. State lives on the Agent (the per-session
// singleton), same as the todo list — the Tool interface is stateless.
//
// Wall-clock accounting only counts *active* time: leaving `.active`
// folds the in-progress span into `wall_ms`; entering `.active` anchors
// `resumed_at_ms`. The pure functions below take an explicit `now_ms`
// so they're trivially testable.
module main

import encoding.base64
import json2
import time

// GoalStatus is the lifecycle state of the current goal.
pub enum GoalStatus {
	active
	paused
	blocked
}

// GoalState is the full state of the session goal, stored on the Agent.
pub struct GoalState {
pub mut:
	objective  string
	criterion  string // completion criterion, may be empty
	status     GoalStatus
	turns_used int
	tokens_used int // output tokens only
	wall_ms i64 // accumulated active wall-clock ms
	resumed_at_ms i64 // epoch ms when status last became active; 0 when not active
	budget_turns int // 0 = unset
	budget_tokens int // 0 = unset
	budget_wall_ms i64 // 0 = unset
	terminal_reason string
}

// live_wall_ms returns the effective wall-clock usage at `now_ms`: the
// accumulated `wall_ms` plus the in-progress span while the goal is
// active.
pub fn live_wall_ms(g GoalState, now_ms i64) i64 {
	if g.status == .active && g.resumed_at_ms > 0 {
		delta := now_ms - g.resumed_at_ms
		if delta > 0 {
			return g.wall_ms + delta
		}
	}
	return g.wall_ms
}

// pause folds the in-progress active span into `wall_ms` and clears the
// anchor. The caller sets the target status (paused/blocked) itself.
pub fn pause(g GoalState, now_ms i64) GoalState {
	mut out := g
	if out.status == .active {
		out.wall_ms = live_wall_ms(g, now_ms)
		out.resumed_at_ms = 0
	}
	return out
}

// resume marks the goal active and anchors `resumed_at_ms` at `now_ms`.
pub fn resume(g GoalState, now_ms i64) GoalState {
	mut out := g
	out.status = .active
	out.resumed_at_ms = now_ms
	return out
}

// over_budget reports whether any configured budget has been reached
// (used >= limit) at `now_ms`. Unset budgets (0) never trigger.
pub fn over_budget(g GoalState, now_ms i64) bool {
	if g.budget_turns > 0 && g.turns_used >= g.budget_turns {
		return true
	}
	if g.budget_tokens > 0 && g.tokens_used >= g.budget_tokens {
		return true
	}
	if g.budget_wall_ms > 0 && live_wall_ms(g, now_ms) >= g.budget_wall_ms {
		return true
	}
	return false
}

// fmt_wall_ms renders a millisecond duration compactly (e.g. "350ms",
// "42s", "3m5s", "2h10m") for goal progress reports.
pub fn fmt_wall_ms(ms i64) string {
	if ms < 1000 {
		return '${ms}ms'
	}
	total_s := ms / 1000
	if total_s < 60 {
		return '${total_s}s'
	}
	m := total_s / 60
	s := total_s % 60
	if m < 60 {
		return '${m}m${s}s'
	}
	return '${m / 60}h${m % 60}m'
}

// budget_report returns a human-readable used/limit summary of the goal's
// progress and budgets (e.g. "3/10 turns, 1200/5000 tokens, 12s elapsed").
// Used by GetGoal and by the goal-continuation reminder. Unset budgets
// show only the used amount.
pub fn budget_report(g GoalState, now_ms i64) string {
	mut parts := []string{}
	if g.budget_turns > 0 {
		parts << '${g.turns_used}/${g.budget_turns} turns'
	} else {
		parts << '${g.turns_used} turns'
	}
	if g.budget_tokens > 0 {
		parts << '${g.tokens_used}/${g.budget_tokens} tokens'
	} else {
		parts << '${g.tokens_used} tokens'
	}
	wall := live_wall_ms(g, now_ms)
	if g.budget_wall_ms > 0 {
		parts << '${fmt_wall_ms(wall)}/${fmt_wall_ms(g.budget_wall_ms)} elapsed'
	} else {
		parts << '${fmt_wall_ms(wall)} elapsed'
	}
	return parts.join(', ')
}

// goal_continuation_prompt builds the synthetic user message the agent
// loop appends when a turn ends while a goal is still active — the
// goal driver that keeps the run going until the model adjudicates.
pub fn goal_continuation_prompt(g GoalState, now_ms i64) string {
	mut lines := []string{}
	lines << 'Continue working toward the active goal. Objective: ${g.objective}'
	if g.criterion.trim_space().len > 0 {
		lines << 'Completion criterion: ${g.criterion}'
	}
	mut progress := 'Progress so far: ${g.turns_used} turns, ${g.tokens_used} tokens, ${fmt_wall_ms(live_wall_ms(g,
		now_ms))} elapsed.'
	if g.budget_turns > 0 || g.budget_tokens > 0 || g.budget_wall_ms > 0 {
		progress += ' Budgets: ${budget_report(g, now_ms)}.'
	}
	lines << progress
	lines << 'Before marking the goal complete, verify the objective is actually satisfied with concrete evidence. Report blocked only after the same blocking condition repeats for at least 3 consecutive goal turns, or immediately if the objective is impossible/unsafe/contradictory. If work remains, keep going with tools; do not ask the user.'
	return lines.join('\n')
}

// GoalSnapshot is the model-facing view of a GoalState. It deliberately
// omits the internal wall-clock anchor (`resumed_at_ms`).
struct GoalSnapshot {
	objective        string
	criterion        string
	status           string
	turns_used       int
	tokens_used      int
	wall_ms          i64
	budget_turns     int
	budget_tokens    int
	budget_wall_ms   i64
	terminal_reason  string
}

// goal_snapshot_json renders the model-facing JSON snapshot of a goal.
pub fn goal_snapshot_json(g GoalState, now_ms i64) string {
	return json2.encode(GoalSnapshot{
		objective:       g.objective
		criterion:       g.criterion
		status:          g.status.str()
		turns_used:      g.turns_used
		tokens_used:     g.tokens_used
		wall_ms:         live_wall_ms(g, now_ms)
		budget_turns:    g.budget_turns
		budget_tokens:   g.budget_tokens
		budget_wall_ms:  g.budget_wall_ms
		terminal_reason: g.terminal_reason
	})
}

// =============================================================================
// Persistence (session metadata channel)
// =============================================================================
//
// The goal rides along in `sess.metadata['goal']` as base64-encoded JSON.
// The session TOML writer emits metadata as `"key" = "value"` without
// escaping (see session_store.v), so base64 keeps the payload safe.

// GoalStateJson is the JSON-serializable form of GoalState (status as a
// plain string so the persisted form survives enum refactors).
struct GoalStateJson {
	objective        string
	criterion        string
	status           string
	turns_used       int
	tokens_used      int
	wall_ms          i64
	resumed_at_ms    i64
	budget_turns     int
	budget_tokens    int
	budget_wall_ms   i64
	terminal_reason  string
}

// goal_to_json serializes the full goal state (including the wall-clock
// anchor) to JSON. The anchor is persisted as-is and re-based on restore.
pub fn goal_to_json(g GoalState) string {
	return json2.encode(GoalStateJson{
		objective:       g.objective
		criterion:       g.criterion
		status:          g.status.str()
		turns_used:      g.turns_used
		tokens_used:     g.tokens_used
		wall_ms:         g.wall_ms
		resumed_at_ms:   g.resumed_at_ms
		budget_turns:    g.budget_turns
		budget_tokens:   g.budget_tokens
		budget_wall_ms:  g.budget_wall_ms
		terminal_reason: g.terminal_reason
	})
}

// goal_status_from_str parses a persisted status string.
fn goal_status_from_str(s string) ?GoalStatus {
	return match s {
		'active' { GoalStatus.active }
		'paused' { GoalStatus.paused }
		'blocked' { GoalStatus.blocked }
		else { none }
	}
}

// goal_from_json deserializes a goal from goal_to_json output. Returns
// none on malformed input or an unknown status (a bad payload must never
// crash session load).
pub fn goal_from_json(s string) ?GoalState {
	if s.len == 0 {
		return none
	}
	j := json2.decode[GoalStateJson](s) or { return none }
	status := goal_status_from_str(j.status) or { return none }
	return GoalState{
		objective:       j.objective
		criterion:       j.criterion
		status:          status
		turns_used:      j.turns_used
		tokens_used:     j.tokens_used
		wall_ms:         j.wall_ms
		resumed_at_ms:   j.resumed_at_ms
		budget_turns:    j.budget_turns
		budget_tokens:   j.budget_tokens
		budget_wall_ms:  j.budget_wall_ms
		terminal_reason: j.terminal_reason
	}
}

// stash_goal_metadata writes the agent's goal into the session metadata
// before save(); with no goal it removes the key so a stale goal never
// leaks into a later resume.
pub fn stash_goal_metadata(mut sess Session, goal ?GoalState) {
	if g := goal {
		sess.metadata['goal'] = base64.encode(goal_to_json(g).bytes())
	} else {
		sess.metadata.delete('goal')
	}
}

// restore_goal_from_metadata loads a persisted goal from the session
// metadata onto the agent. A goal that was active when persisted is
// downgraded to paused (wall_ms kept, anchor cleared): the agent wasn't
// running while the session was on disk, so that idle time must not
// count against a wall-clock budget. No metadata → no-op.
pub fn restore_goal_from_metadata(mut a Agent, sess Session) {
	raw := sess.metadata['goal'] or { return }
	decoded := base64.decode(raw)
	mut g := goal_from_json(decoded.bytestr()) or { return }
	if g.status == .active {
		g.status = .paused
		g.terminal_reason = 'Paused after agent resume'
		g.resumed_at_ms = 0
	}
	a.goal = g
}

// =============================================================================
// TUI badge + detail (status channel payload)
// =============================================================================

// goal_badge_summary renders the header badge content, e.g.
// "GOAL active · 3 turns · 12s" (elapsed only while active).
pub fn goal_badge_summary(g GoalState, now_ms i64) string {
	mut s := 'GOAL ${g.status.str()} · ${g.turns_used} turns'
	if g.status == .active {
		s += ' · ${fmt_wall_ms(live_wall_ms(g, now_ms))}'
	}
	return s
}

// goal_detail_text renders the multi-line snapshot shown by `/goal`.
pub fn goal_detail_text(g GoalState, now_ms i64) string {
	mut lines := []string{}
	lines << 'goal: ${g.objective}'
	if g.criterion.len > 0 {
		lines << 'criterion: ${g.criterion}'
	}
	lines << 'status: ${g.status.str()}'
	lines << 'progress: ${budget_report(g, now_ms)}'
	if g.terminal_reason.len > 0 {
		lines << 'reason: ${g.terminal_reason}'
	}
	return lines.join('\n')
}

// emit_goal_status pushes the current goal badge + detail to the
// on_goal_change callback (wired by the TUI runner). Empty strings when
// there is no goal; no-op when the callback isn't wired.
fn (a Agent) emit_goal_status() {
	if cb := a.on_goal_change {
		if g := a.goal {
			now := time.now().unix_milli()
			cb(goal_badge_summary(g, now), goal_detail_text(g, now))
		} else {
			cb('', '')
		}
	}
}

// ── Agent-side goal helpers (used by the loop driver and the tools) ────

// goal_is_active reports whether the agent currently has an active goal.
fn (a Agent) goal_is_active() bool {
	if g := a.goal {
		return g.status == .active
	}
	return false
}

// goal_over_budget reports whether the current goal (if any) has reached
// one of its configured budgets.
fn (a Agent) goal_over_budget() bool {
	if g := a.goal {
		return over_budget(g, time.now().unix_milli())
	}
	return false
}

// add_goal_tokens books `n` output tokens against the current goal.
fn (mut a Agent) add_goal_tokens(n int) {
	if g := a.goal {
		mut g2 := g
		g2.tokens_used += n
		a.goal = g2
	}
}

// bump_goal_turn counts one completed goal turn against the current goal.
fn (mut a Agent) bump_goal_turn() {
	if g := a.goal {
		mut g2 := g
		g2.turns_used += 1
		a.goal = g2
	}
}

// block_goal_over_budget marks the current goal blocked because one of
// its configured budgets was reached, folding in any active wall time.
fn (mut a Agent) block_goal_over_budget() {
	if g := a.goal {
		mut g2 := pause(g, time.now().unix_milli())
		g2.status = .blocked
		g2.terminal_reason = 'A configured budget was reached'
		a.goal = g2
	}
}

// pause_goal_after_interrupt pauses an active goal after a user
// cancellation so idle time isn't counted against a wall-clock budget.
fn (mut a Agent) pause_goal_after_interrupt() {
	if g := a.goal {
		if g.status == .active {
			mut g2 := pause(g, time.now().unix_milli())
			g2.status = .paused
			g2.terminal_reason = 'Paused after interruption'
			a.goal = g2
		}
	}
}

// current_goal_continuation_prompt renders the continuation prompt for
// the agent's active goal ('' when there is none).
fn (a Agent) current_goal_continuation_prompt() string {
	if g := a.goal {
		return goal_continuation_prompt(g, time.now().unix_milli())
	}
	return ''
}
