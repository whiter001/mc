// vfrpc：frp 客户端（V 语言重写）。
// 用法：vfrpc [-c vfrpc.toml]
// 读取客户端配置 → 启动 Service（登录、注册代理、心跳、断线重连）。
module main

import os
import flag
import client
import pkg.config
import pkg.util.log
import pkg.util.version

fn main() {
	mut fp := flag.new_flag_parser(os.args)
	fp.application('vfrpc')
	fp.version(version.version)
	fp.description('frp client: expose local services through a frp server')
	fp.skip_executable()
	cfg_path :=
		fp.string('c', `c`, 'vfrpc.toml', 'path of the client config file', flag.FlagConfig{})
	rest := fp.finalize() or {
		eprintln(err.msg())
		println(fp.usage())
		exit(1)
	}
	if rest.len > 0 {
		eprintln('unexpected arguments: ${rest}')
		println(fp.usage())
		exit(1)
	}

	cfg := config.load_client_config(cfg_path) or {
		log.error('load config failed: ${err.msg()}')
		exit(1)
	}
	log.info('client starting, server ${cfg.server_addr}:${cfg.server_port}, ${cfg.proxies.len} proxy(ies)')
	mut svc := client.new_service(cfg)
	svc.run()
}
