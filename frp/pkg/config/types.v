module config

// ServerConfig 是 vfrps 服务端配置（TOML，见 plan.md §5）。
// 字段缺省时由 load_server_config 填默认值。
pub struct ServerConfig {
pub mut:
	bind_addr       string = '0.0.0.0'
	bind_port       int    = 7000
	vhost_http_port int // 0 表示不开 HTTP vhost；非 0 时起 vhost HTTP 监听器
	auth_token      string
}

// ProxyConfig 是客户端 [[proxies]] 数组中的一条转发规则（tcp / udp / http）。
pub struct ProxyConfig {
pub mut:
	name        string
	type        string
	local_ip    string = '127.0.0.1'
	local_port  int
	remote_port int
	// http 代理专用：custom_domains 与 subdomain 互斥，subdomain_host 指定
	// subdomain 拼成完整域名时的主域名后缀。
	custom_domains []string
	subdomain      string
	subdomain_host string
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
