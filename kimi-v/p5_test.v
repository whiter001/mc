module main

import os

// ───────────────────────── Subagent profiles ─────────────────────────

fn test_default_profiles_present() {
	profiles := default_profiles()
	assert 'coder' in profiles
	assert 'explore' in profiles
	assert 'plan' in profiles
	assert profiles['coder'].tools.len > 0
	assert profiles['explore'].tools.len > 0
	assert profiles['plan'].tools.len > 0
}

fn test_profile_tool_allowlists() {
	profiles := default_profiles()
	// plan + explore must NOT carry file-writing tools.
	for name in ['explore', 'plan'] {
		p := profiles[name]
		assert !(name in p.tools)
		assert !('write_file' in p.tools)
		assert !('edit_file' in p.tools)
	}
	// coder may write/edit.
	c := profiles['coder']
	assert 'write_file' in c.tools
	assert 'edit_file' in c.tools
	assert 'bash' in c.tools
}

fn test_profile_carry_system_prompt() {
	profiles := default_profiles()
	for _, p in profiles {
		assert p.system.contains('subagent')
		assert p.description.len > 0
		assert p.when_to_use.len > 0
	}
}

// ───────────────────────── Hook engine ─────────────────────────

fn test_hook_event_from_name_roundtrip() {
	assert hook_event_from_name('PreToolUse') or { HookEventType.notification } == .pre_tool_use
	assert hook_event_from_name('PostToolUse') or { HookEventType.notification } == .post_tool_use
	assert hook_event_from_name('Stop') or { HookEventType.notification } == .stop
	assert hook_event_from_name('SessionStart') or { HookEventType.notification } == .session_start
	assert hook_event_from_name('SubagentStart') or { HookEventType.notification } == .subagent_start
	assert hook_event_from_name('PreCompact') or { HookEventType.notification } == .pre_compact
	// Unknown event resolves to none.
	assert hook_event_from_name('Nope') == none
}

fn test_is_blockable_event() {
	assert is_blockable_event(.pre_tool_use)
	assert is_blockable_event(.stop)
	assert is_blockable_event(.user_prompt_submit)
	assert !is_blockable_event(.post_tool_use)
	assert !is_blockable_event(.notification)
	assert !is_blockable_event(.subagent_start)
}

fn test_hook_engine_add_and_summary() {
	mut e := new_hook_engine(os.getwd(), 'sess-1')
	assert !e.has_hooks()
	e.add(HookDef{ event: .pre_tool_use, command: 'echo hi' })
	e.add(HookDef{ event: .pre_tool_use, command: 'echo bye' })
	e.add(HookDef{ event: .stop, command: 'echo done' })
	assert e.has_hooks()
	assert e.summary()['PreToolUse'] == 2
	assert e.summary()['Stop'] == 1
}

fn test_result_from_exit_code() {
	// exit 0 → allow
	r0 := result_from_exit_code(0, 'ok', '')
	assert r0.action == 'allow'
	// exit 2 → block (with stderr as message)
	r2 := result_from_exit_code(2, '', 'denied')
	assert r2.action == 'block'
	assert r2.message == 'denied'
	// exit 1 → fail-open (allow). stderr is preserved on the result.
	r1 := result_from_exit_code(1, '', 'boom')
	assert r1.action == 'allow'
	assert r1.stderr == 'boom'
}

fn test_parse_hook_json_deny() {
	// A hook that returns a structured permissionDecision deny.
	stdout := '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"nope"}}'
	r := parse_hook_json(stdout)
	assert r.action == 'block'
	assert r.reason == 'nope'
	assert r.structured_output
}

fn test_parse_hook_json_allow() {
	// Empty / non-blocking stdout → allow.
	assert parse_hook_json('').action == 'allow'
	assert parse_hook_json('just some log line').action == 'allow'
}

fn test_hook_matches_regex() {
	// signature: hook_matches(pattern, value)
	assert hook_matches('read_.*', 'read_file')
	assert hook_matches('write_file', 'write_file')
	assert !hook_matches('write_.*', 'read_file')
	// Empty matcher matches everything (hook applies to all targets).
	assert hook_matches('', 'read_file')
}

fn test_camel_to_snake() {
	assert camel_to_snake('sessionId') == 'session_id'
	assert camel_to_snake('hookEventName') == 'hook_event_name'
	assert camel_to_snake('cwd') == 'cwd'
}

// ───────────────────────── Skills ─────────────────────────

fn test_parse_skill_text_basic() {
	md := '---
name: demo
description: A demo skill
type: prompt
when_to_use: when demoing
arguments: "foo bar"
---
# Demo

Do the thing with $foo and $ARGUMENTS.
'
	def := parse_skill_text(md, '/tmp/SKILL.md', .project) or { panic('parse failed') }
	assert def.name == 'demo'
	assert def.description == 'A demo skill'
	assert def.type == 'prompt'
	assert def.when_to_use == 'when demoing'
	assert def.arguments == ['foo', 'bar']
	assert def.content.contains('$foo')
}

fn test_parse_skill_text_missing_fence() {
	// No frontmatter fence → error (parse returns a Result we reject).
	parse_skill_text('just text', '/tmp/x.md', .project) or { return }
	assert false // should have errored above, so we never reach here
}

fn test_expand_skill_parameters() {
	body := 'Name=$name, positional=$1, args=$ARGUMENTS, dir=\${KIMI_SKILL_DIR}, sid=\${KIMI_SESSION_ID}'
	out := expand_skill_parameters(body, 'first second', '/skills/demo', 'sess-9', ['name'])
	os.write_file('/tmp/rt.txt', 'rt=[${replace_token('Name=$name', 'name', 'first')}]\n') or {}
	assert out.contains('Name=first')
	assert out.contains('positional=first')
	assert out.contains('args=first second')
	assert out.contains('dir=/skills/demo')
	assert out.contains('sid=sess-9')
}

fn test_expand_skill_named_avoid_arguments_collision() {
	// Longest-name-first replacement must not turn $arg into part of $arguments.
	body := 'arg=$arg arguments=$arguments'
	out := expand_skill_parameters(body, 'VAL rest', '/d', 's', ['arg'])
	assert out.contains('arg=VAL')
	assert out.contains('arguments=VAL rest')
	assert !out.contains('arguments=VALrest')
}

fn test_discover_skills_finds_project_skill() {
	// Build a temp project root with one skill.
	tmp := os.join_path(os.temp_dir(), 'kimi-skill-test-${time_now_ms()}')
	skill_dir := os.join_path(tmp, '.kimi', 'skills', 'myskill')
	os.mkdir_all(skill_dir) or { panic('mkdir') }
	md := '---\nname: myskill\ndescription: test\n---\n# My Skill\nbody text\n'
	os.write_file(os.join_path(skill_dir, 'SKILL.md'), md) or { panic('write') }
	defer {
		os.rmdir_all(tmp) or {}
	}

	cat := discover_skills(tmp)
	assert cat.get('myskill') != none
	got := cat.get('myskill') or { panic('') }
	assert got.source == .project
	assert got.content.contains('body text')
}

fn test_skill_catalog_list_invokable() {
	mut c := SkillCatalog{ skills: []SkillDefinition{} }
	c.skills << SkillDefinition{ name: 'a', disable_model_invocation: false }
	c.skills << SkillDefinition{ name: 'b', disable_model_invocation: true }
	assert c.list_invokable().len == 1
	assert c.get('a') != none
	assert c.get('missing') == none
}

// time_now_ms is a tiny helper (avoids importing time just for a seed).
fn time_now_ms() string {
	return '${os.getpid()}'
}
