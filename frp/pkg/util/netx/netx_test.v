module netx

import net
import sync
import time

fn test_join_host_port() {
	assert join_host_port('127.0.0.1', 7000) == '127.0.0.1:7000'
	assert join_host_port('0.0.0.0', 0) == '0.0.0.0:0'
	// IPv6 字面量自动加方括号
	assert join_host_port('::1', 80) == '[::1]:80'
	assert join_host_port('[::1]', 80) == '[::1]:80'
}

fn test_split_host_port_ok() {
	host, port := split_host_port('127.0.0.1:7000') or {
		assert false, 'unexpected error: ${err}'
		return
	}
	assert host == '127.0.0.1'
	assert port == 7000

	host2, port2 := split_host_port('[::1]:80') or {
		assert false, 'unexpected error: ${err}'
		return
	}
	assert host2 == '::1'
	assert port2 == 80

	host3, port3 := split_host_port('localhost:65535') or {
		assert false, 'unexpected error: ${err}'
		return
	}
	assert host3 == 'localhost'
	assert port3 == 65535

	// 与 join_host_port 往返一致
	round, port4 := split_host_port(join_host_port('10.0.0.1', 22)) or {
		assert false, 'unexpected error: ${err}'
		return
	}
	assert round == '10.0.0.1'
	assert port4 == 22
}

fn test_split_host_port_missing_separator() {
	split_host_port('no-port-here') or {
		assert err.msg().contains('port separator')
		return
	}
	assert false, 'expected error for missing port'
}

fn test_split_host_port_empty_port() {
	split_host_port('127.0.0.1:') or {
		assert err.msg().contains('empty port')
		return
	}
	assert false, 'expected error for empty port'
}

fn test_split_host_port_non_numeric() {
	split_host_port('127.0.0.1:abc') or {
		assert err.msg().contains('bad port')
		return
	}
	assert false, 'expected error for non-numeric port'
}

fn test_split_host_port_out_of_range() {
	split_host_port('127.0.0.1:70000') or {
		assert err.msg().contains('out of range')
		return
	}
	assert false, 'expected error for out-of-range port'
}

// 建两对 TCP 连接（客户端侧 c1/c2，服务端侧 s1/s2），用于 relay 测试。
fn setup_pair() !(&net.TcpListener, &net.TcpConn, &net.TcpConn, &net.TcpConn, &net.TcpConn) {
	mut ln := net.listen_tcp(.ip, '127.0.0.1:0', net.ListenOptions{})!
	addr := (ln.addr()!).str()
	mut c1 := net.dial_tcp(addr)!
	mut s1 := ln.accept()!
	mut c2 := net.dial_tcp(addr)!
	mut s2 := ln.accept()!
	return ln, c1, s1, c2, s2
}

fn test_relay_bidirectional() {
	mut ln, mut c1, mut s1, mut c2, mut s2 := setup_pair()!
	// 服务端两侧对接
	relay(s1, s2)

	// c1 -> relay -> c2
	c1.write_string('hello-from-c1') or {
		assert false, 'c1 write failed: ${err}'
		return
	}
	c2.set_read_deadline(time.now().add(3 * time.second))
	mut buf := []u8{len: 1024}
	n1 := c2.read(mut buf) or {
		assert false, 'c2 read failed: ${err}'
		return
	}
	assert buf[..n1].bytestr() == 'hello-from-c1'

	// c2 -> relay -> c1
	c2.write_string('hello-from-c2') or {
		assert false, 'c2 write failed: ${err}'
		return
	}
	c1.set_read_deadline(time.now().add(3 * time.second))
	n2 := c1.read(mut buf) or {
		assert false, 'c1 read failed: ${err}'
		return
	}
	assert buf[..n2].bytestr() == 'hello-from-c2'

	// 收尾：关闭客户端侧，relay 线程应因 EOF 自行退出
	c1.close() or {}
	c2.close() or {}
	ln.close() or {}
	time.sleep(100 * time.millisecond)
}

fn test_relay_eof_closes_both_sides() {
	mut ln, mut c1, mut s1, mut c2, mut s2 := setup_pair()!
	relay(s1, s2)

	// 关掉 c1：relay 里读 s1 的线程收到 EOF，应关闭 s1 和 s2，
	// 于是 c2 侧会看到连接被关闭（read 报错）。
	c1.close() or {}
	c2.set_read_deadline(time.now().add(3 * time.second))
	mut buf := []u8{len: 1024}
	c2.read(mut buf) or {
		// 期望：对端关闭导致读失败
		c2.close() or {}
		ln.close() or {}
		time.sleep(100 * time.millisecond)
		return
	}
	c2.close() or {}
	ln.close() or {}
	time.sleep(100 * time.millisecond)
	assert false, 'expected read error after peer closed'
}

fn test_close_all_is_idempotent() {
	mut ln, mut c1, mut s1, mut c2, mut s2 := setup_pair()!
	mut rc := &RelayCloser{
		mu: sync.new_mutex()
		a:  s1
		b:  s2
	}
	// 多次调用 close_all 不能 panic，且结果幂等
	rc.close_all()
	rc.close_all()
	c1.close() or {}
	c2.close() or {}
	ln.close() or {}
}
