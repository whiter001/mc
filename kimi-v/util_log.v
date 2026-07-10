// internal/util/log.v
// Tiny structured logger. The output is intentionally minimal — Kimi Code's
// primary surface is the TUI, so logs are a diagnostic fallback.
module main

import time

pub enum Level {
	debug = 0
	info  = 1
	warn  = 2
	err   = 3
}

pub struct Logger {
pub mut:
	level Level
	sink  LogSink
}

pub interface LogSink {
	write(ts time.Time, level Level, msg string)
}

struct StdioSink {}

fn (s StdioSink) write(ts time.Time, level Level, msg string) {
	tag := match level {
		.debug { 'DEBUG' }
		.info { 'INFO ' }
		.warn { 'WARN ' }
		.err { 'ERROR' }
	}

	eprintln('[${tag}] ${ts.format_ss()}  ${msg}')
}

pub fn new_logger(level Level) Logger {
	return Logger{
		level: level
		sink:  StdioSink{}
	}
}

pub fn (mut l Logger) debug(msg string) {
	if int(l.level) <= int(Level.debug) {
		l.sink.write(time.now(), .debug, msg)
	}
}

pub fn (mut l Logger) info(msg string) {
	if int(l.level) <= int(Level.info) {
		l.sink.write(time.now(), .info, msg)
	}
}

pub fn (mut l Logger) warn(msg string) {
	if int(l.level) <= int(Level.warn) {
		l.sink.write(time.now(), .warn, msg)
	}
}

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
