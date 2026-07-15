// internal/util/log.v
// Tiny structured logger. The output is intentionally minimal — Kimi Code's
// primary surface is the TUI, so logs are a diagnostic fallback.
module main

import time

// Level is the severity threshold for log output.
pub enum Level {
	debug = 0
	info  = 1
	warn  = 2
	err   = 3
}

// Logger writes structured log messages through a LogSink when the message
// level is at or above the configured threshold.
pub struct Logger {
pub mut:
	level Level
	sink  LogSink
}

// LogSink receives formatted log lines. Implementations decide where to write.
pub interface LogSink {
	write(ts time.Time, level Level, msg string)
}

// StdioSink writes log lines to stderr with a level tag and timestamp.
struct StdioSink {}

// write formats and emits one log line to stderr.
fn (s StdioSink) write(ts time.Time, level Level, msg string) {
	tag := match level {
		.debug { 'DEBUG' }
		.info { 'INFO ' }
		.warn { 'WARN ' }
		.err { 'ERROR' }
	}

	eprintln('[${tag}] ${ts.format_ss()}  ${msg}')
}

// new_logger creates a logger that writes to stderr at the given level.
pub fn new_logger(level Level) Logger {
	return Logger{
		level: level
		sink:  StdioSink{}
	}
}

// debug logs a debug message if the logger level is debug.
pub fn (mut l Logger) debug(msg string) {
	if int(l.level) <= int(Level.debug) {
		l.sink.write(time.now(), .debug, msg)
	}
}

// info logs an info message if the logger level is info or lower.
pub fn (mut l Logger) info(msg string) {
	if int(l.level) <= int(Level.info) {
		l.sink.write(time.now(), .info, msg)
	}
}

// warn logs a warning message if the logger level is warn or lower.
pub fn (mut l Logger) warn(msg string) {
	if int(l.level) <= int(Level.warn) {
		l.sink.write(time.now(), .warn, msg)
	}
}

// error logs an error message if the logger level is error or lower.
pub fn (mut l Logger) error(msg string) {
	if int(l.level) <= int(Level.err) {
		l.sink.write(time.now(), .err, msg)
	}
}

// Level parsing for CLI / env.
pub fn parse_level(s string) Level {
	return match s.to_lower() {
		'debug' { .debug }
		'info' { .info }
		'warn', 'warning' { .warn }
		'error', 'err' { .err }
		else { .info }
	}
}

// Suppress unused import warning if os isn't referenced yet.
// (removed: const unused = ...)
