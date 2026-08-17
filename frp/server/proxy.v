// 服务端 TCP 代理：监听 remote_port，收到用户连接后向 control 请求一条 work
// conn，取到后向 work conn 发 StartWorkConn 并双向对接（netx.relay 接管）。
module server

import net
import sync
import pkg.msg
import pkg.util.log
import pkg.util.netx

// TcpProxy 服务端 TCP 代理。含 Mutex / 引用字段，须以引用（&TcpProxy）形式使用；
// accept 循环线程与 control 线程会并发访问。
pub struct TcpProxy {
pub mut:
	name        string
	remote_port int      // 实际监听端口（acquire 分配或指定）
	control     &Control // 所属控制会话
	listener    &net.TcpListener
	closed      bool
	close_mu    sync.Mutex
}

// new_tcp_proxy 创建 TCP 代理，remote_port 为已分配端口。
pub fn new_tcp_proxy(name string, remote_port int, control &Control) &TcpProxy {
	return &TcpProxy{
		name:        name
		remote_port: remote_port
		control:     control
		listener:    unsafe { nil }
		close_mu:    sync.new_mutex()
	}
}

// start 在 bind_addr 上监听 remote_port，返回实际监听端口，并启动 accept 循环。
pub fn (mut p TcpProxy) start(bind_addr string) !int {
	addr := netx.join_host_port(bind_addr, p.remote_port)
	mut l := net.listen_tcp(.ip, addr) or {
		return error('tcp proxy [${p.name}]: listen on ${addr} failed: ${err.msg()}')
	}
	p.listener = l
	a := l.addr() or {
		l.close() or {}
		return error('tcp proxy [${p.name}]: read listener addr failed: ${err.msg()}')
	}
	real_port := '${a}'.all_after(':').int()
	p.remote_port = real_port
	log.info('tcp proxy [${p.name}] listen on ${addr}')
	spawn p.accept_loop()
	return real_port
}

// accept_loop 循环 accept 用户连接；listener 被关闭（close 调用）时 accept 报错退出。
fn (mut p TcpProxy) accept_loop() {
	for {
		mut user_conn := p.listener.accept() or {
			if !p.is_closed() {
				log.warn('tcp proxy [${p.name}]: accept error: ${err.msg()}')
			}
			return
		}
		spawn p.handle_user_conn(user_conn)
	}
}

// handle_user_conn 处理一条用户连接：请求 work conn → 等 work conn（超时关闭）→
// 发 StartWorkConn → 双向对接。relay 会接管并最终关闭两端连接。
// 参数不带 mut：spawn 传参 `mut x &T` 会捕获调用方栈地址（原因见 netx.copy_one_way 注释）。
fn (mut p TcpProxy) handle_user_conn(user_conn &net.TcpConn) {
	mut uc := user_conn
	mut ctl := p.control
	// 1. 通过控制连接请求一条 work conn
	ctl.send_req_work_conn() or {
		log.warn('tcp proxy [${p.name}]: send ReqWorkConn failed: ${err.msg()}')
		uc.close() or {}
		return
	}
	// 2. 等待 work conn（带超时）
	mut work_conn := ctl.get_work_conn(work_conn_wait_timeout) or {
		log.warn('tcp proxy [${p.name}]: timeout (${work_conn_wait_timeout}) waiting for work conn')
		uc.close() or {}
		return
	}
	// 3. 向 work conn 发 StartWorkConn（携带用户连接对端/本端地址）
	peer := uc.peer_addr() or {
		uc.close() or {}
		work_conn.close() or {}
		return
	}
	src_addr, src_port := netx.split_host_port('${peer}') or {
		uc.close() or {}
		work_conn.close() or {}
		return
	}
	local := uc.addr() or {
		uc.close() or {}
		work_conn.close() or {}
		return
	}
	dst_addr, dst_port := netx.split_host_port('${local}') or {
		uc.close() or {}
		work_conn.close() or {}
		return
	}
	msg.write_msg(mut work_conn, msg.StartWorkConn{
		proxy_name: p.name
		src_addr:   src_addr
		dst_addr:   dst_addr
		src_port:   u16(src_port)
		dst_port:   u16(dst_port)
	}) or {
		log.warn('tcp proxy [${p.name}]: send StartWorkConn failed: ${err.msg()}')
		uc.close() or {}
		work_conn.close() or {}
		return
	}
	// 4. 双向对接（netx.relay 接管两端连接，结束即自动关闭）
	log.info('tcp proxy [${p.name}]: relay user conn ${src_addr}:${src_port} <-> work conn')
	netx.relay(uc, work_conn)
}

// close 关闭代理（幂等）：关闭 listener，accept 循环随之退出。
pub fn (mut p TcpProxy) close() {
	p.close_mu.lock()
	if p.closed {
		p.close_mu.unlock()
		return
	}
	p.closed = true
	p.close_mu.unlock()
	if p.listener != unsafe { nil } {
		p.listener.close() or {}
	}
	log.info('tcp proxy [${p.name}] closed')
}

// is_closed 返回代理是否已关闭。
pub fn (mut p TcpProxy) is_closed() bool {
	p.close_mu.lock()
	defer {
		p.close_mu.unlock()
	}
	return p.closed
}
