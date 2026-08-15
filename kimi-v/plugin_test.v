// plugin_test.v — unit tests for local plugin loading (issue #13, option A).
//
// Fixtures live under $KIMI_CONFIG_DIR/plugins/<name>/. Each test points
// KIMI_CONFIG_DIR at a fresh temp dir so the host's real config is never
// touched. Tests in this file run sequentially (they mutate KIMI_CONFIG_DIR).
module main

import os

// plugin_fixture_root returns the isolated config dir used by these tests.
fn plugin_fixture_root() string {
	return os.join_path(os.temp_dir(), 'kimi-plugin-test')
}

// plugin_write materializes a plugin directory under
// <fixture>/plugins/<name> from a map of relative-path -> file-content.
// Any intermediate directories are created as needed.
fn plugin_write(name string, files map[string]string) string {
	root := os.join_path(plugin_fixture_root(), 'plugins', name)
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	for rel, content in files {
		p := os.join_path(root, rel)
		os.mkdir_all(os.dir(p)) or { panic(err) }
		os.write_file(p, content) or { panic(err) }
	}
	return root
}

// plugin_setup_env points KIMI_CONFIG_DIR at a clean temp dir and returns it.
fn plugin_setup_env() string {
	dir := plugin_fixture_root()
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	os.setenv('KIMI_CONFIG_DIR', dir, true)
	return dir
}

// plugin_teardown_env unsets KIMI_CONFIG_DIR and removes the fixture dir.
fn plugin_teardown_env() {
	os.setenv('KIMI_CONFIG_DIR', '', true)
	os.rmdir_all(plugin_fixture_root()) or {}
}

// ---------- manifest location --------------------------------------------

fn test_plugin_manifest_root_json() {
	plugin_setup_env()
	defer { plugin_teardown_env() }
	root := plugin_write('alpha', {
		'plugin.json':   '{"name":"alpha","version":"1.2.3","description":"demo","skills":["./skills"]}'
		'skills/foo/SKILL.md': '---\nname: foo\ndescription: bar\n---\nbody\n'
	})
	m := parse_plugin_manifest(root) or { panic(err) }
	assert m.name == 'alpha'
	assert m.version == '1.2.3'
	assert m.description == 'demo'
	assert m.root == os.abs_path(root)
	assert m.skills_dirs.len == 1
	assert m.skills_dirs[0] == os.join_path(os.abs_path(root), 'skills')
	assert !m.root_skill_fallback
}

fn test_plugin_manifest_kimi_plugin_dir() {
	plugin_setup_env()
	defer { plugin_teardown_env() }
	root := plugin_write('beta', {
		'.kimi-plugin/plugin.json': '{"name":"beta","skills":["./skills"]}'
		'skills/x/SKILL.md':        '---\nname: x\ndescription: y\n---\n'
	})
	m := parse_plugin_manifest(root) or { panic(err) }
	assert m.name == 'beta'
	assert m.skills_dirs.len == 1
	assert m.skills_dirs[0] == os.join_path(os.abs_path(root), 'skills')
}

fn test_plugin_manifest_root_wins_over_dir() {
	plugin_setup_env()
	defer { plugin_teardown_env() }
	// Both locations present: root plugin.json must win.
	root := plugin_write('gamma', {
		'plugin.json':            '{"name":"gamma-root","skills":["./skills"]}'
		'.kimi-plugin/plugin.json': '{"name":"gamma-dir","skills":["./skills"]}'
		'skills/x/SKILL.md':      '---\nname: x\ndescription: y\n---\n'
	})
	m := parse_plugin_manifest(root) or { panic(err) }
	assert m.name == 'gamma-root'
}

// ---------- name validation ----------------------------------------------

fn test_plugin_name_missing_errors() {
	plugin_setup_env()
	defer { plugin_teardown_env() }
	root := plugin_write('no-name', {
		'plugin.json': '{"version":"1.0"}'
	})
	parse_plugin_manifest(root) or { return }
	assert false, 'expected error for missing name'
}

fn test_plugin_name_invalid_errors() {
	plugin_setup_env()
	defer { plugin_teardown_env() }
	root := plugin_write('bad-name', {
		'plugin.json': '{"name":"Bad_Name!","skills":[]}'
	})
	parse_plugin_manifest(root) or { return }
	assert false, 'expected error for invalid name'
}

fn test_plugin_name_valid_ok() {
	plugin_setup_env()
	defer { plugin_teardown_env() }
	root := plugin_write('good1', {
		'plugin.json': '{"name":"good-plugin_1","skills":[]}'
	})
	m := parse_plugin_manifest(root) or { panic(err) }
	assert m.name == 'good-plugin_1'
}

fn test_plugin_name_empty_errors() {
	plugin_setup_env()
	defer { plugin_teardown_env() }
	root := plugin_write('empty-name', {
		'plugin.json': '{"name":"","skills":[]}'
	})
	parse_plugin_manifest(root) or { return }
	assert false, 'expected error for empty name'
}

// ---------- skills resolution --------------------------------------------

fn test_plugin_skills_explicit_list() {
	plugin_setup_env()
	defer { plugin_teardown_env() }
	root := plugin_write('skillslist', {
		'plugin.json':    '{"name":"skillslist","skills":["./a","./missing","./b"]}'
		'a/s/SKILL.md':   '---\nname: s\ndescription: d\n---\n'
		'b/t/SKILL.md':   '---\nname: t\ndescription: d\n---\n'
	})
	m := parse_plugin_manifest(root) or { panic(err) }
	abs := os.abs_path(root)
	assert m.skills_dirs.len == 2
	assert os.join_path(abs, 'a') in m.skills_dirs
	assert os.join_path(abs, 'b') in m.skills_dirs
	assert os.join_path(abs, 'missing') !in m.skills_dirs
	assert !m.root_skill_fallback
}

fn test_plugin_root_skill_fallback() {
	plugin_setup_env()
	defer { plugin_teardown_env() }
	root := plugin_write('rootskill', {
		'plugin.json': '{"name":"rootskill"}'
		'SKILL.md':     '---\nname: root\ndescription: d\n---\n'
	})
	m := parse_plugin_manifest(root) or { panic(err) }
	assert m.root_skill_fallback
	assert m.skills_dirs.len == 1
	assert m.skills_dirs[0] == os.abs_path(root)
}

fn test_plugin_skills_dir_fallback() {
	plugin_setup_env()
	defer { plugin_teardown_env() }
	root := plugin_write('skillsdir', {
		'plugin.json':        '{"name":"skillsdir"}'
		'skills/x/SKILL.md':  '---\nname: x\ndescription: d\n---\n'
	})
	m := parse_plugin_manifest(root) or { panic(err) }
	assert !m.root_skill_fallback
	assert m.skills_dirs.len == 1
	assert m.skills_dirs[0] == os.join_path(os.abs_path(root), 'skills')
}

fn test_plugin_skills_empty_array_no_fallback() {
	plugin_setup_env()
	defer { plugin_teardown_env() }
	// skills: [] is explicit (not absent), so no root/skills fallback applies.
	root := plugin_write('explicit-empty', {
		'plugin.json': '{"name":"explicit-empty","skills":[]}'
		'SKILL.md':     '---\nname: root\ndescription: d\n---\n'
	})
	m := parse_plugin_manifest(root) or { panic(err) }
	assert !m.root_skill_fallback
	assert m.skills_dirs.len == 0
}

fn test_plugin_skills_single_string() {
	plugin_setup_env()
	defer { plugin_teardown_env() }
	root := plugin_write('singlestr', {
		'plugin.json':  '{"name":"singlestr","skills":"./skills"}'
		'skills/x/SKILL.md': '---\nname: x\ndescription: d\n---\n'
	})
	m := parse_plugin_manifest(root) or { panic(err) }
	assert m.skills_dirs.len == 1
	assert m.skills_dirs[0] == os.join_path(os.abs_path(root), 'skills')
}

// ---------- discover_plugins resilience ----------------------------------

fn test_plugin_discover_skips_bad() {
	plugin_setup_env()
	defer { plugin_teardown_env() }
	// A clean plugin.
	plugin_write('good', {
		'plugin.json': '{"name":"good","skills":[]}'
	})
	// Empty directory: no manifest at all.
	plugin_write('emptydir', {})
	// Invalid JSON manifest.
	plugin_write('brokenjson', {
		'plugin.json': '{not json'
	})
	// Manifest present but illegal name.
	plugin_write('badname', {
		'plugin.json': '{"name":"BAD","skills":[]}'
	})
	plugins := discover_plugins()
	names := plugins.map(it.name)
	assert 'good' in names
	// Only the one valid plugin should survive.
	assert plugins.len == 1
}

fn test_plugin_discover_multiple() {
	plugin_setup_env()
	defer { plugin_teardown_env() }
	plugin_write('one', {
		'plugin.json': '{"name":"one","skills":[]}'
	})
	plugin_write('two', {
		'.kimi-plugin/plugin.json': '{"name":"two","skills":[]}'
	})
	plugins := discover_plugins()
	names := plugins.map(it.name)
	assert 'one' in names
	assert 'two' in names
	assert plugins.len == 2
}

// ---------- end-to-end injection into the skill catalog -------------------

fn test_plugin_skills_injected_into_catalog() {
	plugin_setup_env()
	defer { plugin_teardown_env() }
	root := plugin_write('inject', {
		'plugin.json': '{"name":"inject"}'
		'SKILL.md':     '---\nname: plugskill\ndescription: from plugin\n---\n'
	})
	// A cwd with no .kimi/skills so only the plugin skill should appear.
	catalog := discover_skills(os.temp_dir())
	got := catalog.get('plugskill') or {
		assert false, 'plugin skill was not injected into the catalog'
		return
	}
	assert got.source == .plugin
	assert got.dir == os.abs_path(root)
}
