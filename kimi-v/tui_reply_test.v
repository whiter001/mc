// Temporary test: simulate the agent->status->render path for an assistant
// reply WITHOUT any network, to confirm the display layer renders streamed
// deltas + the promoted assistant block. If this passes, the rendering path
// is correct and the "reply not showing" bug lives upstream (provider/agent).
module main

fn test_assistant_reply_renders_without_network() {
	mut state := new_tui_state()
	ib := new_input_buf()
	state.cols = 80
	state.rows = 24
	handle_status(status_started(), mut state)
	handle_status(status_delta('Hello'), mut state)
	handle_status(status_delta(' world'), mut state)
	handle_status(status_finished(10, 5), mut state)
	frame := render(state, ib)
	assert frame.contains('Hello world'), 'assistant reply not rendered in frame:\n${frame}'
	// And the user message path too.
	mut s2 := new_tui_state()
	s2.cols = 80
	s2.rows = 24
	s2.blocks << Block{ kind: .user, text: 'ping' }
	f2 := render(s2, ib)
	assert f2.contains('ping'), 'user message not rendered:\n${f2}'
}
