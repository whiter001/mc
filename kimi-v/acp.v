// internal/acp/server.v
// ACP v1 (Agent Client Protocol) stdio server — `kimi acp`.
//
// Implements the JSON-RPC subset required for P4:
//   initialize / notifications/initialized / authenticate / session/new /
//   session/load / session/prompt / session/cancel
//
// The server reads newline-delimited JSON-RPC messages from stdin and writes
// responses / notifications to stdout. Every line is flushed immediately so
// the protocol stream stays synchronous. Logs go to stderr and never touch
// the stdout protocol stream.
//
// P4 subset notes:
//   - Only `text` content blocks are supported; thinking / tool-call
//     streaming updates are not emitted (deltas are plain agent_message_chunk).
//   - mcpServers in session/new / session/load are accepted and ignored
//     (config-level MCP servers from config.toml are still connected).
//   - session/close, session/list, session/delete and fs / terminal
//     capabilities are not implemented (session/load replays the transcript).
//   - Concurrent prompts on the same session are rejected (-32602).
module main

import json2
import os
import sync

// ── Wire schema (ACP v1) ────────────────────────────────────────────────
// Only the fields each handler reads are declared; unknown JSON fields are
// tolerated and dropped by json2.decode. Every request is first classified
// by AcpReqMeta (id present ⇒ request, absent ⇒ notification), then decoded
// into the per-method struct. A non-integer `id` (e.g. a string) fails the
// whole decode and the line is dropped.

struct AcpReqMeta {
	id     ?int @[json: 'id']
	method string
}

struct AcpInitializeReq {
	id     ?int @[json: 'id']
	method string
	params AcpInitializeParams
}

struct AcpInitializeParams {
	protocol_version ?int @[json: 'protocolVersion']
}

struct AcpAuthenticateReq {
	id     ?int @[json: 'id']
	method string
	params AcpAuthenticateParams
}

struct AcpAuthenticateParams {
	method_id string @[json: 'methodId']
}

struct AcpSessionNewReq {
	id     ?int @[json: 'id']
	method string
	params AcpSessionNewParams
}

struct AcpSessionNewParams {
	cwd string
}

struct AcpSessionLoadReq {
	id     ?int @[json: 'id']
	method string
	params AcpSessionLoadParams
}

struct AcpSessionLoadParams {
	session_id string @[json: 'sessionId']
	cwd        string
}

struct AcpPromptReq {
	id     ?int @[json: 'id']
	method string
	params AcpPromptParams
}

struct AcpPromptParams {
	session_id string @[json: 'sessionId']
	prompt     []AcpContentBlock
}

// AcpContentBlock is one element of a session/prompt `prompt` array. Only
// `text` blocks are supported (P4 subset).
struct AcpContentBlock {
	typ  string @[json: 'type']
	text string
}

struct AcpCancelReq {
	id     ?int @[json: 'id']
	method string
	params AcpCancelParams
}

struct AcpCancelParams {
	session_id string @[json: 'sessionId']
}

// ── Server state ────────────────────────────────────────────────────────

// AcpSession is the server-side wrapper around a Session. `busy` guards
// against concurrent prompts on the same session; `turn_seq` numbers turns
// for message ids; `cancel_ch` is shared with the in-flight agent (both
// sides hold the same channel handle, and neither reassigns it mid-turn —
// the runner resets it to a fresh channel when a turn completes).
struct AcpSession {
mut:
	sess      Session
	busy      bool
	turn_seq  int
	cancel_ch chan int
}

// AcpServer owns the protocol loop. It is heap-allocated (@[heap]) because
// prompt turns run in goroutines that may outlive the stdin read loop.
@[heap]
pub struct AcpServer {
mut:
	cfg      Config
	sessions map[string]AcpSession
	smu      sync.Mutex // guards sessions
	wmu      sync.Mutex // serializes writes to stdout
	log      Logger
}

// run_acp_cmd is the `kimi acp` entry point: load config, build the server,
// and serve stdin/stdout until EOF. Authentication is a per-request concern
// (authenticate), so config validation (which forces api_key + model) is
// deliberately skipped here; load_config alone injects saved OAuth
// credentials into cfg.api_key when present.
pub fn run_acp_cmd(cli Cli, mut log Logger) ! {
	// NOTE: a `Config{}` literal would carry the struct's built-in field
	// defaults (api_base='https://api.openai.com', provider='openai-compat',
	// max_turns=32, max_tokens=4096, ...) into load_config, where they are
	// treated as CLI overrides and clobber env vars (KIMI_API_BASE) and
	// config.toml. Zero out every field that has a non-zero default so ACP
	// honors env/file configuration only.
	cfg := load_config(Config{
		provider:             ''
		api_base:             ''
		log_level:            ''
		max_turns:            0
		max_tokens:           0
		max_retries_per_step: 0
	})!
	mut srv := &AcpServer{
		cfg:      cfg
		sessions: map[string]AcpSession{}
		log:      log
	}
	run_acp_loop(mut srv)
}

// run_acp_loop reads newline-delimited JSON-RPC messages from stdin until
// EOF, dispatching each line to the request handler.
fn run_acp_loop(mut s AcpServer) {
	for {
		line := os.get_raw_line()
		if line.len == 0 {
			break
		}
		s.handle_line(line.trim_space())
	}
	s.log.info('acp: stdin closed; shutting down')
}

// ── Request dispatch ────────────────────────────────────────────────────

// handle_line classifies one raw request line (id ⇒ request, no id ⇒
// notification) and dispatches to the matching handler.
fn (mut s AcpServer) handle_line(line string) {
	if line.len == 0 {
		return
	}
	meta := json2.decode[AcpReqMeta](line) or {
		s.log.warn('acp: dropping malformed request: ${err.msg()}')
		return
	}
	if meta.method.len == 0 {
		s.log.warn('acp: dropping request without a method')
		return
	}
	if meta.id == none {
		// Notification: no response expected.
		match meta.method {
			'session/cancel' {
				req := json2.decode[AcpCancelReq](line) or {
					s.log.warn('acp: bad session/cancel notification: ${err.msg()}')
					return
				}
				s.handle_cancel(req.params.session_id)
			}
			else {
				// notifications/initialized, $/... and anything else are
				// acknowledged by being ignored.
			}
		}
		return
	}
	id := meta.id or { 0 }
	match meta.method {
		'initialize' {
			req := json2.decode[AcpInitializeReq](line) or {
				s.log.warn('acp: bad initialize request: ${err.msg()}')
				s.send_error(id, -32602, 'invalid params')
				return
			}
			s.handle_initialize(id, req)
		}
		'authenticate' {
			req := json2.decode[AcpAuthenticateReq](line) or {
				s.log.warn('acp: bad authenticate request: ${err.msg()}')
				s.send_error(id, -32602, 'invalid params')
				return
			}
			s.handle_authenticate(id, req)
		}
		'session/new' {
			req := json2.decode[AcpSessionNewReq](line) or {
				s.log.warn('acp: bad session/new request: ${err.msg()}')
				s.send_error(id, -32602, 'invalid params')
				return
			}
			s.handle_session_new(id, req)
		}
		'session/load' {
			req := json2.decode[AcpSessionLoadReq](line) or {
				s.log.warn('acp: bad session/load request: ${err.msg()}')
				s.send_error(id, -32602, 'invalid params')
				return
			}
			s.handle_session_load(id, req)
		}
		'session/prompt' {
			req := json2.decode[AcpPromptReq](line) or {
				s.log.warn('acp: bad session/prompt request: ${err.msg()}')
				s.send_error(id, -32602, 'invalid params')
				return
			}
			s.handle_session_prompt(id, req)
		}
		else {
			s.send_error(id, -32601, 'method not found: ' + meta.method)
		}
	}
}

// ── Handlers ────────────────────────────────────────────────────────────

// handle_initialize answers the ACP handshake. We implement protocol
// version 1; a client requesting anything else is told we speak 1.
fn (mut s AcpServer) handle_initialize(id int, req AcpInitializeReq) {
	v := req.params.protocol_version or { 1 }
	if v != 1 {
		s.log.warn('acp: client requested protocol version ${v}; negotiating 1')
	}
	result := '{"protocolVersion":1,' +
		'"agentCapabilities":{"loadSession":true,' +
		'"promptCapabilities":{"image":false,"audio":false,"embeddedContext":false},' +
		'"mcpCapabilities":{"http":false,"sse":false},"sessionCapabilities":{},"auth":{}},' +
		'"agentInfo":{"name":"kimi","title":"Kimi Code","version":"${version}"},' +
		'"authMethods":[{"id":"agent","name":"Kimi Code"}]}'
	s.send_result(id, result)
}

// handle_authenticate validates the `agent` auth method against locally
// available credentials: an explicit api_key (env / config.toml / OAuth
// injection from load_config) or a non-expired saved OAuth token.
fn (mut s AcpServer) handle_authenticate(id int, req AcpAuthenticateReq) {
	if req.params.method_id != 'agent' {
		s.send_error(id, -32602, 'unknown auth method: ' + req.params.method_id)
		return
	}
	if s.has_credentials() {
		s.send_result(id, '{}')
	} else {
		s.send_error(id, -32001,
			'no credentials; run `kimi login` (or `kimi login --oauth`), or set KIMI_API_KEY')
	}
}

// has_credentials reports whether the server can authenticate the agent
// auth method without a user interaction.
fn (s AcpServer) has_credentials() bool {
	if s.cfg.api_key.len > 0 {
		return true
	}
	creds := load_credentials() or { return false }
	return !is_credentials_expired(creds)
}

// handle_session_new creates a session rooted at an absolute cwd.
fn (mut s AcpServer) handle_session_new(id int, req AcpSessionNewReq) {
	cwd := req.params.cwd
	if !os.is_abs_path(cwd) {
		s.send_error(id, -32602, 'cwd must be an absolute path')
		return
	}
	sess := new_session(cwd)
	s.save_session(sess)
	s.smu.lock()
	s.sessions[sess.id] = AcpSession{
		sess:      sess
		cancel_ch: chan int{cap: 1}
	}
	s.smu.unlock()
	s.log.info('acp: session/new ${sess.id} cwd=${cwd}')
	s.send_result(id, '{"sessionId":"${sess.id}"}')
}

// handle_session_load restores a session (from memory or disk), checks the
// cwd matches, and replays the transcript as agent_message_chunk updates.
fn (mut s AcpServer) handle_session_load(id int, req AcpSessionLoadReq) {
	sid := req.params.session_id
	cwd := req.params.cwd
	if sid.len == 0 {
		s.send_error(id, -32602, 'missing sessionId')
		return
	}
	if cwd.len == 0 {
		s.send_error(id, -32602, 'missing cwd')
		return
	}
	// In-memory sessions take precedence; otherwise load from disk.
	mut sess := Session{}
	s.smu.lock()
	if sid in s.sessions {
		es := s.sessions[sid]
		sess = es.sess
	}
	s.smu.unlock()
	if sess.id.len == 0 {
		sess = load(sid) or {
			s.send_error(id, -32602, 'session not found: ' + sid)
			return
		}
	}
	if cwd != sess.cwd {
		s.send_error(id, -32602, 'cwd does not match the session cwd')
		return
	}
	// Stream the transcript as update notifications. Only the assistant side
	// is replayed: the client already sent the user messages itself, and tool
	// calls are echoed back in their own updates during the turn.
	for i, m in sess.messages {
		if m.role != .assistant {
			continue
		}
		text := acp_message_to_text(m)
		if text.len == 0 {
			continue
		}
		s.send_update(sid, '${sid}-replay-${i}', text)
	}
	s.log.info('acp: session/load ${sid} (${sess.messages.len} messages)')
	s.send_result(id, '{}')
}

// handle_session_prompt starts an agent turn in a goroutine and returns
// immediately. The turn's streaming updates and final result arrive on the
// same stdout stream afterwards.
fn (mut s AcpServer) handle_session_prompt(id int, req AcpPromptReq) {
	sid := req.params.session_id
	if sid.len == 0 {
		s.send_error(id, -32602, 'missing sessionId')
		return
	}
	text := acp_prompt_to_text(req.params.prompt) or {
		s.send_error(id, -32602, err.msg())
		return
	}
	// Reserve the session (busy flag) under the mutex, then hand the turn
	// to a goroutine so the read loop keeps servicing stdin.
	s.smu.lock()
	mut es := s.sessions[sid] or {
		s.smu.unlock()
		s.send_error(id, -32602, 'session not found: ' + sid)
		return
	}
	if es.busy {
		s.smu.unlock()
		s.send_error(id, -32602, 'session is busy')
		return
	}
	es.busy = true
	es.turn_seq++
	es.cancel_ch = chan int{cap: 1}
	s.sessions[sid] = es
	s.smu.unlock()

	s.log.info('acp: session/prompt ${sid} turn=${es.turn_seq}')
	go fn (mut s AcpServer, id int, sid string, text string, turn int) {
		s.run_prompt_turn(id, sid, text, turn)
	}(mut s, id, sid, text, es.turn_seq)
}

// handle_cancel (notification) requests cancellation of an in-flight turn.
// There is no response; the prompt turn itself answers with stopReason
// "cancelled" (or just ends, if it already finished).
fn (mut s AcpServer) handle_cancel(sid string) {
	s.smu.lock()
	es := s.sessions[sid] or {
		s.smu.unlock()
		return
	}
	s.smu.unlock()
	if !es.busy {
		return
	}
	es.cancel_ch.try_push(1)
	s.log.info('acp: session/cancel ${sid}')
}

// run_prompt_turn builds an agent for the session's cwd, appends the user
// message, runs the loop, and reports the outcome. Runs in a goroutine; the
// AcpServer handle (and the shared cancel channel) keep working while it's
// in flight.
fn (mut s AcpServer) run_prompt_turn(id int, sid string, text string, turn int) {
	// Snapshot per-session state under the lock: the goroutine runs with a
	// copy of the Session so the map stays consistent.
	s.smu.lock()
	es := s.sessions[sid] or {
		s.smu.unlock()
		s.send_error(id, -32602, 'session not found: ' + sid)
		return
	}
	s.smu.unlock()
	cwd := es.sess.cwd
	cancel_ch := es.cancel_ch
	mid := '${sid}-${turn}'

	// Build the agent exactly like run_prompt, but rooted at the session
	// cwd (each ACP session may live in a different directory).
	mut provider := make_provider(s.cfg)
	base_system := 'You are Kimi Code, an AI coding assistant running in the terminal. ' +
		'Use the available tools to read files, edit files, and run shell commands. ' +
		'Be concise. Prefer reading files before editing them.'
	system := base_system + load_agents_md(cwd, config_dir())

	mut a := new_agent(provider, system)
	a.max_turns = s.cfg.max_turns
	a.max_retries_per_step = s.cfg.max_retries_per_step
	a.registry = default_registry(mut a, cwd, s.cfg.mcp_servers)
	defer {
		close_all_mcp_servers(mut a.mcp_clients)
	}
	a.set_skills(discover_skills(cwd))
	mut he := new_hook_engine(cwd, sid)
	for h in s.cfg.hooks {
		he.add(h)
	}
	a.set_hooks(he)
	// Non-interactive: plan-mode approvals must auto-pass; there is no UI.
	a.non_interactive = true
	if s.cfg.risky_tools.len > 0 {
		a.risky_tools = s.cfg.risky_tools
	}
	a.approved_tools = load_approved_tools()
	a.permission_rules = s.cfg.permission_rules
	a.yolo = s.cfg.yolo
	a.session_id = sid
	a.cancel_ch = cancel_ch
	a.on_delta = fn [mut s, sid, mid] (chunk string) {
		s.send_update(sid, mid, chunk)
	}
	// on_thinking / on_tool are intentionally not wired: the P4 subset
	// streams plain text deltas only.

	mut sess := es.sess
	sess.append_user(text)
	result := a.run(mut sess) or {
		// `cancelled` is a normal (client-requested) end; everything else
		// is an internal error.
		if err.msg() == 'cancelled' {
			s.log.info('acp: turn ${mid} cancelled')
			s.send_result(id, '{"stopReason":"cancelled"}')
		} else {
			s.log.error('acp: turn ${mid} failed: ${err.msg()}')
			s.send_error(id, -32603, err.msg())
		}
		s.finish_turn(sid, sess)
		return
	}
	s.send_result(id, '{"stopReason":"' + acp_stop_reason(result.outcome) + '"}')
	s.finish_turn(sid, sess)
}

// finish_turn writes the mutated session back into the map, clears the busy
// flag, resets the cancel channel for the next turn, and persists the
// session to disk (best-effort).
fn (mut s AcpServer) finish_turn(sid string, sess Session) {
	s.smu.lock()
	if sid in s.sessions {
		mut es := s.sessions[sid]
		es.sess = sess
		es.busy = false
		es.cancel_ch = chan int{cap: 1}
		s.sessions[sid] = es
	}
	s.smu.unlock()
	s.save_session(sess)
}

// ── Wire helpers ────────────────────────────────────────────────────────

// acp_prompt_to_text flattens a session/prompt content-block array into a
// single newline-joined prompt string. Only text blocks are accepted.
fn acp_prompt_to_text(blocks []AcpContentBlock) !string {
	if blocks.len == 0 {
		return error('prompt must contain at least one content block')
	}
	mut parts := []string{}
	for b in blocks {
		if b.typ != 'text' {
			return error('unsupported content block type: ' + b.typ)
		}
		parts << b.text
	}
	return parts.join('\n')
}

// acp_message_to_text converts a stored Session message into its text form
// for session/load replay. System messages are skipped (empty string).
fn acp_message_to_text(m Message) string {
	return match m.role {
		.user {
			m.content
		}
		.assistant {
			m.content
		}
		.tool {
			'[tool result: ${m.name}] ${m.content}'
		}
		.system {
			''
		}
	}
}

// acp_stop_reason maps a loop outcome to an ACP stopReason string.
fn acp_stop_reason(outcome LoopOutcome) string {
	return match outcome {
		.finished { 'end_turn' }
		.max_turns { 'max_turn_requests' }
		.errored { 'end_turn' }
	}
}

// acp_chunk_update builds the params object for a session/update
// notification carrying one text chunk:
//
//	{"sessionId":"<sid>","update":{"sessionUpdate":"agent_message_chunk",
//	 "messageId":"<mid>","content":{"type":"text","text":"<text>"}}}
fn acp_chunk_update(sid string, mid string, text string) string {
	return '{"sessionId":"${sid}","update":{"sessionUpdate":"agent_message_chunk",' +
		'"messageId":"${mid}","content":{"type":"text","text":${json2.encode(text)}}}}'
}

// acp_build_result wraps a pre-encoded result JSON object in a JSON-RPC
// response envelope.
fn acp_build_result(id int, result_json string) string {
	return '{"id":${id},"result":${result_json}}'
}

// acp_build_error wraps an error code/message in a JSON-RPC error response.
fn acp_build_error(id int, code int, msg string) string {
	return '{"id":${id},"error":{"code":${code},"message":${json2.encode(msg)}}}'
}

// acp_build_notification wraps a pre-encoded params JSON object in a
// JSON-RPC notification envelope.
fn acp_build_notification(method string, params_json string) string {
	return '{"method":"${method}","params":${params_json}}'
}

// ── Output ──────────────────────────────────────────────────────────────

// send_result writes a result response for the given request id.
fn (mut s AcpServer) send_result(id int, result_json string) {
	s.write_line(acp_build_result(id, result_json))
}

// send_error writes an error response for the given request id.
fn (mut s AcpServer) send_error(id int, code int, msg string) {
	s.write_line(acp_build_error(id, code, msg))
}

// send_update streams one agent_message_chunk update for a session.
fn (mut s AcpServer) send_update(sid string, mid string, text string) {
	s.write_line(acp_build_notification('session/update', acp_chunk_update(sid, mid, text)))
}

// write_line emits one protocol line on stdout, mutex-protected and flushed
// immediately so the client never waits on a buffered pipe.
fn (mut s AcpServer) write_line(line string) {
	s.wmu.lock()
	println(line)
	os.flush()
	s.wmu.unlock()
}

// save_session persists a session to disk, best-effort (protocol continues
// even when persistence fails).
fn (mut s AcpServer) save_session(sess Session) {
	save(sess) or { s.log.warn('acp: session save failed: ${err.msg()}') }
}
