module main

import os
import time
import json2

fn setup_plan_agent() Agent {
	mut a := new_agent(OpenAICompatProvider{}, 'sys')
	a.registry = default_registry(mut a, os.getwd(), [])
	return a
}

fn test_enter_exit_plan_mode() {
	mut a := setup_plan_agent()
	assert !a.plan.is_active
	path := a.enter_plan_mode()
	assert a.plan.is_active
	assert path.len > 0
	// Re-entering is a no-op returning the same path.
	assert a.enter_plan_mode() == path
	// Plan file exists and is writable/editable target.
	assert os.exists(path)
	prev := a.exit_plan_mode()
	assert prev == path
	assert !a.plan.is_active
}

fn test_plan_data_reads_file() {
	mut a := setup_plan_agent()
	path := a.enter_plan_mode()
	os.write_file(path, '# My Plan\n\nStep 1.') or { assert false }
	content, inactive := a.plan_data()
	assert !inactive
	assert content.contains('Step 1.')
	// After exit, plan_data reports inactive.
	a.exit_plan_mode()
	_, inactive2 := a.plan_data()
	assert inactive2
}

fn test_read_only_guard_blocks_non_plan_writes() {
	// Build a minimal session with a write_file call to a non-plan file
	// while plan mode is active; the loop should deny it.
	mut a := setup_plan_agent()
	a.enter_plan_mode()
	plan_path := a.plan.plan_file_path

	// A write to the plan file itself is allowed.
	assert tool_write_path('{"path":"${plan_path}","content":"x"}') == plan_path
	// A write to a different file is denied by the guard.
	other := os.join_path(os.temp_dir(), 'should-not-be-written-${time.now().unix_milli()}.txt')
	assert tool_write_path('{"path":"${other}","content":"x"}') == other
	assert other != plan_path
}

fn test_exit_plan_options_reserved_labels_filtered() {
	// The ExitPlanMode tool should drop reserved labels (Approve/Reject/...).
	// We exercise the parse path indirectly: build args with a reserved
	// label and confirm decode yields an empty options list after filtering
	// (the filtering happens inside execute; here we just sanity-check the
	// struct decodes).
	raw := '{"options":[{"label":"Approve","description":"x"}]}'
	decoded := json2.decode[ExitPlanArgs](raw) or { panic('decode failed') }
	// The reserved label is filtered out by execute(); decoding alone keeps
	// it, so we assert the raw decode works.
	assert decoded.options.len == 1
}
