// 服务端主体：监听 bind_addr:bind_port，按连接首条消息分发——Login 建控制会话，
// NewWorkConn 注册 work conn，其余类型直接关闭。SIGINT/SIGTERM 优雅退出（关 listener）。
// 可选监听 vhost_http_port 接收 HTTP vhost 请求（按 Host 头路由到对应代理）。
module server

import net
import os
import sync
import time
import pkg.auth
import pkg.config
import pkg.msg
import pkg.util.log
import pkg.util.netx
import pkg.util.version

// stop_poll_interval run() 轮询退出标志的间隔。
const stop_poll_interval = 100 * time.millisecond

// vhost_http_header_read_timeout vhost 监听器读 HTTP headers 的总超时。
// 超时则按 408 简单处理（关连接），避免恶意半连接挂住 accept 循环。
const vhost_http_header_read_timeout = 5 * time.second

// vhost_http_max_header_bytes 解析 Host 头时最多读取的字节数（防 DoS）。
const vhost_http_max_header_bytes = 64 * 1024

// VhostRoute 单条 vhost 路由表项：host 唯一对应一个 (control, proxy_name)。
pub struct VhostRoute {
pub:
	control    &Control
	proxy_name string
}

// Service 服务端。含 Mutex，须以引用（&Service）形式使用；accept 循环线程、
// 各连接处理线程并发访问。
pub struct Service {
pub mut:
	cfg             config.ServerConfig
	listener        &net.TcpListener
	vhost_listener  &net.TcpListener // vhost_http_port == 0 时为 nil
	pm              &PortManager
	controls        map[string]&Control // run_id -> control
	controls_mu     sync.Mutex
	vhost_routes    map[string]VhostRoute // host -> 路由
	vhost_routes_mu sync.Mutex
	stop            bool // 收到退出信号后置位
	closed          bool
	close_mu        sync.Mutex
}

// new_service 创建服务端实例（含端口管理器）。
pub fn new_service(cfg config.ServerConfig) &Service {
	return &Service{
		cfg:             cfg
		listener:        unsafe { nil }
		vhost_listener:  unsafe { nil }
		pm:              new_port_manager(cfg.bind_addr)
		controls:        map[string]&Control{}
		controls_mu:     sync.new_mutex()
		vhost_routes:    map[string]VhostRoute{}
		vhost_routes_mu: sync.new_mutex()
		close_mu:        sync.new_mutex()
	}
}

// run 启动服务并阻塞：监听 → 起 accept 循环 → 轮询退出标志；
// 收到 SIGINT/SIGTERM 后关闭 listener 与所有 control，返回。
pub fn (mut s Service) run() ! {
	addr := netx.join_host_port(s.cfg.bind_addr, s.cfg.bind_port)
	mut l := net.listen_tcp(.ip, addr) or {
		return error('vfrps listen on ${addr} failed: ${err.msg()}')
	}
	s.listener = l
	log.info('vfrps ${version.version} listening on ${addr}')

	// 可选 vhost HTTP 监听器
	if s.cfg.vhost_http_port > 0 {
		vhost_addr := netx.join_host_port(s.cfg.bind_addr, s.cfg.vhost_http_port)
		mut vl := net.listen_tcp(.ip, vhost_addr) or {
			l.close() or {}
			return error('vfrps vhost listen on ${vhost_addr} failed: ${err.msg()}')
		}
		s.vhost_listener = vl
		log.info('vfrps vhost HTTP listening on ${vhost_addr}')
		spawn s.vhost_accept_loop()
	}

	// SIGINT/SIGTERM → 置 stop 标志，主循环轮询退出。
	os.signal_opt(os.Signal.int, fn [mut s] (sig os.Signal) {
		s.stop = true
	}) or {}
	os.signal_opt(os.Signal.term, fn [mut s] (sig os.Signal) {
		s.stop = true
	}) or {}

	spawn s.accept_loop()

	for !s.stop {
		time.sleep(stop_poll_interval)
	}
	log.info('vfrps received stop signal, shutting down')
	s.close()!
}

// accept_loop 循环 accept；listener 被关闭（close 调用）时 accept 报错退出。
fn (mut s Service) accept_loop() {
	for {
		mut conn := s.listener.accept() or {
			if !s.is_closed() {
				log.warn('service: accept error: ${err.msg()}')
			}
			return
		}
		spawn s.handle_conn(conn)
	}
}

// handle_conn 读首条消息并分发：Login → 建控制会话；NewWorkConn → 注册 work conn；
// 其他类型或读失败 → 直接关闭连接。
// 参数不带 mut：spawn 传参 `mut x &T` 会捕获调用方栈地址（原因见 netx.copy_one_way 注释）。
fn (mut s Service) handle_conn(conn &net.TcpConn) {
	mut c := conn
	m := msg.read_msg(mut c) or {
		log.warn('service: read first message failed: ${err.msg()}')
		c.close() or {}
		return
	}
	match m {
		msg.Login {
			s.handle_login_conn(c, m)
		}
		msg.NewWorkConn {
			s.handle_work_conn(mut c, m)
		}
		else {
			log.warn('service: unexpected first message ${typeof(m).name}, closing conn')
			c.close() or {}
		}
	}
}

// handle_login_conn 处理登录连接：建 Control、校验并应答 LoginResp；
// 成功后注册进控制表（同 run_id 冲突时踢掉旧 control）并跑控制循环。
fn (mut s Service) handle_login_conn(conn &net.TcpConn, login msg.Login) {
	mut ctl := new_control(conn, s.cfg.auth_token, s.cfg.bind_addr, s.pm, s, login.run_id)
	ctl.handle_login(login) or {
		// handle_login 失败时已回 LoginResp{error} 并关闭连接
		log.warn('service: client login rejected for run_id ${ctl.run_id}: ${err.msg()}')
		return
	}
	s.register_control(ctl) or {
		log.warn('service: control ${ctl.run_id} was replaced')
		ctl.close()
		return
	}
	log.info('service: client [${ctl.run_id}] login success')
	ctl.run()
	s.unregister_control(ctl)
	log.info('service: client [${ctl.run_id}] exited')
}

// handle_work_conn 处理 NewWorkConn：按 run_id 找到 control，校验 privilege_key
// 后把连接塞入其 work 队列；找不到或校验失败则回 StartWorkConn{error} 并关闭。
fn (mut s Service) handle_work_conn(mut conn &net.TcpConn, m msg.NewWorkConn) {
	s.controls_mu.lock()
	mut ctl := s.controls[m.run_id] or {
		s.controls_mu.unlock()
		log.warn('service: no control for run_id ${m.run_id}, rejecting work conn')
		msg.write_msg(mut conn, msg.StartWorkConn{
			error: 'no control for run_id ${m.run_id}'
		}) or {}
		conn.close() or {}
		return
	}
	s.controls_mu.unlock()

	if !auth.verify_privilege_key(ctl.token, m.timestamp, m.privilege_key, time.now().unix()) {
		log.warn('service: work conn auth failed for run_id ${m.run_id}')
		msg.write_msg(mut conn, msg.StartWorkConn{
			error: 'work conn auth failed'
		}) or {}
		conn.close() or {}
		return
	}
	ctl.register_work_conn(mut conn)
}

// register_control 把 control 注册进控制表；同 run_id 已有 control 时先关闭旧的控制
// 再替换（客户端重连踢旧）。
pub fn (mut s Service) register_control(ctl &Control) ! {
	s.controls_mu.lock()
	defer {
		s.controls_mu.unlock()
	}
	if mut old := s.controls[ctl.run_id] {
		log.warn('service: run_id ${ctl.run_id} already active, replacing old control')
		s.controls.delete(ctl.run_id)
		old.close()
	}
	s.controls[ctl.run_id] = ctl
}

// unregister_control 从控制表移除；仅当表中仍是该 control 时才删除
// （防止被替换后旧 control 的收尾线程误删新 control）。
// 退出时同步清理指向该 control 的 vhost 路由，避免 stale pointer。
pub fn (mut s Service) unregister_control(ctl &Control) {
	s.controls_mu.lock()
	if cur := s.controls[ctl.run_id] {
		if cur == ctl {
			s.controls.delete(ctl.run_id)
		}
	}
	s.controls_mu.unlock()
	s.unregister_vhost_routes_for_control(ctl)
}

// close 关闭服务（幂等）：关闭 listener，再关闭所有 control。
pub fn (mut s Service) close() ! {
	s.close_mu.lock()
	if s.closed {
		s.close_mu.unlock()
		return
	}
	s.closed = true
	s.close_mu.unlock()

	if s.listener != unsafe { nil } {
		s.listener.close() or {}
		log.info('service: listener closed')
	}
	if s.vhost_listener != unsafe { nil } {
		s.vhost_listener.close() or {}
		log.info('service: vhost listener closed')
	}
	s.controls_mu.lock()
	mut ctls := s.controls.values()
	s.controls_mu.unlock()
	for mut ctl in ctls {
		ctl.close()
	}
}

// register_vhost_route 注册一条 vhost 路由；同 host 已有路由时后注册的覆盖前者。
// 同名不同 proxy 的覆盖是 frp 官方行为，后到的 vfrpc 注册"赢"；避免 stale 路由
// 在 control 退出后还指向空指针。
pub fn (mut s Service) register_vhost_route(host string, control &Control, proxy_name string) {
	s.vhost_routes_mu.lock()
	s.vhost_routes[host] = VhostRoute{
		control:    control
		proxy_name: proxy_name
	}
	s.vhost_routes_mu.unlock()
	log.info('service: vhost route "${host}" -> control [${control.run_id}] proxy [${proxy_name}]')
}

// unregister_vhost_routes_for_control 移除所有指向该 control 的 vhost 路由
// （control 退出时由 Service 自动调用，避免 stale pointer）。
pub fn (mut s Service) unregister_vhost_routes_for_control(control &Control) {
	s.vhost_routes_mu.lock()
	defer {
		s.vhost_routes_mu.unlock()
	}
	mut to_remove := []string{}
	for host, route in s.vhost_routes {
		if route.control == control {
			to_remove << host
		}
	}
	for host in to_remove {
		s.vhost_routes.delete(host)
		log.info('service: vhost route "${host}" unregistered (control exited)')
	}
}

// lookup_vhost_route 按 host 查路由；找不到返回 none。
pub fn (s &Service) lookup_vhost_route(host string) ?VhostRoute {
	s.vhost_routes_mu.lock()
	defer {
		s.vhost_routes_mu.unlock()
	}
	if r := s.vhost_routes[host] {
		return r
	}
	return none
}

// vhost_accept_loop vhost HTTP 端口的 accept 循环。每条 user conn 启动一个
// handle_vhost_conn 线程（spawn 走闭包）。
fn (mut s Service) vhost_accept_loop() {
	for {
		mut conn := s.vhost_listener.accept() or {
			if !s.is_closed() {
				log.warn('service: vhost accept error: ${err.msg()}')
			}
			return
		}
		spawn s.handle_vhost_conn(conn)
	}
}

// handle_vhost_conn 处理一条 vhost user conn：读 HTTP headers → 解析 Host →
// 查 vhost_routes 找到目标 (control, proxy_name) → 走 work conn 链路转发。
// V P7 MVP：单请求/单连接（非 keep-alive）；HTTP body 跟随原 user conn 流转发。
fn (mut s Service) handle_vhost_conn(user_conn &net.TcpConn) {
	mut uc := user_conn
	// 1) 读 HTTP headers（到 \r\n\r\n 截止）
	header_buf := read_http_headers(mut uc) or {
		log.warn('vhost: read http headers failed: ${err.msg()}')
		uc.close() or {}
		return
	}
	// 2) 解析 Host（去端口；缺省端口 80）
	host := parse_host_header(header_buf.bytestr()) or {
		log.warn('vhost: no Host header in request, closing')
		uc.close() or {}
		return
	}
	// 3) 查 vhost 路由
	route := s.lookup_vhost_route(host) or {
		log.warn('vhost: no route for host "${host}"')
		uc.close() or {}
		return
	}
	log.info('vhost: route host="${host}" -> control [${route.control.run_id}] proxy [${route.proxy_name}]')
	// 4) 走 work conn：request → 等 → send StartWorkConn → relay
	mut ctl := route.control
	ctl.send_req_work_conn() or {
		log.warn('vhost: send ReqWorkConn failed: ${err.msg()}')
		uc.close() or {}
		return
	}
	mut work_conn := ctl.get_work_conn(work_conn_wait_timeout) or {
		log.warn('vhost: wait work conn timed out for host "${host}"')
		uc.close() or {}
		return
	}
	// 5) 发 StartWorkConn（带用户连接地址对信息）
	peer := uc.peer_addr() or {
		uc.close() or {}
		work_conn.close() or {}
		return
	}
	peer_str := '${peer}'
	src_addr, src_port := netx.split_host_port(peer_str) or {
		uc.close() or {}
		work_conn.close() or {}
		return
	}
	local := uc.addr() or {
		uc.close() or {}
		work_conn.close() or {}
		return
	}
	local_str := '${local}'
	dst_addr, dst_port := netx.split_host_port(local_str) or {
		uc.close() or {}
		work_conn.close() or {}
		return
	}
	msg.write_msg(mut work_conn, msg.StartWorkConn{
		proxy_name: route.proxy_name
		src_addr:   src_addr
		dst_addr:   dst_addr
		src_port:   u16(src_port)
		dst_port:   u16(dst_port)
	}) or {
		log.warn('vhost: send StartWorkConn failed: ${err.msg()}')
		uc.close() or {}
		work_conn.close() or {}
		return
	}
	// 6) 把缓冲的 HTTP headers 先发给 work conn（client 侧 handle_udp_proxy
	// / 未来的 handle_http_proxy 会原样转发给本地 HTTP server）
	mut wc := work_conn
	wc.write(header_buf) or {
		log.warn('vhost: write buffered headers to work conn failed: ${err.msg()}')
		uc.close() or {}
		wc.close() or {}
		return
	}
	// 7) 后续字节（HTTP body 可能有）走双向 relay
	log.info('vhost: host="${host}" relay established, ${header_buf.len} buffered bytes forwarded')
	netx.relay(uc, wc)
}

// read_http_headers 从 user_conn 读 HTTP headers（截至 \r\n\r\n）。
// 设总超时防恶意慢速连接。返回的 []u8 包含终止的 \r\n\r\n。
fn read_http_headers(mut conn &net.TcpConn) ![]u8 {
	conn.set_read_deadline(time.now().add(vhost_http_header_read_timeout))
	defer {
		conn.set_read_deadline(time.unix(0))
	}
	mut buf := []u8{}
	mut tmp := []u8{len: 1}
	for buf.len < vhost_http_max_header_bytes {
		n := conn.read(mut tmp) or { return error('read http header: ${err.msg()}') }
		if n == 0 {
			return error('read http header: connection closed before \\r\\n\\r\\n')
		}
		buf << tmp[0]
		if buf.len >= 4 && buf[buf.len - 4] == `\r` && buf[buf.len - 3] == `\n`
			&& buf[buf.len - 2] == `\r` && buf[buf.len - 1] == `\n` {
			return buf
		}
	}
	return error('http headers exceed ${vhost_http_max_header_bytes} bytes')
}

// parse_host_header 从 HTTP request 头里解析 Host 字段值（去掉端口）。
// 形如 "Host: example.com:8080\r\n" → "example.com"。
// 不区分大小写；忽略首尾空白。
fn parse_host_header(headers string) ?string {
	mut lines := headers.split('\n')
	for line in lines {
		// 去掉可能的 \r
		mut clean := line.trim_space()
		if clean.len == 0 {
			continue
		}
		// 跳过 request line
		if clean.starts_with('GET ') || clean.starts_with('POST ') || clean.starts_with('PUT ')
			|| clean.starts_with('DELETE ') || clean.starts_with('HEAD ')
			|| clean.starts_with('OPTIONS ') || clean.starts_with('PATCH ')
			|| clean.starts_with('CONNECT ') {
			continue
		}
		// 找冒号
		colon_idx := clean.index(':') or { continue }
		name := clean[..colon_idx].trim_space().to_lower()
		if name != 'host' {
			continue
		}
		mut value := clean[colon_idx + 1..].trim_space()
		// 去掉端口
		colon2 := value.index(':') or { return value.to_lower() }
		return value[..colon2].to_lower()
	}
	return none
}

// is_closed 返回服务是否已关闭。
pub fn (mut s Service) is_closed() bool {
	s.close_mu.lock()
	defer {
		s.close_mu.unlock()
	}
	return s.closed
}
