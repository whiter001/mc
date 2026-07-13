// internal/tools/v
// All built-in tools for P0. Each Tool is a small struct that implements
// the `Tool` interface. Schemas are inline JSON Schema strings —
// verbose, but explicit and easy to tweak without touching code.
module main

import os
import json
import regex

fn count_occurrences(s string, sub string) int {
	if sub.len == 0 {
		return 0
	}
	mut n := 0
	mut i := 0
	for {
		idx := s.index_after_(sub, i)
		if idx < 0 { break
		 }
		n++
		i = idx + sub.len
		if i > s.len { break
		 }
	}
	return n
}

// =============================================================================
// read_file
// =============================================================================

pub struct ReadFileTool {
pub:
	cwd string
}

pub fn (t ReadFileTool) name() string {
	return 'read_file'
}

pub fn (t ReadFileTool) description() string {
	return 'Read the contents of a file at the given absolute path. Returns the full file as a UTF-8 string. Use this before editing a file to confirm its current state.'
}

pub fn (t ReadFileTool) parameters_schema() string {
	return '{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to the file to read"}},"required":["path"],"additionalProperties":false}'
}

pub fn (t ReadFileTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	args_map := json.decode(map[string]string, args.raw) or {
		return ToolResult{
			content:  'invalid arguments: ${err.msg()}'
			is_error: true
		}
	}
	path := args_map['path'] or {
		return ToolResult{
			content:  'missing required argument: path'
			is_error: true
		}
	}
	if !os.exists(path) {
		return ToolResult{
			content:  'file not found: ${path}'
			is_error: true
		}
	}
	content := os.read_file(path) or {
		return ToolResult{
			content:  'read failed: ${err.msg()}'
			is_error: true
		}
	}
	return ToolResult{
		content: content
	}
}

// =============================================================================
// write_file
// =============================================================================

pub struct WriteFileTool {
pub:
	cwd string
}

pub fn (t WriteFileTool) name() string {
	return 'write_file'
}

pub fn (t WriteFileTool) description() string {
	return 'Create or overwrite a file at the given absolute path with the provided content. Parent directories are created if they do not exist.'
}

pub fn (t WriteFileTool) parameters_schema() string {
	return '{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to the file to write"},"content":{"type":"string","description":"Full file content to write"}},"required":["path","content"],"additionalProperties":false}'
}

pub fn (t WriteFileTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	args_map := json.decode(map[string]string, args.raw) or {
		return ToolResult{
			content:  'invalid arguments: ${err.msg()}'
			is_error: true
		}
	}
	path := args_map['path'] or {
		return ToolResult{
			content:  'missing required argument: path'
			is_error: true
		}
	}
	content := args_map['content'] or {
		return ToolResult{
			content:  'missing required argument: content'
			is_error: true
		}
	}

	// Sandbox: refuse paths that resolve outside the tool's cwd.
	// We use the tool's configured cwd, not ctx.cwd — the tool was
	// constructed with its own sandbox root, which is what main/TUI
	// passes in from the user's session directory.
	safe_path := resolve_within(t.cwd, path) or {
		return ToolResult{
			content:  err.msg()
			is_error: true
		}
	}

	// Create parent directories.
	parent := os.dir(safe_path)
	if parent.len > 0 && !os.is_dir(parent) {
		os.mkdir_all(parent) or {
			return ToolResult{
				content:  'mkdir failed for ${parent}: ${err.msg()}'
				is_error: true
			}
		}
	}

	os.write_file(safe_path, content) or {
		return ToolResult{
			content:  'write failed: ${err.msg()}'
			is_error: true
		}
	}
	return ToolResult{
		content: 'wrote ${content.len} bytes to ${safe_path}'
	}
}

// =============================================================================
// edit_file  (string replace with required-uniqueness check)
// =============================================================================

pub struct EditFileTool {
pub:
	cwd string
}

pub fn (t EditFileTool) name() string {
	return 'edit_file'
}

pub fn (t EditFileTool) description() string {
	return 'Replace `old_text` with `new_text` in the file at `path`. The match must be unique within the file (use surrounding context to disambiguate). Returns the number of replacements made (0 or 1).'
}

pub fn (t EditFileTool) parameters_schema() string {
	return '{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to the file to edit"},"old_text":{"type":"string","description":"Exact text to find (must appear exactly once)"},"new_text":{"type":"string","description":"Replacement text"}},"required":["path","old_text","new_text"],"additionalProperties":false}'
}

pub fn (t EditFileTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	args_map := json.decode(map[string]string, args.raw) or {
		return ToolResult{
			content:  'invalid arguments: ${err.msg()}'
			is_error: true
		}
	}
	path := args_map['path'] or {
		return ToolResult{
			content:  'missing required argument: path'
			is_error: true
		}
	}
	old_text := args_map['old_text'] or {
		return ToolResult{
			content:  'missing required argument: old_text'
			is_error: true
		}
	}
	new_text := args_map['new_text'] or {
		return ToolResult{
			content:  'missing required argument: new_text'
			is_error: true
		}
	}

	// Sandbox: refuse paths that resolve outside the tool's cwd.
	safe_path := resolve_within(t.cwd, path) or {
		return ToolResult{
			content:  err.msg()
			is_error: true
		}
	}

	content := os.read_file(safe_path) or {
		return ToolResult{
			content:  'read failed: ${err.msg()}'
			is_error: true
		}
	}

	occurrences := count_occurrences(content, old_text)
	if occurrences == 0 {
		return ToolResult{
			content:  'old_text not found in ${path}'
			is_error: true
		}
	}
	if occurrences > 1 {
		return ToolResult{
			content:  'old_text matches ${occurrences} places in ${path}; please add more context to make it unique'
			is_error: true
		}
	}

	new_content := content.replace(old_text, new_text)
	os.write_file(safe_path, new_content) or {
		return ToolResult{
			content:  'write failed: ${err.msg()}'
			is_error: true
		}
	}
	return ToolResult{
		content: 'edited ${safe_path} (1 replacement)'
	}
}

// =============================================================================
// bash
// =============================================================================

pub struct BashTool {
pub:
	cwd string
}

pub fn (t BashTool) name() string {
	return 'bash'
}

pub fn (t BashTool) description() string {
	return 'Run a shell command (bash on Unix, cmd on Windows) and return its combined stdout + stderr. The command runs in the session working directory.'
}

pub fn (t BashTool) parameters_schema() string {
	return '{"type":"object","properties":{"command":{"type":"string","description":"Shell command to execute"},"timeout_ms":{"type":"integer","description":"Optional timeout in milliseconds (default 30000)"}},"required":["command"],"additionalProperties":false}'
}

pub fn (t BashTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	args_map := json.decode(map[string]string, args.raw) or {
		return ToolResult{
			content:  'invalid arguments: ${err.msg()}'
			is_error: true
		}
	}
	command := args_map['command'] or {
		return ToolResult{
			content:  'missing required argument: command'
			is_error: true
		}
	}

	cwd := if ctx.cwd.len > 0 { ctx.cwd } else { os.getwd() }
	result := os.execute('cd "${cwd}" && ${command}')
	if result.exit_code != 0 {
		return ToolResult{
			content:  '${result.output}\n[exit ${result.exit_code}]'
			is_error: true
		}
	}
	return ToolResult{
		content: result.output
	}
}

// =============================================================================
// glob
// =============================================================================

pub struct GlobTool {
pub:
	cwd string
}

pub fn (t GlobTool) name() string {
	return 'glob'
}

pub fn (t GlobTool) description() string {
	return 'Find files matching a glob pattern (relative to the session cwd or absolute). Returns a newline-separated list of paths.'
}

pub fn (t GlobTool) parameters_schema() string {
	return '{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern, e.g. "**/*.v" or "/abs/path/**/*.md""}},"required":["pattern"],"additionalProperties":false}'
}

pub fn (t GlobTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	args_map := json.decode(map[string]string, args.raw) or {
		return ToolResult{
			content:  'invalid arguments: ${err.msg()}'
			is_error: true
		}
	}
	pattern := args_map['pattern'] or {
		return ToolResult{
			content:  'missing required argument: pattern'
			is_error: true
		}
	}

	mut matches := []string{}
	base := if pattern.starts_with('/') { '/' } else { ctx.cwd }

	walk(base, pattern, mut matches) or {
		return ToolResult{
			content:  'glob error: ${err.msg()}'
			is_error: true
		}
	}

	if matches.len == 0 {
		return ToolResult{
			content: '(no matches)'
		}
	}
	return ToolResult{
		content: matches.join('\n')
	}
}

// walk is a tiny recursive matcher: strips a leading "**/" prefix and walks
// the directory tree. Good enough for P0; we'll swap it for a real globber
// (or shell out to `find`) if performance matters.
fn walk(base string, pattern string, mut out []string) ! {
	// Strip leading **/
	pat := if pattern.starts_with('**/') { pattern[3..] } else { pattern }

	if !os.is_dir(base) {
		return
	}

	entries := os.ls(base) or { return error('ls failed: ${err.msg()}') }
	for entry in entries {
		if entry.starts_with('.') {
			continue
		}
		path := os.join_path(base, entry)
		if os.is_dir(path) {
			walk(path, pattern, mut out) or { continue }
		} else {
			// Match against the pattern's final segment after the last '/'.
			if match_glob(entry, pat.all_after_last('/')) {
				out << path
			}
		}
	}
}

// match_glob does a tiny glob match against a filename. Supports:
//   '*' matches any run of chars
//   '?' matches any single char
//   everything else is literal
// No regex engine needed — V's stdlib regex is heavyweight and we only need
// this one operation. Falls back to a substring match if the pattern has no
// wildcards.
fn match_glob(name string, pat string) bool {
	if pat == '*' {
		return true
	}
	mut ni := 0
	mut pi := 0
	for ni < name.len && pi < pat.len {
		c := pat[pi]
		if c == `*` {
			// Skip consecutive stars.
			for pi < pat.len && pat[pi] == `*` {
				pi++
			}
			if pi == pat.len {
				return true
			}
			// Try matching the rest of the pattern at each suffix.
			for ni <= name.len {
				if match_glob(name[ni..], pat[pi..]) {
					return true
				}
				ni++
			}
			return false
		} else if c == `?` {
			ni++
			pi++
		} else {
			if name[ni] != c {
				return false
			}
			ni++
			pi++
		}
	}
	// Skip trailing stars in pat.
	for pi < pat.len && pat[pi] == `*` {
		pi++
	}
	return ni == name.len && pi == pat.len
}

// =============================================================================
// grep
// =============================================================================

pub struct GrepTool {
pub:
	cwd string
}

pub fn (t GrepTool) name() string {
	return 'grep'
}

pub fn (t GrepTool) description() string {
	return 'Search for a regex pattern in files under the session cwd. Returns matching lines as `path:lineno:text`.'
}

pub fn (t GrepTool) parameters_schema() string {
	return '{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression pattern to search for (PCRE-ish via ripgrep, or V regex fallback)"},"path":{"type":"string","description":"Directory to search in (defaults to session cwd)"},"include":{"type":"string","description":"Optional glob filter for file names, e.g. "*.v""},"i":{"type":"boolean","description":"Optional case-insensitive match (default false)"}},"required":["pattern"],"additionalProperties":false}'
}

pub fn (t GrepTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	args_map := json.decode(map[string]string, args.raw) or {
		return ToolResult{
			content:  'invalid arguments: ${err.msg()}'
			is_error: true
		}
	}
	pattern := args_map['pattern'] or {
		return ToolResult{
			content:  'missing required argument: pattern'
			is_error: true
		}
	}
	search_path := args_map['path'] or { ctx.cwd }
	include := args_map['include'] or { '' }
	case_insensitive := args_map['i'] == 'true'

	mut hits := []string{}
	// First try ripgrep (rg), matching upstream kimi-code behaviour. If rg
	// is available on PATH we get fast, properly-regex, skip-VCS, hidden-
	// aware search for free. Otherwise fall back to a built-in V regex
	// walker so the tool still works on minimal systems.
	if rg_available() {
		run_rg(mut hits, search_path, pattern, include, case_insensitive) or {
			return ToolResult{
				content:  'grep (rg) error: ${err.msg()}'
				is_error: true
			}
		}
	} else if case_insensitive {
		// No rg and case-insensitive requested → literal CI fallback
		// (V's stdlib `regex` has no clean CI flag here).
		search_dir_literal(mut hits, search_path, pattern, include, true)
	} else {
		search_dir_regex(mut hits, search_path, pattern, include) or {
			return ToolResult{
				content:  'grep error: ${err.msg()}'
				is_error: true
			}
		}
	}

	if hits.len == 0 {
		return ToolResult{
			content: '(no matches)'
		}
	}
	return ToolResult{
		content: hits.join('\n')
	}
}

// rg_available caches whether `rg` exists on PATH so we don't spawn
// `which` on every grep call.
fn rg_available() bool {
	$if windows {
		res := os.execute('where rg')
		return res.exit_code == 0
	} $else {
		res := os.execute('command -v rg')
		return res.exit_code == 0
	}
}

// run_rg shells out to ripgrep. We pass -n (line numbers), --no-heading
// (one match per line, path:line:content), -H (always print path) and
// -I (don't skip binary). Optional --glob and -i flags filter the
// search. Output cap is enforced by the caller-side truncation in the
// TUI; here we rely on rg's own sane defaults.
fn run_rg(mut hits []string, dir string, pattern string, include string, ci bool) ! {
	mut cmd := 'rg --no-heading -H -n -I --color never'
	if ci {
		cmd += ' -i'
	}
	if include.len > 0 {
		cmd += ' --glob "${include}"'
	}
	// Quote the pattern to avoid shell interpretation of regex metachars.
	cmd += ' -- ' + shell_quote(pattern) + ' "${dir}"'
	res := os.execute(cmd)
	// rg exits 1 when there are no matches — that's not an error for us.
	if res.exit_code != 0 && res.exit_code != 1 {
		return error('rg exited ${res.exit_code}: ${res.output}')
	}
	for line in res.output.split_into_lines() {
		if line.len > 0 {
			hits << line.trim_space()
		}
	}
}

// shell_quote wraps a string in single quotes, escaping embedded single
// quotes, so it can be safely passed as a shell argument.
fn shell_quote(s string) string {
	mut out := "'"
	for ch in s {
		if ch == `'` {
			out += "'\\''"
		} else {
			out += ch.ascii_str()
		}
	}
	out += "'"
	return out
}

// search_dir_regex is the fallback when ripgrep isn't installed. It
// walks the tree and applies V's `regex` module line-by-line. Much
// slower and lacks rg's VCS/skip smarts, but correct and dependency-free.
fn search_dir_regex(mut hits []string, dir string, pattern string, include string) ! {
	if !os.is_dir(dir) {
		return
	}
	// Compile once for the whole tree. If the pattern isn't valid regex,
	// fall back to literal substring matching so the tool never hard-fails
	// on a simple query.
	re := regex.regex_opt(pattern) or {
		search_dir_literal(mut hits, dir, pattern, include, false)
		return
	}
	walk_regex(mut hits, dir, re, include)
}

fn walk_regex(mut hits []string, dir string, re regex.RE, include string) {
	if !os.is_dir(dir) {
		return
	}
	entries := os.ls(dir) or { return }
	for entry in entries {
		if entry.starts_with('.') {
			continue
		}
		path := os.join_path(dir, entry)
		if os.is_dir(path) {
			walk_regex(mut hits, path, re, include)
			continue
		}
		if include.len > 0 && !match_glob(entry, include) {
			continue
		}
		if entry.all_after_last('.').to_lower() in ['png', 'jpg', 'jpeg', 'gif', 'zip', 'tar',
			'gz', 'exe', 'dll', 'so', 'dylib', 'pdf'] {
			continue
		}
		content := os.read_file(path) or { continue }
		mut line_no := 1
		for line in content.split_into_lines() {
			if re.matches_string(line) {
				hits << '${path}:${line_no}:${line.trim_space()}'
			}
			line_no++
		}
	}
}

fn search_dir_literal(mut hits []string, dir string, pattern string, include string, ci bool) {
	if !os.is_dir(dir) {
		return
	}
	entries := os.ls(dir) or { return }
	mut needle := if ci { pattern.to_lower() } else { pattern }
	for entry in entries {
		if entry.starts_with('.') {
			continue
		}
		path := os.join_path(dir, entry)
		if os.is_dir(path) {
			search_dir_literal(mut hits, path, pattern, include, ci)
			continue
		}
		if include.len > 0 && !match_glob(entry, include) {
			continue
		}
		if entry.all_after_last('.').to_lower() in ['png', 'jpg', 'jpeg', 'gif', 'zip', 'tar',
			'gz', 'exe', 'dll', 'so', 'dylib', 'pdf'] {
			continue
		}
		content := os.read_file(path) or { continue }
		mut line_no := 1
		for line in content.split_into_lines() {
			hay := if ci { line.to_lower() } else { line }
			if hay.contains(needle) {
				hits << '${path}:${line_no}:${line.trim_space()}'
			}
			line_no++
		}
	}
}

// =============================================================================
// Registry helper
// =============================================================================

pub fn default_registry(mut a Agent, cwd string, mcp_servers []McpServerConfig) ToolRegistry {
	mut r := new_registry()
	r.register(ReadFileTool{ cwd: cwd })
	r.register(WriteFileTool{ cwd: cwd })
	r.register(EditFileTool{ cwd: cwd })
	r.register(BashTool{ cwd: cwd })
	r.register(GlobTool{ cwd: cwd })
	r.register(GrepTool{ cwd: cwd })
	r.register(WebFetchTool{})
	r.register(WebSearchTool{})
	r.register(TodoWriteTool{})
	r.register(TodoReadTool{})
	r.register(AskUserQuestionTool{})
	r.register(EnterPlanModeTool{ agent: &a })
	r.register(ExitPlanModeTool{ agent: &a })
	r.register(AgentTool{ agent: &a })
	r.register(SkillTool{ agent: &a })
	// External MCP servers (config-driven). Failures are logged, not fatal,
	// unless a server is explicitly marked required. Connections are stored
	// on the Agent so McpTool.execute can reach the live mcp.Client.
	register_mcp_tools(mut r, mut a.mcp_clients, mcp_servers)
	return r
}
