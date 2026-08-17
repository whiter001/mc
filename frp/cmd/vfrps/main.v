// vfrps 服务端入口：解析 -c 配置（默认 vfrps.toml），启动 Service。
module main

import os
import flag
import pkg.config
import pkg.util.log
import pkg.util.version
import server

fn main() {
	mut fp := flag.new_flag_parser(os.args)
	fp.application('vfrps')
	fp.version(version.version)
	fp.description('vfrps - frp server rewritten in V (module vfrp)')
	fp.skip_executable()
	config_path := fp.string('c', `c`, 'vfrps.toml', 'path of server config file (TOML)')
	fp.finalize() or {
		log.error('vfrps: ${err.msg()}')
		exit(1)
	}

	cfg := config.load_server_config(config_path) or {
		log.error('vfrps: failed to load config "${config_path}": ${err.msg()}')
		exit(1)
	}

	mut svr := server.new_service(cfg)
	svr.run() or {
		log.error('vfrps: exited with error: ${err.msg()}')
		exit(1)
	}
	log.info('vfrps exited')
}
