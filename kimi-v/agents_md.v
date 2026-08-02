// agents_md.v — AGENTS.md instruction-file loading (parity with kimi-code).
//
// kimi-code layers markdown instruction files into the system prompt from
// four locations, in this order (user-level first, project root last):
//
//   1. <config-dir>/AGENTS.md    user-level Kimi instructions
//   2. ~/.agents/AGENTS.md       cross-tool shared instructions
//   3. <cwd>/.kimi/AGENTS.md     project Kimi-specific instructions
//   4. <cwd>/AGENTS.md           project-root instructions
//
// Only files that exist (and are non-empty) are included. Each is wrapped
// in its own section headed by its source path so the model can attribute
// instructions. The whole thing returns '' when nothing was found, so
// callers can append it unconditionally.
module main

import os

// load_agents_md collects AGENTS.md content from the four standard
// locations and returns the concatenated sections (each prefixed with
// '\n\n# AGENTS.md (<path>)\n\n'). Returns '' when no files exist.
fn load_agents_md(cwd string, cfg_dir string) string {
	paths := [
		os.join_path(cfg_dir, 'AGENTS.md'),
		os.join_path(os.home_dir(), '.agents', 'AGENTS.md'),
		os.join_path(cwd, '.kimi', 'AGENTS.md'),
		os.join_path(cwd, 'AGENTS.md'),
	]
	mut out := ''
	for path in paths {
		if !os.exists(path) {
			continue
		}
		content := os.read_file(path) or { continue }
		if content.trim_space().len == 0 {
			continue
		}
		out += '\n\n# AGENTS.md (${path})\n\n${content}'
	}
	return out
}
