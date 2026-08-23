module config

import os
import toml

// load_server_config 读取服务端 TOML 配置并返回：
// 读文件 → toml 解析 → 填默认值（结构体字段默认值）→ 校验。
pub fn load_server_config(path string) !ServerConfig {
	text := read_config_file(path)!
	cfg := toml.decode[ServerConfig](text) or {
		return error('invalid TOML in "${path}": ${err.msg()}')
	}
	cfg.validate()!
	return cfg
}

// load_client_config 读取客户端 TOML 配置并返回：
// 读文件 → toml 解析 → 填默认值（结构体字段默认值）→ 校验。
pub fn load_client_config(path string) !ClientConfig {
	text := read_config_file(path)!
	cfg := toml.decode[ClientConfig](text) or {
		return error('invalid TOML in "${path}": ${err.msg()}')
	}
	cfg.validate()!
	return cfg
}

fn read_config_file(path string) !string {
	return os.read_file(path) or { return error('cannot read config file "${path}": ${err.msg()}') }
}

// check_port 校验端口范围 1-65535，field 用于生成可读的错误信息。
fn check_port(port int, field string) ! {
	if port < 1 || port > 65535 {
		return error('invalid ${field}: ${port}, want 1-65535')
	}
}

// is_digits 判断字符串是否全为十进制数字（allow_ports 解析用，
// 避免 V 的 string.int() 对 "12abc" 这类串只解析前导数字导致误放行）。
fn is_digits(s string) bool {
	if s.len == 0 {
		return false
	}
	for c in s {
		if c < `0` || c > `9` {
			return false
		}
	}
	return true
}

// validate_auth_scopes 校验 auth_additional_scopes 取值，只能为 Go 版
// v1.AuthScope 常量 "HeartBeats" / "NewWorkConns"（大小写敏感）。
fn validate_auth_scopes(scopes []string, where string) ! {
	for s in scopes {
		if s != 'HeartBeats' && s != 'NewWorkConns' {
			return error('${where}: invalid auth_additional_scopes value "${s}", want "HeartBeats" or "NewWorkConns"')
		}
	}
}

// validate_allow_ports 校验 allow_ports 每项格式：单端口或 start-end 区间，
// 端口范围 1-65535 且 end >= start。
// pub：server 模块的 new_port_manager 复用本校验，避免两套解析器行为漂移
//（见 server/ports.v parse_allow_ports）。
pub fn validate_allow_ports(ports []string) ! {
	for p in ports {
		entry := p.trim_space()
		if entry == '' {
			return error('allow_ports: empty entry')
		}
		if entry.contains('-') {
			parts := entry.split('-')
			if parts.len != 2 || !is_digits(parts[0].trim_space()) || !is_digits(parts[1].trim_space()) {
				return error('allow_ports: invalid range "${p}", want single port or start-end')
			}
			start := parts[0].trim_space().int()
			end := parts[1].trim_space().int()
			check_port(start, 'allow_ports "${p}" start')!
			check_port(end, 'allow_ports "${p}" end')!
			if end < start {
				return error('allow_ports: invalid range "${p}", end < start')
			}
		} else {
			if !is_digits(entry) {
				return error('allow_ports: invalid port "${p}", want 1-65535')
			}
			check_port(entry.int(), 'allow_ports "${p}"')!
		}
	}
}

fn (cfg ServerConfig) validate() ! {
	check_port(cfg.bind_port, 'bind_port')!
	if cfg.bind_addr == '' {
		return error('bind_addr must not be empty')
	}
	// vhost_http_port == 0 表示不开；非 0 时校验范围
	if cfg.vhost_http_port != 0 {
		check_port(cfg.vhost_http_port, 'vhost_http_port')!
	}
	validate_auth_scopes(cfg.auth_additional_scopes, 'server')!
	validate_allow_ports(cfg.allow_ports)!
}

fn (cfg ClientConfig) validate() ! {
	if cfg.server_addr == '' {
		return error('server_addr must not be empty')
	}
	check_port(cfg.server_port, 'server_port')!
	validate_auth_scopes(cfg.auth_additional_scopes, 'client')!
	for i, p in cfg.proxies {
		p.validate(i)!
	}
}

// validate 校验单条代理规则：name/type/local_port/remote_port 必填；
// type 取 tcp/udp/http。tcp/udp 需 remote_port，http 需 custom_domains 与
// subdomain 至少一个（subdomain 须配合 subdomain_host）。idx 用于错误信息定位。
fn (p ProxyConfig) validate(idx int) ! {
	where := 'proxies[${idx}]'
	if p.name == '' {
		return error('${where}: missing required field "name"')
	}
	if p.type == '' {
		return error('${where} "${p.name}": missing required field "type"')
	}
	match p.type {
		'tcp', 'udp' {
			if p.local_port == 0 {
				return error('${where} "${p.name}": missing required field "local_port"')
			}
			if p.remote_port == 0 {
				return error('${where} "${p.name}": missing required field "remote_port"')
			}
			check_port(p.local_port, '${where} "${p.name}" local_port')!
			check_port(p.remote_port, '${where} "${p.name}" remote_port')!
		}
		'http' {
			if p.local_port == 0 {
				return error('${where} "${p.name}": missing required field "local_port"')
			}
			if p.custom_domains.len == 0 && p.subdomain == '' {
				return error('${where} "${p.name}" (http): need custom_domains or subdomain')
			}
			if p.subdomain != '' && p.subdomain_host == '' {
				return error('${where} "${p.name}" (http): subdomain requires subdomain_host')
			}
			check_port(p.local_port, '${where} "${p.name}" local_port')!
		}
		else {
			return error('${where} "${p.name}": unknown proxy type "${p.type}", want tcp/udp/http')
		}
	}
}
