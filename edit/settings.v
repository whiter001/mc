module main

import os

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
