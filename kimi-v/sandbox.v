// sandbox.v — confine file-write tools (write_file / edit_file) to the
// session working directory.
//
// Self-use, so we only enforce the simple invariant:
//
//	resolve(path) must equal or sit under abs(cwd)
//
// Where `resolve` is `os.abs_path` (joins cwd if relative, then normalizes
// `.` / `..` and redundant separators). Symlinks are NOT followed — we
// don't call realpath. For a personal dev box that's fine; a future
// hardening pass can add realpath-based checks if needed.
//
// We deliberately keep this minimal: a real "agent sandbox" would also
// cover bash (via a shell parser or syscall filter), but that's a much
// larger surface and out of scope for v0.2.

module main

import os

// resolve_within returns the normalized absolute form of `path` if it
// resolves to `root` or a descendant of `root` (an already-absolute,
// normalized directory). It rejects paths that escape `root` via `..` or
// by pointing elsewhere on the filesystem.
//
// On success the returned string is the path the caller should use (it
// may differ from the input — e.g. "foo/../bar" becomes "/abs/cwd/bar").
// On failure the error is a clear, user-readable string the model can
// surface in its tool result.
pub fn resolve_within(root string, path string) !string {
	if root.len == 0 {
		return error('sandbox: empty root')
	}
	if !os.is_abs_path(root) {
		return error('sandbox: root must be absolute: ${root}')
	}
	abs := os.abs_path(path)
	// abs_path calls norm_path internally, so `..`, `.`, and redundant
	// separators are already collapsed. Either the resolved path IS the
	// root, or it sits beneath root with a separator in between.
	if abs == root {
		return abs
	}
	sep := if root.ends_with('/') { '' } else { '/' }
	prefix := '${root}${sep}'
	if abs.starts_with(prefix) {
		return abs
	}
	return error('path "${path}" resolves outside sandbox (root=${root}, resolved=${abs})')
}
