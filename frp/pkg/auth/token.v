module auth

import crypto.sha1

// ts_delta_limit 是服务端允许的客户端时间戳偏差上限（秒），即 ±15 分钟。
pub const ts_delta_limit = i64(900)

// new_privilege_key 用 token 和时间戳计算认证 key：
// privilege_key = sha1_hex(token + ts)，与 plan.md §6 一致。
pub fn new_privilege_key(token string, ts i64) string {
	return sha1.hexhash(token + ts.str())
}

// verify_privilege_key 校验客户端携带的认证 key：
// - token 为空时不校验，恒真（M1 允许不配置 token）；
// - 时间戳 ts 与当前时间 now 偏差超过 ±900 秒拒绝；
// - 用同样的 token 重算 privilege_key，与传入 key 比对。
pub fn verify_privilege_key(token string, ts i64, key string, now i64) bool {
	if token == '' {
		return true
	}
	if ts < now - ts_delta_limit || ts > now + ts_delta_limit {
		return false
	}
	return new_privilege_key(token, ts) == key
}
