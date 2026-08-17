// 客户端控制连接：登录会话的载体。
// Control 持有控制连接的共享状态（conn + 写锁 + 会话标识 run_id），
// 提供加锁写与读循环。读循环出错返回错误，由 Service 统一重连。
module client

import net
import sync
import time
import pkg.config
import pkg.msg
import pkg.util.netx
import pkg.util.log

// Control 封装一条控制连接及其共享状态。
// 并发模型：
// - conn 只被两个线程访问 —— 读循环（read_loop）独占读；
//   心跳线程 / Service 主线程通过 write_msg（write_mu 保护）独占写；
// - stopped 由 Service 在重连前置位（stop），心跳线程轮询（is_stopped）退出。
pub struct Control {
pub:
	cfg    config.ClientConfig
	run_id string
mut:
	conn      &net.TcpConn
	write_mu  sync.Mutex
	stop_mu   sync.Mutex
	stopped   bool
	last_pong i64
}

// new_control 拨号连接服务器并构造 Control（尚未登录）。
// 返回堆分配的引用：spawn 心跳/读循环等需要跨线程共享同一对象。
pub fn new_control(cfg config.ClientConfig, run_id string) !&Control {
	addr := netx.join_host_port(cfg.server_addr, cfg.server_port)
	mut conn := net.dial_tcp(addr) or { return error('dial server ${addr} failed: ${err.msg()}') }
	return &Control{
		cfg:      cfg
		run_id:   run_id
		conn:     conn
		write_mu: sync.new_mutex()
		stop_mu:  sync.new_mutex()
	}
}

// write_msg 加锁写一条控制消息。所有写控制连接的操作共用这把锁。
fn (mut c Control) write_msg(m msg.Message) ! {
	c.write_mu.lock()
	defer {
		c.write_mu.unlock()
	}
	mut conn := c.conn
	msg.write_msg(mut conn, m)!
}

// stop 标记会话终止（重连前调用），心跳线程据此退出。
fn (mut c Control) stop() {
	c.stop_mu.lock()
	defer {
		c.stop_mu.unlock()
	}
	c.stopped = true
}

// is_stopped 判断会话是否已被终止。
fn (mut c Control) is_stopped() bool {
	c.stop_mu.lock()
	defer {
		c.stop_mu.unlock()
	}
	return c.stopped
}

// close 关闭控制连接（幂等，重复调用无害）。
fn (mut c Control) close() {
	mut conn := c.conn
	conn.close() or {}
}

// read_login_resp 读取下一条消息并断言是 LoginResp（登录应答专用）。
fn (mut c Control) read_login_resp() !msg.LoginResp {
	mut conn := c.conn
	m := msg.read_msg(mut conn)!
	match m {
		msg.LoginResp {
			return m
		}
		else {
			return error('login: expected LoginResp, got ${m.type_name()}')
		}
	}
}

// read_loop 控制连接读循环，分派各消息：
// - ReqWorkConn → spawn 一个 work conn 线程（见 proxy.v）
// - NewProxyResp → 记录代理注册结果
// - Pong → 记录 last_pong（心跳超时判定留待 P5）
// 读循环出错（对端关闭 / 网络错误）即返回错误，由 Service 统一重连。
fn (mut c Control) read_loop() ! {
	for {
		mut conn := c.conn
		m := msg.read_msg(mut conn)!
		match m {
			msg.ReqWorkConn {
				log.debug('received ReqWorkConn, opening a new work conn')
				spawn handle_work_conn(c.cfg, c.run_id)
			}
			msg.NewProxyResp {
				if m.error != '' {
					log.error('proxy "${m.proxy_name}" start failed: ${m.error}')
				} else {
					log.info('proxy "${m.proxy_name}" registered, remote addr: ${m.remote_addr}')
				}
			}
			msg.Pong {
				c.last_pong = time.now().unix()
				log.debug('received heartbeat pong')
			}
			else {
				log.debug('ignoring unexpected message: ${m.type_name()}')
			}
		}
	}
}
