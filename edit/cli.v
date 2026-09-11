module main

import os

// edit_version is injected by build.sh from v.mod. The fallback keeps direct
// `v test` invocations usable for contributors.
const edit_version = $d('edit_version', 'dev')

enum CliAction {
	run
	help
	version
}

struct GotoPoint {
	line   int
	column int = 1
}

struct CliPath {
	path     string
	goto     GotoPoint
	has_goto bool
}

struct CliOptions {
mut:
	action      CliAction
	paths       []CliPath
	stdin_input bool
}

fn cli_help_text() string {
	return 'Usage: edit [OPTIONS] [FILE]...\n' +
		'Options:\n' +
		'    -g, --goto <FILE:LINE[:CHARACTER]>    Open a file at the specified line and character position\n' +
		'    -h, --help                            Print this help message\n' +
		'    -v, --version                         Print the version number\n\n'
}

fn cli_version_text() string {
	return 'edit version ${edit_version}\n'
}

// parse_cli_args parses arguments without touching the terminal. Paths are
// made absolute here so every later entry point uses the same identity rule.
fn parse_cli_args(args []string, cwd string) !CliOptions {
	mut result := CliOptions{}
	mut parse_options := true
	mut goto_next := false

	for arg in args {
		if parse_options {
			match arg {
				'--' {
					if goto_next {
						return error('missing value for -g/--goto')
					}
					parse_options = false
					continue
				}
				'-' {
					result.paths.clear()
					result.stdin_input = true
					break
				}
				'-g', '--goto' {
					if goto_next {
						return error('missing value for -g/--goto')
					}
					goto_next = true
					continue
				}
				'-h', '--help' {
					result.action = .help
					return result
				}
				'-v', '--version' {
					result.action = .version
					return result
				}
				else {
					if arg.starts_with('-') {
						return error('unknown option: ${arg}')
					}
				}
			}
		}

		mut path := arg
		mut point := GotoPoint{}
		mut has_goto := false
		if goto_next {
			path, point, has_goto = parse_filename_goto(arg)
			goto_next = false
		}
		result.paths << CliPath{
			path:     normalize_document_path(path, cwd)
			goto:     point
			has_goto: has_goto
		}
	}

	if goto_next {
		return error('missing value for -g/--goto')
	}
	return result
}

fn normalize_document_path(path string, cwd string) string {
	if os.is_abs_path(path) {
		return os.norm_path(path)
	}
	return os.norm_path(os.join_path(cwd, path))
}

// parse_filename_goto mirrors the Rust parser: scan numeric suffixes from the
// right so colons remain valid inside filenames. Negative values are accepted
// only when the final suffix is interpreted as a line number.
fn parse_filename_goto(input string) (string, GotoPoint, bool) {
	last_colon := input.last_index(':') or { return input, GotoPoint{}, false }
	if last_colon <= 0 {
		return input, GotoPoint{}, false
	}
	// Reject degenerate paths like ":123:456" or ":123": the segment before
	// the first colon must be non-empty, otherwise the whole input is the
	// path (matches how Rust's reference parser bails on empty path parts).
	if input.starts_with(':') {
		return input, GotoPoint{}, false
	}
	last := parse_goto_number(input[last_colon + 1..]) or {
		return input, GotoPoint{}, false
	}

	mut path_end := last_colon
	mut point := GotoPoint{
		line:   last
		column: 1
	}
	if last >= 0 {
		prefix := input[..last_colon]
		if first_colon := prefix.last_index(':') {
			if first_colon > 0 {
				if first := parse_goto_number(input[first_colon + 1..last_colon]) {
					path_end = first_colon
					point = GotoPoint{
						line:   first
						column: last
					}
				}
			}
		}
	}
	return input[..path_end], point, true
}

fn parse_goto_number(text string) ?int {
	if text == '' {
		return none
	}
	negative := text[0] == `-`
	digits := if negative { text[1..] } else { text }
	if digits == '' {
		return none
	}
	mut value := i64(0)
	for ch in digits.bytes() {
		if ch < `0` || ch > `9` {
			return none
		}
		value = value * 10 + i64(ch - `0`)
		if value > i64(coord_type_max) {
			return none
		}
	}
	return if negative { -int(value) } else { int(value) }
}

// parse_prompt_goto accepts the interactive 1-based LINE[:COLUMN] form.
fn parse_prompt_goto(text string) !GotoPoint {
	parts := text.split(':')
	if parts.len < 1 || parts.len > 2 {
		return error('expected line[:column]')
	}
	line := parse_goto_number(parts[0]) or { return error('invalid line') }
	if line < 1 {
		return error('line must be positive')
	}
	mut column := 1
	if parts.len == 2 {
		column = parse_goto_number(parts[1]) or { return error('invalid column') }
		if column < 1 {
			return error('column must be positive')
		}
	}
	return GotoPoint{
		line:   line
		column: column
	}
}

// goto_line_index converts the CLI's 1-based line coordinate to the internal
// 0-based line index. Rust permits negative lines to count backwards from the
// end of the document (-1 is the last line).
fn goto_line_index(line int, last_line CoordType) CoordType {
	if line < 0 {
		return coord_max(last_line + CoordType(line) + 1, CoordType(0))
	}
	return coord_min(coord_max(CoordType(line - 1), CoordType(0)), last_line)
}
