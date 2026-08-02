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
