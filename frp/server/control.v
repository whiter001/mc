// 控制会话：单个客户端（frpc）与 vfrps 之间的控制连接。
// 职责：登录校验与应答、NewProxy/Ping/CloseProxy 处理、work conn 队列、
// 代理表管理。写控制连接用 Mutex 串行化（代理线程与读循环可能同时写）。
// 控制消息直接使用 pkg.msg 的 read_msg/write_msg（v1 帧格式）。
module server

import net
import sync
import time
import crypto.rand
import pkg.msg
import pkg.auth
import pkg.util.log
import pkg.util.version

// work_conn_chan_cap work conn 队列缓冲大小。
const work_conn_chan_cap = 64

// work_conn_wait_timeout 代理等待一条 work conn 的最长等待时间。
const work_conn_wait_timeout = 10 * time.second

// ---------------------------------------------------------------------------
// 控制会话
// ---------------------------------------------------------------------------

// Control 管理单个客户端的控制会话。含 Mutex / chan，须以引用（&Control）形式
// 使用；其方法被读循环线程、代理线程、service 线程并发调用。
pub struct Control {
pub mut:
	run_id     string               // 客户端标识（服务端生成，16 字符 hex；客户端重连可自带）
	conn       &net.TcpConn         // 控制连接
	write_mu   sync.Mutex           // 串行化控制连接写入
	work_conns chan &net.TcpConn    // 客户端上报的 work conn 队列（缓冲 64，永不 close）
	work_mu    sync.Mutex           // 保护 closed 标志（work conn 注册与排空）
	closed     bool                 // 本 control 是否已关闭
	token      string               // 服务端 auth token（校验 privilege_key 用）
	proxies    map[string]&TcpProxy // 代理表
	proxies_mu sync.Mutex           // 保护代理表
	bind_addr  string               // 代理监听地址（服务端 bind_addr）
	pm         &PortManager         // 端口管理器（NewProxy 分配 remote_port 用）
}

// new_control 创建控制会话。run_id 为空时由服务端生成随机 16 字符 hex；
// 非空（客户端重连携带）时沿用客户端 run_id。
pub fn new_control(conn &net.TcpConn, token string, bind_addr string, pm &PortManager,
	run_id string) &Control {
	rid := if run_id == '' { gen_run_id() } else { run_id }
	return &Control{
		run_id:     rid
		conn:       conn
		write_mu:   sync.new_mutex()
		work_conns: chan &net.TcpConn{cap: work_conn_chan_cap}
		work_mu:    sync.new_mutex()
		token:      token
		proxies:    map[string]&TcpProxy{}
		proxies_mu: sync.new_mutex()
		bind_addr:  bind_addr
		pm:         pm
	}
}

// gen_run_id 生成 16 字符随机 hex 字符串（8 随机字节的 hex 表示）。
fn gen_run_id() string {
	b := rand.bytes(8) or {
		// 随机源不可用属极端情况：退回时间戳，保证唯一即可
		return 'run${time.now().unix_nano().str()}'
	}
	return b.hex()
}

// write_msg 向控制连接写一条消息，写操作全程持锁（代理线程、读循环、心跳共用）。
fn (mut c Control) write_msg(m msg.Message) ! {
	c.write_mu.lock()
	defer {
		c.write_mu.unlock()
	}
	msg.write_msg(mut c.conn, m)!
}

// send_req_work_conn 向客户端请求一条 work conn（写加锁，供代理线程调用）。
pub fn (mut c Control) send_req_work_conn() ! {
	c.write_msg(msg.ReqWorkConn{})!
}

// get_work_conn 从 work 队列取一条 work conn，等待超时返回 none。
// 注：work 队列永不 close，control 关闭后此处只会超时返回，由代理自行收尾。
pub fn (mut c Control) get_work_conn(timeout time.Duration) ?&net.TcpConn {
	work_ch := c.work_conns
	select {
		wc := <-work_ch {
			return wc
		}
		timeout {
			return none
		}
	}
	return none
}

// register_work_conn 注册一条客户端新连上来的 work conn（来自 NewWorkConn）。
// control 已关闭时直接关闭该连接；否则入队（缓冲满时阻塞，等待代理取用）。
pub fn (mut c Control) register_work_conn(mut conn &net.TcpConn) {
	c.work_mu.lock()
	if c.closed {
		c.work_mu.unlock()
		conn.close() or {}
		return
	}
	c.work_mu.unlock()
	c.work_conns <- conn
}

// handle_login 校验登录（privilege_key + 时间窗），通过回 LoginResp{version, run_id}，
// 失败回 LoginResp{error} 并关闭连接后返回错误。
pub fn (mut c Control) handle_login(login msg.Login) ! {
	if !auth.verify_privilege_key(c.token, login.timestamp, login.privilege_key, time.now().unix()) {
		log.warn('control ${c.run_id}: login rejected: bad privilege_key or timestamp')
		c.write_msg(msg.LoginResp{
			version: version.version
			error:   'authentication failed'
		}) or {}
		c.close()
		return error('login auth failed for run_id ${c.run_id}')
	}
	log.info('control ${c.run_id}: client login, version ${login.version}, hostname ${login.hostname}')
	c.write_msg(msg.LoginResp{
		version: version.version
		run_id:  c.run_id
	})!
}

// run 进入控制消息读循环，直到读错误（连接断开）后清理并退出。
pub fn (mut c Control) run() {
	for {
		m := msg.read_msg(mut c.conn) or {
			log.info('control ${c.run_id}: control conn closed: ${err.msg()}')
			c.close()
			return
		}
		match m {
			msg.NewProxy {
				c.handle_new_proxy(m)
			}
			msg.CloseProxy {
				c.handle_close_proxy(m)
			}
			msg.Ping {
				c.handle_ping(m)
			}
			else {
				log.warn('control ${c.run_id}: ignore unexpected message ${typeof(m).name}')
			}
		}
	}
}

// handle_new_proxy 处理 NewProxy：仅支持 tcp；分配 remote_port、启动 TcpProxy，
// 回 NewProxyResp{proxy_name, remote_addr} 或带 error 的 NewProxyResp。
fn (mut c Control) handle_new_proxy(m msg.NewProxy) {
	if m.proxy_type != 'tcp' {
		c.write_msg(msg.NewProxyResp{
			proxy_name: m.proxy_name
			error:      'unsupported proxy type "${m.proxy_type}", only "tcp" supported'
		}) or {}
		return
	}
	port := c.pm.acquire(m.remote_port) or {
		c.write_msg(msg.NewProxyResp{
			proxy_name: m.proxy_name
			error:      'allocate remote port ${m.remote_port} failed: ${err.msg()}'
		}) or {}
		return
	}
	mut pxy := new_tcp_proxy(m.proxy_name, port, c)
	real_port := pxy.start(c.bind_addr) or {
		c.pm.release(port)
		c.write_msg(msg.NewProxyResp{
			proxy_name: m.proxy_name
			error:      'listen on port ${port} failed: ${err.msg()}'
		}) or {}
		return
	}
	c.proxies_mu.lock()
	c.proxies[m.proxy_name] = pxy
	c.proxies_mu.unlock()
	// remote_addr 与 Go 版一致采用 ":port"（客户端自行拼接 server_addr）。
	log.info('control ${c.run_id}: new proxy [${m.proxy_name}] type tcp, remote_addr :${real_port}')
	c.write_msg(msg.NewProxyResp{
		proxy_name:  m.proxy_name
		remote_addr: ':${real_port}'
	}) or {}
}

// handle_ping 处理心跳：校验 privilege_key 后回 Pong；校验失败回带 error 的 Pong。
fn (mut c Control) handle_ping(m msg.Ping) {
	if !auth.verify_privilege_key(c.token, m.timestamp, m.privilege_key, time.now().unix()) {
		log.warn('control ${c.run_id}: invalid ping auth')
		c.write_msg(msg.Pong{
			error: 'invalid ping auth'
		}) or {}
		return
	}
	c.write_msg(msg.Pong{}) or {}
}

// handle_close_proxy 关闭指定代理并释放其端口。
fn (mut c Control) handle_close_proxy(m msg.CloseProxy) {
	c.proxies_mu.lock()
	mut pxy := c.proxies[m.proxy_name] or {
		c.proxies_mu.unlock()
		log.warn('control ${c.run_id}: close unknown proxy ${m.proxy_name}')
		return
	}
	c.proxies.delete(m.proxy_name)
	c.proxies_mu.unlock()
	log.info('control ${c.run_id}: close proxy [${m.proxy_name}]')
	pxy.close()
	c.pm.release(pxy.remote_port)
}

// close 关闭控制会话（幂等）：关闭控制连接、标记 closed（拒绝后续 work conn）、
// 排空并关闭已入队 work conn、关闭所有代理并释放端口。
pub fn (mut c Control) close() {
	c.work_mu.lock()
	if c.closed {
		c.work_mu.unlock()
		return
	}
	c.closed = true
	c.work_mu.unlock()

	c.conn.close() or {}

	// 排空已入队 work conn 并关闭（select-else 非阻塞排空；
	// 正在入队的连接为竞态窗口，可能漏关，由客户端侧自行断开，可接受）。
	work_ch := c.work_conns
	for {
		mut wc := &net.TcpConn{}
		mut drained := false
		select {
			wc = <-work_ch {
				drained = true
			}
			else {
				drained = false
			}
		}
		if !drained {
			break
		}
		wc.close() or {}
	}

	c.proxies_mu.lock()
	mut proxies := c.proxies.values()
	c.proxies = map[string]&TcpProxy{}
	c.proxies_mu.unlock()
	for mut pxy in proxies {
		pxy.close()
		c.pm.release(pxy.remote_port)
	}
}
