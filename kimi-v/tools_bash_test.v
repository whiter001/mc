// tools_bash_test.v — unit tests for BashTool's timeout implementation.
//
// The implementation polls os.Process.is_alive() — no goroutines, no
// channels — so these integration-style tests are safe for the V test
// runner (unlike the provider/streaming paths).
module main

import os

fn bash_ctx() ToolContext {
	return ToolContext{
		cwd:        os.temp_dir()
		permission: 'default'
	}
}

// ---------- bash_timeout_ms (pure) -----------------------------------------

fn test_bash_timeout_ms_default() {
	assert bash_timeout_ms(0) == 60_000
	assert bash_timeout_ms(-5) == 60_000
}

fn test_bash_timeout_ms_passthrough() {
	assert bash_timeout_ms(5_000) == 5_000
	assert bash_timeout_ms(300_000) == 300_000
}

fn test_bash_timeout_ms_capped() {
	assert bash_timeout_ms(300_001) == 300_000
	assert bash_timeout_ms(999_999_999) == 300_000
}

// ---------- BashTool.execute ------------------------------------------------

fn test_bash_execute_short_command() {
	tool := BashTool{ cwd: os.temp_dir() }
	res := tool.execute(ToolArgs{ raw: '{"command":"echo hi"}' }, bash_ctx()) or { panic(err) }
	assert !res.is_error
	assert res.content.contains('hi')
}

fn test_bash_execute_nonzero_exit() {
	tool := BashTool{ cwd: os.temp_dir() }
	res := tool.execute(ToolArgs{ raw: '{"command":"echo oops >&2; exit 3"}' }, bash_ctx()) or {
		panic(err)
	}
	assert res.is_error
	assert res.content.contains('oops')
	assert res.content.contains('[exit 3]')
}

fn test_bash_execute_timeout_kills() {
	tool := BashTool{ cwd: os.temp_dir() }
	res := tool.execute(ToolArgs{ raw: '{"command":"sleep 30; echo never","timeout_ms":200}' },
		bash_ctx()) or { panic(err) }
	assert res.is_error
	assert res.content.contains('timed out after 200 ms')
	assert !res.content.contains('never')
}

fn test_bash_execute_timeout_json_number() {
	// The model may send timeout_ms as a JSON number; the typed-struct
	// decode handles it (the map[string]string decode would silently
	// drop it and fall back to the 60s default).
	tool := BashTool{ cwd: os.temp_dir() }
	res := tool.execute(ToolArgs{ raw: '{"command":"echo ok","timeout_ms":5000}' }, bash_ctx()) or {
		panic(err)
	}
	assert !res.is_error
	assert res.content.contains('ok')
}

fn test_bash_execute_timeout_json_string() {
	// Some models send timeout_ms as a string; tolerated via the map
	// decode fallback.
	tool := BashTool{ cwd: os.temp_dir() }
	res := tool.execute(ToolArgs{ raw: '{"command":"sleep 30","timeout_ms":"200"}' }, bash_ctx()) or {
		panic(err)
	}
	assert res.is_error
	assert res.content.contains('timed out after 200 ms')
}
