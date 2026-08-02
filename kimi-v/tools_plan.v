// internal/tools/plan.v
// Plan-mode tools: EnterPlanMode and ExitPlanMode.
//
// Mirrors kimi-code's builtin planning tools. EnterPlanMode puts the agent
// into a read-only planning state (the loop then blocks edits to any file
// except the plan file). ExitPlanMode reads the plan file the model wrote,
// surfaces it to the user for approval (TUI modal, or auto-approve in
// non-interactive mode), and deactivates plan mode.
//
// Both tools hold an `&Agent` so they can flip `a.plan` directly and, in the
// ExitPlanMode case, block on the TUI-owned approval channel.
module main

import json2

// =============================================================================
// EnterPlanMode
// =============================================================================

// EnterPlanModeTool activates read-only plan mode before starting non-trivial work.
pub struct EnterPlanModeTool {
pub:
	agent &Agent
}

// name returns the tool identifier used in the registry and provider.
pub fn (t EnterPlanModeTool) name() string {
	return 'EnterPlanMode'
}

// description returns the human-readable description shown to the model.
pub fn (t EnterPlanModeTool) description() string {
	return 'Use this tool proactively when you are about to start a non-trivial implementation task and want to get user sign-off on your approach before writing code. Entering plan mode does NOT require approval. Once in plan mode you MUST NOT edit files except the plan file, and your turn must end with either AskUserQuestion (to clarify) or ExitPlanMode (for approval).'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t EnterPlanModeTool) parameters_schema() string {
	return '{"type":"object","properties":{},"required":[],"additionalProperties":false}'
}

// execute enables plan mode and returns the plan file path and workflow.
pub fn (t EnterPlanModeTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	mut a := t.agent
	if a.plan.is_active {
		return ToolResult{
			content:  'Plan mode is already active. Use ExitPlanMode when the plan is ready.'
			is_error: true
		}
	}
	path := a.enter_plan_mode()
	// The loop injects the full plan-mode reminder on the next turn via
	// a.build_request() (see plan_mode_reminder()). We give the model a
	// short immediate acknowledgement here.
	msg := [
		'Plan mode is now active. Your workflow:',
		'',
		'Plan file: ${path}',
		'',
		'1. Use read-only tools (read_file, grep, glob) to investigate the codebase. Use Bash only when needed.',
		'2. Design a concrete, step-by-step plan.',
		'3. Write the plan to the plan file with write_file or edit_file.',
		'4. When the plan is ready, call ExitPlanMode for user approval.',
		'',
		'Do NOT edit files other than the plan file while plan mode is active.',
	].join('\n')
	return ToolResult{
		content: msg
	}
}

// =============================================================================
// ExitPlanMode
// =============================================================================

// ExitPlanModeTool finalizes plan mode by presenting the plan for user approval.
pub struct ExitPlanModeTool {
pub:
	agent &Agent
}

// name returns the tool identifier used in the registry and provider.
pub fn (t ExitPlanModeTool) name() string {
	return 'ExitPlanMode'
}

// description returns the human-readable description shown to the model.
pub fn (t ExitPlanModeTool) description() string {
	return 'Use this tool when you are in plan mode and have finished writing your plan to the plan file and are ready for user approval. This tool reads the plan from the file you wrote and presents it to the user. Do NOT pass the plan content as a parameter. When the plan offers multiple approaches, pass them via the `options` parameter (up to 3) so the user can choose which to execute. End your turn with this tool — do not ask about plan approval via text or AskUserQuestion.'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t ExitPlanModeTool) parameters_schema() string {
	return '{"type":"object","properties":{"options":{"type":"array","description":"When the plan contains multiple alternative approaches, list 2-3 of them so the user can choose which to execute. Each: {label: short name (1-8 words, append (Recommended) if recommended), description: trade-offs}. Do not use the reserved labels Approve/Reject/Revise/Reject and Exit.","items":{"type":"object","properties":{"label":{"type":"string","description":"Short name for this approach"},"description":{"type":"string","description":"Brief summary of this approach and its trade-offs"}},"required":["label","description"],"additionalProperties":false},"minItems":1,"maxItems":3}},"required":[],"additionalProperties":false}'
}

// exit_plan_args is the parsed input for ExitPlanMode. `options` is optional.
struct ExitPlanArgs {
	options []ExitPlanOptionRaw
}

// ExitPlanOptionRaw is one alternative approach passed to ExitPlanMode.
struct ExitPlanOptionRaw {
	label       string
	description string
}

// execute reads the plan file, prompts the user (or auto-approves), and exits plan mode.
pub fn (t ExitPlanModeTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	mut a := t.agent
	if !a.plan.is_active {
		return ToolResult{
			content:  'ExitPlanMode can only be called while plan mode is active. Use EnterPlanMode (or /plan) first.'
			is_error: true
		}
	}

	// Parse optional `options` (alternative approaches).
	mut opts := []PlanOption{}
	decoded := json2.decode[ExitPlanArgs](args.raw) or {
		// No options / empty args is fine; proceed with the plan only.
		ExitPlanArgs{}
	}
	for o in decoded.options {
		label := o.label.trim_space()
		if label.len == 0 {
			continue
		}
		// Reject reserved labels (Approve / Reject / Revise / Reject and Exit).
		norm := label.to_lower()
		if norm in ['approve', 'reject', 'revise', 'reject and exit'] {
			continue
		}
		opts << PlanOption{ label: label, description: o.description.trim_space() }
	}

	// Read the plan file the model wrote.
	content, inactive := a.plan_data()
	if inactive {
		return ToolResult{
			content:  'Plan mode is no longer active. Cannot read the plan file.'
			is_error: true
		}
	}
	if content.trim_space().len == 0 {
		path := a.plan.plan_file_path
		if path.len > 0 {
			return ToolResult{
				content:  'No plan file found. Write your plan to ${path} first, then call ExitPlanMode.'
				is_error: true
			}
		}
		return ToolResult{
			content:  'No plan file found. Write the plan to the current plan file first, then call ExitPlanMode.'
			is_error: true
		}
	}

	// Non-interactive mode (e.g. `kimi -p`): auto-approve so the agent
	// never blocks waiting for a UI that isn't there. The plan mode
	// read-only guard is lifted and the approved plan is returned to the
	// model as context.
	if a.non_interactive {
		prev_path := a.exit_plan_mode()
		saved_to := if prev_path.len > 0 { 'Plan saved to: ${prev_path}\n\n' } else { '' }
		return ToolResult{
			content: 'Exited plan mode. ${saved_to}## Approved Plan:\n${content}'
		}
	}

	// Interactive mode: block on the TUI's exit-plan approval channel.
	a.next_exit_plan_id++
	req := ExitPlanRequest{
		id:      a.next_exit_plan_id
		plan:    content
		path:    a.plan.plan_file_path
		options: opts
	}
	// Send to TUI; if the channel is closed/unavailable treat as approved
	// (defensive — should not happen while the TUI is up).
	a.exit_plan_ch <- req or {
		a.exit_plan_mode()
		return ToolResult{
			content: 'Exited plan mode. ## Approved Plan:\n${content}'
		}
	}

	res := <-a.exit_plan_result_ch or {
		ExitPlanResult{ id: req.id, decision: 'approved' }
	}

	// The TUI already flipped plan mode off for approve/reject_and_exit.
	// For revise/dismissed we keep plan mode active so the model can
	// produce a new plan on the next turn.
	match res.decision {
		'approved' {
			// Deactivate plan mode so the read-only guard lifts and the
			// model can start executing. The TUI already cleared its own
			// `plan_mode_active` banner flag.
			a.exit_plan_mode()
			saved_to := if req.path.len > 0 { 'Plan saved to: ${req.path}\n\n' } else { '' }
			mut option_prefix := ''
			if res.selected_label.len > 0 {
				option_prefix = 'Selected approach: ${res.selected_label}\nExecute ONLY the selected approach. Do not execute any unselected alternatives.\n\n'
			}
			return ToolResult{
				content: 'Exited plan mode. ${option_prefix}${saved_to}## Approved Plan:\n${content}'
			}
		}
		'rejected_and_exit' {
			a.exit_plan_mode()
			return ToolResult{
				content:  'Plan rejected by user. Plan mode deactivated.'
				is_error: true
			}
		}
		'revise' {
			feedback := if res.feedback.len > 0 {
				'\n\nUser feedback on the plan:\n${res.feedback}'
			} else {
				''
			}
			// Plan mode stays active so the model can revise and call
			// ExitPlanMode again on the next turn.
			return ToolResult{
				content: 'User requested revisions. Plan mode remains active. Revise your plan and call ExitPlanMode again.${feedback}'
			}
		}
		'dismissed' {
			// Plan mode stays active.
			return ToolResult{
				content: 'Plan approval dismissed. Plan mode remains active.'
			}
		}
		else { // 'rejected' and any unknown → stay in plan mode
			return ToolResult{
				content:  'Plan rejected by user. Plan mode remains active.'
				is_error: true
			}
		}
	}
}
