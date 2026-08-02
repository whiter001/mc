// tools_todo.v — session todo list (parity with upstream `TodoList`).
//
// The model uses these to track multi-step work: TodoWrite replaces the
// whole list, TodoRead returns the current list. State lives on the
// Agent (ctx.agent) because the Tool interface is stateless by design
// (everything is passed via `ctx`). A single kimi-v process serves one
// session, so agent-scoped state is the natural home — and it sidesteps
// any cross-goroutine mutation concerns.

module main

import json2

// TodoItem is one tracked task.
pub struct TodoItem {
pub:
	content     string // what to do
	status      string // pending | in_progress | completed
	active_form string @[json: 'activeForm'] // optional present-participle form
}

// normalize_status maps arbitrary model input to one of the three valid
// statuses, defaulting to "pending".
fn normalize_status(s string) string {
	match s.to_lower() {
		'in_progress', 'inprogress', 'active' { return 'in_progress' }
		'completed', 'done', 'complete', 'finished' { return 'completed' }
		else { return 'pending' }
	}
}

// todos_to_markdown renders the todo list as markdown with checkboxes.
fn todos_to_markdown(items []TodoItem) string {
	if items.len == 0 {
		return '(todo list is empty)'
	}
	mut out := '# Todo\n\n'
	mut completed := 0
	for it in items {
		if it.status == 'completed' {
			completed++
		}
		box := match it.status {
			'completed' { '[x]' }
			'in_progress' { '[~]' }
			else { '[ ]' }
		}
		out += '- ${box} ${it.content}\n'
	}
	out += '\n${completed}/${items.len} completed'
	return out
}

// =============================================================================
// TodoWrite
// =============================================================================

// TodoWriteTool replaces the agent's current todo list with a new one.
pub struct TodoWriteTool {}

// name returns the tool identifier used in the registry and provider.
pub fn (t TodoWriteTool) name() string {
	return 'TodoWrite'
}

// description returns the human-readable description shown to the model.
pub fn (t TodoWriteTool) description() string {
	return 'Use this to create and manage a structured task list for your current coding session. ' +
		'This helps you track progress, organize complex tasks, and demonstrate thoroughness. ' +
		'Call this whenever you start a multi-step task. Pass the full list each time — this ' +
		'replaces the previous list. Each item needs: content (what to do), status ' +
		'(pending | in_progress | completed), and an optional activeForm.'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t TodoWriteTool) parameters_schema() string {
	return '{"type":"object","properties":{"todos":{"type":"array","description":"The complete list of todos (replaces any prior list)","items":{"type":"object","properties":{"content":{"type":"string","description":"Task description"},"status":{"type":"string","description":"pending | in_progress | completed"},"activeForm":{"type":"string","description":"Optional present-participle form, e.g. \\"Fixing the bug\\""}},"required":["content","status"]}}},"required":["todos"],"additionalProperties":false}'
}

// TodoRaw is one todo entry as received from the model.
struct TodoRaw {
	content     string
	status      string
	active_form string @[json: 'activeForm']
}

// TodoArgs is the parsed JSON input for TodoWrite.
struct TodoArgs {
	todos []TodoRaw
}

// execute normalizes the input and stores the updated todo list on the Agent.
pub fn (t TodoWriteTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	// The model sends `todos` as a JSON array inside the args object.
	parsed := json2.decode[TodoArgs](args.raw) or {
		return ToolResult{
			content:  'invalid arguments: ${err.msg()} (expected {"todos":[...]})'
			is_error: true
		}
	}
	items := parsed.todos
	if items.len == 0 {
		return ToolResult{
			content:  'missing required argument: todos (non-empty array)'
			is_error: true
		}
	}
	mut norm := []TodoItem{cap: items.len}
	for it in items {
		norm << TodoItem{
			content:     it.content
			status:      normalize_status(it.status)
			active_form: it.active_form
		}
	}
	// Store on the Agent (the per-session singleton, reachable via ctx).
	mut a := ctx.agent or {
		return ToolResult{
			content:  'todo tool: no agent context available'
			is_error: true
		}
	}
	a.todos = norm
	mut done := 0
	for it in norm {
		if it.status == 'completed' {
			done++
		}
	}
	return ToolResult{
		content: 'Updated todo list (${norm.len} items, ${done} completed).'
	}
}

// =============================================================================
// TodoRead
// =============================================================================

// TodoReadTool returns the current todo list for this session.
pub struct TodoReadTool {}

// name returns the tool identifier used in the registry and provider.
pub fn (t TodoReadTool) name() string {
	return 'TodoRead'
}

// description returns the human-readable description shown to the model.
pub fn (t TodoReadTool) description() string {
	return 'Read the current todo list for this session. Returns the items and their statuses. ' +
		'Use this to check what you have left to do before reporting completion.'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t TodoReadTool) parameters_schema() string {
	return '{"type":"object","properties":{},"additionalProperties":false}'
}

// execute returns the stored todos formatted as markdown.
pub fn (t TodoReadTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	a := ctx.agent or {
		return ToolResult{
			content:  'todo tool: no agent context available'
			is_error: true
		}
	}
	return ToolResult{
		content: todos_to_markdown(a.todos)
	}
}
