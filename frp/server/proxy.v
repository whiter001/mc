// 服务端代理：TcpProxy（TCP）+ UdpProxy（UDP）。TCP 走"每用户连接一条 work conn"模型，
// UDP 走"代理级一条 work conn、长期复用"模型（与 Go frp 的 udp.go 思路一致）。
// 收到 NewProxy 时按 proxy_type 分派给 start_tcp_proxy / start_udp_proxy。
module server

import net
import sync
import time
import pkg.msg
import pkg.util.log
import pkg.util.netx

// udp_read_buf_size 服务端 UDP 读循环的单次读缓冲（max UDP payload ≈ 64KB）。
const udp_read_buf_size = 64 * 1024

// udp_work_conn_wait_timeout 服务端为 UDP 代理等一条 work conn 的超时。
const udp_work_conn_wait_timeout = 10 * time.second

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

// ---------------------------------------------------------------------------
// UdpProxy
// ---------------------------------------------------------------------------

// UdpProxy 服务端 UDP 代理：监听 remote_port（UDP socket），收发按 v1 帧格式
// 走 work conn 的 UDPPacket 消息。work conn 是代理级别的、长期复用的（多用户共享），
// 不像 TcpProxy 那样每用户连接一条。V 0.5.x json2 已确认 UDPPacket 用同款
// "wire 副本"路径（msg_test 已覆盖），这里不再额外 shim。
pub struct UdpProxy {
pub mut:
	name        string
	remote_port int      // 实际监听端口（acquire_udp 分配或指定）
	control     &Control // 所属控制会话
	udp_conn    &net.UdpConn
	work_conn   &net.TcpConn // 当前复用的 work conn（首次包时申请并写入；可为 nil 表示尚未就绪）
	work_mu     sync.Mutex   // 保护 work_conn 的设置与读取
	closed      bool
	close_mu    sync.Mutex
}

// new_udp_proxy 创建 UDP 代理，remote_port 为已分配端口。
pub fn new_udp_proxy(name string, remote_port int, control &Control) &UdpProxy {
	return &UdpProxy{
		name:        name
		remote_port: remote_port
		control:     control
		udp_conn:    unsafe { nil }
		work_conn:   unsafe { nil }
		work_mu:     sync.new_mutex()
		close_mu:    sync.new_mutex()
	}
}

// start 监听 UDP remote_port，并 spawn 长期 read 循环（包驱动 work conn 申请与转发）。
// 返回实际绑定端口（remote_port=0 时由 PortManager 探测得到，本方法只透传）。
// 注意：work_read_loop 不在 start() 里 spawn；它在 acquire_work_conn 拿到 work conn
// 并向 client 发完 StartWorkConn 之后才 spawn。否则 work_read_loop 会抢先 read
// 走 work conn 上的 StartWorkConn，client 侧 read 不到、handle_udp_proxy 永远不
// 会被调用。
pub fn (mut p UdpProxy) start(bind_addr string) !int {
	addr := netx.join_host_port(bind_addr, p.remote_port)
	mut s := net.listen_udp(addr) or {
		return error('udp proxy [${p.name}]: listen on ${addr} failed: ${err.msg()}')
	}
	// V 0.5.2 的 UdpConn 默认 100ms read_timeout，每次 read 没数据就返"timeout"。
	// 代理需要长期阻塞等包：先试 time.infinite（走"无限等待"分支），置 0 在某些
	// 版本里会被当作"用 deadline"误用，故避开。
	s.set_read_timeout(time.infinite)
	p.udp_conn = s
	// V 0.5.2 UdpConn 不暴露绑定后的本地地址；探测时已记录实际端口（p.remote_port）
	log.info('udp proxy [${p.name}] listen on ${addr}')
	spawn p.read_loop()
	return p.remote_port
}

// acquire_work_conn 申请并缓存一条 work conn；并发安全，重复调用复用同一 conn。
// 流程：先尝试 control.get_work_conn（不阻塞），无则发 ReqWorkConn 再等。
// 失败返回 false；调用方决定是否丢包。
fn (mut p UdpProxy) acquire_work_conn() bool {
	// fast path：已有就复用
	p.work_mu.lock()
	if p.work_conn != unsafe { nil } {
		p.work_mu.unlock()
		return true
	}
	p.work_mu.unlock()

	// 慢路径：发 ReqWorkConn 再等一条
	p.control.send_req_work_conn() or {
		log.warn('udp proxy [${p.name}]: send ReqWorkConn failed: ${err.msg()}')
		return false
	}
	wc := p.control.get_work_conn(udp_work_conn_wait_timeout) or {
		log.warn('udp proxy [${p.name}]: wait work conn timed out')
		return false
	}
	mut wc_mut := wc
	p.work_mu.lock()
	// 期间可能有别的线程已设置：丢弃这次拿到的，避免泄漏
	if p.work_conn != unsafe { nil } {
		p.work_mu.unlock()
		wc_mut.close() or {}
		return true
	}
	p.work_conn = wc_mut
	p.work_mu.unlock()
	// 在 work conn 上发 StartWorkConn（带用户地址信息——UDP 代理下用 0.0.0.0:0 占位，
	// 真实用户地址走 UDPPacket.local_addr / remote_addr 携带，handler 不依赖此字段）
	msg.write_msg(mut wc_mut, msg.StartWorkConn{
		proxy_name: p.name
		src_addr:   '0.0.0.0'
		dst_addr:   '0.0.0.0'
		src_port:   0
		dst_port:   u16(p.remote_port)
	}) or {
		log.warn('udp proxy [${p.name}]: send StartWorkConn failed: ${err.msg()}')
		p.work_mu.lock()
		p.work_conn = unsafe { nil }
		p.work_mu.unlock()
		wc_mut.close() or {}
		return false
	}
	log.info('udp proxy [${p.name}]: work conn established, ready to relay')
	// 现在 work conn 上的 StartWorkConn 已经发出；启动 work_read_loop 接收后续 UDPPacket。
	// 之前在 start() 里 spawn 会抢在 client 读 StartWorkConn 之前把它吃掉。
	spawn p.work_read_loop()
	return true
}

// read_loop 长期从 UDP socket 读包；每包申请/复用 work conn 后用 UDPPacket 转发。
// 注：spawn 传参 `mut x &T` 会捕获调用方栈地址（原因见 netx.copy_one_way 注释），
// 故方法参数不带 mut。
fn (mut p UdpProxy) read_loop() {
	mut buf := []u8{len: udp_read_buf_size}
	for {
		if p.is_closed() {
			return
		}
		mut conn := p.udp_conn
		n, addr := conn.read(mut buf) or {
			if !p.is_closed() {
				log.warn('udp proxy [${p.name}]: read error: ${err.msg()}')
			}
			return
		}
		if n == 0 {
			continue
		}
		if !p.acquire_work_conn() {
			// 申请失败：当前包丢弃（V P6 MVP；多包重试 / 缓冲放后续版本）
			log.debug('udp proxy [${p.name}]: drop packet, no work conn')
			continue
		}
		p.work_mu.lock()
		mut wc := p.work_conn
		p.work_mu.unlock()
		// 用单次读缓冲构造 UDPPacket；content 拷贝走，避免 buf 复用踩到
		mut pkt_content := []u8{len: n, init: 0}
		copy(mut pkt_content, buf[..n])
		// V 0.5.2 UdpConn 无 addr() 方法；用已知 remote_port 与 bind_addr 拼 local_addr
		mut local_str := netx.join_host_port(p.control.bind_addr, p.remote_port)
		msg.write_msg(mut wc, msg.UDPPacket{
			content:     pkt_content
			remote_addr: '${addr}'
			local_addr:  local_str
		}) or {
			log.warn('udp proxy [${p.name}]: write UDPPacket to work conn failed: ${err.msg()}')
			// work conn 死了，清掉让下次重新申请
			p.work_mu.lock()
			p.work_conn = unsafe { nil }
			p.work_mu.unlock()
			continue
		}
		log.debug('udp proxy [${p.name}]: forwarded ${n} bytes from ${addr}')
	}
}

// work_read_loop 从 work conn 读 UDPPacket，解析出 content + remote_addr 后回写到 UDP socket。
// remote_addr 是当初用户发包来的地址（"ip:port" 串）。
fn (mut p UdpProxy) work_read_loop() {
	for {
		if p.is_closed() {
			return
		}
		p.work_mu.lock()
		mut wc := p.work_conn
		p.work_mu.unlock()
		if wc == unsafe { nil } {
			time.sleep(100 * time.millisecond)
			continue
		}
		m := msg.read_msg(mut wc) or {
			if !p.is_closed() {
				log.warn('udp proxy [${p.name}]: read from work conn failed: ${err.msg()}')
			}
			// work conn 失效，清掉并等 read_loop 重新申请
			p.work_mu.lock()
			p.work_conn = unsafe { nil }
			p.work_mu.unlock()
			time.sleep(100 * time.millisecond)
			continue
		}
		match m {
			msg.UDPPacket {
				addr := m.remote_addr
				if addr == '' {
					log.debug('udp proxy [${p.name}]: drop UDPPacket without remote_addr')
					continue
				}
				mut uc := p.udp_conn
				addrs := net.resolve_addrs_fuzzy(addr, .udp) or {
					log.warn('udp proxy [${p.name}]: bad remote_addr "${addr}": ${err.msg()}')
					continue
				}
				if addrs.len == 0 {
					log.warn('udp proxy [${p.name}]: resolve_addrs returned empty for ${addr}')
					continue
				}
				uc.write_to(addrs[0], m.content) or {
					log.warn('udp proxy [${p.name}]: write_to ${addr} failed: ${err.msg()}')
				}
			}
			else {
				log.debug('udp proxy [${p.name}]: ignore non-UDPPacket from work conn')
			}
		}
	}
}

// close 关闭 UDP 代理（幂等）：关闭 UDP socket 与已缓存的 work conn。
pub fn (mut p UdpProxy) close() {
	p.close_mu.lock()
	if p.closed {
		p.close_mu.unlock()
		return
	}
	p.closed = true
	p.close_mu.unlock()
	if p.udp_conn != unsafe { nil } {
		p.udp_conn.close() or {}
	}
	p.work_mu.lock()
	mut wc := p.work_conn
	p.work_conn = unsafe { nil }
	p.work_mu.unlock()
	if wc != unsafe { nil } {
		wc.close() or {}
	}
	log.info('udp proxy [${p.name}] closed')
}

// is_closed 返回代理是否已关闭。
fn (mut p UdpProxy) is_closed() bool {
	p.close_mu.lock()
	defer {
		p.close_mu.unlock()
	}
	return p.closed
}
