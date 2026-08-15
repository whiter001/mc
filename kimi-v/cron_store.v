// cron_store.v — persistence for the per-session cron task table.
//
// Tasks live in <config-dir>/cron/<session-id>.json as a JSON array
// (json2). Loads are fail-open: a missing or corrupt file is a warning
// plus an empty table, so a bad store never blocks session startup.
module main

import os
import json2

// cron_dir returns the directory holding per-session cron tables.
pub fn cron_dir() string {
	return os.join_path(config_dir(), 'cron')
}

// cron_store_path returns the store file for one session.
pub fn cron_store_path(session_id string) string {
	return os.join_path(cron_dir(), '${session_id}.json')
}

// load_cron_tasks reads the persisted table for a session. Missing file
// → empty table; unreadable/corrupt file → warning + empty table.
pub fn load_cron_tasks(session_id string) []CronTask {
	path := cron_store_path(session_id)
	if !os.exists(path) {
		return []CronTask{}
	}
	content := os.read_file(path) or {
		eprintln('[warn] cron store read failed for ${path}: ${err.msg()}')
		return []CronTask{}
	}
	tasks := json2.decode[[]CronTask](content) or {
		eprintln('[warn] cron store corrupt for ${path}: ${err.msg()} (treating as empty)')
		return []CronTask{}
	}
	return tasks
}

// save_cron_tasks writes the session's table, creating the cron dir on
// first use. Callers decide how to handle the error (most ignore it —
// the in-memory table stays authoritative for the live session).
pub fn save_cron_tasks(session_id string, tasks []CronTask) ! {
	ensure_dir(cron_dir())!
	os.write_file(cron_store_path(session_id), json2.encode(tasks))!
}
