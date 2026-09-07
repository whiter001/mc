// STCP visitor 管理：stcp 代理不开 remote listener，注册时只把
// (proxy_name, sk, allow_users, 属主 control) 登记到 VisitorManager；
// visitor 客户端每条用户连接新开一条 TCP 连到 vfrps，首条消息 NewVisitorConn，
// 服务端校验 sk 与 allow_users 后把该连接当作用户连接走既有 work conn 链路。
// 对齐 Go 版 server/visitor/visitor.go 的 Listen / NewConn 语义。
module server

import sync
import pkg.auth
import pkg.util.log

// VisitorListener 一条 stcp 代理的监听项（无实际 socket，仅鉴权与属主信息）。
pub struct VisitorListener {
pub:
	proxy_name  string
	sk          string
	allow_users []string
	owner_user  string // 代理属主客户端的登录 user
	control     &Control // 代理属主的 control（work conn 从它取）
}

// VisitorManager stcp 监听项注册表。含 Mutex，须以引用（&VisitorManager）形式使用；
// control 线程与 visitor 连接处理线程并发访问。
pub struct VisitorManager {
pub mut:
	listeners map[string]&VisitorListener // proxy_name -> 监听项
	mu        sync.Mutex
}

// new_visitor_manager 创建空的 stcp 监听项注册表。
pub fn new_visitor_manager() &VisitorManager {
	return &VisitorManager{
		listeners: map[string]&VisitorListener{}
		mu: sync.new_mutex()
	}
}

// listen 注册一条 stcp 监听项；同名已存在时先记 warn 再覆盖
// （与 vhost 路由一致：后注册的"赢"）。
pub fn (mut vm VisitorManager) listen(proxy_name string, sk string, allow_users []string, owner_user string, control &Control) {
	vm.mu.lock()
	if _ := vm.listeners[proxy_name] {
		log.warn('visitor: stcp proxy [${proxy_name}] already registered, replacing old listener')
	}
	vm.listeners[proxy_name] = &VisitorListener{
		proxy_name: proxy_name
		sk: sk
		allow_users: allow_users
		owner_user: owner_user
		control: control
	}
	vm.mu.unlock()
}

// validate 校验 visitor 连接：监听项存在、sign_key == md5(sk + timestamp)、
// allow_users 放行（为空时仅允许与属主同一登录用户；非空时要求在列表中或含 "*"）。
// 校验通过返回监听项（含属主 control）。
pub fn (mut vm VisitorManager) validate(proxy_name string, timestamp i64, sign_key string, visitor_user string) !&VisitorListener {
	vm.mu.lock()
	l := vm.listeners[proxy_name] or {
		vm.mu.unlock()
		return error('custom listener for [${proxy_name}] does not exist')
	}
	vm.mu.unlock()

	if !auth.verify_privilege_key(l.sk, timestamp, sign_key) {
		return error('visitor connection of sk not match for proxy [${proxy_name}]')
	}
	if l.allow_users.len == 0 {
		if visitor_user != l.owner_user {
			return error('visitor user [${visitor_user}] not allowed for proxy [${proxy_name}]')
		}
		return l
	}
	if visitor_user in l.allow_users || '*' in l.allow_users {
		return l
	}
	return error('visitor user [${visitor_user}] not allowed for proxy [${proxy_name}]')
}

// remove 删除指定 proxy_name 的监听项（CloseProxy 用）。
// 返回是否命中。
pub fn (mut vm VisitorManager) remove(proxy_name string) bool {
	vm.mu.lock()
	defer {
		vm.mu.unlock()
	}
	if _ := vm.listeners[proxy_name] {
		vm.listeners.delete(proxy_name)
		return true
	}
	return false
}

// has 查询是否存在指定 proxy_name 的监听项。
pub fn (mut vm VisitorManager) has(proxy_name string) bool {
	vm.mu.lock()
	defer {
		vm.mu.unlock()
	}
	return proxy_name in vm.listeners
}

// remove_for_control 删除所有属于该 control 的监听项（control 关闭/退出时调用，
// 避免 stale pointer）。
pub fn (mut vm VisitorManager) remove_for_control(ctl &Control) {
	vm.mu.lock()
	defer {
		vm.mu.unlock()
	}
	mut to_remove := []string{}
	for name, l in vm.listeners {
		if l.control == ctl {
			to_remove << name
		}
	}
	for name in to_remove {
		vm.listeners.delete(name)
		log.info('visitor: stcp proxy [${name}] unregistered (control exited)')
	}
}
