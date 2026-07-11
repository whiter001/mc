// approval.v — risky-tool permission flow.
//
// For self-use we want a minimal but real approval flow: bash / write_file /
// edit_file / web_fetch need a y/n prompt before they run. Read-only tools
// (read_file, glob, grep) are auto-allowed.
//
// The flow:
//   1. Agent loop hits a risky tool call.
//   2. It sends an ApprovalRequest on approval_ch.
//   3. TUI receives, renders a modal, captures y/n.
//   4. TUI sends an ApprovalDecision back on decision_ch.
//   5. Agent loop unblocks and either runs the tool or skips it.
//
// The agent loop is single-threaded (it's a goroutine but the run() method
// is sequential), so a blocking receive on decision_ch is safe. The TUI's
// render loop polls approval_ch alongside its other channels.

module main

// ApprovalRequest is sent by the agent when it wants to call a risky tool.
pub struct ApprovalRequest {
pub:
	id        u64    // monotonic, matches the response
	tool_name string
	args      string // raw JSON the model emitted
}

// ApprovalDecision is sent by the TUI after the user answers the modal.
pub struct ApprovalDecision {
pub:
	id         u64
	approved   bool
	// `remember` is reserved for a future "approve for the rest of the
	// session" option; for now it's always false (every call is asked
	// individually).
	remember   bool
}

// default_risky_tools is the hardcoded list of tools that always require
// approval. Configurable via permissions.toml in a follow-up.
pub const default_risky_tools = ['bash', 'write_file', 'edit_file', 'web_fetch']

// needs_approval returns true if the named tool requires user confirmation
// before running. The agent loop calls this on every tool call; safe tools
// (read_file, glob, grep) return false and skip the modal entirely.
pub fn needs_approval(tool_name string, risky []string) bool {
	for r in risky {
		if r == tool_name {
			return true
		}
	}
	return false
}

// next_request_id returns a monotonic id. Callers should keep the counter
// in their own `mut` field; this helper exists for testability and returns
// the new value (the caller assigns).
pub fn next_request_id(prev u64) u64 {
	return prev + 1
}
