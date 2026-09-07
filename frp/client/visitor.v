// 客户端 visitor：stcp 访问端。每条 [[visitors]] 配置起一个本地 TCP 监听器；
// 用户连接进来后拨一条到 vfrps 的连接，发 NewVisitorConn 拿 NewVisitorConnResp，
// 同意后由 netx.relay 双向转发。
// 流程（对齐 Go 版 frp client/visitor/stcp.go）：
// listen(bind_addr:bind_port) → accept_loop → 对每条 user_conn：
//   dial(server) → write_msg(NewVisitorConn{run_id, proxy_name, sign_key, ts})
//   → set_read_deadline(10s) + read_msg 等 NewVisitorConnResp
//   → resp.error 非空 → log warn + close 两条；否则 relay(user_conn, visitor_conn)
// 生命周期绑定当前登录会话：read_loop 出错时由 Service 关闭 listener，
// 重连后随新会话重新监听（run_id 不变，配合服务端"同 run_id 踢旧"）。
module client

import net
import sync
import time
import pkg.config
import pkg.msg
import pkg.auth
import pkg.util.netx
import pkg.util.log

// visitor_resp_timeout 等待 NewVisitorConnResp 的超时（秒），对齐 Go 版 stcp visitor 默认 10s。
const visitor_resp_timeout = 10 * time.second

// Visitor 一条 visitor 配置对应的运行时：本地监听器 + 关闭标志。
// listener 字段在 run() 之前为 nil（unsafe { nil } 初始化）；run() 失败时保持 nil，
// close() 需对此做空检查。
pub struct Visitor {
pub:
	cfg         config.VisitorConfig
	server_addr string
	server_port int
	run_id      string
mut:
	listener &net.TcpListener = unsafe { nil }
	close_mu sync.Mutex
	closed   bool
}

// new_visitor 用配置构造 visitor 实例（堆分配，跨线程共享）。
fn new_visitor(cfg config.VisitorConfig, server_addr string, server_port int, run_id string) &Visitor {
	return &Visitor{
		cfg: cfg
		server_addr: server_addr
		server_port: server_port
		run_id: run_id
		close_mu: sync.new_mutex()
	}
}

// run 启动本地监听并 spawn accept 循环。
// 监听失败返回错误（调用方记日志决定生死）；accept 循环在 listener 被 close 时安静退出。
fn (mut v Visitor) run() ! {
	addr := netx.join_host_port(v.cfg.bind_addr, v.cfg.bind_port)
	l := net.listen_tcp(.ip, addr) or {
		return error('visitor "${v.cfg.name}" listen on ${addr} failed: ${err.msg()}')
	}
	v.listener = l
	log.info('visitor "${v.cfg.name}" (type=${v.cfg.type}) listening on ${addr}')
	spawn v.accept_loop()
}

// accept_loop 循环 accept；每条连接 spawn 一个 handle_conn 线程。
// listener 被 close 后 accept 返回错误，此时 is_closed() 为 true → 安静 return。
fn (mut v Visitor) accept_loop() {
	for {
		conn := v.listener.accept() or {
			if !v.is_closed() {
				log.warn('visitor "${v.cfg.name}" accept error: ${err.msg()}')
			}
			return
		}
		spawn v.handle_conn(conn)
	}
}

// handle_conn 处理一条 user_conn 的完整生命周期：
// dial server → 发 NewVisitorConn（带 sign_key）→ 10s 超时等 NewVisitorConnResp
// → resp.error 非空 → log warn + close 两条；否则 netx.relay 接管。
// 参数不带 mut（spawn 传参 `mut x &T` 会捕获调用方栈地址悬垂，详见 netx.copy_one_way 注释）。
// 注意：accept 返回的 conn 类型是 &TcpConn；spawn / 参数传递需 &TcpConn（非 mut）。
fn (mut v Visitor) handle_conn(user_conn &net.TcpConn) {
	mut uc := user_conn
	server_addr := netx.join_host_port(v.server_addr, v.server_port)
	mut vc := net.dial_tcp(server_addr) or {
		log.warn('visitor "${v.cfg.name}": dial server ${server_addr} failed: ${err.msg()}')
		uc.close() or {}
		return
	}
	ts := time.now().unix()
	msg.write_msg(mut vc, msg.NewVisitorConn{
		run_id: v.run_id
		proxy_name: v.cfg.server_name
		sign_key: auth.new_privilege_key(v.cfg.secret_key, ts)
		timestamp: ts
	}) or {
		log.warn('visitor "${v.cfg.name}": write NewVisitorConn failed: ${err.msg()}')
		vc.close() or {}
		uc.close() or {}
		return
	}
	vc.set_read_deadline(time.now().add(visitor_resp_timeout))
	m := msg.read_msg(mut vc) or {
		log.warn('visitor "${v.cfg.name}": wait NewVisitorConnResp failed: ${err.msg()}')
		vc.close() or {}
		uc.close() or {}
		return
	}
	// NewVisitorConnResp 已收：清读超时，后续生命周期交给 relay（EOF 决定关闭）
	vc.set_read_deadline(time.unix(0))
	mut resp := msg.NewVisitorConnResp{}
	match m {
		msg.NewVisitorConnResp {
			resp = m
		}
		else {
			log.warn('visitor "${v.cfg.name}": expected NewVisitorConnResp, got ${m.type_name()}')
			vc.close() or {}
			uc.close() or {}
			return
		}
	}
	if resp.error != '' {
		log.warn('visitor "${v.cfg.name}": server rejected visitor conn: ${resp.error}')
		vc.close() or {}
		uc.close() or {}
		return
	}
	log.info('visitor "${v.cfg.name}": relaying user conn via proxy "${v.cfg.server_name}"')
	netx.relay(uc, vc)
}

// close 幂等关闭 listener；调用后 accept_loop 立即因 accept 错误退出。
// 已 close 时不重复关 listener（可能为 nil，run 失败时）。
fn (mut v Visitor) close() {
	v.close_mu.lock()
	if v.closed {
		v.close_mu.unlock()
		return
	}
	v.closed = true
	v.close_mu.unlock()
	if v.listener != unsafe { nil } {
		v.listener.close() or {}
	}
}

// is_closed 判断 visitor 是否已被关闭（accept_loop 据此区分"正常关闭"和"异常退出"）。
fn (mut v Visitor) is_closed() bool {
	v.close_mu.lock()
	defer {
		v.close_mu.unlock()
	}
	return v.closed
}

// start_visitors 为 cfg.visitors 每项起一个 Visitor 并 run；单个失败记日志继续其余，
// 返回成功启动的列表（用于会话断开时统一 close）。
// 仅支持 stcp；其他类型记 warn 跳过（xtcp / fallback_to 等 P9+）。
fn start_visitors(cfg config.ClientConfig, run_id string) []&Visitor {
	mut visitors := []&Visitor{}
	for vc in cfg.visitors {
		if vc.type != 'stcp' {
			log.warn('visitor "${vc.name}": unsupported type "${vc.type}", skipping (only stcp supported)')
			continue
		}
		mut v := new_visitor(vc, cfg.server_addr, cfg.server_port, run_id)
		v.run() or {
			log.error('visitor "${vc.name}": ${err.msg()}')
			continue
		}
		visitors << v
	}
	return visitors
}
