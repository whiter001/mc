// e2e 测试：真实 vfrps + vfrpc 进程 + 进程内 TCP echo 服务，
// 走完整链路：vfrpc 登录 → 注册代理 → 用户连接 remote_port → 请求 work conn
// → StartWorkConn → 双向 relay 到本地 echo → 回显。
// 另一个用例验证错误 token 时登录被拒绝、代理端口永不开放。
//
// 设计取舍：
// - 用日志而非"连 remote_port 探测"来同步代理就绪。反复开/关 remote_port 连接
//   会触发服务端 accept_loop 的竞态（spawn 线程持栈地址），导致偶发连接被误关；
//   日志等待只产生真正的业务连接，稳定得多。
// - 回显带重试 + 间隔，容忍服务端偶发的工作连接建立竞态，又不掩盖真实故障。
@[has_globals]
module main

import net
import os
import time

__global (
	g_root      string // 项目根目录（@VMODROOT）
	g_tmp       string // 本测试专用临时目录（按 pid 隔离）
	g_vfrps_bin string // 构建产物 vfrps
	g_vfrpc_bin string // 构建产物 vfrpc
	g_procs     []&os.Process // 已启动的子进程（testsuite_end 兜底清理）
)

const echo_msg_1 = 'hello-vfrp-e2e'
const echo_msg_2 = 'hello-vfrp-e2e-round-2'
const wait_total = 15 * time.second
const observe_interval = 250 * time.millisecond
const settle_delay = 300 * time.millisecond

// testsuite_begin 在文件内所有测试前运行一次：构建 vfrps/vfrpc 二进制。
fn testsuite_begin() {
	g_root = os.real_path(@VMODROOT)
	g_tmp = os.join_path(os.temp_dir(), 'vfrp_e2e_${os.getpid()}')
	os.rmdir_all(g_tmp) or {}
	os.mkdir_all(g_tmp) or { panic('cannot create tmp dir ${g_tmp}: ${err}') }

	g_vfrps_bin = os.join_path(g_tmp, 'vfrps')
	g_vfrpc_bin = os.join_path(g_tmp, 'vfrpc')

	build_binaries([g_vfrps_bin, g_vfrpc_bin]!, [os.join_path(g_root, 'cmd', 'vfrps'),
		os.join_path(g_root, 'cmd', 'vfrpc')]!)
}

// testsuite_end 在所有测试结束后运行（无论成败）：清理子进程与临时目录。
fn testsuite_end() {
	kill_all_procs()
	os.rmdir_all(g_tmp) or {}
}

// BuildMsg 记录一次子构建的结果（并行构建时经 channel 回传）。
struct BuildMsg {
	bin    string
	exit   int
	output string
}

// do_build 在独立线程里执行一次 v 构建，把结果发回 channel。
fn do_build(ch chan BuildMsg, bin string, src string) {
	os.rm(bin) or {}
	cmd := '${os.quoted_path(@VEXE)} -o ${os.quoted_path(bin)} ${os.quoted_path(src)}'
	res := os.execute(cmd)
	ch <- BuildMsg{
		bin:    bin
		exit:   res.exit_code
		output: res.output
	}
}

// build_binaries 并行构建两个二进制；校验产物存在、非空且 mtime 是新的
// （V 0.5.2 v3 偶发 Boehm 崩溃不产二进制，必须显式检查）。
fn build_binaries(bins [2]string, srcs [2]string) {
	mut before := [2]i64{init: 0}
	for i in 0 .. 2 {
		before[i] = os.file_last_mod_unix(bins[i])
	}
	ch := chan BuildMsg{cap: 2}
	for i in 0 .. 2 {
		spawn do_build(ch, bins[i], srcs[i])
	}
	mut results := map[string]BuildMsg{}
	for _ in 0 .. 2 {
		msg := <-ch
		results[msg.bin] = msg
	}
	for i in 0 .. 2 {
		bin := bins[i]
		msg := results[bin]
		if msg.exit != 0 {
			panic('build failed for ${bin}:\n${msg.output}')
		}
		if !os.exists(bin) {
			panic('v produced no binary at ${bin} (possible Boehm crash)')
		}
		if os.file_size(bin) <= 0 {
			panic('binary ${bin} has zero size')
		}
		if os.file_last_mod_unix(bin) < before[i] {
			panic('binary ${bin} has stale mtime')
		}
	}
}

// ---------------------------------------------------------------------------
// 进程管理
// ---------------------------------------------------------------------------

// start_proc 启动子进程并登记到全局列表（testsuite_end 兜底清理）。
fn start_proc(bin string, args []string) &os.Process {
	mut p := os.new_process(bin)
	p.set_args(args)
	p.set_redirect_stdio()
	p.run()
	g_procs << p
	return p
}

// kill_proc 优先 SIGTERM 优雅退出；3 秒未退出再 SIGKILL；最后 reap 并释放资源。
fn kill_proc(mut p &os.Process) {
	if p.status !in [.running, .stopped] {
		p.close()
		return
	}
	p.signal_term()
	deadline := time.now().add(3 * time.second)
	for p.is_alive() && time.now() < deadline {
		time.sleep(50 * time.millisecond)
	}
	if p.is_alive() {
		p.signal_kill()
	}
	p.wait()
	p.close()
}

// kill_all_procs 杀死全部已登记子进程（幂等，重复调用无害）。
fn kill_all_procs() {
	mut procs := g_procs.clone()
	g_procs = []&os.Process{}
	for mut pp in procs {
		kill_proc(mut pp)
	}
}

// read_pending_stderr 非阻塞地读出子进程 stderr 管道里当前可读的内容。
fn read_pending_stderr(mut p &os.Process) string {
	mut out := ''
	for p.is_pending(.stderr) {
		out += p.stderr_read()
	}
	return out
}

// wait_log_contains 轮询读子进程 stderr，直到累计日志出现 needle 或超时。
// 返回 (是否命中, 累计日志)，累计日志供断言失败时打印诊断。
fn wait_log_contains(mut p &os.Process, needle string, timeout time.Duration) (bool, string) {
	mut log_out := ''
	deadline := time.now().add(timeout)
	for time.now() < deadline {
		log_out += read_pending_stderr(mut p)
		if log_out.contains(needle) {
			return true, log_out
		}
		time.sleep(200 * time.millisecond)
	}
	log_out += read_pending_stderr(mut p)
	return log_out.contains(needle), log_out
}

// ---------------------------------------------------------------------------
// 网络工具
// ---------------------------------------------------------------------------

// probe_free_port 探测一个空闲的高端口：listen(:0) 让内核分配再关闭。
fn probe_free_port() !int {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or {
		return error('probe: listen failed: ${err.msg()}')
	}
	addr := l.addr() or {
		l.close() or {}
		return error('probe: addr failed: ${err.msg()}')
	}
	port := addr.str().all_after(':').int()
	l.close() or {}
	return port
}

// probe_distinct_ports 探测 n 个互不相同的空闲端口。
fn probe_distinct_ports(n int) ![]int {
	mut ports := []int{}
	for ports.len < n {
		p := probe_free_port()!
		if p !in ports {
			ports << p
		}
	}
	return ports
}

// dial_ok 尝试连接 addr 并立即关闭；成功返回 true。
fn dial_ok(addr string) bool {
	mut c := net.dial_tcp(addr) or { return false }
	c.close() or {}
	return true
}

// dial_and_echo 连上 addr、发送 msg、循环读到完整回显后返回。
// 注意：写完不立刻关连接，等读完回显再关（避免 FIN 竞态吞掉回显）。
fn dial_and_echo(addr string, msg string) !string {
	mut c := net.dial_tcp(addr) or { return error('dial ${addr} failed: ${err.msg()}') }
	defer {
		c.close() or {}
	}
	c.set_read_deadline(time.now().add(5 * time.second))
	c.write_string(msg) or { return error('write to ${addr} failed: ${err.msg()}') }
	mut out := []u8{}
	mut buf := []u8{len: 256}
	for out.len < msg.len {
		n := c.read(mut buf) or {
			if out.len == 0 {
				return error('read from ${addr} failed: ${err.msg()}')
			}
			break
		}
		if n == 0 {
			break
		}
		out << buf[..n]
	}
	return out.bytestr()
}

// echo_roundtrip_with_retry 对回显做多次尝试：每轮先小睡再连，避免立即重连
// 撞上服务端偶发的工作连接建立竞态；重试耗尽仍失败则返回最后错误。
fn echo_roundtrip_with_retry(addr string, msg string, attempts int) !string {
	mut last_err := ''
	for i in 0 .. attempts {
		time.sleep(settle_delay)
		got := dial_and_echo(addr, msg) or {
			last_err = err.msg()
			continue
		}
		if got == msg {
			return got
		}
		last_err = 'echo mismatch: got "${got}", want "${msg}"'
	}
	return error('echo roundtrip failed after ${attempts} attempts: ${last_err}')
}

// ---------------------------------------------------------------------------
// 进程内 TCP echo 服务（收什么回什么）
// ---------------------------------------------------------------------------

struct EchoServer {
mut:
	listener &net.TcpListener
	port     int
}

fn start_echo_server() !&EchoServer {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or {
		return error('echo: listen failed: ${err.msg()}')
	}
	port :=
		(l.addr() or { return error('echo: addr failed: ${err.msg()}') }).str().all_after(':').int()
	spawn echo_accept_loop(mut l)
	return &EchoServer{
		listener: l
		port:     port
	}
}

fn stop_echo_server(s &EchoServer) {
	mut l := s.listener
	l.close() or {}
}

fn echo_accept_loop(mut l net.TcpListener) {
	for {
		mut conn := l.accept() or { return }
		spawn echo_handler(mut conn)
	}
}

fn echo_handler(mut c net.TcpConn) {
	mut buf := []u8{len: 4096}
	for {
		n := c.read(mut buf) or { break }
		if n == 0 {
			break
		}
		c.write(buf[..n]) or { break }
	}
	c.close() or {}
}

// ---------------------------------------------------------------------------
// 配置写入
// ---------------------------------------------------------------------------

fn write_server_config(path string, bind_port int, token string) {
	content := 'bind_addr = "127.0.0.1"\nbind_port = ${bind_port}\nauth_token = "${token}"\n'
	os.write_file(path, content) or { panic('write ${path} failed: ${err}') }
}

fn write_client_config(path string, server_port int, local_port int, remote_port int, token string) {
	content := 'server_addr = "127.0.0.1"\nserver_port = ${server_port}\nauth_token = "${token}"\nheartbeat_interval = 1\n\n[[proxies]]\nname = "e2e"\ntype = "tcp"\nlocal_ip = "127.0.0.1"\nlocal_port = ${local_port}\nremote_port = ${remote_port}\n'
	os.write_file(path, content) or { panic('write ${path} failed: ${err}') }
}

// ---------------------------------------------------------------------------
// 测试用例
// ---------------------------------------------------------------------------

// test_tcp_proxy_e2e：起真实 vfrps + vfrpc + echo 服务，经代理端口做两轮回显。
fn test_tcp_proxy_e2e() {
	ports := probe_distinct_ports(2)!
	server_port := ports[0]
	remote_port := ports[1]

	echo := start_echo_server()!
	defer {
		stop_echo_server(echo)
		kill_all_procs()
	}

	srv_cfg := os.join_path(g_tmp, 'tcp_proxy_vfrps.toml')
	cli_cfg := os.join_path(g_tmp, 'tcp_proxy_vfrpc.toml')
	write_server_config(srv_cfg, server_port, 'test-token')
	write_client_config(cli_cfg, server_port, echo.port, remote_port, 'test-token')

	mut psrv := start_proc(g_vfrps_bin, ['-c', srv_cfg])
	up, srv_log := wait_log_contains(mut psrv, 'listening on 127.0.0.1:${server_port}', wait_total)
	assert up, 'vfrps did not start listening, log:\n${srv_log}'

	mut pcli := start_proc(g_vfrpc_bin, ['-c', cli_cfg])
	reg, cli_log := wait_log_contains(mut pcli, 'proxy "e2e" registered', wait_total)
	assert reg, 'proxy ${remote_port} not registered, client log:\n${cli_log}'

	addr := '127.0.0.1:${remote_port}'
	got1 := echo_roundtrip_with_retry(addr, echo_msg_1, 5)!
	assert got1 == echo_msg_1, 'round 1: got "${got1}", want "${echo_msg_1}"'

	// 第二条独立连接：确认 work conn 申请/复用链路对每连接都正常
	got2 := echo_roundtrip_with_retry(addr, echo_msg_2, 5)!
	assert got2 == echo_msg_2, 'round 2: got "${got2}", want "${echo_msg_2}"'
}

// test_wrong_token_rejected：vfrpc 用错误 token，登录被拒并重试，
// 代理端口在观察期内始终连不上，且 vfrpc stderr 出现 login failed。
fn test_wrong_token_rejected() {
	ports := probe_distinct_ports(3)!
	server_port := ports[0]
	local_port := ports[1]
	remote_port := ports[2]

	srv_cfg := os.join_path(g_tmp, 'wrong_token_vfrps.toml')
	cli_cfg := os.join_path(g_tmp, 'wrong_token_vfrpc.toml')
	write_server_config(srv_cfg, server_port, 'test-token')
	write_client_config(cli_cfg, server_port, local_port, remote_port, 'wrong-token')

	mut psrv := start_proc(g_vfrps_bin, ['-c', srv_cfg])
	defer {
		kill_all_procs()
	}
	up, srv_log := wait_log_contains(mut psrv, 'listening on 127.0.0.1:${server_port}', wait_total)
	assert up, 'vfrps did not start listening, log:\n${srv_log}'

	mut pcli := start_proc(g_vfrpc_bin, ['-c', cli_cfg])

	// 观察 ~8s：远程代理端口必须始终连不上；同时累积 vfrpc stderr。
	mut err_log := ''
	mut never_up := true
	deadline := time.now().add(8 * time.second)
	for time.now() < deadline {
		err_log += read_pending_stderr(mut pcli)
		if dial_ok('127.0.0.1:${remote_port}') {
			never_up = false
			break
		}
		time.sleep(observe_interval)
	}
	err_log += read_pending_stderr(mut pcli)

	assert never_up, 'remote port ${remote_port} became reachable despite wrong token'
	assert !dial_ok('127.0.0.1:${remote_port}'), 'remote port ${remote_port} connectable after wait'
	assert err_log.contains('login failed'), 'vfrpc stderr did not report login failure, got:\n${err_log}'
}
