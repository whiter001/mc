// internal/tools/v
// All built-in tools for P0. Each Tool is a small struct that implements
// the `Tool` interface. Schemas are inline JSON Schema strings —
// verbose, but explicit and easy to tweak without touching code.
module main

import os
import json
import regex
import time

// count_occurrences returns the number of non-overlapping occurrences of `sub` in `s`.
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

// ReadFileTool reads a file from disk and returns its UTF-8 contents.
pub struct ReadFileTool {
pub:
	cwd string
}

// name returns the tool identifier used in the registry and provider.
pub fn (t ReadFileTool) name() string {
	return 'read_file'
}

// description returns the human-readable description shown to the model.
pub fn (t ReadFileTool) description() string {
	return 'Read the contents of a file at the given absolute path. Returns the full file as a UTF-8 string. Use this before editing a file to confirm its current state.'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t ReadFileTool) parameters_schema() string {
	return '{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to the file to read"}},"required":["path"],"additionalProperties":false}'
}

// execute reads the requested file and returns its contents.
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

// WriteFileTool creates or overwrites a file, creating parent directories as needed.
pub struct WriteFileTool {
pub:
	cwd string
}

// name returns the tool identifier used in the registry and provider.
pub fn (t WriteFileTool) name() string {
	return 'write_file'
}

// description returns the human-readable description shown to the model.
pub fn (t WriteFileTool) description() string {
	return 'Create or overwrite a file at the given absolute path with the provided content. Parent directories are created if they do not exist.'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t WriteFileTool) parameters_schema() string {
	return '{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to the file to write"},"content":{"type":"string","description":"Full file content to write"}},"required":["path","content"],"additionalProperties":false}'
}

// execute resolves the path, creates parents, and writes the provided content.
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

// EditFileTool replaces a unique occurrence of old_text with new_text in a file.
pub struct EditFileTool {
pub:
	cwd string
}

// name returns the tool identifier used in the registry and provider.
pub fn (t EditFileTool) name() string {
	return 'edit_file'
}

// description returns the human-readable description shown to the model.
pub fn (t EditFileTool) description() string {
	return 'Replace `old_text` with `new_text` in the file at `path`. The match must be unique within the file (use surrounding context to disambiguate). Returns the number of replacements made (0 or 1).'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t EditFileTool) parameters_schema() string {
	return '{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to the file to edit"},"old_text":{"type":"string","description":"Exact text to find (must appear exactly once)"},"new_text":{"type":"string","description":"Replacement text"}},"required":["path","old_text","new_text"],"additionalProperties":false}'
}

// execute verifies the replacement text is unique and applies it.
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

// BashTool runs a shell command in the session working directory.
pub struct BashTool {
pub:
	cwd string
}

// name returns the tool identifier used in the registry and provider.
pub fn (t BashTool) name() string {
	return 'bash'
}

// description returns the human-readable description shown to the model.
pub fn (t BashTool) description() string {
	return 'Run a shell command (bash on Unix, cmd on Windows) and return its combined stdout + stderr. The command runs in the session working directory.'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t BashTool) parameters_schema() string {
	return '{"type":"object","properties":{"command":{"type":"string","description":"Shell command to execute"},"timeout_ms":{"type":"integer","description":"Optional timeout in milliseconds (default 60000, max 300000)"}},"required":["command"],"additionalProperties":false}'
}

const bash_default_timeout_ms = 60_000
const bash_max_timeout_ms = 300_000

// BashToolArgs is the typed-decode form of the bash tool arguments.
// Preferred over map[string]string because the map decode silently
// drops JSON numbers (timeout_ms would come back as '').
struct BashToolArgs {
	command    string @[json: command]
	timeout_ms int    @[json: timeout_ms]
}

// bash_timeout_ms resolves the effective timeout: the schema's
// `timeout_ms` when positive, otherwise the 60s default, capped at 5min
// (parity with kimi-code's bash timeout).
fn bash_timeout_ms(requested int) int {
	if requested <= 0 {
		return bash_default_timeout_ms
	}
	if requested > bash_max_timeout_ms {
		return bash_max_timeout_ms
	}
	return requested
}

// bash_shell returns the shell executable used to run bash commands.
fn bash_shell() string {
	$if windows {
		return 'cmd'
	} $else {
		return 'sh'
	}
}

// bash_shell_args wraps `command` in the shell invocation that reproduces
// the old `os.execute('cd "<cwd>" && <command>')` semantics.
fn bash_shell_args(cwd string, command string) []string {
	$if windows {
		return ['/c', 'cd /d "${cwd}" && ${command}']
	} $else {
		return ['-c', 'cd "${cwd}" && ${command}']
	}
}

// execute runs the command with a timeout and returns its combined
// stdout and stderr. os.execute has no timeout support, so we spawn the
// shell as an os.Process and poll is_alive() until it exits or the
// deadline passes. Stdout and stderr are merged into one pipe so the
// result matches the old os.execute combined-output format. The pipe is
// drained during polling so chatty commands can't deadlock on a full
// pipe buffer.
pub fn (t BashTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	// The schema declares timeout_ms as an integer, but some models send
	// it as a string. A typed-struct decode handles the number form;
	// fall back to the map[string]string decode used by the other tools
	// for the string form.
	mut command := ''
	mut timeout_ms := bash_default_timeout_ms
	if parsed := json.decode(BashToolArgs, args.raw) {
		command = parsed.command
		mut timeout_req := parsed.timeout_ms
		if timeout_req == 0 && args.raw.contains('"timeout_ms"') {
			// timeout_ms was present but didn't survive the typed decode
			// (e.g. the model sent it as a string, which coerces to 0).
			// Retry through the map decode, which keeps string values.
			if args_map := json.decode(map[string]string, args.raw) {
				timeout_req = (args_map['timeout_ms'] or { '' }).int()
			}
		}
		timeout_ms = bash_timeout_ms(timeout_req)
	} else {
		args_map := json.decode(map[string]string, args.raw) or {
			return ToolResult{
				content:  'invalid arguments: ${err.msg()}'
				is_error: true
			}
		}
		command = args_map['command'] or { '' }
		timeout_ms = bash_timeout_ms((args_map['timeout_ms'] or { '' }).int())
	}
	if command.len == 0 {
		return ToolResult{
			content:  'missing required argument: command'
			is_error: true
		}
	}

	cwd := if ctx.cwd.len > 0 { ctx.cwd } else { os.getwd() }

	mut p := os.new_process(bash_shell())
	p.set_args(bash_shell_args(cwd, command))
	p.set_redirect_stdio_merged()
	// Own process group so a timeout kills the whole tree (e.g. a `sleep`
	// child of the shell), not just the shell — otherwise stdout_slurp
	// below would block until the surviving grandchild closes the pipe.
	p.use_pgroup = true
	p.run()
	if p.err.len > 0 {
		return ToolResult{
			content:  'failed to start shell: ${p.err}'
			is_error: true
		}
	}

	deadline := time.now().add(time.millisecond * timeout_ms)
	mut out := ''
	mut timed_out := false
	for p.is_alive() {
		out += p.stdout_read()
		if time.now() > deadline {
			p.signal_pgkill()
			timed_out = true
			break
		}
		time.sleep(10 * time.millisecond)
	}
	// wait() is a no-op when is_alive() already reaped the child; on the
	// timeout path it blocks until the SIGKILL lands (prompt).
	p.wait()
	out += p.stdout_slurp()
	p.close()

	if timed_out {
		return ToolResult{
			content:  '${out}\n[command timed out after ${timeout_ms} ms and was killed; increase timeout_ms (max ${bash_max_timeout_ms}) and retry if it legitimately needs longer]'
			is_error: true
		}
	}
	if p.code != 0 {
		return ToolResult{
			content:  '${out}\n[exit ${p.code}]'
			is_error: true
		}
	}
	return ToolResult{
		content: out
	}
}

// =============================================================================
// glob
// =============================================================================

// GlobTool finds files matching a glob pattern under the session cwd.
pub struct GlobTool {
pub:
	cwd string
}

// name returns the tool identifier used in the registry and provider.
pub fn (t GlobTool) name() string {
	return 'glob'
}

// description returns the human-readable description shown to the model.
pub fn (t GlobTool) description() string {
	return 'Find files matching a glob pattern (relative to the session cwd or absolute). Returns a newline-separated list of paths.'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t GlobTool) parameters_schema() string {
	return '{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern, e.g. "**/*.v" or "/abs/path/**/*.md""}},"required":["pattern"],"additionalProperties":false}'
}

// execute resolves the pattern and returns matching file paths.
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

// GrepTool searches file contents for a regex pattern under the session cwd.
pub struct GrepTool {
pub:
	cwd string
}

// name returns the tool identifier used in the registry and provider.
pub fn (t GrepTool) name() string {
	return 'grep'
}

// description returns the human-readable description shown to the model.
pub fn (t GrepTool) description() string {
	return 'Search for a regex pattern in files under the session cwd. Returns matching lines as `path:lineno:text`.'
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t GrepTool) parameters_schema() string {
	return '{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression pattern to search for (PCRE-ish via ripgrep, or V regex fallback)"},"path":{"type":"string","description":"Directory to search in (defaults to session cwd)"},"include":{"type":"string","description":"Optional glob filter for file names, e.g. "*.v""},"i":{"type":"boolean","description":"Optional case-insensitive match (default false)"}},"required":["pattern"],"additionalProperties":false}'
}

// execute runs ripgrep if available, otherwise falls back to a built-in walker.
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

// walk_regex recursively searches files under `dir` using the compiled regex.
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

// search_dir_literal recursively searches files under `dir` for a literal substring.
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

// default_registry creates a registry with all built-in tools and registers any configured MCP servers.
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
	r.register(AgentSwarmTool{ agent: &a })
	r.register(TaskListTool{ agent: &a })
	r.register(SkillTool{ agent: &a })
	// External MCP servers (config-driven). Failures are logged, not fatal,
	// unless a server is explicitly marked required. Connections are stored
	// on the Agent so McpTool.execute can reach the live mcp.Client.
	register_mcp_tools(mut r, mut a.mcp_clients, mcp_servers)
	return r
}
