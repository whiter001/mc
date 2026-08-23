module auth

fn test_new_and_verify_privilege_key() {
	token := 'token123'
	ts := i64(1_700_000_000)

	key := new_privilege_key(token, ts)
	assert key.len == 32 // md5 hex 是 32 个字符

	// 同 token 同 ts 重算一致
	assert verify_privilege_key(token, ts, key)
	assert new_privilege_key(token, ts) == key
}

fn test_verify_rejects_wrong_key() {
	token := 'token123'
	ts := i64(1_700_000_000)
	key := new_privilege_key(token, ts)
	assert verify_privilege_key(token, ts, 'wrong-key') == false
	assert verify_privilege_key(token, ts, key) == true
}

fn test_verify_rejects_wrong_timestamp() {
	token := 'token123'
	ts := i64(1_700_000_000)
	// 无时间窗校验：用错误 ts 算出的 key 与正确 key 不同，必然拒绝
	assert verify_privilege_key(token, ts, new_privilege_key(token, ts + 1)) == false
}

fn test_empty_token_both_sides_match() {
	// token 为空时仍按 md5('' + ts) 计算比对（对齐 Go 版）：
	// 两端 token 都为空时通过；key 不匹配时拒绝（不再恒真放行）。
	ts := i64(1_700_000_000)
	key := new_privilege_key('', ts)
	assert verify_privilege_key('', ts, key)
	assert verify_privilege_key('', ts, 'garbage') == false
	assert verify_privilege_key('', ts, '') == false
}

fn test_known_md5_vector() {
	// md5('0') 的已知值（token 为空、ts=0 时 key = md5_hex('0')）
	assert new_privilege_key('', 0) == 'cfcd208495d565ef66e7dff9f98764da'
}

fn test_constant_time_compare_rejects_mismatch() {
	token := 'token123'
	ts := i64(1_700_000_000)
	good := new_privilege_key(token, ts)
	assert verify_privilege_key(token, ts, good) == true
	// 仅末位不同
	assert verify_privilege_key(token, ts, good[..31] + 'x') == false
	// 长度不同直接拒绝
	assert verify_privilege_key(token, ts, good[..31]) == false
}

fn test_has_scope() {
	assert has_scope(['HeartBeats', 'NewWorkConns'], 'HeartBeats')
	assert has_scope(['HeartBeats'], 'NewWorkConns') == false
	assert has_scope([], 'HeartBeats') == false
	// 大小写敏感（对齐参考常量）
	assert has_scope(['heartbeats'], 'HeartBeats') == false
}
