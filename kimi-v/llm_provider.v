// internal/llm/provider.v
// The Provider interface. Concrete providers (OpenAI-compat, Anthropic, ...)
// implement `chat()`.
module main

// Provider is the abstract LLM backend. Each provider owns its API base URL,
// authentication, and wire format.
//
// Implementations should:
//   - push ChatEvents into `out` in order
//   - close `out` exactly once when done (success or failure)
//   - never panic; report errors via the .err variant
//   - poll `cancel_ch` (non-blocking) at safe points — when a value is
//     received, stop reading and exit promptly without sending the
//     `.end_of_stream` sentinel. The caller is responsible for draining
//     any buffered events before discarding the channel.
pub interface Provider {
	name     string
	model    string
	api_base string
	api_key  string
	chat(req ChatRequest, out chan ChatEvent, cancel_ch chan int) !
}
