// oauth_test.v — unit tests for the OAuth device-flow implementation.
//
// Credentials persistence is tested against an isolated KIMI_CONFIG_DIR under
// the system temp dir; pure functions (poll classification, expiry, parsing)
// need no filesystem or network. Tests within this file run sequentially.
module main

import os
import time

// oauth_test_dir returns a unique scratch config dir for one test.
fn oauth_test_dir(suffix string) string {
	return os.join_path(os.temp_dir(), 'kimi-oauth-test-' + suffix)
}

// ---------- credentials persistence ----------------------------------------

fn test_credentials_roundtrip_and_permissions() {
	dir := oauth_test_dir('roundtrip')
	os.setenv('KIMI_CONFIG_DIR', dir, true)
	defer {
		os.setenv('KIMI_CONFIG_DIR', '', true)
		os.rmdir_all(dir) or {}
	}
	creds := Credentials{
		access_token:  'tok-abc'
		refresh_token: 'ref-xyz'
		expires_at:    time.now().unix() + 3600
		token_type:    'Bearer'
	}
	save_credentials(creds)!
	loaded := load_credentials()!
	assert loaded.access_token == 'tok-abc'
	assert loaded.refresh_token == 'ref-xyz'
	assert loaded.expires_at == creds.expires_at
	assert loaded.token_type == 'Bearer'
	path := credentials_path()
	assert os.exists(path)
	st := os.stat(path)!
	assert st.mode & 0o777 == 0o600
	dst := os.stat(dir)!
	assert dst.mode & 0o777 == 0o700
}

fn test_load_credentials_missing_errors() {
	dir := oauth_test_dir('missing')
	os.setenv('KIMI_CONFIG_DIR', dir, true)
	defer {
		os.setenv('KIMI_CONFIG_DIR', '', true)
		os.rmdir_all(dir) or {}
	}
	load_credentials() or {
		assert err.msg().contains('no credentials file')
		return
	}
	assert false, 'expected an error for a missing credentials file'
}

fn test_delete_credentials() {
	dir := oauth_test_dir('delete')
	os.setenv('KIMI_CONFIG_DIR', dir, true)
	defer {
		os.setenv('KIMI_CONFIG_DIR', '', true)
		os.rmdir_all(dir) or {}
	}
	// No-op when the file is absent.
	delete_credentials()!
	creds := Credentials{
		access_token: 'tok'
		expires_at:   time.now().unix() + 60
	}
	save_credentials(creds)!
	assert os.exists(credentials_path())
	delete_credentials()!
	assert !os.exists(credentials_path())
	// No-op again after removal.
	delete_credentials()!
}

// ---------- expiry ----------------------------------------------------------

fn test_is_credentials_expired() {
	now := time.now().unix()
	// expires_at == 0 (hand-written or unknown) counts as expired.
	assert is_credentials_expired(Credentials{
		access_token: 'a'
		expires_at:   0
	})
	assert is_credentials_expired(Credentials{
		access_token: 'a'
		expires_at:   now - 1
	})
	assert !is_credentials_expired(Credentials{
		access_token: 'a'
		expires_at:   now + 3600
	})
}

// ---------- token response → credentials -----------------------------------

fn test_credentials_from_token_defaults() {
	now := time.now().unix()
	c := credentials_from_token(TokenResponseRaw{
		access_token: 'tok'
	})
	assert c.access_token == 'tok'
	assert c.token_type == 'Bearer'
	assert c.expires_at >= now + oauth_access_ttl_s - 1
		&& c.expires_at <= now + oauth_access_ttl_s + 1
}

fn test_credentials_from_token_explicit_fields() {
	now := time.now().unix()
	c := credentials_from_token(TokenResponseRaw{
		access_token:  'tok'
		refresh_token: 'ref'
		expires_in:    120
		token_type:    'custom'
	})
	assert c.token_type == 'custom'
	assert c.expires_at == now + 120
}

// ---------- device authorization parsing -----------------------------------

fn test_parse_device_auth_ok() {
	da :=
		parse_device_auth('{"user_code":"ABCD-EFGH","device_code":"dev-1","verification_uri":"https://auth.kimi.com/verify","verification_uri_complete":"https://auth.kimi.com/verify?code=ABCD-EFGH","expires_in":900,"interval":5}')!
	assert da.user_code == 'ABCD-EFGH'
	assert da.device_code == 'dev-1'
	assert da.verification_uri == 'https://auth.kimi.com/verify'
	assert da.verification_uri_complete.len > 0
	assert da.interval == 5
}

fn test_parse_device_auth_missing_fields_errors() {
	parse_device_auth('{"user_code":"only"}') or {
		assert err.msg().contains('device_code')
		return
	}
	assert false, 'expected an error for a missing device_code'
}

// ---------- poll response classification -----------------------------------

fn test_classify_poll_success() {
	d := classify_poll_response(200,
		'{"access_token":"tok","refresh_token":"ref","expires_in":900,"token_type":"Bearer"}')
	assert d.state == .success
	assert d.token.access_token == 'tok'
	assert d.token.refresh_token == 'ref'
}

fn test_classify_poll_pending() {
	d := classify_poll_response(400, '{"error":"authorization_pending"}')
	assert d.state == .pending
}

fn test_classify_poll_slow_down() {
	d := classify_poll_response(400, '{"error":"slow_down"}')
	assert d.state == .slow_down
}

fn test_classify_poll_expired() {
	d := classify_poll_response(400, '{"error":"expired_token"}')
	assert d.state == .expired
}

fn test_classify_poll_denied() {
	d := classify_poll_response(400, '{"error":"access_denied"}')
	assert d.state == .denied
}

fn test_classify_poll_unparseable_fails() {
	d := classify_poll_response(500, 'not json at all')
	assert d.state == .failed
}

fn test_classify_poll_unknown_error_fails() {
	d := classify_poll_response(500, '{"error":"server_error"}')
	assert d.state == .failed
}

// ---------- refresh ---------------------------------------------------------

fn test_refresh_credentials_without_refresh_token_errors() {
	// Short-circuits before any HTTP; safe to run without a network.
	oc := default_oauth_config()
	creds := Credentials{
		access_token: 'a'
		expires_at:   time.now().unix() + 60
	}
	refresh_credentials(oc, creds) or {
		assert err.msg().contains('no refresh token')
		return
	}
	assert false, 'expected an error when no refresh token is available'
}
