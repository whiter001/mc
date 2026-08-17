// 客户端 work conn 处理：一条 work conn 对接一条本地 TCP 连接（UDP 代理下为
// 长期复用的 UDP socket，见 handle_udp_proxy）。
// 流程（与 Go 版 frp client/proxy.go HandleTCPWorkConnection 对齐）：
// 拨号服务器 → 发 NewWorkConn（带认证）→ 等 StartWorkConn（10s 超时）
// → 按 proxy_name 查本地代理配置 → 拨 local_ip:local_port → 双向转发。
// 由 control.v 读循环收到 ReqWorkConn 时 spawn 调用，每条 work conn 一个线程。
module client

import net
import time
import pkg.config
import pkg.msg
import pkg.auth
import pkg.util.netx
import pkg.util.log

// start_work_conn_timeout 等待 StartWorkConn 的超时（秒），对应 Go 版默认 10s。
const start_work_conn_timeout = 10 * time.second

// udp_read_buf_size 客户端 UDP 读循环单次读缓冲（max UDP payload ≈ 64KB）。
const udp_read_buf_size = 64 * 1024

// handle_work_conn 处理一条 work conn 的完整生命周期。
// 注意：最后调用 netx.relay 会接管并最终关闭 work_conn 与 local_conn，
// 因此失败路径显式 close work_conn，成功路径不 close。
fn handle_work_conn(cfg config.ClientConfig, run_id string) {
	server_addr := netx.join_host_port(cfg.server_addr, cfg.server_port)
	mut work_conn := net.dial_tcp(server_addr) or {
		log.warn('work conn: dial server ${server_addr} failed: ${err.msg()}')
		return
	}
	ts := time.now().unix()
	msg.write_msg(mut work_conn, msg.NewWorkConn{
		run_id:        run_id
		privilege_key: auth.new_privilege_key(cfg.auth_token, ts)
		timestamp:     ts
	}) or {
		log.warn('work conn: write NewWorkConn failed: ${err.msg()}')
		work_conn.close() or {}
		return
	}
	// 等 StartWorkConn：设 10s 读超时
	work_conn.set_read_deadline(time.now().add(start_work_conn_timeout))
	m := msg.read_msg(mut work_conn) or {
		log.warn('work conn: wait StartWorkConn failed: ${err.msg()}')
		work_conn.close() or {}
		return
	}
	// StartWorkConn 已收到：清掉读超时，后续生命周期交给 relay（EOF 决定关闭）
	work_conn.set_read_deadline(time.unix(0))
	mut start := msg.StartWorkConn{}
	match m {
		msg.StartWorkConn {
			start = m
		}
		else {
			log.warn('work conn: expected StartWorkConn, got ${m.type_name()}')
			work_conn.close() or {}
			return
		}
	}
	if start.error != '' {
		log.error('proxy "${start.proxy_name}": server rejected work conn: ${start.error}')
		work_conn.close() or {}
		return
	}
	local, ok := find_proxy_config(cfg, start.proxy_name)
	if !ok {
		log.error('proxy "${start.proxy_name}": not found in local config, closing work conn')
		work_conn.close() or {}
		return
	}
	if local.type == 'udp' {
		// UDP 代理：work conn 长期复用，不做 TCP 风格的 per-connection relay。
		// 详见 handle_udp_proxy。
		handle_udp_proxy(local, mut work_conn)
		return
	}
	local_addr := netx.join_host_port(local.local_ip, local.local_port)
	mut local_conn := net.dial_tcp(local_addr) or {
		log.error('proxy "${local.name}": dial local ${local_addr} failed: ${err.msg()}')
		work_conn.close() or {}
		return
	}
	log.info('proxy "${local.name}": relaying work conn to local ${local_addr}')
	netx.relay(work_conn, local_conn)
}

// handle_udp_proxy 处理 UDP 代理 work conn：单进程内建立一对后台 goroutine
// - local_udp_to_work：从本地 UDP socket 读包，包装成 UDPPacket（remote_addr=本端源）写回 work conn
// - work_to_local_udp：从 work conn 读 UDPPacket，解出 content + remote_addr，UDP 写回给用户
// V P6 MVP：单会话（vfrpc 作为唯一对端与本地 app 通信）。多用户会话/多用户并发留 P6+。
// 失败路径不显式关 work_conn：与 TCP 路径一致，由 netx.relay / 错误返回时的 close 负责。
// 生命周期：local_udp 句柄交给两个 spawned goroutine 共享，handle_udp_proxy 本函数
// **不能** defer close（否则函数返回瞬间 socket 就关了，子 goroutine 立刻 EBADF）。
// socket 关闭由 work conn 读错误触发：work conn 断 → udp_work_to_local 退出 → 之后
// 由 Service 的 read_loop 出错触发整体重连（参见 client/service.v）。
fn handle_udp_proxy(local config.ProxyConfig, mut work_conn &net.TcpConn) {
	local_addr := netx.join_host_port(local.local_ip, local.local_port)
	// V 0.5.2 缺 dial_udp(laddr, raddr) 形式；用 listen_udp(laddr) 监听同一个端口，
	// 再 write_to(dialed) 发送（OS 会分配本地端口作为源）。
	mut local_udp := net.listen_udp(local_addr) or {
		log.error('proxy "${local.name}": listen_udp on ${local_addr} failed: ${err.msg()}')
		return
	}
	// V 0.5.2 的 UdpConn 默认 100ms read_timeout；代理需长期阻塞等包，走无限等待
	local_udp.set_read_timeout(time.infinite)
	// resolve 一次 local_ip:local_port 作为发送目标
	dst_addrs := net.resolve_addrs_fuzzy(local_addr, .udp) or {
		log.error('proxy "${local.name}": resolve local ${local_addr} failed: ${err.msg()}')
		local_udp.close() or {}
		return
	}
	if dst_addrs.len == 0 {
		log.error('proxy "${local.name}": resolve returned empty for ${local_addr}')
		local_udp.close() or {}
		return
	}
	dst := dst_addrs[0]
	log.info('proxy "${local.name}": udp relay ready, local=${local_addr}')

	// 本地 UDP → work conn
	spawn udp_local_to_work(local.name, mut local_udp, dst, mut work_conn)
	// work conn → 本地 UDP
	spawn udp_work_to_local(local.name, mut work_conn, mut local_udp)
}

// udp_local_to_work 持续从本地 UDP socket 读包，wrap 成 UDPPacket 写到 work conn。
// 把本端 UDP 源（vfrpc→local app 的来源）记入 remote_addr，让 server 侧能正确回包。
fn udp_local_to_work(proxy_name string, mut local_udp &net.UdpConn, dst net.Addr, mut work_conn &net.TcpConn) {
	mut buf := []u8{len: udp_read_buf_size}
	for {
		n, src_addr := local_udp.read(mut buf) or {
			log.warn('proxy "${proxy_name}": udp local read error: ${err.msg()}')
			return
		}
		if n == 0 {
			continue
		}
		mut pkt_content := []u8{len: n, init: 0}
		copy(mut pkt_content, buf[..n])
		msg.write_msg(mut work_conn, msg.UDPPacket{
			content:     pkt_content
			remote_addr: '${dst}'
			local_addr:  '${src_addr}'
		}) or {
			log.warn('proxy "${proxy_name}": udp write to work conn failed: ${err.msg()}')
			return
		}
	}
}

// udp_work_to_local 持续从 work conn 读 UDPPacket，write_to local UDP socket。
// V P6 MVP：使用包里的 remote_addr 作为发送目标（多用户路由在 P6+ 加 session 表）。
fn udp_work_to_local(proxy_name string, mut work_conn &net.TcpConn, mut local_udp &net.UdpConn) {
	for {
		m := msg.read_msg(mut work_conn) or {
			log.warn('proxy "${proxy_name}": udp work read error: ${err.msg()}')
			return
		}
		match m {
			msg.UDPPacket {
				local_udp.write_to(m.remote_addr_as_addr(), m.content) or {
					log.warn('proxy "${proxy_name}": udp write_to ${m.remote_addr} failed: ${err.msg()}')
				}
			}
			else {
				log.debug('proxy "${proxy_name}": drop non-UDPPacket on udp work conn')
			}
		}
	}
}

// find_proxy_config 按 name 在配置中查找代理；找不到返回 false。
fn find_proxy_config(cfg config.ClientConfig, name string) (config.ProxyConfig, bool) {
	for p in cfg.proxies {
		if p.name == name {
			return p, true
		}
	}
	return config.ProxyConfig{}, false
}
