module config

// ServerConfig 是 vfrps 服务端配置（TOML，见 plan.md §5）。
// 字段缺省时由 load_server_config 填默认值。
pub struct ServerConfig {
pub mut:
	bind_addr  string = '0.0.0.0'
	bind_port  int    = 7000
	auth_token string
}

// ProxyConfig 是客户端 [[proxies]] 数组中的一条转发规则（tcp / udp）。
pub struct ProxyConfig {
pub mut:
	name        string
	type        string
	local_ip    string = '127.0.0.1'
	local_port  int
	remote_port int
}

// ClientConfig 是 vfrpc 客户端配置（TOML，见 plan.md §5）。
pub struct ClientConfig {
pub mut:
	server_addr        string
	server_port        int = 7000
	auth_token         string
	pool_count         int
	heartbeat_interval int = 30
	proxies            []ProxyConfig
}
