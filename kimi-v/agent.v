// internal/agent/v
// Agent = LLM caller + tool dispatcher. The class is intentionally stateless
// w.r.t. session (matches the original `kimi-code` rule). You create one
// Agent per provider/model and reuse it across sessions.
module main

import time
import os
import sync

// AskOption is one selectable choice presented to the user.
pub struct AskOption {
pub:
	label   string // short label shown to the user
	description string // optional longer explanation
}

// AskRequest is sent by the agent when the model invokes AskUserQuestion.
// The TUI renders `question` + numbered `options` and waits for a choice.
pub struct AskRequest {
pub:
	id       u64
	question string
	header   string // short category tag (optional)
	options  []AskOption
	multi    bool // allow multiple selections (comma-separated)
}

// AskResult is the user's answer, sent back to the agent.
pub struct AskResult {
pub:
	id      u64
	ok      bool // false if the user declined to answer
	choices []string // selected option labels (or raw text)
}

// PlanOption is one approach the model can offer at ExitPlanMode so the
// user picks which one to execute.
pub struct PlanOption {
pub:
	label       string
	description string
}

// ExitPlanRequest is sent by the ExitPlanMode tool to surface the finalised
// plan to the user for approval. The TUI renders a plan-review modal with the
// plan text, the plan file path, and (optionally) a list of alternative
// approaches. The user answers with Approve / Reject / Reject-and-Exit /
// Revise(+feedback), which the TUI sends back on exit_plan_result_ch.
pub struct ExitPlanRequest {
pub:
	id      u64
	plan    string // plan file content (already read by the tool)
	path    string // plan file path (or '' if none)
	options []PlanOption // alternative approaches (may be empty)
}

// ExitPlanResult is the user's decision on an ExitPlanRequest.
pub struct ExitPlanResult {
pub:
	id               u64
	decision         string // 'approved' | 'rejected' | 'rejected_and_exit' | 'revise' | 'dismissed'
	selected_label   string // chosen option label when multiple approaches were offered
	feedback         string // user feedback when decision == 'revise'
}

// PlanModeState tracks whether the agent is currently in plan mode and where
// the in-progress plan file lives. Mirrors kimi-code's `PlanMode` service:
// entering plan mode opens a plan file the model writes to, and exiting
// deactivates the read-only guard so normal edits can proceed.
pub struct PlanModeState {
pub mut:
	is_active     bool
	plan_file_path string // absolute path to the plan .md file ('' if none)
	plan_id       string
	// Reminder bookkeeping: we re-inject the plan-mode system reminder every
	// few turns and on first entry. `injection_turns` counts assistant turns
	// since the last injection so we can refresh at a cadence.
	injection_turns int
}

// default_ask channels (unused placeholder to satisfy type visibility).


@[heap]
pub struct Agent {
pub:
	provider Provider
	system   string
pub mut:
	// Hard cap on think-act-observe turns. The original default is high
	// enough that genuine runaway loops still fail loudly.
	max_turns int = 32
	// Retries per step on transient provider errors (parity with
	// kimi-code's [loop_control] max_retries_per_step). Wired from
	// Config by the runner; cancellations are never retried.
	max_retries_per_step int = 10
	registry  ToolRegistry
	// When non-nil, the agent streams deltas as it receives them. Used by
	// the TUI; P0 single-shot mode ignores it.
	on_delta    ?fn (string) // regular content
	on_thinking ?fn (string) // reasoning/thinking content
	on_tool     ?fn (string, string, string) // (id, name, args)
	// Tool-result callback: invoked once per executed tool with its
	// outcome. Args are (id, name, is_error).
	on_tool_done ?fn (string, string, bool)
	// Compaction callback: invoked when context is compacted. Args are
	// (estimated_tokens_before, estimated_tokens_after). The TUI uses
	// this to surface a system block.
	on_compact ?fn (int, int)
	// Cancellation channel: caller sends to this to abort an in-flight
	// step. The provider's read loop polls it; step() also selects on it
	// so it can return promptly. The runner should reset the channel at
	// the start of each turn (one-shot semantics, cap 1).
	cancel_ch chan int
	// Steer channel: the TUI sends the user's current input box contents
	// here during a streaming turn. step() selects on it alongside the
	// chunk channel; when a steer message arrives, it's appended to the
	// session as a new user message and step() returns so the agent
	// loop can call step() again on the updated session. The user
	// doesn't have to interrupt + retype — they can redirect the agent
	// mid-turn. cap 4 so multiple keystrokes can queue if the agent is
	// busy with tool execution.
	steer_ch chan string
	// Compaction config. context_window = model's max input tokens;
	// compact_threshold = fraction above which we trigger compaction.
	// Defaults: 128k window, 0.6 threshold (self-use aggressive).
	context_window    int = default_context_window
	compact_threshold f32 = default_compact_threshold
	// Approval flow: when a risky tool is called, the agent sends an
	// ApprovalRequest on approval_ch and blocks on decision_ch waiting
	// for the user's answer. The TUI owns the other ends.
	approval_ch  chan ApprovalRequest
	decision_ch  chan ApprovalDecision
	// Tools that always require approval. Defaults to bash + write_file
	// + edit_file + web_fetch. Configurable; the TUI sets this from its
	// own config (which may overlay permissions.toml in a follow-up).
	risky_tools []string = default_risky_tools
	// Tools the user has chosen "always allow" for in the current
	// session. Combined with `risky_tools` to short-circuit the approval
	// modal for trusted tools (e.g. "always allow read_file"). Sensitive
	// patterns (rm -rf, sudo, /etc/*) still re-prompt regardless.
	approved_tools []string
	// Permission rules from config.toml [[permission.rules]]. Evaluated
	// before the built-in risky-tools logic: deny always wins, allow
	// short-circuits the modal, ask forces it. Set by the runner from
	// cfg.permission_rules.
	permission_rules []PermissionRule
	// YOLO mode: skip approval entirely for the rest of the session.
	// Toggled at runtime via `/yolo` slash. Sensitive patterns still
	// re-prompt as a backstop against the most obvious foot-guns.
	yolo bool
	// Monotonic id for approval requests. Bumped per request so the TUI
	// can match a response back to a request even if multiple are queued.
	next_approval_id u64
	// Monotonic id for ExitPlanMode requests (parallel to approval ids).
	next_exit_plan_id u64
	// Session todo list (parity with upstream TodoList tool). The model
	// manages it via TodoWrite/TodoRead; it lives on the Agent because the
	// Agent is the per-session singleton and the Tool interface is
	// stateless by design.
	todos []TodoItem
	// AskUserQuestion flow: when the model calls the AskUserQuestion tool,
	// the agent sends an AskRequest on ask_ch and blocks on ask_result_ch
	// waiting for the user's choice. The TUI owns the other ends (mirrors
	// the approval flow).
	ask_ch       chan AskRequest
	ask_result_ch chan AskResult
	// Plan-mode state. When active, the agent bounds the model to read-only
	// work plus writes to the plan file. EnterPlanMode/ExitPlanMode tools
	// flip it; the loop enforces the read-only guard.
	plan        PlanModeState
	// ExitPlanMode flow: when the model calls ExitPlanMode, the tool sends
	// an ExitPlanRequest on exit_plan_ch and blocks on exit_plan_result_ch
	// waiting for the user's Approve / Reject / Revise decision. The TUI
	// owns the other ends (mirrors the approval flow).
	exit_plan_ch       chan ExitPlanRequest
	exit_plan_result_ch chan ExitPlanResult
	// Non-interactive mode flag: when true (e.g. `kimi -p`), plan-mode
	// approvals auto-pass so the agent never blocks waiting for a UI that
	// isn't there. Set by the runner / main.
	non_interactive bool
	// Skill catalog discovered at session start. The `Skill` tool looks
	// skills up here; the runner populates it via set_skills().
	skills SkillCatalog
	// Hook engine for lifecycle hooks. The runner wires it from config.toml
	// [[hooks]]; the agent loop fires events through it. Empty engine = no
	// hooks (all events are no-ops).
	hooks HookEngine
	// Session id, surfaced to skills ($KIMI_SESSION_ID) and hooks
	// (session_id in the payload). Set by the runner.
	session_id string
	// MCP client connections, keyed by server name. Populated at session
	// start from Config.mcp_servers via connect_all_mcp_servers. The namespaced
	// McpTool delegates its calls here (see tools_mcp.v) — the mcp.Client must
	// be reachable from a non-mut Tool.execute, hence it lives on the Agent
	// rather than inside the stateless tool value.
	mcp_clients map[string]&McpClient
	// Background subagent support. When the model calls Agent with
	// run_in_background=true, a goroutine runs the subagent and delivers its
	// result as a <background-agent-result> user message on a later turn via
	// bg_results_ch. The runner drains that channel at the top of each turn
	// (see Agent.drain_background_results). bg_tasks holds the live status for
	// the TaskList tool; it's guarded by bg_mutex because the finishing
	// goroutine writes it from another thread.
	bg_results_ch chan BackgroundAgentResult
	bg_tasks      map[string]BackgroundTask
	bg_mutex      sync.Mutex
	// Wall-clock deadline (unix ms) after which the run() loop stops making
	// turns and returns what it has. 0 = no deadline. Set by the subagent
	// runner to enforce the subagent timeout; the check lives at the top of
	// each loop iteration in run().
	deadline_ms i64
	// Session goal (parity with kimi-code's Goal system). Created by the
	// CreateGoal tool; while a goal is `.active` the run() loop keeps the
	// session going with a continuation prompt until the model adjudicates
	// it via UpdateGoal or a budget set with SetGoalBudget is reached.
	goal ?GoalState
	// Goal-change callback: invoked with (badge, detail) whenever the goal
	// state changes (create / resume / complete / blocked / budget-stop /
	// per-goal-turn count). The TUI wires this to its status channel;
	// '' badge means no goal.
	on_goal_change ?fn (string, string)
	// Session cron jobs (parity with kimi-code's cron tool). Managed by the
	// CronCreate/CronList/CronDelete tools; persisted per session under
	// <config-dir>/cron/<session-id>.json. The TUI scheduler polls this
	// list and injects due jobs as user turns. Restored on session load
	// via restore_cron_tasks.
	cron_tasks []CronTask
}

// new_agent creates an Agent with default channels, thresholds, and an
// empty tool registry. The caller must register tools and wire callbacks
// before running the loop.
pub fn new_agent(provider Provider, system string) Agent {
	return Agent{
		provider:         provider
		system:           system
		registry:         new_registry()
		cancel_ch:        chan int{cap: 1}
		steer_ch:         chan string{cap: 4}
		context_window:   default_context_window
		compact_threshold: default_compact_threshold
		approval_ch:      chan ApprovalRequest{cap: 4}
		decision_ch:      chan ApprovalDecision{cap: 1}
		risky_tools:      default_risky_tools.clone()
		approved_tools:   []string{}
		permission_rules: []PermissionRule{}
		yolo:             false
		ask_ch:           chan AskRequest{cap: 4}
		ask_result_ch:    chan AskResult{cap: 1}
		plan:             PlanModeState{}
		exit_plan_ch:     chan ExitPlanRequest{cap: 4}
		exit_plan_result_ch: chan ExitPlanResult{cap: 1}
		non_interactive:  false
		skills:           SkillCatalog{ skills: []SkillDefinition{} }
		hooks:            new_hook_engine('', '')
		session_id:       ''
		mcp_clients:      map[string]&McpClient{}
		bg_results_ch:    chan BackgroundAgentResult{cap: 32}
		bg_tasks:         map[string]BackgroundTask{}
		bg_mutex:         sync.Mutex{}
		deadline_ms:      i64(0)
	}
}

// set_skills installs the discovered skill catalog on the agent (called by
// the runner before the loop starts).
pub fn (mut a Agent) set_skills(catalog SkillCatalog) {
	a.skills = catalog
}

// skills returns the agent's skill catalog (used by the Skill tool).
pub fn (a Agent) skills_catalog() SkillCatalog {
	return a.skills
}

// skill_session_id returns the session id for skill ${KIMI_SESSION_ID}
// expansion (best-effort; '' when not set).
pub fn (a Agent) skill_session_id() string {
	return a.session_id
}

// set_hooks installs the hook engine (built from config [[hooks]]).
pub fn (mut a Agent) set_hooks(engine HookEngine) {
	a.hooks = engine
}

// hooks_engine returns the agent's hook engine (used by the loop).
pub fn (a Agent) hooks_engine() HookEngine {
	return a.hooks
}

// attach_tool registers a tool on the agent so the model can invoke it.
pub fn (mut a Agent) attach_tool(t Tool) {
	a.registry.register(t)
}

// ── Plan-mode helpers ──────────────────────────────────────────────────────
// These mirror kimi-code's `PlanMode` service. We keep them as Agent methods
// so the EnterPlanMode/ExitPlanMode tools (which hold `&Agent`) can flip the
// state directly, and the loop can consult `a.plan.is_active` for the
// read-only guard.

// plan_file_dir resolves where plan files are stored. We use the user's
// config dir (`<config-dir>/plans`) so plans persist across sessions; when
// that's unavailable we fall back to a `plan/` dir inside the cwd.
fn plan_file_dir() string {
	cfg := config_dir()
	return os.join_path(cfg, 'plans')
}

// enter_plan_mode turns plan mode on and opens a fresh plan file. Returns the
// plan file path (always non-empty on success). If already active, it's a
// no-op that returns the current path.
pub fn (mut a Agent) enter_plan_mode() string {
	if a.plan.is_active {
		return a.plan.plan_file_path
	}
	a.plan.is_active = true
	a.plan.plan_id = 'plan-${time.now().unix_milli()}'
	dir := plan_file_dir()
	os.mkdir_all(dir) or {}
	path := os.join_path(dir, '${a.plan.plan_id}.md')
	a.plan.plan_file_path = path
	a.plan.injection_turns = 0
	// Seed an empty plan file so the model can Edit it (Edit needs an
	// existing target).
	os.write_file(path, '') or {}
	return path
}

// exit_plan_mode turns plan mode off and returns the plan file path that was
// active (or '' if none). Safe to call when not active.
pub fn (mut a Agent) exit_plan_mode() string {
	prev := a.plan.plan_file_path
	a.plan.is_active = false
	a.plan.plan_file_path = ''
	a.plan.plan_id = ''
	a.plan.injection_turns = 0
	return prev
}

// plan_data reads the current plan file content. Returns ('', true) when plan
// mode is inactive or no file path is set; otherwise the content and ok=false.
pub fn (a Agent) plan_data() (string, bool) {
	if !a.plan.is_active || a.plan.plan_file_path.len == 0 {
		return '', true
	}
	content := os.read_file(a.plan.plan_file_path) or {
		return '', false
	}
	return content, false
}

// build_request constructs the ChatRequest from the session messages plus
// the registered tool definitions. A leading system message is inserted if
// `a.system` is non-empty.
pub fn (a Agent) build_request(sess Session) ChatRequest {
	mut msgs := []Message{cap: sess.messages.len + 1}
	if a.system.len > 0 {
		msgs << Message{
			role:    .system
			content: a.system
		}
	}
	// When plan mode is active, inject (or re-inject) the plan-mode
	// reminder as a system message. We re-inject on a cadence so the
	// read-only invariant stays visible across long planning sessions.
	if a.plan.is_active {
		reminder := plan_mode_reminder(a.plan.plan_file_path)
		msgs << Message{
			role:    .system
			content: reminder
		}
	}
	// Inject the available-skills list so the model can auto-invoke them
	// via the Skill tool (parity with kimi-code's skill prompt injection).
	skills_hint := a.skills_prompt()
	if skills_hint.len > 0 {
		msgs << Message{
			role:    .system
			content: skills_hint
		}
	}
	msgs << sess.messages

	return ChatRequest{
		model:       a.provider.model
		messages:    msgs
		tools:       a.registry.definitions()
		temperature: 0.0
		max_tokens:  4096
	}
}

// plan_mode_reminder returns the system reminder shown to the model while plan
// mode is active. Mirrors kimi-code's plan-mode injection (full variant).
fn plan_mode_reminder(plan_file_path string) string {
	footer := if plan_file_path.len > 0 {
		'\n\nPlan file: ${plan_file_path}'
	} else {
		''
	}
	body := 'Plan mode is active. You MUST NOT make any edits (with the exception of the current plan file) or otherwise make changes to the system unless a tool request is explicitly approved. Prefer read-only tools. Use Bash only when needed; Bash follows the normal permission mode and rules. This supersedes any other instructions you have received.

Workflow:
  1. Understand — explore the codebase with glob, grep, read_file.
  2. Design — converge on the best approach; consider trade-offs but aim for a single recommendation.
  3. Review — re-read key files to verify understanding.
  4. Write Plan — modify the plan file with write_file or edit_file. If it does not exist yet, create it with write_file first.
  5. Exit — call ExitPlanMode for user approval.

When the plan offers multiple approaches, pass them as the `options` parameter when calling ExitPlanMode so the user can select which approach to execute.
Your turn must end with either AskUserQuestion (to clarify requirements or preferences) or ExitPlanMode (to request plan approval). Do NOT end your turn any other way.
Never ask about plan approval via text or AskUserQuestion.'
	return body + footer
}

// skills_prompt builds the system-prompt fragment that advertises the
// available skills to the model, so it can auto-invoke them via the Skill
// tool. Returns '' when no skills are installed. Parity with kimi-code's
// skill prompt injection (only invokable skills are advertised).
fn (a Agent) skills_prompt() string {
	cat := a.skills
	if cat.skills.len == 0 {
		return ''
	}
	mut lines := []string{}
	lines << '# Available Skills'
	lines << 'The following skills are installed and can be invoked with the Skill tool:'
	for s in cat.list_invokable() {
		mut entry := '- ${s.name}: ${s.description}'
		if s.when_to_use.len > 0 {
			entry += ' (use when: ${s.when_to_use})'
		}
		lines << entry
	}
	return lines.join('\n')
}

// step runs a single LLM call and returns the resulting assistant message
// plus any tool calls the model emitted. Pure: doesn't touch the session
// directly (the caller appends the result).
//
// The channel is closed by the provider goroutine (it sends a
// `.end_of_stream` sentinel and then closes). We keep reading past
// `.finish` to capture the trailing `.usage` chunk.
//
// During a streaming turn the user can press Ctrl-S to inject a new
// user message ("steer"). We select on a.steer_ch alongside the chunk
// channel; on a steer we append it to `sess` and return immediately
// so the main loop can call step() again with the updated history.
// cap 4 on the channel lets multiple steers queue during tool exec.
pub fn (mut a Agent) step(mut sess Session) !StepResult {
	req := a.build_request(sess)
	ch := chan ChatEvent{cap: 32}

	go a.provider.chat(req, ch, a.cancel_ch)

	mut result := StepResult{
		tool_calls: []ToolCall{}
		finish:     FinishEvent{
			reason: .unknown
		}
	}
	mut text_acc := []string{}
	// Pending usage arrives in a separate chunk after finish_reason.
	// We patch it onto the finish event when we see it.
	mut usage_input := 0
	mut usage_output := 0
	mut saw_finish := false

	// The select below has receive-only branches on `a.steer_ch` and
	// `a.cancel_ch` that are typically empty (steer is only written by the
	// TUI on Ctrl-S; cancel is written by the TUI's cancel watcher on
	// Ctrl-C). In `-p` mode steer_ch has no writer at all. V 0.5.x's
	// `select` is buggy: when any branch is a bare receive on a channel
	// that will never deliver, the runtime fails to pick the other ready
	// branches and the whole select hangs forever — even ones with
	// buffered values sitting in them.
	//
	// The 1ms timeout case below is the documented workaround. It forces
	// select to re-evaluate the channel set ~1000×/sec so that ready
	// branches (the chunk channel `ch`) get a chance to fire. The
	// overhead is negligible (1ms of idle is invisible to the user) and
	// it's strictly correct — every other branch still wins when it has
	// a value, including the steer/cancel ones. Same pattern as
	// tui_loop.v:run_tui's main loop and tui_loop.v:299's cancel-watcher
	// (the latter has a comment on this V gotcha).
	for {
		select {
			ev := <-ch {
				match ev.kind {
					.delta {
						text_acc << ev.content
						if cb := a.on_delta {
							cb(ev.content)
						}
					}
					.thinking {
						if cb := a.on_thinking {
							cb(ev.thinking)
						}
					}
					.tool_call {
						result.tool_calls << ToolCall{
							id:        ev.id
							name:      ev.name
							arguments: ev.arguments
						}
						if cb := a.on_tool {
							cb(ev.id, ev.name, ev.arguments)
						}
					}
					.usage {
						usage_input = ev.input_tokens
						usage_output = ev.output_tokens
						if saw_finish {
							result.finish = FinishEvent{
								reason:        result.finish.reason
								input_tokens:  usage_input
								output_tokens: usage_output
							}
						}
					}
					.finish {
						// Usage may arrive on the finish event itself
						// (Anthropic provider) or as a separate .usage event
						// (OpenAI provider); prefer whichever is non-zero.
						fin_input := if ev.input_tokens > 0 { ev.input_tokens } else { usage_input }
						fin_output := if ev.output_tokens > 0 { ev.output_tokens } else { usage_output }
						result.finish = FinishEvent{
							reason:        ev.reason
							input_tokens:  fin_input
							output_tokens: fin_output
						}
						saw_finish = true
					}
					.end_of_stream {
						result.text = text_acc.join('')
						return result
					}
					.err_kind {
						// Surface as ProviderError so the loop's retry
						// logic can consult `retryable` (429 / 5xx /
						// connection failures → retry; the rest → fail).
						return ProviderError{
							message:   ev.err
							kind:      'provider_error'
							retryable: ev.retryable
						}
					}
				}
			}
			steer := <-a.steer_ch {
				// Mid-turn user intervention. Append the new user
				// message to the session and return whatever we've
				// accumulated so far. The main loop will call step()
				// again; the next LLM call will see the steered
				// message in its history. The model will likely
				// abandon the current response (we don't surface a
				// "the user interrupted you" prefix; the model
				// notices the new user message on its own).
				sess.append_user(steer)
				result.text = text_acc.join('')
				return result
			}
			_ := <-a.cancel_ch {
				// Cancellation requested. Spawn a drainer so the provider
				// goroutine can keep writing to `ch` (and close it) without
				// blocking on a full buffered channel — the agent has
				// already stopped reading. The drainer exits when the
				// channel is closed.
				go fn (ch chan ChatEvent) {
					for {
						_ := <-ch or { return }
					}
				}(ch)
				return error('cancelled')
			}
			1 * time.millisecond {
				// V 0.5.x select workaround — see the comment above the
				// for loop. With bare receive branches on steer_ch and
				// cancel_ch, the runtime never picks the chunk branch on
				// its own. This 1ms tick re-polls the channel set so the
				// chunk branch fires promptly when SSE events arrive.
			}
		}
	}
	// Unreachable in practice — the select always returns from one of
	// its branches — but V requires a return here for control-flow
	// analysis. If we ever land here, the channel was closed without a
	// proper `.end_of_stream` sentinel; treat it as a clean end.
	return error('stream ended without sentinel')
}

// StepResult is the output of one agent step: the assistant text, any
// tool calls requested by the model, and finish metadata including token
// usage.
pub struct StepResult {
pub mut:
	text       string
	tool_calls []ToolCall
	finish     FinishEvent
}
