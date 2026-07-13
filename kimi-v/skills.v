// skills.v — SKILL.md loader (parity with kimi-code's skill parser).
//
// A skill is a markdown file with a YAML/TOML-ish frontmatter block and a
// body. The frontmatter carries `name`, `description`, and optional metadata
// (`type`, `when_to_use`, `arguments`, `disable_model_invocation`, ...). The
// body is the instruction text injected into the system prompt when the skill
// is activated (via the `Agent` model calling it, or the user's `/skill:NAME`
// slash command).
//
// Skills are discovered from two roots:
//   - project:  <cwd>/.kimi/skills/<name>/SKILL.md
//   - user:     <config-dir>/skills/<name>/SKILL.md
//
// The PARITY_PLAN locks the description language to YAML frontmatter (2026-
// 07-11), matching upstream + the Claude Code ecosystem, so we parse the
// frontmatter as YAML. V has no stdlib YAML, so we implement a tiny
// key: value / key: "quoted" frontmatter parser sufficient for the fields we
// care about (no nested structures beyond flat scalars and simple lists).
module main

import os

// SkillSource marks where a skill was found.
pub enum SkillSource {
	project
	user
}

// SkillDefinition is a fully-parsed skill.
pub struct SkillDefinition {
pub:
	name        string
	description string
	path        string // absolute path to SKILL.md
	dir         string // directory containing SKILL.md
	content     string // body markdown (instruction text)
	source      SkillSource
	when_to_use string
	arguments   []string // declared argument names (for $name substitution)
	type        string   // 'prompt' (default) | 'reference' | 'flow' ...
	disable_model_invocation bool
}

// SkillCatalog is the in-memory collection of discovered skills.
pub struct SkillCatalog {
pub mut:
	skills []SkillDefinition
}

pub fn (c SkillCatalog) get(name string) ?SkillDefinition {
	for s in c.skills {
		if s.name == name {
			return s
		}
	}
	return none
}

pub fn (c SkillCatalog) list() []SkillDefinition {
	return c.skills
}

// list_invokable returns skills the model may auto-invoke (when
// disable_model_invocation is false). Mirrors upstream semantics.
pub fn (c SkillCatalog) list_invokable() []SkillDefinition {
	mut out := []SkillDefinition{}
	for s in c.skills {
		if !s.disable_model_invocation {
			out << s
		}
	}
	return out
}

// discover_skills scans the project + user skill roots and returns a catalog.
// Errors reading individual skills are skipped (logged to stderr) so one bad
// skill doesn't break the whole run.
pub fn discover_skills(cwd string) SkillCatalog {
	mut catalog := SkillCatalog{ skills: []SkillDefinition{} }

	// User root.
	user_root := os.join_path(config_dir(), 'skills')
	scan_skill_root(mut catalog, user_root, .user)

	// Project root (relative to cwd).
	project_root := os.join_path(cwd, '.kimi', 'skills')
	scan_skill_root(mut catalog, project_root, .project)

	return catalog
}

fn scan_skill_root(mut catalog SkillCatalog, root string, source SkillSource) {
	if !os.is_dir(root) {
		return
	}
	entries := os.ls(root) or { return }
	for entry in entries {
		if entry.starts_with('.') {
			continue
		}
		skill_dir := os.join_path(root, entry)
		if !os.is_dir(skill_dir) {
			continue
		}
		skill_path := os.join_path(skill_dir, 'SKILL.md')
		if !os.exists(skill_path) {
			continue
		}
		def := parse_skill_file(skill_path, source) or {
			eprintln('[warn] failed to parse skill ${skill_path}: ${err.msg()}')
			continue
		}
		catalog.skills << def
	}
}

// parse_skill_file reads a SKILL.md and returns its definition.
pub fn parse_skill_file(path string, source SkillSource) !SkillDefinition {
	raw := os.read_file(path) or { return error('cannot read ${path}: ${err.msg()}') }
	return parse_skill_text(raw, path, source)
}

// parse_skill_text parses the in-memory text of a SKILL.md. The first line
// must be a `---` fence; we split out the YAML frontmatter, parse it, and the
// rest is the body.
pub fn parse_skill_text(text string, path string, source SkillSource) !SkillDefinition {
	lines := text.split('\n')
	if lines.len == 0 || lines[0].trim_space() != '---' {
		return error('missing frontmatter fence in ${path}')
	}
	// Find the closing fence (after line 0).
	mut close_idx := -1
	for i in 1 .. lines.len {
		if lines[i].trim_space() == '---' {
			close_idx = i
			break
		}
	}
	if close_idx == -1 {
		return error('missing closing frontmatter fence in ${path}')
	}
	fm_text := lines[1..close_idx].join('\n')
	body := lines[close_idx + 1..].join('\n').trim_space()

	fm := parse_frontmatter(fm_text)
	name := fm['name'] or { '' }
	description := fm['description'] or { '' }
	if name.len == 0 || description.len == 0 {
		return error('SKILL.md ${path} requires name and description in frontmatter')
	}

	typ := fm['type'] or { 'prompt' }
	when_to_use := fm['when_to_use'] or { '' }
	disable := fm['disable_model_invocation'] in ['true', '1', 'yes']
	args := parse_arguments(fm['arguments'] or { '' })

	dir := os.dir(path)
	return SkillDefinition{
		name:        name
		description: description
		path:        path
		dir:         dir
		content:     body
		source:      source
		when_to_use: when_to_use
		arguments:   args
		type:        typ
		disable_model_invocation: disable
	}
}

// parse_frontmatter parses a flat YAML-ish frontmatter block into a
// string→string map. Supports:
//   key: value
//   key: "quoted value"     (quotes stripped)
//   key: 'single-quoted'
// Lists (key: [a, b]) are kept as a single comma-joined string and handled
// by parse_arguments. Nested maps are NOT supported (skills don't need them).
fn parse_frontmatter(text string) map[string]string {
	mut out := map[string]string{}
	lines := text.split('\n')
	for raw in lines {
		line := raw.trim_space()
		if line.len == 0 || line.starts_with('#') {
			continue
		}
		// Find the first ': ' or trailing ':'.
		idx := line.index(':') or { continue }
		if idx <= 0 {
			continue
		}
		key := line[..idx].trim_space()
		mut val := line[idx + 1..].trim_space()
		if val.len == 0 {
			continue
		}
		// Strip surrounding quotes.
		if val.len >= 2 && (val[0] == `"` && val[val.len - 1] == `"`) {
			val = val[1..val.len - 1]
		} else if val.len >= 2 && (val[0] == `'` && val[val.len - 1] == `'`) {
			val = val[1..val.len - 1]
		}
		out[key] = val
	}
	return out
}

// parse_arguments turns a frontmatter `arguments` value into a list of names.
// Accepts either a quoted CSV ("a b c" or "a, b, c") or a bracket list
// "[foo, bar]"; purely numeric tokens are dropped (per upstream rule).
fn parse_arguments(raw string) []string {
	mut s := raw.trim_space()
	if s.len == 0 {
		return []
	}
	// Strip enclosing brackets if present.
	if s[0] == `[` && s[s.len - 1] == `]` {
		s = s[1..s.len - 1]
	}
	// Split on comma or whitespace.
	tokens := s.replace(',', ' ').split(' ')
	mut out := []string{}
	for tok in tokens {
		t := tok.trim_space()
		if t.len == 0 {
			continue
		}
		// Drop purely-numeric tokens (per upstream validity rule).
		mut is_numeric := true
		for ch in t {
			if !((ch >= `0` && ch <= `9`) || ch == `_`) {
				is_numeric = false
				break
			}
		}
		if !is_numeric {
			out << t
		}
	}
	return out
}

// expand_skill_parameters substitutes argument placeholders in a skill body.
// Supports:
//   $ARGUMENTS        → the raw args string
//   $ARGUMENTS[N]     → the N-th whitespace-split token
//   $1 $2 ...          → positional tokens
//   $name              → named argument (from the skill's declared arguments)
//   ${KIMI_SKILL_DIR}  → the skill directory
//   ${KIMI_SESSION_ID} → the current session id (best-effort; '' if unknown)
// Unmatched placeholders are left as-is (fail-soft) to avoid mangling text.
pub fn expand_skill_parameters(body string, raw_args string, skill_dir string, session_id string, arg_names []string) string {
	tokens := tokenize_args(raw_args)
	mut content := body

	// Positional $ARGUMENTS[N], $N (token-aware, boundary-safe so $1 does
	// not clobber $10, and $arg does not clobber $arguments).
	for i, tok in tokens {
		content = replace_token(content, 'ARGUMENTS[${i}]', tok)
		content = replace_token(content, '${i + 1}', tok)
	}
	// $ARGUMENTS and $arguments (case-insensitive built-ins) → raw args.
	content = replace_token(content, 'ARGUMENTS', raw_args)
	content = replace_token(content, 'arguments', raw_args)

	// Environment-style placeholders (fixed `${...}` literals — use a plain
	// replace since they cannot collide with other tokens).
	content = content.replace('\${KIMI_SKILL_DIR}', skill_dir)
	content = content.replace('\${KIMI_SESSION_ID}', session_id)

	// Named args ($name) — longest names first so `$foo` does not clobber
	// `$foobar`. Boundary-safe so `$arg` never touches `$arguments`.
	mut sorted_names := arg_names.clone()
	sorted_names.sort_with_compare(fn (a &string, b &string) int {
		if a.len > b.len { return -1 }
		if a.len < b.len { return 1 }
		return 0
	})
	for name in sorted_names {
		if content.contains('$' + name) {
			idx := arg_names.index(name)
			val := if idx >= 0 && idx < tokens.len { tokens[idx] } else { '' }
			content = replace_token(content, name, val)
		}
	}

	return content
}

// replace_token replaces occurrences of `$token` in `s` where the character
// immediately after the token is NOT an identifier character (letter/digit/_)
// or end-of-string. This prevents a short placeholder like `$arg` from
// partially matching a longer one like `$arguments`. It is a boundary-safe
// analogue of `string.replace` for `$`-prefixed tokens.
fn replace_token(s string, token string, val string) string {
	if token.len == 0 {
		return s
	}
	mut out := ''
	mut i := 0
	for i < s.len {
		if s[i] == 36 && has_prefix(s[i + 1..], token) {
			after := i + 1 + token.len
			if after >= s.len || !is_ident_char(s[after]) {
				out += val
				i = after
				continue
			}
		}
		out += s[i].ascii_str()
		i++
	}
	return out
}

// has_prefix reports whether `s` starts with `prefix` (no stdlib dependency).
fn has_prefix(s string, prefix string) bool {
	if prefix.len > s.len {
		return false
	}
	for j := 0; j < prefix.len; j++ {
		if s[j] != prefix[j] {
			return false
		}
	}
	return true
}

// is_ident_char reports whether `c` is a continuation character for a $name
// placeholder (so $arg does not match inside $arguments).
fn is_ident_char(c u8) bool {
	return (c >= `A` && c <= `Z`) || (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`)
		|| c == `_`
}

// tokenize_args splits a raw args string into tokens, honouring single/double
// quotes (so "two words" stays one token). Mirrors upstream tokenizeArgs.
fn tokenize_args(raw string) []string {
	mut out := []string{}
	mut current := ''
	mut quote := ` ` // 0 = none
	mut has_content := false
	mut in_quote := false
	for ch in raw {
		if in_quote {
			if ch == quote {
				in_quote = false
			} else {
				current += ch.ascii_str()
			}
			continue
		}
		if ch == `"` || ch == `'` {
			in_quote = true
			quote = ch
			has_content = true
			continue
		}
		if ch == ` ` || ch == `\t` || ch == `\n` || ch == `\r` {
			if has_content {
				out << current
				current = ''
				has_content = false
			}
			continue
		}
		current += ch.ascii_str()
		has_content = true
	}
	if has_content {
		out << current
	}
	return out
}
