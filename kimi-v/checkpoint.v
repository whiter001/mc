// checkpoint.v — file-modification checkpoints and /undo support (issue #9).
//
// WriteFileTool and EditFileTool snapshot the target file right before
// writing (via checkpoint_file). Snapshots live under
// <config-dir>/checkpoints/<session-id>/: a JSON manifest (a Checkpoint
// array) plus one <seq>.bak per pre-existing file. /undo pops the newest
// manifest entry and restores the backup (or removes a file the tool
// created). All loads are fail-open (same policy as cron_store.v) so a
// corrupt store never blocks a write or the session.
module main

import os
import time
import json2

// checkpoint_max_entries caps the per-session manifest; the oldest
// entries (and their backup files) are evicted beyond this.
pub const checkpoint_max_entries = 50

// Checkpoint records one pre-write snapshot of a file modified by a
// built-in tool.
pub struct Checkpoint {
pub:
	seq     int    // monotonic per session (also the backup file name)
	path    string // absolute path the tool wrote to
	backup  string // backup file path ('' when the target did not exist)
	existed bool   // whether `path` existed before the write
	tool    string // 'write_file' | 'edit_file'
	ts_ms   i64    // wall-clock time of the snapshot (unix ms)
}

// checkpoints_dir returns the per-session checkpoint directory.
pub fn checkpoints_dir(session_id string) string {
	return os.join_path(config_dir(), 'checkpoints', session_id)
}

// checkpoint_manifest_path returns the manifest file for one session.
fn checkpoint_manifest_path(session_id string) string {
	return os.join_path(checkpoints_dir(session_id), 'manifest.json')
}

// load_checkpoints reads the persisted manifest for a session. Missing
// file → empty list; unreadable/corrupt file → warning + empty list.
fn load_checkpoints(session_id string) []Checkpoint {
	path := checkpoint_manifest_path(session_id)
	if !os.exists(path) {
		return []Checkpoint{}
	}
	content := os.read_file(path) or {
		eprintln('[warn] checkpoint manifest read failed for ${path}: ${err.msg()}')
		return []Checkpoint{}
	}
	cps := json2.decode[[]Checkpoint](content) or {
		eprintln('[warn] checkpoint manifest corrupt for ${path}: ${err.msg()} (treating as empty)')
		return []Checkpoint{}
	}
	return cps
}

// save_checkpoints writes the session manifest, creating the checkpoint
// dir on first use.
fn save_checkpoints(session_id string, cps []Checkpoint) ! {
	ensure_dir(checkpoints_dir(session_id))!
	os.write_file(checkpoint_manifest_path(session_id), json2.encode(cps))!
}

// checkpoint_file snapshots `path` before a tool overwrites it. Called by
// WriteFileTool / EditFileTool after sandbox validation, right before the
// actual write. An existing file is copied to <seq>.bak; a not-yet-existing
// file only gets a manifest entry (undo removes it). Errors are warnings
// only — checkpointing must never block the write itself. Skipped silently
// when the agent carries no session id (tests / no-session contexts).
pub fn checkpoint_file(mut a Agent, path string, tool string) {
	if a.session_id.len == 0 {
		return
	}
	dir := checkpoints_dir(a.session_id)
	ensure_dir(dir) or {
		eprintln('[warn] checkpoint: cannot create ${dir}: ${err.msg()}')
		return
	}
	mut cps := load_checkpoints(a.session_id)
	seq := if cps.len > 0 { cps.last().seq + 1 } else { 1 }
	existed := os.exists(path)
	mut backup := ''
	if existed {
		backup = os.join_path(dir, '${seq}.bak')
		content := os.read_file(path) or {
			eprintln('[warn] checkpoint: cannot read ${path}: ${err.msg()}')
			return
		}
		os.write_file(backup, content) or {
			eprintln('[warn] checkpoint: cannot write ${backup}: ${err.msg()}')
			return
		}
	}
	cps << Checkpoint{
		seq:     seq
		path:    path
		backup:  backup
		existed: existed
		tool:    tool
		ts_ms:   time.now().unix_milli()
	}
	// Evict the oldest entries (and their backups) beyond the cap.
	for cps.len > checkpoint_max_entries {
		old := cps[0]
		if old.backup.len > 0 && os.exists(old.backup) {
			os.rm(old.backup) or {}
		}
		cps.delete(0)
	}
	save_checkpoints(a.session_id, cps) or {
		eprintln('[warn] checkpoint: manifest save failed: ${err.msg()}')
	}
}

// undo_last_checkpoint pops the newest manifest entry and reverts it: a
// pre-existing file is restored from its backup, a tool-created file is
// removed. The entry (and its backup) are dropped from the store. Returns
// a human-readable description for the TUI system block. On failure the
// on-disk manifest is left untouched so the user can retry.
pub fn undo_last_checkpoint(mut a Agent) !string {
	mut cps := load_checkpoints(a.session_id)
	if cps.len == 0 {
		return error('nothing to undo')
	}
	cp := cps.last()
	cps.delete(cps.len - 1)
	mut desc := ''
	if cp.existed {
		content := os.read_file(cp.backup) or {
			return error('backup missing for ${cp.path}: ${err.msg()}')
		}
		os.write_file(cp.path, content) or {
			return error('restore failed for ${cp.path}: ${err.msg()}')
		}
		os.rm(cp.backup) or {}
		desc = 'restored ${cp.path}'
	} else {
		if os.exists(cp.path) {
			os.rm(cp.path) or {
				return error('remove failed for ${cp.path}: ${err.msg()}')
			}
		}
		desc = 'removed ${cp.path} (created by ${cp.tool})'
	}
	save_checkpoints(a.session_id, cps) or {
		eprintln('[warn] checkpoint: manifest save failed after undo: ${err.msg()}')
	}
	return desc
}

// list_checkpoints returns the session's recorded checkpoints (oldest
// first). Missing/corrupt manifest → empty list.
pub fn list_checkpoints(a Agent) []Checkpoint {
	if a.session_id.len == 0 {
		return []Checkpoint{}
	}
	return load_checkpoints(a.session_id)
}

// format_checkpoint_list renders the checkpoint list shown by `/undo list`.
pub fn format_checkpoint_list(cps []Checkpoint) string {
	if cps.len == 0 {
		return 'no checkpoints recorded for this session'
	}
	mut lines := ['checkpoints (oldest first; /undo reverts the newest):']
	for cp in cps {
		ts := time.unix_milli(cp.ts_ms).utc_to_local().custom_format('MM-DD HH:mm:ss')
		action := if cp.existed { 'modified' } else { 'created ' }
		lines << '  #${cp.seq} ${ts}  ${cp.tool} ${action} ${cp.path}'
	}
	return lines.join('\n')
}
