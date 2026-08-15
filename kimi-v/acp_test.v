// acp_test.v — 单元测试 for acp.v 的纯函数（ACP v1 wire helpers）。
//
// 只测不依赖 IO / goroutine 的纯函数：prompt/message 文本转换、JSON-RPC
// 信封构造、stopReason 映射。生成 JSON 的正确性用 json2.decode 往返验证，
// 比直接字符串比较更能抓住转义错误。
module main

import json2

// ---- 测试用解码结构（验证生成 JSON 的往返） ----

struct AcpTestError {
	id    int
	error AcpTestErrorBody
}

struct AcpTestErrorBody {
	code    int
	message string
}

struct AcpTestChunk {
	session_id string @[json: 'sessionId']
	update     AcpTestChunkUpdate
}

struct AcpTestChunkUpdate {
	session_update string @[json: 'sessionUpdate']
	message_id     string @[json: 'messageId']
	content        AcpTestChunkContent
}

struct AcpTestChunkContent {
	typ  string @[json: 'type']
	text string
}

// agent_thought_chunk 载荷（复用 AcpTestChunkContent）
struct AcpTestThought {
	session_id string @[json: 'sessionId']
	update     AcpTestThoughtUpdate
}

struct AcpTestThoughtUpdate {
	session_update string @[json: 'sessionUpdate']
	message_id     string @[json: 'messageId']
	content        AcpTestChunkContent
}

// tool_call / tool_call_update 载荷（tool_call_update 只填 sessionUpdate /
// toolCallId / status，title/kind 缺失时按默认值解码）
struct AcpTestToolCall {
	session_id string @[json: 'sessionId']
	update     AcpTestToolCallUpdate
}

struct AcpTestToolCallUpdate {
	session_update string @[json: 'sessionUpdate']
	tool_call_id   string @[json: 'toolCallId']
	title          string
	kind           string
	status         string
}

// ---- acp_build_result ----

fn test_acp_build_result() {
	assert acp_build_result(7, '{"stopReason":"end_turn"}') == '{"id":7,"result":{"stopReason":"end_turn"}}'
	// id 0 必须原样输出（JSON-RPC 合法 id）
	assert acp_build_result(0, '{}') == '{"id":0,"result":{}}'
}

// ---- acp_build_error ----

fn test_acp_build_error() {
	assert acp_build_error(3, -32602, 'bad') == '{"id":3,"error":{"code":-32602,"message":"bad"}}'
	// message 含引号/换行/反斜杠时必须正确 JSON 转义，往返不变
	raw := 'a"b\nc\\d'
	line := acp_build_error(1, -32601, raw)
	dec := json2.decode[AcpTestError](line) or {
		assert false, 'invalid JSON: ${err.msg()}'
		return
	}
	assert dec.id == 1
	assert dec.error.code == -32601
	assert dec.error.message == raw
	// 转义字符确实出现在线里（不能有裸引号/换行）
	assert line.contains('\\"')
	assert line.contains('\\n')
	assert line.contains('\\\\')
}

// ---- acp_build_notification ----

fn test_acp_build_notification() {
	assert acp_build_notification('session/update', '{"x":1}') == '{"method":"session/update","params":{"x":1}}'
}

// ---- acp_chunk_update ----

fn test_acp_chunk_update() {
	text := 'say "hi"\nnext\\path 你好'
	line := acp_chunk_update('s-1', 'm-2', text)
	dec := json2.decode[AcpTestChunk](line) or {
		assert false, 'invalid JSON: ${err.msg()}'
		return
	}
	assert dec.session_id == 's-1'
	assert dec.update.session_update == 'agent_message_chunk'
	assert dec.update.message_id == 'm-2'
	assert dec.update.content.typ == 'text'
	assert dec.update.content.text == text
	assert line.contains('\\"')
	assert line.contains('\\n')
	assert line.contains('\\\\')
}

// ---- acp_thought_chunk_update ----

fn test_acp_thought_chunk_update() {
	text := 'reasoning "deep"\nstep\\two'
	line := acp_thought_chunk_update('s-1', 'm-2', text)
	dec := json2.decode[AcpTestThought](line) or {
		assert false, 'invalid JSON: ${err.msg()}'
		return
	}
	assert dec.session_id == 's-1'
	assert dec.update.session_update == 'agent_thought_chunk'
	assert dec.update.message_id == 'm-2'
	assert dec.update.content.typ == 'text'
	assert dec.update.content.text == text
	assert line.contains('\\"')
	assert line.contains('\\n')
	assert line.contains('\\\\')
}

// ---- acp_tool_call_update ----

fn test_acp_tool_call_update() {
	line := acp_tool_call_update('s-1', 'call-9', 'bash', 'execute')
	dec := json2.decode[AcpTestToolCall](line) or {
		assert false, 'invalid JSON: ${err.msg()}'
		return
	}
	assert dec.session_id == 's-1'
	assert dec.update.session_update == 'tool_call'
	assert dec.update.tool_call_id == 'call-9'
	assert dec.update.title == 'bash'
	assert dec.update.kind == 'execute'
	assert dec.update.status == 'in_progress'
	// 含特殊字符的 id/title 必须正确 JSON 转义，往返不变
	raw := 'a"b\nc\\d'
	esc_line := acp_tool_call_update('s-1', raw, raw, 'other')
	dec2 := json2.decode[AcpTestToolCall](esc_line) or {
		assert false, 'invalid JSON: ${err.msg()}'
		return
	}
	assert dec2.update.tool_call_id == raw
	assert dec2.update.title == raw
	assert esc_line.contains('\\"')
	assert esc_line.contains('\\n')
	assert esc_line.contains('\\\\')
}

// ---- acp_tool_done_update ----

fn test_acp_tool_done_update() {
	line := acp_tool_done_update('s-1', 'call-9', 'completed')
	dec := json2.decode[AcpTestToolCall](line) or {
		assert false, 'invalid JSON: ${err.msg()}'
		return
	}
	assert dec.session_id == 's-1'
	assert dec.update.session_update == 'tool_call_update'
	assert dec.update.tool_call_id == 'call-9'
	assert dec.update.status == 'completed'
	// failed 变体
	line_f := acp_tool_done_update('s-1', 'call-9', 'failed')
	dec_f := json2.decode[AcpTestToolCall](line_f) or {
		assert false, 'invalid JSON: ${err.msg()}'
		return
	}
	assert dec_f.update.status == 'failed'
}

// ---- acp_tool_kind 映射表 ----

fn test_acp_tool_kind() {
	assert acp_tool_kind('bash') == 'execute'
	assert acp_tool_kind('write_file') == 'edit'
	assert acp_tool_kind('edit_file') == 'edit'
	assert acp_tool_kind('read_file') == 'read'
	assert acp_tool_kind('grep') == 'search'
	assert acp_tool_kind('glob') == 'search'
	assert acp_tool_kind('web_fetch') == 'fetch'
	assert acp_tool_kind('web_search') == 'fetch'
	// 未识别工具 → other
	assert acp_tool_kind('TodoWrite') == 'other'
	assert acp_tool_kind('Agent') == 'other'
	assert acp_tool_kind('') == 'other'
}

// ---- acp_tool_done_status ----

fn test_acp_tool_done_status() {
	assert acp_tool_done_status(false) == 'completed'
	assert acp_tool_done_status(true) == 'failed'
}

// ---- acp_stop_reason ----

fn test_acp_stop_reason() {
	assert acp_stop_reason(.finished) == 'end_turn'
	assert acp_stop_reason(.max_turns) == 'max_turn_requests'
	assert acp_stop_reason(.errored) == 'end_turn'
}

// ---- acp_prompt_to_text ----

fn test_acp_prompt_to_text() {
	r := acp_prompt_to_text([AcpContentBlock{typ: 'text', text: 'hi'}]) or {
		assert false, 'unexpected error: ${err.msg()}'
		return
	}
	assert r == 'hi'

	multi := acp_prompt_to_text([
		AcpContentBlock{typ: 'text', text: 'a'},
		AcpContentBlock{typ: 'text', text: 'b'},
	]) or {
		assert false, 'unexpected error: ${err.msg()}'
		return
	}
	assert multi == 'a\nb'

	// 空数组必须报错
	acp_prompt_to_text([]) or {
		assert err.msg() == 'prompt must contain at least one content block'
		return
	}
	assert false, 'acp_prompt_to_text([]) should have failed'

	// 非 text 块必须报错
	acp_prompt_to_text([AcpContentBlock{typ: 'image', text: ''}]) or {
		assert err.msg() == 'unsupported content block type: image'
		return
	}
	assert false, 'non-text block should have failed'
}

// ---- acp_message_to_text ----

fn test_acp_message_to_text() {
	assert acp_message_to_text(Message{role: .user, content: 'hi'}) == 'hi'
	assert acp_message_to_text(Message{role: .assistant, content: 'hello'}) == 'hello'
	assert acp_message_to_text(Message{role: .tool, name: 'bash', content: 'out'}) == '[tool result: bash] out'
	// 无 name 的 tool 消息（V 默认空字符串）
	assert acp_message_to_text(Message{role: .tool, content: 'out'}) == '[tool result: ] out'
	// system 消息跳过（session/load 不重放系统提示）
	assert acp_message_to_text(Message{role: .system, content: 'sys'}) == ''
}
