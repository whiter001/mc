// tools_subagent.v — the `Agent` collaboration tool.
//
// Mirrors kimi-code's `AgentTool`: lets the model delegate a task to a
// subagent (coder / explore / plan, or a generic 'coder' by default). The
// subagent runs as its own in-process loop instance with an isolated
// Session and (for explore/plan) a trimmed toolset. The parent receives only
// the subagent's final handoff text.
//
// Per upstream: subagents keep the bulk of intermediate file contents out of
// the parent's context — the parent gets a conclusion back instead of a pile
// of dumps. A subagent's result is only visible to the parent agent, not the
// end user.
module main

import json

// =============================================================================
// Agent (subagent dispatch)
// =============================================================================

pub struct AgentTool {
pub:
	// The parent agent, used to inherit provider/model/cwd/approval
	// settings when spawning the subagent.
	agent &Agent
}

pub fn (t AgentTool) name() string {
	return 'Agent'
}

// build_subagent_type_lines composes the "Available agent types" section of
// the tool description, mirroring upstream's buildSubagentDescriptions().
fn build_subagent_type_lines() string {
	profiles := default_profiles()
	mut lines := []string{}
	order := ['coder', 'explore', 'plan']
	for name in order {
		p := profiles[name]
		lines << '- ${name}: ${p.description}. ${p.when_to_use}'
	}
	return lines.join('\n')
}

pub fn (t AgentTool) description() string {
	base := 'Launch a subagent to handle a task. The subagent runs as a same-process loop instance with its own context. Delegating also keeps the bulk of intermediate file contents out of your own context — you get a conclusion back instead of a pile of dumps.

Writing the prompt:
- The subagent starts with zero context — it has not seen this conversation. Brief it like a colleague who just walked into the room: state the goal, list what you already know, hand over the specifics.
- Lookups (read this file, run that test): put the exact path or command in the prompt. The subagent should not have to search for things you already know.
- Investigations (figure out X, find why Y): give the question, not prescribed steps — fixed steps become dead weight when the premise is wrong.
- Do not delegate understanding. If the task hinges on a file path or line number, find it yourself first and write it into the prompt.

Usage notes:
- A subagent\'s result is only visible to you, not to the user. When the user needs to see what a subagent produced, summarize the relevant parts yourself in your own reply.

When NOT to use Agent: skip delegation for trivial work you can do directly — reading a file whose path you already know, searching a small known set of files, or any task that takes only a step or two. Delegation has a context-handoff cost; it pays off only when the task is substantial enough to outweigh it.'
	types := build_subagent_type_lines()
	return '${base}\n\nAvailable agent types (pass via subagent_type):\n${types}'
}

pub fn (t AgentTool) parameters_schema() string {
	return '{"type":"object","properties":{"prompt":{"type":"string","description":"Full task prompt for the subagent"},"description":{"type":"string","description":"Short task description (3-5 words) for display"},"subagent_type":{"type":"string","description":"One of: coder, explore, plan. Defaults to coder when omitted."},"resume":{"type":"string","description":"Optional agent ID to resume instead of creating a new instance. When set, do not also pass subagent_type."},"run_in_background":{"type":"boolean","description":"If true, return immediately. (Background execution is not supported in this build; treated as foreground.)"}},"required":["prompt","description"],"additionalProperties":false}'
}

struct AgentToolArgs {
	prompt         string
	description    string
	subagent_type  string @[json: 'subagent_type']
	resume         string
	run_in_background bool @[json: 'run_in_background']
}

pub fn (t AgentTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	parsed := json.decode(AgentToolArgs, args.raw) or {
		return ToolResult{
			content:  'invalid arguments: ${err.msg()} (expected {"prompt":..., "description":...})'
			is_error: true
		}
	}
	if parsed.prompt.len == 0 || parsed.description.len == 0 {
		return ToolResult{
			content:  'missing required argument: prompt and description'
			is_error: true
		}
	}

	mut a := ctx.agent or {
		return ToolResult{
			content:  'Agent tool: no agent context available'
			is_error: true
		}
	}

	// Resolve profile name. Default to 'coder' (mirrors upstream).
	profile_name := if parsed.subagent_type.len > 0 { parsed.subagent_type } else { 'coder' }
	// Validate the profile name; unknown types fall back to coder.
	profiles := default_profiles()
	if profile_name !in profiles {
		// Still let the model know it was an unknown type.
		return ToolResult{
			content:  'Unknown subagent_type "${profile_name}". Available: coder, explore, plan.'
			is_error: true
		}
	}

	// Resume is not supported in this build (spawn-and-forget, per the
	// PARITY_PLAN lock). If the model passed it, explain.
	if parsed.resume.len > 0 {
		return ToolResult{
			content:  'Resuming a prior subagent is not supported in this build. A fresh ${profile_name} subagent will be launched instead.'
			is_error: false
		}
	}

	// Spawn and run the subagent to completion.
	res := spawn_subagent(mut a, profile_name, parsed.prompt, a.non_interactive)

	if !res.ok {
		return ToolResult{
			content: 'subagent error (${res.profile_name}, agent_id ${res.agent_id}): ${res.err}'
			is_error: true
		}
	}

	// Format the handoff (mirrors upstream's foreground success shape).
	mut out := []string{}
	out << 'agent_id: ${res.agent_id}'
	out << 'actual_subagent_type: ${res.profile_name}'
	out << 'status: completed'
	out << ''
	out << '[summary]'
	out << res.result
	return ToolResult{
		content: out.join('\n')
	}
}
