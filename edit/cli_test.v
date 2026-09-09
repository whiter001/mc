module main

fn test_parse_cli_args_basics() {
	opts := parse_cli_args(['a.txt', 'b.txt'], '/work') or { panic(err) }
	assert opts.action == .run
	assert opts.paths.len == 2
	assert opts.paths[0].path == '/work/a.txt'
	assert opts.paths[1].path == '/work/b.txt'
}

fn test_parse_cli_args_help_version_and_errors() {
	assert (parse_cli_args(['--help'], '/work') or { panic(err) }).action == .help
	assert (parse_cli_args(['--version'], '/work') or { panic(err) }).action == .version
	if _ := parse_cli_args(['--unknown'], '/work') {
		assert false
	}
	if _ := parse_cli_args(['-g'], '/work') {
		assert false
	}
}

fn test_parse_cli_args_double_dash_and_stdin() {
	opts := parse_cli_args(['--', '-name'], '/work') or { panic(err) }
	assert opts.paths.len == 1
	assert opts.paths[0].path == '/work/-name'

	stdin_opts := parse_cli_args(['a.txt', '-', 'ignored.txt'], '/work') or { panic(err) }
	assert stdin_opts.stdin_input
	assert stdin_opts.paths.len == 0
}

fn test_parse_filename_goto_matches_reference_cases() {
	path1, point1, ok1 := parse_filename_goto('file.txt:10')
	assert ok1
	assert path1 == 'file.txt'
	assert point1 == GotoPoint{ line: 10, column: 1 }

	path2, point2, ok2 := parse_filename_goto('file.txt:10:5')
	assert ok2
	assert path2 == 'file.txt'
	assert point2 == GotoPoint{ line: 10, column: 5 }

	path3, point3, ok3 := parse_filename_goto('file.txt:-1')
	assert ok3
	assert path3 == 'file.txt'
	assert point3 == GotoPoint{ line: -1, column: 1 }

	path4, point4, ok4 := parse_filename_goto('file.txt:10:-5')
	assert ok4
	assert path4 == 'file.txt:10'
	assert point4 == GotoPoint{ line: -5, column: 1 }

	path5, _, ok5 := parse_filename_goto(':123:456')
	assert !ok5
	assert path5 == ':123:456'
}

fn test_parse_prompt_goto() {
	assert parse_prompt_goto('3')! == GotoPoint{ line: 3, column: 1 }
	assert parse_prompt_goto('3:4')! == GotoPoint{ line: 3, column: 4 }
	for invalid in ['', '0', '-1', '1:0', 'a', '1:2:3'] {
		if _ := parse_prompt_goto(invalid) {
			assert false
		}
	}
}

fn test_goto_line_index_supports_negative_cli_lines() {
	assert goto_line_index(1, 9) == 0
	assert goto_line_index(99, 9) == 9
	assert goto_line_index(-1, 9) == 9
	assert goto_line_index(-2, 9) == 8
	assert goto_line_index(-99, 9) == 0
}
