@[has_globals]
module log

import time

// Level 是日志级别，从低到高排列：debug < info < warn < error。
pub enum Level {
	debug
	info
	warn
	error
}

__global (
	cur_level = Level.info
)

// set_level 设置全局日志级别：低于该级别的日志会被丢弃。
// 默认级别是 info。
pub fn set_level(level Level) {
	cur_level = level
}

// get_level 返回当前全局日志级别。
pub fn get_level() Level {
	return cur_level
}

// enabled 判断某个级别在当前全局级别下是否会被输出。
pub fn enabled(level Level) bool {
	return int(level) >= int(cur_level)
}

// format_line 拼装一条日志行，形如：`2026-08-16 17:58:25 [info] msg`。
pub fn format_line(level Level, msg string) string {
	level_name := match level {
		.debug { 'debug' }
		.info { 'info' }
		.warn { 'warn' }
		.error { 'error' }
	}
	return '${time.now().format_ss()} [${level_name}] ${msg}'
}

fn write_line(level Level, msg string) {
	if !enabled(level) {
		return
	}
	eprintln(format_line(level, msg))
}

// debug 输出 debug 级日志。
pub fn debug(msg string) {
	write_line(.debug, msg)
}

// info 输出 info 级日志。
pub fn info(msg string) {
	write_line(.info, msg)
}

// warn 输出 warn 级日志。
pub fn warn(msg string) {
	write_line(.warn, msg)
}

// error 输出 error 级日志。
pub fn error(msg string) {
	write_line(.error, msg)
}
