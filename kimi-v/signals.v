// signals.v — install OS signal handlers that ask the TUI to exit cleanly.
//
// Without these, the process can be left in raw mode (terminal looks
// broken) when:
//
//   - SIGHUP: parent shell / ssh session goes away
//   - SIGTERM: graceful kill (e.g. systemd stop)
//   - SIGPIPE: stdout is closed (piped to `head` etc.)
//
// The TUI main loop watches the `shutdown_ch` channel; we push 1 from the
// signal handler. The loop then calls `leave_tui()` + `exit(0)` on its
// own — keeping all terminal restoration in one place (the main loop).
//
// On non-unix (Windows) we install only what the runtime supports.

module main

import os

// install_signal_handlers wires the TUI shutdown channel into the OS
// signal handlers. Call this from `run_tui` right after the alt-screen
// is entered. Safe to call more than once — V replaces the prior
// handler on each `signal_opt`.
//
// The closures capture `shutdown_ch` explicitly (V's `fn ()` closures
// capture by reference; `fn [shutdown_ch] ()` is the V-idiomatic way to
// pull a local into a callback).
pub fn install_signal_handlers(shutdown_ch chan int) {
	$if !windows {
		os.signal_opt(.hup, fn [shutdown_ch] (_ os.Signal) {
			request_shutdown(shutdown_ch)
		}) or {}
		os.signal_opt(.term, fn [shutdown_ch] (_ os.Signal) {
			request_shutdown(shutdown_ch)
		}) or {}
		// SIGPIPE: don't die when the downstream pipe is closed (e.g. user
		// pipes our stdout into `head`). We treat it as a clean exit so
		// the rest of the process (history save, etc.) still runs.
		os.signal_ignore(.pipe)
	}
}
