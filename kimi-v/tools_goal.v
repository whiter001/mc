// tools_goal.v — the Goal tools (parity with kimi-code's Goal system).
//
// CreateGoal starts a session goal the agent loop then drives to
// completion: while a goal is active, run() appends a continuation
// prompt instead of stopping when the model goes quiet. UpdateGoal lets
// the model adjudicate the goal (complete / blocked / resume), GetGoal
// returns the current snapshot, and SetGoalBudget configures turn/token/
// wall-clock budgets that stop the run when reached.
//
// State lives on the Agent (the per-session singleton) — same pattern as
// the todo list and plan-mode tools.
module main

import json2
import time

// goal_max_text_len caps objective / completion-criterion length.
const goal_max_text_len = 4000

// goal_now_ms returns the current epoch milliseconds (one call site so
// tests can reason about clock use).
fn goal_now_ms() i64 {
	return time.now().unix_milli()
}

// =============================================================================
// CreateGoal
// =============================================================================

// CreateGoalTool creates (or replaces) the session goal.
pub struct CreateGoalTool {
pub:
	agent &Agent
}

// name returns the tool identifier used in the registry and provider.
pub fn (t CreateGoalTool) name() string {
	return 'CreateGoal'
}

// description returns the human-readable description shown to the model.
pub fn (t CreateGoalTool) description() string {
	return 'Create a goal for this session. While a goal is active, the agent keeps working across turns until you adjudicate it with UpdateGoal (complete or blocked) or a budget set with SetGoalBudget is reached. Use this for substantial multi-step tasks where you should not stop to ask the user. Pass replace=true to overwrite an existing goal.'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t CreateGoalTool) parameters_schema() string {
	return '{"type":"object","properties":{"objective":{"type":"string","description":"The objective to work toward (required, max 4000 chars)"},"completion_criterion":{"type":"string","description":"Optional criterion that must hold for the goal to be complete (max 4000 chars)"},"replace":{"type":"boolean","description":"If true, replace an existing goal; otherwise creating over an existing goal is an error."}},"required":["objective"],"additionalProperties":false}'
}

// CreateGoalArgs is the parsed JSON input for CreateGoal.
struct CreateGoalArgs {
	objective             string
	completion_criterion string @[json: 'completion_criterion']
	replace               bool
}

// execute validates the input and installs a fresh active goal on the agent.
pub fn (t CreateGoalTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	parsed := json2.decode[CreateGoalArgs](args.raw) or {
		return ToolResult{
			content:  'invalid arguments: ${err.msg()} (expected {"objective":...})'
			is_error: true
		}
	}
	mut a := t.agent
	objective := parsed.objective.trim_space()
	if objective.len == 0 {
		return ToolResult{
			content:  'missing required argument: objective (non-empty)'
			is_error: true
		}
	}
	if objective.len > goal_max_text_len {
		return ToolResult{
			content:  'objective is too long (${objective.len} chars, max ${goal_max_text_len}). Put the detailed spec in a file and reference its path in the objective instead.'
			is_error: true
		}
	}
	mut criterion := parsed.completion_criterion.trim_space()
	if criterion.len > goal_max_text_len {
		criterion = criterion[..goal_max_text_len]
	}
	if a.goal != none {
		if !parsed.replace {
			return ToolResult{
				content:  'GOAL_ALREADY_EXISTS: a goal is already set for this session. Pass replace=true to overwrite it, or UpdateGoal/GetGoal to inspect it first.'
				is_error: true
			}
		}
	}
	now := goal_now_ms()
	a.goal = GoalState{
		objective:     objective
		criterion:     criterion
		status:        .active
		resumed_at_ms: now
	}
	a.emit_goal_status()
	return ToolResult{
		content: goal_snapshot_json(a.goal or { GoalState{} }, now)
	}
}

// =============================================================================
// GetGoal
// =============================================================================

// GetGoalTool returns the current goal snapshot (never errors).
pub struct GetGoalTool {
pub:
	agent &Agent
}

// name returns the tool identifier used in the registry and provider.
pub fn (t GetGoalTool) name() string {
	return 'GetGoal'
}

// description returns the human-readable description shown to the model.
pub fn (t GetGoalTool) description() string {
	return 'Get the current session goal: objective, completion criterion, status, progress (turns, tokens, elapsed time), and budgets. Returns {"goal": null} when no goal is set.'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t GetGoalTool) parameters_schema() string {
	return '{"type":"object","properties":{},"additionalProperties":false}'
}

// execute returns the goal snapshot JSON, or {"goal": null} when unset.
pub fn (t GetGoalTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	a := t.agent
	now := goal_now_ms()
	g := a.goal or {
		return ToolResult{
			content: '{"goal": null}'
		}
	}
	return ToolResult{
		content: goal_snapshot_json(g, now)
	}
}

// =============================================================================
// UpdateGoal
// =============================================================================

// UpdateGoalTool adjudicates the session goal (complete/blocked/resume).
pub struct UpdateGoalTool {
pub:
	agent &Agent
}

// name returns the tool identifier used in the registry and provider.
pub fn (t UpdateGoalTool) name() string {
	return 'UpdateGoal'
}

// description returns the human-readable description shown to the model.
pub fn (t UpdateGoalTool) description() string {
	return 'Update the session goal status. "complete": the objective is verifiably satisfied — write your completion summary in your reply; the goal is cleared. "blocked": you cannot make progress — explain the blocking condition in your reply. "active": resume a paused/blocked goal. Only call "complete" with concrete evidence the objective is satisfied.'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t UpdateGoalTool) parameters_schema() string {
	return '{"type":"object","properties":{"status":{"type":"string","description":"One of: active, complete, blocked.","enum":["active","complete","blocked"]}},"required":["status"],"additionalProperties":false}'
}

// UpdateGoalArgs is the parsed JSON input for UpdateGoal.
struct UpdateGoalArgs {
	status string
}

// execute applies the requested state transition to the agent's goal.
pub fn (t UpdateGoalTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	parsed := json2.decode[UpdateGoalArgs](args.raw) or {
		return ToolResult{
			content:  'invalid arguments: ${err.msg()} (expected {"status":"active|complete|blocked"})'
			is_error: true
		}
	}
	mut a := t.agent
	now := goal_now_ms()
	match parsed.status {
		'complete' {
			g := a.goal or {
				return ToolResult{
					content: 'Goal not completed: no active goal.'
				}
			}
			if g.status != .active {
				return ToolResult{
					content: 'Goal not completed: no active goal.'
				}
			}
			// Snapshot stats before clearing so the model can fold them
			// into its completion summary.
			g2 := pause(g, now)
			stats := '${g2.turns_used} turns, ${g2.tokens_used} tokens, ${fmt_wall_ms(g2.wall_ms)} elapsed'
			a.goal = none
			a.emit_goal_status()
			return ToolResult{
				content: 'Goal marked complete (${stats}). The goal has been cleared. Now write a concise completion summary for the user in your reply: what was accomplished, key evidence the objective is satisfied, and anything intentionally left out.'
			}
		}
		'blocked' {
			g := a.goal or {
				return ToolResult{
					content: 'Goal not marked blocked: no active goal.'
				}
			}
			if g.status != .active {
				return ToolResult{
					content: 'Goal not marked blocked: no active goal.'
				}
			}
			// The reason itself belongs in the model's own reply, so
			// terminal_reason stays empty here.
			mut g2 := pause(g, now)
			g2.status = .blocked
			g2.terminal_reason = ''
			a.goal = g2
			a.emit_goal_status()
			return ToolResult{
				content: 'Goal marked blocked (${budget_report(g2, now)}). Explain the blocking condition in your reply: what you tried, what is blocking progress, and what would unblock it.'
			}
		}
		'active' {
			g := a.goal or {
				return ToolResult{
					content: 'Goal not resumed: no current goal.'
				}
			}
			if g.status == .active {
				// Idempotent: already active, nothing to do.
				return ToolResult{
					content: 'Goal is already active. ${budget_report(g, now)}'
				}
			}
			mut g2 := resume(g, now)
			g2.terminal_reason = ''
			a.goal = g2
			a.emit_goal_status()
			return ToolResult{
				content: 'Goal resumed (${budget_report(g2, now)}). Continue working toward the objective.'
			}
		}
		else {
			return ToolResult{
				content:  'invalid status "${parsed.status}": expected one of active, complete, blocked'
				is_error: true
			}
		}
	}
}

// =============================================================================
// SetGoalBudget
// =============================================================================

// SetGoalBudgetTool configures turn/token/wall-clock budgets on the goal.
pub struct SetGoalBudgetTool {
pub:
	agent &Agent
}

// name returns the tool identifier used in the registry and provider.
pub fn (t SetGoalBudgetTool) name() string {
	return 'SetGoalBudget'
}

// description returns the human-readable description shown to the model.
pub fn (t SetGoalBudgetTool) description() string {
	return 'Set a budget on the current goal. When the goal reaches the budget, the run stops and the goal is marked blocked. Units: turns, tokens (output), milliseconds, seconds, minutes, hours. Budgets merge — each call updates only the unit you pass. Time budgets must be between 1 second and 24 hours.'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t SetGoalBudgetTool) parameters_schema() string {
	return '{"type":"object","properties":{"value":{"type":"number","description":"Budget amount (positive)"},"unit":{"type":"string","description":"One of: turns, tokens, milliseconds, seconds, minutes, hours.","enum":["turns","tokens","milliseconds","seconds","minutes","hours"]}},"required":["value","unit"],"additionalProperties":false}'
}

// SetGoalBudgetArgs is the parsed JSON input for SetGoalBudget. `value` is
// decoded as f64 so fractional model input (e.g. 1.5 minutes) rounds sanely.
struct SetGoalBudgetArgs {
	value f64
	unit  string
}

// goal_budget_wall_min_ms / goal_budget_wall_max_ms bound wall-clock budgets.
const goal_budget_wall_min_ms = i64(1000)
const goal_budget_wall_max_ms = i64(86400000)

// execute merges the requested budget into the current goal's budgets.
pub fn (t SetGoalBudgetTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	parsed := json2.decode[SetGoalBudgetArgs](args.raw) or {
		return ToolResult{
			content:  'invalid arguments: ${err.msg()} (expected {"value":..., "unit":...})'
			is_error: true
		}
	}
	mut a := t.agent
	mut g := a.goal or {
		return ToolResult{
			content: 'Goal budget not set: no current goal.'
		}
	}
	if parsed.value <= 0 {
		return ToolResult{
			content:  'invalid budget value ${parsed.value}: must be positive'
			is_error: true
		}
	}
	// Round to the nearest whole unit, minimum 1.
	mut rounded := int(parsed.value + 0.5)
	if rounded < 1 {
		rounded = 1
	}
	match parsed.unit {
		'turns' {
			g.budget_turns = rounded
		}
		'tokens' {
			g.budget_tokens = rounded
		}
		'milliseconds', 'seconds', 'minutes', 'hours' {
			multiplier := match parsed.unit {
				'milliseconds' { i64(1) }
				'seconds' { i64(1000) }
				'minutes' { i64(60000) }
				else { i64(3600000) }
			}
			ms := i64(rounded) * multiplier
			if ms < goal_budget_wall_min_ms || ms > goal_budget_wall_max_ms {
				return ToolResult{
					content:  '${parsed.value} ${parsed.unit} is not a reasonable goal budget (must be between 1 second and 24 hours)'
					is_error: true
				}
			}
			g.budget_wall_ms = ms
		}
		else {
			return ToolResult{
				content:  'invalid budget unit "${parsed.unit}": expected one of turns, tokens, milliseconds, seconds, minutes, hours'
				is_error: true
			}
		}
	}
	a.goal = g
	a.emit_goal_status()
	now := goal_now_ms()
	mut content := 'Goal budget updated: ${budget_report(g, now)}'
	if over_budget(g, now) {
		content += '\nThe goal has already reached this budget and ...will stop now'
	}
	return ToolResult{
		content: content
	}
}
