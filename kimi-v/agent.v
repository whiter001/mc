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
	on_delta ?fn (string)
	on_tool  ?fn (string, string) // (name, args)
}

pub fn new_agent(provider Provider, system string) Agent {
	return Agent{
		provider: provider
		system:   system
		registry: new_registry()
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

	go a.provider.chat(req, ch)

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
		ev := <-ch or { break }
		match ev.kind {
			.delta {
				text_acc << ev.content
				if cb := a.on_delta {
					cb(ev.content)
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
				break
			}
			.err_kind {
				return error('provider error: ${ev.err}')
			}
		}
	}

	result.text = text_acc.join('')
	return result
}

pub struct StepResult {
pub mut:
	text       string
	tool_calls []ToolCall
	finish     FinishEvent
}
