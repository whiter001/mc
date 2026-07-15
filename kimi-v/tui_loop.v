// tui_loop.v — the main TUI event loop.
//
// Architecture:
//   - One goroutine reads keys from stdin (via StdinReader), pushes
//     KeyEvents to `key_ch`.
//   - When the user submits, we spawn the agent goroutine which reads
//     from `submit_ch`, runs the agent, and emits status updates via
//     `status_ch`.
//   - Main loop: drain key_ch + status_ch, update TuiState, re-render.

module main

import os
import time

// TuiLoopResult tells main() how to proceed after the loop exits.
pub enum TuiLoopResult {
	clean_exit
	fallback_to_stdout
}

// SubmitMsg is sent from the input loop to the agent runner.
// `attachments` carries any pending image attachments (P0.7). The
// agent_runner_loop pushes them into the session as part of the
// user message; the wire form encodes them as image_url content
// parts in llm_openai_compat.v.
pub struct SubmitMsg {
pub:
	prompt      string
	attachments []Attachment
}

// StatusKind + payload pair used for TuiStatus. We use one struct rather
// than enum-with-payload (V's enum variants can't have PascalCase field
// names, which makes payload access painful).
pub enum StatusKind {
	started
	delta            // regular content chunk (assistant text)
	thinking_delta   // reasoning/thinking chunk (k1.5 / R1 style)
	tool_call
	tool_result
	finished
	cancelled        // user interrupted the current turn
	errored
	plan_mode        // plan-mode state change (enter/exit) — carries text
}

// PlanControl is a control message from the TUI (e.g. the `/plan` slash
// command) to the agent runner. The runner applies it to the agent's
// plan-mode state and emits a status so the TUI can render the banner.
pub struct PlanControl {
pub:
	kind string // 'enter' (enter plan mode) | 'exit' (exit plan mode)
}

pub struct TuiStatus {
pub:
	kind         StatusKind
	// Streaming payload: the chunk text for .delta / .thinking_delta.
	// The consumer appends it to the appropriate TuiState streaming field.
	chunk        string
	tool_name    string
	tool_args    string
	tool_result  string
	tool_is_err  bool
	input_tokens int
	output_tokens int
	// When the run ends, the streamed content lives in `state.streaming` /
	// `state.streaming_thinking`; the main loop promotes those to permanent
	// blocks. We no longer carry the full text in the status message.
	err          string
}

// status_started returns a status marking the start of an agent turn.
pub fn status_started() TuiStatus { return TuiStatus{ kind: .started } }

// status_delta returns a status carrying a regular assistant content chunk.
pub fn status_delta(chunk string) TuiStatus {
	return TuiStatus{ kind: .delta, chunk: chunk }
}

// status_thinking_delta returns a status carrying a reasoning/thinking chunk.
pub fn status_thinking_delta(chunk string) TuiStatus {
	return TuiStatus{ kind: .thinking_delta, chunk: chunk }
}

// status_tool_call returns a status announcing a tool call.
pub fn status_tool_call(name string, args string) TuiStatus {
	return TuiStatus{ kind: .tool_call, tool_name: name, tool_args: args }
}

// status_tool_result returns a status carrying a tool result.
pub fn status_tool_result(name string, result string, is_err bool) TuiStatus {
	return TuiStatus{ kind: .tool_result, tool_name: name, tool_result: result, tool_is_err: is_err }
}

// status_finished returns a status marking the end of a turn, carrying token
// usage for the session tally.
pub fn status_finished(input_tokens int, output_tokens int) TuiStatus {
	return TuiStatus{
		kind: .finished
		input_tokens: input_tokens
		output_tokens: output_tokens
	}
}

// status_errored returns a status carrying an error message.
pub fn status_errored(err string) TuiStatus {
	return TuiStatus{ kind: .errored, err: err }
}

// status_cancelled returns a status marking a user-interrupted turn.
pub fn status_cancelled() TuiStatus {
	return TuiStatus{ kind: .cancelled }
}

// status_plan_mode returns a status announcing a plan-mode state change.
pub fn status_plan_mode(text string) TuiStatus {
	return TuiStatus{ kind: .plan_mode, err: text }
}

// run_tui is the main interactive loop. Returns:
//   - .clean_exit on user request (Esc Esc or /exit)
//   - .fallback_to_stdout if TUI can't initialize (non-TTY)
pub fn run_tui(mut cfg Config, provider OpenAICompatProvider) TuiLoopResult {
	mut state := new_tui_state()
	mut ib := new_input_buf()
	// Load persisted history before entering raw mode so any I/O error
	// (e.g. missing file) is handled cleanly without flashing the TUI.
	ib.history = load_history()

	if !enter_tui() {
		return .fallback_to_stdout
	}

	key_ch := chan KeyEvent{cap: 16}
	submit_ch := chan SubmitMsg{cap: 4}
	status_ch := chan TuiStatus{cap: 32}
	// Buffered cap 1 so the main loop can drop a signal non-blockingly;
	// one in-flight cancel at a time is enough.
	cancel_request_ch := chan int{cap: 1}
	// Approval flow: the agent sends an ApprovalRequest on approval_ch
	// when it hits a risky tool, then blocks waiting for the decision.
	// cap 4 because multiple tool calls in one step can all queue up
	// before the user answers the first one.
	approval_ch := chan ApprovalRequest{cap: 4}
	decision_ch := chan ApprovalDecision{cap: 1}
	// Steer flow: while the agent is streaming, the user can press
	// Ctrl-S to inject the current input box contents as a new user
	// message. The agent loop's step() selects on this channel and
	// returns when a steer arrives so the loop can call step() again.
	// cap 4 so multiple typed-and-entered steers can queue.
	steer_ch := chan string{cap: 4}
	// AskUserQuestion flow: the agent forwards a question; the TUI renders
	// a modal and sends the answer back. cap 4 so several can queue.
	ask_ch := chan AskRequest{cap: 4}
	ask_result_ch := chan AskResult{cap: 1}
	// ExitPlanMode flow: the agent forwards the finalised plan; the TUI
	// renders a plan-review modal and sends the decision back. cap 4 so
	// several can queue (in practice one at a time).
	exit_plan_ch := chan ExitPlanRequest{cap: 4}
	exit_plan_result_ch := chan ExitPlanResult{cap: 1}
	// Plan-control channel: the TUI (e.g. `/plan` slash) sends control
	// messages to the agent runner to flip plan-mode state. cap 1.
	plan_control_ch := chan PlanControl{cap: 1}
	// Shutdown channel: signal handlers (SIGHUP / SIGTERM) push 1 here;
	// the main loop picks it up on its next iteration and unwinds.
	shutdown_ch := chan int{cap: 1}
	install_signal_handlers(shutdown_ch)
	// Resize channel: SIGWINCH handler pushes 1 here; the main loop
	// re-queries the terminal size only when it arrives (instead of
	// polling `stty size` every frame, which fork/execs a shell ~30×/s).
	resize_ch := chan int{cap: 1}
	install_winch_handler(resize_ch)

	// Build the agent (and any MCP connections) up-front so /mcp and the
	// deferred teardown in run_tui can reach it.
	mut agent := new_agent(provider, cfg.system_prompt)
	agent.max_turns = cfg.max_turns
	agent.registry = default_registry(mut agent, cfg.cwd, cfg.mcp_servers)
	agent.set_skills(discover_skills(cfg.cwd))
	state.mcp_connected = agent.mcp_clients.keys()
	// Tear down MCP connections on any exit path (best-effort).
	defer {
		close_all_mcp_servers(mut agent.mcp_clients)
	}

	spawn key_reader_loop(key_ch)
	spawn agent_runner_loop(mut &agent, cfg, submit_ch, status_ch, cancel_request_ch,
		approval_ch, decision_ch, steer_ch, ask_ch, ask_result_ch, exit_plan_ch,
		exit_plan_result_ch, plan_control_ch)

	state.should_exit = false
	state.should_interrupt = false
	mut last_render_ms := i64(0)
	mut last_size_ms := i64(0)
	render_interval_ms := i64(33)
	// Fallback size-refresh cadence. SIGWINCH refreshes immediately on a
	// real resize; this 2s throttle covers environments that don't emit
	// SIGWINCH (so a stale width never lingers for long). Far cheaper than
	// the old per-frame `stty size` poll.
	size_refresh_ms := i64(2000)

	for {
		// Non-blocking drain of all available events. V's select takes
		// integer nanosecond durations, so 1ms = 1_000_000.
		mut drain_status := true
		for drain_status {
			select {
				s := <-status_ch {
					handle_status(s, mut state)
				}
				req := <-approval_ch {
					// Risky tool call pending — render the modal and wait
					// for the user's y/n.
					state.pending_approval = req
					state.status = 'awaiting approval: ${req.tool_name}'
					state.dirty = true
				}
				areq := <-ask_ch {
					// The model asked the user a question — render the
					// question modal and wait for a choice.
					state.pending_ask = areq
					state.status = 'awaiting answer'
					state.dirty = true
				}
				preq := <-exit_plan_ch {
					// The model finished planning — render the plan
					// review modal and wait for Approve / Reject / etc.
					state.pending_exit_plan = preq
					state.status = 'plan awaiting approval'
					state.dirty = true
				}
				1 * time.millisecond {
					drain_status = false
				}
			}
		}

		mut drain_keys := true
		for drain_keys {
			select {
				ev := <-key_ch {
			handle_key(ev, mut state, mut ib, submit_ch, mut cfg, decision_ch,
				steer_ch, ask_result_ch, exit_plan_result_ch, plan_control_ch)
				}
				1 * time.millisecond {
					drain_keys = false
				}
			}
		}

		// Forward pending interrupt request to the agent runner. We
		// use a non-blocking send so a duplicate Ctrl-C while we're
		// already cancelling doesn't pile up. Only forward if a turn
		// is actually in progress; an idle-time Ctrl-C would otherwise
		// consume the next turn's signal.
		if state.should_interrupt && state.status != 'idle' {
			select {
				cancel_request_ch <- 1 {}
				else {}
			}
			state.should_interrupt = false
			state.status = 'cancelling...'
		}

		now_ms := time.now().unix_milli()
		if now_ms - last_render_ms >= render_interval_ms {
			// Only repaint when something actually changed. This keeps a
			// static screen from being cleared + redrawn ~30×/s (which
			// causes flicker and wasted CPU). Streaming counts as
			// "changed" so live tokens still paint every frame.
			streaming := state.streaming.len > 0 || state.streaming_thinking.len > 0
			if state.dirty || streaming {
				// Re-query terminal size on a throttled cadence so the
				// layout adapts even without a SIGWINCH (see size_refresh_ms).
				if now_ms - last_size_ms > size_refresh_ms {
					state.refresh_size()
					last_size_ms = now_ms
				}
				frame := render(state, ib)
				write_stdout(frame)
				state.dirty = false
				last_render_ms = now_ms
			}
		}

		if state.should_exit {
			break
		}

		// Check for shutdown signal (SIGHUP / SIGTERM). Non-blocking
		// drain so we don't pile up signals.
		select {
			_ := <-shutdown_ch {
				state.should_exit = true
			}
			1 * time.millisecond {}
		}

		// Check for a terminal-resize signal (SIGWINCH). Re-query the
		// size immediately and mark the frame dirty so the very next
		// paint uses the new dimensions.
		select {
			_ := <-resize_ch {
				state.refresh_size()
				state.dirty = true
			}
			1 * time.millisecond {}
		}

		if state.status == 'idle' && state.streaming.len == 0 {
			time.sleep(10 * time.millisecond)
		}
	}

	leave_tui()
	// Persist history after leaving raw mode — write failures here
	// shouldn't crash the TUI; we just log and move on. The user can
	// still quit; they'll lose history but the session itself is fine.
	save_history(ib.history) or {
		eprintln('[warn] failed to save history: ${err.msg()}')
	}
	return .clean_exit
}

// key_reader_loop pulls keys from stdin and pushes them onto key_ch.
// On EOF (pipe broken, TTY disconnected) it pushes a `.stdin_eof`
// sentinel so the main loop can exit cleanly. The channel is NOT closed
// — closing it would let `<-key_ch` return zero values forever, and
// KeyEvent's zero value (.none) is indistinguishable from a real
// "unrecognized byte" event.
fn key_reader_loop(key_ch chan KeyEvent) {
	mut reader := new_stdin_reader()
	for {
		ev := reader.read_key()
		key_ch <- ev
		if ev.kind == .stdin_eof {
			break
		}
	}
}

// agent_runner_loop consumes SubmitMsg and runs the agent, pushing status
// updates as it goes.
fn agent_runner_loop(mut agent &Agent, cfg Config, submit_ch chan SubmitMsg, status_ch chan TuiStatus, cancel_request_ch chan int, approval_ch chan ApprovalRequest, decision_ch chan ApprovalDecision, steer_ch chan string, ask_ch chan AskRequest, ask_result_ch chan AskResult, exit_plan_ch chan ExitPlanRequest, exit_plan_result_ch chan ExitPlanResult, plan_control_ch chan PlanControl) {
	// The registry, skills, and MCP connections are already initialised
	// by run_tui (which owns the Agent). Wire up hooks here.
	mut hook_engine := new_hook_engine(cfg.cwd, agent.session_id)
	for h in cfg.hooks {
		hook_engine.add(h)
	}
	agent.set_hooks(hook_engine)
	// Apply user-configured risky-tools list (config.toml /
	// KIMI_RISKY_TOOLS). Empty means "use the built-in default".
	if cfg.risky_tools.len > 0 {
		agent.risky_tools = cfg.risky_tools
	}
	// Share the session-wide approved_tools list (so the TUI can
	// mutate cfg.approved_tools on 'a' and the agent sees it on the
	// next tool call).
	agent.approved_tools = cfg.approved_tools
	// yolo propagates too; toggled at runtime via /yolo slash.
	agent.yolo = cfg.yolo
	// Steer channel: the TUI pushes the user's current input box
	// contents here during a streaming turn. The agent's step() selects
	// on it and returns so the main loop can call step() again with
	// the appended user message.
	agent.steer_ch = steer_ch
	// Wire up the TUI-owned approval channels. The agent blocks on
	// decision_ch when it hits a risky tool; the TUI main loop pumps
	// the request through to a modal and feeds the answer back here.
	agent.approval_ch = approval_ch
	agent.decision_ch = decision_ch
	// AskUserQuestion flow: the runner shares the TUI-owned channels so
	// the AskUserQuestion tool can forward questions and read answers.
	agent.ask_ch = ask_ch
	agent.ask_result_ch = ask_result_ch
	// ExitPlanMode flow: the runner shares the TUI-owned channels so the
	// ExitPlanMode tool can forward the plan and read the user's decision.
	agent.exit_plan_ch = exit_plan_ch
	agent.exit_plan_result_ch = exit_plan_result_ch
	mut sess := new_session(cfg.cwd)
	agent.session_id = sess.id

	// ── SessionStart hook (observation-only) ──
	mut ss_input := map[string]string{}
	ss_input['source'] = 'startup'
	hook_engine.run_hook_for_event(.session_start, 'startup', ss_input)

	for {
		// Drain any pending plan-control messages (e.g. `/plan`) without
		// blocking the submit loop. We peek non-blockingly so a typed
		// `/plan` flips plan mode immediately even when idle.
		// NOTE: `<-plan_control_ch or { break }` BLOCKS on an empty,
		// open channel in this V version (the `or` branch only fires on
		// close), which would deadlock the runner before it ever reaches
		// `<-submit_ch` — so user messages would never be picked up and
		// the assistant would never reply. Use a non-blocking select with
		// a 1ms timeout (the same pattern as the status/key drains) so an
		// idle plan_control_ch is skipped immediately.
		for {
			mut ctrl := PlanControl{}
			select {
				ctrl = <-plan_control_ch {
					match ctrl.kind {
						'enter' {
							if !agent.plan.is_active {
								np := agent.enter_plan_mode()
								status_ch <- status_plan_mode('entered plan mode.\nplan file: ${np}\nwrite your plan, then call ExitPlanMode when ready.')
							} else {
								status_ch <- status_plan_mode('plan mode is already active (plan file: ${agent.plan.plan_file_path})')
							}
						}
						'exit' {
							if agent.plan.is_active {
								prev := agent.exit_plan_mode()
								status_ch <- status_plan_mode('exited plan mode (plan file: ${prev}). All tools are now available.')
							}
						}
						else {}
					}
				}
				1 * time.millisecond {
					break
				}
			}
		}

		msg := <-submit_ch or { break }
		// Per-chunk forward to the TUI: every delta / thinking chunk the
		// agent emits becomes a status, so the render loop paints tokens
		// in real time (back-pressured via the channel's natural blocking).
		agent.on_delta = fn [status_ch] (chunk string) {
			status_ch <- status_delta(chunk)
		}
		agent.on_thinking = fn [status_ch] (chunk string) {
			status_ch <- status_thinking_delta(chunk)
		}

		// Reset cancel channel for this turn (one-shot semantics, cap 1).
		agent.cancel_ch = chan int{cap: 1}

		// Spawn a watcher goroutine that forwards Ctrl-C requests from
		// the main loop to the agent's cancel channel. The watcher exits
		// when the run finishes (we signal via watcher_exit).
		watcher_exit := chan int{cap: 1}
		spawn fn (mut agent &Agent, cancel_request_ch chan int, watcher_exit chan int) {
			for {
				// Drain one of the two channels each iteration. Whichever
				// has a value first wins. We avoid select-with-two-chan-
				// receives because V's parser is unreliable for that shape
				// inside spawn closures.
				select {
					_ := <-cancel_request_ch {
						// Forward: signal the agent to abort. The agent's
						// step() selects on this channel and returns
						// error('cancelled') promptly.
						agent.cancel_ch <- 1 or {}
					}
					1 * time.millisecond {
						// No cancel request this tick; check for exit.
					}
				}
				_ = <-watcher_exit or { continue }
				return
			}
		}(mut &agent, cancel_request_ch, watcher_exit)

		sess.append_user_with_attachments(msg.prompt, msg.attachments)
		// ── UserPromptSubmit hook (blockable): a block decision aborts
		// the turn before the model is called; the reason is surfaced as a
		// system block instead of running. Fail-open on hook errors.
		mut ups_input := map[string]string{}
		ups_input['prompt'] = msg.prompt
		block := hook_engine.run_hook_for_event(.user_prompt_submit, msg.prompt, ups_input)
		if block != none {
			status_ch <- status_started()
			status_ch <- status_errored('blocked by UserPromptSubmit hook: ${block}')
			continue
		}
		status_ch <- status_started()

		res := agent.run(mut sess) or {
			// Tell the watcher to stop, then translate the error into a
			// user-friendly status. Cancel is a user-initiated interrupt,
			// not a real error.
			watcher_exit <- 1
			// ── StopFailure hook (observation-only) ──
			mut sf_input := map[string]string{}
			sf_input['error'] = err.msg()
			hook_engine.run_hook_for_event(.stop_failure, err.msg(), sf_input)
			if err.msg() == 'cancelled' {
				// ── Interrupt hook (observation-only) ──
				mut intr_input := map[string]string{}
				intr_input['reason'] = 'user interrupted'
				hook_engine.run_hook_for_event(.interrupt, '', intr_input)
				status_ch <- status_cancelled()
			} else {
				status_ch <- status_errored(err.msg())
			}
			continue
		}

		watcher_exit <- 1
		// ── Stop hook (blockable): upstream lets a block append a message
		// so the model continues. Our single-run loop can't easily re-loop,
		// so we surface a block reason as a system block (fail-open: an
		// error in the hook never blocks). Observation-only in practice
		// here, but we keep the trigger for parity + logging.
		hook_engine.run_hook_for_event(.stop, '', map[string]string{})
		// Signal "stream done" — the consumer promotes whatever has
		// accumulated in state.streaming / state.streaming_thinking into
		// permanent blocks.
		status_ch <- status_finished(res.usage.input_tokens, res.usage.output_tokens)
	}

	// ── SessionEnd hook (observation-only) ──
	mut se_input := map[string]string{}
	se_input['reason'] = 'exit'
	hook_engine.run_hook_for_event(.session_end, 'exit', se_input)
}

// handle_status updates TuiState based on a TuiStatus message.
fn handle_status(s TuiStatus, mut state TuiState) {
	// Every status change mutates the visible state — mark the frame
	// dirty so the render loop repaints (it otherwise skips idle frames).
	state.dirty = true
	match s.kind {
		.started {
			state.status = 'thinking...'
			state.streaming = ''
			state.streaming_thinking = ''
			state.streaming_done = false
		}
		.delta {
			// Regular assistant text chunk. Append to the in-progress
			// streaming buffer; the render loop will re-paint every frame.
			state.streaming += s.chunk
			// Promote status once we leave the "waiting on first token" state.
			if state.status == 'thinking...' {
				state.status = 'generating...'
			}
		}
		.thinking_delta {
			// Reasoning/thinking chunk (k1.5 / R1 style). Append to its
			// own buffer so the render can show the dim 💭 block above
			// the (yet-to-arrive) answer.
			state.streaming_thinking += s.chunk
			state.status = 'thinking...'
		}
		.tool_call {
			state.blocks << Block{
				kind: .tool_call
				tool_name: s.tool_name
				tool_args: s.tool_args
			}
			state.status = 'running ${s.tool_name}...'
		}
		.tool_result {
			state.blocks << Block{
				kind: .tool_result
				tool_name: s.tool_name
				tool_result: s.tool_result
				tool_is_error: s.tool_is_err
			}
			state.status = 'idle'
		}
		.finished {
			// Promote the streamed content into permanent blocks. Thinking
			// goes first so the rendered order matches kimi-code: dim
			// reasoning above, then the assistant answer below.
			if state.streaming_thinking.len > 0 {
				state.blocks << Block{
					kind: .thinking
					text: state.streaming_thinking
				}
			}
			if state.streaming.len > 0 {
				state.blocks << Block{
					kind: .assistant
					text: state.streaming
				}
			}
			state.streaming = ''
			state.streaming_thinking = ''
			state.streaming_done = true
			state.input_tokens += s.input_tokens
			state.output_tokens += s.output_tokens
			state.status = 'idle'
		}
		.errored {
			state.blocks << Block{
				kind: .system
				text: 'error: ${s.err}'
			}
			state.status = 'idle'
		}
		.cancelled {
			// Promote any partial streamed content into permanent blocks
			// before clearing, so the user can see what was produced
			// before the interrupt. Same logic as .finished.
			if state.streaming_thinking.len > 0 {
				state.blocks << Block{
					kind: .thinking
					text: state.streaming_thinking
				}
			}
			if state.streaming.len > 0 {
				state.blocks << Block{
					kind: .assistant
					text: state.streaming
				}
			}
			state.streaming = ''
			state.streaming_thinking = ''
			state.streaming_done = true
			state.blocks << Block{
				kind: .system
				text: '[cancelled]'
			}
			state.status = 'idle'
		}
		.plan_mode {
			// Plan-mode state changed (entered / exited). Surface the
			// notice as a system block and reflect the active state in
			// the TUI so the render loop can draw the banner.
			state.blocks << Block{
				kind: .system
				text: s.err
			}
			if s.err.to_lower().contains('entered plan mode') {
				state.plan_mode_active = true
			} else if s.err.to_lower().contains('exited plan mode') {
				state.plan_mode_active = false
			}
			state.status = 'idle'
		}
	}
}

// handle_key applies a KeyEvent to the input buffer or other state.
// May push a SubmitMsg to submit_ch, run a shell command, or trigger
// a slash command.
fn handle_key(ev KeyEvent, mut state TuiState, mut ib InputBuf, submit_ch chan SubmitMsg, mut cfg Config, decision_ch chan ApprovalDecision, steer_ch chan string, ask_result_ch chan AskResult, exit_plan_result_ch chan ExitPlanResult, plan_control_ch chan PlanControl) {
	// Most keys mutate the visible state. Mark dirty so the loop repaints;
	// paths that are no-ops (e.g. a key eaten while a modal is up) cause
	// at most one redundant paint, which is harmless.
	state.dirty = true
	// EOF from stdin: pipe broken, TTY disconnected. Trigger a clean
	// shutdown so the user doesn't get stuck in raw mode.
	if ev.kind == .stdin_eof {
		state.should_exit = true
		return
	}
	// Focus-in/out reports from the terminal. On focus-in, check whether
	// the system clipboard holds an image and surface a paste hint.
	if ev.kind == .focus_in {
		if clipboard_has_image() {
			state.status = 'Ctrl+V to paste image'
		} else if state.status == 'Ctrl+V to paste image' {
			state.status = 'idle'
		}
		return
	}
	if ev.kind == .focus_out {
		return
	}
	// If the model asked a question (AskUserQuestion), route digit keys
	// to option selection, comma-separated digits for multi-select, and
	// Esc to skip. Everything else is ignored while the modal is up.
	if state.pending_ask != none {
		req := state.pending_ask or { return }
		if ev.kind == .esc {
			ask_result_ch <- AskResult{ id: req.id, ok: false } or {}
			state.pending_ask = none
			state.status = 'question skipped'
			return
		}
		if ev.kind == .char {
			if ev.text == '\n' || ev.text == '\r' {
				// Enter with no accumulated buffer in single-char mode:
				// treat as "no selection yet" — ignore. Multi-select uses
				// comma which we gather below.
				return
			}
			// Accumulate the user's typed selection in the input buffer
			// text so a comma-separated list like "1,3" builds up. We
			// re-use ib.text as a scratch area for the selection.
			if ev.text.len == 1 {
				c := ev.text[0]
				if (c >= `0` && c <= `9`) || c == `,` || c == ` ` {
					ib.text += ev.text
					state.status = 'answer: ${ib.text} (Enter to confirm, Esc to skip)'
					return
				}
			}
			// Confirm selection on Enter (the .enter kind is handled by
			// the apply() path only when not in a modal, so we trap it
			// here via the .char newline above; also handle .enter kind).
			is_enter := ev.kind == .enter
			if is_enter || (ev.text.len == 1 && (ev.text[0] == `\n` || ev.text[0] == `\r`)) {
				sel := parse_selection(ib.text, req.options.len, req.multi)
				ib.text = ''
				if sel.len == 0 {
					state.status = 'invalid selection; try again or Esc'
					return
				}
				mut choices := []string{}
				for idx in sel {
					choices << req.options[idx - 1].label
				}
				ask_result_ch <- AskResult{ id: req.id, ok: true, choices: choices } or {}
				state.pending_ask = none
				state.status = 'answered'
				return
			}
		}
		// Eat all other keys while the ask modal is up.
		return
	}
	// If the model finished planning (ExitPlanMode), route plan-review
	// keys: y=approve, n=reject (stay), e=reject+exit, r=revise,
	// Esc=dismiss; digit keys pick a specific approach when offered.
	if state.pending_exit_plan != none {
		req := state.pending_exit_plan or { return }
		// Digit keys select a specific approach (when options are offered).
		if ev.kind == .char && req.options.len >= 2 {
			c := ev.text[0]
			if c >= `1` && c <= `9` {
				idx := int(c - `0`)
				if idx <= req.options.len {
					sel := req.options[idx - 1]
					exit_plan_result_ch <- ExitPlanResult{
						id:             req.id
						decision:       'approved'
						selected_label: sel.label
					} or {}
					state.pending_exit_plan = none
					state.status = 'plan approved: ${sel.label}'
					return
				}
			}
		}
		if ev.kind == .char {
			t := ev.text.to_lower()
			if t == 'y' {
				exit_plan_result_ch <- ExitPlanResult{
					id:       req.id
					decision: 'approved'
				} or {}
				state.pending_exit_plan = none
				state.plan_mode_active = false
				state.status = 'plan approved'
				return
			}
			if t == 'n' {
				exit_plan_result_ch <- ExitPlanResult{
					id:       req.id
					decision: 'rejected'
				} or {}
				state.pending_exit_plan = none
				state.status = 'plan rejected (still in plan mode)'
				return
			}
			if t == 'e' {
				exit_plan_result_ch <- ExitPlanResult{
					id:       req.id
					decision: 'rejected_and_exit'
				} or {}
				state.pending_exit_plan = none
				state.plan_mode_active = false
				state.status = 'plan rejected; exiting plan mode'
				return
			}
			if t == 'r' {
				exit_plan_result_ch <- ExitPlanResult{
					id:       req.id
					decision: 'revise'
				} or {}
				state.pending_exit_plan = none
				state.status = 'plan revision requested'
				return
			}
		}
		if ev.kind == .esc {
			exit_plan_result_ch <- ExitPlanResult{
				id:       req.id
				decision: 'dismissed'
			} or {}
			state.pending_exit_plan = none
			state.status = 'plan approval dismissed'
			return
		}
		// Eat all other keys while the plan-review modal is up.
		return
	}
	// If a risky tool is awaiting approval, route y/n to the decision
	// channel and ignore everything else (modal is modal — user can't
	// type in the input box while it's up).
	if state.pending_approval != none {
		if ev.kind == .char {
			if ev.text == 'y' || ev.text == 'Y' {
				req := state.pending_approval or { return }
				decision_ch <- ApprovalDecision{ id: req.id, approved: true } or {}
				state.pending_approval = none
				state.status = 'running...'
				return
			}
			if ev.text == 'a' || ev.text == 'A' {
				// "always for this session" — approve this call AND
				// add the tool name to cfg.approved_tools so the agent
				// short-circuits the modal for future calls. Sensitive
				// patterns (rm -rf, sudo, etc.) still re-prompt because
				// the agent checks those before consulting the allowlist.
				req := state.pending_approval or { return }
				decision_ch <- ApprovalDecision{ id: req.id, approved: true } or {}
				if req.tool_name !in cfg.approved_tools {
					cfg.approved_tools << req.tool_name
				}
				state.pending_approval = none
				state.status = 'always-allow: ${req.tool_name}'
				return
			}
			if ev.text == 'n' || ev.text == 'N' {
				req := state.pending_approval or { return }
				decision_ch <- ApprovalDecision{ id: req.id, approved: false } or {}
				state.pending_approval = none
				state.status = 'denied'
				return
			}
		}
		if ev.kind == .esc {
			// Esc inside the modal = deny (consistent with "Esc = cancel" elsewhere).
			req := state.pending_approval or { return }
			decision_ch <- ApprovalDecision{ id: req.id, approved: false } or {}
			state.pending_approval = none
			state.status = 'denied'
			return
		}
		// Eat all other keys while the modal is up.
		return
	}
	if ev.kind == .esc {
		state.should_exit = true
		return
	}
	if ev.kind == .interrupt {
		state.should_interrupt = true
		state.status = 'interrupt requested...'
		return
	}
	// Ctrl-S during a streaming turn: inject the current input box
	// contents as a new user message. The agent's step() returns when
	// it sees the steer and the main loop calls step() again with the
	// appended message. The input buffer is consumed but not cleared
	// (we want the user to see what they just steered with). A no-op
	// when the agent isn't running (Ctrl-S in idle state).
	if ev.kind == .steer {
		if state.status == 'idle' {
			// No agent turn to steer. Treat as a hint.
			state.status = 'idle (Ctrl-S: nothing to steer)'
			return
		}
		prompt := ib.text.trim_space()
		if prompt.len == 0 {
			state.status = 'steer: empty input, ignored'
			return
		}
		// Surface the steered message as a system block so the user can
		// see what's being sent. Distinct from a `.user` block because
		// it's mid-turn, not a fresh prompt.
		state.blocks << Block{
			kind: .system
			text: '⤳ steer: ${prompt}'
		}
		steer_ch <- prompt or {}
		state.status = 'steering...'
		return
	}
	if ev.kind == .clear_screen {
		return
	}
	// Ctrl-O: toggle collapse of all tool_result blocks. If any are
	// expanded, collapse them all (so a single press cleans up the
	// scrollback); if all are already collapsed, expand them. No-op
	// when there are no tool_result blocks — we surface a brief hint
	// in the status line so the user knows we heard the key.
	if ev.kind == .collapse {
		toggle_collapse(mut state)
		return
	}
	// Ctrl-X: drop all pending image attachments. Surface a status
	// hint with the count (or "no attachments" if the buffer was
	// empty) so the user knows the key was received even when
	// there was nothing to clear.
	if ev.kind == .clear_attachments {
		n := ib.clear_attachments()
		if n == 0 {
			state.status = 'no attachments to clear'
		} else {
			plural := if n == 1 { '' } else { 's' }
			state.status = 'cleared ${n} attachment${plural}'
		}
		return
	}
	if ev.kind == .enter && ib.text.starts_with('/') {
		cmd := ib.text.all_after('/').trim_space()
		if handle_slash(cmd, mut state, mut ib, mut cfg, plan_control_ch, submit_ch) {
			return
		}
	}
	// Bracketed-paste event: a chunk of text pasted by the terminal
	// (wrapped in ESC[200~...ESC[201~). Try to attach it if it looks
	// like a single image path or data URL; otherwise insert it as text
	// so multi-line paste doesn't auto-submit.
	if ev.kind == .paste {
		text := ev.text
		candidate := text.trim_space()
		if looks_like_attach_candidate(candidate) {
			mut ok := false
			mut att_name := ''
			if candidate.starts_with('data:image/') {
				if ib.attach_data_url(candidate) {
					ok = true
					if ib.attachments.len > 0 {
						att_name = ib.attachments[ib.attachments.len - 1].name
					}
				}
			} else {
				if ib.attach_file(cfg.cwd, candidate) {
					ok = true
					if ib.attachments.len > 0 {
						att_name = ib.attachments[ib.attachments.len - 1].name
					}
				}
			}
			if ok {
				state.status = 'attached ${att_name} (Ctrl-X to clear, Enter to send)'
				return
			}
		}
		// Not an attach candidate or attach failed: insert as plain text.
		ib.insert(text)
		return
	}
	// Auto-attach: when a single `.char` event delivers a string that
	// looks like a file path or a data: URL, try to attach the image
	// instead of inserting the text. If the attach fails (path
	// doesn't exist, wrong extension, too large) we fall through to
	// apply() so the text lands in the buffer as a normal character —
	// the user can backspace if they didn't mean to paste a path.
	// This runs BEFORE apply() so the char event is consumed on
	// success (no spurious text appears in the input box).
	if ev.kind == .char {
		text := ev.text
		if looks_like_attach_candidate(text) {
			mut ok := false
			mut att_name := ''
			if text.starts_with('data:image/') {
				if ib.attach_data_url(text) {
					ok = true
					if ib.attachments.len > 0 {
						att_name = ib.attachments[ib.attachments.len - 1].name
					}
				}
			} else {
				if ib.attach_file(cfg.cwd, text) {
					ok = true
					if ib.attachments.len > 0 {
						att_name = ib.attachments[ib.attachments.len - 1].name
					}
				}
			}
			if ok {
				state.status = 'attached ${att_name} (Ctrl-X to clear, Enter to send)'
				return
			}
		}
	}
	// Capture the text before apply() (which clears it on submit).
	pre_submit_text := ib.text
	kind := ib.apply(ev)
	match kind {
		.agent {
			state.blocks << Block{
				kind: .user
				text: pre_submit_text
			}
			// Snapshot the pending attachments and clear the buffer's
			// list — they're now committed to the submit message and
			// the buffer shouldn't keep showing them. The session's
			// copy is what gets serialized to the wire.
			pending := ib.attachments.clone()
			ib.attachments = []Attachment{}
			submit_ch <- SubmitMsg{
				prompt:      pre_submit_text
				attachments: pending
			}
		}
		.shell {
			// Strip the leading `!` and run as a shell command. We don't
			// ask for approval — the user typed it, so they own the
			// consequences. Output is captured and rendered as a system
			// block (compact, dim) so it doesn't pollute the chat
			// transcript.
			cmd := pre_submit_text[1..].trim_space()
			if cmd.len == 0 {
				// Bare `!` (Enter on a `!` line) is a no-op; don't
				// pretend we ran a command.
				state.blocks << Block{
					kind: .system
					text: '(shell: empty command)'
				}
				return
			}
			state.blocks << Block{
				kind: .user
				text: pre_submit_text
			}
			run_shell_block(mut state, cmd, cfg.cwd)
		}
		.none {
			// nothing
		}
	}
}

// run_shell_block executes `cmd` via the host shell and appends the
// result to state.blocks as a system block. The command runs in the
// session cwd (cfg.cwd is passed in; TuiState itself doesn't carry
// cwd, so the caller must thread it through). A non-zero exit code is
// reported inline so the user can spot failures without scrolling.
const shell_max_lines = 200

fn run_shell_block(mut state TuiState, cmd string, cwd string) {
	res := os.execute('cd "${cwd}" && ${cmd}')
	exit := res.exit_code
	output := res.output
	// Truncate very long output to keep the TUI from scrolling forever.
	// 200 lines is enough for status commands; longer output can be
	// inspected via the bash tool if the user really wants it.
	lines := output.split('\n')
	mut truncated := false
	mut shown := lines.clone()
	if lines.len > shell_max_lines {
		shown = lines[..shell_max_lines].clone()
		truncated = true
	}
	mut body := shown.join('\n')
	if truncated {
		body += '\n[... ${lines.len - shell_max_lines} more lines truncated; rerun via the bash tool for the full output ...]'
	}
	mut prefix := '\$ ${cmd}\n'
	if exit != 0 {
		prefix = '\$ ${cmd}  [exit ${exit}]\n'
	}
	state.blocks << Block{
		kind: .system
		text: '${prefix}${body}'
	}
}

// toggle_collapse flips the `collapsed` flag on every .tool_result
// block in the scrollback. If any tool_result is currently expanded,
// all get folded to a one-line summary; if they're all already
// collapsed, they all expand. This matches the "press once to fold,
// press again to unfold" muscle memory that IDEs and kimi-code itself
// use. No-op (with a status hint) when there are zero tool_result
// blocks — pressing Ctrl-O in a chat with no tool calls shouldn't be
// silent.
fn toggle_collapse(mut state TuiState) {
	n_results := state.blocks.filter(it.kind == .tool_result).len
	if n_results == 0 {
		state.status = 'no tool results to collapse'
		return
	}
	any_expanded := state.blocks.any(it.kind == .tool_result && !it.collapsed)
	// If any block is expanded, fold them all; otherwise expand them all.
	target := any_expanded
	for i in 0 .. state.blocks.len {
		if state.blocks[i].kind == .tool_result {
			state.blocks[i].collapsed = target
		}
	}
	plural := if n_results == 1 { '' } else { 's' }
	if target {
		state.status = 'collapsed ${n_results} tool result${plural} (Ctrl-O to expand)'
	} else {
		state.status = 'expanded ${n_results} tool result${plural}'
	}
}

// handle_slash processes slash commands. Returns true if handled.
fn handle_slash(cmd string, mut state TuiState, mut ib InputBuf, mut cfg Config, plan_control_ch chan PlanControl, submit_ch chan SubmitMsg) bool {
	parts := cmd.split(' ')
	// `/skill:NAME [args]` — load a skill's instructions into context by
	// submitting its expanded body as a user turn. Mirrors upstream
	// `/skill:NAME` (the colon form, distinct from the `Skill` tool the
	// model calls on its own).
	if parts[0].starts_with('skill:') {
		name := parts[0]['skill:'.len..].trim_space()
		args := if parts.len > 1 { parts[1..].join(' ').trim_space() } else { '' }
		if name.len == 0 {
			state.blocks << Block{
				kind: .system
				text: 'usage: /skill:NAME [args]'
			}
			ib.text = ''
			ib.cursor = 0
			return true
		}
		catalog := discover_skills(cfg.cwd)
		def := catalog.get(name) or {
			mut names := []string{}
			for s in catalog.skills {
				names << s.name
			}
			avail := if names.len > 0 { names.join(', ') } else { '(none installed)' }
			state.blocks << Block{
				kind: .system
				text: 'skill "${name}" not found. Installed: ${avail}'
			}
			ib.text = ''
			ib.cursor = 0
			return true
		}
		expanded := expand_skill_parameters(def.content, args, def.dir, '', def.arguments)
		state.blocks << Block{
			kind: .user
			text: '/skill:${name}${if args.len > 0 { ' ' + args } else { '' }}'
		}
		submit_ch <- SubmitMsg{
			prompt: '# Skill: ${def.name}\n\n${expanded}'
		}
		ib.text = ''
		ib.cursor = 0
		return true
	}
	match parts[0] {
		'help' {
			state.blocks << Block{
				kind: .system
				text: 'slash commands:\n  /help        show this\n  /clear       clear conversation\n  /login       store credentials\n  /model NAME  switch model\n  /plan        enter plan mode (read-only planning)\n  /tokens      show usage tally\n  /usage       alias for /tokens\n  /compact     force context compaction on next turn\n  /yolo [on|off]  toggle YOLO mode (skip approvals)\n  /mcp         list connected MCP servers and their tools\n  /exit        leave TUI\n\nhotkeys:\n  Ctrl-C       cancel current turn\n  Ctrl-L       clear screen\n  Ctrl-S       steer — inject input mid-turn\n  Ctrl-O       toggle collapse of tool results\n  Ctrl-X       clear pending image attachments\n\nplan review (when a plan is ready):\n  y            approve plan\n  1/2/3        approve a specific approach (when offered)\n  n            reject (stay in plan mode)\n  e            reject and exit plan mode\n  r            request revisions\n  Esc          dismiss\n\nattachments:\n  paste a path to a .png/.jpg/.jpeg/.gif/.webp/.bmp file\n  (absolute, or ~/... / ./... / ../... relative to cwd) to attach\n  paste a data:image/...;base64,... URL to attach\n  multi-line image input: paste a path on a new line, then type'
			}
		}
		'clear' {
			state.blocks = []
			state.streaming = ''
			state.streaming_done = true
			state.status = 'idle'
		}
		'login' {
			state.blocks << Block{
				kind: .system
				text: 'use `kimi login` from another shell (TUI cannot read passwords yet)'
			}
		}
		'model' {
			if parts.len >= 2 {
				cfg.model = parts[1]
				state.blocks << Block{
					kind: .system
					text: 'model set to ${cfg.model} (takes effect on next turn)'
				}
			} else {
				state.blocks << Block{
					kind: .system
					text: 'current model: ${cfg.model}\nusage: /model <name>'
				}
			}
		}
		'tokens', 'usage' {
			// `state.input_tokens / output_tokens` is the running tally
			// of the current session, accumulated by the agent loop
			// (see tui_loop.v around line 335).
			state.blocks << Block{
				kind: .system
				text: 'session tokens: ${state.input_tokens} in / ${state.output_tokens} out'
			}
		}
		'compact' {
			// Compaction runs automatically when the session crosses
			// 60% of the model's context window. The check happens at
			// the start of each agent step, so the next turn (or any
			// tool call that gets sent to the LLM) is when it'll fire.
			// This slash command just surfaces the current estimated
			// state so the user can decide whether to send a fresh
			// message and trigger compaction immediately.
			//
			// A future enhancement could request compaction inline via
			// a control channel between the TUI and agent loop; for now
			// we just print the status and let the auto-trigger handle it.
			est := state.input_tokens + state.output_tokens
			state.blocks << Block{
				kind: .system
				text: 'compaction runs automatically at 60% of the context window. ' +
					'current est tokens: ${est}.\n' +
					'to trigger now, send any message — the next turn compacts if over threshold.'
			}
		}
		'yolo', 'yes' {
			// `/yolo [on|off]` toggles yolo mode. With no arg, flips the
			// current state. With explicit `on`/`off`, forces the value.
			// Mutates cfg.yolo in place; the agent_runner_loop already
			// shares the reference so the next tool call sees the change.
			mut target := !cfg.yolo
			if parts.len >= 2 {
				match parts[1] {
					'on' { target = true }
					'off' { target = false }
					'true' { target = true }
					'false' { target = false }
					else {}
				}
			}
			cfg.yolo = target
			label := if cfg.yolo { 'on' } else { 'off' }
			state.blocks << Block{
				kind: .system
				text: 'yolo mode: ${label} (tool approvals ${if cfg.yolo { "skipped" } else { "back on" }}; sensitive patterns still re-prompt)'
			}
		}
		'mcp' {
			// List configured MCP servers and their live connection state.
			// Tools from each server are exposed to the model as
			// `mcp__<server>__<tool>` and can be invoked directly; this
			// command only shows configuration + connectivity.
			mut lines := ['MCP servers:']
			if cfg.mcp_servers.len == 0 {
				lines << '  (none configured — add a [[mcp]] table to config.toml)'
			}
			for srv in cfg.mcp_servers {
				transport := if srv.url.len > 0 { srv.url } else { '${srv.command} ${srv.args.join(' ')}' }
				connected := srv.name in state.mcp_connected
				status := if connected { 'connected' } else { 'not connected' }
				lines << '  - ${srv.name}: ${status} (${transport})'
			}
			state.blocks << Block{
				kind: .system
				text: lines.join('\n')
			}
		}
		'exit', 'quit' {
			state.should_exit = true
		}
		'plan' {
			// `/plan` enters plan mode directly (equivalent to the model
			// calling EnterPlanMode). We forward the request to the agent
			// runner via plan_control_ch; it flips the agent's plan-mode
			// state and emits a system block confirming the plan file path.
			plan_control_ch <- PlanControl{ kind: 'enter' } or {}
		}
		else {
			state.blocks << Block{
				kind: .system
				text: 'unknown command: /${parts[0]} (try /help)'
			}
		}
	}
	ib.text = ''
	ib.cursor = 0
	return true
}

// parse_selection parses a user-typed answer ("1", "1,3", " 2 ") into a
// de-duplicated, sorted list of 1-based option indices. Out-of-range or
// non-numeric tokens are dropped. When `multi` is false and the user gave
// more than one valid index, we keep only the first (the harness still
// answers with that single choice — matches single-select semantics).
fn parse_selection(raw string, option_count int, multi bool) []int {
	mut out := []int{}
	for tok in raw.split(',') {
		t := tok.trim_space()
		if t.len == 0 {
			continue
		}
		// Single digit (we only support 1-9 options; upstream caps at 4).
		if t.len == 1 && t[0] >= `1` && t[0] <= `9` {
			n := int(t[0] - `0`)
			if n <= option_count {
				out << n
			}
		}
	}
	if out.len == 0 {
		return []
	}
	// De-duplicate.
	mut seen := map[int]bool{}
	mut dedup := []int{}
	for n in out {
		if n !in seen {
			seen[n] = true
			dedup << n
		}
	}
	if !multi && dedup.len > 1 {
		return [dedup[0]]
	}
	return dedup
}