// agents_md_test.v — unit tests for AGENTS.md collection and splicing.
//
// Pure filesystem tests against a temp directory (no goroutines, no
// channels). HOME is overridden so the ~/.agents/AGENTS.md lookup is
// hermetic.
module main

import os
import time

// setup_agents_md_fixture builds a temp tree:
//
//	<tmp>/cfg/AGENTS.md           (user-level)
//	<tmp>/home/.agents/AGENTS.md  (cross-tool; HOME pointed at <tmp>/home)
//	<tmp>/proj/.kimi/AGENTS.md    (project kimi)
//	<tmp>/proj/AGENTS.md          (project root)
//
// Returns (tmp_root, cfg_dir, proj_dir). Caller must clean up.
fn setup_agents_md_fixture() (string, string, string) {
	tmp := os.join_path(os.temp_dir(), 'kimi-agents-md-test-${time.now().unix_milli()}')
	cfg_dir := os.join_path(tmp, 'cfg')
	home := os.join_path(tmp, 'home')
	proj := os.join_path(tmp, 'proj')
	os.mkdir_all(cfg_dir) or { panic(err) }
	os.mkdir_all(os.join_path(home, '.agents')) or { panic(err) }
	os.mkdir_all(os.join_path(proj, '.kimi')) or { panic(err) }
	os.setenv('HOME', home, true)
	return tmp, cfg_dir, proj
}

fn test_load_agents_md_all_four_in_order() {
	tmp, cfg_dir, proj := setup_agents_md_fixture()
	defer { os.rmdir_all(tmp) or {} }
	os.write_file(os.join_path(cfg_dir, 'AGENTS.md'), 'USER-RULES') or { panic(err) }
	os.write_file(os.join_path(os.join_path(tmp, 'home', '.agents'), 'AGENTS.md'), 'SHARED-RULES') or {
		panic(err)
	}
	os.write_file(os.join_path(proj, '.kimi', 'AGENTS.md'), 'KIMI-RULES') or { panic(err) }
	os.write_file(os.join_path(proj, 'AGENTS.md'), 'ROOT-RULES') or { panic(err) }

	got := load_agents_md(proj, cfg_dir)

	// Order: config-dir, ~/.agents, .kimi, project root.
	i_user := got.index('USER-RULES') or { -1 }
	i_shared := got.index('SHARED-RULES') or { -1 }
	i_kimi := got.index('KIMI-RULES') or { -1 }
	i_root := got.index('ROOT-RULES') or { -1 }
	assert i_user >= 0 && i_shared >= 0 && i_kimi >= 0 && i_root >= 0
	assert i_user < i_shared
	assert i_shared < i_kimi
	assert i_kimi < i_root

	// Each section is wrapped with its source path.
	assert got.contains('# AGENTS.md (${os.join_path(cfg_dir, 'AGENTS.md')})')
	assert got.contains('# AGENTS.md (${os.join_path(proj, 'AGENTS.md')})')
	assert got.starts_with('\n\n# AGENTS.md (')
}

fn test_load_agents_md_missing_files_skipped() {
	tmp, cfg_dir, proj := setup_agents_md_fixture()
	defer { os.rmdir_all(tmp) or {} }
	// Only the project-root file exists.
	os.write_file(os.join_path(proj, 'AGENTS.md'), 'ONLY-ROOT') or { panic(err) }

	got := load_agents_md(proj, cfg_dir)
	assert got == '\n\n# AGENTS.md (${os.join_path(proj, 'AGENTS.md')})\n\nONLY-ROOT'
}

fn test_load_agents_md_none_returns_empty() {
	tmp, cfg_dir, proj := setup_agents_md_fixture()
	defer { os.rmdir_all(tmp) or {} }
	assert load_agents_md(proj, cfg_dir) == ''
}

fn test_load_agents_md_empty_file_skipped() {
	tmp, cfg_dir, proj := setup_agents_md_fixture()
	defer { os.rmdir_all(tmp) or {} }
	os.write_file(os.join_path(proj, 'AGENTS.md'), '   \n  ') or { panic(err) }
	assert load_agents_md(proj, cfg_dir) == ''
}
