# frp V 重写 - 任务清单（修正版）

> 项目根：`/Volumes/Extreme/github2/mc/frp`，模块名 `vfrp`。
> 验证命令：编译 `v .`；测试 `v -stats test .`；格式化 `v fmt -w .`

## P0 骨架
- [x] `v.mod`（module vfrp）
- [x] 目录结构（cmd/ pkg/ server/ client/ test/）
- [x] `Makefile`：build / test / fmt / clean
- [x] `pkg/util/version`：版本常量
- [x] `pkg/util/log`：分级日志（debug/info/warn/error，带时间戳）
- [x] `pkg/util/netx`：join_host_port、split_host_port、conn 双向拷贝

## P1 基础包
- [x] `pkg/msg/msg.v`：消息类型常量（'o','1','p','2','c','w','r','s','h','4','u'）
- [x] `pkg/msg/msg.v`：Login / LoginResp / NewProxy / NewProxyResp / CloseProxy / NewWorkConn / ReqWorkConn / StartWorkConn / Ping / Pong / UDPPacket 结构体，JSON tag 与 Go 版一致
- [x] `pkg/msg/io.v`：v1 帧读写（type byte + JSON + '\n'），含 read_msg / write_msg
- [x] `pkg/msg/msg_test.v`：所有消息 encode/decode 往返测试；帧读写测试（用 TCP pair 或 pipe）
- [x] `pkg/config/types.v`：ServerConfig / ClientConfig / ProxyConfig（tcp/udp/http 字段）
- [x] `pkg/config/load.v`：TOML 解析（vlib toml）、默认值填充、校验（端口范围、必填字段）
- [x] `pkg/config/config_test.v`：解析示例 toml、缺省值、非法配置报错
- [x] `pkg/auth/token.v`：privilege_key = sha1_hex(token+timestamp)；校验函数（含 ±15min 时间窗）
- [x] `pkg/auth/token_test.v`

## P2 server 端
- [x] `cmd/vfrps/main.v`：`-c` 指定配置文件，启动 service
- [x] `server/ports.v`：端口分配/释放/占用检查（Mutex 保护）
- [x] `server/proxy.v`：TCP 代理——监听 remote_port，收到用户连接后向 control 发 ReqWorkConn，拿到 work conn 后双向对接
- [x] `server/control.v`：处理 Login（校验 token）→ LoginResp；NewProxy → 起代理 → NewProxyResp；Ping→Pong；接收 NewWorkConn 注册 work conn
- [x] `server/service.v`：bind_port 监听，按首条消息分发 control 连接（Login）与 work 连接（NewWorkConn）
- [x] 验收：vfrps 能启动、接受登录、分配端口（冒烟：登录/内核分配端口/固定端口/端口冲突拒绝/心跳/ReqWorkConn/StartWorkConn/双向数据全部通过）

## P3 client 端
- [x] `cmd/vfrpc/main.v`：`-c` 指定配置文件，启动 service
- [x] `client/service.v`：登录（含 token）、失败指数退避重连
- [x] `client/control.v`：发 NewProxy 注册所有代理；处理 ReqWorkConn → 建 work conn
- [x] `client/proxy.v`：work conn 收到 StartWorkConn 后连 local_ip:local_port 并双向转发
- [x] 验收：vfrpc 登录成功、代理注册成功（冒烟：假服务端登录/注册/心跳/ReqWorkConn/StartWorkConn/双向数据回显全部通过；断线后指数退避重连并重新注册通过）

## P4 e2e（M1 完成线）
- [x] `test/e2e/tcp_proxy_test.v`：本地起 TCP echo 服务 → 起 vfrps → 起 vfrpc（注册 tcp 代理）→ 连 remote_port 发数据断言回显（两轮独立连接；连续 3 次全绿）
- [x] 心跳 Ping/Pong 保活（e2e 以 heartbeat_interval=1 覆盖）
- [x] token 错误时登录被拒绝的测试（双断言：remote_port 连不上 + 日志含 login failed）

## P5 健壮性
- [x] work conn 预建池（pool_count）— client/service.v 注册代理后预 spawn N 条 handle_work_conn 蹲到 server 的 work_conns 队列；test/e2e/tcp_proxy_test.v::test_pool_count_e2e 覆盖：pool_count=2 预建生效、首条连接命中池、第二条走 ReqWorkConn 重新填充
- [x] 断线自动重连 + 代理重新注册（client 冒烟：杀服务端后指数退避重连、重新注册、数据恢复）
- [x] 优雅退出（SIGINT/SIGTERM 清理 listener；server/service.v）
- [x] 多代理并发 — client/service.v 的 register_proxies 早已支持多 [[proxies]]；test/e2e/tcp_proxy_test.v::test_multi_proxy_e2e 覆盖：单 vfrpc 同时挂 2 个代理，分别指向不同 local echo，remote_port 独立回显
- [x] 竞态修复：spawn mut 引用悬垂（server/proxy.v、server/service.v、client/service.v），50 并发随机载荷压测 120/120 通过

## P5.x 修复（实现 P5 时撞到的 V 0.5.2 json2 bug）
- [x] NewWorkConn 解码 panic（array.get 越界）— 复用 Login/LoginWire 的 Wire 兼容路径：pkg/msg/msg.v 加 NewWorkConnWire（无 omitempty），pkg/msg/io.v 改走 decode[NewWorkConnWire] + new_work_conn_from_wire。NewWorkConn 自身去掉 omitempty（与 Wire 字段一一对应，编码端不再产生空字段歧义）

## P6 UDP 代理（M2）
- [ ] msg: UDPPacket 二进制编码（参考 Go 版 udp_binary.go）
- [ ] server/proxy UDP 实现
- [ ] client/proxy UDP 实现
- [ ] e2e UDP 测试

## P7 HTTP vhost（M3）
- [ ] vhost 路由表（域名/location → 代理）
- [ ] server HTTP 代理：解析 Host 头分流
- [ ] client HTTP 代理
- [ ] e2e 域名分流测试

## P8 TLS（M4）
- [ ] transport TLS（net.openssl 或 net.mbedtls 可行性验证先行）
- [ ] HTTPS/SNI 路由

## P9+ 可选（不主动做）
- [ ] STCP/XTCP visitor、NAT 打洞
- [ ] tcpmux（HTTP CONNECT 多路复用）
- [ ] Prometheus metrics
- [ ] KCP / WebSocket 传输
- [ ] wire v2 AEAD 帧
- [ ] OIDC、插件系统、vnet、dashboard
- [ ] 交叉编译 / Docker / release
