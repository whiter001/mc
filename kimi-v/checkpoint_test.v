// checkpoint_test.v — unit tests for the checkpoint/undo system:
// snapshot + undo roundtrip, undoing a tool-created file, the 50-entry
// eviction cap, tool-level hooking (including the no-agent none skip),
// and the empty-manifest undo error. Tests use an isolated
// KIMI_CONFIG_DIR and run sequentially (env mutation).
module main

import os

// CheckpointFakeProvider satisfies the Provider interface for these tests;
// chat is never called (checkpointing never talks to the model). Each
// _test.v file is compiled standalone, so this cannot be shared with
// cron_test.v's equivalent.
struct CheckpointFakeProvider {
	name     string = 'fake'
	model    string = 'fake-model'
	api_base string = 'http://fake'
	api_key  string = 'fake-key'
}

fn (p CheckpointFakeProvider) chat(req ChatRequest, out chan ChatEvent, cancel_ch chan int) ! {
	return error('not implemented')
}

// checkpoint_test_dir returns a unique scratch config dir for one test.
fn checkpoint_test_dir(suffix string) string {
	return os.join_path(os.temp_dir(), 'kimi-checkpoint-test-' + suffix)
}

// new_checkpoint_test_agent builds an Agent whose session id keys the
// checkpoint store (the provider is never called).
fn new_checkpoint_test_agent(session_id string) Agent {
	mut a := new_agent(CheckpointFakeProvider{}, '')
	a.session_id = session_id
	return a
}

fn test_checkpoint_roundtrip_restores_original() {
	dir := checkpoint_test_dir('roundtrip')
	os.setenv('KIMI_CONFIG_DIR', dir, true)
	os.mkdir_all(dir)!
	defer {
		os.setenv('KIMI_CONFIG_DIR', '', true)
		os.rmdir_all(dir) or {}
	}
	mut a := new_checkpoint_test_agent('sess-rt')
	target := os.join_path(dir, 'target.txt')
	os.write_file(target, 'original')!
	checkpoint_file(mut a, target, 'write_file')
	// The tool would now overwrite the file.
	os.write_file(target, 'modified')!
	cps := list_checkpoints(a)
	assert cps.len == 1
	assert cps[0].existed
	assert cps[0].path == target
	assert cps[0].tool == 'write_file'
	assert cps[0].seq == 1
	assert os.exists(cps[0].backup)
	desc := undo_last_checkpoint(mut a)!
	assert desc == 'restored ${target}'
	assert os.read_file(target)! == 'original'
	// The popped entry and its backup are gone from the store.
	assert list_checkpoints(a).len == 0
	assert !os.exists(os.join_path(checkpoints_dir('sess-rt'), '1.bak'))
}

fn test_checkpoint_undo_removes_created_file() {
	dir := checkpoint_test_dir('created')
	os.setenv('KIMI_CONFIG_DIR', dir, true)
	os.mkdir_all(dir)!
	defer {
		os.setenv('KIMI_CONFIG_DIR', '', true)
		os.rmdir_all(dir) or {}
	}
	mut a := new_checkpoint_test_agent('sess-new')
	target := os.join_path(dir, 'fresh.txt')
	// Checkpoint a not-yet-existing file: no backup, existed=false.
	checkpoint_file(mut a, target, 'write_file')
	cps := list_checkpoints(a)
	assert cps.len == 1
	assert !cps[0].existed
	assert cps[0].backup == ''
	// The tool then creates the file; undo must remove it.
	os.write_file(target, 'brand new')!
	desc := undo_last_checkpoint(mut a)!
	assert desc == 'removed ${target} (created by write_file)'
	assert !os.exists(target)
	assert list_checkpoints(a).len == 0
}

fn test_checkpoint_cap_evicts_oldest() {
	dir := checkpoint_test_dir('cap')
	os.setenv('KIMI_CONFIG_DIR', dir, true)
	os.mkdir_all(dir)!
	defer {
		os.setenv('KIMI_CONFIG_DIR', '', true)
		os.rmdir_all(dir) or {}
	}
	mut a := new_checkpoint_test_agent('sess-cap')
	target := os.join_path(dir, 'capped.txt')
	os.write_file(target, 'v0')!
	// 1 + checkpoint_max_entries snapshots → seq 1 (with its backup)
	// must be evicted.
	checkpoint_file(mut a, target, 'write_file')
	first_backup := list_checkpoints(a)[0].backup
	assert os.exists(first_backup)
	for i in 0 .. checkpoint_max_entries {
		os.write_file(target, 'v${i + 1}')!
		checkpoint_file(mut a, target, 'edit_file')
	}
	cps := list_checkpoints(a)
	assert cps.len == checkpoint_max_entries
	assert cps[0].seq == 2
	assert !os.exists(first_backup)
	// The newest entry is still undoable after eviction.
	os.write_file(target, 'broken')!
	undo_last_checkpoint(mut a)!
	assert os.read_file(target)! == 'v${checkpoint_max_entries}'
}

fn test_checkpoint_empty_manifest_undo_errors() {
	dir := checkpoint_test_dir('empty')
	os.setenv('KIMI_CONFIG_DIR', dir, true)
	os.mkdir_all(dir)!
	defer {
		os.setenv('KIMI_CONFIG_DIR', '', true)
		os.rmdir_all(dir) or {}
	}
	mut a := new_checkpoint_test_agent('sess-empty')
	undo_last_checkpoint(mut a) or {
		assert err.msg() == 'nothing to undo'
		return
	}
	assert false, 'expected a nothing-to-undo error'
}

fn test_write_file_tool_skips_checkpoint_without_agent() {
	// ctx.agent is none (tests / no-session contexts): the write still
	// succeeds and no checkpoint store is created.
	dir := checkpoint_test_dir('noagent')
	os.setenv('KIMI_CONFIG_DIR', dir, true)
	os.mkdir_all(dir)!
	defer {
		os.setenv('KIMI_CONFIG_DIR', '', true)
		os.rmdir_all(dir) or {}
	}
	tool := WriteFileTool{
		cwd: dir
	}
	target := os.join_path(dir, 'out.txt')
	res := tool.execute(ToolArgs{ raw: '{"path":"${target}","content":"hi"}' }, ToolContext{
		cwd: dir
	})!
	assert !res.is_error
	assert os.read_file(target)! == 'hi'
	assert !os.exists(os.join_path(config_dir(), 'checkpoints'))
}

fn test_edit_file_tool_records_checkpoint_and_undo() {
	dir := checkpoint_test_dir('toolhook')
	os.setenv('KIMI_CONFIG_DIR', dir, true)
	os.mkdir_all(dir)!
	defer {
		os.setenv('KIMI_CONFIG_DIR', '', true)
		os.rmdir_all(dir) or {}
	}
	mut a := new_checkpoint_test_agent('sess-hook')
	target := os.join_path(dir, 'edit.txt')
	os.write_file(target, 'hello world')!
	tool := EditFileTool{
		cwd: dir
	}
	res := tool.execute(ToolArgs{ raw: '{"path":"${target}","old_text":"world","new_text":"kimi"}' },
		ToolContext{
		cwd:   dir
		agent: &a
	})!
	assert !res.is_error
	assert os.read_file(target)! == 'hello kimi'
	cps := list_checkpoints(a)
	assert cps.len == 1
	assert cps[0].tool == 'edit_file'
	assert cps[0].existed
	undo_last_checkpoint(mut a)!
	assert os.read_file(target)! == 'hello world'
}
