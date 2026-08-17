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

fn (cfg ServerConfig) validate() ! {
	check_port(cfg.bind_port, 'bind_port')!
	if cfg.bind_addr == '' {
		return error('bind_addr must not be empty')
	}
}

fn (cfg ClientConfig) validate() ! {
	if cfg.server_addr == '' {
		return error('server_addr must not be empty')
	}
	check_port(cfg.server_port, 'server_port')!
	for i, p in cfg.proxies {
		p.validate(i)!
	}
}

// validate 校验单条代理规则：name/type/local_port/remote_port 必填，
// type 只接受 tcp/udp，端口须在 1-65535。idx 用于错误信息定位。
fn (p ProxyConfig) validate(idx int) ! {
	where := 'proxies[${idx}]'
	if p.name == '' {
		return error('${where}: missing required field "name"')
	}
	if p.type == '' {
		return error('${where} "${p.name}": missing required field "type"')
	}
	if p.type != 'tcp' && p.type != 'udp' {
		return error('${where} "${p.name}": unknown proxy type "${p.type}", want "tcp" or "udp"')
	}
	if p.local_port == 0 {
		return error('${where} "${p.name}": missing required field "local_port"')
	}
	if p.remote_port == 0 {
		return error('${where} "${p.name}": missing required field "remote_port"')
	}
	check_port(p.local_port, '${where} "${p.name}" local_port')!
	check_port(p.remote_port, '${where} "${p.name}" remote_port')!
}
