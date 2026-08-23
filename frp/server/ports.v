// 端口管理：代理 remote_port 的分配、释放与占用检查。
// 所有操作经 Mutex 串行化；acquire(0) 表示让内核分配（探测端口后返回实际端口）。
module server

import rand
import net
import sync
import pkg.config
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
// allow_ports 白名单：has_allow 为 true 时，指定端口必须命中白名单、随机分配
// 只在白名单内挑（对齐 Go 版 ports.Manager 的 allowPorts 语义；空 = 不限制）。
pub struct PortManager {
mut:
	mu        sync.Mutex      // 保护 used
	bind      string          // 探测端口时的绑定地址（与服务端 bind_addr 一致）
	used      map[string]bool // 协议隔离：key = "<proto>:<port>"，避免 TCP/UDP 同端口冲突
	allow_map map[int]bool    // 白名单端口集合（has_allow=false 时忽略）
	has_allow bool            // 是否配置了白名单
	allow_seq []int           // 白名单端口有序数组（随机分配时从中挑选）
}

// new_port_manager 创建端口管理器。bind 用于端口占用探测，须与代理实际
// 监听地址一致，否则内核分配的端口可能与监听绑定冲突。
// allow_ports 每项为单端口或 start-end 区间（格式已由配置校验保证）。
pub fn new_port_manager(bind string, allow_ports []string) &PortManager {
	allow_map, allow_seq, has_allow := parse_allow_ports(allow_ports)
	return &PortManager{
		mu:        sync.new_mutex()
		bind:      bind
		used:      map[string]bool{}
		allow_map: allow_map
		has_allow: has_allow
		allow_seq: allow_seq
	}
}

// parse_allow_ports 把白名单配置解析为端口集合 + 有序数组。
// 返回 (集合, 有序数组, 是否配置了白名单)。
// 畸形项（多段区间、空段、非数字、越界等）直接整体放弃白名单（返回空 + 记 warn）：
// 复用 pkg/config 的 validate_allow_ports 校验，避免两套解析器行为漂移
//（load_server_config 已在入口校验，但 new_port_manager 是 pub API，不能依赖该前置）。
fn parse_allow_ports(allow_ports []string) (map[int]bool, []int, bool) {
	mut valid := true
	config.validate_allow_ports(allow_ports) or {
		valid = false
		log.warn('port manager: invalid allow_ports config, allow list disabled: ${err.msg()}')
	}
	if !valid {
		return map[int]bool{}, []int{}, false
	}
	mut m := map[int]bool{}
	for entry in allow_ports {
		parts := entry.trim_space().split('-')
		if parts.len == 1 {
			m[parts[0].trim_space().int()] = true
		} else {
			start := parts[0].trim_space().int()
			end := parts[1].trim_space().int()
			for p in start .. end + 1 {
				m[p] = true
			}
		}
	}
	has_allow := m.len > 0
	if !has_allow {
		return m, []int{}, false
	}
	return m, m.keys().sorted(), true
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
		if pm.has_allow {
			// 随机分配：只在白名单内挑，且不放回抽样（对齐 Go 版从 freePorts 挑——
			// 已分配端口会从 freePorts 删除，不会再被抽到）。候选集先剔除本进程
			// 已占用端口，探测失败再从候选剔除继续挑，避免重复抽到占用/失败端口
			// 导致"明明有空闲端口却报 no free"。
			mut candidates := []int{}
			for p in pm.allow_seq {
				if !pm.used[key_for(proto, p)] {
					candidates << p
				}
			}
			for _ in 0 .. max_probe_tries {
				if candidates.len == 0 {
					break
				}
				idx := rand.intn(candidates.len) or { 0 }
				candidate := candidates[idx]
				candidates.delete(idx)
				if proto == 'udp' {
					if !probe_udp_port_free(pm.bind, candidate) {
						continue
					}
				} else {
					if !probe_tcp_port_free(pm.bind, candidate) {
						continue
					}
				}
				pm.used[key_for(proto, candidate)] = true
				log.debug('port manager: allocated random ${proto} port ${candidate} (allow list)')
				return candidate
			}
			return error('no free random ${proto} port in allow list after ${max_probe_tries} tries')
		}
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
	if pm.has_allow && port !in pm.allow_map {
		return error('${proto} port ${port} not allowed')
	}
	k := key_for(proto, port)
	if pm.used[k] {
		return error('${proto} port ${port} already in use')
	}
	// 指定端口也探测内核实际占用（对齐 Go 版 Acquire：isPortAvailable 失败即报
	// ErrPortUnAvailable），避免"端口被其他进程占用"的错误延迟到 start_tcp_proxy /
	// start_udp_proxy 的 listen 才暴露。
	available := if proto == 'udp' {
		probe_udp_port_free(pm.bind, port)
	} else {
		probe_tcp_port_free(pm.bind, port)
	}
	if !available {
		return error('${proto} port ${port} unavailable')
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

// probe_tcp_port_free 判断 bind 上指定 TCP 端口当前是否空闲（可绑定 = 空闲）。
// 供白名单随机分配使用（按指定端口探测，而非内核分配）。
fn probe_tcp_port_free(bind string, port int) bool {
	addr := netx.join_host_port(bind, port)
	mut l := net.listen_tcp(.ip, addr) or { return false }
	l.close() or {}
	return true
}

// probe_udp_port_free 判断 bind 上指定 UDP 端口当前是否空闲。
fn probe_udp_port_free(bind string, port int) bool {
	addr := netx.join_host_port(bind, port)
	mut s := net.listen_udp(addr) or { return false }
	s.close() or {}
	return true
}
