module netx

import net
import strconv
import sync

// join_host_port 把 host 和端口拼成 "host:port"。
// 若 host 是 IPv6 字面量（含 ':'）则自动加方括号，与 Go 的 net.JoinHostPort 行为一致。
pub fn join_host_port(host string, port int) string {
	mut h := host
	if h.contains(':') && !h.starts_with('[') {
		h = '[' + h + ']'
	}
	return '${h}:${port}'
}

// split_host_port 把 "host:port" 拆成 host 字符串和端口整数。
// 支持 "[::1]:80" 形式的 IPv6 字面量；格式非法或端口越界时报错。
pub fn split_host_port(addr string) !(string, int) {
	idx := addr.last_index(':') or {
		return error('invalid address "${addr}": missing port separator')
	}
	mut host := addr[..idx]
	port_str := addr[idx + 1..]
	if port_str == '' {
		return error('invalid address "${addr}": empty port')
	}
	port := strconv.atoi(port_str) or {
		return error('invalid address "${addr}": bad port "${port_str}"')
	}
	if port < 0 || port > 65535 {
		return error('invalid address "${addr}": port ${port} out of range')
	}
	if host.starts_with('[') && host.ends_with(']') {
		host = host[1..host.len - 1]
	}
	return host, port
}

// RelayCloser 包装双向拷贝的关闭逻辑：两个拷贝线程共享同一个实例，
// 保证两端连接只会被 close 一次（幂等，不会重复 close 导致 panic）。
struct RelayCloser {
mut:
	mu     sync.Mutex
	closed bool
	a      &net.TcpConn
	b      &net.TcpConn
}

// close_all 关闭两个连接；重复调用（竞态下两个线程同时进入）只生效一次。
fn (mut rc RelayCloser) close_all() {
	rc.mu.lock()
	if rc.closed {
		rc.mu.unlock()
		return
	}
	rc.closed = true
	rc.mu.unlock()
	mut a := rc.a
	mut b := rc.b
	a.close() or {}
	b.close() or {}
}

// copy_one_way 单向拷贝：从 src 读、写入 dst。读或写一旦出错（含 EOF）
// 就触发整体关闭并退出。
// 重要：所有 &net.TcpConn / &RelayCloser 参数都**不带 mut**，按值传指针。
// V 0.5.2 v3 对非 main 模块的 `mut x &T` 参数会生成 T**（调用方变量地址），
// spawn 线程持有的 T** 在调用方返回后悬垂，访问即段错误（已在冒烟中复现）。
// 函数内用 `mut s := src` 取可变引用以调用 read/write 等 mut 方法。
fn copy_one_way(src &net.TcpConn, dst &net.TcpConn, rc &RelayCloser) {
	mut s := src
	mut d := dst
	mut r := rc
	mut buf := []u8{len: 32 * 1024}
	for {
		n := s.read(mut buf) or {
			r.close_all()
			return
		}
		if n == 0 {
			r.close_all()
			return
		}
		d.write(buf[..n]) or {
			r.close_all()
			return
		}
	}
}

// relay 在两个 TCP 连接之间建立双向转发：分别起一个线程做 a→b 和 b→a
// 的拷贝。任一方向 EOF 或出错即关闭两端并结束所有拷贝线程。
// 注意：relay 接管并最终关闭两端连接，调用方不要再 close。
// 参数不带 mut（原因见 copy_one_way 注释），调用方直接传 &net.TcpConn。
pub fn relay(a &net.TcpConn, b &net.TcpConn) {
	mut rc := &RelayCloser{
		mu: sync.new_mutex()
		a:  a
		b:  b
	}
	spawn copy_one_way(a, b, rc)
	spawn copy_one_way(b, a, rc)
}
