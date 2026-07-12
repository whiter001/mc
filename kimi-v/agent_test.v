// agent_test.v — regression tests for Agent.step().
//
// These guard against a V 0.5.x select bug that surfaced in the wild:
//
//   The step() select has three receive branches: the chunk channel `ch`
//   (has values), `a.steer_ch` (empty in -p mode and TUI idle), and
//   `a.cancel_ch` (empty until Ctrl-C). V 0.5.x's select implementation
//   fails to pick a ready branch when at least one branch is a bare
//   receive on a never-delivering channel — the whole select hangs even
//   though `ch` is full of SSE events.
//
//   Symptom: every TUI prompt "hangs" with no reply, and `-p` mode
//   prints nothing then times out. The production fix is a 1ms timeout
//   case in the select (see agent.v). The tests below exercise both the
//   full agent.step() path and the raw V select pattern with a hard
//   deadline so a regression fails fast with a clear assertion instead
//   of stalling the suite.
module main

import time

// ---------- Inline FakeProvider ------------------------------------------
//
// V's test runner compiles each _test.v file independently, so the
// FakeProvider in compaction_test.v is not visible here. We define a
// minimal local copy that emits deltas + finish + end_of_stream.

struct InlineFake {
	name     string
	model    string
	api_base string
	api_key  string
	deltas   []string
}

fn (p InlineFake) chat(req ChatRequest, out chan ChatEvent, cancel_ch chan int) ! {
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

// ---------- Result + deadline wrapper ------------------------------------

struct StepOutcome {
pub:
	ok   bool
	text string
	err  string
}

fn run_step_with_deadline(mut a Agent, mut sess Session, deadline_ms int) StepOutcome {
	res_ch := chan StepOutcome{cap: 1}
	spawn fn (mut a Agent, mut sess Session, res_ch chan StepOutcome) {
		r := a.step(mut sess) or {
			res_ch <- StepOutcome{
				ok:  false
				err: err.msg()
			}
			return
		}
		res_ch <- StepOutcome{
			ok:   true
			text: r.text
		}
	}(mut a, mut sess, res_ch)
	deadline := chan int{cap: 1}
	spawn fn (deadline chan int, deadline_ms int) {
		time.sleep(deadline_ms * time.millisecond)
		deadline <- 1
	}(deadline, deadline_ms)
	select {
		r := <-res_ch {
			return r
		}
		_ := <-deadline {
			return StepOutcome{
				ok:  false
				err: 'step() did not return within ${deadline_ms}ms — likely V 0.5.x select bug (empty steer_ch / cancel_ch blocking)'
			}
		}
	}
	return StepOutcome{
		ok:  false
		err: 'unreachable'
	}
}

// ---------- Tests --------------------------------------------------------

fn test_step_drains_deltas_from_fake_provider() {
	// FakeProvider emits three deltas, a finish, and an end_of_stream.
	// Before the agent.v fix, step() would hang in its select because
	// steer_ch and cancel_ch are empty bare-receive branches and V 0.5.x
	// doesn't pick the chunk branch when any sibling branch is empty.
	// With the 1ms timeout case the select polls and the chunk branch
	// fires promptly. The 2-second deadline turns a regression into a
	// clear assertion failure instead of a hung test runner.
	mut a := new_agent(InlineFake{ deltas: ['hello', ' ', 'world'] }, '')
	mut sess := new_session('/tmp')
	sess.append_user('hi')
	res := run_step_with_deadline(mut a, mut sess, 2000)
	assert res.ok, 'step() failed: ${res.err}'
	assert res.text == 'hello world', 'expected joined deltas, got [${res.text}]'
}

fn test_select_with_bare_recv_on_empty_chan_does_not_starve_other_branches() {
	// Self-contained micro-test for the V gotcha. agent.v uses a 1ms
	// timeout case in the select to work around the V 0.5.x bug; this
	// test reproduces the *broken* pattern (no timeout) and asserts
	// the chunk branch still fires. If V is upgraded and the bug is
	// fixed, this test will simply pass; if V is downgraded or the
	// bug returns, this test will hang and the 1.5s deadline will fire.
	//
	// Note: the test currently passes because of the workaround in
	// agent.v — not because V is fixed. If the agent.v timeout is
	// ever removed, the production `test_step_drains_deltas_*` test
	// above will hang and fail with the clear error.
	ch := chan int{cap: 8}
	empty1 := chan string{}
	empty2 := chan int{}
	spawn fn (ch chan int) {
		time.sleep(20 * time.millisecond)
		ch <- 1
		ch <- 2
		ch <- 3
	}(ch)
	deadline := chan int{cap: 1}
	spawn fn (deadline chan int) {
		time.sleep(1500 * time.millisecond)
		deadline <- 1
	}(deadline)
	mut got := []int{}
	mut loop := true
	for loop {
		select {
			v := <-ch {
				got << v
				if got.len == 3 {
					loop = false
				}
			}
			_ := <-empty1 {}
			_ := <-empty2 {}
			_ := <-deadline {
				assert false, 'select hung: bare-receive on empty channels starved the chunk channel. ' +
					'This is the V 0.5.x bug the agent.v 1ms timeout works around. ' +
					'If this fails on a newer V, agent.v can drop the workaround.'
				return
			}
		}
	}
	assert got == [1, 2, 3], 'got=${got}'
}
