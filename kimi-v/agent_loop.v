// internal/agent/loop.v
// The think-act-observe loop. This is the single most important piece of
// the agent: it decides when to stop, when to keep going, and how to handle
// errors.
module main

pub enum LoopOutcome {
	finished
	max_turns
	errored
}

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

		step := a.step(sess)!

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
