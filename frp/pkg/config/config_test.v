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
type = "http"
local_port = 80
remote_port = 8080
')
	defer {
		os.rm(path) or {}
	}
	err := client_err(path)
	assert err.contains('unknown proxy type "http"'), 'got: ${err}'
	assert err.contains('proxies[0]'), 'expected position hint, got: ${err}'
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
