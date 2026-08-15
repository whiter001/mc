// goal_test.v — tests for the Goal system: state/budget pure functions,
// the four Goal tools, and the goal driver in the agent loop.
module main

import time

// ---------- Scripted fake provider ----------------------------------------
//
// V's test runner compiles each _test.v file independently, so the fake
// providers in agent_test.v / compaction_test.v aren't visible here. This
// one is scripted: each chat() call pops the next event list.

struct GoalScript {
mut:
	idx   int
	calls [][]ChatEvent
}

struct GoalFakeProvider {
	name     string = 'fake'
	model    string = 'fake-model'
	api_base string = 'http://fake'
	api_key  string = 'fake-key'
	script   &GoalScript
}

fn (p GoalFakeProvider) chat(req ChatRequest, out chan ChatEvent, cancel_ch chan int) ! {
	mut s := p.script
	i := if s.idx < s.calls.len { s.idx } else { s.calls.len - 1 }
	s.idx++
	for ev in s.calls[i] {
		out <- ev
	}
	out <- ChatEvent{
		kind: .end_of_stream
	}
}

// goal_text_events scripts one plain-text response (no tool calls).
fn goal_text_events(text string, out_tokens int) []ChatEvent {
	return [
		ChatEvent{
			kind:    .delta
			content: text
		},
		ChatEvent{
			kind:          .finish
			reason:        .stop
			output_tokens: out_tokens
		},
	]
}

// goal_tool_call_events scripts one response carrying a single tool call.
fn goal_tool_call_events(id string, name string, args string, out_tokens int) []ChatEvent {
	return [
		ChatEvent{
			kind:      .tool_call
			id:        id
			name:      name
			arguments: args
		},
		ChatEvent{
			kind:          .finish
			reason:        .tool_calls
			output_tokens: out_tokens
		},
	]
}

// new_goal_test_agent builds an agent whose provider never gets called.
fn new_goal_test_agent() Agent {
	return new_agent(GoalFakeProvider{
		script: &GoalScript{}
	}, '')
}

fn goal_test_ctx(a &Agent) ToolContext {
	return ToolContext{
		cwd:   '/tmp'
		agent: a
	}
}

// ---------- Pure functions -------------------------------------------------

fn test_live_wall_ms_active_counts_in_progress_span() {
	g := GoalState{
		status:        .active
		wall_ms:       500
		resumed_at_ms: 1000
	}
	assert live_wall_ms(g, 1600) == 1100
	// Clock skew / same-instant reads never go negative.
	assert live_wall_ms(g, 900) == 500
}

fn test_live_wall_ms_inactive_returns_accumulated() {
	g := GoalState{
		status:  .paused
		wall_ms: 500
	}
	assert live_wall_ms(g, 999999) == 500
}

fn test_pause_folds_active_span() {
	g := GoalState{
		status:        .active
		wall_ms:       500
		resumed_at_ms: 1000
	}
	g2 := pause(g, 2000)
	assert g2.wall_ms == 1500
	assert g2.resumed_at_ms == 0
	// pause() doesn't change the status — the caller picks the target.
	assert g2.status == .active
	// Pausing a non-active goal is a no-op.
	g3 := pause(g2, 99999)
	assert g3.wall_ms == 1500
}

fn test_resume_anchors_resumed_at() {
	g := GoalState{
		status:  .blocked
		wall_ms: 1500
	}
	g2 := resume(g, 5000)
	assert g2.status == .active
	assert g2.resumed_at_ms == 5000
	assert g2.wall_ms == 1500
	assert live_wall_ms(g2, 6000) == 2500
}

fn test_over_budget() {
	// Unset budgets never trigger.
	g0 := GoalState{
		status:      .active
		turns_used:  100
		tokens_used: 100000
		wall_ms:     9999999
	}
	assert !over_budget(g0, 9999999)
	// Turns: used >= limit triggers.
	assert over_budget(GoalState{ turns_used: 5, budget_turns: 5 }, 0)
	assert !over_budget(GoalState{ turns_used: 4, budget_turns: 5 }, 0)
	// Tokens.
	assert over_budget(GoalState{ tokens_used: 100, budget_tokens: 100 }, 0)
	assert !over_budget(GoalState{ tokens_used: 99, budget_tokens: 100 }, 0)
	// Wall clock, using the live (in-progress) span.
	gw := GoalState{
		status:         .active
		wall_ms:        900
		resumed_at_ms:  1000
		budget_wall_ms: 2000
	}
	assert over_budget(gw, 2100) // live = 900 + 1100 >= 2000
	assert !over_budget(gw, 1800) // live = 900 + 800 < 2000
}

// ---------- CreateGoal -----------------------------------------------------

fn test_create_goal_success() {
	mut a := new_goal_test_agent()
	t := CreateGoalTool{
		agent: &a
	}
	r := execute_tool(t, '{"objective":"fix the flaky test","completion_criterion":"tests pass 3x"}',
		goal_test_ctx(&a))
	assert !r.is_error
	assert r.content.contains('"status":"active"')
	assert r.content.contains('fix the flaky test')
	g := a.goal or {
		assert false, 'goal not set'
		return
	}
	assert g.objective == 'fix the flaky test'
	assert g.criterion == 'tests pass 3x'
	assert g.status == .active
	assert g.turns_used == 0 && g.tokens_used == 0 && g.wall_ms == 0
	assert g.resumed_at_ms > 0
}

fn test_create_goal_empty_objective() {
	mut a := new_goal_test_agent()
	t := CreateGoalTool{
		agent: &a
	}
	r := execute_tool(t, '{"objective":"   "}', goal_test_ctx(&a))
	assert r.is_error
	assert a.goal == none
}

fn test_create_goal_too_long_objective() {
	mut a := new_goal_test_agent()
	t := CreateGoalTool{
		agent: &a
	}
	long := 'x'.repeat(4001)
	r := execute_tool(t, '{"objective":"${long}"}', goal_test_ctx(&a))
	assert r.is_error
	assert r.content.contains('too long')
	assert a.goal == none
}

fn test_create_goal_truncates_long_criterion() {
	mut a := new_goal_test_agent()
	t := CreateGoalTool{
		agent: &a
	}
	long := 'y'.repeat(5000)
	r := execute_tool(t, '{"objective":"obj","completion_criterion":"${long}"}', goal_test_ctx(&a))
	assert !r.is_error
	g := a.goal or {
		assert false, 'goal not set'
		return
	}
	assert g.criterion.len == 4000
}

fn test_create_goal_already_exists_and_replace() {
	mut a := new_goal_test_agent()
	t := CreateGoalTool{
		agent: &a
	}
	r1 := execute_tool(t, '{"objective":"first"}', goal_test_ctx(&a))
	assert !r1.is_error
	// Second create without replace → GOAL_ALREADY_EXISTS.
	r2 := execute_tool(t, '{"objective":"second"}', goal_test_ctx(&a))
	assert r2.is_error
	assert r2.content.contains('GOAL_ALREADY_EXISTS')
	g := a.goal or {
		assert false, 'goal not set'
		return
	}
	assert g.objective == 'first'
	// With replace=true the goal is overwritten and counters reset.
	mut g2 := a.goal or {
		assert false, 'goal not set'
		return
	}
	g2.turns_used = 7
	a.goal = g2
	r3 := execute_tool(t, '{"objective":"second","replace":true}', goal_test_ctx(&a))
	assert !r3.is_error
	g3 := a.goal or {
		assert false, 'goal not set after replace'
		return
	}
	assert g3.objective == 'second'
	assert g3.turns_used == 0
}

// ---------- GetGoal --------------------------------------------------------

fn test_get_goal_null_when_unset() {
	mut a := new_goal_test_agent()
	t := GetGoalTool{
		agent: &a
	}
	r := execute_tool(t, '{}', goal_test_ctx(&a))
	assert !r.is_error
	assert r.content == '{"goal": null}'
}

fn test_get_goal_snapshot() {
	mut a := new_goal_test_agent()
	a.goal = GoalState{
		objective:     'ship it'
		status:        .active
		turns_used:    2
		tokens_used:   42
		resumed_at_ms: time.now().unix_milli()
	}
	t := GetGoalTool{
		agent: &a
	}
	r := execute_tool(t, '{}', goal_test_ctx(&a))
	assert !r.is_error
	assert r.content.contains('"objective":"ship it"')
	assert r.content.contains('"turns_used":2')
	assert r.content.contains('"tokens_used":42')
	// The internal wall-clock anchor is not part of the snapshot.
	assert !r.content.contains('resumed_at_ms')
}

// ---------- UpdateGoal -----------------------------------------------------

fn test_update_goal_complete_clears_goal() {
	mut a := new_goal_test_agent()
	a.goal = GoalState{
		objective:     'obj'
		status:        .active
		turns_used:    3
		tokens_used:   100
		resumed_at_ms: time.now().unix_milli()
	}
	t := UpdateGoalTool{
		agent: &a
	}
	r := execute_tool(t, '{"status":"complete"}', goal_test_ctx(&a))
	assert !r.is_error
	assert r.content.contains('complete')
	assert r.content.contains('3 turns')
	assert r.content.contains('100 tokens')
	assert a.goal == none
}

fn test_update_goal_complete_without_active_goal() {
	mut a := new_goal_test_agent()
	t := UpdateGoalTool{
		agent: &a
	}
	// No goal at all.
	r := execute_tool(t, '{"status":"complete"}', goal_test_ctx(&a))
	assert !r.is_error
	assert r.content == 'Goal not completed: no active goal.'
	// Paused/blocked goal is not active either.
	a.goal = GoalState{
		objective: 'obj'
		status:   .blocked
	}
	r2 := execute_tool(t, '{"status":"complete"}', goal_test_ctx(&a))
	assert !r2.is_error
	assert r2.content == 'Goal not completed: no active goal.'
}

fn test_update_goal_blocked() {
	mut a := new_goal_test_agent()
	a.goal = GoalState{
		objective:     'obj'
		status:        .active
		resumed_at_ms: time.now().unix_milli()
	}
	t := UpdateGoalTool{
		agent: &a
	}
	r := execute_tool(t, '{"status":"blocked"}', goal_test_ctx(&a))
	assert !r.is_error
	g := a.goal or {
		assert false, 'goal should survive blocked'
		return
	}
	assert g.status == .blocked
	// The reason lives in the model's own reply, not in the state.
	assert g.terminal_reason == ''
	assert g.resumed_at_ms == 0
	// Blocking again is a no-op hint, not an error.
	r2 := execute_tool(t, '{"status":"blocked"}', goal_test_ctx(&a))
	assert !r2.is_error
	assert r2.content == 'Goal not marked blocked: no active goal.'
}

fn test_update_goal_resume() {
	mut a := new_goal_test_agent()
	t := UpdateGoalTool{
		agent: &a
	}
	// No goal → hint.
	r0 := execute_tool(t, '{"status":"active"}', goal_test_ctx(&a))
	assert !r0.is_error
	assert r0.content == 'Goal not resumed: no current goal.'
	// Blocked → active resumes wall-clock accounting and clears the reason.
	a.goal = GoalState{
		objective:       'obj'
		status:          .blocked
		wall_ms:         500
		terminal_reason: 'stuck'
	}
	r := execute_tool(t, '{"status":"active"}', goal_test_ctx(&a))
	assert !r.is_error
	g := a.goal or {
		assert false, 'goal lost on resume'
		return
	}
	assert g.status == .active
	assert g.resumed_at_ms > 0
	assert g.terminal_reason == ''
	assert g.wall_ms == 500
	// Already active → idempotent.
	r2 := execute_tool(t, '{"status":"active"}', goal_test_ctx(&a))
	assert !r2.is_error
	assert r2.content.contains('already active')
}

fn test_update_goal_invalid_status() {
	mut a := new_goal_test_agent()
	a.goal = GoalState{
		objective: 'obj'
		status:   .active
	}
	t := UpdateGoalTool{
		agent: &a
	}
	r := execute_tool(t, '{"status":"done"}', goal_test_ctx(&a))
	assert r.is_error
}

// ---------- SetGoalBudget --------------------------------------------------

fn test_set_goal_budget_no_goal() {
	mut a := new_goal_test_agent()
	t := SetGoalBudgetTool{
		agent: &a
	}
	r := execute_tool(t, '{"value":5,"unit":"turns"}', goal_test_ctx(&a))
	assert !r.is_error
	assert r.content.contains('no current goal')
}

fn test_set_goal_budget_units() {
	mut a := new_goal_test_agent()
	a.goal = GoalState{
		objective: 'obj'
		status:   .active
	}
	t := SetGoalBudgetTool{
		agent: &a
	}
	// Turns: fractional values round, minimum 1.
	r := execute_tool(t, '{"value":2.6,"unit":"turns"}', goal_test_ctx(&a))
	assert !r.is_error
	mut g := a.goal or {
		assert false, 'goal lost'
		return
	}
	assert g.budget_turns == 3
	r2 := execute_tool(t, '{"value":0.4,"unit":"turns"}', goal_test_ctx(&a))
	assert !r2.is_error
	g = a.goal or {
		assert false, 'goal lost'
		return
	}
	assert g.budget_turns == 1
	// Tokens.
	execute_tool(t, '{"value":100,"unit":"tokens"}', goal_test_ctx(&a))
	g = a.goal or {
		assert false, 'goal lost'
		return
	}
	assert g.budget_tokens == 100
	// Merge semantics: setting tokens kept the turns budget.
	assert g.budget_turns == 1
	// Wall-clock units → ms.
	execute_tool(t, '{"value":5000,"unit":"milliseconds"}', goal_test_ctx(&a))
	g = a.goal or { panic('goal lost') }
	assert g.budget_wall_ms == 5000
	execute_tool(t, '{"value":30,"unit":"seconds"}', goal_test_ctx(&a))
	g = a.goal or { panic('goal lost') }
	assert g.budget_wall_ms == 30000
	execute_tool(t, '{"value":2,"unit":"minutes"}', goal_test_ctx(&a))
	g = a.goal or { panic('goal lost') }
	assert g.budget_wall_ms == 120000
	execute_tool(t, '{"value":1,"unit":"hours"}', goal_test_ctx(&a))
	g = a.goal or { panic('goal lost') }
	assert g.budget_wall_ms == 3600000
}

fn test_set_goal_budget_rejects_unreasonable() {
	mut a := new_goal_test_agent()
	a.goal = GoalState{
		objective: 'obj'
		status:   .active
	}
	t := SetGoalBudgetTool{
		agent: &a
	}
	// Below the 1s floor.
	r := execute_tool(t, '{"value":500,"unit":"milliseconds"}', goal_test_ctx(&a))
	assert r.is_error
	assert r.content.contains('not a reasonable goal budget')
	// Above the 24h ceiling.
	r2 := execute_tool(t, '{"value":25,"unit":"hours"}', goal_test_ctx(&a))
	assert r2.is_error
	assert r2.content.contains('not a reasonable goal budget')
	// Non-positive value / unknown unit.
	r3 := execute_tool(t, '{"value":0,"unit":"turns"}', goal_test_ctx(&a))
	assert r3.is_error
	r4 := execute_tool(t, '{"value":5,"unit":"weeks"}', goal_test_ctx(&a))
	assert r4.is_error
}

fn test_set_goal_budget_already_over_warns_stop() {
	mut a := new_goal_test_agent()
	a.goal = GoalState{
		objective:  'obj'
		status:     .active
		turns_used: 2
	}
	t := SetGoalBudgetTool{
		agent: &a
	}
	r := execute_tool(t, '{"value":1,"unit":"turns"}', goal_test_ctx(&a))
	assert !r.is_error
	assert r.content.ends_with('...will stop now')
}

// ---------- Goal driver (loop integration) ---------------------------------

fn test_goal_driver_continues_and_stops_on_turn_budget() {
	// Goal active with a 1-turn budget: the first no-tool-calls step doesn't
	// end the run — the driver appends a continuation prompt and goes again;
	// after the second step the budget is reached and the goal is blocked.
	script := &GoalScript{
		calls: [
			goal_text_events('still working', 10),
			goal_text_events('wrapped up', 20),
		]
	}
	mut a := new_agent(GoalFakeProvider{
		script: script
	}, '')
	a.goal = GoalState{
		objective:     'finish the refactor'
		status:        .active
		resumed_at_ms: time.now().unix_milli()
		budget_turns:  1
	}
	mut sess := new_session('/tmp')
	sess.append_user('please refactor')
	res := a.run(mut sess) or {
		assert false, 'run failed: ${err.msg()}'
		return
	}
	assert res.outcome == .finished
	assert res.turns == 2
	assert script.idx == 2
	// The continuation prompt was appended as a synthetic user message.
	mut saw_continuation := false
	for m in sess.messages {
		if m.role == .user && m.content.contains('Continue working toward the active goal')
			&& m.content.contains('finish the refactor') {
			saw_continuation = true
		}
	}
	assert saw_continuation, 'continuation prompt not found in session'
	// Goal accounting: one completed goal turn, all output tokens booked,
	// and the reached budget marked the goal blocked.
	g := a.goal or {
		assert false, 'goal should survive budget stop'
		return
	}
	assert g.turns_used == 1
	assert g.tokens_used == 30
	assert g.status == .blocked
	assert g.terminal_reason == 'A configured budget was reached'
}

fn test_goal_driver_exits_when_model_marks_complete() {
	// Turn 1: plain text → driver continues. Turn 2: the model calls
	// UpdateGoal(complete) → goal cleared. Turn 3: plain text → normal exit.
	script := &GoalScript{
		calls: [
			goal_text_events('working on it', 5),
			goal_tool_call_events('call-1', 'UpdateGoal', '{"status":"complete"}', 5),
			goal_text_events('all done, here is the summary', 5),
		]
	}
	mut a := new_agent(GoalFakeProvider{
		script: script
	}, '')
	a.registry.register(UpdateGoalTool{
		agent: &a
	})
	a.goal = GoalState{
		objective:     'write the docs'
		status:        .active
		resumed_at_ms: time.now().unix_milli()
	}
	mut sess := new_session('/tmp')
	sess.append_user('write the docs')
	res := a.run(mut sess) or {
		assert false, 'run failed: ${err.msg()}'
		return
	}
	assert res.outcome == .finished
	assert res.turns == 3
	assert res.final_text == 'all done, here is the summary'
	// UpdateGoal(complete) cleared the goal, so the run exited normally.
	assert a.goal == none
}

// ---------- Persistence (goal_to_json / goal_from_json / metadata) ---------

fn test_goal_json_round_trip() {
	g := GoalState{
		objective:       'fix "quoted" things\nwith newlines'
		criterion:       'tests pass'
		status:          .blocked
		turns_used:      7
		tokens_used:     12345
		wall_ms:         60000
		resumed_at_ms:   0
		budget_turns:    10
		budget_tokens:   50000
		budget_wall_ms:  300000
		terminal_reason: 'stuck on CI'
	}
	g2 := goal_from_json(goal_to_json(g)) or {
		assert false, 'round trip failed'
		return
	}
	assert g2 == g
}

fn test_goal_json_round_trip_all_statuses() {
	for s in [GoalStatus.active, .paused, .blocked] {
		g := GoalState{
			objective: 'obj'
			status:   s
		}
		g2 := goal_from_json(goal_to_json(g)) or {
			assert false, 'round trip failed for ${s}'
			return
		}
		assert g2.status == s
	}
}

fn test_goal_from_json_rejects_garbage() {
	assert goal_from_json('') == none
	assert goal_from_json('not json') == none
	assert goal_from_json('{"status":"weird","objective":"x"}') == none
}

fn test_stash_and_restore_metadata_round_trip() {
	mut sess := new_session('/tmp')
	// A goal persisted mid-run: active, with accumulated wall time.
	g := GoalState{
		objective:     'long task'
		criterion:     'done'
		status:        .active
		turns_used:    3
		tokens_used:   777
		wall_ms:       42000
		resumed_at_ms: 123456789
		budget_turns:  10
	}
	stash_goal_metadata(mut sess, g)
	encoded := sess.metadata['goal'] or {
		assert false, 'goal key not stashed'
		return
	}
	assert encoded.len > 0
	// base64 alphabet only — safe for the unescaped TOML metadata writer.
	assert !encoded.contains('"') && !encoded.contains('\n')

	mut a := new_goal_test_agent()
	restore_goal_from_metadata(mut a, sess)
	g2 := a.goal or {
		assert false, 'goal not restored'
		return
	}
	// Active goals come back paused: the agent wasn't running while the
	// session was on disk, so the idle span must not count as active time.
	assert g2.status == .paused
	assert g2.terminal_reason == 'Paused after agent resume'
	assert g2.resumed_at_ms == 0
	// Everything else survives the round trip.
	assert g2.objective == 'long task'
	assert g2.criterion == 'done'
	assert g2.turns_used == 3
	assert g2.tokens_used == 777
	assert g2.wall_ms == 42000
	assert g2.budget_turns == 10
}

fn test_restore_non_active_goal_keeps_status() {
	mut sess := new_session('/tmp')
	stash_goal_metadata(mut sess, GoalState{
		objective:       'obj'
		status:          .blocked
		terminal_reason: 'A configured budget was reached'
	})
	mut a := new_goal_test_agent()
	restore_goal_from_metadata(mut a, sess)
	g := a.goal or {
		assert false, 'goal not restored'
		return
	}
	assert g.status == .blocked
	assert g.terminal_reason == 'A configured budget was reached'
}

fn test_stash_none_deletes_key() {
	mut sess := new_session('/tmp')
	stash_goal_metadata(mut sess, GoalState{
		objective: 'obj'
		status:   .active
	})
	assert 'goal' in sess.metadata
	stash_goal_metadata(mut sess, none)
	assert 'goal' !in sess.metadata
}

fn test_restore_without_metadata_is_noop() {
	mut sess := new_session('/tmp')
	mut a := new_goal_test_agent()
	a.goal = GoalState{
		objective: 'existing'
		status:   .active
	}
	restore_goal_from_metadata(mut a, sess)
	// Untouched.
	g := a.goal or {
		assert false, 'goal clobbered'
		return
	}
	assert g.objective == 'existing'
	assert g.status == .active
}

fn test_restore_ignores_corrupt_metadata() {
	mut sess := new_session('/tmp')
	sess.metadata['goal'] = '!!!not-base64!!!'
	mut a := new_goal_test_agent()
	restore_goal_from_metadata(mut a, sess)
	assert a.goal == none
}

fn test_goal_badge_summary() {
	active := GoalState{
		status:        .active
		turns_used:    3
		wall_ms:       5000
		resumed_at_ms: 1000
	}
	assert goal_badge_summary(active, 11000) == 'GOAL active · 3 turns · 15s'
	blocked := GoalState{
		status:     .blocked
		turns_used: 3
	}
	assert goal_badge_summary(blocked, 99999) == 'GOAL blocked · 3 turns'
}
