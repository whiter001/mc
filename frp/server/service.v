// 服务端主体：监听 bind_addr:bind_port，按连接首条消息分发——Login 建控制会话，
// NewWorkConn 注册 work conn，其余类型直接关闭。SIGINT/SIGTERM 优雅退出（关 listener）。
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

// Service 服务端。含 Mutex，须以引用（&Service）形式使用；accept 循环线程、
// 各连接处理线程并发访问。
pub struct Service {
pub mut:
	cfg         config.ServerConfig
	listener    &net.TcpListener
	pm          &PortManager
	controls    map[string]&Control // run_id -> control
	controls_mu sync.Mutex
	stop        bool // 收到退出信号后置位
	closed      bool
	close_mu    sync.Mutex
}

// new_service 创建服务端实例（含端口管理器）。
pub fn new_service(cfg config.ServerConfig) &Service {
	return &Service{
		cfg:         cfg
		listener:    unsafe { nil }
		pm:          new_port_manager(cfg.bind_addr)
		controls:    map[string]&Control{}
		controls_mu: sync.new_mutex()
		close_mu:    sync.new_mutex()
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
	mut ctl := new_control(conn, s.cfg.auth_token, s.cfg.bind_addr, s.pm, login.run_id)
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
pub fn (mut s Service) unregister_control(ctl &Control) {
	s.controls_mu.lock()
	defer {
		s.controls_mu.unlock()
	}
	if cur := s.controls[ctl.run_id] {
		if cur == ctl {
			s.controls.delete(ctl.run_id)
		}
	}
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
	s.controls_mu.lock()
	mut ctls := s.controls.values()
	s.controls_mu.unlock()
	for mut ctl in ctls {
		ctl.close()
	}
}

// is_closed 返回服务是否已关闭。
pub fn (mut s Service) is_closed() bool {
	s.close_mu.lock()
	defer {
		s.close_mu.unlock()
	}
	return s.closed
}
