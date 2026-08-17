module log

// 测试日志级别过滤与行格式。输出本身走 stderr（eprintln），
// 这里通过 enabled() 与 format_line() 覆盖核心行为。

fn test_default_level_is_info() {
	assert get_level() == Level.info
	assert enabled(.debug) == false
	assert enabled(.info) == true
	assert enabled(.warn) == true
	assert enabled(.error) == true
}

fn test_set_level_filters() {
	set_level(Level.debug)
	assert enabled(.debug) == true

	set_level(Level.warn)
	assert enabled(.debug) == false
	assert enabled(.info) == false
	assert enabled(.warn) == true
	assert enabled(.error) == true

	set_level(Level.error)
	assert enabled(.error) == true

	// 恢复默认，避免影响其它测试
	set_level(Level.info)
}

fn test_format_line() {
	line := format_line(Level.info, 'hello log')
	assert line.ends_with('[info] hello log')
	assert line.starts_with('20') // 时间戳年份开头

	line_warn := format_line(Level.warn, 'careful')
	assert line_warn.contains('[warn] careful')
}
