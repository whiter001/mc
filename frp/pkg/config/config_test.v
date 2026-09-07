module config

import os

const server_toml = '
bind_addr = "127.0.0.1"
bind_port = 7001
auth_token = "s3cret"
'
const client_toml = '
server_addr = "127.0.0.1"
server_port = 7000
auth_token = "s3cret"
pool_count = 2
heartbeat_interval = 30

[[proxies]]
name = "ssh"
type = "tcp"
local_port = 22
remote_port = 6000

[[proxies]]
name = "dns"
type = "udp"
local_ip = "10.0.0.2"
local_port = 53
remote_port = 6001
'

// write_tmp 把 TOML 文本写到临时文件并返回路径。
fn write_tmp(name string, txt string) string {
	path := os.join_path(os.temp_dir(), 'vfrp_config_${os.getpid()}_${name}.toml')
	os.write_file(path, txt) or { panic(err.msg()) }
	return path
}

// server_err 返回 load_server_config 的错误信息；无错误时返回空串。
fn server_err(path string) string {
	_ := load_server_config(path) or { return err.msg() }
	return ''
}

// client_err 返回 load_client_config 的错误信息；无错误时返回空串。
fn client_err(path string) string {
	_ := load_client_config(path) or { return err.msg() }
	return ''
}

fn test_server_config_valid() {
	path := write_tmp('server_valid', server_toml)
	defer {
		os.rm(path) or {}
	}
	cfg := load_server_config(path) or { panic(err.msg()) }
	assert cfg.bind_addr == '127.0.0.1'
	assert cfg.bind_port == 7001
	assert cfg.auth_token == 's3cret'
}

fn test_server_config_defaults() {
	path := write_tmp('server_defaults', '')
	defer {
		os.rm(path) or {}
	}
	cfg := load_server_config(path) or { panic(err.msg()) }
	assert cfg.bind_addr == '0.0.0.0'
	assert cfg.bind_port == 7000
	assert cfg.auth_token == ''
}

fn test_server_config_invalid_port() {
	for port in [0, -1, 65536] {
		path := write_tmp('server_port_${port}', 'bind_port = ${port}')
		defer {
			os.rm(path) or {}
		}
		err := server_err(path)
		assert err.contains('bind_port'), 'expected bind_port error for ${port}, got: ${err}'
		assert err.contains('1-65535'), 'expected range hint for ${port}, got: ${err}'
	}
}

fn test_server_config_missing_file() {
	path := os.join_path(os.temp_dir(), 'vfrp_no_such_file_${os.getpid()}.toml')
	err := server_err(path)
	assert err.contains('cannot read config file'), 'got: ${err}'
}

fn test_server_config_invalid_toml() {
	path := write_tmp('server_bad_toml', 'bind_port = x')
	defer {
		os.rm(path) or {}
	}
	err := server_err(path)
	assert err.contains('invalid TOML'), 'got: ${err}'
}

fn test_client_config_valid() {
	path := write_tmp('client_valid', client_toml)
	defer {
		os.rm(path) or {}
	}
	cfg := load_client_config(path) or { panic(err.msg()) }
	assert cfg.server_addr == '127.0.0.1'
	assert cfg.server_port == 7000
	assert cfg.auth_token == 's3cret'
	assert cfg.pool_count == 2
	assert cfg.heartbeat_interval == 30
	assert cfg.proxies.len == 2
	assert cfg.proxies[0].name == 'ssh'
	assert cfg.proxies[0].type == 'tcp'
	assert cfg.proxies[0].local_ip == '127.0.0.1' // 默认值
	assert cfg.proxies[0].local_port == 22
	assert cfg.proxies[0].remote_port == 6000
	assert cfg.proxies[1].name == 'dns'
	assert cfg.proxies[1].type == 'udp'
	assert cfg.proxies[1].local_ip == '10.0.0.2'
	assert cfg.proxies[1].local_port == 53
	assert cfg.proxies[1].remote_port == 6001
}

fn test_client_config_defaults() {
	path := write_tmp('client_defaults', 'server_addr = "127.0.0.1"')
	defer {
		os.rm(path) or {}
	}
	cfg := load_client_config(path) or { panic(err.msg()) }
	assert cfg.server_addr == '127.0.0.1'
	assert cfg.server_port == 7000
	assert cfg.auth_token == ''
	assert cfg.pool_count == 0
	assert cfg.heartbeat_interval == 30
	assert cfg.proxies.len == 0
}

fn test_client_config_invalid_server_port() {
	path := write_tmp('client_port_0', '
server_addr = "127.0.0.1"
server_port = 0
')
	defer {
		os.rm(path) or {}
	}
	err := client_err(path)
	assert err.contains('server_port'), 'got: ${err}'
	assert err.contains('1-65535'), 'got: ${err}'
}

fn test_client_config_missing_server_addr() {
	path := write_tmp('client_no_addr', 'server_port = 7000')
	defer {
		os.rm(path) or {}
	}
	err := client_err(path)
	assert err.contains('server_addr must not be empty'), 'got: ${err}'
}

fn test_proxy_missing_name() {
	path := write_tmp('proxy_no_name', '
server_addr = "127.0.0.1"

[[proxies]]
type = "tcp"
local_port = 22
remote_port = 6000
')
	defer {
		os.rm(path) or {}
	}
	err := client_err(path)
	assert err.contains('missing required field "name"'), 'got: ${err}'
	assert err.contains('proxies[0]'), 'got: ${err}'
}

fn test_proxy_missing_type() {
	path := write_tmp('proxy_no_type', '
server_addr = "127.0.0.1"

[[proxies]]
name = "ssh"
local_port = 22
remote_port = 6000
')
	defer {
		os.rm(path) or {}
	}
	err := client_err(path)
	assert err.contains('missing required field "type"'), 'got: ${err}'
}

fn test_proxy_missing_local_port() {
	path := write_tmp('proxy_no_local_port', '
server_addr = "127.0.0.1"

[[proxies]]
name = "ssh"
type = "tcp"
remote_port = 6000
')
	defer {
		os.rm(path) or {}
	}
	err := client_err(path)
	assert err.contains('missing required field "local_port"'), 'got: ${err}'
}

fn test_proxy_missing_remote_port() {
	path := write_tmp('proxy_no_remote_port', '
server_addr = "127.0.0.1"

[[proxies]]
name = "ssh"
type = "tcp"
local_port = 22
')
	defer {
		os.rm(path) or {}
	}
	err := client_err(path)
	assert err.contains('missing required field "remote_port"'), 'got: ${err}'
}

fn test_proxy_invalid_ports() {
	for port in [65536, -1] {
		path := write_tmp('proxy_port_${port}', '
server_addr = "127.0.0.1"

[[proxies]]
name = "ssh"
type = "tcp"
local_port = ${port}
remote_port = 6000
')
		defer {
			os.rm(path) or {}
		}
		err := client_err(path)
		assert err.contains('local_port'), 'expected local_port error for ${port}, got: ${err}'
		assert err.contains('1-65535'), 'expected range hint for ${port}, got: ${err}'
	}
}

fn test_proxy_unknown_type() {
	path := write_tmp('proxy_unknown_type', '
server_addr = "127.0.0.1"

[[proxies]]
name = "web"
type = "sctp"
local_port = 80
remote_port = 8080
')
	defer {
		os.rm(path) or {}
	}
	err := client_err(path)
	assert err.contains('unknown proxy type "sctp"'), 'got: ${err}'
	assert err.contains('proxies[0]'), 'expected position hint, got: ${err}'
}

// stcp 代理：合法配置（带 sk/allow_users，无 remote_port）通过校验。
fn test_proxy_stcp_valid() {
	path := write_tmp('proxy_stcp_valid', '
server_addr = "127.0.0.1"

[[proxies]]
name = "ssh-stcp"
type = "stcp"
local_ip = "127.0.0.1"
local_port = 22
sk = "shared-secret"
allow_users = ["alice", "bob"]
')
	defer {
		os.rm(path) or {}
	}
	cfg := load_client_config(path) or { panic(err.msg()) }
	assert cfg.proxies.len == 1
	assert cfg.proxies[0].type == 'stcp'
	assert cfg.proxies[0].sk == 'shared-secret'
	assert cfg.proxies[0].allow_users == ['alice', 'bob']
	assert cfg.proxies[0].local_port == 22
	assert cfg.proxies[0].remote_port == 0 // stcp 不要求 remote_port
}

// stcp 代理缺 sk → 报错；提示信息含位置和字段名。
fn test_proxy_stcp_missing_sk() {
	path := write_tmp('proxy_stcp_no_sk', '
server_addr = "127.0.0.1"

[[proxies]]
name = "ssh-stcp"
type = "stcp"
local_port = 22
')
	defer {
		os.rm(path) or {}
	}
	err := client_err(path)
	assert err.contains('proxies[0]'), 'expected position hint, got: ${err}'
	assert err.contains('"ssh-stcp"'), 'expected proxy name in error, got: ${err}'
	assert err.contains('(stcp)'), 'expected stcp tag in error, got: ${err}'
	assert err.contains('"sk"'), 'expected sk field in error, got: ${err}'
}

// stcp 代理缺 local_port → 报错（与 tcp 行为一致）。
fn test_proxy_stcp_missing_local_port() {
	path := write_tmp('proxy_stcp_no_port', '
server_addr = "127.0.0.1"

[[proxies]]
name = "ssh-stcp"
type = "stcp"
sk = "shared-secret"
')
	defer {
		os.rm(path) or {}
	}
	err := client_err(path)
	assert err.contains('"ssh-stcp"'), 'got: ${err}'
	assert err.contains('"local_port"'), 'got: ${err}'
}

// visitor 缺 secret_key → 报错。
fn test_visitor_missing_secret_key() {
	path := write_tmp('visitor_no_sk', '
server_addr = "127.0.0.1"

[[visitors]]
name = "v1"
type = "stcp"
server_name = "ssh-stcp"
bind_port = 6000
')
	defer {
		os.rm(path) or {}
	}
	err := client_err(path)
	assert err.contains('visitors[0]'), 'expected position hint, got: ${err}'
	assert err.contains('"v1"'), 'expected visitor name in error, got: ${err}'
	assert err.contains('"secret_key"'), 'expected secret_key field, got: ${err}'
}

// visitor 类型非 stcp → 报错。
fn test_visitor_unknown_type() {
	path := write_tmp('visitor_bad_type', '
server_addr = "127.0.0.1"

[[visitors]]
name = "v1"
type = "xtcp"
server_name = "ssh-stcp"
secret_key = "shared-secret"
bind_port = 6000
')
	defer {
		os.rm(path) or {}
	}
	err := client_err(path)
	assert err.contains('unknown visitor type "xtcp"'), 'got: ${err}'
	assert err.contains('want stcp'), 'got: ${err}'
}

// visitor bind_port 越界 → 报错（走 check_port）。
fn test_visitor_invalid_bind_port() {
	path := write_tmp('visitor_bad_port', '
server_addr = "127.0.0.1"

[[visitors]]
name = "v1"
type = "stcp"
server_name = "ssh-stcp"
secret_key = "shared-secret"
bind_port = 70000
')
	defer {
		os.rm(path) or {}
	}
	err := client_err(path)
	assert err.contains('bind_port'), 'got: ${err}'
	assert err.contains('1-65535'), 'got: ${err}'
}

// 合法配置（含 [[visitors]] 数组）完整解析。
fn test_client_config_with_visitors() {
	path := write_tmp('client_visitors', '
server_addr = "127.0.0.1"
server_port = 7000
auth_token = "tok"

[[proxies]]
name = "ssh-stcp"
type = "stcp"
local_port = 22
sk = "shared-secret"

[[visitors]]
name = "v-ssh"
type = "stcp"
server_name = "ssh-stcp"
server_user = "alice"
secret_key = "shared-secret"
bind_addr = "127.0.0.1"
bind_port = 6000
')
	defer {
		os.rm(path) or {}
	}
	cfg := load_client_config(path) or { panic(err.msg()) }
	assert cfg.proxies.len == 1
	assert cfg.visitors.len == 1
	assert cfg.visitors[0].name == 'v-ssh'
	assert cfg.visitors[0].type == 'stcp'
	assert cfg.visitors[0].server_name == 'ssh-stcp'
	assert cfg.visitors[0].server_user == 'alice'
	assert cfg.visitors[0].secret_key == 'shared-secret'
	assert cfg.visitors[0].bind_addr == '127.0.0.1'
	assert cfg.visitors[0].bind_port == 6000
}

// visitor 缺 name → 报错（含位置）。
fn test_visitor_missing_name() {
	path := write_tmp('visitor_no_name', '
server_addr = "127.0.0.1"

[[visitors]]
type = "stcp"
server_name = "ssh-stcp"
secret_key = "k"
bind_port = 6000
')
	defer {
		os.rm(path) or {}
	}
	err := client_err(path)
	assert err.contains('visitors[0]'), 'got: ${err}'
	assert err.contains('"name"'), 'got: ${err}'
}

// visitor 缺 server_name → 报错。
fn test_visitor_missing_server_name() {
	path := write_tmp('visitor_no_srv', '
server_addr = "127.0.0.1"

[[visitors]]
name = "v1"
type = "stcp"
secret_key = "k"
bind_port = 6000
')
	defer {
		os.rm(path) or {}
	}
	err := client_err(path)
	assert err.contains('"v1"'), 'got: ${err}'
	assert err.contains('"server_name"'), 'got: ${err}'
}

fn test_client_config_empty_proxies() {
	path := write_tmp('client_no_proxies', '
server_addr = "127.0.0.1"
server_port = 7000
')
	defer {
		os.rm(path) or {}
	}
	cfg := load_client_config(path) or { panic(err.msg()) }
	assert cfg.server_addr == '127.0.0.1'
	assert cfg.proxies.len == 0
}

fn test_server_config_valid_scopes() {
	path := write_tmp('server_scopes', '
auth_additional_scopes = ["HeartBeats", "NewWorkConns"]
')
	defer {
		os.rm(path) or {}
	}
	cfg := load_server_config(path) or { panic(err.msg()) }
	assert cfg.auth_additional_scopes.len == 2
	assert cfg.auth_additional_scopes[0] == 'HeartBeats'
	assert cfg.auth_additional_scopes[1] == 'NewWorkConns'
}

fn test_server_config_invalid_scope() {
	for scope in ['Heartbeat', 'heartbeats', 'Ping', ''] {
		path := write_tmp('server_scope_${scope}', 'auth_additional_scopes = ["${scope}"]')
		defer {
			os.rm(path) or {}
		}
		err := server_err(path)
		assert err.contains('auth_additional_scopes'), 'expected scope error for "${scope}", got: ${err}'
		assert err.contains('HeartBeats'), 'expected hint in error for "${scope}", got: ${err}'
	}
}

fn test_client_config_invalid_scope() {
	path := write_tmp('client_scope_bad', '
server_addr = "127.0.0.1"
auth_additional_scopes = ["NewWorkConn"]
')
	defer {
		os.rm(path) or {}
	}
	err := client_err(path)
	assert err.contains('auth_additional_scopes'), 'got: ${err}'
	assert err.contains('NewWorkConns'), 'got: ${err}'
}

fn test_server_config_valid_allow_ports() {
	path := write_tmp('server_allow_ports', 'allow_ports = ["2000-3000", "3001"]')
	defer {
		os.rm(path) or {}
	}
	cfg := load_server_config(path) or { panic(err.msg()) }
	assert cfg.allow_ports.len == 2
	assert cfg.allow_ports[0] == '2000-3000'
	assert cfg.allow_ports[1] == '3001'
}

fn test_server_config_invalid_allow_ports() {
	// end < start
	for entry in ['3000-2000', '1-0', '0-1'] {
		path := write_tmp('allow_ports_bad_${entry}', 'allow_ports = ["${entry}"]')
		defer {
			os.rm(path) or {}
		}
		err := server_err(path)
		assert err.contains('allow_ports'), 'expected allow_ports error for "${entry}", got: ${err}'
	}
	// 越界
	for entry in ['65536', '0', '-1'] {
		path := write_tmp('allow_ports_out_${entry}', 'allow_ports = ["${entry}"]')
		defer {
			os.rm(path) or {}
		}
		err := server_err(path)
		assert err.contains('allow_ports'), 'expected allow_ports error for "${entry}", got: ${err}'
	}
	// 非数字 / 多段
	for entry in ['abc', '1-2-3', '2000-3000,4000'] {
		path := write_tmp('allow_ports_weird_${entry}', 'allow_ports = ["${entry}"]')
		defer {
			os.rm(path) or {}
		}
		err := server_err(path)
		assert err.contains('allow_ports'), 'expected allow_ports error for "${entry}", got: ${err}'
	}
}
