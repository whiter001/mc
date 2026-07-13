// tools_skill.v — the `Skill` tool (parity with kimi-code's skill-tool).
//
// Lets the model invoke a discovered skill by name. When called, the tool
// looks up the skill in the catalog, expands its argument placeholders with
// the supplied `args`, and returns the (expanded) skill body as the tool
// result — which the model then follows as instructions. This is how skills
// get "loaded into context".
//
// The catalog is built once per session by the runner (discover_skills) and
// shared with the tool via the agent reference. We store the catalog on the
// Agent so the stateless Tool interface can reach it through ctx.agent.
module main

import json

// skill_catalog is stored on the Agent so tools can look skills up. We keep a
// pointer; the runner populates it before the loop starts.
pub struct SkillTool {
pub:
	agent &Agent
}

pub fn (t SkillTool) name() string {
	return 'Skill'
}

pub fn (t SkillTool) description() string {
	return 'Invoke a skill by name to load its instructions into context. ' +
		'Use this when the user references a skill, or when a task matches a skill\'s described use case. ' +
		'Pass the skill name and any arguments. Skills provide specialised, reusable workflows.'
}

pub fn (t SkillTool) parameters_schema() string {
	return '{"type":"object","properties":{"skill":{"type":"string","description":"The skill name to invoke"},"args":{"type":"string","description":"Optional arguments passed to the skill ($ARGUMENTS / $1 / $name placeholders)"}},"required":["skill"],"additionalProperties":false}'
}

struct SkillToolArgs {
	skill string
	args  string
}

pub fn (t SkillTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	parsed := json.decode(SkillToolArgs, args.raw) or {
		return ToolResult{
			content:  'invalid arguments: ${err.msg()} (expected {"skill":"...","args":"..."})'
			is_error: true
		}
	}
	if parsed.skill.len == 0 {
		return ToolResult{
			content:  'missing required argument: skill'
			is_error: true
		}
	}

	a := ctx.agent or {
		return ToolResult{
			content:  'Skill tool: no agent context available'
			is_error: true
		}
	}

	catalog := a.skills_catalog()
	if catalog.skills.len == 0 {
		return ToolResult{
			content:  'No skills are installed. Place a SKILL.md under ~/.kimi/skills/<name>/ or <cwd>/.kimi/skills/<name>/ to use skills.'
			is_error: true
		}
	}

	def := catalog.get(parsed.skill) or {
		// List available skills so the model can self-correct.
		mut names := []string{}
		for s in catalog.skills {
			names << s.name
		}
		avail := if names.len > 0 { names.join(', ') } else { '(none)' }
		return ToolResult{
			content:  'Skill "${parsed.skill}" not found. Available: ${avail}.'
			is_error: true
		}
	}

	// Expand placeholders with the supplied args.
	session_id := a.skill_session_id()
	expanded := expand_skill_parameters(def.content, parsed.args, def.dir, session_id, def.arguments)

	return ToolResult{
		content: '# Skill: ${def.name}\n\n${expanded}'
	}
}
