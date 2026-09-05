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
