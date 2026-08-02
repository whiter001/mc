// tools_subagent_tasklist.v — the `TaskList` tool.
//
// Mirrors kimi-code's TaskList tool: lists the background subagent tasks
// launched via Agent(run_in_background=true) with their current status, so
// the model can check on a running subagent and pick up the result of a
// finished one. Status lives on the parent Agent (bg_tasks), written by the
// background goroutine under bg_mutex and read here under the same lock.
module main

import time

// =============================================================================
// TaskList (background subagent status)
// =============================================================================

// TaskListTool reports the status of background subagent tasks.
pub struct TaskListTool {
pub:
	// The parent agent whose bg_tasks map we read. Kept for parity with the
	// other agent-bound tools; reads actually go through ctx.agent.
	agent &Agent
}

// name returns the tool identifier used in the registry and provider.
pub fn (t TaskListTool) name() string {
	return 'TaskList'
}

// description returns the human-readable description shown to the model.
pub fn (t TaskListTool) description() string {
	return 'List all background subagent tasks launched with Agent(run_in_background=true) and their current status (running / completed / failed). Call this to check on a background subagent, or to retrieve the result preview of one that has finished. Each entry shows the agent_id, profile, status, elapsed time, and a preview of the result for completed tasks.'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t TaskListTool) parameters_schema() string {
	return '{"type":"object","properties":{},"additionalProperties":false}'
}

// execute lists the background tasks, newest first. The result preview is
// truncated to keep the parent's context lean.
pub fn (t TaskListTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	_ := args
	a := ctx.agent or {
		return ToolResult{
			content:  'TaskList tool: no agent context available'
			is_error: true
		}
	}
	a.bg_mutex.lock()
	mut ids := a.bg_tasks.keys()
	ids.sort(a > b)
	mut lines := []string{}
	for id in ids {
		task := a.bg_tasks[id]
		mut line := '- ${task.agent_id} (${task.profile_name}): ${task.status}'
		if task.status == 'running' {
			line += ' (${time.now().unix_milli() - task.started_ms} ms elapsed)'
		} else {
			line += ' (${task.elapsed_ms} ms elapsed)'
		}
		lines << line
		if task.status == 'completed' && task.result.len > 0 {
			lines << '  result: ${truncate(task.result, 200)}'
		}
		if task.status == 'failed' && task.err.len > 0 {
			lines << '  error: ${truncate(task.err, 200)}'
		}
	}
	a.bg_mutex.unlock()
	content := if lines.len == 0 { '(no background subagent tasks)' } else { lines.join('\n') }
	return ToolResult{
		content: content
	}
}
