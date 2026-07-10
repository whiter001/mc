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

import time

// TuiLoopResult tells main() how to proceed after the loop exits.
pub enum TuiLoopResult {
	clean_exit
	fallback_to_stdout
}

// SubmitMsg is sent from the input loop to the agent runner.
pub struct SubmitMsg {
pub:
	prompt string
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
	errored
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

pub fn status_started() TuiStatus { return TuiStatus{ kind: .started } }

pub fn status_delta(chunk string) TuiStatus {
	return TuiStatus{ kind: .delta, chunk: chunk }
}

pub fn status_thinking_delta(chunk string) TuiStatus {
	return TuiStatus{ kind: .thinking_delta, chunk: chunk }
}

pub fn status_tool_call(name string, args string) TuiStatus {
	return TuiStatus{ kind: .tool_call, tool_name: name, tool_args: args }
}

pub fn status_tool_result(name string, result string, is_err bool) TuiStatus {
	return TuiStatus{ kind: .tool_result, tool_name: name, tool_result: result, tool_is_err: is_err }
}

pub fn status_finished(input_tokens int, output_tokens int) TuiStatus {
	return TuiStatus{
		kind: .finished
		input_tokens: input_tokens
		output_tokens: output_tokens
	}
}

pub fn status_errored(err string) TuiStatus {
	return TuiStatus{ kind: .errored, err: err }
}

// run_tui is the main interactive loop. Returns:
//   - .clean_exit on user request (Esc Esc or /exit)
//   - .fallback_to_stdout if TUI can't initialize (non-TTY)
pub fn run_tui(mut cfg Config, provider OpenAICompatProvider) TuiLoopResult {
	mut state := new_tui_state()
	mut ib := new_input_buf()

	if !enter_tui() {
		return .fallback_to_stdout
	}

	key_ch := chan KeyEvent{cap: 16}
	submit_ch := chan SubmitMsg{cap: 4}
	status_ch := chan TuiStatus{cap: 32}

	spawn key_reader_loop(key_ch)
	spawn agent_runner_loop(provider, cfg, submit_ch, status_ch)

	state.should_exit = false
	state.should_interrupt = false
	mut last_render_ms := i64(0)
	render_interval_ms := i64(33)

	for {
		// Non-blocking drain of all available events. V's select takes
		// integer nanosecond durations, so 1ms = 1_000_000.
		mut drain_status := true
		for drain_status {
			select {
				s := <-status_ch {
					handle_status(s, mut state)
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
					handle_key(ev, mut state, mut ib, submit_ch, mut cfg)
				}
				1 * time.millisecond {
					drain_keys = false
				}
			}
		}

		now_ms := time.now().unix_milli()
		if now_ms - last_render_ms >= render_interval_ms {
			frame := render(state, ib)
			write_stdout(frame)
			last_render_ms = now_ms
		}

		if state.should_exit {
			break
		}

		if state.status == 'idle' && state.streaming.len == 0 {
			time.sleep(10 * time.millisecond)
		}
	}

	leave_tui()
	return .clean_exit
}

// key_reader_loop pulls keys from stdin and pushes them onto key_ch.
fn key_reader_loop(key_ch chan KeyEvent) {
	mut reader := new_stdin_reader()
	for {
		ev := reader.read_key()
		key_ch <- ev
		if ev.kind == .none {
			break
		}
	}
}

// agent_runner_loop consumes SubmitMsg and runs the agent, pushing status
// updates as it goes.
fn agent_runner_loop(provider OpenAICompatProvider, cfg Config, submit_ch chan SubmitMsg, status_ch chan TuiStatus) {
	mut agent := new_agent(provider, cfg.system_prompt)
	agent.max_turns = cfg.max_turns
	agent.registry = default_registry(cfg.cwd)
	mut sess := new_session(cfg.cwd)

	for {
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

		sess.append_user(msg.prompt)
		status_ch <- status_started()

		res := agent.run(mut sess) or {
			status_ch <- status_errored(err.msg())
			continue
		}

		// Signal "stream done" — the consumer promotes whatever has
		// accumulated in state.streaming / state.streaming_thinking into
		// permanent blocks.
		status_ch <- status_finished(res.usage.input_tokens, res.usage.output_tokens)
	}
}

// handle_status updates TuiState based on a TuiStatus message.
fn handle_status(s TuiStatus, mut state TuiState) {
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
	}
}

// handle_key applies a KeyEvent to the input buffer or other state.
// May push a SubmitMsg to submit_ch.
fn handle_key(ev KeyEvent, mut state TuiState, mut ib InputBuf, submit_ch chan SubmitMsg, mut cfg Config) {
	if ev.kind == .esc {
		state.should_exit = true
		return
	}
	if ev.kind == .interrupt {
		state.should_interrupt = true
		state.status = 'interrupt requested...'
		return
	}
	if ev.kind == .clear_screen {
		return
	}
	if ev.kind == .enter && ib.text.starts_with('/') {
		cmd := ib.text.all_after('/').trim_space()
		if handle_slash(cmd, mut state, mut ib, mut cfg) {
			return
		}
	}
	if ib.apply(ev) {
		state.blocks << Block{
			kind: .user
			text: ib.text
		}
		submit_ch <- SubmitMsg{ prompt: ib.text }
	}
}

// handle_slash processes slash commands. Returns true if handled.
fn handle_slash(cmd string, mut state TuiState, mut ib InputBuf, mut cfg Config) bool {
	parts := cmd.split(' ')
	match parts[0] {
		'help' {
			state.blocks << Block{
				kind: .system
				text: 'slash commands:\n  /help        show this\n  /clear       clear conversation\n  /login       store credentials\n  /model NAME  switch model\n  /tokens      show usage tally\n  /exit        leave TUI'
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
		'tokens' {
			state.blocks << Block{
				kind: .system
				text: 'session tokens: ${state.input_tokens} in / ${state.output_tokens} out'
			}
		}
		'exit', 'quit' {
			state.should_exit = true
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