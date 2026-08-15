// plugin.v — local plugin loading (issue #13, option A).
//
// A plugin is a directory under <config-dir>/plugins/<name>/ carrying a
// manifest. Two manifest locations are accepted, with the root-level
// `plugin.json` taking precedence:
//   - <plugin>/plugin.json
//   - <plugin>/.kimi-plugin/plugin.json
//
// Only the `skills` aspect of a plugin is consumed for now. Remote install,
// marketplace, `agents`, `systemPrompt`, `hooks`, and plugin slash commands
// are out of scope for this milestone.
//
// `name` is required and must match [a-z0-9][a-z0-9-_]*. The `skills` field
// is a list of directories resolved relative to the plugin root; a string is
// accepted as a single entry. When `skills` is not specified, the plugin
// root itself is a skill if it contains a SKILL.md (rootSkillFallback),
// otherwise a `skills/` directory under the root is used if present.
module main

import os
import json2

// PluginManifest is the parsed local form of a plugin manifest.
pub struct PluginManifest {
pub:
	name                string
	version             string
	description         string
	skills_dirs         []string // absolute paths of skill roots
	root_skill_fallback bool     // true when the plugin root itself is a skill
	root                string   // plugin directory (absolute)
}

// plugin_name_valid reports whether `name` matches [a-z0-9][a-z0-9-_]*.
fn plugin_name_valid(name string) bool {
	if name.len == 0 {
		return false
	}
	c0 := name[0]
	if !((c0 >= `a` && c0 <= `z`) || (c0 >= `0` && c0 <= `9`)) {
		return false
	}
	for i := 1; i < name.len; i++ {
		c := name[i]
		if !((c >= `a` && c <= `z`) || (c >= `0` && c <= `9`) || c == `-` || c == `_`) {
			return false
		}
	}
	return true
}

// parse_plugin_manifest reads and validates a plugin's manifest. The
// root-level plugin.json wins over .kimi-plugin/plugin.json when both exist.
// A missing/illegal `name` or an unparseable JSON file is a hard error;
// everything else degrades to warnings.
pub fn parse_plugin_manifest(plugin_root string) !PluginManifest {
	root := os.abs_path(plugin_root)
	root_json := os.join_path(root, 'plugin.json')
	dir_json := os.join_path(root, '.kimi-plugin', 'plugin.json')

	mut manifest_path := ''
	if os.is_file(root_json) {
		manifest_path = root_json
	} else if os.is_file(dir_json) {
		manifest_path = dir_json
	} else {
		return error('no plugin.json or .kimi-plugin/plugin.json in ${root}')
	}

	raw_text := os.read_file(manifest_path) or {
		return error('cannot read ${manifest_path}: ${err.msg()}')
	}
	decoded := json2.decode[json2.Any](raw_text) or {
		return error('failed to parse ${manifest_path}: ${err.msg()}')
	}
	if decoded !is map[string]json2.Any {
		return error('${manifest_path} must be a JSON object')
	}
	body := decoded as map[string]json2.Any

	// name is required and must match the plugin name pattern.
	name_any := body['name'] or { json2.Null{} }
	if name_any !is string {
		return error('plugin ${root}: "name" is required')
	}
	name := (name_any as string).trim_space()
	if !plugin_name_valid(name) {
		return error('plugin ${root}: "name" must match [a-z0-9][a-z0-9-_]* (got "${name}")')
	}

	ver := plugin_str_field(body, 'version')
	description := plugin_str_field(body, 'description')

	// skills field, when present.
	mut skills_raw := json2.Any(json2.Null{})
	mut has_skills := false
	if v := body['skills'] {
		skills_raw = v
		has_skills = true
	}
	skills_dirs, root_skill_fallback := plugin_resolve_skills(root, skills_raw, has_skills)

	return PluginManifest{
		name:                name
		version:             ver
		description:         description
		skills_dirs:         skills_dirs
		root_skill_fallback: root_skill_fallback
		root:                root
	}
}

// plugin_str_field reads a string field from the manifest object, trimming
// whitespace. Non-string values are treated as absent.
fn plugin_str_field(body map[string]json2.Any, key string) string {
	v := body[key] or { return '' }
	if v is string {
		return (v as string).trim_space()
	}
	return ''
}

// plugin_resolve_skills turns the raw `skills` manifest value into a list of
// absolute directory paths. When the field is absent, fallback rules apply:
// a SKILL.md at the plugin root makes the root itself a skill
// (root_skill_fallback), otherwise a `skills/` directory is used when it
// exists. Explicit entries are resolved relative to the plugin root;
// entries that do not name an existing directory are skipped with a warning.
fn plugin_resolve_skills(plugin_root string, raw json2.Any, has_skills bool) ([]string, bool) {
	if !has_skills {
		if os.is_file(os.join_path(plugin_root, 'SKILL.md')) {
			return [plugin_root], true
		}
		skills_dir := os.join_path(plugin_root, 'skills')
		if os.is_dir(skills_dir) {
			return [skills_dir], false
		}
		return []string{}, false
	}

	mut entries := []string{}
	match raw {
		string {
			entries << raw
		}
		[]json2.Any {
			for item in raw {
				if item is string {
					entries << (item as string)
				} else {
					eprintln('[warn] plugin ${plugin_root}: "skills" entry must be a string (got ${item.type_name()})')
				}
			}
		}
		else {
			eprintln('[warn] plugin ${plugin_root}: "skills" must be a string or string[] (got ${raw.type_name()})')
			return []string{}, false
		}
	}

	mut out := []string{}
	for e in entries {
		p := if e.starts_with('/') {
			os.abs_path(e)
		} else {
			os.abs_path(os.join_path(plugin_root, e))
		}
		if !os.is_dir(p) {
			eprintln('[warn] plugin ${plugin_root}: skills path "${e}" is not a directory; skipped')
			continue
		}
		out << p
	}
	return out, false
}

// discover_plugins scans <config-dir>/plugins/*/ and parses every plugin
// directory. A broken plugin is reported on stderr and skipped so one bad
// plugin cannot break the rest of the catalog.
pub fn discover_plugins() []PluginManifest {
	mut out := []PluginManifest{}
	plugins_root := os.join_path(config_dir(), 'plugins')
	if !os.is_dir(plugins_root) {
		return out
	}
	entries := os.ls(plugins_root) or { return out }
	for entry in entries {
		if entry.starts_with('.') {
			continue
		}
		plugin_root := os.join_path(plugins_root, entry)
		if !os.is_dir(plugin_root) {
			continue
		}
		m := parse_plugin_manifest(plugin_root) or {
			eprintln('[warn] skipping plugin ${entry}: ${err.msg()}')
			continue
		}
		out << m
	}
	return out
}
