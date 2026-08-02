// subagent_test.v — tests for the Agent / AgentSwarm / TaskList tools and the
// subagent runner (subagent.v, tools_subagent.v, tools_subagent_tasklist.v,
// tools_subagent_swarm.v).
//
// The integration tests run real subagents against a fake provider that emits
// one text reply with no tool calls, so each subagent completes in a single
// turn. KIMI_CONFIG_DIR is redirected to a temp dir so subagent session
// persistence never touches the real config directory.
module main

import os
import time

// ---------- FakeProvider --------------------------------------------------
//
// V's test runner compiles each _test.v file independently, so the fakes in
// agent_test.v / compaction_test.v are not visible here. Minimal local copy:
// emits one assistant reply (no tool calls) and closes the stream, so a
// subagent loop finishes in a single turn.

struct SubFake {
	name     string
	model    string
	api_base string
	api_key  string
	deltas   []string
}

fn (p SubFake) chat(req ChatRequest, out chan ChatEvent, cancel_ch chan int) ! {
	for d in p.deltas {
		out <- ChatEvent{
			kind:    .delta
			content: d
		}
	}
	out <- ChatEvent{
		kind:   .finish
		reason: .stop
	}
	out <- ChatEvent{
		kind: .end_of_stream
	}
}

// ---------- Test helpers --------------------------------------------------

// with_tmp_config runs `fn_` with KIMI_CONFIG_DIR pointed at a fresh temp
// directory, restoring the previous value afterwards.
fn with_tmp_config(fn_ fn () !) {
	old := os.getenv('KIMI_CONFIG_DIR')
	tmp := os.join_path(os.temp_dir(), 'kimi_sub_test_${time.now().unix_milli()}_${short_rand()}')
	os.setenv('KIMI_CONFIG_DIR', tmp, true)
	defer {
		os.setenv('KIMI_CONFIG_DIR', old, true)
		os.rmdir_all(tmp) or {}
	}
	fn_() or { panic(err) }
}

// with_ctx runs fn_ with a live non-interactive Agent (fake provider) and a
// ToolContext pointing at it — enough context for the validation and format
// paths of the subagent tools.
fn with_ctx(fn_ fn (mut a Agent, ctx ToolContext) !) {
	mut a := new_agent(SubFake{ deltas: ['handoff text'] }, '')
	a.non_interactive = true
	ctx := ToolContext{ agent: &a }
	fn_(mut a, ctx) or { panic(err) }
}

// ---------- Ids / description ---------------------------------------------

fn test_new_subagent_id_unique() {
	id1 := new_subagent_id()
	id2 := new_subagent_id()
	assert id1 != id2
	assert id1.starts_with('sub-')
	assert id2.starts_with('sub-')
}

fn test_build_subagent_type_lines_lists_all_types() {
	lines := build_subagent_type_lines()
	assert lines.contains('- coder:')
	assert lines.contains('- explore:')
	assert lines.contains('- plan:')
}

// ---------- Agent tool: validation ----------------------------------------

fn test_agent_tool_rejects_invalid_json() {
	with_ctx(fn (mut a Agent, ctx ToolContext) ! {
		res := AgentTool{ agent: &a }.execute(ToolArgs{ raw: 'not json' }, ctx)!
		assert res.is_error
		assert res.content.contains('invalid arguments')
	})
}

fn test_agent_tool_requires_prompt_and_description() {
	with_ctx(fn (mut a Agent, ctx ToolContext) ! {
		// Missing both.
		r1 := AgentTool{ agent: &a }.execute(ToolArgs{ raw: '{}' }, ctx)!
		assert r1.is_error
		assert r1.content.contains('missing required argument')
		// Missing description only.
		r2 := AgentTool{ agent: &a }.execute(ToolArgs{ raw: '{"prompt":"hi"}' }, ctx)!
		assert r2.is_error
		assert r2.content.contains('missing required argument')
	})
}

fn test_agent_tool_rejects_unknown_subagent_type() {
	with_ctx(fn (mut a Agent, ctx ToolContext) ! {
		raw := '{"prompt":"do it","description":"task","subagent_type":"hacker"}'
		res := AgentTool{ agent: &a }.execute(ToolArgs{ raw: raw }, ctx)!
		assert res.is_error
		assert res.content.contains('Unknown subagent_type "hacker"')
	})
}

fn test_agent_tool_rejects_resume_with_subagent_type() {
	with_ctx(fn (mut a Agent, ctx ToolContext) ! {
		raw := '{"prompt":"continue","description":"resume","resume":"sub-123","subagent_type":"explore"}'
		res := AgentTool{ agent: &a }.execute(ToolArgs{ raw: raw }, ctx)!
		assert res.is_error
		assert res.content.contains('do not pass subagent_type when resuming')
	})
}

fn test_agent_tool_resume_missing_session() {
	with_ctx(fn (mut a Agent, ctx ToolContext) ! {
		raw := '{"prompt":"continue","description":"resume","resume":"sub-does-not-exist"}'
		res := AgentTool{ agent: &a }.execute(ToolArgs{ raw: raw }, ctx)!
		assert res.is_error
		assert res.content.contains('subagent not found')
	})
}

// ---------- Agent tool: format helpers ------------------------------------

fn test_format_subagent_result_completed() {
	tr := format_subagent_result(SubagentResult{
		agent_id:     'sub-1'
		profile_name: 'coder'
		result:       'fixed the bug in src/a.v'
		ok:           true
	})
	assert !tr.is_error
	assert tr.content.contains('agent_id: sub-1')
	assert tr.content.contains('actual_subagent_type: coder')
	assert tr.content.contains('status: completed')
	assert tr.content.contains('fixed the bug in src/a.v')
}

fn test_format_subagent_result_timeout() {
	tr := format_subagent_result(SubagentResult{
		agent_id:     'sub-2'
		profile_name: 'coder'
		result:       'partial work'
		ok:           false
		timed_out:    true
		err:          'timed out'
	})
	assert tr.is_error
	assert tr.content.contains('status: timed_out')
	assert tr.content.contains('resume="sub-2"')
	assert tr.content.contains('partial work')
}

fn test_format_subagent_result_error() {
	tr := format_subagent_result(SubagentResult{
		agent_id:     'sub-3'
		profile_name: 'coder'
		ok:           false
		err:          'provider exploded'
	})
	assert tr.is_error
	assert tr.content.contains('provider exploded')
}

fn test_format_background_launch() {
	tr := format_background_launch(SubagentResult{
		agent_id:     'sub-4'
		profile_name: 'coder'
		ok:           true
		result:       'running'
	})
	assert !tr.is_error
	assert tr.content.contains('agent_id: sub-4')
	assert tr.content.contains('status: running')
	assert tr.content.contains('background-agent-result')
}

// ---------- Agent tool: resume integration --------------------------------

fn test_agent_tool_resume_persisted_session() {
	with_tmp_config(fn () ! {
		with_ctx(fn (mut a Agent, ctx ToolContext) ! {
			// Persist a first subagent session, as run_subagent would.
			mut sess := new_session(os.getwd())
			sess.id = 'sub-resume-1'
			sess.append_user('first task')
			save_to(subagent_sessions_dir(), sess)!

			// Resuming it runs the appended prompt to completion.
			raw := '{"prompt":"continue the work","description":"resume","resume":"sub-resume-1"}'
			res := AgentTool{ agent: &a }.execute(ToolArgs{ raw: raw }, ctx)!
			assert !res.is_error
			assert res.content.contains('agent_id: sub-resume-1')
			assert res.content.contains('status: completed')
		})
	})
}

// ---------- TaskList tool -------------------------------------------------

fn test_tasklist_empty() {
	mut a := new_agent(SubFake{ deltas: []string{} }, '')
	ctx := ToolContext{ agent: &a }
	res := TaskListTool{ agent: &a }.execute(ToolArgs{ raw: '{}' }, ctx) or { panic(err) }
	assert !res.is_error
	assert res.content.contains('(no background subagent tasks)')
}

fn test_tasklist_lists_tasks() {
	mut a := new_agent(SubFake{ deltas: []string{} }, '')
	a.register_background_task(BackgroundTask{
		agent_id:     'sub-7'
		profile_name: 'explore'
		status:       'completed'
		started_ms:   time.now().unix_milli() - 1000
		finished_ms:  time.now().unix_milli()
		elapsed_ms:   1000
		result:       'found the widget'
	})
	a.register_background_task(BackgroundTask{
		agent_id:     'sub-8'
		profile_name: 'coder'
		status:       'running'
		started_ms:   time.now().unix_milli()
	})
	ctx := ToolContext{ agent: &a }
	res := TaskListTool{ agent: &a }.execute(ToolArgs{ raw: '{}' }, ctx) or { panic(err) }
	assert !res.is_error
	assert res.content.contains('sub-7')
	assert res.content.contains('explore')
	assert res.content.contains('completed')
	assert res.content.contains('found the widget')
	assert res.content.contains('sub-8')
	assert res.content.contains('running')
}

// ---------- AgentSwarm tool: validation -----------------------------------

fn test_swarm_rejects_bad_json() {
	with_ctx(fn (mut a Agent, ctx ToolContext) ! {
		res := AgentSwarmTool{ agent: &a }.execute(ToolArgs{ raw: 'garbage' }, ctx)!
		assert res.is_error
		assert res.content.contains('invalid arguments')
	})
}

fn test_swarm_requires_items_or_resumes() {
	with_ctx(fn (mut a Agent, ctx ToolContext) ! {
		res := AgentSwarmTool{ agent: &a }.execute(ToolArgs{ raw: '{}' }, ctx)!
		assert res.is_error
		assert res.content.contains('provide at least 2 items unless you pass resume_agent_ids')
	})
}

fn test_swarm_requires_two_items() {
	with_ctx(fn (mut a Agent, ctx ToolContext) ! {
		raw := '{"prompt_template":"T {{item}}","items":["only-one"]}'
		res := AgentSwarmTool{ agent: &a }.execute(ToolArgs{ raw: raw }, ctx)!
		assert res.is_error
		assert res.content.contains('provide at least 2 items')
	})
}

fn test_swarm_requires_item_placeholder() {
	with_ctx(fn (mut a Agent, ctx ToolContext) ! {
		raw := '{"prompt_template":"No placeholder here","items":["a","b"]}'
		res := AgentSwarmTool{ agent: &a }.execute(ToolArgs{ raw: raw }, ctx)!
		assert res.is_error
		assert res.content.contains('must contain {{item}}')
	})
}

fn test_swarm_rejects_duplicate_expansions() {
	with_ctx(fn (mut a Agent, ctx ToolContext) ! {
		raw := '{"prompt_template":"T {{item}}","items":["a","a"]}'
		res := AgentSwarmTool{ agent: &a }.execute(ToolArgs{ raw: raw }, ctx)!
		assert res.is_error
		assert res.content.contains('duplicate prompts')
	})
}

fn test_swarm_rejects_unknown_subagent_type() {
	with_ctx(fn (mut a Agent, ctx ToolContext) ! {
		raw := '{"prompt_template":"T {{item}}","items":["a","b"],"subagent_type":"hacker"}'
		res := AgentSwarmTool{ agent: &a }.execute(ToolArgs{ raw: raw }, ctx)!
		assert res.is_error
		assert res.content.contains('Unknown subagent_type "hacker"')
	})
}

// ---------- AgentSwarm tool: foreground integration -----------------------

fn test_swarm_foreground_runs_all_items() {
	with_tmp_config(fn () ! {
		with_ctx(fn (mut a Agent, ctx ToolContext) ! {
			raw := '{"prompt_template":"Review {{item}} for regressions.","items":["src/a.ts","src/b.ts"]}'
			res := AgentSwarmTool{ agent: &a }.execute(ToolArgs{ raw: raw }, ctx)!
			assert !res.is_error
			assert res.content.contains('AgentSwarm completed: 2 subagents (2 succeeded, 0 failed)')
			assert res.content.contains('(coder): completed')
			assert res.content.contains('handoff text')
		})
	})
}

// ---------- Background launch: delivery + TaskList ------------------------

fn test_background_launch_delivers_result() {
	with_tmp_config(fn () ! {
		mut a := new_agent(SubFake{ deltas: ['background handoff text'] }, '')
		a.non_interactive = true

		mut sess := new_session(os.getwd())
		sess.id = new_subagent_id()
		sess.append_user('do the thing in the background')
		launch := launch_background(mut a, 'coder', mut sess, true)
		assert launch.ok
		id := launch.agent_id

		// Wait (bounded) for the background goroutine to finish.
		mut done := false
		mut deadline := time.now().add(15 * time.second)
		for !done && time.now() < deadline {
			a.bg_mutex.lock()
			t := a.bg_tasks[id] or { BackgroundTask{ status: 'running' } }
			done = t.status == 'completed' || t.status == 'failed'
			a.bg_mutex.unlock()
			if !done {
				time.sleep(50 * time.millisecond)
			}
		}
		assert done

		// The finished result lands in the session on the next drain. The
		// status flag and the channel push happen in the same goroutine, so
		// poll a few times in case the drain races the send.
		mut delivered := false
		for attempt in 0 .. 20 {
			mut s2 := new_session(os.getwd())
			a.drain_background_results(mut s2)
			if s2.messages.len > 0 {
				assert s2.messages[0].content.contains('<background-agent-result')
				assert s2.messages[0].content.contains('status="completed"')
				assert s2.messages[0].content.contains('background handoff text')
				delivered = true
				break
			}
			time.sleep(50 * time.millisecond)
		}
		assert delivered

		// TaskList reflects the finished task.
		ctx := ToolContext{ agent: &a }
		res := TaskListTool{ agent: &a }.execute(ToolArgs{ raw: '{}' }, ctx)!
		assert res.content.contains(id)
		assert res.content.contains('completed')
	})
}
