module msg

import net
import json

// new_tcp_pair 建立一对已连接的 TCP（server 端连接 + client 端连接），用于帧读写测试。
// 端口用 0 自动分配，避免固定端口冲突。
fn new_tcp_pair() (&net.TcpConn, &net.TcpConn) {
	mut lst := net.listen_tcp(.ip, '127.0.0.1:0') or { panic('listen: ${err}') }
	addr := lst.addr() or { panic('addr: ${err}') }
	port := '${addr}'.all_after(':').int()
	mut dialed := chan &net.TcpConn{}
	spawn fn [port, mut dialed] () {
		mut c := net.dial_tcp('127.0.0.1:${port}') or {
			eprintln('dial: ${err}')
			return
		}
		dialed <- c
	}()
	mut sconn := lst.accept() or { panic('accept: ${err}') }
	c := <-dialed
	return sconn, c
}

fn test_type_byte_constants() {
	// 与 Go 版 pkg/msg/msg.go 的类型字节一致
	assert type_login == `o`
	assert type_login_resp == `1`
	assert type_new_proxy == `p`
	assert type_new_proxy_resp == `2`
	assert type_close_proxy == `c`
	assert type_new_work_conn == `w`
	assert type_req_work_conn == `r`
	assert type_start_work_conn == `s`
	assert type_ping == `h`
	assert type_pong == `4`
	assert type_udp_packet == `u`
	// msg_type_byte 与类型字节一一对应
	assert msg_type_byte(Login{}) == type_login
	assert msg_type_byte(LoginResp{}) == type_login_resp
	assert msg_type_byte(NewProxy{}) == type_new_proxy
	assert msg_type_byte(NewProxyResp{}) == type_new_proxy_resp
	assert msg_type_byte(CloseProxy{}) == type_close_proxy
	assert msg_type_byte(NewWorkConn{}) == type_new_work_conn
	assert msg_type_byte(ReqWorkConn{}) == type_req_work_conn
	assert msg_type_byte(StartWorkConn{}) == type_start_work_conn
	assert msg_type_byte(Ping{}) == type_ping
	assert msg_type_byte(Pong{}) == type_pong
	assert msg_type_byte(UDPPacket{}) == type_udp_packet
}

fn test_json_roundtrip_login() {
	orig := Login{
		version:       'v0.1'
		hostname:      'h1'
		os:            'linux'
		arch:          'amd64'
		user:          'u1'
		privilege_key: 'pk'
		timestamp:     1700000000
		run_id:        'run-1'
		client_id:     'client-1'
		metas:         {
			'k1': 'v1'
		}
		client_spec:   ClientSpec{
			typ:              'ssh-tunnel'
			always_auth_pass: true
		}
		pool_count:    2
	}
	raw := json.encode(orig)
	// 编码侧：map 字段以 JSON 对象形式上线（Go 端可读）
	assert raw.contains('"metas":{"k1":"v1"}')
	assert raw.contains('"client_spec":{"type":"ssh-tunnel","always_auth_pass":true}')
	// 解码侧：V 0.5.2 无法直接解码含 map 字段的结构体，走 wire 结构再转换
	w := json.decode(LoginWire, raw) or {
		assert false
		return
	}
	d := login_from_wire(w)
	assert d.version == orig.version
	assert d.hostname == orig.hostname
	assert d.os == orig.os
	assert d.arch == orig.arch
	assert d.user == orig.user
	assert d.privilege_key == orig.privilege_key
	assert d.timestamp == orig.timestamp
	assert d.run_id == orig.run_id
	assert d.client_id == orig.client_id
	assert d.metas.len == 0 // V 0.5.2 json map 缺陷：内容不可还原
	assert d.client_spec.typ == 'ssh-tunnel'
	assert d.client_spec.always_auth_pass
	assert d.pool_count == orig.pool_count
	// 空 metas 的 Login 正常上线（"metas":{}，"client_spec":{}，Go 端可读）
	raw2 := json.encode(Login{ version: 'x' })
	assert raw2 == '{"version":"x","metas":{},"client_spec":{}}'
}

fn test_json_roundtrip_new_proxy() {
	orig := NewProxy{
		proxy_name:           'ssh'
		proxy_type:           'tcp'
		use_encryption:       true
		use_compression:      false
		bandwidth_limit:      '1MB'
		bandwidth_limit_mode: 'server'
		group:                'g'
		group_key:            'gk'
		metas:                {
			'a': 'b'
		}
		annotations:          {
			'c': 'd'
		}
		remote_port:          6000
		custom_domains:       ['a.example.com', 'b.example.com']
		subdomain:            'sub'
		locations:            ['/a', '/b']
		http_user:            'u'
		http_pwd:             'p'
		host_header_rewrite:  'h'
		headers:              {
			'h1': 'v1'
		}
		response_headers:     {
			'h2': 'v2'
		}
		route_by_http_user:   'ru'
		sk:                   'secret'
		allow_users:          ['alice', 'bob']
		multiplexer:          'm'
	}
	raw := json.encode(orig)
	// 编码侧：map / 数组字段如实上线
	assert raw.contains('"metas":{"a":"b"}')
	assert raw.contains('"annotations":{"c":"d"}')
	assert raw.contains('"custom_domains":["a.example.com","b.example.com"]')
	assert raw.contains('"allow_users":["alice","bob"]')
	// 解码侧：走 wire 结构再转换
	w := json.decode(NewProxyWire, raw) or {
		assert false
		return
	}
	d := new_proxy_from_wire(w)
	assert d.proxy_name == 'ssh'
	assert d.proxy_type == 'tcp'
	assert d.use_encryption
	assert !d.use_compression
	assert d.bandwidth_limit == '1MB'
	assert d.bandwidth_limit_mode == 'server'
	assert d.group == 'g'
	assert d.group_key == 'gk'
	assert d.metas.len == 0
	assert d.annotations.len == 0
	assert d.remote_port == 6000
	assert d.custom_domains == ['a.example.com', 'b.example.com']
	assert d.subdomain == 'sub'
	assert d.locations == ['/a', '/b']
	assert d.http_user == 'u'
	assert d.http_pwd == 'p'
	assert d.host_header_rewrite == 'h'
	assert d.headers.len == 0
	assert d.response_headers.len == 0
	assert d.route_by_http_user == 'ru'
	assert d.sk == 'secret'
	assert d.allow_users == ['alice', 'bob']
	assert d.multiplexer == 'm'
}

fn test_json_roundtrip_basic_messages() {
	// LoginResp
	lr := LoginResp{
		version: 'v1'
		run_id:  'r1'
		error:   'e1'
	}
	dlr := json.decode(LoginResp, json.encode(lr)) or {
		assert false
		return
	}
	assert dlr == lr
	// CloseProxy
	cp := CloseProxy{
		proxy_name: 'ssh'
	}
	dcp := json.decode(CloseProxy, json.encode(cp)) or {
		assert false
		return
	}
	assert dcp == cp
	// NewWorkConn
	nw := NewWorkConn{
		run_id:        'r'
		privilege_key: 'pk'
		timestamp:     123
	}
	dnw := json.decode(NewWorkConn, json.encode(nw)) or {
		assert false
		return
	}
	assert dnw == nw
	// ReqWorkConn（空结构体）
	assert json.encode(ReqWorkConn{}) == '{}'
	dreq := json.decode(ReqWorkConn, '{}') or {
		assert false
		return
	}
	assert dreq == ReqWorkConn{}
	// StartWorkConn
	sw := StartWorkConn{
		proxy_name: 'ssh'
		src_addr:   '1.1.1.1'
		dst_addr:   '2.2.2.2'
		src_port:   1234
		dst_port:   22
	}
	dsw := json.decode(StartWorkConn, json.encode(sw)) or {
		assert false
		return
	}
	assert dsw == sw
	// Ping
	pg := Ping{
		privilege_key: 'pk'
		timestamp:     456
	}
	dpg := json.decode(Ping, json.encode(pg)) or {
		assert false
		return
	}
	assert dpg == pg
	// Pong
	po := Pong{
		error: 'ok'
	}
	dpo := json.decode(Pong, json.encode(po)) or {
		assert false
		return
	}
	assert dpo == po
	// UDPPacket
	up := UDPPacket{
		content:     [u8(0xde), 0xad, 0xbe, 0xef]
		local_addr:  '1.2.3.4:5000'
		remote_addr: '5.6.7.8:6000'
	}
	dup := json.decode(UDPPacket, json.encode(up)) or {
		assert false
		return
	}
	assert dup == up
	// 空消息编成 {}（标量字段 omitempty 生效）
	assert json.encode(Ping{}) == '{}'
	assert json.encode(LoginResp{}) == '{}'
	assert json.encode(StartWorkConn{}) == '{}'
	// UDPPacket 的 []u8 编成 JSON 数字数组
	assert json.encode(UDPPacket{ content: [u8(1), 2] }) == '{"c":[1,2]}'
}

// NewWorkConn 带空认证字段（auth_additional_scopes 不含 NewWorkConns 时）也能编码，
// 不会触发 V 0.5.2 json2 对无 omitempty 空字符串字段的 panic（bug 回归测试）。
// 注意：按生产路径（io.v encode_message / decode_message，走 json2）验证——
// 不用 vlib 废弃的 json.encode，否则 json2 侧回归本测试捕获不到。
fn test_new_work_conn_empty_auth_fields_encode() {
	raw := encode_message(NewWorkConn{ run_id: 'r' })
	assert raw == '{"run_id":"r"}', 'got: ${raw}'
	// 解码回读字段齐全（omitempty 只影响编码，不影响解码）
	m := decode_message(type_new_work_conn, raw.bytes()) or {
		assert false
		return
	}
	match m {
		NewWorkConn {
			assert m.run_id == 'r'
			assert m.privilege_key == ''
			assert m.timestamp == 0
		}
		else {
			assert false, 'decode returned ${typeof(m).name}'
		}
	}
}

// 客户端连发两条消息、连读两条消息；服务端对应连读、连写 —— 验证帧不粘连。
fn test_write_read_tcp_roundtrip() {
	mut lst := net.listen_tcp(.ip, '127.0.0.1:0') or {
		assert false
		return
	}
	addr := lst.addr() or {
		assert false
		return
	}
	port := '${addr}'.all_after(':').int()

	mut client_result := chan string{}
	spawn fn [port, mut client_result] () {
		mut c := net.dial_tcp('127.0.0.1:${port}') or {
			client_result <- 'dial: ${err}'
			return
		}
		// 客户端连发两条消息
		write_msg(mut c, Login{
			version:  'v0.1'
			hostname: 'testhost'
			metas:    {
				'k1': 'v1'
			}
		}) or {
			client_result <- 'write Login: ${err}'
			return
		}
		write_msg(mut c, Ping{ timestamp: 1234567890 }) or {
			client_result <- 'write Ping: ${err}'
			return
		}
		// 客户端连读两条消息
		m1 := read_msg(mut c) or {
			client_result <- 'read LoginResp: ${err}'
			return
		}
		match m1 {
			LoginResp {
				if m1.version != 'v0.1' || m1.run_id != 'run-1' {
					client_result <- 'LoginResp 内容不符'
					return
				}
			}
			else {
				client_result <- '期望 LoginResp，实际读到其他消息'
				return
			}
		}
		m2 := read_msg(mut c) or {
			client_result <- 'read Pong: ${err}'
			return
		}
		match m2 {
			Pong {}
			else {
				client_result <- '期望 Pong，实际读到其他消息'
				return
			}
		}
		client_result <- ''
	}()

	// 服务端（主线程）：连读两条
	mut sconn := lst.accept() or {
		assert false
		return
	}
	m1 := read_msg(mut sconn) or {
		assert false
		return
	}
	assert m1 is Login
	if m1 is Login {
		assert m1.version == 'v0.1'
		assert m1.hostname == 'testhost'
		assert m1.metas.len == 0 // V 0.5.2 无法解码 map 字段，恒为空
	}
	m2 := read_msg(mut sconn) or {
		assert false
		return
	}
	assert m2 is Ping
	if m2 is Ping {
		assert m2.timestamp == 1234567890
	}
	// 服务端连发两条
	write_msg(mut sconn, LoginResp{ version: 'v0.1', run_id: 'run-1' }) or {
		assert false
		return
	}
	write_msg(mut sconn, Pong{}) or {
		assert false
		return
	}

	// 等待客户端线程结果
	res := <-client_result
	assert res == ''
	sconn.close() or {}
}

// 校验 write_msg 产出的原始帧字节：类型字节 + JSON + '\n'。
fn test_write_msg_frame_shape() {
	mut sconn, mut c := new_tcp_pair()
	spawn fn [mut c] () {
		write_msg(mut c, Ping{ timestamp: 5 }) or {}
		c.close() or {}
	}()
	mut frame := []u8{}
	mut b := []u8{len: 1}
	for {
		n := sconn.read(mut b) or { break }
		if n == 0 {
			break
		}
		frame << b[0]
		if b[0] == `\n` {
			break
		}
	}
	assert frame.bytestr() == 'h{"timestamp":5}\n'
	sconn.close() or {}
}

// Login 帧的 map 字段（metas）以 JSON 对象形式出现在线上。
// 注：V 0.5.2 中空 client_spec 编成 {"always_auth_pass":false}（嵌套结构体
// omitempty 缺陷，且是否出现取决于同结构体其他字段），这里只校验帧核心形态。
fn test_write_msg_login_frame_with_metas() {
	mut sconn, mut c := new_tcp_pair()
	spawn fn [mut c] () {
		write_msg(mut c, Login{
			metas: {
				'a': 'b'
			}
		}) or {}
		c.close() or {}
	}()
	mut frame := []u8{}
	mut b := []u8{len: 1}
	for {
		n := sconn.read(mut b) or { break }
		if n == 0 {
			break
		}
		frame << b[0]
		if b[0] == `\n` {
			break
		}
	}
	assert frame.bytestr().starts_with('o{"metas":{"a":"b"}')
	assert frame.bytestr().ends_with('\n')
	sconn.close() or {}
}

// 未知类型字节：read_msg 报错而不是 panic。
fn test_read_msg_unknown_type_byte() {
	mut sconn, mut c := new_tcp_pair()
	spawn fn [mut c] () {
		c.write_string('z{"x":1}\n') or {}
		c.close() or {}
	}()
	read_msg(mut sconn) or {
		assert err.msg().contains('unknown message type')
		sconn.close() or {}
		return
	}
	assert false
	sconn.close() or {}
}

// 超长载荷（>64KB）：read_msg 报错而不是无限读下去。
fn test_read_msg_oversize_payload() {
	mut sconn, mut c := new_tcp_pair()
	spawn fn [mut c] () {
		c.write_string('o' + 'a'.repeat(70000) + '\n') or {}
		c.close() or {}
	}()
	read_msg(mut sconn) or {
		assert err.msg().contains('exceeds')
		sconn.close() or {}
		return
	}
	assert false
	sconn.close() or {}
}

// 连接直接关闭：read_msg 报错（进入 or 分支即证明），而不是挂死或 panic。
fn test_read_msg_conn_closed() {
	mut sconn, mut c := new_tcp_pair()
	c.close() or {}
	read_msg(mut sconn) or {
		sconn.close() or {}
		return
	}
	assert false
	sconn.close() or {}
}

// 并发编解码压测：多线程同时 encode/decode 同一消息类型，验证 json2 懒缓存
// 数据竞争防护（g_encode_mu / g_decode_mu）不 panic、不丢字段、不死锁。
fn test_concurrent_encode_decode() {
	mut fails := chan int{cap: 8}
	for _ in 0 .. 8 {
		spawn fn [mut fails] () {
			mut bad := 0
			for j in 0 .. 200 {
				raw := encode_message(NewWorkConn{ run_id: 'r${j}' })
				if raw != '{"run_id":"r${j}"}' {
					bad++
					continue
				}
				m := decode_message(type_new_work_conn, raw.bytes()) or {
					bad++
					continue
				}
				match m {
					NewWorkConn {
						if m.run_id != 'r${j}' {
							bad++
						}
					}
					else {
						bad++
					}
				}
			}
			fails <- bad
		}()
	}
	mut total_bad := 0
	for _ in 0 .. 8 {
		total_bad += <-fails
	}
	assert total_bad == 0, 'concurrent encode/decode produced ${total_bad} mismatches'
}
