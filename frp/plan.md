# frp V 语言重写计划（修正版）

> 参考实现：`/Volumes/Extreme/github2/frp`（Go 版 frp）
> 目标目录：`/Volumes/Extreme/github2/mc/frp`（本目录，V 项目根）
> 模块名：`vfrp`；产物：`vfrps`（服务端）、`vfrpc`（客户端）

## 0. 相对原版计划的修正点

| 原版问题 | 修正 |
|---|---|
| 模块名 `vfpr`（笔误），结构里有 `vfpr/` 根目录 | 模块名 `vfrp`，项目根即本目录，不再多套一层 |
| plan/todo 放在 Go 仓库里 | plan.md / todo.md 移到 V 项目根（本目录） |
| QUIC 传输 | **砍掉**。V 无 QUIC 库，自实现代价远超收益 |
| KCP / WebSocket 传输 | 降为 P3 可选，主线只做 TCP |
| wire v2（AEAD 加密帧） | 降为 P3 可选。主线用 v1 帧格式（见 §4），与 Go frp 默认格式兼容 |
| INI/YAML 配置 | 只做 TOML（vlib 自带 `toml` 模块） |
| OIDC 认证 | 降为 P3，主线只做 token 认证 |
| 插件系统 / vnet TUN / Web dashboard 嵌入 | **暂不实现**（P3+），API 只返回 JSON |
| 并发模型描述含糊 | 明确：V 的 `spawn` 是 OS 线程，采用 thread-per-connection；共享 map 用 `sync.Mutex` 保护 |
| TLS 用 "V 内置 crypto" | 实际 TLS 在 `net.openssl` / `net.mbedtls`，放 P2，MVP 先明文 + token |
| 无明确 MVP 验收标准 | 增加里程碑定义（见 §6） |

## 1. 目标

用 V 实现 frp 的核心能力：**让 NAT/防火墙后的本地服务通过公网服务器暴露出去**。

里程碑：
- **M1（MVP）**：vfrps + vfrpc，token 认证，TCP 代理端到端打通（e2e 测试验证）
- **M2**：UDP 代理、多代理、连接池、心跳保活、断线重连
- **M3**：HTTP vhost 路由（按域名分发）
- **M4**：TLS 传输加密、HTTPS/SNI 路由
- **M5+（可选）**：STCP/XTCP、tcpmux、metrics、KCP/WS、wire v2

## 2. 架构

```
        vfrps (公网服务器)                     vfrpc (内网客户端)
 ┌───────────────────────────┐        ┌───────────────────────────┐
 │ TCP listener (bind_port)  │◄───────│ control conn (登录/心跳)   │
 │  ├─ control 连接处理       │        │  ├─ login + NewProxy      │
 │  ├─ work conn 接收        │◄───────│  └─ work conn 池          │
 │ proxy listener (remote)   │        │ proxy → local 连接         │
 │  └─ 用户连接 ──► work conn │───────►│  └─ 转发到 local_ip:port  │
 └───────────────────────────┘        └───────────────────────────┘
```

核心流程（TCP 代理）：
1. vfrpc 发起 control 连接，发 `Login`（带 token 派生的 privilege_key + timestamp）
2. vfrps 校验后回 `LoginResp`
3. vfrpc 为每个代理发 `NewProxy`；vfrps 分配 remote_port、起 listener，回 `NewProxyResp`
4. 用户连 vfrps 的 remote_port → vfrps 通过 control 连接发 `ReqWorkConn`
5. vfrpc 收到后新建 work conn 连 vfrps，发 `NewWorkConn`，等待 `StartWorkConn`
6. vfrps 把用户连接和 work conn 对接（双向拷贝）；vfrpc 把 work conn 和 local 服务对接

## 3. 目录结构

```
mc/frp/                       # 项目根
├── v.mod                     # module vfrp
├── Makefile                  # build / test / fmt
├── plan.md / todo.md         # 本文件与任务清单
├── AGENTS.md                 # 构建与测试命令
├── cmd/
│   ├── vfrps/main.v          # 服务端入口
│   └── vfrpc/main.v          # 客户端入口
├── pkg/
│   ├── msg/msg.v             # 消息类型常量 + 结构体（JSON）
│   ├── msg/io.v              # v1 帧读写（type byte + JSON + '\n'）
│   ├── config/
│   │   ├── types.v           # ServerConfig / ClientConfig / ProxyConfig
│   │   └── load.v            # TOML 加载、校验、默认值
│   ├── auth/token.v          # token → privilege_key（md5_hex(token+timestamp)）
│   └── util/
│       ├── log/log.v         # 分级日志
│       ├── version/version.v # 版本常量
│       └── netx/netx.v       # join_host_port、双向拷贝等
├── server/
│   ├── service.v             # 监听、连接分发（control vs work conn）
│   ├── control.v             # 单个客户端的控制会话
│   ├── proxy.v               # TCP 代理（listener + work conn 对接）
│   └── ports.v               # 端口分配与占用检查
├── client/
│   ├── service.v             # 登录、重连（指数退避）、心跳
│   ├── control.v             # 控制连接消息处理
│   └── proxy.v               # TCP 代理客户端（work conn ↔ local）
└── test/
    └── e2e/tcp_proxy_test.v  # 端到端：起 vfrps+vfrpc+echo 服务，验证转发
```

## 4. 消息协议（v1 帧格式）

与 Go frp 默认格式兼容：`[1 字节类型][JSON  payload]['\n']`。

- 写：先写类型字节，再写 `json.encode(msg)`，最后写 `'\n'`
- 读：读 1 字节类型，按类型选结构体，读到 `'\n'` 为止做 `json.decode`

类型字节（与 Go 版一致）：`Login='o'`、`LoginResp='1'`、`NewProxy='p'`、`NewProxyResp='2'`、`CloseProxy='c'`、`NewWorkConn='w'`、`ReqWorkConn='r'`、`StartWorkConn='s'`、`Ping='h'`、`Pong='4'`、`UDPPacket='u'`。

M1 只需要：`Login / LoginResp / NewProxy / NewProxyResp / NewWorkConn / ReqWorkConn / StartWorkConn / Ping / Pong`。
JSON 字段名与 Go 版保持一致（snake_case tag），保留互通可能。

## 5. 配置格式（TOML）

```toml
# vfrps.toml
bind_addr = "0.0.0.0"
bind_port = 7000
auth_token = "token123"
```

```toml
# vfrpc.toml
server_addr = "127.0.0.1"
server_port = 7000
auth_token = "token123"
pool_count = 2            # 预建立的 work conn 数量
heartbeat_interval = 30   # 秒

[[proxies]]
name = "ssh"
type = "tcp"
local_ip = "127.0.0.1"
local_port = 22
remote_port = 6000
```

字段命名采用扁平 snake_case（不用 Go 版的 `auth.token` 嵌套点号写法，降低 TOML 解析复杂度）。

## 6. 认证（token）

与 Go frp 一致：`privilege_key = md5_hex(token + str(timestamp))`（Go 版 `util.GetAuthKey` 用 MD5，小写 hex）。
- `Login` 始终校验 privilege_key；`Ping` / `NewWorkConn` 默认不校验
- `auth_additional_scopes = ["HeartBeats", "NewWorkConns"]`（两端配置一致时）才额外校验 Ping / NewWorkConn —— 对齐 Go 版 `AuthScope` 语义
- 无时间戳新鲜度校验（Go 版 token 认证没有 ±15min 窗口；OIDC 才验过期，本实现不做 OIDC）
- token 为空时仍按 `md5('' + ts)` 计算比对（两端 token 都为空时自然通过），不做恒真特判
- key 比对用常量时间比较（`crypto.subtle.constant_time_compare`）
- 服务端 `allow_ports` 白名单（单端口或 start-end 区间，空 = 不限制）：指定端口不在白名单 → 拒绝；随机分配只在白名单内挑 —— 对齐 Go 版 `ports.Manager.allowPorts`
- Login 时校验 run_id：非空、≤64 字节、合法 UTF-8、全为可打印字符（Go 版 `validation.ValidateRunID`）

## 7. V 实现要点

- **JSON**：vlib `json`（`json.encode` / `json.decode`），结构体字段用 `[json: field_name]` attribute
- **TOML**：vlib `toml`（`toml.parse_text`），手动映射到配置结构体
- **网络**：vlib `net`（`net.listen_tcp` / `net.dial_tcp` / `net.listen_udp`）
- **并发**：`spawn fn()` 起 OS 线程；注册表等共享状态用 `sync.Mutex`；连接对转发用两个线程双向 `read`/`write` 拷贝
- **错误处理**：`!` 传播；网络读循环遇错即关闭并清理
- **CLI 参数**：`-c` 指定配置文件；不用 vlib `flag` 模块（V 0.5.2 中 `import flag` 与 `import toml` 同现会导致产物运行时 toml 解析出错，已改手工解析）
- **测试**：`*_test.v` + `v -stats test .`；e2e 用 `os.execute` 或 `spawn` 起进程

## 8. 实施阶段

| 阶段 | 内容 | 验收 |
|---|---|---|
| P0 | 骨架：v.mod、Makefile、目录、util(log/version/netx) | `v .` 编译通过 |
| P1 | pkg/msg + pkg/config + pkg/auth + 单测 | `v -stats test .` 全绿 |
| P2 | server 端：service/control/proxy/ports | vfrps 可启动监听 |
| P3 | client 端：service/control/proxy | vfrpc 可登录注册代理 |
| P4 | e2e：TCP 代理端到端测试（M1 完成线） | e2e 测试通过 |
| P5 | 心跳保活、断线重连、连接池、多代理 | 手测 + 单测 |
| P6 | UDP 代理（M2） | e2e UDP 测试 |
| P7 | HTTP vhost 路由（M3） | 域名分流测试 |
| P8 | TLS 传输（M4） | TLS 连接打通 |
| P9+ | STCP/XTCP/tcpmux/metrics/KCP/WS/wire v2（可选，按需） | — |

## 9. 风险与对策

| 风险 | 对策 |
|---|---|
| V 标准库 API 不稳定/有坑 | 每阶段先写最小程序验证 `net`/`toml`/`json` 用法，再铺开 |
| 线程安全问题（共享 map） | 所有共享状态集中管理 + Mutex；review 时专项检查 |
| 与 Go frp 互通 | 非目标。帧格式对齐即可，不保证完整互通 |
| 范围膨胀 | 严格按里程碑走，P9+ 一律不提前做 |
