// vfrpc：frp 客户端（V 语言重写）。
// 用法：vfrpc [-c vfrpc.toml]
// 读取客户端配置 → 启动 Service（登录、注册代理、心跳、断线重连）。
// 注：不用 vlib flag 模块——V 0.5.2 中 `import flag` 与 `import toml` 同现会
// 导致编译产物运行时 toml 解析出错（token kind 越界），改用极简手工参数解析。
module main

import os
import client
import pkg.config
import pkg.util.log
import pkg.util.version

fn usage() {
	eprintln('vfrpc ${version.version} - frp client rewritten in V (module vfrp)')
	eprintln('usage: vfrpc [-c config.toml]')
	eprintln('  -c <path>   path of the client config file (TOML, default "vfrpc.toml")')
	eprintln('  --version   print version and exit')
	eprintln('  -h, --help  show this help and exit')
}

// parse_args 解析命令行参数，返回配置文件路径。
// 支持 `-c <path>` / `-c=<path>`、`--version`、`-h/--help`；未知参数直接报错退出。
fn parse_args() string {
	mut config_path := 'vfrpc.toml'
	mut args := os.args[1..].clone()
	for i := 0; i < args.len; i++ {
		match args[i] {
			'-c' {
				if i + 1 >= args.len {
					eprintln('vfrpc: missing value after -c')
					usage()
					exit(1)
				}
				config_path = args[i + 1]
				i++
			}
			'--version' {
				println(version.version)
				exit(0)
			}
			'-h', '--help' {
				usage()
				exit(0)
			}
			else {
				if args[i].starts_with('-c=') {
					// 兼容旧用法 `-c=<path>`
					config_path = args[i].all_after('-c=')
					if config_path == '' {
						eprintln('vfrpc: missing value after -c=')
						usage()
						exit(1)
					}
				} else {
					eprintln('vfrpc: unexpected argument: ${args[i]}')
					usage()
					exit(1)
				}
			}
		}
	}
	return config_path
}

fn main() {
	config_path := parse_args()

	cfg := config.load_client_config(config_path) or {
		log.error('load config failed: ${err.msg()}')
		exit(1)
	}
	log.info('client starting, server ${cfg.server_addr}:${cfg.server_port}, ${cfg.proxies.len} proxy(ies)')
	mut svc := client.new_service(cfg)
	svc.run()
}
