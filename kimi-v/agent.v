// internal/agent/v
// Agent = LLM caller + tool dispatcher. The class is intentionally stateless
// w.r.t. session (matches the original `kimi-code` rule). You create one
// Agent per provider/model and reuse it across sessions.
module main

pub struct Agent {
pub:
	provider Provider
	system   string
pub mut:
	// Hard cap on think-act-observe turns. The original default is high
	// enough that genuine runaway loops still fail loudly.
	max_turns int = 32
	registry  ToolRegistry
	// When non-nil, the agent streams deltas as it receives them. Used by
	// the TUI; P0 single-shot mode ignores it.
	on_delta    ?fn (string) // regular content
	on_thinking ?fn (string) // reasoning/thinking content
	on_tool     ?fn (string, string) // (name, args)
	// Compaction callback: invoked when context is compacted. Args are
	// (estimated_tokens_before, estimated_tokens_after). The TUI uses
	// this to surface a system block.
	on_compact ?fn (int, int)
	// Cancellation channel: caller sends to this to abort an in-flight
	// step. The provider's read loop polls it; step() also selects on it
	// so it can return promptly. The runner should reset the channel at
	// the start of each turn (one-shot semantics, cap 1).
	cancel_ch chan int
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
	// Monotonic id for approval requests. Bumped per request so the TUI
	// can match a response back to a request even if multiple are queued.
	next_approval_id u64
}

pub fn new_agent(provider Provider, system string) Agent {
	return Agent{
		provider:         provider
		system:           system
		registry:         new_registry()
		cancel_ch:        chan int{cap: 1}
		context_window:   default_context_window
		compact_threshold: default_compact_threshold
		approval_ch:      chan ApprovalRequest{cap: 4}
		decision_ch:      chan ApprovalDecision{cap: 1}
		risky_tools:      default_risky_tools.clone()
		approved_tools:   []string{}
	}
}

pub fn (mut a Agent) attach_tool(t Tool) {
	a.registry.register(t)
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
	msgs << sess.messages

	return ChatRequest{
		model:       a.provider.model
		messages:    msgs
		tools:       a.registry.definitions()
		temperature: 0.0
		max_tokens:  4096
	}
}

// step runs a single LLM call and returns the resulting assistant message
// plus any tool calls the model emitted. Pure: doesn't touch the
//
// The channel is closed by the provider goroutine (it sends a
// `.end_of_stream` sentinel and then closes). We keep reading past
// `.finish` to capture the trailing `.usage` chunk.
pub fn (mut a Agent) step(sess Session) !StepResult {
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
							cb(ev.name, ev.arguments)
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
						result.finish = FinishEvent{
							reason:        ev.reason
							input_tokens:  usage_input
							output_tokens: usage_output
						}
						saw_finish = true
					}
					.end_of_stream {
						result.text = text_acc.join('')
						return result
					}
					.err_kind {
						return error('provider error: ${ev.err}')
					}
				}
			}
			<-a.cancel_ch {
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
		}
	}
	// Unreachable in practice — the select always returns from one of
	// its branches — but V requires a return here for control-flow
	// analysis. If we ever land here, the channel was closed without a
	// proper `.end_of_stream` sentinel; treat it as a clean end.
	return error('stream ended without sentinel')
}

pub struct StepResult {
pub mut:
	text       string
	tool_calls []ToolCall
	finish     FinishEvent
}
