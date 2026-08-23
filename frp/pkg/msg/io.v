// v1 帧读写：write_msg / read_msg。
// 帧格式（与 Go 版 frp 默认 v1 格式兼容）：
//   [1 字节类型][JSON payload]['\n']
@[has_globals]
module msg

import net
import json2
import sync

// g_encode_mu / g_decode_mu 分别串行化 json2.encode / json2.decode：
// V 0.5.2 的 json2 用 C static 做字段信息懒缓存（encode 的 cached_field_infos
// 与 decode 的 cached_struct_field_infos，二者独立），多线程并发首次处理同一
// 类型时数据竞争，会把缓存指针覆盖成空数组，encode 触发 array.get 越界 panic、
// decode 则丢字段（服务端并发收多条 NewWorkConn 时 run_id 被解成空串，已在 e2e
// 复现）。encode 与 decode 的缓存互不共享，故拆成两把锁以降低多 control 高并发
// 下的互斥范围（原单把全局锁会串行化所有连接的编解码，成为吞吐瓶颈）。
__global (
	g_encode_mu sync.Mutex
	g_decode_mu sync.Mutex
)

// 单条消息 JSON 载荷的最大字节数（64KB）。读取时逐字节累积，超过即报错，
// 防止恶意对端发无限长的行耗尽内存。
const max_msg_payload = 64 * 1024

// write_msg 把 msg 按 v1 帧格式写入 conn：类型字节 + JSON + '\n'。
pub fn write_msg(mut conn net.TcpConn, msg Message) ! {
	tb := msg_type_byte(msg)
	payload := encode_message(msg)
	conn.write_string(tb.ascii_str() + payload + '\n')!
}

// read_msg 从 conn 读取一条 v1 帧消息：先读 1 字节定类型，
// 再逐字节读到 '\n'，按类型解码为对应结构体返回。
pub fn read_msg(mut conn net.TcpConn) !Message {
	mut type_buf := []u8{len: 1}
	n := conn.read(mut type_buf)!
	if n != 1 {
		return error('read_msg: connection closed while reading message type byte')
	}
	payload := read_payload(mut conn)!
	return decode_message(type_buf[0], payload)!
}

// msg_type_byte 返回消息对应的类型字节。
fn msg_type_byte(msg Message) u8 {
	return match msg {
		Login { type_login }
		LoginResp { type_login_resp }
		NewProxy { type_new_proxy }
		NewProxyResp { type_new_proxy_resp }
		CloseProxy { type_close_proxy }
		NewWorkConn { type_new_work_conn }
		ReqWorkConn { type_req_work_conn }
		StartWorkConn { type_start_work_conn }
		Ping { type_ping }
		Pong { type_pong }
		UDPPacket { type_udp_packet }
	}
}

// encode_message 把消息编码为 JSON 字符串。
// 注意：V 0.5.2 对 sum type 值直接 json.encode 会得到空串，
// 必须先 match 收窄到具体类型再编码。
// 全程持 g_encode_mu（见该变量注释：json2 懒缓存非线程安全）。
fn encode_message(msg Message) string {
	g_encode_mu.lock()
	defer {
		g_encode_mu.unlock()
	}
	return match msg {
		Login { json2.encode(msg, escape_unicode: true) }
		LoginResp { json2.encode(msg, escape_unicode: true) }
		NewProxy { json2.encode(msg, escape_unicode: true) }
		NewProxyResp { json2.encode(msg, escape_unicode: true) }
		CloseProxy { json2.encode(msg, escape_unicode: true) }
		NewWorkConn { json2.encode(msg, escape_unicode: true) }
		ReqWorkConn { json2.encode(msg, escape_unicode: true) }
		StartWorkConn { json2.encode(msg, escape_unicode: true) }
		Ping { json2.encode(msg, escape_unicode: true) }
		Pong { json2.encode(msg, escape_unicode: true) }
		UDPPacket { json2.encode(msg, escape_unicode: true) }
	}
}

// read_payload 逐字节读取直到 '\n'，返回去掉换行的载荷（上限 64KB）。
// 控制消息量小，逐字节读可接受。
fn read_payload(mut conn net.TcpConn) ![]u8 {
	mut payload := []u8{}
	mut b := []u8{len: 1}
	for payload.len <= max_msg_payload {
		n := conn.read(mut b)!
		if n == 0 {
			return error('read_msg: connection closed before end of message')
		}
		if b[0] == `\n` {
			return payload
		}
		payload << b[0]
	}
	return error('read_msg: message payload exceeds ${max_msg_payload} bytes')
}

// decode_message 按类型字节把 JSON 载荷解码为对应消息。
// 全程持 g_decode_mu（见该变量注释：json2 懒缓存非线程安全，decode 也会丢字段）。
fn decode_message(type_byte u8, payload []u8) !Message {
	g_decode_mu.lock()
	defer {
		g_decode_mu.unlock()
	}
	data := payload.bytestr()
	match type_byte {
		type_login {
			w := json2.decode[LoginWire](data) or {
				return error('read_msg: bad Login payload: ${err}')
			}

			return login_from_wire(w)
		}
		type_login_resp {
			return json2.decode[LoginResp](data) or {
				return error('read_msg: bad LoginResp payload: ${err}')
			}
		}
		type_new_proxy {
			w := json2.decode[NewProxyWire](data) or {
				return error('read_msg: bad NewProxy payload: ${err}')
			}

			return new_proxy_from_wire(w)
		}
		type_new_proxy_resp {
			return json2.decode[NewProxyResp](data) or {
				return error('read_msg: bad NewProxyResp payload: ${err}')
			}
		}
		type_close_proxy {
			return json2.decode[CloseProxy](data) or {
				return error('read_msg: bad CloseProxy payload: ${err}')
			}
		}
		type_new_work_conn {
			w := json2.decode[NewWorkConnWire](data) or {
				return error('read_msg: bad NewWorkConn payload: ${err}')
			}
			return new_work_conn_from_wire(w)
		}
		type_req_work_conn {
			return json2.decode[ReqWorkConn](data) or {
				return error('read_msg: bad ReqWorkConn payload: ${err}')
			}
		}
		type_start_work_conn {
			return json2.decode[StartWorkConn](data) or {
				return error('read_msg: bad StartWorkConn payload: ${err}')
			}
		}
		type_ping {
			return json2.decode[Ping](data) or {
				return error('read_msg: bad Ping payload: ${err}')
			}
		}
		type_pong {
			return json2.decode[Pong](data) or {
				return error('read_msg: bad Pong payload: ${err}')
			}
		}
		type_udp_packet {
			return json2.decode[UDPPacket](data) or {
				return error('read_msg: bad UDPPacket payload: ${err}')
			}
		}
		else {
			return error('read_msg: unknown message type byte: ${type_byte}')
		}
	}
}

// login_from_wire 把 LoginWire 转换为 Login（map 字段保持空）。
fn login_from_wire(w LoginWire) Login {
	return Login{
		version:       w.version
		hostname:      w.hostname
		os:            w.os
		arch:          w.arch
		user:          w.user
		privilege_key: w.privilege_key
		timestamp:     w.timestamp
		run_id:        w.run_id
		client_id:     w.client_id
		client_spec:   w.client_spec
		pool_count:    w.pool_count
	}
}

// new_proxy_from_wire 把 NewProxyWire 转换为 NewProxy（map 字段保持空）。
fn new_proxy_from_wire(w NewProxyWire) NewProxy {
	return NewProxy{
		proxy_name:           w.proxy_name
		proxy_type:           w.proxy_type
		use_encryption:       w.use_encryption
		use_compression:      w.use_compression
		bandwidth_limit:      w.bandwidth_limit
		bandwidth_limit_mode: w.bandwidth_limit_mode
		group:                w.group
		group_key:            w.group_key
		remote_port:          w.remote_port
		custom_domains:       w.custom_domains
		subdomain:            w.subdomain
		subdomain_host:       w.subdomain_host
		locations:            w.locations
		http_user:            w.http_user
		http_pwd:             w.http_pwd
		host_header_rewrite:  w.host_header_rewrite
		route_by_http_user:   w.route_by_http_user
		sk:                   w.sk
		allow_users:          w.allow_users
		multiplexer:          w.multiplexer
	}
}

// new_work_conn_from_wire 把 NewWorkConnWire 转换为 NewWorkConn。
// 字段一一对应（见 NewWorkConnWire 注释）。
fn new_work_conn_from_wire(w NewWorkConnWire) NewWorkConn {
	return NewWorkConn{
		run_id:        w.run_id
		privilege_key: w.privilege_key
		timestamp:     w.timestamp
	}
}
