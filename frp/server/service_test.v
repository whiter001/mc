// 验证功能单测：
// - validate_run_id / is_print（对齐 Go 版 pkg/config/v1/validation/name_test.go 边界用例）；
// - PortManager 白名单随机分配 / 畸形项解析 / 指定端口探测（审查问题 1/3/4 回归）。
module server

import net

// ---------------------------------------------------------------------------
// validate_run_id / is_print
// ---------------------------------------------------------------------------

// test_validate_run_id 覆盖 Go 版 ValidateRunID 的边界：
// 空串、超长（>64 字节）、控制字符、C1 控制符、软连字符、行分隔符、非法 UTF-8 拒绝；
// 中文、正常 hex 放行。
fn test_validate_run_id() {
	// 空串拒绝
	assert !validate_run_id('')
	// 64 字节上限：64 放行、65 拒绝
	assert validate_run_id('a'.repeat(64))
	assert !validate_run_id('a'.repeat(65))
	// 控制字符：\n、NUL、DEL
	assert !validate_run_id('run\nforged')
	assert !validate_run_id('run\u0000forged')
	assert !validate_run_id('run\u007fforged')
	// C1 控制符 U+0085 (NEL)
	assert !validate_run_id('run\u0085forged')
	// Cf 软连字符 U+00AD
	assert !validate_run_id('run\u00adforged')
	// Zl 行分隔符 U+2028
	assert !validate_run_id('run\u2028forged')
	// 非法 UTF-8（单字节 0xFF）
	assert !validate_run_id('run' + u8(0xff).ascii_str())
	// 合法值放行：hex、含 '-' / '%' 的可打印串、中文
	assert validate_run_id('0123456789abcdef')
	assert validate_run_id('run-1000s-中文')
	assert validate_run_id('run%1000s-中文')
}

// test_is_print 覆盖 is_print 的拒绝/放行边界。
fn test_is_print() {
	// 放行：ASCII 空格与可打印、Latin-1 补充、中文
	assert is_print(0x20)
	assert is_print(0x41)
	assert is_print(0xe4)
	assert is_print(0x4e2d)
	// 拒绝：C0/C1 控制符、DEL
	assert !is_print(0x00)
	assert !is_print(0x1f)
	assert !is_print(0x7f)
	assert !is_print(0x85)
	assert !is_print(0x9f)
	// 拒绝：Cf 软连字符、Zs 空格分隔符
	assert !is_print(0xad)
	assert !is_print(0xa0)
	assert !is_print(0x1680)
	assert !is_print(0x202f)
	assert !is_print(0x3000)
	// 拒绝：Zl/Zp 行/段分隔符
	assert !is_print(0x2028)
	assert !is_print(0x2029)
	// 拒绝：代理区、私有区
	assert !is_print(0xd800)
	assert !is_print(0xdfff)
	assert !is_print(0xe000)
	assert !is_print(0xf8ff)
	assert !is_print(0xf0000)
	assert !is_print(0x10fffd)
	// 拒绝：非字符区（U+FDD0–U+FDEF、各平面 U+nFFFE/U+nFFFF）
	assert !is_print(0xfdd0)
	assert !is_print(0xfdef)
	assert !is_print(0xfffe)
	assert !is_print(0xffff)
	assert !is_print(0x1fffe)
	assert !is_print(0x10ffff)
}

// ---------------------------------------------------------------------------
// PortManager 白名单分配
// ---------------------------------------------------------------------------

// find_free_allow_window 找一个连续 n 个端口都空闲的安全窗口（50000-60000 中段）。
// 返回窗口起始端口。
fn find_free_allow_window(n int) !int {
	for _ in 0 .. 8 {
		base := probe_free_port('127.0.0.1') or { continue }
		lo := 50000 + (base % 8000)
		if lo + n > 60000 {
			continue
		}
		mut all_free := true
		for p in lo .. lo + n {
			if !probe_tcp_port_free('127.0.0.1', p) {
				all_free = false
				break
			}
		}
		if all_free {
			return lo
		}
	}
	return error('could not find a free port window of ${n}')
}

// acquire_error_msg 返回 acquire 的错误信息；成功返回空串（测试辅助）。
fn acquire_error_msg(mut pm &PortManager, port int) string {
	_ := pm.acquire(port) or { return err.msg() }
	return ''
}

// test_acquire_random_allow_list 验证白名单随机分配（port==0 + has_allow）：
// 占满只剩一个空闲端口时，随机分配必须命中它（不放回抽样，不复抽已占用端口）；
// 全部占满后再随机分配应报错。
fn test_acquire_random_allow_list() {
	lo := find_free_allow_window(11) or {
		assert false, err.msg()
		return
	}
	mut pm := new_port_manager('127.0.0.1', ['${lo}-${lo + 10}'])
	for i in 0 .. 10 {
		got := pm.acquire(lo + i) or {
			assert false, 'acquire ${lo + i} failed: ${err.msg()}'
			return
		}
		assert got == lo + i
	}
	got := pm.acquire(0) or {
		assert false, 'random acquire failed with only one free port: ${err.msg()}'
		return
	}
	assert got == lo + 10, 'random acquire picked ${got}, want only-free ${lo + 10}'
	err := acquire_error_msg(mut pm, 0)
	assert err.contains('no free random'), 'expected no-free error, got: ${err}'
}

// test_acquire_random_stays_in_allow_list 验证随机分配不超出白名单。
fn test_acquire_random_stays_in_allow_list() {
	lo := find_free_allow_window(5) or {
		assert false, err.msg()
		return
	}
	mut pm := new_port_manager('127.0.0.1', ['${lo}-${lo + 4}'])
	for _ in 0 .. 5 {
		p := pm.acquire(0) or {
			assert false, 'random acquire failed: ${err.msg()}'
			return
		}
		assert p >= lo && p <= lo + 4, 'random acquire ${p} outside allow list'
	}
	// 5 个都分配完后再随机分配应报错
	err := acquire_error_msg(mut pm, 0)
	assert err.contains('no free random'), 'got: ${err}'
}

// test_parse_allow_ports_malformed 验证畸形白名单项整体被拒（问题 3）。
fn test_parse_allow_ports_malformed() {
	m, seq, has := parse_allow_ports(['1-2-3'])
	assert !has
	assert m.len == 0
	assert seq.len == 0
	_, _, has2 := parse_allow_ports(['1--2'])
	assert !has2
	_, _, has3 := parse_allow_ports(['abc'])
	assert !has3
	_, _, has4 := parse_allow_ports(['70000'])
	assert !has4
	// 合法项照常解析
	m5, seq5, has5 := parse_allow_ports(['1000-1002', '2000'])
	assert has5
	assert m5[1000] && m5[1002] && m5[2000]
	assert !m5[1003]
	assert seq5 == [1000, 1001, 1002, 2000]
}

// test_acquire_specified_port_unavailable 验证指定端口被其他进程占用时报 unavailable
//（问题 4：指定端口路径探测内核占用，对齐 Go 版 ErrPortUnAvailable）。
fn test_acquire_specified_port_unavailable() {
	lo := find_free_allow_window(1) or {
		assert false, err.msg()
		return
	}
	mut l := net.listen_tcp(.ip, '127.0.0.1:${lo}') or {
		assert false, 'listen on ${lo} failed: ${err.msg()}'
		return
	}
	defer {
		l.close() or {}
	}
	mut pm := new_port_manager('127.0.0.1', ['${lo}'])
	err := acquire_error_msg(mut pm, lo)
	assert err.contains('unavailable'), 'expected unavailable error, got: ${err}'
}
