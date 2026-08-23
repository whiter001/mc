// 客户端服务主循环：登录、代理注册、心跳、断线重连（指数退避）。
// 流程（plan.md §2）：
// 拨号 → Login（token 派生 privilege_key + timestamp + run_id）→ LoginResp
// → spawn 心跳循环 → 注册所有代理（NewProxy）→ 控制读循环；
// 读循环出错 → 关闭会话 → 指数退避（1s→2s→…→上限 30s）→ 重新登录注册。
module client

import os
import rand
import time
import pkg.config
import pkg.msg
import pkg.auth
import pkg.util.log
import pkg.util.version

// max_backoff 重连指数退避上限（秒）。
const max_backoff = 30

// Service 客户端服务：管理与 frps 的会话生命周期（登录、心跳、重连）。
pub struct Service {
pub:
	cfg config.ClientConfig
}

// new_service 用已加载的配置构造客户端服务。
pub fn new_service(cfg config.ClientConfig) Service {
	return Service{
		cfg: cfg
	}
}

// run 主循环，持续运行直到进程退出（Ctrl-C / kill 终止）。
pub fn (mut svc Service) run() {
	mut backoff := 1
	// 首次会话生成 run_id；登录成功后由 LoginResp 记录实际 run_id，
	// 之后断线重连复用同一个 run_id（对齐 Go 版 svr.runID 语义：同一客户端
	// 重连保持 run_id 不变，服务端 register_control 的"同 run_id 踢旧"才能生效）。
	mut run_id := rand.hex(16)
	for {
		mut ctl := new_control(svc.cfg, run_id) or {
			log.error('connect to server failed: ${err.msg()}, retry in ${backoff}s')
			time.sleep(backoff * time.second)
			backoff = next_backoff(backoff)
			continue
		}
		login(mut ctl) or {
			log.error('login failed: ${err.msg()}, retry in ${backoff}s')
			ctl.close()
			time.sleep(backoff * time.second)
			backoff = next_backoff(backoff)
			continue
		}
		// login() 内已用 LoginResp 回显的 run_id 覆盖 ctl.run_id；这里记录到
		// run_id 变量，供下一次重连复用。
		run_id = ctl.run_id
		backoff = 1
		log.info('login to server success, run id: ${run_id}')
		svc.register_proxies(mut ctl) or {
			log.error('register proxies failed: ${err.msg()}, retry in ${backoff}s')
			ctl.close()
			time.sleep(backoff * time.second)
			backoff = next_backoff(backoff)
			continue
		}
		log.info('all proxies registered, entering control read loop')
		// 心跳循环与读循环并发运行；心跳写走 write_mu，读循环独占读
		interval := svc.cfg.heartbeat_interval
		spawn heartbeat_loop(ctl, interval)
		// P5: 预建 work conn 池。pool_count 条 work conn 预先 dial + 发 NewWorkConn，
		// 蹲在 server 的 work_conns 队列里；用户连接时 server 立即从队列取，
		// 省去 dial+auth 等待。handle_work_conn 内部已处理连接失败路径。
		// 取 cfg by value（与 read_loop 的 ReqWorkConn 分支同型），spawn 不会捕获栈地址。
		pool_count := svc.cfg.pool_count
		if pool_count > 0 {
			log.info('pre-warming work conn pool: ${pool_count} conns')
			for _ in 0 .. pool_count {
				spawn handle_work_conn(svc.cfg, run_id)
			}
		}
		ctl.read_loop() or {
			ctl.stop()
			ctl.close()
			log.error('control connection lost: ${err.msg()}, retry in ${backoff}s')
			time.sleep(backoff * time.second)
			backoff = next_backoff(backoff)
		}
	}
}

// register_proxies 为配置中的每个代理发送 NewProxy 注册消息。
// udp 代理在 work conn 阶段跳过（P6 支持），此处照常注册，服务端自会处理。
fn (mut svc Service) register_proxies(mut ctl Control) ! {
	for p in svc.cfg.proxies {
		ctl.write_msg(msg.NewProxy{
			proxy_name:     p.name
			proxy_type:     p.type
			remote_port:    p.remote_port
			custom_domains: p.custom_domains
			subdomain:      p.subdomain
			subdomain_host: p.subdomain_host
		}) or { return error('register proxy "${p.name}" failed: ${err.msg()}') }
		log.info('registering proxy "${p.name}" (${p.type}), remote port: ${p.remote_port}')
	}
}

// login 发送 Login（token 派生 privilege_key + 系统信息 + run_id）并等待 LoginResp。
fn login(mut ctl Control) ! {
	ts := time.now().unix()
	ctl.write_msg(msg.Login{
		version:       version.version
		hostname:      hostname()
		os:            os_name()
		arch:          arch_name()
		user:          username()
		privilege_key: auth.new_privilege_key(ctl.cfg.auth_token, ts)
		timestamp:     ts
		run_id:        ctl.run_id
		pool_count:    ctl.cfg.pool_count
	})!
	resp := ctl.read_login_resp()!
	if resp.error != '' {
		return error('login rejected by server: ${resp.error}')
	}
	// 记录服务端回显/生成的 run_id：重连时复用（对齐 Go 版 login 后
	// sessionCtx.RunID → svr.runID 的语义）。
	if resp.run_id != '' {
		ctl.run_id = resp.run_id
	}
}

// heartbeat_loop 每隔 interval 秒发一次 Ping。默认不携带认证字段；
// 仅当配置 auth_additional_scopes 含 "HeartBeats" 时携带 token 派生 privilege_key
// 与 timestamp（对齐 Go 版 TokenAuth.SetPing）。
// 写控制连接走 write_mu（与注册等写操作互斥）；会话被 stop 后退出。
// 参数不带 mut：spawn 传参 `mut x &T` 会捕获调用方栈地址（原因见 netx.copy_one_way 注释）。
fn heartbeat_loop(ctl &Control, interval int) {
	if interval <= 0 {
		return
	}
	mut c := ctl
	need_auth := auth.has_scope(c.cfg.auth_additional_scopes, 'HeartBeats')
	for {
		time.sleep(interval * time.second)
		if c.is_stopped() {
			return
		}
		mut ping := msg.Ping{}
		if need_auth {
			ts := time.now().unix()
			ping.privilege_key = auth.new_privilege_key(c.cfg.auth_token, ts)
			ping.timestamp = ts
		}
		c.write_msg(ping) or {
			log.warn('heartbeat: send ping failed: ${err.msg()}')
			// 连接已坏，读循环会感知并触发重连；这里继续循环等 stop
			continue
		}
		log.debug('heartbeat: ping sent')
	}
}

// next_backoff 计算下一次退避时长（秒），1→2→…→上限 max_backoff。
fn next_backoff(cur int) int {
	if cur >= max_backoff {
		return max_backoff
	}
	return cur * 2
}

// hostname / os_name / arch_name / username 组装 Login 的系统信息字段。
fn hostname() string {
	return os.hostname() or { '' }
}

fn os_name() string {
	return os.user_os()
}

// arch_name 把 uname 的 machine 归一化为 Go 版的 GOARCH 写法。
fn arch_name() string {
	machine := os.uname().machine
	return match machine {
		'x86_64' { 'amd64' }
		'aarch64' { 'arm64' }
		else { machine }
	}
}

fn username() string {
	return os.getenv('USER')
}
