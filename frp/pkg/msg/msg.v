// 消息类型定义：字节常量 + 结构体 + sum type。
// 字段名与 JSON tag 与 Go 版 frp pkg/msg/msg.go 第 66-190 行保持一致，
// 以便保留线上格式互通的可能。
// 注：消息结构体字段在 pub: 区块中，供 client/server 模块跨模块构造与读取。
// （V 0.5.2 不支持单字段 `pub x type @[attr]` 写法，只能用区块形式。）
module msg

// 消息类型字节常量（与 Go 版 pkg/msg/msg.go 一致）。
// 注：V 常量名必须 snake_case（不允许大写），故用 type_xxx 命名，值不变。
pub const type_login = `o`
pub const type_login_resp = `1`
pub const type_new_proxy = `p`
pub const type_new_proxy_resp = `2`
pub const type_close_proxy = `c`
pub const type_new_work_conn = `w`
pub const type_req_work_conn = `r`
pub const type_start_work_conn = `s`
pub const type_ping = `h`
pub const type_pong = `4`
pub const type_udp_packet = `u`

// ClientSpec 客户端类型说明（对应 Go 版 ClientSpec，目前仅 VirtualClient 使用）。
pub struct ClientSpec {
pub:
	typ              string @[json: 'type'; omitempty]
	always_auth_pass bool   @[json: 'always_auth_pass'; omitempty]
}

// Login 客户端启动时向服务端发送的登录消息。
// 注意：metas 字段不能加 omitempty —— V 0.5.2 的 json.encode 对
// 数组/map/结构体字段加 omitempty 会把整个结构体编成空串。
// 同理 client_spec（结构体字段）也不能加 omitempty。
pub struct Login {
pub:
	version       string            @[json: 'version'; omitempty]
	hostname      string            @[json: 'hostname'; omitempty]
	os            string            @[json: 'os'; omitempty]
	arch          string            @[json: 'arch'; omitempty]
	user          string            @[json: 'user'; omitempty]
	privilege_key string            @[json: 'privilege_key'; omitempty]
	timestamp     i64               @[json: 'timestamp'; omitempty]
	run_id        string            @[json: 'run_id'; omitempty]
	client_id     string            @[json: 'client_id'; omitempty]
	metas         map[string]string @[json: 'metas']
	client_spec   ClientSpec        @[json: 'client_spec']
	pool_count    int               @[json: 'pool_count'; omitempty]
}

// LoginWire 是 Login 的"解码专用"副本，去掉 map 字段。
// 背景：V 0.5.2 的 json.decode 对任何含 map 字段的结构体恒返回错误
// （V 自带的 vlib/json 测试在 0.5.2 也是 6/7 挂），因此 read_msg 先解码
// 到本结构（多余键被忽略），再经 login_from_wire 转换回 Login。
// 后果：从线上读到的 metas 内容无法还原（保持空 map）。
// 待 V 修复 json map 后，可删除本结构与转换函数。
struct LoginWire {
	version       string     @[json: 'version'; omitempty]
	hostname      string     @[json: 'hostname'; omitempty]
	os            string     @[json: 'os'; omitempty]
	arch          string     @[json: 'arch'; omitempty]
	user          string     @[json: 'user'; omitempty]
	privilege_key string     @[json: 'privilege_key'; omitempty]
	timestamp     i64        @[json: 'timestamp'; omitempty]
	run_id        string     @[json: 'run_id'; omitempty]
	client_id     string     @[json: 'client_id'; omitempty]
	client_spec   ClientSpec @[json: 'client_spec']
	pool_count    int        @[json: 'pool_count'; omitempty]
}

// LoginResp 服务端对登录的应答。
pub struct LoginResp {
pub:
	version string @[json: 'version'; omitempty]
	run_id  string @[json: 'run_id'; omitempty]
	error   string @[json: 'error'; omitempty]
}

// NewProxy 客户端登录成功后为每个代理发送的注册消息。
// 同 Login：metas/annotations/headers/response_headers 为 map 字段，
// 不能加 omitempty；custom_domains/locations/allow_users 为数组字段，
// 同样不能加 omitempty（原因见 Login 注释）。
pub struct NewProxy {
pub:
	proxy_name           string            @[json: 'proxy_name'; omitempty]
	proxy_type           string            @[json: 'proxy_type'; omitempty]
	use_encryption       bool              @[json: 'use_encryption'; omitempty]
	use_compression      bool              @[json: 'use_compression'; omitempty]
	bandwidth_limit      string            @[json: 'bandwidth_limit'; omitempty]
	bandwidth_limit_mode string            @[json: 'bandwidth_limit_mode'; omitempty]
	group                string            @[json: 'group'; omitempty]
	group_key            string            @[json: 'group_key'; omitempty]
	metas                map[string]string @[json: 'metas']
	annotations          map[string]string @[json: 'annotations']
	// tcp 和 udp 专用
	remote_port int @[json: 'remote_port'; omitempty]
	// http 和 https 专用
	custom_domains      []string          @[json: 'custom_domains']
	subdomain           string            @[json: 'subdomain'; omitempty]
	locations           []string          @[json: 'locations']
	http_user           string            @[json: 'http_user'; omitempty]
	http_pwd            string            @[json: 'http_pwd'; omitempty]
	host_header_rewrite string            @[json: 'host_header_rewrite'; omitempty]
	headers             map[string]string @[json: 'headers']
	response_headers    map[string]string @[json: 'response_headers']
	route_by_http_user  string            @[json: 'route_by_http_user'; omitempty]
	// stcp, sudp, xtcp
	sk          string   @[json: 'sk'; omitempty]
	allow_users []string @[json: 'allow_users']
	// tcpmux
	multiplexer string @[json: 'multiplexer'; omitempty]
}

// NewProxyWire 是 NewProxy 的"解码专用"副本，去掉 4 个 map 字段，
// 原因见 LoginWire 注释。
struct NewProxyWire {
	proxy_name           string   @[json: 'proxy_name'; omitempty]
	proxy_type           string   @[json: 'proxy_type'; omitempty]
	use_encryption       bool     @[json: 'use_encryption'; omitempty]
	use_compression      bool     @[json: 'use_compression'; omitempty]
	bandwidth_limit      string   @[json: 'bandwidth_limit'; omitempty]
	bandwidth_limit_mode string   @[json: 'bandwidth_limit_mode'; omitempty]
	group                string   @[json: 'group'; omitempty]
	group_key            string   @[json: 'group_key'; omitempty]
	remote_port          int      @[json: 'remote_port'; omitempty]
	custom_domains       []string @[json: 'custom_domains']
	subdomain            string   @[json: 'subdomain'; omitempty]
	locations            []string @[json: 'locations']
	http_user            string   @[json: 'http_user'; omitempty]
	http_pwd             string   @[json: 'http_pwd'; omitempty]
	host_header_rewrite  string   @[json: 'host_header_rewrite'; omitempty]
	route_by_http_user   string   @[json: 'route_by_http_user'; omitempty]
	sk                   string   @[json: 'sk'; omitempty]
	allow_users          []string @[json: 'allow_users']
	multiplexer          string   @[json: 'multiplexer'; omitempty]
}

// NewProxyResp 服务端对 NewProxy 的应答。
pub struct NewProxyResp {
pub:
	proxy_name  string @[json: 'proxy_name'; omitempty]
	remote_addr string @[json: 'remote_addr'; omitempty]
	error       string @[json: 'error'; omitempty]
}

// CloseProxy 关闭某个代理。
pub struct CloseProxy {
pub:
	proxy_name string @[json: 'proxy_name'; omitempty]
}

// NewWorkConn 客户端新建 work 连接时发送。
pub struct NewWorkConn {
pub:
	run_id        string @[json: 'run_id'; omitempty]
	privilege_key string @[json: 'privilege_key'; omitempty]
	timestamp     i64    @[json: 'timestamp'; omitempty]
}

// ReqWorkConn 服务端向客户端请求一条 work 连接（无字段）。
pub struct ReqWorkConn {}

// StartWorkConn 服务端通知客户端：已为用户连接分配 work 连接，开始对接。
pub struct StartWorkConn {
pub:
	proxy_name string @[json: 'proxy_name'; omitempty]
	src_addr   string @[json: 'src_addr'; omitempty]
	dst_addr   string @[json: 'dst_addr'; omitempty]
	src_port   u16    @[json: 'src_port'; omitempty]
	dst_port   u16    @[json: 'dst_port'; omitempty]
	error      string @[json: 'error'; omitempty]
}

// Ping 心跳。
pub struct Ping {
pub:
	privilege_key string @[json: 'privilege_key'; omitempty]
	timestamp     i64    @[json: 'timestamp'; omitempty]
}

// Pong 心跳应答。
pub struct Pong {
pub:
	error string @[json: 'error'; omitempty]
}

// UDPPacket 承载一条 UDP 数据报。
// 简化：content 用 []u8（V 编码为 JSON 数字数组，而非 Go 的 base64 字符串）；
// local_addr / remote_addr 用 string（Go 版是 *net.UDPAddr 对象）。
// 注意：content 为数组字段，不能加 omitempty。
pub struct UDPPacket {
pub:
	content     []u8   @[json: 'c']
	local_addr  string @[json: 'l'; omitempty]
	remote_addr string @[json: 'r'; omitempty]
}

// Message 是所有消息的 sum type，read_msg 返回此类型。
pub type Message = Login
	| LoginResp
	| NewProxy
	| NewProxyResp
	| CloseProxy
	| NewWorkConn
	| ReqWorkConn
	| StartWorkConn
	| Ping
	| Pong
	| UDPPacket
