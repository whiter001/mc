module auth

import crypto.md5
import crypto.subtle

// new_privilege_key 用 token 和时间戳计算认证 key：
// privilege_key = md5_hex(token + str(timestamp))，
// 与 Go 版 frp pkg/util/util/util.go 的 GetAuthKey 一致（MD5，小写 hex）。
// 注意：MD5 不应用于安全场景，此处仅为与 Go frp 保持互通（参考实现亦如此）。
pub fn new_privilege_key(token string, ts i64) string {
	return md5.hexhash(token + ts.str())
}

// verify_privilege_key 校验客户端携带的认证 key：
// 用同样的 token 重算 privilege_key，与传入 key 做常量时间比对（防时序侧信道）。
// 与 Go 版 TokenAuth.VerifyLogin/VerifyPing/VerifyNewWorkConn 对齐：
// - 不做时间戳新鲜度校验（参考实现 token 认证无此检查）；
// - token 为空时仍按 md5('' + ts) 计算比对（两端 token 都为空时自然通过）。
pub fn verify_privilege_key(token string, ts i64, key string) bool {
	expect := new_privilege_key(token, ts)
	if expect.len != key.len {
		return false
	}
	return subtle.constant_time_compare(expect.bytes(), key.bytes()) == 1
}

// has_scope 判断 additional scopes 列表是否包含指定 scope（精确匹配，大小写敏感）。
// 取值对应 Go 版 v1.AuthScope 常量："HeartBeats" / "NewWorkConns"。
pub fn has_scope(scopes []string, scope string) bool {
	for s in scopes {
		if s == scope {
			return true
		}
	}
	return false
}
