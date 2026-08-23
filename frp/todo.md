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
- [x] `pkg/auth/token.v`：privilege_key = md5_hex(token+timestamp)（对齐 Go 版 util.GetAuthKey）；校验函数（常量时间比较、无时间窗、空 token 也按 md5 计算比对）；has_scope 辅助（HeartBeats / NewWorkConns）
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
- [x] msg: UDPPacket 编码（v1 帧格式 JSON，content 为 []u8；Go 版的 v2 二进制编码 v0.5.2 上不实现，v1 已满足单会话 M2）
- [x] server/proxy UDP 实现 — UdpProxy（server/proxy.v）：bind UDP socket、首包触发 ReqWorkConn 申请+发送 StartWorkConn、代理级单 work conn 长期复用、读循环转发
- [x] client/proxy UDP 实现 — handle_udp_proxy（client/proxy.v）：监听 local UDP、与一对 spawned goroutine（local↔work）拼装 UDPPacket
- [x] e2e UDP 测试 — test_udp_proxy_e2e：用户发 UDP 包到 vfrps:remote_port → 完整走 work conn → 本地 echo → 回环

## P6.x 实现期踩到的 V 0.5.2 坑（已修）
- [x] `net.UdpConn` 默认 100ms read_timeout（`udp_default_read_timeout = time.second / 10`）；代理须 `set_read_timeout(time.infinite)` 走"无限等待"分支，否则每次 read 都返"op timed out"导致 read_loop 提前退出
- [x] `net.UdpConn` 不暴露绑定后的本地地址（`str()` 是 TODO）；UDP 随机端口探测改用 bind(:port) + 冲突重试 + `rand.intn` 在 40000-60000 范围内挑
- [x] work conn 上的 StartWorkConn 不能被 server 侧 `work_read_loop` 抢先 read 走（否则 client 侧 read_msg 永远拿不到，handle_udp_proxy 不被调用）；work_read_loop 推迟到 `acquire_work_conn` 发完 StartWorkConn 之后才 spawn
- [x] client 侧 handle_udp_proxy 不能 `defer { local_udp.close() }`：handle 函数返回瞬间 socket 就关了，子 goroutine 立刻 EBADF。改由 work conn 错误驱动退出，关闭沿 client/service.v 整体重连路径走
- [x] 服务端代理表按协议拆成 `tcp_proxies` / `udp_proxies` 两张 map（共享一把 `proxies_mu`），close/handle_close_proxy 按代理类型走对应 `pm.release` / `pm.release_udp`
- [x] V 0.5.2 缺 `net.parse_addr(string)`；UDPPacket 加 `remote_addr_as_addr()` 方法，借 `net.resolve_addrs_fuzzy(addr, .udp)` 走 DNS 解析路径（接受本轮多一次解析的代价，换不用自己实现 sockaddr 解析）

## P7 HTTP vhost（M3）
- [x] vhost 路由表（域名/location → 代理）— server/service.v: `VhostRoute` struct + `vhost_routes map[string]VhostRoute`（host → control + proxy_name），`register_vhost_route` / `unregister_vhost_routes_for_control` / `lookup_vhost_route`
- [x] server HTTP 代理：解析 Host 头分流 — `Service.vhost_listener`（独立 vhost_http_port）+ `vhost_accept_loop` + `handle_vhost_conn`（read_http_headers → parse_host_header → 查路由 → 走 work conn 链路 + netx.relay 转发）
- [x] client HTTP 代理 — 复用 TCP work conn 链路（HTTP over TCP 字节透明转发，handle_work_conn 不用改）；register_proxies 补发 custom_domains / subdomain / subdomain_host
- [x] e2e 域名分流测试 — `test_http_vhost_e2e`：2 个本地 HTTP echo server（label A/B），注册 2 个 http 代理用 custom_domains `a.test` / `b.test`，分别用对应 Host 头请求，断言 body 含对应 label

## P7.x 实现期踩到的坑（已修）
- [x] `vfrpc/client/service.v::register_proxies` 原本只发 `proxy_name/proxy_type/remote_port` 三个字段，**漏发 `custom_domains` / `subdomain` / `subdomain_host`**——服务端的 NewProxyWire 收到了空数组，返回 "needs at least one custom_domain" 报错。补发后通
- [x] V 0.5.2 TOML parser 数组字段 `[]string` 缺省 nil；写 `custom_domains = ["a.test"]` 后正常填充，透传链路无问题（用 `v json2.decode` 单独测过 `[]string` 字段 roundtrip 是 OK 的，问题在字段没传，不在解析）
- [x] `parse_host_header` 兼容大小写 + 去端口 + 跳过 request line；V 字符串 `index`、`starts_with`、`trim_space`、`to_lower` 组合用 OK
- [x] `Control` 加 `svc &Service` 字段 + `new_control` 加 `svc` 参数（vhost 注册需要回到 Service 写路由表）。`handle_login_conn` 调用处补 `s` 实参
- [x] `ProxyConfig` 增 `custom_domains []string` / `subdomain string` / `subdomain_host string` 字段；`validate` 按 type 分支（tcp/udp 需 remote_port，http 需 custom_domains 或 subdomain+host）
- [x] `msg.NewProxy` / `NewProxyWire` / `new_proxy_from_wire` 三处都补 `subdomain_host` 字段（一开始忘了在 wire 拷贝里也加，会导致 json decode 后回填丢字段；已补）
- [x] V 编译器在 vfrp 项目（含 vhost/http 后）触发 2.3G 内存上限；测试 build 加 `-no-memory-limit` 绕开

## P7.x 验证功能对齐（对照 Go frp 逐项核查后补齐）
- [x] 认证密钥算法：SHA1 → **MD5**（`md5_hex(token + str(timestamp))`），与 Go 版 `pkg/util/util/util.go::GetAuthKey` 一致；token_test 补 md5('0') 已知向量
- [x] 校验语义对齐：**去掉 ±15min 时间窗**（Go 版 token 认证无此检查）；**去掉空 token 恒真特判**（空 token 也按 `md5('' + ts)` 比对）；key 比对改用 `crypto.subtle.constant_time_compare`（先判长度再比）
- [x] `auth_additional_scopes`（ServerConfig / ClientConfig，值仅 `HeartBeats` / `NewWorkConns`）：默认只校验 Login；Ping / NewWorkConn 仅在对应 scope 开启时才携带并校验 —— 对齐 Go 版 `TokenAuth.SetPing/VerifyPing/SetNewWorkConn/VerifyNewWorkConn`
- [x] `allow_ports` 端口白名单（ServerConfig，单端口 / start-end 区间，空 = 不限制）：指定端口不在白名单 → 拒绝注册；随机分配只在白名单内挑 —— 对齐 Go 版 `ports.Manager.allowPorts`（e2e：白名单内放行、白名单外拒绝）
- [x] run_id 校验：Login 时非空、≤64 字节、合法 UTF-8、全为可打印字符 —— 对齐 Go 版 `validation.ValidateRunID`
- [x] `msg.NewWorkConn` / `msg.Ping` 的 privilege_key / timestamp 改 `pub mut` + `omitempty`（scope 关闭时编码为空字段也不 panic；`NewWorkConnWire` 同步）

## P7.x 修复的实现期坑（V 0.5.2，已修）
- [x] **`mut x &T` → T** 代码生成 bug 损坏 chan 指针**：`handle_work_conn(mut conn &net.TcpConn)` 中转后调 `register_work_conn(mut conn)`，生成的 C 把 T* 值错塞给 T** 形参，chan 里读回的是 TcpConn 结构体首 8 字节（垃圾指针），代理侧 write StartWorkConn 即段错误（vfrps 收到用户连接就崩）。修复：server/service.v `handle_work_conn` 与 server/control.v `register_work_conn` 参数改非 mut `&net.TcpConn`，函数内 `mut cc := conn`（沿用 netx.copy_one_way 的既有规避模式）
- [x] **UDP 代理 spawn 悬垂 T\*\***：client/proxy.v `handle_udp_proxy` 把 `mut work_conn` / `mut local_udp` 传给 spawned goroutine，函数返回后 T** 悬垂即段错误。修复：三个函数参数全部改非 mut（`&net.TcpConn` / `&net.UdpConn`），内部取 `mut`；`&net.UdpConn` 参数赋给 mut 局部需 `unsafe`（V 对非 main 模块函数参数无法证明堆分配）
- [x] **json2 懒缓存数据竞争**：json2 encode 的 `cached_field_infos[T]` 与 decode 的 `cached_struct_field_infos[T]` 用 C static 懒初始化，多线程并发首次处理同一类型时缓存指针被覆盖成空数组 → encode 触发 `array.get` 越界 panic / decode 丢字段（run_id 被解成空串）。修复：pkg/msg/io.v 给 encode_message / decode_message 加包级 `__global sync.Mutex` 串行化（msg 模块标 `@[has_globals]`）
- [x] `cmd/vfrps/main.v` / `cmd/vfrpc/main.v`：弃用 vlib `flag` 模块（V 0.5.2 中 `import flag` 与 `import toml` 同现导致产物运行时 toml 解析出错），改手工解析 `-c` / `--version` / `-h`

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
