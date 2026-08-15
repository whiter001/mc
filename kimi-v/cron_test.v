// cron_test.v — unit tests for the cron system: expression parsing,
// next-fire computation, the due-check / one-shot logic (all pure), the
// store roundtrip (isolated KIMI_CONFIG_DIR), and the tool-level 50-job
// cap. Tests within this file run sequentially (env mutation).
module main

import os
import time

// cron_test_dir returns a unique scratch config dir for one test.
fn cron_test_dir(suffix string) string {
	return os.join_path(os.temp_dir(), 'kimi-cron-test-' + suffix)
}

// local_of converts epoch ms to a Time carrying local wall-clock fields
// (same fixed-offset derivation next_fire_after uses, so the assertions
// below are timezone-independent).
fn local_of(ms i64) time.Time {
	return time.unix_milli(ms + i64(time.offset()) * 1000)
}

// CronFakeProvider satisfies the Provider interface for tool-level tests;
// chat is never called (the Cron tools don't talk to the model).
struct CronFakeProvider {
	name     string = 'fake'
	model    string = 'fake-model'
	api_base string = 'http://fake'
	api_key  string = 'fake-key'
}

fn (p CronFakeProvider) chat(req ChatRequest, out chan ChatEvent, cancel_ch chan int) ! {
	return error('not implemented')
}

fn new_cron_test_agent(session_id string) Agent {
	mut a := new_agent(CronFakeProvider{}, '')
	a.session_id = session_id
	return a
}

// ---------- expression parsing ----------------------------------------------

fn test_parse_cron_valid_expressions() {
	for expr in ['*/5 * * * *', '0 9 * * *', '30 14 28 2 *', '* * * * *', '0 9-17 * * *',
		'0 9 * * 1,3,5', '15,45 8 * * 0', '*/15 9-18/2 1,15 1-6 *'] {
		parse_cron(expr) or { assert false, 'expected "${expr}" to parse: ${err.msg()}' }
	}
}

fn test_parse_cron_rejects_wrong_field_count() {
	for expr in ['* * * *', '* * * * * *', ''] {
		parse_cron(expr) or { continue }
		assert false, 'expected field-count error for "${expr}"'
	}
}

fn test_parse_cron_rejects_bad_values() {
	for expr in ['61 * * * *', '* 25 * * *', '* * 0 * *', '* * * 13 *', '* * * * 8',
		'abc * * * *', '*/0 * * * *', '5-2 * * * *', '1-2-3 * * * *'] {
		parse_cron(expr) or { continue }
		assert false, 'expected parse error for "${expr}"'
	}
}

fn test_parse_cron_dow_seven_is_sunday() {
	seven := parse_cron('0 9 * * 7')!
	zero := parse_cron('0 9 * * 0')!
	assert seven.dow == zero.dow
}

// ---------- next_fire_after ---------------------------------------------------

fn test_next_fire_every_5_minutes() {
	from := i64(1700000000000) // arbitrary fixed instant
	next := next_fire_after('*/5 * * * *', from)!
	assert next > from
	assert next % 60000 == 0
	l := local_of(next)
	assert l.minute % 5 == 0
	assert next - from <= 5 * 60000
}

fn test_next_fire_daily_at_9() {
	from := i64(1700000000000)
	next := next_fire_after('0 9 * * *', from)!
	l := local_of(next)
	assert l.hour == 9 && l.minute == 0
	assert next > from
	// Always within the next 24h + one minute of slack.
	assert next - from <= i64(24)*3600*1000 + 60000
	// From just before a fire point, the next fire is that point.
	just_before := next - 30000
	again := next_fire_after('0 9 * * *', just_before)!
	assert again == next
}

fn test_next_fire_crosses_month_boundary() {
	// From late January, `0 0 1 * *` must land on the 1st of a later month.
	from := i64(1706400000000) // 2024-01-28
	next := next_fire_after('0 0 1 * *', from)!
	l := local_of(next)
	assert l.day == 1 && l.hour == 0 && l.minute == 0
	assert l.month == 2 // next 1st-of-month after Jan 28
	assert next > from
}

fn test_next_fire_impossible_expression_errors() {
	// Feb 31 never happens; the 5-year scan must give up.
	next_fire_after('0 0 31 2 *', i64(1700000000000)) or {
		assert err.msg().contains('no fire time')
		return
	}
	assert false, 'expected an error for an impossible expression'
}

fn test_next_fire_dow_or_rule() {
	// Both dom and dow restricted → match when either matches. From a
	// known Wednesday (2024-01-03), `0 0 15 * 1` (15th OR Monday) must
	// fire on Monday Jan 8, before the 15th.
	from := i64(1704240000000) // 2024-01-03 00:00 UTC; local may shift the day slightly
	next := next_fire_after('0 0 15 * 1', from)!
	l := local_of(next)
	is_monday := l.day_of_week() == 1
	is_15th := l.day == 15
	assert is_monday || is_15th
	assert next - from <= 7 * 24 * 3600 * 1000
}

// ---------- cron_human --------------------------------------------------------

fn test_cron_human_common_patterns() {
	assert cron_human('* * * * *') == 'every minute'
	assert cron_human('*/5 * * * *') == 'every 5 minutes'
	assert cron_human('30 * * * *') == 'hourly at minute 30'
	assert cron_human('0 9 * * *') == 'at 09:00 daily'
	assert cron_human('0 9 * * 1') == 'at 09:00 on Monday'
	assert cron_human('0 9 15 * *') == 'at 09:00 on day 15 of every month'
	assert cron_human('0 9 28 2 *') == 'at 09:00 on Feb 28'
	// Complex expressions fall back to the raw form.
	assert cron_human('*/15 9-18/2 1,15 1-6 *') == '*/15 9-18/2 1,15 1-6 *'
}

// ---------- due check / one-shot logic (pure) ---------------------------------

fn test_check_due_cron_fires_once_for_missed_points() {
	t0 := i64(1700000000000)
	tasks := [CronTask{
		id:           'a'
		cron:         '*/5 * * * *'
		prompt:       'p'
		recurring:    true
		created_at_ms: t0
	}]
	mut fired := map[string]i64{}
	// Two hours later: many fire points were missed, but the recurring
	// catch-up rule yields exactly one due injection.
	now := t0 + 2 * 3600 * 1000
	due := check_due_cron(tasks, mut fired, now)
	assert due.len == 1
	assert due[0].id == 'a'
	assert fired['a'] == now
	// Right after the catch-up the anchor is "now", so nothing is due.
	assert check_due_cron(tasks, mut fired, now + 1000).len == 0
	// And it is not due before its first fire point either.
	mut fresh := map[string]i64{}
	assert check_due_cron(tasks, mut fresh, t0 + 1000).len == 0
}

fn test_check_due_cron_skips_unschedulable() {
	tasks := [CronTask{
		id:           'bad'
		cron:         '0 0 31 2 *'
		prompt:       'p'
		recurring:    true
		created_at_ms: i64(1700000000000)
	}]
	mut fired := map[string]i64{}
	assert check_due_cron(tasks, mut fired, i64(1700000000000) + 3600 * 1000).len == 0
}

fn test_cron_remove_task_one_shot() {
	mut tasks := [
		CronTask{ id: 'one', cron: '* * * * *', prompt: 'a', recurring: false },
		CronTask{ id: 'two', cron: '* * * * *', prompt: 'b', recurring: true },
	]
	// One-shot semantics: after firing, the job is removed from the table.
	assert cron_remove_task(mut tasks, 'one')
	assert tasks.len == 1
	assert tasks[0].id == 'two'
	// Removing again (or an unknown id) reports "not found".
	assert !cron_remove_task(mut tasks, 'one')
	assert !cron_remove_task(mut tasks, 'nope')
	assert tasks.len == 1
}

fn test_cron_fire_prompt_envelope() {
	t := CronTask{
		id:        'cron-1'
		cron:      '*/5 * * * *'
		prompt:    'check the build'
		recurring: true
	}
	p := cron_fire_prompt(t)
	assert p == '<cron-fire jobId="cron-1" cron="*/5 * * * *" recurring=true>\ncheck the build\n</cron-fire>'
}

// ---------- store --------------------------------------------------------------

fn test_cron_store_roundtrip() {
	dir := cron_test_dir('roundtrip')
	os.setenv('KIMI_CONFIG_DIR', dir, true)
	defer {
		os.setenv('KIMI_CONFIG_DIR', '', true)
		os.rmdir_all(dir) or {}
	}
	tasks := [
		CronTask{
			id:           'cron-a'
			cron:         '*/5 * * * *'
			prompt:       'ping'
			recurring:    true
			created_at_ms: 1700000000000
		},
		CronTask{
			id:           'cron-b'
			cron:         '0 9 * * *'
			prompt:       'standup'
			recurring:    false
			created_at_ms: 1700000060000
		},
	]
	save_cron_tasks('sess-1', tasks)!
	loaded := load_cron_tasks('sess-1')
	assert loaded.len == 2
	assert loaded[0] == tasks[0]
	assert loaded[1] == tasks[1]
	// Unknown session → empty table, no error.
	assert load_cron_tasks('sess-nope').len == 0
}

fn test_cron_store_corrupt_file_fail_open() {
	dir := cron_test_dir('corrupt')
	os.setenv('KIMI_CONFIG_DIR', dir, true)
	defer {
		os.setenv('KIMI_CONFIG_DIR', '', true)
		os.rmdir_all(dir) or {}
	}
	ensure_dir(cron_dir())!
	os.write_file(cron_store_path('sess-bad'), '{not json')!
	// A corrupt store is a warning + empty table, never a hard failure.
	assert load_cron_tasks('sess-bad').len == 0
}

// ---------- tools ----------------------------------------------------------------

fn test_cron_create_and_delete_tool() {
	dir := cron_test_dir('tools')
	os.setenv('KIMI_CONFIG_DIR', dir, true)
	defer {
		os.setenv('KIMI_CONFIG_DIR', '', true)
		os.rmdir_all(dir) or {}
	}
	mut a := new_cron_test_agent('sess-tools')
	ctx := ToolContext{
		cwd:   '/tmp'
		agent: &a
	}
	create := CronCreateTool{ agent: &a }
	// Default recurring=true when the key is absent.
	res := create.execute(ToolArgs{ raw: '{"cron":"*/5 * * * *","prompt":"ping"}' }, ctx) or {
		assert false, 'create failed: ${err.msg()}'
		return
	}
	assert !res.is_error
	assert res.content.contains('next fire at')
	assert a.cron_tasks.len == 1
	assert a.cron_tasks[0].recurring
	assert a.cron_tasks[0].id.starts_with('cron-')
	// Persisted eagerly on create.
	assert load_cron_tasks('sess-tools').len == 1
	// Explicit recurring=false → one-shot.
	res2 := create.execute(ToolArgs{ raw: '{"cron":"0 9 * * *","prompt":"once","recurring":false}' },
		ctx) or {
		assert false, 'create failed: ${err.msg()}'
		return
	}
	assert !res2.is_error && res2.content.contains('one-shot')
	assert a.cron_tasks.len == 2 && !a.cron_tasks[1].recurring

	list := CronListTool{ agent: &a }
	lres := list.execute(ToolArgs{ raw: '{}' }, ctx) or { panic(err) }
	assert lres.content.contains('every 5 minutes')
	assert lres.content.contains('recurring=false')

	del := CronDeleteTool{ agent: &a }
	dres := del.execute(ToolArgs{ raw: '{"id":"${a.cron_tasks[0].id}"}' }, ctx) or { panic(err) }
	assert !dres.is_error
	assert a.cron_tasks.len == 1
	assert load_cron_tasks('sess-tools').len == 1
	// Unknown id → is_error.
	dres2 := del.execute(ToolArgs{ raw: '{"id":"nope"}' }, ctx) or { panic(err) }
	assert dres2.is_error
}

fn test_cron_create_validation_errors() {
	dir := cron_test_dir('validate')
	os.setenv('KIMI_CONFIG_DIR', dir, true)
	defer {
		os.setenv('KIMI_CONFIG_DIR', '', true)
		os.rmdir_all(dir) or {}
	}
	mut a := new_cron_test_agent('sess-validate')
	ctx := ToolContext{
		cwd:   '/tmp'
		agent: &a
	}
	create := CronCreateTool{ agent: &a }
	// Empty prompt.
	r1 := create.execute(ToolArgs{ raw: '{"cron":"* * * * *","prompt":"  "}' }, ctx) or {
		panic(err)
	}
	assert r1.is_error
	// Unparseable expression.
	r2 := create.execute(ToolArgs{ raw: '{"cron":"not cron","prompt":"x"}' }, ctx) or {
		panic(err)
	}
	assert r2.is_error
	// Parseable but impossible schedule.
	r3 := create.execute(ToolArgs{ raw: '{"cron":"0 0 31 2 *","prompt":"x"}' }, ctx) or {
		panic(err)
	}
	assert r3.is_error
	assert a.cron_tasks.len == 0
}

fn test_cron_create_enforces_max_tasks() {
	dir := cron_test_dir('cap')
	os.setenv('KIMI_CONFIG_DIR', dir, true)
	defer {
		os.setenv('KIMI_CONFIG_DIR', '', true)
		os.rmdir_all(dir) or {}
	}
	mut a := new_cron_test_agent('sess-cap')
	for i in 0 .. cron_max_tasks {
		a.cron_tasks << CronTask{
			id:           't${i}'
			cron:         '* * * * *'
			prompt:       'p'
			created_at_ms: 1
		}
	}
	create := CronCreateTool{ agent: &a }
	res := create.execute(ToolArgs{ raw: '{"cron":"* * * * *","prompt":"x"}' }, ToolContext{
		cwd:   '/tmp'
		agent: &a
	}) or { panic(err) }
	assert res.is_error
	assert res.content.contains('${cron_max_tasks}')
	assert a.cron_tasks.len == cron_max_tasks
}

fn test_cron_create_notes_headless_session() {
	dir := cron_test_dir('headless')
	os.setenv('KIMI_CONFIG_DIR', dir, true)
	defer {
		os.setenv('KIMI_CONFIG_DIR', '', true)
		os.rmdir_all(dir) or {}
	}
	mut a := new_cron_test_agent('sess-headless')
	a.non_interactive = true
	create := CronCreateTool{ agent: &a }
	res := create.execute(ToolArgs{ raw: '{"cron":"* * * * *","prompt":"x"}' }, ToolContext{
		cwd:   '/tmp'
		agent: &a
	}) or { panic(err) }
	assert !res.is_error
	assert res.content.contains('fires only while an interactive session is alive')
}

fn test_cron_list_empty() {
	mut a := new_cron_test_agent('sess-empty')
	list := CronListTool{ agent: &a }
	res := list.execute(ToolArgs{ raw: '{}' }, ToolContext{
		cwd:   '/tmp'
		agent: &a
	}) or { panic(err) }
	assert res.content == 'No cron jobs for this session.'
}
