// internal/agent/loop.v
// The think-act-observe loop. This is the single most important piece of
// the agent: it decides when to stop, when to keep going, and how to handle
// errors.
module main

import json

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

	for turn in 0 .. a.max_turns {
		// Compact before each step so we never send an oversized request
		// that the model would reject. Failure is non-fatal (logged inside
		// compact()); we'd rather lose a turn than crash the loop.
		a.compact(mut sess) or {}

		step := a.step(mut sess)!

		// Persist the assistant turn (text + tool calls).
		sess.append_assistant(step.text, step.tool_calls)
		last_text = step.text
		total_in += step.finish.input_tokens
		total_out += step.finish.output_tokens

		// If the model didn't ask for tool calls, we're done.
		if step.tool_calls.len == 0 {
			return LoopResult{
				outcome:    .finished
				final_text: last_text
				turns:      turn + 1
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

			// Risky tools (bash, write_file, edit_file, web_fetch) require
			// user approval before running — UNLESS:
			//   1. yolo mode is on (skip everything; sensitive patterns
			//      still re-prompt as a backstop), OR
			//   2. the user previously chose "always allow" for this tool
			//      in the current session (a / approved_tools), AND the
			//      args don't trip a sensitive pattern (rm -rf, sudo,
			//      /etc/* writes, etc. still re-prompt).
			// Send the request and block until the TUI replies. If the
			// decision channel is closed (e.g. TUI exited mid-turn)
			// treat as denied.
			skip_for_yolo := a.yolo && !is_sensitive(call.name, call.arguments)
			skip_for_session := should_skip_approval(call.name, call.arguments, a.approved_tools)
			if needs_approval(call.name, a.risky_tools) && !skip_for_yolo && !skip_for_session {
				if a.non_interactive {
					// One-shot / non-interactive mode (`-p`) has no UI to
					// pump `approval_ch` / `decision_ch`, so blocking on
					// them would deadlock the whole agent (it just hangs
					// forever waiting for a human who isn't there). Without
					// `--yolo`, refuse risky tools and tell the model it can
					// answer without them; with `--yolo` the branch above
					// already skips approval entirely.
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
			}

			// Plan-mode read-only guard. While plan mode is active,
			// write_file / edit_file may ONLY target the current plan
			// file. Any other write path is denied outright — the model
			// must call ExitPlanMode (which the user approves) before
			// editing code. This mirrors kimi-code's
			// plan-mode-guard-deny permission policy. bash is NOT blocked
			// here (the model may still inspect via Bash), but it follows
			// the normal approval path above.
			if a.plan.is_active && (call.name == 'write_file' || call.name == 'edit_file') {
				target := tool_write_path(call.arguments)
				plan_path := a.plan.plan_file_path
				if plan_path.len == 0 || target != plan_path {
					deny := if plan_path.len > 0 {
						'Plan mode is active. You may only write to the current plan file: ${plan_path}. Call ExitPlanMode to exit plan mode before editing other files.'
					} else {
						'Plan mode is active. No plan file is available in this mode. Call ExitPlanMode to exit plan mode before editing files.'
					}
					sess.append_tool_result(call.id, call.name, deny)
					continue
				}
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

// tool_write_path extracts the `path` argument from a write_file / edit_file
// tool call's raw JSON arguments. Returns '' if not found or the JSON is
// malformed. Used by the plan-mode read-only guard to decide whether a write
// is allowed (only the plan file may be written while plan mode is active).
fn tool_write_path(raw_args string) string {
	args_map := json.decode(map[string]string, raw_args) or {
		return ''
	}
	return args_map['path'] or { '' }
}
