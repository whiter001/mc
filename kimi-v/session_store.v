// internal/session/store.v
// Persists Sessions to TOML files under <config_dir>/sessions/<id>.toml.
// Format is human-readable so users can inspect, diff, and (with care) edit.
module main

import os
import json2
import strings
import time

// SessionSummary holds just the metadata needed for listing.
pub struct SessionSummary {
pub:
	id         string
	cwd        string
	created_at time.Time
	updated_at time.Time
	msg_count  int
	// Flattened preview of the first user message (may be empty).
	first_user string
}

// save persists sess to a TOML file under the sessions directory.
pub fn save(sess Session) ! {
	save_to(sessions_dir(), sess)!
}

// save_to persists sess to `<dir>/<id>.toml`. Shared by the regular session
// store and the subagent session store (resume support) — subagent sessions
// live under subagent_sessions_dir() so they don't pollute the user's session
// list.
pub fn save_to(dir string, sess Session) ! {
	ensure_dir(dir)!
	path := os.join_path(dir, '${sess.id}.toml')

	mut buf := strings.new_builder(1024)
	buf.write_string('[meta]\n')
	buf.write_string('id = "${sess.id}"\n')
	buf.write_string('cwd = "${sess.cwd}"\n')
	buf.write_string('created_at = "${sess.created_at.format()}"\n')
	buf.write_string('updated_at = "${sess.updated_at.format()}"\n')

	for k, v in sess.metadata {
		buf.write_string('"${k}" = "${v}"\n')
	}

	buf.write_string('\n[[messages]]\n')
	for m in sess.messages {
		write_message(mut buf, m)
		buf.write_string('\n[[messages]]\n')
	}

	os.write_file(path, buf.str())!
}

// write_message serializes a single message into the TOML buffer.
fn write_message(mut buf strings.Builder, m Message) {
	buf.write_string('[messages]\n')
	buf.write_string('role = "${m.role.str()}"\n')
	if m.content.len > 0 {
		buf.write_string('content = """\n${m.content}\n"""\n')
	}
	if m.tool_call_id.len > 0 {
		buf.write_string('tool_call_id = "${m.tool_call_id}"\n')
	}
	if m.name.len > 0 {
		buf.write_string('name = "${m.name}"\n')
	}
	if m.tool_calls.len > 0 {
		buf.write_string('tool_calls = ${json2.encode(m.tool_calls, escape_unicode: true)}\n')
	}
}

// load reads a session from its TOML file.
pub fn load(id string) !Session {
	return load_from(sessions_dir(), id)!
}

// load_from reads a session from `<dir>/<id>.toml`. Missing files error out so
// callers can distinguish "no such subagent" from an empty result.
pub fn load_from(dir string, id string) !Session {
	path := os.join_path(dir, '${id}.toml')
	if !os.exists(path) {
		return error('session not found: ${id}')
	}
	content := os.read_file(path)!
	return parse_session(id, content)!
}

// list_all returns metadata summaries for all persisted sessions, newest first.
pub fn list_all() ![]SessionSummary {
	ensure_dir(sessions_dir())!
	mut summaries := []SessionSummary{}
	mut entries := os.ls(sessions_dir()) or { return summaries }
	entries.sort(a > b) // newest first
	for entry in entries {
		if !entry.ends_with('.toml') {
			continue
		}
		id := entry.all_before_last('.')
		path := os.join_path(sessions_dir(), entry)
		content := os.read_file(path) or { continue }
		summary := parse_summary(id, content) or { continue }
		summaries << summary
	}
	return summaries
}

// parse_summary extracts metadata from a session TOML file without loading messages.
fn parse_summary(id string, content string) !SessionSummary {
	mut sess := Session{
		id: id
	}
	lines := content.split_into_lines()
	mut in_messages := false
	// Track the first user message's triple-quoted content (may span lines).
	mut want_first_user := false
	mut in_content := false
	mut content_lines := []string{}
	for line in lines {
		trimmed := line.trim_space()
		if trimmed == '[[messages]]' {
			in_messages = true
			want_first_user = false
			in_content = false
			content_lines = []string{}
			continue
		}
		if in_content {
			if trimmed.ends_with('"""') {
				content_lines << trimmed[..trimmed.len - 3]
				sess.metadata['__first_user'] = content_lines.join('\n')
				in_content = false
			} else {
				content_lines << trimmed
			}
			continue
		}
		if trimmed == '[meta]' {
			continue
		}
		if trimmed.len == 0 || trimmed.starts_with('#') {
			continue
		}
		if in_messages {
			if trimmed.starts_with('role = ') {
				role_str := trimmed.all_after('role = ').trim(' "')
				if role_str == 'user' && sess.metadata['__first_user'].len == 0 {
					want_first_user = true
				}
			} else if trimmed.starts_with('content = """') && want_first_user {
				idx := trimmed.index('"""') or { -1 }
				if idx >= 0 {
					rest := trimmed[idx + 3..]
					if rest.ends_with('"""') {
						sess.metadata['__first_user'] = rest[..rest.len - 3]
						want_first_user = false
					} else {
						content_lines = [rest]
						in_content = true
					}
				}
			}
			continue // [[messages]] block not needed for summary
		}
		if trimmed.starts_with('id = ') {
			sess.id = trimmed.all_after('id = ').trim(' "')
		} else if trimmed.starts_with('cwd = ') {
			sess.cwd = trimmed.all_after('cwd = ').trim(' "')
		} else if trimmed.starts_with('created_at = ') {
			ts := trimmed.all_after('created_at = ').trim(' "')
			sess.created_at = time.parse(ts) or { time.now() }
		} else if trimmed.starts_with('updated_at = ') {
			ts := trimmed.all_after('updated_at = ').trim(' "')
			sess.updated_at = time.parse(ts) or { time.now() }
		}
	}
	// count [[messages]] blocks
	msg_count := content.count('[[messages]]') - 1 // subtract 1 for the one after [meta]
	return SessionSummary{
		id:         sess.id
		cwd:        sess.cwd
		created_at: sess.created_at
		updated_at: sess.updated_at
		msg_count:  if msg_count > 0 { msg_count } else { 0 }
		first_user: first_user_preview(sess.metadata['__first_user'])
	}
}

// first_user_preview flattens the first user message into a single-line,
// truncated preview suitable for the sessions modal.
fn first_user_preview(content string) string {
	mut s := content.replace('\n', ' ').trim_space()
	if s.len > 60 {
		s = s[..60] + '…'
	}
	return s
}

// parse_session reconstructs a full Session from a TOML file.
fn parse_session(id string, content string) !Session {
	mut sess := Session{
		id: id
	}
	lines := content.split_into_lines()
	mut in_message := false

	// Fields for the current message being parsed.
	mut m_role := Role.user
	mut m_content := ''
	mut m_tool_call_id := ''
	mut m_name := ''
	mut m_tool_calls := []ToolCall{}

	for line in lines {
		trimmed := line.trim_space()
		if trimmed == '[[messages]]' {
			// Emit the message we just finished.
			sess.messages << Message{
				role:         m_role
				content:      m_content
				tool_call_id: m_tool_call_id
				name:         m_name
				tool_calls:   m_tool_calls
			}
			// Reset for next message.
			m_role = .user
			m_content = ''
			m_tool_call_id = ''
			m_name = ''
			m_tool_calls = []ToolCall{}
			in_message = true
			continue
		}
		if trimmed == '[meta]' {
			continue
		}
		if trimmed.len == 0 || trimmed.starts_with('#') {
			continue
		}
		if !in_message {
			if trimmed.starts_with('id = ') {
				sess.id = trimmed.all_after('id = ').trim(' "')
			} else if trimmed.starts_with('cwd = ') {
				sess.cwd = trimmed.all_after('cwd = ').trim(' "')
			} else if trimmed.starts_with('created_at = ') {
				ts := trimmed.all_after('created_at = ').trim(' "')
				sess.created_at = time.parse(ts) or { time.now() }
			} else if trimmed.starts_with('updated_at = ') {
				ts := trimmed.all_after('updated_at = ').trim(' "')
				sess.updated_at = time.parse(ts) or { time.now() }
			} else if trimmed.starts_with('"') {
				// metadata entry: "key" = "value"
				parts := trimmed.split_nth('=', 2)
				if parts.len == 2 {
					key := parts[0].trim(' "')
					val := parts[1].trim(' "')
					if sess.metadata.len == 0 {
						sess.metadata = map[string]string{}
					}
					sess.metadata[key] = val
				}
			}
			continue
		}

		// Inside [[messages]] block: collect field values into temp vars.
		if trimmed.starts_with('role = ') {
			role_str := trimmed.all_after('role = ').trim(' "')
			m_role = role_from_str(role_str)
		} else if trimmed.starts_with('content = """') {
			// Triple-quoted: content = """... """. Take everything after the opening """.
			idx := trimmed.index('"""') or { -1 }
			if idx >= 0 {
				rest := trimmed[idx + 3..]
				if rest.ends_with('"""') {
					m_content = rest[..rest.len - 3]
				} else {
					m_content = rest
				}
			}
		} else if trimmed.starts_with('tool_call_id = ') {
			m_tool_call_id = trimmed.all_after('tool_call_id = ').trim(' "')
		} else if trimmed.starts_with('name = ') {
			m_name = trimmed.all_after('name = ').trim(' "')
		} else if trimmed.starts_with('tool_calls = ') {
			json_str := trimmed.all_after('tool_calls = ').trim(' ')
			if json_str.len > 0 {
				m_tool_calls = json2.decode[[]ToolCall](json_str) or { []ToolCall{} }
			}
		}
	}

	return sess
}

// role_from_str maps a TOML role string to the Role enum.
fn role_from_str(s string) Role {
	return match s {
		'system' { .system }
		'user' { .user }
		'assistant' { .assistant }
		'tool' { .tool }
		else { .user }
	}
}

// list_recent returns the most recent session ids, newest first.
pub fn list_recent(limit int) ![]string {
	ensure_dir(sessions_dir())!
	mut ids := []string{}
	mut entries := os.ls(sessions_dir()) or { return ids }
	entries.sort(a > b)
	for entry in entries {
		if entry.ends_with('.toml') {
			ids << entry.all_before_last('.')
			if ids.len >= limit {
				break
			}
		}
	}
	return ids
}
