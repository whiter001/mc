module auth

fn test_new_and_verify_privilege_key() {
	token := 'token123'
	now := i64(1_700_000_000)

	key := new_privilege_key(token, now)
	assert key.len == 40 // sha1 hex 是 40 个字符

	// 时间一致：通过
	assert verify_privilege_key(token, now, key, now)

	// 边界：正好 ±900 秒内通过
	assert verify_privilege_key(token, now - 900, new_privilege_key(token, now - 900), now)
	assert verify_privilege_key(token, now + 900, new_privilege_key(token, now + 900), now)

	// 超过时间窗：拒绝
	assert verify_privilege_key(token, now - 901, key, now) == false
	assert verify_privilege_key(token, now + 901, key, now) == false
}

fn test_verify_rejects_wrong_key() {
	token := 'token123'
	now := i64(1_700_000_000)
	key := new_privilege_key(token, now)
	assert verify_privilege_key(token, now, 'wrong-key', now) == false
	assert verify_privilege_key(token, now, key, now) == true
}

fn test_verify_empty_token_always_true() {
	now := i64(1_700_000_000)
	// 任意 ts / key 都通过
	assert verify_privilege_key('', now, '', now)
	assert verify_privilege_key('', now, 'garbage', now)
	assert verify_privilege_key('', now - 99_999, '', now)
}

fn test_known_sha1_vector() {
	// sha1('0') 的已知值（token 为空、ts=0 时 key = sha1_hex('0')）
	assert new_privilege_key('', 0) == 'b6589fc6ab0dc82cf12099d1c2d40ab994e8410c'
}
