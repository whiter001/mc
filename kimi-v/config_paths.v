// internal/config/paths.v
// Cross-platform config directory resolution. Honors XDG on Linux,
// ~/Library/Application Support on macOS, %AppData% on Windows.
module main

import os

// detect_os returns 'macos' | 'windows' | 'linux' | 'other'. We use a
// runtime check rather than $if so the code stays in one place and we
// don't fight V's compile-time conditional syntax.
fn detect_os() string {
	$if macos {
		return 'macos'
	} $else $if windows {
		return 'windows'
	} $else $if linux {
		return 'linux'
	} $else {
		return 'other'
	}
}

// config_dir returns the platform-specific directory for Kimi configuration files.
pub fn config_dir() string {
	override := os.getenv('KIMI_CONFIG_DIR')
	if override.len > 0 {
		return override
	}
	match detect_os() {
		'macos' {
			home := os.home_dir()
			return os.join_path(home, 'Library', 'Application Support', 'kimi')
		}
		'windows' {
			appdata := os.getenv('APPDATA')
			if appdata.len > 0 {
				return os.join_path(appdata, 'kimi')
			}
			return os.join_path(os.home_dir(), 'AppData', 'Roaming', 'kimi')
		}
		else {
			// Linux / other Unix
			xdg := os.getenv('XDG_CONFIG_HOME')
			if xdg.len > 0 {
				return os.join_path(xdg, 'kimi')
			}
			return os.join_path(os.home_dir(), '.config', 'kimi')
		}
	}
}

// sessions_dir returns the directory where session TOML files are stored.
pub fn sessions_dir() string {
	return os.join_path(config_dir(), 'sessions')
}

// subagent_sessions_dir returns the directory where persisted subagent
// sessions (used by the Agent tool's resume) are stored, one TOML per
// subagent id: <sessions_dir>/subagents/<id>.toml.
pub fn subagent_sessions_dir() string {
	return os.join_path(sessions_dir(), 'subagents')
}

// cache_dir returns the platform-specific directory for Kimi cache files.
pub fn cache_dir() string {
	override := os.getenv('KIMI_CACHE_DIR')
	if override.len > 0 {
		return override
	}
	match detect_os() {
		'macos' {
			return os.join_path(os.home_dir(), 'Library', 'Caches', 'kimi')
		}
		'windows' {
			local := os.getenv('LOCALAPPDATA')
			if local.len > 0 {
				return os.join_path(local, 'kimi', 'cache')
			}
			return os.join_path(os.home_dir(), 'AppData', 'Local', 'kimi', 'cache')
		}
		else {
			xdg := os.getenv('XDG_CACHE_HOME')
			if xdg.len > 0 {
				return os.join_path(xdg, 'kimi')
			}
			return os.join_path(os.home_dir(), '.cache', 'kimi')
		}
	}
}

// ensure_dir creates path and its parents if they do not already exist.
pub fn ensure_dir(path string) ! {
	if !os.exists(path) {
		os.mkdir_all(path)!
	}
}
