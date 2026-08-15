// upgrade_test.v — unit tests for the self-update module (issue #15).
//
// Pure-function tests only: no network, no filesystem. The orchestration in
// run_upgrade() (which hits the GitHub API and replaces the binary) is
// exercised manually via `bin/kimi upgrade`, not here.
module main

import json2

// ---------- compare_versions -------------------------------------------------

fn test_compare_versions_equal() {
	assert compare_versions('0.1.0', '0.1.0') == 0
	assert compare_versions('1.2.3', '1.2.3') == 0
}

fn test_compare_versions_current_older() {
	assert compare_versions('0.1.0', '0.2.0') == -1
	assert compare_versions('1.0.0', '1.0.1') == -1
	assert compare_versions('0.9.9', '1.0.0') == -1
}

fn test_compare_versions_current_newer() {
	assert compare_versions('0.2.0', '0.1.0') == 1
	assert compare_versions('2.0.0', '1.9.9') == 1
}

fn test_compare_versions_v_prefix() {
	assert compare_versions('v0.1.0', '0.1.0') == 0
	assert compare_versions('v0.1.0', 'v0.2.0') == -1
	assert compare_versions('0.2.0', 'v0.1.0') == 1
}

fn test_compare_versions_missing_segment_padded_to_zero() {
	assert compare_versions('1.2', '1.2.0') == 0
	assert compare_versions('1.2', '1.2.1') == -1
	assert compare_versions('1.2.1', '1.2') == 1
}

fn test_compare_versions_extra_segment() {
	assert compare_versions('1.2.3.4', '1.2.3') == 1
	assert compare_versions('1.2.3', '1.2.3.4') == -1
}

fn test_compare_versions_non_numeric_tail_truncated() {
	assert compare_versions('1.2.3-beta', '1.2.3') == 0
	assert compare_versions('1.2.3-beta', '1.2.4') == -1
	assert compare_versions('0.1.0', '0.1.0-alpha') == 0
}

// ---------- platform_asset_name ---------------------------------------------

fn test_platform_asset_name_shape() {
	name := platform_asset_name('0.2.0')
	// Runs on this mac: asset must be kimi-v-<version>-darwin-<arch>.
	assert name.starts_with('kimi-v-0.2.0-')
	assert name.contains('darwin')
	assert name.contains('arm64') || name.contains('amd64')
}

// ---------- select_asset ------------------------------------------------------

fn test_select_asset_hit() {
	assets := [
		ReleaseAsset{ name: 'kimi-v-0.2.0-darwin-arm64', url: 'https://a.example/x' },
		ReleaseAsset{ name: 'kimi-v-0.2.0-darwin-amd64', url: 'https://a.example/y' },
	]
	a := select_asset(assets, 'kimi-v-0.2.0-darwin-arm64') or {
		assert false
		return
	}
	assert a.name == 'kimi-v-0.2.0-darwin-arm64'
	assert a.url == 'https://a.example/x'
}

fn test_select_asset_miss() {
	assets := [ReleaseAsset{ name: 'kimi-v-0.2.0-linux-amd64', url: 'https://a.example/z' }]
	if _ := select_asset(assets, 'kimi-v-0.2.0-darwin-arm64') {
		assert false, 'should not match a different asset name'
	}
}

fn test_select_asset_exact_match_only() {
	assets := [ReleaseAsset{ name: 'kimi-v-0.2.0-darwin', url: 'https://a.example/d' }]
	if _ := select_asset(assets, 'kimi-v-0.2.0-darwin-arm64') {
		assert false, 'exact name match required'
	}
}

// ---------- is_lock_stale -----------------------------------------------------

fn test_is_lock_stale_boundaries() {
	now := i64(1_000_000_000_000)
	// Fresh lock: 1 second old.
	assert !is_lock_stale(now - 1_000, now)
	// Exactly 30 minutes old → not stale (must exceed the threshold).
	assert !is_lock_stale(now - 30 * 60 * 1000, now)
	// Just past 30 minutes → stale.
	assert is_lock_stale(now - (30 * 60 * 1000 + 1), now)
	// Hours old → stale.
	assert is_lock_stale(now - 2 * 60 * 60 * 1000, now)
}

// ---------- release JSON parsing ---------------------------------------------

fn test_parse_release_json() {
	raw := '{\"tag_name\":\"v0.2.0\",\"assets\":[{\"name\":\"kimi-v-0.2.0-darwin-arm64\",\"browser_download_url\":\"https://github.com/whiter001/mc/releases/download/v0.2.0/kimi-v-0.2.0-darwin-arm64\"},{\"name\":\"kimi-v-0.2.0-linux-amd64\",\"browser_download_url\":\"https://github.com/whiter001/mc/releases/download/v0.2.0/kimi-v-0.2.0-linux-amd64\"}]}'
	info := json2.decode[ReleaseInfo](raw) or {
		assert false, 'release JSON should parse: ${err.msg()}'
		return
	}
	assert info.version == 'v0.2.0'
	assert info.assets.len == 2
	assert info.assets[0].name == 'kimi-v-0.2.0-darwin-arm64'
	assert info.assets[0].url == 'https://github.com/whiter001/mc/releases/download/v0.2.0/kimi-v-0.2.0-darwin-arm64'
	assert info.assets[1].name == 'kimi-v-0.2.0-linux-amd64'
}
