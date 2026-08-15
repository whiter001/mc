// internal/agent/loop.v
// The think-act-observe loop. This is the single most important piece of
// the agent: it decides when to stop, when to keep going, and how to handle
// errors.
module main

import json2
import rand
import time

// LoopOutcome describes why the agent loop stopped.
pub enum LoopOutcome {
	finished
	max_turns
	errored
}

// LoopResult summarizes a completed agent run.
pub struct LoopResult {
pub:
	outcome    LoopOutcome
	final_text string
	turns      int
	usage      Usage
}

// run executes the agent loop on the given session in place. The session
// is mutated as messages are appended.
//
// In P0 this is single-shot (blocking). In P1 the TUI runs `run()` in a
// goroutine and renders deltas via `on_delta`.
pub fn (mut a Agent) run(mut sess Session) !LoopResult {
	mut total_in := 0
	mut total_out := 0
	mut last_text := ''
	// Cumulative turn counter across goal-continuation rounds, so max_turns
	// still bounds the whole run (not just one round).
	mut turns := 0

	// Outer structure: a single loop whose "normal end" (a step with no
	// tool calls) is intercepted by the goal driver — while a goal is
	// active, we append a continuation prompt and keep going instead of
	// returning, until the model adjudicates the goal (UpdateGoal) or a
	// configured budget is reached.
	for turns < a.max_turns {
		// Wall-clock deadline (set by the subagent runner to enforce the
		// subagent timeout). Once it passes we stop making new turns and
		// return whatever we've accumulated — this bounds a runaway loop
		// even when max_turns is generous.
		if a.deadline_ms > 0 && time.now().unix_milli() >= a.deadline_ms {
			break
		}
		// Deliver finished background subagent results to the model before
		// the next step so it can react to them on this turn.
		a.drain_background_results(mut sess)
		// Compact before each step so we never send an oversized request
		// that the model would reject. Failure is non-fatal (logged inside
		// compact()); we'd rather lose a turn than crash the loop.
		//
		// Cheap local pass first: clear the content of old, long tool
		// results (no LLM, no hooks). Only if we're still over the
		// threshold after that do we pay for a full LLM summary.
		estimated := estimate_tokens(sess.messages)
		if should_compact(estimated, a.context_window, a.compact_threshold) {
			mut truncated := 0
			sess.messages, truncated = micro_compact(sess.messages)
			after := estimate_tokens(sess.messages)
			if truncated > 0 {
				eprintln('micro-compact: cleared ${truncated} old tool result(s), ${estimated} → ${after} est tokens')
			}
			if should_compact(after, a.context_window, a.compact_threshold) {
				a.compact(mut sess, false, '') or {}
			}
		}

		step := a.step_with_retry(mut sess) or {
			// User cancellation: pause an active goal (so idle time isn't
			// counted against a wall-clock budget), then propagate.
			if err.msg() == 'cancelled' {
				a.pause_goal_after_interrupt()
				a.emit_goal_status()
			}
			return err
		}

		// Persist the assistant turn (text + tool calls).
		sess.append_assistant(step.text, step.tool_calls)
		last_text = step.text
		total_in += step.finish.input_tokens
		total_out += step.finish.output_tokens
		turns++

		// Goal token accounting: book this step's output tokens against the
		// active goal. If that crosses the token budget, mark the goal
		// blocked and stop the run before executing any tool calls.
		if a.goal_is_active() {
			a.add_goal_tokens(step.finish.output_tokens)
			if a.goal_over_budget() {
				a.block_goal_over_budget()
				a.emit_goal_status()
				a.drain_background_results(mut sess)
				return LoopResult{
					outcome:    .finished
					final_text: last_text
					turns:      turns
					usage:      new_usage(total_in, total_out)
				}
			}
		}

		// If the model didn't ask for tool calls, the turn is over. Drain
		// any background results that landed during the turn first so
		// they're not lost.
		if step.tool_calls.len == 0 {
			a.drain_background_results(mut sess)
			// Goal driver: while a goal is active the run doesn't stop
			// here. Over budget → mark blocked and exit; otherwise count
			// the goal turn, append the continuation prompt, and loop.
			if a.goal_is_active() {
				if a.goal_over_budget() {
					a.block_goal_over_budget()
					a.emit_goal_status()
					return LoopResult{
						outcome:    .finished
						final_text: last_text
						turns:      turns
						usage:      new_usage(total_in, total_out)
					}
				}
				a.bump_goal_turn()
				// Refresh the goal badge (turn count / elapsed) each goal turn.
				a.emit_goal_status()
				sess.append_user(a.current_goal_continuation_prompt())
				continue
			}
			// No goal, or the model already adjudicated it (complete /
			// blocked) — the run ends normally.
			return LoopResult{
				outcome:    .finished
				final_text: last_text
				turns:      turns
				usage:      new_usage(total_in, total_out)
			}
		}

		// Otherwise execute each tool call (in parallel via goroutines).
		ctx := ToolContext{
			cwd:        sess.cwd
			permission: 'default'
			dry_run:    false
			agent:      &a
		}

		results_ch := chan ToolExecResult{}
		mut spawned := 0
		for call in step.tool_calls {
			t := a.registry.get(call.name) or {
				// Unknown tool → emit a synthetic error result so the model
				// sees the failure and can recover.
				sess.append_tool_result(call.id, call.name, 'unknown tool: ${call.name}')
				continue
			}

			// ── PreToolUse hook (lifecycle) ───────────────────────────────
			// Fires before permission checks. A blockable event whose hook
			// returns 'block' aborts the tool call (the reason is fed back
			// to the model). Observation-only events never block. Fail-open
			// on hook errors/timeouts (a bad hook must never stall the loop).
			mut pre_input := map[string]string{}
			pre_input['tool_name'] = call.name
			pre_input['tool_input'] = call.arguments
			pre_block := a.hooks_engine().run_hook_for_event(.pre_tool_use, call.name, pre_input)
			if pre_block != none {
				sess.append_tool_result(call.id, call.name,
					'[blocked by PreToolUse hook] ${pre_block}')
				continue
			}

			// Tool approval gate. evaluate_approval runs the full ordered
			// policy chain (see approval.v): deny rules → plan-mode guard
			// → sensitive patterns → ask rules → plan-mode risky re-ask →
			// allow rules → yolo → session always-allow → built-in risky
			// list. A .deny verdict feeds the reason back to the model; an
			// .ask verdict blocks on the TUI approval modal; .run executes.
			appr_ctx := ApprovalContext{
				risky_tools:      a.risky_tools
				approved_tools:   a.approved_tools
				permission_rules: a.permission_rules
				yolo:             a.yolo
				plan_active:      a.plan.is_active
				plan_file_path:   a.plan.plan_file_path
			}
			appr := evaluate_approval(call.name, call.arguments, appr_ctx)
			match appr.action {
				.deny {
					sess.append_tool_result(call.id, call.name, appr.reason)
					continue
				}
				.ask {
					// Send the request and block until the TUI replies. If
					// the decision channel is closed (e.g. TUI exited
					// mid-turn) treat as denied.
					if a.non_interactive {
						// One-shot / non-interactive mode (`-p`) has no UI to
						// pump `approval_ch` / `decision_ch`, so blocking on
						// them would deadlock the whole agent (it just hangs
						// forever waiting for a human who isn't there). Without
						// `--yolo`, refuse risky tools and tell the model it can
						// answer without them; with `--yolo` the policy chain
						// already returns .run.
						sess.append_tool_result(call.id, call.name,
							'[tool "${call.name}" requires approval but this is a non-interactive session; re-run with -y/--yolo to allow it, or ask without shell tools]')
						continue
					}
					a.next_approval_id++
					a.approval_ch <- ApprovalRequest{
						id:        a.next_approval_id
						tool_name: call.name
						args:      call.arguments
					}
					decision := <-a.decision_ch or {
						ApprovalDecision{
							id:       a.next_approval_id
							approved: false
						}
					}
					if !decision.approved {
						sess.append_tool_result(call.id, call.name, '[user denied this action]')
						continue
					}
					// "always allow for the rest of the session" (TUI 'a'
					// key): remember the tool in our own list so the change
					// takes effect within the same turn. The TUI also persists
					// it to disk, so future sessions load it at startup.
					if decision.remember {
						if call.name !in a.approved_tools {
							a.approved_tools << call.name
						}
					}
				}
				.run {}
			}

			spawned++
			go fn (call ToolCall, t Tool, ctx ToolContext, ch chan ToolExecResult) {
				r := execute_tool(t, call.arguments, ctx)
				ch <- ToolExecResult{
					call_id: call.id
					name:    call.name
					result:  r
				}
			}(call, t, ctx, results_ch)
		}

		// Wait for whichever executions actually ran.
		for _ in 0 .. spawned {
			r := <-results_ch
			sess.append_tool_result(r.call_id, r.name, r.result.content)
			// Tool-result callback (ACP streams tool_call_update from it).
			if cb := a.on_tool_done {
				cb(r.call_id, r.name, r.result.is_error)
			}
			// ── PostToolUse / PostToolUseFailure hooks (observation-only)
			if r.result.is_error {
				mut fail_input := map[string]string{}
				fail_input['tool_name'] = r.name
				fail_input['tool_response'] = r.result.content
				a.hooks_engine().run_hook_for_event(.post_tool_use_failure, r.name, fail_input)
			} else {
				mut post_input := map[string]string{}
				post_input['tool_name'] = r.name
				post_input['tool_response'] = r.result.content
				a.hooks_engine().run_hook_for_event(.post_tool_use, r.name, post_input)
			}
		}
		results_ch.close()
	}

	// Drain background results before the final return so nothing queued
	// during the last turn is left undelivered.
	a.drain_background_results(mut sess)
	return LoopResult{
		outcome:    .max_turns
		final_text: last_text
		turns:      a.max_turns
		usage:      new_usage(total_in, total_out)
	}
}

struct ToolExecResult {
	call_id string
	name    string
	result  ToolResult
}

// step_with_retry wraps Agent.step with bounded retries for transient
// provider errors — parity with kimi-code's `[loop_control]
// max_retries_per_step` (default 10 retries). Only ProviderError values
// flagged `retryable` (HTTP 429 / 5xx / connection failures) are retried;
// cancellations and client errors return immediately. The backoff between
// attempts is exponential (500ms base, factor 2, capped at 32s) with up to
// +25% random jitter, and interruptible via the agent's cancel channel
// (Ctrl-C aborts the wait, not just the request).
fn (mut a Agent) step_with_retry(mut sess Session) !StepResult {
	mut log := new_logger(.info)
	for attempt := 0; ; attempt++ {
		res := a.step(mut sess) or {
			if err is ProviderError && err.retryable && attempt < a.max_retries_per_step {
				backoff := retry_backoff_ms(attempt + 1)
				log.warn('step failed (${err.msg()}); retrying in ${backoff}ms (attempt ${attempt + 1}/${a.max_retries_per_step})')
				if a.sleep_or_cancel(backoff) {
					return error('cancelled')
				}
				continue
			}
			return err
		}
		return res
	}
	return error('unreachable')
}

// retry_backoff_ms returns the sleep (in ms) before the given 1-based
// retry attempt. Exponential with a 500ms base, factor 2, capped at 32s,
// plus up to +25% random jitter added on top of the capped base to avoid
// herd retries. The jitter makes the return value non-deterministic; use
// retry_backoff_base_ms for the deterministic base sequence.
fn retry_backoff_ms(attempt int) int {
	base := retry_backoff_base_ms(attempt)
	// +0..25% of the base, upper bound inclusive (base / 4 is exact since
	// every base is a multiple of 500).
	jitter := rand.int_in_range(0, base / 4 + 1) or { 0 }
	return base + jitter
}

// retry_backoff_base_ms returns the deterministic exponential backoff base
// for the given 1-based attempt: 500ms, 1s, 2s, 4s … capped at 32s.
fn retry_backoff_base_ms(attempt int) int {
	mut ms := 500
	for _ in 1 .. attempt {
		ms *= 2
		if ms >= 32000 {
			return 32000
		}
	}
	return ms
}

// sleep_or_cancel sleeps for `ms` but returns early (true) when a cancel
// arrives on the agent's cancel channel. Polls every 50ms — same
// select-with-timeout workaround as step(), since a bare receive branch
// on an often-idle channel hangs V 0.5.x's select.
fn (a Agent) sleep_or_cancel(ms int) bool {
	start := time.now()
	for time.since(start).milliseconds() < ms {
		select {
			_ := <-a.cancel_ch {
				return true
			}
			50 * time.millisecond {
			}
		}
	}
	return false
}

// tool_write_path extracts the `path` argument from a write_file / edit_file
// tool call's raw JSON arguments. Returns '' if not found or the JSON is
// malformed. Used by the plan-mode guard in evaluate_approval (approval.v)
// and by permission glob matching (permissions.v).
fn tool_write_path(raw_args string) string {
	args_map := json2.decode[map[string]string](raw_args) or {
		return ''
	}
	return args_map['path'] or { '' }
}
