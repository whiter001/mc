// cron.v — Cron expression parsing and fire-time computation.
//
// Parity with kimi-code's cron tool (packages/agent-core/src/tools/cron):
// a session-scoped list of scheduled jobs, each a 5-field cron expression
// (minute hour day-of-month month day-of-week) plus a prompt. The TUI
// scheduler injects a due job's prompt as a user turn; one-shot jobs are
// deleted after firing, recurring jobs re-schedule from "now" (missed
// fire points while the process was down are caught up exactly once).
//
// Everything here is a pure function of explicit `now_ms` arguments so
// the scheduling logic is unit-testable without a clock or filesystem.
module main

import time

// cron_max_tasks is the per-session cap on scheduled jobs (parity with
// kimi-code's per-session limit).
pub const cron_max_tasks = 50

// cron_scan_years bounds how far next_fire_after scans into the future
// before giving up (impossible expressions like `0 0 31 2 *` never match).
const cron_scan_years = 5

// CronTask is one scheduled job. Persisted per session in
// <config-dir>/cron/<session-id>.json (see cron_store.v).
pub struct CronTask {
pub mut:
	id           string
	cron         string // 5-field cron expression
	prompt       string // injected as a user turn when the job fires
	recurring    bool   // false = one-shot: auto-deleted after firing
	created_at_ms i64  // epoch ms; anchor for the first fire computation
}

// CronSpec is a parsed cron expression: one bitmask per field (bit N set
// = value N matches). dom_star/dow_star remember whether the day-of-month
// / day-of-week fields were literally '*', which selects the standard
// cron OR-rule for day matching.
struct CronSpec {
	minutes  u64 // bits 0..59
	hours    u64 // bits 0..23
	dom      u64 // bits 1..31
	months   u64 // bits 1..12
	dow      u64 // bits 0..6 (Sunday = 0; input 7 folds into 0)
	dom_star bool
	dow_star bool
}

// parse_cron parses a 5-field cron expression. Each field supports `*`,
// `*/n`, single values `a`, ranges `a-b`, and comma lists of those.
// Returns an error on wrong field count, out-of-range values, or bad
// syntax.
pub fn parse_cron(expr string) !CronSpec {
	fields := expr.trim_space().fields()
	if fields.len != 5 {
		return error('cron expression must have exactly 5 fields (minute hour day-of-month month day-of-week), got ${fields.len}')
	}
	minutes, _ := parse_cron_field(fields[0], 0, 59)!
	hours, _ := parse_cron_field(fields[1], 0, 23)!
	dom, dom_star := parse_cron_field(fields[2], 1, 31)!
	months, _ := parse_cron_field(fields[3], 1, 12)!
	// day-of-week accepts 0-7 with both 0 and 7 meaning Sunday.
	dow_raw, dow_star := parse_cron_field(fields[4], 0, 7)!
	mut dow := dow_raw
	if dow_raw & (u64(1) << 7) != 0 {
		dow = (dow_raw & ~(u64(1) << 7)) | u64(1)
	}
	return CronSpec{
		minutes:  minutes
		hours:    hours
		dom:      dom
		months:   months
		dow:      dow
		dom_star: dom_star
		dow_star: dow_star
	}
}

// parse_cron_field parses one field into a value bitmask. Also reports
// whether the field is the bare wildcard `*` (needed for the dom/dow
// OR-rule).
fn parse_cron_field(field string, min int, max int) !(u64, bool) {
	if field.len == 0 {
		return error('empty cron field')
	}
	mut mask := u64(0)
	for part in field.split(',') {
		if part.len == 0 {
			return error('empty list item in cron field "${field}"')
		}
		// Optional step suffix: */n or a-b/n.
		mut base := part
		mut step := 1
		if part.contains('/') {
			pieces := part.split('/')
			if pieces.len != 2 || pieces[1].len == 0 {
				return error('invalid step in cron field "${part}"')
			}
			base = pieces[0]
			step = pieces[1].int()
			if step < 1 {
				return error('invalid step "${pieces[1]}" in cron field "${part}"')
			}
		}
		mut lo := 0
		mut hi := 0
		if base == '*' {
			lo = min
			hi = max
		} else if base.contains('-') {
			bounds := base.split('-')
			if bounds.len != 2 {
				return error('invalid range "${base}" in cron field')
			}
			lo = cron_field_value(bounds[0], min, max)!
			hi = cron_field_value(bounds[1], min, max)!
			if lo > hi {
				return error('inverted range "${base}" in cron field')
			}
		} else {
			lo = cron_field_value(base, min, max)!
			hi = lo
			// A bare value with a step (a/n) means a-max step n.
			if part.contains('/') {
				hi = max
			}
		}
		mut v := lo
		for v <= hi {
			mask |= u64(1) << v
			v += step
		}
	}
	return mask, field == '*'
}

// cron_field_value parses a single integer and bounds-checks it.
fn cron_field_value(s string, min int, max int) !int {
	if s.len == 0 || !s.is_int() {
		return error('invalid value "${s}" in cron field')
	}
	v := s.int()
	if v < min || v > max {
		return error('cron value ${v} out of range ${min}-${max}')
	}
	return v
}

// matches reports whether local time `t` satisfies the spec. Day matching
// follows the standard cron rule: when both day-of-month and day-of-week
// are restricted (neither is '*'), a day matches if EITHER matches.
fn (s CronSpec) matches(t time.Time) bool {
	if s.minutes & (u64(1) << t.minute) == 0 {
		return false
	}
	if s.hours & (u64(1) << t.hour) == 0 {
		return false
	}
	if s.months & (u64(1) << t.month) == 0 {
		return false
	}
	// time.Time.day_of_week(): Monday=1 .. Sunday=7; cron wants Sunday=0.
	dow := t.day_of_week() % 7
	dom_hit := s.dom & (u64(1) << t.day) != 0
	dow_hit := s.dow & (u64(1) << dow) != 0
	if s.dom_star && s.dow_star {
		return true
	}
	if s.dom_star {
		return dow_hit
	}
	if s.dow_star {
		return dom_hit
	}
	return dom_hit || dow_hit
}

// next_fire_after returns the epoch ms of the next minute boundary after
// `from_ms` (exclusive) whose local wall-clock time matches the cron
// expression. Scans minute-by-minute up to cron_scan_years ahead; returns
// an error when nothing matches in that window (e.g. Feb 31).
//
// Local time is derived via the current fixed UTC offset (time.offset());
// DST transitions mid-scan are not modelled — same pragmatic behaviour as
// most embedded crons.
pub fn next_fire_after(expr string, from_ms i64) !i64 {
	spec := parse_cron(expr)!
	offset_ms := i64(time.offset()) * 1000
	minute_ms := i64(60000)
	// Start at the next whole minute strictly after from_ms.
	mut m := (from_ms / minute_ms + 1) * minute_ms
	limit := from_ms + i64(cron_scan_years) * 365 * 24 * 60 * minute_ms
	for m <= limit {
		local := time.unix_milli(m + offset_ms)
		if spec.matches(local) {
			return m
		}
		m += minute_ms
	}
	return error('cron expression "${expr}" has no fire time within ${cron_scan_years} years')
}

// cron_human renders a short English description for the common cron
// patterns (shown by CronList). Unrecognised expressions are returned
// verbatim.
pub fn cron_human(expr string) string {
	fields := expr.trim_space().fields()
	if fields.len != 5 {
		return expr
	}
	m := fields[0]
	h := fields[1]
	dom := fields[2]
	mon := fields[3]
	dow := fields[4]
	if m == '*' && h == '*' && dom == '*' && mon == '*' && dow == '*' {
		return 'every minute'
	}
	if m.starts_with('*/') && h == '*' && dom == '*' && mon == '*' && dow == '*' {
		return 'every ${m[2..]} minutes'
	}
	if h == '*' && dom == '*' && mon == '*' && dow == '*' && m.is_int() {
		return 'hourly at minute ${m.int()}'
	}
	if m.is_int() && h.is_int() {
		at := 'at ${h.int():02}:${m.int():02}'
		if mon == '*' {
			if dom == '*' && dow == '*' {
				return '${at} daily'
			}
			if dom == '*' && dow.is_int() {
				return '${at} on ${cron_weekday_name(dow.int())}'
			}
			if dow == '*' && dom.is_int() {
				return '${at} on day ${dom.int()} of every month'
			}
		} else if mon.is_int() && dom.is_int() && dow == '*' {
			return '${at} on ${cron_month_name(mon.int())} ${dom.int()}'
		}
	}
	return expr
}

// cron_weekday_name maps a cron day-of-week (0/7 = Sunday) to a name.
fn cron_weekday_name(d int) string {
	return match (d % 7 + 7) % 7 {
		0 { 'Sunday' }
		1 { 'Monday' }
		2 { 'Tuesday' }
		3 { 'Wednesday' }
		4 { 'Thursday' }
		5 { 'Friday' }
		else { 'Saturday' }
	}
}

// cron_month_name maps a cron month (1-12) to a name.
fn cron_month_name(m int) string {
	return match m {
		1 { 'Jan' }
		2 { 'Feb' }
		3 { 'Mar' }
		4 { 'Apr' }
		5 { 'May' }
		6 { 'Jun' }
		7 { 'Jul' }
		8 { 'Aug' }
		9 { 'Sep' }
		10 { 'Oct' }
		11 { 'Nov' }
		else { 'Dec' }
	}
}

// check_due_cron returns the tasks due to fire at `now_ms`. `fired` maps
// task id → the anchor (epoch ms) of its last fire computation; the
// anchor starts at created_at_ms and jumps to `now_ms` on every fire, so
// a recurring task whose fire points were missed while the process was
// down (or the agent was busy) fires exactly once, not once per missed
// point. Tasks with unschedulable expressions are skipped silently.
pub fn check_due_cron(tasks []CronTask, mut fired map[string]i64, now_ms i64) []CronTask {
	mut due := []CronTask{}
	for t in tasks {
		anchor := fired[t.id] or { t.created_at_ms }
		next := next_fire_after(t.cron, anchor) or { continue }
		if next <= now_ms {
			fired[t.id] = now_ms
			due << t
		}
	}
	return due
}

// cron_remove_task removes the task with the given id from the list.
// Returns true when a task was actually removed.
pub fn cron_remove_task(mut tasks []CronTask, id string) bool {
	for i, t in tasks {
		if t.id == id {
			tasks.delete(i)
			return true
		}
	}
	return false
}

// cron_fire_prompt wraps a fired job's prompt in the <cron-fire> envelope
// the scheduler injects as a user turn (parity with kimi-code).
pub fn cron_fire_prompt(t CronTask) string {
	return '<cron-fire jobId="${t.id}" cron="${t.cron}" recurring=${t.recurring}>\n${t.prompt}\n</cron-fire>'
}

// new_cron_id generates a job id: timestamp + short random-ish suffix
// (same approach as session short_id — no extra entropy source needed).
fn new_cron_id() string {
	ts := time.now().unix_milli()
	rnd := time.now().unix_micro() & 0xFFFF
	return 'cron-${ts.hex()}-${rnd.hex()}'
}

// restore_cron_tasks loads the persisted cron table for the session onto
// the agent (mirrors restore_goal_from_metadata). Missing/corrupt files
// yield an empty table (fail-open — see cron_store.v).
pub fn restore_cron_tasks(mut a Agent, sess Session) {
	a.cron_tasks = load_cron_tasks(sess.id)
}
