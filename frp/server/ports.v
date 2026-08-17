// 端口管理：代理 remote_port 的分配、释放与占用检查。
// 所有操作经 Mutex 串行化；acquire(0) 表示让内核分配（探测端口后返回实际端口）。
module server

import rand
import net
import sync
import pkg.util.log
import pkg.util.netx

// udp_ephemeral_lo / udp_ephemeral_hi UDP 随机端口探测的候选范围。
// V 0.5.2 的 UdpConn 不暴露绑定后的本地地址（str() 是 TODO），无法走"bind(:0) → 读端口"
// 的常规路径；改为在该范围里随机挑、bind 试占用、失败重试。
const udp_ephemeral_lo = 40000
const udp_ephemeral_hi = 60000

// max_probe_tries 随机端口探测的最大尝试次数（防极端情况下探测结果被占用的自旋）。
const max_probe_tries = 5

// PortManager 管理代理端口占用状态。含 Mutex，须以引用（&PortManager）形式使用，
// 不能按值拷贝。
pub struct PortManager {
mut:
	mu   sync.Mutex      // 保护 used
	bind string          // 探测端口时的绑定地址（与服务端 bind_addr 一致）
	used map[string]bool // 协议隔离：key = "<proto>:<port>"，避免 TCP/UDP 同端口冲突
}

// new_port_manager 创建端口管理器。bind 用于端口占用探测，须与代理实际
// 监听地址一致，否则内核分配的端口可能与监听绑定冲突。
pub fn new_port_manager(bind string) &PortManager {
	return &PortManager{
		mu:   sync.new_mutex()
		bind: bind
		used: map[string]bool{}
	}
}

// acquire 申请一个 TCP 代理端口并标记占用：
// - port == 0：listen(bind:0) 探测让内核分配，返回实际端口；
// - port > 0：指定端口，已被占用则报错；
// - 返回实际端口，调用方随后须在该端口上监听（占用标记只防本进程内重复分配）。
pub fn (mut pm PortManager) acquire(port int) !int {
	return pm.acquire_proto('tcp', port)
}

// acquire_udp 同 acquire，但探测/占用走 UDP 命名空间。
// TCP/UDP 在同一端口号上互不冲突；用协议前缀 key 隔离。
pub fn (mut pm PortManager) acquire_udp(port int) !int {
	return pm.acquire_proto('udp', port)
}

fn (mut pm PortManager) acquire_proto(proto string, port int) !int {
	pm.mu.lock()
	defer {
		pm.mu.unlock()
	}
	key_for := fn (p string, port int) string {
		return '${p}:${port}'
	}
	if port == 0 {
		for _ in 0 .. max_probe_tries {
			real := if proto == 'udp' {
				probe_free_udp_port(pm.bind)!
			} else {
				probe_free_port(pm.bind)!
			}
			k := key_for(proto, real)
			if !pm.used[k] {
				pm.used[k] = true
				log.debug('port manager: allocated random ${proto} port ${real}')
				return real
			}
		}
		return error('no free random ${proto} port available after ${max_probe_tries} tries')
	}
	k := key_for(proto, port)
	if pm.used[k] {
		return error('${proto} port ${port} already in use')
	}
	pm.used[k] = true
	log.debug('port manager: allocated ${proto} port ${port}')
	return port
}

// release 释放 TCP 端口占用标记；未占用的端口释放是空操作。
pub fn (mut pm PortManager) release(port int) {
	pm.release_proto('tcp', port)
}

// release_udp 释放 UDP 端口占用标记。
pub fn (mut pm PortManager) release_udp(port int) {
	pm.release_proto('udp', port)
}

fn (mut pm PortManager) release_proto(proto string, port int) {
	pm.mu.lock()
	defer {
		pm.mu.unlock()
	}
	k := '${proto}:${port}'
	if pm.used[k] {
		pm.used.delete(k)
		log.debug('port manager: released ${proto} port ${port}')
	}
}

// is_used 检查端口是否已被本管理器占用。
pub fn (mut pm PortManager) is_used(port int) bool {
	return pm.is_used_proto('tcp', port)
}

// is_used_udp 同 is_used，但查 UDP 命名空间。
pub fn (mut pm PortManager) is_used_udp(port int) bool {
	return pm.is_used_proto('udp', port)
}

fn (mut pm PortManager) is_used_proto(proto string, port int) bool {
	pm.mu.lock()
	defer {
		pm.mu.unlock()
	}
	return pm.used['${proto}:${port}']
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

// probe_free_udp_port 在 udp_ephemeral_lo..hi 范围内随机挑一个端口，bind 试占用：
// 成功（拿到一个空闲端口）即返回；失败（端口已被其他服务占用）重试。
// 注意：V 0.5.2 的 UdpConn 不暴露绑定后的本地地址，所以这里用 bind(:端口) + 成功即用。
fn probe_free_udp_port(bind string) !int {
	span := udp_ephemeral_hi - udp_ephemeral_lo
	for _ in 0 .. max_probe_tries {
		offset := rand.intn(span) or { 0 }
		port := udp_ephemeral_lo + offset
		addr := netx.join_host_port(bind, port)
		mut s := net.listen_udp(addr) or { continue }
		s.close() or {}
		return port
	}
	return error('no free random udp port in [${udp_ephemeral_lo}, ${udp_ephemeral_hi}) after ${max_probe_tries} tries')
}
