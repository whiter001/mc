// 客户端 work conn 处理：一条 work conn 对接一条本地 TCP 连接。
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
		log.warn('proxy "${local.name}": udp proxy not supported yet (P6), closing work conn')
		work_conn.close() or {}
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

// find_proxy_config 按 name 在配置中查找代理；找不到返回 false。
fn find_proxy_config(cfg config.ClientConfig, name string) (config.ProxyConfig, bool) {
	for p in cfg.proxies {
		if p.name == name {
			return p, true
		}
	}
	return config.ProxyConfig{}, false
}
