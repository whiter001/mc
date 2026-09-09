module main

import os
import json2

const settings_filename = 'settings.json'

// Returns absolute path of user-level settings.json, or '' if HOME unset.
fn settings_path() string {
    dir := settings_config_dir()
    if dir == '' { return '' }
    return os.join_path(dir, settings_filename)
}

// Returns the absolute path of the directory that holds settings.json.
// Does NOT create the directory on disk.
fn settings_config_dir() string {
    home := os.getenv('HOME')
    if home == '' { return '' }
    $if macos {
        return os.join_path(home, 'Library', 'Application Support', 'com.microsoft.edit')
    } $else $if linux {
        xdg := os.getenv('XDG_CONFIG_HOME')
        base := if xdg != '' { xdg } else { os.join_path(home, '.config') }
        return os.join_path(base, 'msedit')
    } $else {
        return os.join_path(home, '.config', 'msedit')
    }
}

// Initial contents when the file does not yet exist (matches Rust bootstrap).
fn settings_bootstrap_text() string { return '{\n}\n' }

// Loaded settings pulled from the user-level settings.json. Currently only
// the `files.associations` block is honoured; everything else is read but
// ignored so future fields don't break the editor on first launch.
pub struct UserSettings {
pub mut:
	path                 string
	file_associations    []FileAssociation
	has_associations     bool
}

// FileAssociation mirrors the `files.associations` map: a glob pattern
// and the language id it maps to. The pattern is stored in its normalised
// form (see `normalize_glob`).
pub struct FileAssociation {
pub:
	pattern  string
	language int
}

// normalize_glob applies the same Rust-style normalisation as the rest of
// the editor: a bare basename (no `/`) is auto-prefixed with `**/` so users
// can write `*.py` instead of `**/*.py`.
fn normalize_glob(pattern string) string {
	if !pattern.contains('/') {
		return '**/' + pattern
	}
	return pattern
}

// language_index returns the index of the language with the given id inside
// `lsh_languages`, or -1 if no such language exists. A return of -1 is the
// signal to drop the association with a friendly error.
fn language_index(id string) int {
	for i, lang in lsh_languages {
		if lang.id == id {
			return i
		}
	}
	return -1
}

// load_settings reads and parses the user settings file. A missing file is
// not an error: the caller just gets an empty UserSettings. Decode errors,
// a non-object root, and unknown language ids are written to the supplied
// error log so the editor can stay usable.
fn load_settings(mut log []string) UserSettings {
	path := settings_path()
	mut settings := UserSettings{
		path: path
	}
	if path == '' || !os.exists(path) {
		return settings
	}
	text := os.read_file(path) or {
		log << 'settings: cannot read ${path}: ${err}'
		return settings
	}
	// Empty/whitespace-only file behaves like a fresh bootstrap: no settings.
	trimmed := text.trim_space()
	if trimmed == '' || trimmed == '{}' {
		return settings
	}
	root := json2.decode[json2.Any](text) or {
		log << 'settings: invalid JSON in ${path}: ${err}'
		return settings
	}
	if root !is map[string]json2.Any {
		log << 'settings: invalid JSON root in ${path}: expected object'
		return settings
	}
	root_map := root as map[string]json2.Any
	if 'files.associations' !in root_map {
		return settings
	}
	associations := root_map['files.associations'] or { return settings }
	if associations !is map[string]json2.Any {
		log << 'settings: ${path}: files.associations must be an object'
		return settings
	}
	for pattern, raw_language in (associations as map[string]json2.Any) {
		if raw_language !is string {
			log << 'settings: ${path}: files.associations[${pattern}] must be a language ID'
			continue
		}
		language := raw_language as string
		idx := language_index(language)
		if idx < 0 {
			log << 'settings: ${path}: files.associations[${pattern}]: unknown language "${language}"'
			continue
		}
		settings.file_associations << FileAssociation{
			pattern:  normalize_glob(pattern)
			language: idx
		}
		settings.has_associations = true
	}
	return settings
}

// Opens settings.json as a new document. When the file is absent, creates
// the parent dir, opens an empty buffer with the bootstrap text, and
// pre-fills doc.path so Ctrl+S writes to the correct platform location.
fn (mut ed Editor) open_preferences() {
    path := settings_path()
    if path == '' {
        ed.status = 'preferences: HOME is unset, cannot resolve settings path'
        return
    }
    if os.exists(path) {
        ed.add_document(path) or {
            ed.status = 'preferences: open failed: ${err}'
            return
        }
        return
    }
    dir := os.dir(path)
    if dir != '' && !os.exists(dir) {
        os.mkdir_all(dir) or {
            ed.status = 'preferences: cannot create ${dir}: ${err}'
            return
        }
    }
    ed.add_document('') or {
        ed.status = 'preferences: cannot create buffer: ${err}'
        return
    }
    mut doc := &ed.docs[ed.active]
    doc.buf.copy_from_str(StringDocument{ text: settings_bootstrap_text() })
    doc.buf.mark_as_clean()
    doc.buf.set_crlf(false)
    doc.path = path
    ed.status = 'preferences: editing ${path} (save to create)'
}
