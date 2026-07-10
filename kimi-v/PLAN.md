# Kimi-V：用 V 重写 Kimi Code CLI 的实现计划

> 本计划基于对 `MoonshotAI/kimi-code`（TypeScript monorepo）的全面分析，目标是将其核心能力用 [V (vlang)](https://vlang.io) 重新实现，最终交付一个单文件静态二进制、毫秒启动、跨平台的 AI 编程 agent CLI。

---

## 0. 项目目标与边界

### 0.1 目标

| 维度 | 原版 (TS) | 本计划 (V) |
|---|---|---|
| 启动速度 | 数十 ~ 数百 ms | 毫秒级（< 50ms cold start） |
| 分发形态 | npm / 脚本 / Homebrew | **单一静态二进制（3–8 MB）** |
| 运行时依赖 | Node.js ≥ 24 | **零** |
| 内存 | V8 GC，受流式影响 | 无 GC，稳态内存可控 |
| 跨平台 | Node 跨平台 + node-pty | V 原生 cross-compile，PTY 走 C 互操作 |
| 核心能力 | 全套 | 先 **P0–P2** 做 MVP，后续按阶段补齐 |

### 0.2 不做（明确划线）

- 不复刻 TS 实现细节；按 V 习惯重新设计
- session 格式不兼容原 JSON（保留导入/导出钩子，但默认是新格式）
- skill/plugin manifest 字段对齐原仓，但描述语言改 TOML
- **不内嵌 Node.js / Bun 运行时**（那就失去 V 重写的意义）
- 商业版功能（Desktop App、托管 Marketplace）不重写

### 0.3 V 版本的甜点对齐

V 0.5+ 的以下特性是本计划的杠杆：

- `v -prod` 单一静态二进制
- 无 GC，TUI 流式渲染无偶发卡顿
- `go fn() + chan` 子 agent 并行（替代 Node Promise 链路）
- C 互操作直接绑 `forkpty` / ConPTY，省掉 `node-pty`
- 交叉编译 `v -os windows -os linux` 一条命令
- TOML 一等公民，配置文件原生支持

---

## 1. 仓库结构（最终形态）

```
kimi-v/
├── v.mod                     # 模块清单
├── README.md                 # 用户文档（带完成度）
├── PLAN.md                   # 本文件
├── LICENSE                   # MIT
├── Makefile                  # build / test / format 封装
│
├── cmd/
│   └── kimi/
│       └── main.v            # 入口；分发 kimi / kimi acp / kimi login / kimi mcp-config
│
├── internal/
│   ├── config/               # 多层 config（CLI > env > 项目 > 用户 > 默认）
│   │   ├── loader.v
│   │   └── paths.v           # 跨平台路径解析（XDG / macOS / Windows）
│   │
│   ├── llm/                  # kosong 等价物
│   │   ├── types.v           # Message / ToolDef / ChatRequest / ChatEvent
│   │   ├── provider.v        # Provider interface
│   │   ├── openai_compat.v   # OpenAI 兼容协议（Kimi 默认走这条）
│   │   ├── anthropic.v       # Claude 协议（P3）
│   │   ├── streaming.v       # SSE 流式解析（裸 TCP）
│   │   └── tool_call.v       # function calling JSON schema 编解码
│   │
│   ├── agent/                # agent-core 等价物
│   │   ├── agent.v           # Agent struct + step()
│   │   ├── session.v         # Session 持久化与回放
│   │   ├── loop.v            # think → tool → observe 循环
│   │   ├── plan.v            # 内置 plan sub-agent
│   │   └── tool_registry.v   # 工具注册与调用
│   │
│   ├── tools/                # 内置工具
│   │   ├── read_file.v
│   │   ├── write_file.v
│   │   ├── edit_file.v       # 字符串精准替换
│   │   ├── bash.v            # 走 PTY
│   │   ├── glob.v
│   │   ├── grep.v
│   │   ├── web_fetch.v       # P2
│   │   └── subagent.v        # 派发 coder/explore/plan
│   │
│   ├── exec/                 # kaos 等价物
│   │   ├── fs.v              # 文件操作
│   │   ├── proc.v            # 子进程
│   │   ├── pty_unix.c.v      # C 绑定 forkpty
│   │   ├── pty_windows.c.v   # ConPTY
│   │   └── sandbox.v         # 工作目录 + 权限约束
│   │
│   ├── auth/                 # P3
│   │   ├── oauth.v
│   │   └── apikey.v
│   │
│   ├── tui/                  # P1
│   │   ├── app.v             # 主循环 + 渲染管线
│   │   ├── input.v           # raw mode + 按键
│   │   ├── render.v          # diff 渲染
│   │   ├── markdown.v        # 流式 MD
│   │   └── media.v           # 视频缩略图（ffmpeg 调用）
│   │
│   ├── mcp/                  # P3
│   │   ├── client.v          # JSON-RPC
│   │   ├── transport_stdio.v
│   │   └── transport_http.v
│   │
│   ├── acp/                  # P4
│   │   ├── server.v
│   │   └── schema.v
│   │
│   ├── skills/               # P5
│   │   └── loader.v
│   │
│   ├── hooks/                # P5
│   │   └── runner.v
│   │
│   ├── session/              # 会话持久化
│   │   ├── store.v
│   │   └── replay.v
│   │
│   ├── telemetry/
│   │   └── client.v
│   │
│   └── util/
│       ├── log.v             # 结构化日志
│       ├── json.v            # JSON 工具
│       └── jsonrpc.v         # 最小 JSON-RPC 框架（MCP/ACP 共用）
│
├── plugins/                  # 示例插件
├── skills/                   # 示例 skill
├── docs/
└── test/
    └── smoke_test.v
```

---

## 2. 阶段划分与里程碑

### 阶段 P0：MVP 单次执行模式（**当前阶段**）

**目标：** 终端能跑通"帮我读 README 并总结"。单次执行模式（`kimi -p "task"`），无 TUI。

**完成定义（DoD）：**

- [x] 项目骨架：v.mod + 目录 + Makefile
- [x] LLM 抽象：Provider interface + OpenAI 兼容协议实现
- [x] Agent 循环：think → tool call → observe，可跑通
- [x] 工具：read_file / write_file / edit_file / bash / glob / grep
- [x] Config 加载：CLI flags + env + 用户级 config.toml
- [x] Session 持久化（基础版）
- [x] CLI 入口：`kimi -p "..."` 单次模式可工作
- [x] 编译通过 `v .` 零警告
- [ ] 流式输出（见 P0.5）

**验证用例：**

```sh
# 用例 1：单次问答（无工具调用）
kimi -p "用一句话解释 V 语言的内存模型"

# 用例 2：读文件 + 总结
kimi -p "读取 README.md 并用三句话总结"

# 用例 3：多工具协作
kimi -p "列出 internal/ 目录所有 .v 文件，并告诉我总行数"
```

### 阶段 P0.5：流式输出

**目标：** 把 `kimi -p` 改为流式（token-by-token），让长输出体验好。

**DoD：**
- [ ] `streaming.v` 实现裸 TCP HTTP 客户端
- [ ] SSE 解析状态机
- [ ] 流式 tool_call 累积解析
- [ ] `-p` 模式流式打印（默认开启）

### 阶段 P1：TUI 最小可用版

**目标：** 端到端打磨的交互界面，专为长时间会话优化。

**DoD：**
- [ ] raw mode + 按键解析
- [ ] diff 渲染（避免全屏重绘）
- [ ] 流式 MD（代码块中途更新）
- [ ] Slash 命令（`/login`, `/clear`, `/compact` 等）
- [ ] 撤销 / 重做（输入框）

### 阶段 P2：工具 + 安全审批

**DoD：**
- [ ] web_fetch 工具
- [ ] edit_file 工具的安全审批 UI（per-tool 策略）
- [ ] sandbox 权限模型
- [ ] 所有 Kimi Code 官方教程例子可跑通

### 阶段 P3：MCP + OAuth

**DoD：**
- [ ] MCP client（stdio + HTTP）
- [ ] `/mcp-config` 对话式配置
- [ ] OAuth + 本地回调
- [ ] Kimi / OpenAI / Anthropic 多 provider

### 阶段 P4：ACP

**DoD：**
- [ ] `kimi acp` 子命令
- [ ] Zed / JetBrains 接入验证

### 阶段 P5：子 agent + hooks + skills

**DoD：**
- [ ] coder / explore / plan 三子 agent
- [ ] 生命周期 hooks
- [ ] skill loader + marketplace client

### 阶段 P6：Web / Desktop（可选）

按需，不在本计划的硬约束里。

---

## 3. 关键模块设计

### 3.1 Provider 接口（`internal/llm/provider.v`）

```v
module llm

pub interface Provider {
    name string
pub mut:
    api_base string
    api_key  string
pub fn:
    chat(req ChatRequest, mut ch chan ChatEvent) !
}
```

设计要点：
- **返回 `chan ChatEvent` 而非 result struct** → 让流式天然支持，避免回调地狱
- **Provider 自带 `api_base` 和 `api_key`** → 配置集中在 Provider 内部
- **不抽象"消息格式"到 Provider** → Provider 负责把内部 `Message` 翻译成自己的 wire 格式

### 3.2 ChatEvent（`internal/llm/types.v`）

```v
pub enum ChatEvent {
    delta      DeltaEvent      // 文本增量
    tool_call  ToolCallEvent   // 工具调用增量（或完整）
    finish     FinishEvent     // 结束原因 + token 用量
    error      string          // 错误
}
```

要点：
- `delta` / `tool_call` 都允许增量（partial JSON），由 loop 层组装完整后再调用工具
- `finish` 必须带 `reason`（stop / length / tool_calls / error）和 `usage`
- `error` 是 union 成员而非 panic → loop 层可以选择 retry

### 3.3 Agent 循环（`internal/agent/loop.v`）

```v
pub fn (mut agent Agent) run(mut sess Session) ! {
    for {
        ev_ch := chan ChatEvent{cap: 32}
        go agent.provider.chat(agent.build_request(sess), mut ev_ch)

        mut tool_calls := []ToolCall{}
        mut text := strings.Builder{}
        mut finish_reason := FinishReason.unknown

        for ev in ev_ch {
            match ev {
                DeltaEvent { text.write_str(d.text) }
                ToolCallEvent { tool_calls << t }
                FinishEvent { finish_reason = f.reason }
                error { return error('provider: ${e}') }
            }
        }

        sess.append_assistant_message(text.str(), tool_calls)
        if finish_reason != .tool_calls { break }

        // 并行执行所有 tool calls
        mut results := []ToolResult{cap: tool_calls.len}
        mut res_ch := chan ToolResult{cap: tool_calls.len}
        for call in tool_calls {
            go agent.execute_tool(mut sess, call, mut res_ch)
        }
        for _ in 0 .. tool_calls.len {
            results << <-res_ch
        }
        sess.append_tool_results(results)
    }
}
```

设计要点：
- **`agent.step()` 是原子单元**（单次 LLM 调用 + 工具执行）
- **tool 并行执行** → V 的 `go fn()` + `chan` 自然达成
- **`session` 是单一事实源** → 所有变更走 `sess.append_*` 方法
- **错误处理走 `!`**，不抛 panic

### 3.4 Tool 接口（`internal/agent/tool_registry.v`）

```v
pub interface Tool {
    name() string
    description() string
    schema() ToolSchema
    execute(args ToolArgs, ctx ToolContext) !ToolResult
}
```

要点：
- **schema 用 V struct 表达**，`json.encode` 自动出 JSON Schema
- **`ctx` 携带 session、cwd、permissions** → 工具无副作用地读环境
- **注册走 `ToolRegistry`**，按名字 dispatch

### 3.5 Session（`internal/agent/session.v`）

```v
pub struct Session {
    pub mut:
    id        string
    cwd       string
    messages  []Message
    created_at time.Time
    updated_at time.Time
    metadata  map[string]string
}
```

要点：
- **`Agent` 不持有 `Session`**（对齐原仓 AGENTS.md 约束）
- session_id 可作为请求 hint 传给 Provider（缓存键）
- 持久化格式：TOML（V 一等公民）+ base64 附件

### 3.6 TUI（`internal/tui/`，P1 详化）

骨架核心：`App` struct + `update(msg)` / `render(buf)` 两个函数。

**渲染管线：**
1. 维护 `prev_frame: []string`
2. 每次 render 输出 `next_frame: []string`
3. diff → 仅 ANSI 覆写变化区域
4. 退出时 reset terminal

**流式 MD：** 维护 token 累积 buffer → 按 token 增量重渲染当前段落，**段落切换时不可变**（避免乱跳）。

### 3.7 PTY（`internal/exec/pty_*.c.v`）

**Unix**（`pty_unix.c.v`）：
```v
#include <pty.h>
#include <unistd.h>
fn C.forkpty(...) 
```

**Windows**（`pty_windows.c.v`）：走 ConPTY 头文件 + dllimport。

要点：
- **不要自己实现 PTY 协议**，直接绑 OS
- 抽象成统一的 `PtyHandle { mut rd net.Socket; mut wr net.Socket; pid int }`
- `bash` 工具默认走 PTY，让命令有颜色 / 交互能力

---

## 4. 关键技术决策

### 4.1 流式 HTTP 的实现路径

V 的 `net.http` 不直接支持 chunked streaming response body。最稳的方案是 **裸 TCP 自己写 HTTP 客户端**：

```v
fn post_streaming(url string, body string) !chan string {
    mut conn := net.dial_tcp('$host:$port')!
    conn.write_str('POST $path HTTP/1.1\r\nHost: $host\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n')!
    // 写入 chunked body
    for chunk in body_chunks {
        conn.write_str('${chunk.len:x}\r\n${chunk}\r\n')!
    }
    conn.write_str('0\r\n\r\n')!
    // 读响应头 + chunked body，分块推 chan
    ...
}
```

这是 P0.5 的工作，P0 先用 `http.post()` 拿完整 response 跑通。

### 4.2 JSON Schema 工具调用

OpenAI 兼容协议的 tool_calls 是结构化 JSON，**V 的反射能做**：

```v
fn tool_schema[T]() json.RawMessage {
    // 用 T 的 field tag `@json:"name"` `@json:"description"` `@json:"required"`
    // + jsonschema hints 编译时生成
}
```

P0 用 hardcoded schema 字符串，不上反射。P1 再做 codegen。

### 4.3 Config 多层合并

```
CLI flags > env vars (KIMI_*) > 项目 .kimi/config.toml > 用户 ~/.config/kimi/config.toml > 内置默认
```

`internal/config/loader.v` 用一个 `Config` struct + `merge()` 函数。

### 4.4 Session 文件格式

```toml
[meta]
id = "..."
cwd = "..."
created_at = "2026-07-09T22:30:00+08:00"

[[messages]]
role = "user"
content = "..."

[[messages]]
role = "assistant"
content = "..."
tool_calls = [{id = "...", name = "...", arguments = "..."}]
```

TOML 对人友好、可 diff、可手改。

---

## 5. 跨平台与构建

### 5.1 Makefile 目标

```makefile
build:        ## 生产构建（当前平台）
	v -prod -o bin/kimi cmd/kimi

build-all:    ## 交叉编译到三大平台
	v -prod -os linux   -o bin/kimi-linux   cmd/kimi
	v -prod -os darwin  -o bin/kimi-darwin  cmd/kimi
	v -prod -os windows -o bin/kimi.exe     cmd/kimi

test:         ## 跑测试
	v test .

fmt:          ## 格式化
	v fmt -w .

lint:         ## 检查
	v -check .

dev:          ## 开发模式（解释器执行）
	v -rebuild cmd/kimi
```

### 5.2 Nix 集成（可选 P3）

参考原仓 `flake.nix`，加 Nix flake 支持，让 reproducible build 也覆盖 V。

---

## 6. 风险与对策

| 风险 | 概率 | 影响 | 对策 |
|---|---|---|---|
| TUI 自研耗时长 | 高 | P1 延期 | P0 先出非 TUI 的 `-p` 模式；TUI 并行 |
| V 生态 LLM 客户端坑 | 中 | P0 拖进度 | 自己写裸 HTTP，不依赖第三方 SDK |
| 流式 SSE 解析边界 bug | 中 | 流式体验崩坏 | P0.5 用真实长 prompt fuzz |
| macOS arm64 编译 PTY | 低 | bash 工具失败 | 早期就上 C 互操作 prototype |
| 团队 V 经验不足 | 中 | 学习曲线 | 200 行 demo 跑通再立项 |

---

## 7. 完成度自审

> 当前阶段：**P0 进行中**

- [x] 项目骨架
- [x] PLAN.md
- [x] Provider 接口
- [x] OpenAI 兼容协议
- [x] Agent / Session / Loop
- [x] 6 个内置工具
- [x] Config 加载
- [x] Session 持久化
- [x] CLI 入口
- [x] 编译验证
- [ ] 流式输出（P0.5）
- [ ] TUI（P1）
- [ ] MCP / ACP（P3/P4）

---

## 8. 引用

- 原项目：`https://github.com/MoonshotAI/kimi-code`
- V 语言：`https://vlang.io`
- Agent Client Protocol：`https://agentclientprotocol.com`
- Model Context Protocol：`https://modelcontextprotocol.io`