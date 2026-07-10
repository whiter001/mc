// internal/agent/v
// Session = the durable state of a conversation. The Agent class itself
// must not hold a Session (matching the constraint in the original
// `kimi-code` AGENTS.md), so we keep it as a pure data type.
module main

import time

pub struct Session {
pub mut:
	id         string
	cwd        string
	messages   []Message
	created_at time.Time
	updated_at time.Time
	// Free-form metadata (model used, total tokens, etc.).
	metadata map[string]string
}

pub fn new_session(cwd string) Session {
	now := time.now()
	return Session{
		id:         short_id()
		cwd:        cwd
		messages:   []Message{}
		created_at: now
		updated_at: now
		metadata:   map[string]string{}
	}
}

pub fn (mut s Session) append_user(text string) {
	s.messages << Message{
		role:    .user
		content: text
	}
	s.updated_at = time.now()
}

pub fn (mut s Session) append_assistant(content string, tool_calls []ToolCall) {
	s.messages << Message{
		role:       .assistant
		content:    content
		tool_calls: tool_calls
	}
	s.updated_at = time.now()
}

pub fn (mut s Session) append_tool_result(call_id string, name string, result string) {
	s.messages << Message{
		role:         .tool
		content:      result
		tool_call_id: call_id
		name:         name
	}
	s.updated_at = time.now()
}

pub fn (mut s Session) last_user() ?Message {
	for i := s.messages.len - 1; i >= 0; i-- {
		if s.messages[i].role == .user {
			return s.messages[i]
		}
	}
	return none
}

// short_id returns a collision-resistant session id: timestamp-hex + 4-digit random suffix.
fn short_id() string {
	ts := time.now().unix_milli()
	// Use microseconds as pseudo-random entropy (good enough, no dep needed).
	rnd := time.now().unix_micro() & 0xFFFF
	return '${ts.hex()}-${rnd.hex()}'
}
