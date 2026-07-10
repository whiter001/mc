// internal/llm/types.v
// Common types shared across LLM providers.
module main

// -----------------------------------------------------------------------------
// Roles and messages
// -----------------------------------------------------------------------------

pub enum Role {
	system
	user
	assistant
	tool
}

pub fn (r Role) str() string {
	return match r {
		.system { 'system' }
		.user { 'user' }
		.assistant { 'assistant' }
		.tool { 'tool' }
	}
}

// A message in the conversation. The wire form is decided by each Provider;
// this struct is the canonical in-process representation.
pub struct Message {
pub:
	role    Role
	content string
	// Set only when role == .assistant and the model emitted tool calls.
	tool_calls []ToolCall
	// Set only when role == .tool (the result of a tool execution).
	tool_call_id string
	// Optional name for tool/system messages (used by some providers).
	name string
}

// A tool call emitted by the model. `arguments` is a JSON string so we can
// stream partial tool calls (the OpenAI protocol allows arguments to grow
// incrementally across several SSE events).
pub struct ToolCall {
pub:
	id        string
	name      string
	arguments string
}

// -----------------------------------------------------------------------------
// Tool definitions (what we tell the model it can call)
// -----------------------------------------------------------------------------

pub struct ToolDef {
pub:
	name        string
	description string
	// JSON Schema for the parameters object, as a string. Providers usually
	// take it verbatim. Keeping it as `string` avoids forcing every provider
	// to know how to re-encode it.
	parameters string
}

// -----------------------------------------------------------------------------
// Request and streaming events
// -----------------------------------------------------------------------------

pub struct ChatRequest {
pub:
	model       string
	messages    []Message
	tools       []ToolDef
	temperature f32 = 0.0
	max_tokens  int = 4096
	// Optional provider-specific hints (e.g. prompt cache key, stop sequences).
	extra map[string]string
}

// ChatEvent is what flows through the provider's output channel.
// We use an int tag (rather than a payload-bearing enum) because V's
// enum-with-payload match syntax varies across versions; a flat struct
// keeps the consumer loop trivially portable.
pub struct ChatEvent {
pub:
	kind ChatEventKind
	// delta fields
	content string
	// tool_call fields
	id        string
	name      string
	arguments string
	index     int
	// finish fields
	reason        FinishReason
	input_tokens  int
	output_tokens int
	// err
	err string
}

pub enum ChatEventKind {
	delta
	tool_call
	finish
	usage
	err_kind
	end_of_stream
}

pub struct DeltaEvent {
pub:
	content string
}

pub struct ToolCallEvent {
pub:
	index int
	id    string
	name  string
	// Partial arguments JSON; the consumer should accumulate by `index`.
	arguments string
}

pub enum FinishReason {
	stop
	length
	tool_calls
	content_filter
	error
	unknown
}

pub struct FinishEvent {
pub:
	reason FinishReason
	// Optional usage, when the provider reports it.
	input_tokens  int
	output_tokens int
}

// -----------------------------------------------------------------------------
// Errors
// -----------------------------------------------------------------------------

pub struct ProviderError {
pub:
	code      string
	message   string
	retryable bool
}

pub fn (e ProviderError) msg() string {
	return '${e.code}: ${e.message}'
}

pub fn (e ProviderError) str() string {
	return e.msg()
}

// -----------------------------------------------------------------------------
// Session metadata (used by Agent to record turns)
// -----------------------------------------------------------------------------

pub struct Usage {
pub:
	input_tokens  int
	output_tokens int
	total_tokens  int
}

pub fn new_usage(input int, output int) Usage {
	return Usage{
		input_tokens:  input
		output_tokens: output
		total_tokens:  input + output
	}
}

// Suppress unused import warning when time isn't directly referenced.
// (removed: const unused = time.now — kept the import for future use)
