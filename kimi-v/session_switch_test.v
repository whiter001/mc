// session_switch_test.v — unit tests for the /sessions switch helpers
// (message → block conversion, modal line formatting, first-message
// preview). These are pure functions; the goroutine-based TUI flows are
// deliberately not end-to-end tested (see main_test.v).
module main

import time

fn test_session_messages_to_blocks() {
	msgs := [
		Message{
			role:    .user
			content: 'hello'
		},
		Message{
			role:       .assistant
			content:    'hi there'
			tool_calls: [
				ToolCall{
					id:        'tc1'
					name:      'bash'
					arguments: '{"cmd":"ls"}'
				},
			]
		},
		Message{
			role:         .tool
			name:         'bash'
			tool_call_id: 'tc1'
			content:      'file list output'
		},
		Message{
			role:    .system
			content: 'system note'
		},
	]
	blocks := session_messages_to_blocks(msgs)
	assert blocks.len == 5, 'expected 5 blocks (1 user + 1 assistant + 1 tool_call + 1 tool + 1 system), got ${blocks.len}'
	assert blocks[0].kind == .user
	assert blocks[0].text == 'hello'
	assert blocks[1].kind == .assistant
	assert blocks[1].text == 'hi there'
	assert blocks[2].kind == .tool_call
	assert blocks[2].tool_name == 'bash'
	assert blocks[2].tool_args == '{"cmd":"ls"}'
	assert blocks[3].kind == .tool_result
	assert blocks[3].tool_name == 'bash'
	assert blocks[3].tool_result == 'file list output'
	assert blocks[3].tool_is_error == false
	assert blocks[4].kind == .system
	assert blocks[4].text == 'system note'
}

fn test_format_session_modal_lines() {
	now := time.now()
	summaries := [
		SessionSummary{
			id:         '01234567890123456789012345' // longer than 20 → truncated
			cwd:        '/tmp'
			created_at: now
			updated_at: now
			msg_count:  12
			first_user: 'first message content'
		},
		SessionSummary{
			id:         'short-id'
			cwd:        '/tmp'
			created_at: now
			updated_at: now
			msg_count:  3
			first_user: ''
		},
	]
	lines := format_session_modal_lines(summaries)
	assert lines.len == 4, 'expected 4 lines (header + 2 sessions + hint), got ${lines.len}'
	assert lines[0] == 'sessions (newest first):'
	assert lines[1].starts_with('1) ')
	assert lines[1].contains('12 msgs')
	assert lines[1].contains('first message content')
	// id longer than 20 chars is truncated
	assert lines[1].contains('…')
	assert lines[2].starts_with('2) short-id')
	assert lines[2].contains('3 msgs')
	assert lines[3] == 'pick a number; Esc to cancel'
}

fn test_first_user_preview() {
	// Newlines are flattened to spaces.
	flat := first_user_preview('line one\nline two')
	assert flat == 'line one line two'
	// Trailing whitespace is trimmed.
	trimmed := first_user_preview('  padded  ')
	assert trimmed == 'padded'
	// Content longer than 60 chars is truncated with an ellipsis.
	long := 'a'.repeat(80)
	preview := first_user_preview(long)
	// `…` is a 3-byte UTF-8 char, so 60 bytes + '…' = 63 bytes.
	assert preview.len == 63, 'expected 60 bytes + ellipsis, got ${preview.len}'
	assert preview.ends_with('…')
	// Empty content stays empty.
	assert first_user_preview('') == ''
}
