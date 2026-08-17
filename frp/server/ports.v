// 端口管理：代理 remote_port 的分配、释放与占用检查。
// 所有操作经 Mutex 串行化；acquire(0) 表示让内核分配（探测端口后返回实际端口）。
module server

import net
import sync
import pkg.util.log
import pkg.util.netx

// max_probe_tries 随机端口探测的最大尝试次数（防极端情况下探测结果被占用的自旋）。
const max_probe_tries = 5

// PortManager 管理代理端口占用状态。含 Mutex，须以引用（&PortManager）形式使用，
// 不能按值拷贝。
pub struct PortManager {
mut:
	mu   sync.Mutex // 保护 used
	bind string     // 探测端口时的绑定地址（与服务端 bind_addr 一致）
	used map[int]bool
}

// new_port_manager 创建端口管理器。bind 用于端口占用探测，须与代理实际
// 监听地址一致，否则内核分配的端口可能与监听绑定冲突。
pub fn new_port_manager(bind string) &PortManager {
	return &PortManager{
		mu:   sync.new_mutex()
		bind: bind
		used: map[int]bool{}
	}
}

// acquire 申请一个代理端口并标记占用：
// - port == 0：listen(bind:0) 探测让内核分配，返回实际端口；
// - port > 0：指定端口，已被占用则报错；
// - 返回实际端口，调用方随后须在该端口上监听（占用标记只防本进程内重复分配）。
pub fn (mut pm PortManager) acquire(port int) !int {
	pm.mu.lock()
	defer {
		pm.mu.unlock()
	}
	if port == 0 {
		for _ in 0 .. max_probe_tries {
			real := probe_free_port(pm.bind)!
			if !pm.used[real] {
				pm.used[real] = true
				log.debug('port manager: allocated random port ${real}')
				return real
			}
		}
		return error('no free random port available after ${max_probe_tries} tries')
	}
	if pm.used[port] {
		return error('port ${port} already in use')
	}
	pm.used[port] = true
	log.debug('port manager: allocated port ${port}')
	return port
}

// release 释放端口占用标记；未占用的端口释放是空操作。
pub fn (mut pm PortManager) release(port int) {
	pm.mu.lock()
	defer {
		pm.mu.unlock()
	}
	if pm.used[port] {
		pm.used.delete(port)
		log.debug('port manager: released port ${port}')
	}
}

// is_used 检查端口是否已被本管理器占用。
pub fn (mut pm PortManager) is_used(port int) bool {
	pm.mu.lock()
	defer {
		pm.mu.unlock()
	}
	return pm.used[port]
}

// probe_free_port 在 bind 上 listen 端口 0，由内核分配一个空闲端口并返回其
// 实际端口号（探测完立即关闭监听）。
fn probe_free_port(bind string) !int {
	addr := netx.join_host_port(bind, 0)
	mut l := net.listen_tcp(.ip, addr) or {
		return error('probe listen on ${addr} failed: ${err.msg()}')
	}
	a := l.addr() or {
		l.close() or {}
		return error('read probe listener addr failed: ${err.msg()}')
	}
	port := '${a}'.all_after(':').int()
	l.close() or {}
	if port <= 0 {
		return error('probe returned invalid port ${port}')
	}
	return port
}
