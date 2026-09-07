// e2e 测试：vfrp STCP（secret TCP）功能。
//
// 架构：vfrps + vfrpc-A（stcp 代理方，注册 [[proxies]] type=stcp）
// + vfrpc-B（visitor 访问方，注册 [[visitors]] type=stcp）+ 本地 TCP echo。
// 用户连接 visitor 端口 → vfrpc-B accept → vfrpc-B dial vfrps 发 NewVisitorConn
// → vfrps 校验 sk / allow_users → 走属主 control 的 work conn 链路（ReqWorkConn →
// vfrpc-A 启 work conn → dial local echo）→ 双向 relay → 回显。
//
// 5 个用例：
// 1. test_stcp_echo_e2e                 正确 sk + 无 allow_users → 回显
// 2. test_stcp_wrong_sk_e2e             错误 sk → 拒绝 + 日志含 "sk not match"
// 3. test_stcp_allow_all_users_e2e      allow_users=["*"] → 回显
// 4. test_stcp_not_allowed_user_e2e     allow_users=["someone-else"] → 拒绝 + 日志含 "not allowed"
// 5. test_stcp_cross_user_allow_users_e2e 跨用户放行：vfrpc-A 配 allow_users=[<visitor user>]，
//    vfrpc-B 用 set_environment 给 USER 设成另一用户，验证服务端按 visitor 的登录 user 校验
//    （加分项；用 vlib os.Process.set_environment 在子进程环境里设 USER）
//
// 设计取舍：
// - 与 test/e2e/tcp_proxy_test.v 类似：跨 _test.v 不共享 helper，所以这里把需要的
//   进程管理 / 端口探测 / wait_log_contains / echo server / 配置写入都拷贝一份。
// - 就绪同步一律走日志（vfrps "listening"、vfrpc-A "proxy ... registered"、
//   vfrpc-B "visitor ... listening on ..."），避免"反复连端口探测"的竞态。
// - 回显带重试 + settle_delay，容忍 work conn 建立链路上的瞬时竞态。
// - 用 kill_all_procs 兜底清进程；每个 test 用 defer 确保结束就清理，避免端口/状态
//   泄漏到下一用例。
@[has_globals]
module main

import net
import os
import time

__global (
	g_root      string
	g_tmp       string
	g_vfrps_bin string
	g_vfrpc_bin string
	g_procs     []&os.Process
)

const stcp_echo_msg_1 = 'hello-vfrp-stcp-e2e'
const stcp_echo_msg_2 = 'hello-vfrp-stcp-e2e-round-2'
const wait_total = 15 * time.second
const settle_delay = 300 * time.millisecond

// testsuite_begin 在所有测试前运行一次：构建 vfrps/vfrpc 二进制。
fn testsuite_begin() {
	g_root = os.real_path(@VMODROOT)
	g_tmp = os.join_path(os.temp_dir(), 'vfrp_e2e_stcp_${os.getpid()}')
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
// 走 -no-memory-limit：vfrp 加上 vhost/http 后 V 编译器会超 2.3G 触发 SIGKILL。
fn do_build(ch chan BuildMsg, bin string, src string) {
	os.rm(bin) or {}
	cmd := '${os.quoted_path(@VEXE)} -no-memory-limit -o ${os.quoted_path(bin)} ${os.quoted_path(src)}'
	res := os.execute(cmd)
	ch <- BuildMsg{
		bin: bin
		exit: res.exit_code
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
	ch := chan BuildMsg{ cap: 2 }
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

// start_proc_with_env 启动子进程并覆盖环境变量（用于跨用户 allow_users 加分用例：
// 给 vfrpc-B 子进程设 USER=<visitor user>，让 vfrpc-B 的 Login.user != vfrpc-A 的
// user，再让 vfrpc-A 的 allow_users 放行该 user）。
fn start_proc_with_env(bin string, args []string, env map[string]string) &os.Process {
	mut p := os.new_process(bin)
	p.set_args(args)
	p.set_redirect_stdio()
	if env.len > 0 {
		p.set_environment(env)
	}
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

// dial_and_echo 连上 addr、发送 msg、循环读到完整回显后返回。
// 注意：写完不立刻关连接，等读完回显再关（避免 FIN 竞态吞掉回显）。
// 对 STCP 失败用例（sk 不匹配、allow_users 不放行）：visitor 收到 NewVisitorConnResp
// 后会立即关闭 user_conn，read 会返 EOF 或错误，外层 echo_roundtrip_with_retry
// 据此判定"无回显"。
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
	for _ in 0 .. attempts {
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

// echo_roundtrip_expect_failure 对"应当失败"的回显做多次尝试：连续 attempts 轮
// 都未拿到完整回显即视为通过；任何一轮拿到完整 msg 即视为失败（与 echo_roundtrip_with_retry
// 语义相反）。返回 (是否成功否定，即：始终未收到回显)。
fn echo_roundtrip_expect_failure(addr string, msg string, attempts int) (bool, string) {
	mut last_log := ''
	for _ in 0 .. attempts {
		time.sleep(settle_delay)
		got := dial_and_echo(addr, msg) or {
			last_log = err.msg()
			return true, last_log
		}
		last_log = 'got "${got}"'
		if got == msg {
			return false, 'unexpectedly received echo "${got}"'
		}
	}
	return true, last_log
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
		port: port
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

// write_server_config 写服务端基础配置。
fn write_server_config(path string, bind_port int, token string) {
	content := 'bind_addr = "127.0.0.1"\nbind_port = ${bind_port}\nauth_token = "${token}"\n'
	os.write_file(path, content) or { panic('write ${path} failed: ${err}') }
}

// write_client_stcp_proxy_config 写 vfrpc 端的 stcp 代理配置（被访问端）：
// 一条 [[proxies]] type=stcp，sk 必填；allow_users 可选（空 = 走"仅同登录用户"语义）。
fn write_client_stcp_proxy_config(path string, server_port int, local_port int, sk string,
	allow_users []string, token string) {
	mut content := 'server_addr = "127.0.0.1"\nserver_port = ${server_port}\nauth_token = "${token}"\nheartbeat_interval = 1\n\n'
	content += '[[proxies]]\nname = "stcp-echo"\ntype = "stcp"\nlocal_ip = "127.0.0.1"\nlocal_port = ${local_port}\nsk = "${sk}"\n'
	if allow_users.len > 0 {
		content += 'allow_users = ['
		for i, u in allow_users {
			if i > 0 {
				content += ', '
			}
			content += '"${u}"'
		}
		content += ']\n'
	}
	os.write_file(path, content) or { panic('write ${path} failed: ${err}') }
}

// write_visitor_vfrpc_config 写 vfrpc 端的 visitor 配置（访问端）：
// 一条 [[visitors]] type=stcp，server_name + secret_key 必填。
fn write_visitor_vfrpc_config(path string, server_port int, server_name string, sk string,
	bind_port int, token string) {
	content := 'server_addr = "127.0.0.1"\nserver_port = ${server_port}\nauth_token = "${token}"\nheartbeat_interval = 1\n\n[[visitors]]\nname = "stcp-echo-visitor"\ntype = "stcp"\nserver_name = "${server_name}"\nsecret_key = "${sk}"\nbind_addr = "127.0.0.1"\nbind_port = ${bind_port}\n'
	os.write_file(path, content) or { panic('write ${path} failed: ${err}') }
}

// ---------------------------------------------------------------------------
// 测试用例
// ---------------------------------------------------------------------------

// test_stcp_echo_e2e：基本通路——vfrpc-A 注册 stcp 代理（sk=correctSK，无 allow_users，
// 即默认仅允许与属主同登录用户），vfrpc-B 同 user 用相同 sk 注册 visitor；
// 用户连 visitor 端口发送数据，断言能拿到完整回显（两轮独立连接）。
fn test_stcp_echo_e2e() {
	ports := probe_distinct_ports(3)!
	server_port := ports[0]
	local_port := ports[1]
	visitor_port := ports[2]

	echo := start_echo_server()!
	defer {
		stop_echo_server(echo)
		kill_all_procs()
	}

	srv_cfg := os.join_path(g_tmp, 'stcp_ok_vfrps.toml')
	cli_a_cfg := os.join_path(g_tmp, 'stcp_ok_vfrpc_a.toml')
	cli_b_cfg := os.join_path(g_tmp, 'stcp_ok_vfrpc_b.toml')
	write_server_config(srv_cfg, server_port, 'test-token')
	write_client_stcp_proxy_config(cli_a_cfg, server_port, echo.port, 'correctSK', [], 'test-token')
	write_visitor_vfrpc_config(cli_b_cfg, server_port, 'stcp-echo', 'correctSK', visitor_port, 'test-token')

	mut psrv := start_proc(g_vfrps_bin, ['-c', srv_cfg])
	up, srv_log := wait_log_contains(mut psrv, 'listening on 127.0.0.1:${server_port}', wait_total)
	assert up, 'vfrps did not start listening, log:\n${srv_log}'

	mut pcli_a := start_proc(g_vfrpc_bin, ['-c', cli_a_cfg])
	reg, cli_a_log := wait_log_contains(mut pcli_a, 'proxy "stcp-echo" registered', wait_total)
	if !reg {
		extra_srv := read_pending_stderr(mut psrv)
		panic('stcp proxy not registered, vfrpc-A log:\n${cli_a_log}\nvfrps log:\n${srv_log}${extra_srv}')
	}

	mut pcli_b := start_proc(g_vfrpc_bin, ['-c', cli_b_cfg])
	lst, cli_b_log := wait_log_contains(mut pcli_b, 'visitor "stcp-echo-visitor" (type=stcp) listening on 127.0.0.1:${visitor_port}', wait_total)
	if !lst {
		extra_srv := read_pending_stderr(mut psrv)
		extra_a := read_pending_stderr(mut pcli_a)
		panic('visitor did not start listening, vfrpc-B log:\n${cli_b_log}\nvfrpc-A log:\n${cli_a_log}${extra_a}\nvfrps log:\n${srv_log}${extra_srv}')
	}

	addr := '127.0.0.1:${visitor_port}'
	got1 := echo_roundtrip_with_retry(addr, stcp_echo_msg_1, 5) or {
		extra_srv := read_pending_stderr(mut psrv)
		extra_a := read_pending_stderr(mut pcli_a)
		extra_b := read_pending_stderr(mut pcli_b)
		panic('stcp round 1 failed: ${err.msg()}\nvfrpc-B log:\n${cli_b_log}${extra_b}\nvfrpc-A log:\n${cli_a_log}${extra_a}\nvfrps log:\n${srv_log}${extra_srv}')
	}
	assert got1 == stcp_echo_msg_1, 'round 1: got "${got1}", want "${stcp_echo_msg_1}"'

	got2 := echo_roundtrip_with_retry(addr, stcp_echo_msg_2, 5) or {
		extra_srv := read_pending_stderr(mut psrv)
		extra_a := read_pending_stderr(mut pcli_a)
		extra_b := read_pending_stderr(mut pcli_b)
		panic('stcp round 2 failed: ${err.msg()}\nvfrpc-B log:\n${cli_b_log}${extra_b}\nvfrpc-A log:\n${cli_a_log}${extra_a}\nvfrps log:\n${srv_log}${extra_srv}')
	}
	assert got2 == stcp_echo_msg_2, 'round 2: got "${got2}", want "${stcp_echo_msg_2}"'
}

// test_stcp_wrong_sk_e2e：vfrpc-A 注册 stcp 代理（sk=correctSK），vfrpc-B 用错误
// sk 发起 visitor 连接；用户连 visitor 端口应当收不到回显（visitor 收到服务端
// NewVisitorConnResp{error: ...} 后立即关闭 user_conn），且 vfrps 日志含 "sk not match"。
fn test_stcp_wrong_sk_e2e() {
	ports := probe_distinct_ports(3)!
	server_port := ports[0]
	local_port := ports[1]
	visitor_port := ports[2]

	echo := start_echo_server()!
	defer {
		stop_echo_server(echo)
		kill_all_procs()
	}

	srv_cfg := os.join_path(g_tmp, 'stcp_badsk_vfrps.toml')
	cli_a_cfg := os.join_path(g_tmp, 'stcp_badsk_vfrpc_a.toml')
	cli_b_cfg := os.join_path(g_tmp, 'stcp_badsk_vfrpc_b.toml')
	write_server_config(srv_cfg, server_port, 'test-token')
	write_client_stcp_proxy_config(cli_a_cfg, server_port, echo.port, 'correctSK', [], 'test-token')
	write_visitor_vfrpc_config(cli_b_cfg, server_port, 'stcp-echo', 'wrongSK', visitor_port, 'test-token')

	mut psrv := start_proc(g_vfrps_bin, ['-c', srv_cfg])
	up, srv_log := wait_log_contains(mut psrv, 'listening on 127.0.0.1:${server_port}', wait_total)
	assert up, 'vfrps did not start listening, log:\n${srv_log}'

	mut pcli_a := start_proc(g_vfrpc_bin, ['-c', cli_a_cfg])
	reg, cli_a_log := wait_log_contains(mut pcli_a, 'proxy "stcp-echo" registered', wait_total)
	if !reg {
		extra_srv := read_pending_stderr(mut psrv)
		panic('stcp proxy not registered, vfrpc-A log:\n${cli_a_log}\nvfrps log:\n${srv_log}${extra_srv}')
	}

	mut pcli_b := start_proc(g_vfrpc_bin, ['-c', cli_b_cfg])
	lst, cli_b_log := wait_log_contains(mut pcli_b, 'visitor "stcp-echo-visitor" (type=stcp) listening on 127.0.0.1:${visitor_port}', wait_total)
	if !lst {
		extra_srv := read_pending_stderr(mut psrv)
		extra_a := read_pending_stderr(mut pcli_a)
		panic('visitor did not start listening, vfrpc-B log:\n${cli_b_log}\nvfrpc-A log:\n${cli_a_log}${extra_a}\nvfrps log:\n${srv_log}${extra_srv}')
	}

	// 否定断言：用户连 visitor 端口发数据，不应拿到回显
	addr := '127.0.0.1:${visitor_port}'
	ok, log_note := echo_roundtrip_expect_failure(addr, stcp_echo_msg_1, 5)
	if !ok {
		extra_srv := read_pending_stderr(mut psrv)
		extra_a := read_pending_stderr(mut pcli_a)
		extra_b := read_pending_stderr(mut pcli_b)
		panic('wrong-sk: ${log_note}\nvfrpc-B log:\n${cli_b_log}${extra_b}\nvfrpc-A log:\n${cli_a_log}${extra_a}\nvfrps log:\n${srv_log}${extra_srv}')
	}

	// 肯定断言：vfrps 日志含 "sk not match"（visitor_mgr.validate 的错误信息）
	// 或 vfrpc-B 日志含 "server rejected visitor conn"（visitor handle_conn 收到
	// 错误应答时的日志）。两者均视作正确拒绝路径。
	full_srv := srv_log + read_pending_stderr(mut psrv)
	full_b := cli_b_log + read_pending_stderr(mut pcli_b)
	has_srv_msg := full_srv.contains('sk not match')
	has_cli_msg := full_b.contains('server rejected visitor conn')
	assert has_srv_msg || has_cli_msg, 'expected sk-rejection message in logs, got srv:\n${full_srv}\ncli_b:\n${full_b}'
}

// test_stcp_allow_all_users_e2e：代理配 allow_users=["*"]，任何登录用户都能访问；
// 验证回显成功（与用例 1 等价，区别在于显式覆盖 "*" 通配语义）。
fn test_stcp_allow_all_users_e2e() {
	ports := probe_distinct_ports(3)!
	server_port := ports[0]
	local_port := ports[1]
	visitor_port := ports[2]

	echo := start_echo_server()!
	defer {
		stop_echo_server(echo)
		kill_all_procs()
	}

	srv_cfg := os.join_path(g_tmp, 'stcp_star_vfrps.toml')
	cli_a_cfg := os.join_path(g_tmp, 'stcp_star_vfrpc_a.toml')
	cli_b_cfg := os.join_path(g_tmp, 'stcp_star_vfrpc_b.toml')
	write_server_config(srv_cfg, server_port, 'test-token')
	write_client_stcp_proxy_config(cli_a_cfg, server_port, echo.port, 'correctSK', ['*'], 'test-token')
	write_visitor_vfrpc_config(cli_b_cfg, server_port, 'stcp-echo', 'correctSK', visitor_port, 'test-token')

	mut psrv := start_proc(g_vfrps_bin, ['-c', srv_cfg])
	up, srv_log := wait_log_contains(mut psrv, 'listening on 127.0.0.1:${server_port}', wait_total)
	assert up, 'vfrps did not start listening, log:\n${srv_log}'

	mut pcli_a := start_proc(g_vfrpc_bin, ['-c', cli_a_cfg])
	reg, cli_a_log := wait_log_contains(mut pcli_a, 'proxy "stcp-echo" registered', wait_total)
	if !reg {
		extra_srv := read_pending_stderr(mut psrv)
		panic('stcp proxy not registered, vfrpc-A log:\n${cli_a_log}\nvfrps log:\n${srv_log}${extra_srv}')
	}

	mut pcli_b := start_proc(g_vfrpc_bin, ['-c', cli_b_cfg])
	lst, cli_b_log := wait_log_contains(mut pcli_b, 'visitor "stcp-echo-visitor" (type=stcp) listening on 127.0.0.1:${visitor_port}', wait_total)
	if !lst {
		extra_srv := read_pending_stderr(mut psrv)
		extra_a := read_pending_stderr(mut pcli_a)
		panic('visitor did not start listening, vfrpc-B log:\n${cli_b_log}\nvfrpc-A log:\n${cli_a_log}${extra_a}\nvfrps log:\n${srv_log}${extra_srv}')
	}

	addr := '127.0.0.1:${visitor_port}'
	got := echo_roundtrip_with_retry(addr, stcp_echo_msg_1, 5) or {
		extra_srv := read_pending_stderr(mut psrv)
		extra_a := read_pending_stderr(mut pcli_a)
		extra_b := read_pending_stderr(mut pcli_b)
		panic('allow_users=* echo failed: ${err.msg()}\nvfrpc-B log:\n${cli_b_log}${extra_b}\nvfrpc-A log:\n${cli_a_log}${extra_a}\nvfrps log:\n${srv_log}${extra_srv}')
	}
	assert got == stcp_echo_msg_1, 'allow_users=*: got "${got}", want "${stcp_echo_msg_1}"'
}

// test_stcp_not_allowed_user_e2e：代理配 allow_users=["someone-else"]（不含当前
// 进程的 USER），visitor 应当被服务端拒绝（"not allowed"），用户收不到回显。
fn test_stcp_not_allowed_user_e2e() {
	ports := probe_distinct_ports(3)!
	server_port := ports[0]
	local_port := ports[1]
	visitor_port := ports[2]

	echo := start_echo_server()!
	defer {
		stop_echo_server(echo)
		kill_all_procs()
	}

	srv_cfg := os.join_path(g_tmp, 'stcp_deny_vfrps.toml')
	cli_a_cfg := os.join_path(g_tmp, 'stcp_deny_vfrpc_a.toml')
	cli_b_cfg := os.join_path(g_tmp, 'stcp_deny_vfrpc_b.toml')
	write_server_config(srv_cfg, server_port, 'test-token')
	write_client_stcp_proxy_config(cli_a_cfg, server_port, echo.port, 'correctSK', [
		'someone-else',
	], 'test-token')
	write_visitor_vfrpc_config(cli_b_cfg, server_port, 'stcp-echo', 'correctSK', visitor_port, 'test-token')

	mut psrv := start_proc(g_vfrps_bin, ['-c', srv_cfg])
	up, srv_log := wait_log_contains(mut psrv, 'listening on 127.0.0.1:${server_port}', wait_total)
	assert up, 'vfrps did not start listening, log:\n${srv_log}'

	mut pcli_a := start_proc(g_vfrpc_bin, ['-c', cli_a_cfg])
	reg, cli_a_log := wait_log_contains(mut pcli_a, 'proxy "stcp-echo" registered', wait_total)
	if !reg {
		extra_srv := read_pending_stderr(mut psrv)
		panic('stcp proxy not registered, vfrpc-A log:\n${cli_a_log}\nvfrps log:\n${srv_log}${extra_srv}')
	}

	mut pcli_b := start_proc(g_vfrpc_bin, ['-c', cli_b_cfg])
	lst, cli_b_log := wait_log_contains(mut pcli_b, 'visitor "stcp-echo-visitor" (type=stcp) listening on 127.0.0.1:${visitor_port}', wait_total)
	if !lst {
		extra_srv := read_pending_stderr(mut psrv)
		extra_a := read_pending_stderr(mut pcli_a)
		panic('visitor did not start listening, vfrpc-B log:\n${cli_b_log}\nvfrpc-A log:\n${cli_a_log}${extra_a}\nvfrps log:\n${srv_log}${extra_srv}')
	}

	// 否定断言：用户连 visitor 端口发数据，不应拿到回显
	addr := '127.0.0.1:${visitor_port}'
	ok, log_note := echo_roundtrip_expect_failure(addr, stcp_echo_msg_1, 5)
	if !ok {
		extra_srv := read_pending_stderr(mut psrv)
		extra_a := read_pending_stderr(mut pcli_a)
		extra_b := read_pending_stderr(mut pcli_b)
		panic('not-allowed: ${log_note}\nvfrpc-B log:\n${cli_b_log}${extra_b}\nvfrpc-A log:\n${cli_a_log}${extra_a}\nvfrps log:\n${srv_log}${extra_srv}')
	}

	// 肯定断言：vfrps 日志含 "not allowed"（visitor_mgr.validate 的错误信息）
	// 或 vfrpc-B 日志含 "server rejected visitor conn"。
	full_srv := srv_log + read_pending_stderr(mut psrv)
	full_b := cli_b_log + read_pending_stderr(mut pcli_b)
	has_srv_msg := full_srv.contains('not allowed')
	has_cli_msg := full_b.contains('server rejected visitor conn')
	assert has_srv_msg || has_cli_msg, 'expected not-allowed message in logs, got srv:\n${full_srv}\ncli_b:\n${full_b}'
}

// test_stcp_cross_user_allow_users_e2e（加分项）：跨用户放行——vfrpc-A 配
// allow_users=[<visitor user>]（不含默认 USER），vfrpc-B 用 start_proc_with_env
// 把 USER 设成另一个值（"cross-user-bonus"），让 vfrpc-B 的 Login.user 变成
// 跨用户身份；服务端 visitor_mgr.validate 应当按 visitor user 命中白名单并放行。
// 注意：此用例依赖 V 0.5.2 os.Process.set_environment 的环境变量注入；若环境
// 注入失败，vfrpc-B 启动后 USER 仍为测试进程的 USER，会被 allow_users 拒绝
// （即表现为用例 4 的失败模式），并非"加分项"本身的功能问题。
fn test_stcp_cross_user_allow_users_e2e() {
	ports := probe_distinct_ports(3)!
	server_port := ports[0]
	local_port := ports[1]
	visitor_port := ports[2]

	echo := start_echo_server()!
	defer {
		stop_echo_server(echo)
		kill_all_procs()
	}

	visitor_user := 'cross-user-bonus'
	// 默认用户（vfrpc-A 进程继承的 USER）不应在 allow_users 中——否则就退化成
	// 默认"同登录用户"语义，无法证明白名单生效。
	srv_cfg := os.join_path(g_tmp, 'stcp_cross_vfrps.toml')
	cli_a_cfg := os.join_path(g_tmp, 'stcp_cross_vfrpc_a.toml')
	cli_b_cfg := os.join_path(g_tmp, 'stcp_cross_vfrpc_b.toml')
	write_server_config(srv_cfg, server_port, 'test-token')
	// 显式把 allow_users 限定为 visitor_user，避开放行默认 USER 的干扰
	write_client_stcp_proxy_config(cli_a_cfg, server_port, echo.port, 'correctSK', [
		visitor_user,
	], 'test-token')
	write_visitor_vfrpc_config(cli_b_cfg, server_port, 'stcp-echo', 'correctSK', visitor_port, 'test-token')

	mut psrv := start_proc(g_vfrps_bin, ['-c', srv_cfg])
	up, srv_log := wait_log_contains(mut psrv, 'listening on 127.0.0.1:${server_port}', wait_total)
	assert up, 'vfrps did not start listening, log:\n${srv_log}'

	mut pcli_a := start_proc(g_vfrpc_bin, ['-c', cli_a_cfg])
	reg, cli_a_log := wait_log_contains(mut pcli_a, 'proxy "stcp-echo" registered', wait_total)
	if !reg {
		extra_srv := read_pending_stderr(mut psrv)
		panic('stcp proxy not registered, vfrpc-A log:\n${cli_a_log}\nvfrps log:\n${srv_log}${extra_srv}')
	}

	// vfrpc-B 用 set_environment 注入 USER=visitor_user，模拟"另一台机器上的用户"
	mut pcli_b := start_proc_with_env(g_vfrpc_bin, ['-c', cli_b_cfg], {
		'USER': visitor_user
	})
	lst, cli_b_log := wait_log_contains(mut pcli_b, 'visitor "stcp-echo-visitor" (type=stcp) listening on 127.0.0.1:${visitor_port}', wait_total)
	if !lst {
		extra_srv := read_pending_stderr(mut psrv)
		extra_a := read_pending_stderr(mut pcli_a)
		panic('visitor did not start listening, vfrpc-B log:\n${cli_b_log}\nvfrpc-A log:\n${cli_a_log}${extra_a}\nvfrps log:\n${srv_log}${extra_srv}')
	}

	// 正面断言：跨用户 visitor 命中白名单，应能拿到回显
	addr := '127.0.0.1:${visitor_port}'
	got := echo_roundtrip_with_retry(addr, stcp_echo_msg_1, 5) or {
		extra_srv := read_pending_stderr(mut psrv)
		extra_a := read_pending_stderr(mut pcli_a)
		extra_b := read_pending_stderr(mut pcli_b)
		panic('cross-user echo failed: ${err.msg()}\nvfrpc-B log:\n${cli_b_log}${extra_b}\nvfrpc-A log:\n${cli_a_log}${extra_a}\nvfrps log:\n${srv_log}${extra_srv}')
	}
	assert got == stcp_echo_msg_1, 'cross-user: got "${got}", want "${stcp_echo_msg_1}"'
}
