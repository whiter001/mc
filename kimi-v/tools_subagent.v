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

// AgentTool launches a subagent to handle a delegated task.
pub struct AgentTool {
pub:
	// The parent agent, used to inherit provider/model/cwd/approval
	// settings when spawning the subagent.
	agent &Agent
}

// name returns the tool identifier used in the registry and provider.
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

// description returns the human-readable description shown to the model.
pub fn (t AgentTool) description() string {
	base := 'Launch a subagent to handle a task. The subagent runs as a same-process loop instance with its own context. Delegating also keeps the bulk of intermediate file contents out of your own context — you get a conclusion back instead of a pile of dumps.

Writing the prompt:
- The subagent starts with zero context — it has not seen this conversation. Brief it like a colleague who just walked into the room: state the goal, list what you already know, hand over the specifics.
- Lookups (read this file, run that test): put the exact path or command in the prompt. The subagent should not have to search for things you already know.
- Investigations (figure out X, find why Y): give the question, not prescribed steps — fixed steps become dead weight when the premise is wrong.
- Do not delegate understanding. If the task hinges on a file path or line number, find it yourself first and write it into the prompt.

Usage notes:
- A subagent\'s result is only visible to you, not to the user. When the user needs to see what a subagent produced, summarize the relevant parts yourself in your own reply.
- Pass run_in_background to launch the subagent on a separate goroutine: the tool returns immediately with the agent_id and the result is delivered as a <background-agent-result> message on a later turn (check TaskList for status).
- Pass resume to continue a previously persisted subagent session instead of starting a fresh one.

When NOT to use Agent: skip delegation for trivial work you can do directly — reading a file whose path you already know, searching a small known set of files, or any task that takes only a step or two. Delegation has a context-handoff cost; it pays off only when the task is substantial enough to outweigh it.'
	types := build_subagent_type_lines()
	return '${base}\n\nAvailable agent types (pass via subagent_type):\n${types}'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t AgentTool) parameters_schema() string {
	return '{"type":"object","properties":{"prompt":{"type":"string","description":"Full task prompt for the subagent"},"description":{"type":"string","description":"Short task description (3-5 words) for display"},"subagent_type":{"type":"string","description":"One of: coder, explore, plan. Defaults to coder when omitted."},"resume":{"type":"string","description":"Optional agent ID to resume instead of creating a new instance. When set, do not also pass subagent_type."},"run_in_background":{"type":"boolean","description":"If true, launch in background and return immediately with the agent_id; the result is delivered as a <background-agent-result> message on a later turn. Call TaskList to check status."}},"required":["prompt","description"],"additionalProperties":false}'
}

// AgentToolArgs is the parsed JSON input for the Agent tool.
struct AgentToolArgs {
	prompt         string
	description    string
	subagent_type  string @[json: 'subagent_type']
	resume         string
	run_in_background bool @[json: 'run_in_background']
}

// execute resolves the profile, spawns the subagent, and returns its handoff.
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

	// Resume path: continue a previously persisted subagent session. The
	// profile is recovered from the session metadata (falling back to the
	// passed subagent_type, then coder).
	if parsed.resume.len > 0 {
		if parsed.subagent_type.len > 0 {
			return ToolResult{
				content:  'do not pass subagent_type when resuming — the profile is restored from the saved session'
				is_error: true
			}
		}
		sess := load_from(subagent_sessions_dir(), parsed.resume) or {
			return ToolResult{
				content:  'subagent not found: ${parsed.resume}. The session may have been cleaned up or the id is wrong.'
				is_error: true
			}
		}
		mut profile_name := sess.metadata['subagent_profile'] or { 'coder' }
		profiles := default_profiles()
		if profile_name !in profiles {
			profile_name = 'coder'
		}
		mut sess2 := sess
		sess2.append_user(parsed.prompt)
		if parsed.run_in_background {
			return format_background_launch(launch_background(mut a, profile_name, mut sess2,
				a.non_interactive))
		}
		return format_subagent_result(run_subagent(mut a, profile_name, mut sess2, a.non_interactive))
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

	// Background launch: return immediately with the agent_id; the result is
	// delivered as a <background-agent-result> message on a later turn.
	if parsed.run_in_background {
		mut sess := new_session(parent_cwd(a))
		sess.id = new_subagent_id()
		sess.append_user(parsed.prompt)
		return format_background_launch(launch_background(mut a, profile_name, mut sess, a.non_interactive))
	}

	// Spawn and run the subagent to completion.
	res := spawn_subagent(mut a, profile_name, parsed.prompt, a.non_interactive)
	return format_subagent_result(res)
}

// format_subagent_result renders a completed subagent handoff for the model,
// mirroring upstream's foreground result shape. Timeouts are reported as an
// error carrying the partial handoff.
fn format_subagent_result(res SubagentResult) ToolResult {
	if !res.ok {
		if res.timed_out {
			return ToolResult{
				content: 'agent_id: ${res.agent_id}\nactual_subagent_type: ${res.profile_name}\nstatus: timed_out\n\n[note] The subagent hit the ${subagent_timeout_ms} ms wall-clock timeout. Its partial handoff so far:\n\n${res.result}\n\nYou can resume it with resume="${res.agent_id}" to continue where it left off.'
				is_error: true
			}
		}
		return ToolResult{
			content: 'subagent error (${res.profile_name}, agent_id ${res.agent_id}): ${res.err}'
			is_error: true
		}
	}

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

// format_background_launch renders the immediate response for a background
// subagent launch: the agent_id plus a note that the result arrives later.
fn format_background_launch(res SubagentResult) ToolResult {
	mut out := []string{}
	out << 'agent_id: ${res.agent_id}'
	out << 'actual_subagent_type: ${res.profile_name}'
	out << 'status: running'
	out << ''
	out << '[note] Subagent ${res.agent_id} is running in the background. Its result will be delivered to you as a <background-agent-result> message on a later turn — check it with the TaskList tool in the meantime.'
	return ToolResult{
		content: out.join('\n')
	}
}
