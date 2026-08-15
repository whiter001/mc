// upgrade.v — `kimi upgrade` self-update via GitHub Releases (issue #15).
//
// Mirrors kimi-code's upgrade flow (check → select target → install; failure
// exits 1, no update exits 0) but targets a single self-contained binary
// distributed through GitHub Releases instead of the npm + CDN canary path.
// Deliberately no telemetry, no interactive confirmation (running `kimi
// upgrade` is consent), and no startup auto-check.
//
// Asset naming convention: kimi-v-<version>-<os>-<arch>, where os is
// darwin/linux and arch is arm64/amd64 (x86_64 normalized to amd64).
module main

import os
import time
import json2
import net.http

const upgrade_repo = 'whiter001/mc'

// lock_stale_ms is how old a lock must be before it is considered abandoned
// and safe to break. Matches kimi-code's 30-minute threshold.
const lock_stale_ms = i64(30 * 60 * 1000)

// ReleaseInfo is the subset of the GitHub releases/latest response we need.
// Unknown JSON fields are ignored by json2.
pub struct ReleaseInfo {
	version string         @[json: 'tag_name']
	assets  []ReleaseAsset @[json: 'assets']
}

// ReleaseAsset is one downloadable artifact of a release.
pub struct ReleaseAsset {
	name string @[json: 'name']
	url  string @[json: 'browser_download_url']
}

// fetch_latest_release GETs the latest release from the GitHub API. A 404
// (repo has no release yet) is surfaced as the specific error 'no-release';
// network, HTTP-status, and JSON-parse problems surface as plain errors.
pub fn fetch_latest_release(api_base string) !ReleaseInfo {
	url := '${api_base}/repos/${upgrade_repo}/releases/latest'
	header := http.new_header(
		http.HeaderConfig{ key: .accept, value: 'application/vnd.github+json' },
		// GitHub API rejects requests without a User-Agent header.
		http.HeaderConfig{ key: .user_agent, value: 'kimi-v' },
	)
	resp := http.fetch(http.FetchConfig{
		url:    url
		method: .get
		header: header
	}) or {
		return error('failed to reach release API: ${err.msg()}')
	}
	if resp.status_code == 404 {
		return error('no-release')
	}
	if resp.status_code !in [200, 201, 202, 203, 204] {
		return error('release API returned HTTP ${resp.status_code}')
	}
	info := json2.decode[ReleaseInfo](resp.body) or {
		return error('failed to parse release JSON: ${err.msg()}')
	}
	if info.version.len == 0 {
		return error('release JSON missing tag_name')
	}
	return info
}

// strip_v removes a single leading 'v' from a version string.
fn strip_v(v string) string {
	if v.len > 0 && v[0] == `v` {
		return v[1..]
	}
	return v
}

// parse_segment converts one dot-separated version segment to a number,
// truncating at the first non-digit character ("3-beta" → 3, "beta" → 0).
fn parse_segment(seg string) int {
	mut n := 0
	for c in seg {
		if c < u8(`0`) || c > u8(`9`) {
			break
		}
		n = n * 10 + int(c - u8(`0`))
	}
	return n
}

// compare_versions compares two version strings numerically, segment by
// segment. Leading 'v' is ignored, missing trailing segments count as 0,
// and non-digit tails are truncated. Returns -1 if current < latest, 0 if
// equal, 1 if current > latest. Pure function — no I/O.
pub fn compare_versions(current string, latest string) int {
	cs := strip_v(current).split('.')
	ls := strip_v(latest).split('.')
	mut n := cs.len
	if ls.len > n {
		n = ls.len
	}
	for i in 0 .. n {
		mut a := 0
		mut b := 0
		if i < cs.len {
			a = parse_segment(cs[i])
		}
		if i < ls.len {
			b = parse_segment(ls[i])
		}
		if a > b {
			return 1
		}
		if a < b {
			return -1
		}
	}
	return 0
}

// platform_asset_name builds the asset name for the current host by asking
// `uname -sm` and normalizing: Darwin → darwin, x86_64 → amd64.
pub fn platform_asset_name(version string) string {
	res := os.execute('uname -sm')
	fields := res.output.trim_space().split(' ')
	mut os_name := ''
	mut arch := ''
	if fields.len >= 2 {
		os_name = fields[0].to_lower()
		arch = fields[1].to_lower()
	} else {
		// Fall back to os.uname() if `uname -sm` produced nothing useful.
		u := os.uname()
		os_name = u.sysname.to_lower()
		arch = u.machine.to_lower()
	}
	mut a := arch
	if a == 'x86_64' {
		a = 'amd64'
	}
	return 'kimi-v-${version}-${os_name}-${a}'
}

// select_asset finds the release asset whose name matches exactly.
pub fn select_asset(assets []ReleaseAsset, name string) ?ReleaseAsset {
	for a in assets {
		if a.name == name {
			return a
		}
	}
	return none
}

// is_lock_stale reports whether a lock started at started_at_ms has outlived
// the 30-minute stale threshold as of now_ms. Pure function — no I/O.
pub fn is_lock_stale(started_at_ms i64, now_ms i64) bool {
	return now_ms - started_at_ms > lock_stale_ms
}

// LockMetadata is the JSON payload stored inside the install lock.
struct LockMetadata {
	version    string @[json: 'version']
	pid        int    @[json: 'pid']
	started_at i64    @[json: 'startedAt'] // epoch milliseconds
}

// lock_dir returns the path of the install lock marker directory.
fn lock_dir() string {
	return os.join_path(config_dir(), 'update-install.lock')
}

// read_lock_metadata parses the lock's info.json. Missing/corrupt content
// yields a zero started_at, which the caller treats as stale.
fn read_lock_metadata(meta_file string) LockMetadata {
	raw := os.read_file(meta_file) or { return LockMetadata{} }
	return json2.decode[LockMetadata](raw) or { return LockMetadata{} }
}

// write_lock_metadata writes the {version, pid, startedAt} JSON payload
// into the lock directory.
fn write_lock_metadata(lock_dir string, version string) ! {
	meta := LockMetadata{
		version:    version
		pid:        os.getpid()
		started_at: time.now().unix_milli()
	}
	os.write_file(os.join_path(lock_dir, 'info.json'), json2.encode(meta))!
}

// acquire_update_lock takes the install lock exclusively. V's os.open_file
// has no O_EXCL/'x' mode (modes are limited to w/a/r/b/s/n/c/+), so we use
// an os.mkdir directory marker instead — C.mkdir is atomic and errors with
// EEXIST when the directory already exists, giving the same exclusive
// semantics. Crucially os.mkdir returns `!` (error), not a bool, in this V
// version, so we use `or { return false }`: a successful mkdir means we
// created the marker and hold the lock; any failure (EEXIST for an existing
// lock, or another I/O error) means we do not. The JSON metadata lives in a
// file inside the marker directory. An existing lock older than the stale
// threshold is broken and retried exactly once. Returns true when the lock
// is held, false when another upgrade holds a fresh lock, and errors only on
// unexpected I/O problems inside write_lock_metadata.
fn acquire_update_lock(version string) !bool {
	dir := lock_dir()
	ensure_dir(config_dir())!
	// Fast path: exclusive create via atomic mkdir.
	os.mkdir(dir, mode: 0o700) or {
		// Lock already exists (EEXIST) or another I/O error — try stale-break.
		return acquire_update_lock_stale_break(dir, version)
	}
	write_lock_metadata(dir, version)!
	return true
}

// acquire_update_lock_stale_break is the slow path for when the lock marker
// already exists: if it is stale (older than the threshold) we remove it and
// re-create once; otherwise we report that another upgrade holds it.
fn acquire_update_lock_stale_break(dir string, version string) !bool {
	meta_file := os.join_path(dir, 'info.json')
	meta := read_lock_metadata(meta_file)
	if meta.started_at <= 0 || is_lock_stale(meta.started_at, time.now().unix_milli()) {
		os.rmdir_all(dir) or {}
		os.mkdir(dir, mode: 0o700) or {
			return false
		}
		write_lock_metadata(dir, version)!
		return true
	}
	return false
}

// release_update_lock removes the lock marker. Best-effort: a missing
// marker is not an error (someone else may have broken a stale lock).
fn release_update_lock() {
	os.rmdir_all(lock_dir()) or {}
}

// run_upgrade drives the whole self-update flow. Returns the process exit
// code: 0 on success / up-to-date / no-release, 1 on failure.
pub fn run_upgrade(current_version string) int {
	info := fetch_latest_release('https://api.github.com') or {
		if err.msg() == 'no-release' {
			println('尚未发布任何 release，无法升级')
			return 0
		}
		eprintln('error: 检查更新失败：${err.msg()}')
		return 1
	}

	if compare_versions(current_version, info.version) >= 0 {
		println('已是最新 (v${current_version})')
		return 0
	}

	asset_name := platform_asset_name(info.version)
	asset := select_asset(info.assets, asset_name) or {
		eprintln('error: 找不到当前平台的 release 资产：${asset_name}')
		eprintln('可用的资产：')
		for a in info.assets {
			eprintln('  ${a.name}')
		}
		return 1
	}

	acquired := acquire_update_lock(info.version) or {
		eprintln('error: 无法创建升级锁：${err.msg()}')
		return 1
	}
	if !acquired {
		eprintln('另一个 upgrade 正在进行')
		return 1
	}
	defer {
		release_update_lock()
	}

	// Download the asset. http.fetch follows 3xx redirects by default
	// (allow_redirect: true), and GitHub asset URLs bounce to
	// objects.githubusercontent.com, so a single fetch is enough.
	header := http.new_header(
		http.HeaderConfig{ key: .accept, value: 'application/octet-stream' },
		http.HeaderConfig{ key: .user_agent, value: 'kimi-v' },
	)
	resp := http.fetch(http.FetchConfig{
		url:    asset.url
		method: .get
		header: header
	}) or {
		eprintln('error: 下载失败：${err.msg()}')
		return 1
	}
	if resp.status_code !in [200, 201, 202, 203, 204] {
		eprintln('error: 下载返回 HTTP ${resp.status_code}')
		return 1
	}

	// Stage the new binary next to the current one, then swap atomically
	// with rollback.
	exe := os.real_path(os.executable())
	dir := os.dir(exe)
	tmp := os.join_path(dir, 'kimi.upgrade-tmp')
	os.write_file(tmp, resp.body) or {
		eprintln('error: 写入临时文件失败：${err.msg()}')
		return 1
	}
	if os.file_size(tmp) == 0 {
		os.rm(tmp) or {}
		eprintln('error: 下载内容为空，已中止升级')
		return 1
	}
	os.chmod(tmp, 0o755) or {
		os.rm(tmp) or {}
		eprintln('error: 无法设置可执行权限：${err.msg()}')
		return 1
	}

	old := '${exe}.kimi-old'
	os.rm(old) or {} // leftover from a previously crashed upgrade
	os.rename(exe, old) or {
		os.rm(tmp) or {}
		eprintln('error: 无法重命名当前二进制：${err.msg()}')
		return 1
	}
	os.rename(tmp, exe) or {
		// Roll back: put the original binary back in place.
		os.rename(old, exe) or {}
		os.rm(tmp) or {}
		eprintln('error: 无法安装新二进制：${err.msg()}')
		return 1
	}
	os.rm(old) or {}

	println('已升级到 v${info.version}，重启后生效')
	return 0
}
