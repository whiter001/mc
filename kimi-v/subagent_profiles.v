// subagent_profiles.v — built-in subagent profiles (coder / explore / plan).
//
// Mirrors kimi-code's `DEFAULT_AGENT_PROFILES` for the three collaboration
// subagents. Each profile carries:
//   - name   : passed via `subagent_type` to the `Agent` tool
//   - description + when_to_use : surfaced to the model in the Agent tool
//                                description so it can pick the right one
//   - system : the subagent's system prompt (role framing + constraints)
//   - tools  : the tool names the subagent is allowed to use. The subagent
//              gets a fresh registry restricted to these names, so e.g.
//              `explore`/`plan` never receive write/edit tools.
//
// Design note: kimi-code models subagents as full Agent instances that
// inherit the parent's model + cwd but run their own loop with a trimmed
// toolset. We follow the same shape — spawn_subagent() builds a new Agent
// from the parent's provider/model, applies the profile's system prompt and
// tool allow-list, and runs its own loop. The parent only ever sees the
// subagent's final text (the "handoff").
module main

// SubagentProfile describes one built-in collaboration subagent.
pub struct SubagentProfile {
pub:
	name         string
	description  string
	when_to_use  string
	// System prompt for the subagent. Appended after the shared
	// role-framing text so every subagent knows it is a subordinate.
	system       string
	// Tool names the subagent may use. Looked up against the parent's
	// tool registry; unknown names are skipped.
	tools        []string
}

// subagent_role_framing is the shared preamble every subagent gets. It tells
// the model it is a subordinate whose only output is its final message —
// matching kimi-code's `roleAdditional` block in each profile YAML.
const subagent_role_framing = 'You are now running as a subagent. All the `user` messages are sent by the main agent. The main agent cannot see your context, it can only see your last message when you finish the task. You must treat the parent agent as your caller. Do not directly ask the end user questions. If something is unclear, explain the ambiguity in your final summary to the parent agent.

Your final message is the entire handoff — the parent sees nothing else from your run. Make it technically complete: what you changed and why, the path of every file you touched, how you verified the change (tests or commands run, with results), and anything left undone or worth follow-up. A final message of only a sentence or two is treated as too brief and sent back to you for expansion, costing an extra turn.'

// default_profiles returns the three built-in subagent profiles. The
// descriptions mirror upstream's `whenToUse` copy so the model's Agent-tool
// prompt stays faithful.
fn default_profiles() map[string]SubagentProfile {
	mut m := map[string]SubagentProfile{}
	m['coder'] = SubagentProfile{
		name:        'coder'
		description: 'Specialized in software engineering work'
		when_to_use: 'Use this agent for non-trivial software engineering work that may require reading files, editing code, running commands, and returning a compact but technically complete summary to the parent agent.'
		system: subagent_role_framing + '

You are a software engineering subagent. You have full file-editing and shell access. Read files before editing them. Verify any change you make (run tests or the relevant commands and report the results). Return a technically complete handoff.'
		tools: ['read_file', 'write_file', 'edit_file', 'bash', 'glob', 'grep',
			'web_fetch', 'web_search']
	}
	m['explore'] = SubagentProfile{
		name:        'explore'
		description: 'Fast agent for exploring codebases'
		when_to_use: 'Fast agent specialized for exploring codebases. Use this when you need to quickly find files by patterns, search code for keywords, or answer questions about the codebase. Prefer launching multiple explore agents concurrently when investigating independent questions.'
		system: subagent_role_framing + '

You are a codebase exploration specialist. Your role is EXCLUSIVELY to search, read, and analyze existing code and resources. You do NOT have access to file editing tools.

Your strengths:
- Rapidly finding files using glob patterns
- Searching code and text with powerful regex patterns
- Reading and analyzing file contents
- Running read-only shell commands (git log, git diff, ls, find, etc.)

Guidelines:
- Use Glob for broad file pattern matching. Prefer patterns with a literal anchor (extension or subdirectory).
- Use Grep for searching file contents with regex.
- Use Read when you know the specific file path.
- Use Bash ONLY for read-only operations (ls, git status, git log, git diff, find).
- NEVER use Bash for any file creation or modification commands.
- Use web_search / web_fetch when a question needs external context.
- Adapt your search depth based on the thoroughness level specified by the caller.
- Spawn multiple parallel tool calls for grepping and reading files to maximize speed.

Complete the search request efficiently and report your findings clearly in a structured format.'
		tools: ['read_file', 'bash', 'glob', 'grep', 'web_fetch', 'web_search']
	}
	m['plan'] = SubagentProfile{
		name:        'plan'
		description: 'Read-only planning agent'
		when_to_use: 'Use this agent when the parent agent needs a step-by-step implementation plan, key file identification, and architectural trade-off analysis before code changes are made.'
		system: subagent_role_framing + '

Before designing your implementation plan, consider whether you fully understand the codebase areas relevant to the task. If not, recommend the parent agent to use the explore agent to investigate key questions first. In your response, clearly state:
1. What you already know from the information provided
2. What questions remain unanswered that would benefit from explore agent investigation
3. Your implementation plan (either preliminary if questions remain, or final if sufficient context exists)

You are a read-only planning agent: you can read and search files and consult the web, but you have no shell and no file-editing tools. Your deliverable is the plan itself, returned as your final message.'
		tools: ['read_file', 'glob', 'grep', 'web_fetch', 'web_search']
	}
	return m
}
