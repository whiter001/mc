// internal/agent/tool_registry.v
// The Tool interface and a name-keyed registry. Built-in tools are registered
// here; future versions add MCP-loaded tools at runtime.
module main

// Tool is what every callable capability implements. Tools are stateless —
// everything they need is passed in via `ctx` (cwd, permissions, abort flag).
pub interface Tool {
	name() string
	description() string
	parameters_schema() string
	execute(args ToolArgs, ctx ToolContext) !ToolResult
}

// ToolArgs is the raw JSON arguments sent by the model. We keep them as a
// string (instead of forcing a typed struct) so a single Tool can accept
// arbitrary input without compile-time coupling.
pub struct ToolArgs {
pub:
	raw string
}

pub struct ToolResult {
pub:
	content  string
	is_error bool
}

pub struct ToolContext {
pub:
	cwd string
	// Permission mode (e.g. 'plan', 'default', 'accept-edits').
	permission string
	// When true, the loop is asking the tool to do a dry-run preview.
	dry_run bool
	// Back-reference to the owning Agent. Lets stateful tools (e.g. the
	// Todo list) read/write agent-scoped state without the Tool interface
	// itself carrying mutable references. Optional; most tools ignore it.
	agent ?&Agent
}

// ToolRegistry resolves tools by name and exposes their definitions to the
// provider.
pub struct ToolRegistry {
pub mut:
	tools map[string]Tool
}

pub fn new_registry() ToolRegistry {
	return ToolRegistry{
		tools: map[string]Tool{}
	}
}

pub fn (mut r ToolRegistry) register(t Tool) {
	r.tools[t.name()] = t
}

pub fn (r ToolRegistry) get(name string) ?Tool {
	if t := r.tools[name] {
		return t
	}
	return none
}

pub fn (r ToolRegistry) names() []string {
	mut out := []string{}
	for name, _ in r.tools {
		out << name
	}
	return out
}

pub fn (r ToolRegistry) definitions() []ToolDef {
	mut defs := []ToolDef{}
	for _, t in r.tools {
		defs << ToolDef{
			name:        t.name()
			description: t.description()
			parameters:  t.parameters_schema()
		}
	}
	return defs
}

// execute_tool runs a tool with the given JSON args, returning a structured
// result. JSON parse failures are returned as `is_error: true` rather than
// thrown — the model needs to see the failure so it can retry.
pub fn execute_tool(t Tool, args_raw string, ctx ToolContext) ToolResult {
	r := t.execute(ToolArgs{ raw: args_raw }, ctx) or {
		return ToolResult{
			content:  'tool error: ${err.msg()}'
			is_error: true
		}
	}
	return r
}
