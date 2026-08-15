// tools_cron.v — the Cron tools (parity with kimi-code's cron tool).
//
// CronCreate schedules a session-scoped job (5-field cron expression +
// prompt), CronList shows the session's jobs, CronDelete removes one.
// State lives on the Agent (the per-session singleton) — same pattern as
// the todo list and the Goal tools. Mutations are persisted immediately
// to <config-dir>/cron/<session-id>.json (see cron_store.v); the TUI
// scheduler (tui_loop.v) injects due jobs as user turns.
//
// In headless sessions (-p / ACP) the tools work but nothing fires:
// CronCreate says so in its result.
module main

import json2
import time

// cron_fmt_ms renders an epoch-ms fire time as local 'YYYY-MM-DD HH:mm'.
fn cron_fmt_ms(ms i64) string {
	return time.unix_milli(ms).utc_to_local().format()
}

// =============================================================================
// CronCreate
// =============================================================================

// CronCreateTool schedules a new cron job for the session.
pub struct CronCreateTool {
pub:
	agent &Agent
}

// name returns the tool identifier used in the registry and provider.
pub fn (t CronCreateTool) name() string {
	return 'CronCreate'
}

// description returns the human-readable description shown to the model.
pub fn (t CronCreateTool) description() string {
	return 'Schedule a cron job for this session: a 5-field cron expression (minute hour day-of-month month day-of-week, local time; supports "*", "*/n", "a", "a-b", "a,b,c") plus a prompt. When the job fires, the prompt is injected as a user message and you act on it. Set recurring=false for a one-shot reminder (auto-deleted after it fires). Max ${cron_max_tasks} jobs per session. Jobs fire only while an interactive session is alive.'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t CronCreateTool) parameters_schema() string {
	return '{"type":"object","properties":{"cron":{"type":"string","description":"5-field cron expression (minute hour day-of-month month day-of-week)"},"prompt":{"type":"string","description":"The prompt to inject when the job fires"},"recurring":{"type":"boolean","description":"true (default) = fires on schedule; false = one-shot, deleted after firing"}},"required":["cron","prompt"],"additionalProperties":false}'
}

// CronCreateArgs is the parsed JSON input for CronCreate. `recurring`
// defaults to true when the key is absent (see execute).
struct CronCreateArgs {
	cron      string
	prompt    string
	recurring bool
}

// execute validates the expression and installs the job on the agent.
pub fn (t CronCreateTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	parsed := json2.decode[CronCreateArgs](args.raw) or {
		return ToolResult{
			content:  'invalid arguments: ${err.msg()} (expected {"cron":..., "prompt":...})'
			is_error: true
		}
	}
	mut a := t.agent
	cron_expr := parsed.cron.trim_space()
	prompt := parsed.prompt.trim_space()
	// `recurring` is optional with a true default; the typed decode can't
	// distinguish "absent" from explicit false, so check the raw JSON.
	recurring := if args.raw.contains('"recurring"') { parsed.recurring } else { true }
	if cron_expr.len == 0 {
		return ToolResult{
			content:  'missing required argument: cron (non-empty)'
			is_error: true
		}
	}
	if prompt.len == 0 {
		return ToolResult{
			content:  'missing required argument: prompt (non-empty)'
			is_error: true
		}
	}
	if a.cron_tasks.len >= cron_max_tasks {
		return ToolResult{
			content:  'cron limit reached: this session already has ${cron_max_tasks} jobs (max). Delete some with CronDelete first.'
			is_error: true
		}
	}
	now := time.now().unix_milli()
	// Validates the expression AND proves it can actually fire (rules out
	// impossible schedules like `0 0 31 2 *`).
	next := next_fire_after(cron_expr, now) or {
		return ToolResult{
			content:  'invalid cron expression: ${err.msg()}'
			is_error: true
		}
	}
	task := CronTask{
		id:           new_cron_id()
		cron:         cron_expr
		prompt:       prompt
		recurring:    recurring
		created_at_ms: now
	}
	a.cron_tasks << task
	save_cron_tasks(a.session_id, a.cron_tasks) or {
		eprintln('[warn] failed to persist cron tasks: ${err.msg()}')
	}
	kind := if recurring { 'recurring' } else { 'one-shot' }
	mut content := 'Cron job created (${kind}): id=${task.id}, cron="${task.cron}" (${cron_human(task.cron)}), next fire at ${cron_fmt_ms(next)}.'
	if a.non_interactive {
		content += '\nNote: this is a headless session — a cron job fires only while an interactive session is alive.'
	}
	return ToolResult{
		content: content
	}
}

// =============================================================================
// CronList
// =============================================================================

// CronListTool lists the session's cron jobs (never errors).
pub struct CronListTool {
pub:
	agent &Agent
}

// name returns the tool identifier used in the registry and provider.
pub fn (t CronListTool) name() string {
	return 'CronList'
}

// description returns the human-readable description shown to the model.
pub fn (t CronListTool) description() string {
	return 'List all cron jobs for this session: id, cron expression, human-readable schedule, next fire time, recurring flag, and prompt.'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t CronListTool) parameters_schema() string {
	return '{"type":"object","properties":{},"additionalProperties":false}'
}

// execute renders the job table as text lines.
pub fn (t CronListTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	a := t.agent
	if a.cron_tasks.len == 0 {
		return ToolResult{
			content: 'No cron jobs for this session.'
		}
	}
	now := time.now().unix_milli()
	mut lines := []string{}
	lines << '${a.cron_tasks.len} cron job(s) for this session:'
	for task in a.cron_tasks {
		next_str := if next := next_fire_after(task.cron, now) {
			cron_fmt_ms(next)
		} else {
			'unschedulable'
		}
		lines << '- id=${task.id} cron="${task.cron}" (${cron_human(task.cron)}) next=${next_str} recurring=${task.recurring} prompt="${task.prompt}"'
	}
	return ToolResult{
		content: lines.join('\n')
	}
}

// =============================================================================
// CronDelete
// =============================================================================

// CronDeleteTool removes a cron job by id.
pub struct CronDeleteTool {
pub:
	agent &Agent
}

// name returns the tool identifier used in the registry and provider.
pub fn (t CronDeleteTool) name() string {
	return 'CronDelete'
}

// description returns the human-readable description shown to the model.
pub fn (t CronDeleteTool) description() string {
	return 'Delete a cron job from this session by id (see CronList for ids).'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t CronDeleteTool) parameters_schema() string {
	return '{"type":"object","properties":{"id":{"type":"string","description":"The job id to delete"}},"required":["id"],"additionalProperties":false}'
}

// CronDeleteArgs is the parsed JSON input for CronDelete.
struct CronDeleteArgs {
	id string
}

// execute removes the job and persists the table.
pub fn (t CronDeleteTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	parsed := json2.decode[CronDeleteArgs](args.raw) or {
		return ToolResult{
			content:  'invalid arguments: ${err.msg()} (expected {"id":...})'
			is_error: true
		}
	}
	mut a := t.agent
	if parsed.id.trim_space().len == 0 {
		return ToolResult{
			content:  'missing required argument: id'
			is_error: true
		}
	}
	if !cron_remove_task(mut a.cron_tasks, parsed.id) {
		return ToolResult{
			content:  'cron job not found: ${parsed.id}'
			is_error: true
		}
	}
	save_cron_tasks(a.session_id, a.cron_tasks) or {
		eprintln('[warn] failed to persist cron tasks: ${err.msg()}')
	}
	return ToolResult{
		content: 'Cron job deleted: ${parsed.id} (${a.cron_tasks.len} remaining)'
	}
}
