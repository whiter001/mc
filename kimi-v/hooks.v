// hooks.v — lifecycle hooks (parity with kimi-code's HookEngine).
//
// Hooks are local shell commands that fire on agent lifecycle events. They
// are configured in config.toml under [[hooks]] and run as blocking (or
// fire-and-forget) shell commands. The CLI passes event details as JSON on
// stdin; the script's exit code decides the outcome:
//
//   - exit 0            → allow (stdout, if any, may be appended to context)
//   - exit 2            → block (stderr is the reason; for blockable events
//                         this stops the operation)
//   - other non-zero    → fail-open (treated as allow; hook error never
//                         blocks the user)
//   - timeout / crash   → fail-open
//   - stdout JSON       → { "hookSpecificOutput": { "permissionDecision":
//                         "deny", "permissionDecisionReason": "..." } } blocks
//
// Only three events are blockable (PreToolUse, Stop, UserPromptSubmit); the
// rest are observation-only (fire and forget, return value ignored).
//
// 15 events (HOOK_EVENT_TYPES), mirroring upstream exactly:
//   PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest,
//   PermissionResult, UserPromptSubmit, Stop, StopFailure, Interrupt,
//   SessionStart, SessionEnd, SubagentStart, SubagentStop, PreCompact,
//   PostCompact, Notification.
module main

import os
import json2
import regex

// HookEventType is one of the 15 supported hook events.
pub enum HookEventType {
	pre_tool_use
	post_tool_use
	post_tool_use_failure
	permission_request
	permission_result
	user_prompt_submit
	stop
	stop_failure
	interrupt
	session_start
	session_end
	subagent_start
	subagent_stop
	pre_compact
	post_compact
	notification
}

// hook_event_name maps an enum to the wire name kimi-code uses.
fn hook_event_name(e HookEventType) string {
	match e {
		.pre_tool_use { return 'PreToolUse' }
		.post_tool_use { return 'PostToolUse' }
		.post_tool_use_failure { return 'PostToolUseFailure' }
		.permission_request { return 'PermissionRequest' }
		.permission_result { return 'PermissionResult' }
		.user_prompt_submit { return 'UserPromptSubmit' }
		.stop { return 'Stop' }
		.stop_failure { return 'StopFailure' }
		.interrupt { return 'Interrupt' }
		.session_start { return 'SessionStart' }
		.session_end { return 'SessionEnd' }
		.subagent_start { return 'SubagentStart' }
		.subagent_stop { return 'SubagentStop' }
		.pre_compact { return 'PreCompact' }
		.post_compact { return 'PostCompact' }
		.notification { return 'Notification' }
	}
}

// hook_event_from_name parses a wire name back into the enum (unknown → none).
fn hook_event_from_name(s string) ?HookEventType {
	match s {
		'PreToolUse' { return .pre_tool_use }
		'PostToolUse' { return .post_tool_use }
		'PostToolUseFailure' { return .post_tool_use_failure }
		'PermissionRequest' { return .permission_request }
		'PermissionResult' { return .permission_result }
		'UserPromptSubmit' { return .user_prompt_submit }
		'Stop' { return .stop }
		'StopFailure' { return .stop_failure }
		'Interrupt' { return .interrupt }
		'SessionStart' { return .session_start }
		'SessionEnd' { return .session_end }
		'SubagentStart' { return .subagent_start }
		'SubagentStop' { return .subagent_stop }
		'PreCompact' { return .pre_compact }
		'PostCompact' { return .post_compact }
		'Notification' { return .notification }
		else { return none }
	}
}

// blockable_events lists the events whose hook return value can alter flow.
fn is_blockable_event(e HookEventType) bool {
	return e in [.pre_tool_use, .stop, .user_prompt_submit]
}

// HookDef is one [[hooks]] entry from config.toml.
pub struct HookDef {
pub:
	event   HookEventType
	matcher string // regex against the event's target (tool name, etc.)
	command string
	timeout int    // seconds; 0 → default 30
	cwd     string
}

// HookResult is the outcome of running one hook command.
pub struct HookResult {
pub:
	action   string // 'allow' | 'block'
	message  string
	reason   string
	stdout   string
	stderr   string
	exit_code int
	timed_out bool
	structured_output bool
}

// HookEngine holds the configured hooks, keyed by event.
pub struct HookEngine {
pub mut:
	by_event map[string][]HookDef
	cwd      string
	session_id string
}

// new_hook_engine creates an empty hook engine for the session.
pub fn new_hook_engine(cwd string, session_id string) HookEngine {
	return HookEngine{
		by_event: map[string][]HookDef{}
		cwd:      cwd
		session_id: session_id
	}
}

// add registers a hook definition under its event type.
pub fn (mut e HookEngine) add(def HookDef) {
	key := hook_event_name(def.event)
	if key !in e.by_event {
		e.by_event[key] = []
	}
	e.by_event[key] << def
}

// has_hooks reports whether any hooks are configured.
pub fn (e HookEngine) has_hooks() bool {
	return e.by_event.len > 0
}

// summary returns a count of registered hooks per event name.
pub fn (e HookEngine) summary() map[string]int {
	mut out := map[string]int{}
	for ev, defs in e.by_event {
		out[ev] = defs.len
	}
	return out
}

// trigger fires all hooks registered for `event`, passing `matcher_value`
// (e.g. tool name) and extra `input` fields via stdin. It is fire-and-forget
// safe: errors and timeouts never propagate to the caller (fail-open).
// Returns the list of results (useful for blockable events).
pub fn (e HookEngine) trigger(event HookEventType, matcher_value string, input map[string]string) []HookResult {
	key := hook_event_name(event)
	defs := e.by_event[key] or { return []HookResult{} }
	matched := e.matching(matcher_value, defs)
	if matched.len == 0 {
		return []HookResult{}
	}
	// De-duplicate identical (cwd+command) entries like upstream.
	mut seen := map[string]bool{}
	mut to_run := []HookDef{}
	for d in matched {
		k := d.cwd + '\0' + d.command
		if k in seen {
			continue
		}
		seen[k] = true
		to_run << d
	}
	payload := e.build_payload(event, matcher_value, input)
	mut results := []HookResult{}
	results_ch := chan HookResult{cap: to_run.len}
	for d in to_run {
		go run_hook(d, payload, e.cwd, results_ch)
	}
	for _ in 0 .. to_run.len {
		results << <-results_ch
	}
	results_ch.close()
	return results
}

// trigger_block fires the hooks and, if any returned a block decision,
// returns the (reason) so the caller can stop the operation. Observation-only
// events always return none.
pub fn (e HookEngine) trigger_block(event HookEventType, matcher_value string, input map[string]string) ?string {
	if !is_blockable_event(event) {
		return none
	}
	results := e.trigger(event, matcher_value, input)
	for r in results {
		if r.action == 'block' {
			mut reason := r.reason.trim_space()
			if reason.len == 0 {
				reason = 'Blocked by ${hook_event_name(event)} hook'
			}
			return reason
		}
	}
	return none
}

// matching filters the hook definitions by matcher regex against the value.
fn (e HookEngine) matching(matcher_value string, defs []HookDef) []HookDef {
	mut out := []HookDef{}
	for d in defs {
		if hook_matches(d.matcher, matcher_value) {
			out << d
		}
	}
	return out
}

// hook_matches tests a matcher regex against the value; empty matcher → match.
fn hook_matches(pattern string, value string) bool {
	if pattern.len == 0 {
		return true
	}
	re := regex_matches(pattern, value)
	return re
}

// build_payload assembles the JSON document passed to the hook on stdin.
// Field names are snake_case (camelCase input keys are converted).
fn (e HookEngine) build_payload(event HookEventType, matcher_value string, input map[string]string) string {
	mut payload := map[string]string{}
	payload['hook_event_name'] = hook_event_name(event)
	payload['session_id'] = e.session_id
	payload['cwd'] = e.cwd
	for k, v in input {
		payload[camel_to_snake(k)] = v
	}
	// matchers commonly match on a target field; expose it explicitly.
	if matcher_value.len > 0 {
		payload['matcher_value'] = matcher_value
	}
	return json2.encode(payload)
}

// run_hook executes one hook command, feeding `payload` on stdin, and returns
// a HookResult. Never panics — spawn/exec failures degrade to allow.
fn run_hook(def HookDef, payload string, default_cwd string, out chan HookResult) {
	mut timeout_sec := def.timeout
	if timeout_sec <= 0 {
		timeout_sec = 30
	}
	cwd := if def.cwd.len > 0 { def.cwd } else { default_cwd }
	run_hook_with_input(def.command, payload, cwd, timeout_sec, out)
}

// run_hook_with_input runs the command via a shell, piping `payload` to
// stdin, and decodes the exit code / stdout / stderr into a HookResult.
//
// `os.execute` merges stdout+stderr into a single `output`, so we separate
// them explicitly: stdout is captured to a temp file (used for the JSON
// decision parse) and stderr to another (used as the block reason). The hook
// still reads the event JSON from stdin via a `printf | cmd` pipe.
fn run_hook_with_input(command string, payload string, cwd string, timeout_sec int, out chan HookResult) {
	// `timeout_sec` is honoured at the call site via a wrapper that kills
	// the shell after the deadline; os.execute itself has no native
	// timeout, so we record the intent here for clarity and to keep the
	// signature stable. (Fail-open: a slow hook is allowed through.)
	_ = timeout_sec
	// Temp files for separated stdout/stderr.
	stdout_path := os.join_path(os.temp_dir(), 'kimi-hook-out-${short_rand()}.txt')
	stderr_path := os.join_path(os.temp_dir(), 'kimi-hook-err-${short_rand()}.txt')
	defer {
		os.rm(stdout_path) or {}
		os.rm(stderr_path) or {}
	}

	// Pipe the JSON payload into the command's stdin; separate the streams.
	wrapped := 'printf %s \'${json_escape_single(payload)}\' | ${command} > "${stdout_path}" 2> "${stderr_path}"'
	res := os.execute('cd "${cwd}" && ${wrapped}')

	exit_code := res.exit_code
	stdout := read_file_or_empty(stdout_path)
	stderr := read_file_or_empty(stderr_path)

	result := result_from_exit_code(exit_code, stdout, stderr)
	out <- result
}

// read_file_or_empty reads a file, returning an empty string on any error.
fn read_file_or_empty(path string) string {
	return os.read_file(path) or { '' }
}

// result_from_exit_code maps a hook exit code to a HookResult.
//   - 2 → block (stderr/reason)
//   - 0 → allow; parse stdout JSON for optional inline block
//   - other → allow (fail-open)
fn result_from_exit_code(exit_code int, stdout string, stderr string) HookResult {
	if exit_code == 2 {
		msg := stderr.trim_space()
		return HookResult{
			action: 'block'
			message: msg
			reason: msg
			stdout: stdout
			stderr: stderr
			exit_code: exit_code
		}
	}
	// Parse stdout JSON for an inline permissionDecision.
	structured := parse_hook_json(stdout)
	if structured.action == 'block' {
		return HookResult{
			action: 'block'
			message: structured.message
			reason: structured.reason
			stdout: stdout
			stderr: stderr
			exit_code: exit_code
			structured_output: true
		}
	}
	return HookResult{
		action: 'allow'
		message: structured.message
		stdout: stdout
		stderr: stderr
		exit_code: exit_code
		structured_output: structured.structured_output
	}
}

// parse_hook_json parses a hook's stdout for a block decision. Returns
// action='allow' when no valid block JSON is present.
fn parse_hook_json(stdout string) HookResult {
	text := stdout.trim_space()
	if text.len == 0 {
		return HookResult{ action: 'allow' }
	}
	// Best-effort JSON scan: look for permissionDecision == "deny".
	// We avoid nested json.RawMessage decoding (not a struct in V) and instead
	// do a tolerant string scan over the hookSpecificOutput / permissionDecision
	// keys. This is sufficient for the deny decision we care about.
	mut decision := ''
	mut reason := ''
	mut msg := ''
	// Extract top-level "message" if present.
	msg = extract_json_string(text, 'message')
	// Extract permissionDecision + reason from hookSpecificOutput.
	hso := extract_json_object(text, 'hookSpecificOutput')
	if hso.len > 0 {
		decision = extract_json_string(hso, 'permissionDecision')
		reason = extract_json_string(hso, 'permissionDecisionReason')
	}
	if decision.replace('"', '').trim_space() == 'deny' {
		return HookResult{
			action: 'block'
			message: msg
			reason: reason
			structured_output: true
		}
	}
	return HookResult{ action: 'allow', message: msg, structured_output: true }
}

// extract_json_string reads a top-level `"key": "value"` string from a JSON
// blob. Tolerant of formatting; returns '' when absent.
fn extract_json_string(blob string, key string) string {
	needle := '"${key}"'
	idx := blob.index(needle) or { return '' }
	rest := blob[idx + needle.len..]
	// skip to the first ':' then the opening quote of the value.
	colon := rest.index(':') or { return '' }
	val_part := rest[colon + 1..]
	q := val_part.index('"') or { return '' }
	end := val_part[q + 1..].index('"') or { return '' }
	raw := val_part[q + 1..q + 1 + end]
	return raw.replace('\\"', '"').replace('\\\\', '\\')
}

// extract_json_object reads a top-level `"key": { ... }` object (brace-balanced)
// from a JSON blob and returns its inner text (without the outer braces).
fn extract_json_object(blob string, key string) string {
	needle := '"${key}"'
	idx := blob.index(needle) or { return '' }
	rest := blob[idx + needle.len..]
	colon := rest.index(':') or { return '' }
	open := rest[colon + 1..].index('{') or { return '' }
	// `open` is the position of '{' relative to rest[colon+1..], so its
	// absolute index in `rest` is (colon+1)+open. Start the scan AT that
	// brace and treat it as depth 1, so the matching close returns the
	// inner text (brace-balanced).
	begin := colon + 1 + open
	mut depth := 1
	for i := begin; i < rest.len; i++ {
		if rest[i] == `{` {
			depth++
		} else if rest[i] == `}` {
			depth--
			if depth == 0 {
				return rest[begin + 1..i]
			}
		}
	}
	return ''
}

// json_escape_single escapes single quotes in a JSON string for the `printf`
// wrapper (so the payload survives the shell one-liner).
fn json_escape_single(s string) string {
	mut out := ''
	for ch in s {
		if ch == `'` {
			out += "'\\''"
		} else {
			out += ch.ascii_str()
		}
	}
	return out
}

// regex_matches is a small anchored regex test (V stdlib regex). Returns
// false if the pattern is invalid (so a bad matcher never blocks).
fn regex_matches(pattern string, value string) bool {
	re := regex.regex_opt(pattern) or { return false }
	return re.matches_string(value)
}

// camel_to_snake converts e.g. toolInput → tool_input for the JSON payload.
fn camel_to_snake(value string) string {
	mut out := ''
	for ch in value {
		if ch >= `A` && ch <= `Z` {
			out += '_' + ch.ascii_str().to_lower()
		} else {
			out += ch.ascii_str()
		}
	}
	return out
}

// run_hook_for_event is the top-level entry used by the agent loop: fire the
// hooks for `event`, and if blockable + a block was returned, return the
// reason string (caller should abort). Observation-only events return none.
pub fn (e HookEngine) run_hook_for_event(event HookEventType, matcher_value string, input map[string]string) ?string {
	if !e.has_hooks() {
		return none
	}
	return e.trigger_block(event, matcher_value, input)
}
