// tools_subagent_swarm.v — the `AgentSwarm` collaboration tool.
//
// Mirrors kimi-code's `AgentSwarm`: launches many subagents from one prompt
// template over a list of items, resumes a set of previously persisted
// subagent sessions — or both. Each subagent is a fresh in-process loop
// instance (or a resumed session) exactly like the `Agent` tool; the parent
// gets back one joined report listing every agent_id and status instead of
// one tool result per subagent.
module main

import json

// =============================================================================
// AgentSwarm (batch subagent dispatch)
// =============================================================================

// AgentSwarmTool launches multiple subagents from one prompt template,
// existing agent resumes, or both.
pub struct AgentSwarmTool {
pub:
	// The parent agent, used to inherit provider/model/cwd/approval
	// settings when spawning the subagents.
	agent &Agent
}

// name returns the tool identifier used in the registry and provider.
pub fn (t AgentSwarmTool) name() string {
	return 'AgentSwarm'
}

// description returns the human-readable description shown to the model.
pub fn (t AgentSwarmTool) description() string {
	base := 'Launch multiple subagents from one prompt template, existing agent resumes, or both.

Use AgentSwarm when many subagents should run the same kind of task over different inputs. The placeholder is exactly {{item}}. For example, with prompt_template set to "Review {{item}} for likely regressions." and items set to ["src/a.ts", "src/b.ts"], AgentSwarm launches two new subagents with those two concrete prompts. For a few differently-shaped tasks, make separate Agent calls in one message instead.

Use resume_agent_ids to continue subagents that already exist from earlier work, such as ones that failed or timed out: map each agent id to the prompt for that resumed subagent (usually "continue" if no extra information is needed). You may combine resume_agent_ids with items in the same call to resume existing subagents and launch new ones. Do not duplicate resumed work in items.

Each of these is enforced — a violation is rejected before any subagent starts: provide at least 2 items unless you pass resume_agent_ids; whenever items are present, prompt_template is required and must contain {{item}}; and the filled-in prompts must be distinct (two items that expand to the same prompt are rejected).

If AgentSwarm is called, that call must be the only tool call in the response.'
	types := build_subagent_type_lines()
	return '${base}\n\nAvailable agent types (pass via subagent_type):\n${types}'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t AgentSwarmTool) parameters_schema() string {
	return '{"type":"object","properties":{"prompt_template":{"type":"string","description":"Prompt template for each subagent. The {{item}} placeholder is replaced with each item value."},"items":{"type":"array","items":{"type":"string"},"description":"Values used to fill {{item}}. Each item launches one new subagent."},"subagent_type":{"type":"string","description":"Subagent type used for every subagent spawned from items; defaults to coder when omitted. Resumed subagents always keep their original type."},"resume_agent_ids":{"type":"object","additionalProperties":{"type":"string"},"description":"Map of existing subagent agent_id to the prompt used to resume that subagent. These resumed subagents are launched before new item-based subagents."},"run_in_background":{"type":"boolean","description":"If true, launch all subagents in the background and return immediately with the agent_ids; results are delivered as <background-agent-result> messages on later turns."}},"required":["prompt_template"],"additionalProperties":false}'
}

// AgentSwarmArgs is the parsed JSON input for the AgentSwarm tool.
struct AgentSwarmArgs {
	prompt_template   string            @[json: 'prompt_template']
	items             []string
	subagent_type     string            @[json: 'subagent_type']
	resume_agent_ids  map[string]string @[json: 'resume_agent_ids']
	run_in_background bool              @[json: 'run_in_background']
}

// execute validates the batch, then launches every subagent (resumed sessions
// first, item spawns after) either in the foreground or in the background.
pub fn (t AgentSwarmTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	parsed := json.decode(AgentSwarmArgs, args.raw) or {
		return ToolResult{
			content:  'invalid arguments: ${err.msg()} (expected {"prompt_template":..., "items":[...]})'
			is_error: true
		}
	}

	has_items := parsed.items.len > 0
	has_resumes := parsed.resume_agent_ids.len > 0

	// ── Validation. Mirrors upstream: every violation is rejected before any
	// subagent starts. ──
	if !has_items && !has_resumes {
		return ToolResult{
			content:  'provide at least 2 items unless you pass resume_agent_ids'
			is_error: true
		}
	}
	if has_items && parsed.items.len < 2 && !has_resumes {
		return ToolResult{
			content:  'provide at least 2 items'
			is_error: true
		}
	}
	if has_items && (parsed.prompt_template.len == 0 || !parsed.prompt_template.contains('{{item}}')) {
		return ToolResult{
			content:  'prompt_template is required and must contain {{item}} when items are present'
			is_error: true
		}
	}
	// Filled-in prompts must be distinct.
	if has_items {
		mut seen := map[string]bool{}
		for item in parsed.items {
			p := parsed.prompt_template.replace('{{item}}', item)
			if p in seen {
				return ToolResult{
					content:  'items expand to duplicate prompts; make each item produce a distinct prompt'
					is_error: true
				}
			}
			seen[p] = true
		}
	}
	// Validate the profile for item spawns up front (before any subagent
	// starts), same message as the Agent tool.
	profile_name := if parsed.subagent_type.len > 0 { parsed.subagent_type } else { 'coder' }
	if has_items {
		profiles := default_profiles()
		if profile_name !in profiles {
			return ToolResult{
				content:  'Unknown subagent_type "${profile_name}". Available: coder, explore, plan.'
				is_error: true
			}
		}
	}

	mut a := ctx.agent or {
		return ToolResult{
			content:  'AgentSwarm tool: no agent context available'
			is_error: true
		}
	}

	mut results := []SubagentResult{}

	// Resumed sessions first (upstream launches these before item spawns).
	for id, prompt in parsed.resume_agent_ids {
		sess := load_from(subagent_sessions_dir(), id) or {
			results << SubagentResult{
				agent_id:     id
				profile_name: profile_name
				ok:           false
				err:          'subagent not found: ${id}. The session may have been cleaned up or the id is wrong.'
			}
			continue
		}
		mut resumed_profile := sess.metadata['subagent_profile'] or { 'coder' }
		profiles := default_profiles()
		if resumed_profile !in profiles {
			resumed_profile = 'coder'
		}
		mut sess2 := sess
		sess2.append_user(prompt)
		results << run_or_launch(mut a, resumed_profile, mut sess2, parsed.run_in_background,
			a.non_interactive)
	}

	// Item-based spawns.
	for item in parsed.items {
		prompt := parsed.prompt_template.replace('{{item}}', item)
		mut sess := new_session(parent_cwd(a))
		sess.id = new_subagent_id()
		sess.append_user(prompt)
		results << run_or_launch(mut a, profile_name, mut sess, parsed.run_in_background,
			a.non_interactive)
	}

	if parsed.run_in_background {
		return format_swarm_background(results)
	}
	return format_swarm_result(results)
}

// run_or_launch runs a subagent either in the foreground (blocking) or in the
// background (goroutine + immediate launch result), depending on `background`.
fn run_or_launch(mut parent Agent, profile_name string, mut sess Session, background bool, non_interactive bool) SubagentResult {
	if background {
		return launch_background(mut parent, profile_name, mut sess, non_interactive)
	}
	return run_subagent(mut parent, profile_name, mut sess, non_interactive)
}

// format_swarm_result renders the joined foreground report: one line per
// subagent with its status and a one-line handoff preview. Handoffs are
// flattened + truncated so the parent's context stays lean.
fn format_swarm_result(results []SubagentResult) ToolResult {
	mut ok_count := 0
	mut fail_count := 0
	for r in results {
		if r.ok {
			ok_count++
		} else {
			fail_count++
		}
	}
	mut out := []string{}
	out << 'AgentSwarm completed: ${results.len} subagents (${ok_count} succeeded, ${fail_count} failed)'
	out << ''
	for r in results {
		status := if r.ok { 'completed' } else { 'failed' }
		out << '- ${r.agent_id} (${r.profile_name}): ${status}'
		if r.ok {
			out << '  [summary] ${one_line(r.result, 400)}'
		} else if r.timed_out {
			out << '  error: timed out after ${subagent_timeout_ms} ms; partial handoff: ${one_line(r.result, 400)}. You can resume it with resume="${r.agent_id}".'
		} else {
			out << '  error: ${one_line(r.err, 400)}'
		}
	}
	return ToolResult{
		content: out.join('\n')
	}
}

// format_swarm_background renders the immediate response for a background
// swarm: every agent_id plus a note that results arrive later.
fn format_swarm_background(results []SubagentResult) ToolResult {
	mut out := []string{}
	out << 'Launched ${results.len} subagent(s) in the background:'
	for r in results {
		if r.ok {
			out << '- ${r.agent_id} (${r.profile_name}): running'
		} else {
			out << '- ${r.agent_id} (${r.profile_name}): launch failed — ${one_line(r.err, 200)}'
		}
	}
	out << ''
	out << '[note] Results will be delivered to you as <background-agent-result> messages on later turns — check them with the TaskList tool in the meantime.'
	return ToolResult{
		content: out.join('\n')
	}
}

// one_line flattens a handoff/error to a single line (newlines become
// spaces) and truncates it, for compact swarm report entries.
fn one_line(s string, max int) string {
	flat := s.trim_space().replace('\n', ' ')
	if flat.len <= max {
		return flat
	}
	return flat[..max] + '…'
}
