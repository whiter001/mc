// internal/llm/types.v
// Common types shared across LLM providers.
module main

// -----------------------------------------------------------------------------
// Roles and messages
// -----------------------------------------------------------------------------

// Role represents the speaker of a message in the conversation.
pub enum Role {
	system
	user
	assistant
	tool
}

// str returns the wire-format string for the role.
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
	// Multimodal attachments (e.g. pasted images). When non-empty, the
	// provider serializes `content` as an array of parts: one text part
	// for `content` (if non-empty) followed by image_url parts for each
	// attachment. Empty for text-only messages — the common case.
	attachments []Attachment
	// Set only when role == .assistant and the model emitted tool calls.
	tool_calls []ToolCall
	// Set only when role == .tool (the result of a tool execution).
	tool_call_id string
	// Optional name for tool/system messages (used by some providers).
	name string
}

// Attachment is a single image (or other multimodal part) attached to a
// Message. The `b64` field is the base64-encoded file content; providers
// wrap it as data:<mime>;base64,<b64> on the image_url side of the wire.
// Attachments are attached at submit time (see InputBuf.attach_file /
// attach_data_url) and not persisted with the session in v1.
pub struct Attachment {
pub:
	mime string  // "image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp"
	b64  string  // base64-encoded content (no data: prefix, no newlines)
	name string  // display name (e.g. "screenshot.png" or "pasted.png")
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

// ToolDef describes a callable tool exposed to the model.
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

// ChatRequest is the canonical input to a chat completions call.
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
	// thinking fields (MiniMax-M3 reasoning)
	thinking string
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
	// True when the error is transient (HTTP 429 / 5xx / connection
	// failure) and the step is worth retrying. Set by the provider on
	// .err_kind events; consumed by the agent loop's retry logic.
	retryable bool
}

// ChatEventKind tags the payload type of a ChatEvent.
pub enum ChatEventKind {
	delta
	thinking
	tool_call
	finish
	usage
	err_kind
	end_of_stream
}

// DeltaEvent carries a incremental text fragment from the model.
pub struct DeltaEvent {
pub:
	content string
}

// ToolCallEvent carries an incremental or complete tool call fragment.
pub struct ToolCallEvent {
pub:
	index int
	id    string
	name  string
	// Partial arguments JSON; the consumer should accumulate by `index`.
	arguments string
}

// FinishReason explains why the model stopped generating tokens.
pub enum FinishReason {
	stop
	length
	tool_calls
	content_filter
	error
	unknown
}

// FinishEvent signals the end of a model response.
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

// ProviderError is a structured error returned by an LLM provider.
// The msg()/code() methods implement vlib's IError interface, so
// returning a ProviderError from a `!`-typed function yields a proper
// error value that `err is ProviderError` can still recover the
// retryable flag from.
pub struct ProviderError {
pub:
	message   string // full human-readable message
	kind      string // provider/HTTP code string, e.g. 'http_429', 'dial_failed'
	status    int    // HTTP status code when applicable (0 otherwise)
	retryable bool
}

// msg implements IError.
pub fn (e ProviderError) msg() string {
	return e.message
}

// code implements IError (HTTP status, or 0 when not applicable).
pub fn (e ProviderError) code() int {
	return e.status
}

// str returns the string representation of the error.
pub fn (e ProviderError) str() string {
	return e.message
}

// is_retryable_status reports whether an HTTP status code is worth
// retrying: 429 (rate limit) and any 5xx are transient; other 4xx are
// client errors a retry won't fix.
fn is_retryable_status(code int) bool {
	return code == 429 || code >= 500
}

// -----------------------------------------------------------------------------
// Session metadata (used by Agent to record turns)
// -----------------------------------------------------------------------------

// Usage records token consumption for one turn.
pub struct Usage {
pub:
	input_tokens  int
	output_tokens int
	total_tokens  int
}

// new_usage creates a Usage record from input and output token counts.
pub fn new_usage(input int, output int) Usage {
	return Usage{
		input_tokens:  input
		output_tokens: output
		total_tokens:  input + output
	}
}

// Suppress unused import warning when time isn't directly referenced.
// (removed: const unused = time.now — kept the import for future use)
