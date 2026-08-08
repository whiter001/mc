module main

import os

// Build the memlimit binary once, before any test runs.
fn testsuite_begin() {
	build := os.execute('v -prod -o memlimit .')
	assert build.exit_code == 0, 'building memlimit failed: ${build.output}'
}

// Safety net: make sure no test-spawned python processes survive the suite.
fn testsuite_end() {
	os.execute('pkill -f memlimit_test_marker')
}

// ---------------------------------------------------------------------------
// Unit tests: parse_ps
// ---------------------------------------------------------------------------

fn test_parse_ps_parses_valid_lines_and_skips_broken_ones() {
	out := '123 1 1024\n456 123 2048\n\n   \nxyz 1 100\n0 5 999\nnotenough 1\n789 abc 512\n999 888 777 555\n'
	procs := parse_ps(out)
	assert procs.len == 4
	assert procs[123] == ProcInfo{ ppid: 1, rss: 1024 }
	assert procs[456] == ProcInfo{ ppid: 123, rss: 2048 }
	// pid 789 is valid, but its non-numeric ppid "abc" parses to 0.
	assert procs[789] == ProcInfo{ ppid: 0, rss: 512 }
	// extra fields beyond pid/ppid/rss are ignored.
	assert procs[999] == ProcInfo{ ppid: 888, rss: 777 }
	// broken lines (blank, whitespace-only, non-numeric pid, pid 0,
	// fewer than 3 fields) must not appear in the map.
	assert 0 !in procs
	assert 1234 !in procs
}

fn test_parse_ps_empty_input_returns_empty_map() {
	procs := parse_ps('')
	assert procs.len == 0
}

// ---------------------------------------------------------------------------
// Unit tests: tree_rss_kb
// ---------------------------------------------------------------------------

fn test_tree_rss_kb_sums_root_and_all_descendants() {
	procs := {
		100: ProcInfo{ ppid: 1, rss: 1000 }
		200: ProcInfo{ ppid: 100, rss: 2000 }
		300: ProcInfo{ ppid: 200, rss: 3000 }
		400: ProcInfo{ ppid: 1, rss: 99999 }
	}
	// root 100 + child 200 + grandchild 300 = 6000; 400 is unrelated (parent 1).
	assert tree_rss_kb(100, procs) == 6000
}

fn test_tree_rss_kb_excludes_unrelated_pids() {
	procs := {
		100: ProcInfo{ ppid: 1, rss: 1000 }
		200: ProcInfo{ ppid: 100, rss: 2000 }
		999: ProcInfo{ ppid: 42, rss: 77777 }
	}
	// 999's parent is 42, not part of the 100-tree, so it must not count.
	assert tree_rss_kb(100, procs) == 3000
}

fn test_tree_rss_kb_missing_root_returns_zero() {
	procs := {
		200: ProcInfo{ ppid: 1, rss: 2000 }
	}
	assert tree_rss_kb(100, procs) == 0
}

fn test_tree_rss_kb_cycle_does_not_loop_forever() {
	procs := {
		100: ProcInfo{ ppid: 200, rss: 100 }
		200: ProcInfo{ ppid: 100, rss: 200 }
	}
	// 100 and 200 form a parent cycle; BFS with the visited set must terminate.
	assert tree_rss_kb(100, procs) == 300
}

// ---------------------------------------------------------------------------
// Integration tests (require the ./memlimit binary built in testsuite_begin)
// ---------------------------------------------------------------------------

fn test_integration_echo_exits_zero() {
	res := os.execute('./memlimit 500 echo hello')
	assert res.exit_code == 0, 'expected exit 0, got ${res.exit_code}: ${res.output}'
	assert res.output.contains('hello'), 'missing echo output: ${res.output}'
}

fn test_integration_child_exit_code_passthrough() {
	res := os.execute(r"./memlimit 500 sh -c 'exit 42'")
	assert res.exit_code == 42, 'expected exit 42, got ${res.exit_code}: ${res.output}'
}

fn test_integration_kills_over_limit() {
	// Allocate 500 MB and then hold it with sleep(3) so the process cannot
	// exit before the poll loop observes the RSS over the 50 MB limit.
	res := os.execute(r'./memlimit 50 python3 -c "a=[]; [a.append(bytearray(1048576)) for _ in range(500)]; import time; time.sleep(3)"')
	assert res.exit_code == 1, 'expected exit 1, got ${res.exit_code}: ${res.output}'
	assert res.output.contains('exceeded memory limit'), 'missing kill message: ${res.output}'
}

fn test_integration_tree_over_limit() {
	res := os.execute("./memlimit 60 sh -c 'python3 -c \"import time;a=bytearray(40*1024*1024);time.sleep(3)#memlimit_test_marker\" & python3 -c \"import time;a=bytearray(40*1024*1024);time.sleep(3)#memlimit_test_marker\" & wait'")
	assert res.exit_code == 1, 'expected exit 1, got ${res.exit_code}: ${res.output}'
	assert res.output.contains('exceeded memory limit'), 'missing kill message: ${res.output}'
	// The two background pythons survive the SIGKILL to their parent shell
	// (only the root pid is killed), so clean them up explicitly.
	os.execute('pkill -f memlimit_test_marker')
}

fn test_integration_tree_under_limit_exits_zero() {
	res := os.execute("./memlimit 120 sh -c 'python3 -c \"import time;a=bytearray(40*1024*1024);time.sleep(3)\" & python3 -c \"import time;a=bytearray(40*1024*1024);time.sleep(3)\" & wait'")
	assert res.exit_code == 0, 'expected exit 0, got ${res.exit_code}: ${res.output}'
}

fn test_integration_help_flag() {
	res := os.execute('./memlimit --help')
	assert res.exit_code == 0, 'expected exit 0, got ${res.exit_code}: ${res.output}'
	assert res.output.contains('usage: memlimit'), 'missing usage text: ${res.output}'
}

fn test_integration_no_args_usage_error() {
	res := os.execute('./memlimit')
	assert res.exit_code == 2, 'expected exit 2, got ${res.exit_code}: ${res.output}'
	assert res.output.contains('usage: memlimit'), 'missing usage text: ${res.output}'
}

fn test_integration_invalid_limit_usage_error() {
	res := os.execute('./memlimit abc echo hi')
	assert res.exit_code == 2, 'expected exit 2, got ${res.exit_code}: ${res.output}'
	assert res.output.contains('usage: memlimit'), 'missing usage text: ${res.output}'
}
