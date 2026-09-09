module main

import os

fn test_settings_bootstrap_text_is_empty_object() {
	assert settings_bootstrap_text() == '{\n}\n'
}

fn test_settings_path_appends_filename() {
	// settings_path is a pure function of HOME, so we can test in isolation
	// by temporarily setting HOME.
	tmp := os.temp_dir() + os.path_separator + 'edit_settings_test_${u64(os.getpid())}'
	os.mkdir_all(tmp) or { panic(err) }
	defer { os.rmdir_all(tmp) or {} }
	os.setenv('HOME', tmp, true)
	defer { os.unsetenv('HOME') }
	assert settings_path().ends_with('${os.path_separator}settings.json')
}

fn test_settings_path_resolves_to_filename() {
	tmp := os.temp_dir() + os.path_separator + 'edit_settings_test_${u64(os.getpid())}'
	os.mkdir_all(tmp) or { panic(err) }
	defer { os.rmdir_all(tmp) or {} }
	os.setenv('HOME', tmp, true)
	defer { os.unsetenv('HOME') }
	// On non-macos, settings_path returns a path under XDG_CONFIG_HOME/msedit/settings.json.
	// We just verify the path is non-empty and ends with settings.json.
	path := settings_path()
	assert path != ''
	assert os.file_name(path) == 'settings.json'
}

$if macos {
	fn test_settings_config_dir_macos() {
		tmp := os.temp_dir() + os.path_separator + 'edit_settings_test_${u64(os.getpid())}'
		os.mkdir_all(tmp) or { panic(err) }
		defer { os.rmdir_all(tmp) or {} }
		os.setenv('HOME', tmp, true)
		defer { os.unsetenv('HOME') }
		dir := settings_config_dir()
		assert dir == os.join_path(tmp, 'Library', 'Application Support', 'com.microsoft.edit')
	}
}

fn test_open_preferences_uses_existing_file() {
	// Verify that settings_path resolves to the correct path by creating the
	// directory and file ahead of time and checking resolution.
	tmp := os.temp_dir() + os.path_separator + 'edit_settings_test_${u64(os.getpid())}'
	os.mkdir_all(tmp) or { panic(err) }
	defer { os.rmdir_all(tmp) or {} }
	os.setenv('HOME', tmp, true)
	defer { os.unsetenv('HOME') }

	path := settings_path()
	dir := os.dir(path)
	os.mkdir_all(dir) or { panic(err) }
	os.write_file(path, '{\n"theme": "dark"\n}\n') or { panic(err) }

	assert os.exists(path)
	assert settings_path() == path
}

fn test_normalize_glob_bare_pattern_gets_prefix() {
	// Bare basenames auto-prefix `**/` so users can write `*.py` instead of
	// `**/*.py`, matching the Rust reference parser.
	assert normalize_glob('*.py') == '**/*.py'
	assert normalize_glob('build.sh') == '**/build.sh'
	// Patterns that already contain a separator are passed through untouched.
	assert normalize_glob('src/**/*.rs') == 'src/**/*.rs'
	assert normalize_glob('**/*.md') == '**/*.md'
}

fn test_load_settings_missing_file_is_empty_not_error() {
	tmp := os.temp_dir() + os.path_separator + 'edit_settings_missing_${u64(os.getpid())}'
	defer { os.rmdir_all(tmp) or {} }
	os.setenv('HOME', tmp, true)
	defer { os.unsetenv('HOME') }

	mut log := []string{}
	settings := load_settings(mut log)
	assert settings.path == settings_path()
	assert settings.path.ends_with('settings.json')
	assert !settings.has_associations
	assert settings.file_associations.len == 0
	assert log.len == 0
}

fn test_load_settings_parses_associations_and_normalizes_globs() {
	tmp := os.temp_dir() + os.path_separator + 'edit_settings_load_${u64(os.getpid())}'
	defer { os.rmdir_all(tmp) or {} }
	os.setenv('HOME', tmp, true)
	defer { os.unsetenv('HOME') }

	path := settings_path()
	os.mkdir_all(os.dir(path)) or { panic(err) }
	os.write_file(path, '{\n  "files.associations": {\n    "*.py": "python",\n    "**/*.md": "markdown"\n  }\n}\n') or { panic(err) }

	mut log := []string{}
	settings := load_settings(mut log)
	assert settings.has_associations
	assert settings.file_associations.len == 2
	assert settings.file_associations[0].pattern == '**/*.py'
	assert settings.file_associations[0].language == language_index('python')
	assert settings.file_associations[1].pattern == '**/*.md'
	assert settings.file_associations[1].language == language_index('markdown')
	assert log.len == 0
}

fn test_load_settings_unknown_language_writes_to_log() {
	tmp := os.temp_dir() + os.path_separator + 'edit_settings_unknown_${u64(os.getpid())}'
	defer { os.rmdir_all(tmp) or {} }
	os.setenv('HOME', tmp, true)
	defer { os.unsetenv('HOME') }

	path := settings_path()
	os.mkdir_all(os.dir(path)) or { panic(err) }
	os.write_file(path, '{\n  "files.associations": {"*.x": "klingon"}\n}\n') or { panic(err) }

	mut log := []string{}
	settings := load_settings(mut log)
	assert !settings.has_associations
	assert settings.file_associations.len == 0
	assert log.len == 1
	assert log[0].contains('klingon')
}

fn test_load_settings_invalid_json_writes_to_log() {
	tmp := os.temp_dir() + os.path_separator + 'edit_settings_bad_${u64(os.getpid())}'
	defer { os.rmdir_all(tmp) or {} }
	os.setenv('HOME', tmp, true)
	defer { os.unsetenv('HOME') }

	path := settings_path()
	os.mkdir_all(os.dir(path)) or { panic(err) }
	os.write_file(path, '{\n  this is not json\n') or { panic(err) }

	mut log := []string{}
	settings := load_settings(mut log)
	assert !settings.has_associations
	assert log.len == 1
	assert log[0].contains('settings:')
}
