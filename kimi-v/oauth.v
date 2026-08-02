// oauth.v — Kimi Code OAuth login (RFC 8628 device flow).
//
// Endpoint and response layout mirror MoonshotAI/kimi-cli's auth/oauth.py:
//   POST <host>/api/oauth/device_authorization   (form: client_id)
//   POST <host>/api/oauth/token                  (grant_type=device_code |
//                                                 refresh_token)
// Tokens are stored in <config-dir>/credentials.json (file 0600, dir 0700),
// separate from config.toml, so an OAuth access token never collides with a
// manually configured API key.
module main

import os
import json2
import time
import net.http

const default_oauth_host = 'https://auth.kimi.com'
// OAuth client id used by kimi-code (KIMI_CODE_CLIENT_ID upstream).
const kimi_code_client_id = '17e5f671-d194-4dfb-9706-5516cb48c098'
// Access tokens expire after 15 minutes upstream; fallback TTL used when
// the token endpoint omits expires_in.
const oauth_access_ttl_s = 900
// Total time the user has to finish authorization in the browser.
const oauth_deadline_s = 600

// OAuthConfig carries the endpoints used by the device flow. All fields are
// overridable via env: KIMI_CODE_OAUTH_HOST / KIMI_OAUTH_HOST (host),
// KIMI_OAUTH_DEVICE_URL, KIMI_OAUTH_TOKEN_URL, KIMI_OAUTH_CLIENT_ID, and
// KIMI_OAUTH_NO_BROWSER (disables auto-opening the browser; useful for
// scripts and tests).
pub struct OAuthConfig {
pub:
	host         string
	device_url   string
	token_url    string
	client_id    string
	open_browser bool
}

// Credentials is the persisted OAuth token pair.
pub struct Credentials {
pub:
	access_token  string
	refresh_token string
	expires_at    i64 // unix seconds; 0 means "never set"
	token_type    string = 'Bearer'
}

// DeviceAuthResponse is the response of the device authorization endpoint.
pub struct DeviceAuthResponse {
pub:
	user_code                 string
	device_code               string
	verification_uri          string
	verification_uri_complete string
	expires_in                int
	interval                  int
}

// TokenResponseRaw is the token endpoint response. It also carries OAuth
// error codes (authorization_pending / slow_down / expired_token /
// access_denied) during polling, so a single struct covers both cases.
pub struct TokenResponseRaw {
pub mut:
	access_token      string
	refresh_token     string
	expires_in        int
	scope             string
	token_type        string
	error             string
	error_description string
}

// OAuthPollState is the result of classifying a poll response.
pub enum OAuthPollState {
	success
	pending
	slow_down
	expired
	denied
	failed
}

// OAuthPollDecision is the classification of one token-endpoint response.
pub struct OAuthPollDecision {
pub:
	state   OAuthPollState
	token   TokenResponseRaw
	message string
}

// OAuthHttpResult is a raw HTTP response from an OAuth endpoint.
struct OAuthHttpResult {
pub:
	status_code int
	body        string
}

// oauth_host returns the OAuth server host, honoring KIMI_CODE_OAUTH_HOST
// (upstream name) then KIMI_OAUTH_HOST, defaulting to the public endpoint.
pub fn oauth_host() string {
	mut h := os.getenv('KIMI_CODE_OAUTH_HOST')
	if h.len == 0 {
		h = os.getenv('KIMI_OAUTH_HOST')
	}
	if h.len == 0 {
		return default_oauth_host
	}
	return h
}

// default_oauth_config resolves the OAuth endpoints from env with the
// upstream defaults as fallback.
pub fn default_oauth_config() OAuthConfig {
	host := oauth_host()
	device_url := oauth_env_or('KIMI_OAUTH_DEVICE_URL', host + '/api/oauth/device_authorization')
	token_url := oauth_env_or('KIMI_OAUTH_TOKEN_URL', host + '/api/oauth/token')
	client_id := oauth_env_or('KIMI_OAUTH_CLIENT_ID', kimi_code_client_id)
	return OAuthConfig{
		host:         host
		device_url:   device_url
		token_url:    token_url
		client_id:    client_id
		open_browser: !oauth_bool_env('KIMI_OAUTH_NO_BROWSER')
	}
}

fn oauth_env_or(name string, fallback string) string {
	v := os.getenv(name)
	if v.len > 0 {
		return v
	}
	return fallback
}

fn oauth_bool_env(name string) bool {
	v := os.getenv(name)
	return v.len > 0 && v in ['1', 'true', 'yes', 'on']
}

// credentials_path returns the on-disk location of the OAuth credentials.
pub fn credentials_path() string {
	return os.join_path(config_dir(), 'credentials.json')
}

// save_credentials writes the token pair to <config-dir>/credentials.json
// with owner-only permissions (file 0600, directory 0700).
pub fn save_credentials(creds Credentials) ! {
	dir := config_dir()
	ensure_dir(dir)!
	os.chmod(dir, 0o700) or {}
	path := credentials_path()
	os.write_file(path, json2.encode(creds, escape_unicode: true))!
	os.chmod(path, 0o600) or {}
}

// load_credentials reads the persisted token pair. Errors when the file is
// missing or corrupt.
pub fn load_credentials() !Credentials {
	path := credentials_path()
	if !os.exists(path) {
		return error('no credentials file at ${path}')
	}
	raw := os.read_file(path)!
	return json2.decode[Credentials](raw)!
}

// delete_credentials removes the credentials file. No-op when absent.
pub fn delete_credentials() ! {
	path := credentials_path()
	if os.exists(path) {
		os.rm(path)!
	}
}

// is_credentials_expired reports whether the access token is expired (or the
// expiry was never recorded, e.g. hand-written file).
pub fn is_credentials_expired(c Credentials) bool {
	return c.expires_at <= 0 || time.now().unix() >= c.expires_at
}

// credentials_from_token builds Credentials from a token-endpoint response,
// defaulting token_type to Bearer and TTL to oauth_access_ttl_s when absent.
pub fn credentials_from_token(tr TokenResponseRaw) Credentials {
	tt := if tr.token_type.len > 0 { tr.token_type } else { 'Bearer' }
	ttl := if tr.expires_in > 0 { i64(tr.expires_in) } else { i64(oauth_access_ttl_s) }
	return Credentials{
		access_token:  tr.access_token
		refresh_token: tr.refresh_token
		expires_at:    time.now().unix() + ttl
		token_type:    tt
	}
}

// parse_device_auth decodes the device authorization response and validates
// the fields the polling loop needs.
pub fn parse_device_auth(raw string) !DeviceAuthResponse {
	da := json2.decode[DeviceAuthResponse](raw)!
	if da.device_code.len == 0 || da.user_code.len == 0 {
		return error('device authorization response missing device_code/user_code')
	}
	return da
}

// classify_poll_response turns a token-endpoint HTTP response into a poll
// decision. 2xx with an access_token is success; OAuth error codes map to
// the remaining states; anything else is a hard failure.
pub fn classify_poll_response(status int, raw string) OAuthPollDecision {
	token := json2.decode[TokenResponseRaw](raw) or {
		return OAuthPollDecision{
			state:   .failed
			message: 'unparseable token response (HTTP ${status})'
		}
	}
	if status >= 200 && status < 300 && token.access_token.len > 0 {
		return OAuthPollDecision{
			state: .success
			token: token
		}
	}
	match token.error {
		'authorization_pending' {
			return OAuthPollDecision{
				state:   .pending
				message: token.error_description
			}
		}
		'slow_down' {
			return OAuthPollDecision{
				state:   .slow_down
				message: token.error_description
			}
		}
		'expired_token' {
			return OAuthPollDecision{
				state:   .expired
				message: token.error_description
			}
		}
		'access_denied' {
			return OAuthPollDecision{
				state:   .denied
				message: token.error_description
			}
		}
		else {
			msg := if token.error.len > 0 { token.error } else { 'HTTP ${status}' }
			return OAuthPollDecision{
				state:   .failed
				message: msg
			}
		}
	}
}

// oauth_post_form sends an application/x-www-form-urlencoded POST and returns
// status + body. Used for both the device and token endpoints.
fn oauth_post_form(url string, form map[string]string, timeout_s int) !OAuthHttpResult {
	mut parts := []string{}
	for k, v in form {
		parts << '${url_encode(k)}=${url_encode(v)}'
	}
	header := http.new_header(
		http.HeaderConfig{ key: .content_type, value: 'application/x-www-form-urlencoded' },
		http.HeaderConfig{
			key:   .user_agent
			value: 'kimi-v/0.1 (oauth)'
		},
	)
	resp := http.fetch(http.FetchConfig{
		url:          url
		method:       .post
		data:         parts.join('&')
		header:       header
		read_timeout: timeout_s * time.second
	}) or { return error('oauth request to ${url} failed: ${err.msg()}') }
	return OAuthHttpResult{
		status_code: resp.status_code
		body:        resp.body
	}
}

// run_device_flow drives the RFC 8628 device flow to completion: requests a
// device code, prints the verification URL + user code, opens the browser,
// then polls the token endpoint until the user authorizes (or the flow is
// denied / expired / times out).
pub fn run_device_flow(oc OAuthConfig) !TokenResponseRaw {
	println('')
	println('Log in to your Kimi account:')
	println('')
	dev := oauth_post_form(oc.device_url, {
		'client_id': oc.client_id
	}, 30)!
	if dev.status_code < 200 || dev.status_code >= 300 {
		return error('device authorization failed (HTTP ${dev.status_code}): ${oauth_body_preview(dev.body)}')
	}
	da := parse_device_auth(dev.body)!
	uri := if da.verification_uri_complete.len > 0 {
		da.verification_uri_complete
	} else {
		da.verification_uri
	}
	println('  open: ${uri}')
	println('  code: ${da.user_code}')
	println('')
	if oc.open_browser {
		open_browser(uri)
	} else {
		println('  (browser auto-open disabled; open the URL manually)')
	}

	mut interval := da.interval
	if interval <= 0 {
		interval = 5
	}
	deadline := time.now().unix() + oauth_deadline_s
	mut first_wait := true
	for {
		if time.now().unix() >= deadline {
			return error('timed out after ${oauth_deadline_s}s waiting for authorization; run `kimi login --oauth` again')
		}
		resp := oauth_post_form(oc.token_url, {
			'grant_type':  'urn:ietf:params:oauth:grant-type:device_code'
			'device_code': da.device_code
			'client_id':   oc.client_id
		}, 30)!
		decision := classify_poll_response(resp.status_code, resp.body)
		match decision.state {
			.success {
				println('')
				println('authorized.')
				return decision.token
			}
			.pending {
				if first_wait {
					println('waiting for authorization in your browser...')
					first_wait = false
				}
			}
			.slow_down {
				interval += 5
			}
			.expired {
				return error('device code expired; run `kimi login --oauth` again')
			}
			.denied {
				return error('authorization denied')
			}
			.failed {
				return error('token request failed (HTTP ${resp.status_code}): ${oauth_body_preview(resp.body)}')
			}
		}
		time.sleep(interval * time.second)
	}
	return error('unreachable')
}

// refresh_credentials exchanges a refresh token for a fresh access token and
// returns new Credentials (keeping the old refresh token when the server
// does not rotate it).
pub fn refresh_credentials(oc OAuthConfig, creds Credentials) !Credentials {
	if creds.refresh_token.len == 0 {
		return error('no refresh token available')
	}
	resp := oauth_post_form(oc.token_url, {
		'grant_type':    'refresh_token'
		'refresh_token': creds.refresh_token
		'client_id':     oc.client_id
	}, 30)!
	decision := classify_poll_response(resp.status_code, resp.body)
	if decision.state != .success {
		return error('token refresh failed (HTTP ${resp.status_code}): ${oauth_body_preview(resp.body)}')
	}
	mut tr := decision.token
	if tr.refresh_token.len == 0 {
		tr.refresh_token = creds.refresh_token
	}
	return credentials_from_token(tr)
}

// resolve_oauth_credentials injects a saved OAuth access token into
// cfg.api_key when no API key was configured anywhere. Expired tokens are
// refreshed via the refresh token; refresh failures are fatal so the user
// gets a clear re-login hint. A missing/corrupt credentials file fails open
// (no key → the normal validate() error tells the user to log in).
pub fn resolve_oauth_credentials(mut cfg Config) ! {
	if cfg.api_key.len > 0 {
		return
	}
	creds := load_credentials() or { return }
	if !is_credentials_expired(creds) {
		cfg.api_key = creds.access_token
		return
	}
	if creds.refresh_token.len == 0 {
		return error('OAuth access token has expired and no refresh token is saved; run `kimi login --oauth` again')
	}
	refreshed := refresh_credentials(default_oauth_config(), creds) or {
		return error('OAuth token refresh failed: ${err.msg()}; run `kimi login --oauth` again')
	}
	save_credentials(refreshed) or {
		return error('could not persist refreshed OAuth credentials: ${err.msg()}')
	}
	cfg.api_key = refreshed.access_token
}

// open_browser tries to open url in the user's default browser. Best-effort:
// failures are ignored — the URL is already printed for manual entry.
fn open_browser(url string) {
	mut opener := 'xdg-open'
	match detect_os() {
		'macos' {
			opener = 'open'
		}
		'windows' {
			opener = 'start ""'
		}
		else {
			opener = 'xdg-open'
		}
	}
	os.system('${opener} "${url}" >/dev/null 2>&1 &')
}

// oauth_body_preview trims a response body for error messages.
fn oauth_body_preview(s string) string {
	if s.len > 300 {
		return s[..300] + '...'
	}
	return s
}
