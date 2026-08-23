// vfrps 服务端入口：解析 -c 配置（默认 vfrps.toml），启动 Service。
// 注：不用 vlib flag 模块——V 0.5.2 中 `import flag` 与 `import toml` 同现会
// 导致编译产物运行时 toml 解析出错（token kind 越界），改用极简手工参数解析。
module main

import os
import server
import pkg.config
import pkg.util.log
import pkg.util.version

fn usage() {
	eprintln('vfrps ${version.version} - frp server rewritten in V (module vfrp)')
	eprintln('usage: vfrps [-c config.toml]')
	eprintln('  -c <path>   path of server config file (TOML, default "vfrps.toml")')
	eprintln('  --version   print version and exit')
	eprintln('  -h, --help  show this help and exit')
}

// parse_args 解析命令行参数，返回配置文件路径。
// 支持 `-c <path>` / `-c=<path>`、`--version`、`-h/--help`；未知参数直接报错退出。
fn parse_args() string {
	mut config_path := 'vfrps.toml'
	mut args := os.args[1..].clone()
	for i := 0; i < args.len; i++ {
		match args[i] {
			'-c' {
				if i + 1 >= args.len {
					eprintln('vfrps: missing value after -c')
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
						eprintln('vfrps: missing value after -c=')
						usage()
						exit(1)
					}
				} else {
					eprintln('vfrps: unexpected argument: ${args[i]}')
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
