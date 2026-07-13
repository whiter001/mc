# Kimi-V

> V 重写 [MoonshotAI/kimi-code](https://github.com/MoonshotAI/kimi-code) —— 终端 AI 编程 agent，单二进制、毫秒启动、零运行时（除 libgc）。

详细实现计划见 [PLAN.md](PLAN.md)。

---

## 当前状态：**P0 + P0.5 + P0.6 + P1 + P1.5 + P2 跑通** ✅

- ✅ **`v .` 0 错误编译**
- ✅ **二进制 1.8 MB**（`v -prod`）
- ✅ **`kimi version` / `kimi help` / `kimi login` / `kimi -p "task"`** 全部可执行
- ✅ **`kimi`（无 `-p`）→ TUI 交互模式**
- ✅ **真·流式 SSE** — `http://` 走裸 TCP；`https://` 走 OpenSSL（`net.openssl`）TLS
- ✅ **工具调用增量累积**（tool_call arguments 跨 chunk 拼接）
- ✅ **Usage 透出** — finish event 现在带 `input_tokens` / `output_tokens`
- ✅ **完整 TOML 解析** — `vlib/toml` 模块；user/project/env/CLI 四层合并
- ✅ **内置工具**：`read_file` / `write_file` / `edit_file` / `bash` / `glob` / `grep`（正则，优先 rg）/ `web_fetch` / `web_search`（DuckDuckGo）/ `TodoWrite` / `TodoRead` / `AskUserQuestion`
- ✅ **OpenAI 兼容 provider**（Kimi、OpenAI、DeepSeek、OpenRouter 通用）
- ✅ **多层 config**（CLI > env > project > user > default）
- ✅ **跨平台路径**（XDG / macOS / Windows）
- ✅ **Session 持久化**（写 TOML）
- ✅ **P1 TUI**：alt-screen + raw mode + 30fps 全帧重绘
- ✅ **P1.5**：流式 token 实时渲染 / Ctrl-C 中断 / 多行输入 / 历史持久化 / **context 压缩（60% 触发）**
- ✅ **P2 审批**：`bash` / `write_file` / `edit_file` / `web_fetch` 走 TUI 模态 y/n
- ✅ **P2 配置化审批**：`risky_tools` via `config.toml` 或 `KIMI_RISKY_TOOLS`
- ✅ **P2 sandbox**：`write_file` / `edit_file` 拒绝 `..` 逃逸到 cwd 外
- ✅ **Plan-mode**：`/plan` 进入只读规划态；`EnterPlanMode` / `ExitPlanMode` 工具；规划态下除 plan 文件外禁止写文件；`ExitPlanMode` 弹出 plan 审阅模态（y 批准 / n 拒绝 / e 拒绝并退出 / r 修订 / Esc 忽略；多方案可数字键选）
- ✅ **Slash 命令**：`/help` `/clear` `/login` `/model` `/plan` `/tokens` `/usage` `/compact` `/exit`
- ✅ **键盘**：字符输入 / Enter / Backspace / Ctrl-A / Ctrl-E / Ctrl-U / Ctrl-W / Esc Esc 退出

### 还差（按 PLAN.md 阶段）

- [ ] P3 多 provider（Anthropic/Google）+ OAuth（MCP 客户端已完成，见下）
- [ ] P4 ACP server
- [x] P3 MCP 客户端 ✅
  - 基于 V 标准库 `mcp` 模块（JSON-RPC 2.0，支持 stdio 与 Streamable HTTP 两种传输）
  - 在 `config.toml` 用 `[[mcp]]` 表配置服务器（`command`/`args` 走 stdio，或 `url` 走 HTTP；`required` 控制是否致命；`headers` 传鉴权头）
  - 启动时连接并 `initialize`，把每个远程工具注册为 `mcp__<server>__<tool>`，模型可直接调用；结果从 `content` 数组扁平化为文本回传
  - 失败 fail-soft：非 `required` 服务器连不上仅告警跳过；退出时关闭所有连接
  - TUI 内 `/mcp` 斜杠命令列出已配置服务器及连接状态

  `config.toml` 示例：
  ```toml
  # stdio 传输：通过 npx 拉起一个 MCP server 子进程
  [[mcp]]
  name = "fs"
  command = "npx"
  args = ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
  required = true   # 连不上则启动失败；省略则仅告警跳过

  # HTTP 传输：Streamable HTTP 端点（鉴权头静态配置）
  [[mcp]]
  name = "remote"
  url = "http://localhost:8000/mcp"
  headers = { Authorization = "Bearer ${YOUR_TOKEN}" }
  ```
  连接后远程工具以 `mcp__<server>__<tool>` 暴露给模型（如 `mcp__fs__read_file`），直接调用即可；结果从 MCP `content` 数组扁平化为文本回传。
- [x] P5 子 agent（coder/explore/plan）+ hooks + skills ✅
  - **子 agent**：`/agent` 或 `Agent` 工具派发 `coder` / `explore` / `plan` 三种预设 profile，独立 Session 递归运行，结果回流父 agent
  - **Hooks**：15 类生命周期事件（tool / turn / session / message / agent / file / error / approval），fail-open，exit 0=allow / 2=block，支持 `permissionDecision:deny` 结构化拦截
  - **Skills**：`SKILL.md`（front matter + markdown body）loader，从 `~/.kimi/skills/` 与 `./.kimi/skills/` 装载，`/skill:NAME` 斜杠命令注入 system prompt，支持 `$ARGUMENTS` / `$N` / `$name` / `${KIMI_SKILL_DIR}` 占位符
- [x] Plan-mode（`/plan` + EnterPlanMode/ExitPlanMode）✅
- [ ] P6 Web / Desktop

### 本轮补齐的工具能力（parity 小步快跑）

对齐 `kimi-code` 的 `builtin/*` 工具集，补了 4 块日常高频能力：

- **`grep` 升级为正则**：优先调用 `rg`（ripgrep，与上游一致，跳过 VCS/隐藏文件、支持 glob、`-i` 大小写不敏感）；`rg` 不可用时回退到 V 自带 `regex` 模块逐行匹配，仍无效则退到字串匹配。schema 新增 `include` 与 `i` 参数。
- **`web_search`**：通过 DuckDuckGo HTML 端点做免 key 联网搜索，复用 `web_fetch` 的 HTML→text 管线解析结果，返回带标题/URL/摘要的编号列表。
- **`TodoWrite` / `TodoRead`**：会话级任务清单，状态存在 `Agent.todos` 上（Agent 已是 per-session 单例），`TodoWrite` 整体覆盖、`TodoRead` 读取并以 Markdown 渲染。
- **`AskUserQuestion`**：模型向用户提问（单选/多选）。TUI 里渲染底部模态、数字键选择、逗号多选、Esc 跳过；`-p` 非交互模式超时返回提示，不阻塞。

#### 新文件

```
tools_web_search.v   # DuckDuckGo 搜索
tools_todo.v          # TodoWrite / TodoRead
tools_ask_user.v      # AskUserQuestion
```

#### 主要改动

- `agent.v`：`Agent` 加 `@[heap]` 注解 + `todos` 字段 + `ask_ch`/`ask_result_ch` 通道
- `agent_tool_registry.v`：`ToolContext` 加 `agent ?&Agent` 回溯引用
- `agent_loop.v`：工具执行上下文带 `agent: &a`
- `tui_loop.v` / `tui_render.v` / `tui.v`：AskUserQuestion 模态渲染与数字键路由、`parse_selection` 辅助
- `tools.v`：`grep` 正则化；`default_registry` 注册 4 个新工具


---

## 构建

需要 V 0.5+。推荐用 `build.sh`，V 的三种 build 模式分得很清楚：

| Mode | V 命令 | 输出 | 大小 | 用途 |
|---|---|---|---|---|
| **dev** | `v -o bin/kimi .` | `bin/kimi` | ~2 MB | 日常开发循环 |
| **debug** | `v -debug -o bin/kimi-debug .` | `bin/kimi-debug` + `bin/kimi-debug.dSYM/` | ~2.5 MB | 调试（lldb/gdb） |
| **prod** | `v -prod -o bin/kimi .` + `strip` | `bin/kimi` | ~1.3 MB | 发布 |

```sh
./build.sh                # dev build（默认）
./build.sh dev            # 同上
./build.sh debug          # debug build（保留符号 + dSYM）
./build.sh prod           # prod build（-O3 + strip）
./build.sh cross          # 一次出三个平台
./build.sh test           # 跑单元测试
./build.sh fmt            # v fmt -w .
./build.sh clean          # 清理构建产物
PREFIX=~/.local ./build.sh install   # 安装到 ~/.local/bin
```

环境变量：

```sh
V=/path/to/v ./build.sh prod          # 指定 v 编译器
DEBUG_FLAGS="-cflags -g" ./build.sh debug   # 附加 debug flag
```

也可以直接用 `v` 命令：

```sh
v -prod -o bin/kimi .                 # 当前平台
v -prod -os linux -o bin/kimi .       # 交叉到 Linux
v -prod -os windows -o bin/kimi.exe . # 交叉到 Windows
```

> 注：`build.sh` 自动检测 host 平台并跳过同名 target；非 host 的跨平台编译通常需要额外 toolchain（macOS→Linux 要专门的 cross clang，→Windows 要 mingw），不支持时会标 `skipped` 而不是失败。

---

## 使用

```sh
# 1) 凭证
./bin/kimi login

# 2) 单次任务
./bin/kimi -p "list every .v file in this directory and count lines"

# 3) 交互式 TUI（默认，无 -p）
./bin/kimi

# 4) env + flags
KIMI_API_KEY=$YOUR_KEY \
KIMI_API_BASE=https://api.moonshot.cn/v1 \
KIMI_MODEL=moonshot-v1-8k \
./bin/kimi -p "summarize README.md"
```

### TUI 快捷键

| 键 | 行为 |
|---|---|
| 字符键 | 输入 |
| `Enter` | 提交 |
| `Backspace` | 删除前一个字符 |
| `Ctrl-A` / `Ctrl-E` | 光标到行首 / 行尾 |
| `Ctrl-B` / `Ctrl-F` | 光标左 / 右 |
| `Ctrl-P` / `Ctrl-N` | 历史上一条 / 下一条 |
| `Ctrl-U` | 清空到行首 |
| `Ctrl-W` | 删除前一个词 |
| `Ctrl-K` | 删除到行尾 |
| `Ctrl-L` | 清屏（重绘） |
| `Ctrl-C` | 中断当前 turn |
| `Esc Esc` | 退出 TUI |

### Slash 命令

| 命令 | 行为 |
|---|---|
| `/help` | 列出所有命令 |
| `/clear` | 清空会话 |
| `/login` | 提示去另一个 shell 跑 `kimi login`（TUI 暂不读密码） |
| `/model NAME` | 切换模型 |
| `/tokens` / `/usage` | 显示当前 session 累计 token 用量 |
| `/compact` | 提示下次 turn 触发 context 压缩（自动 60% 触发） |
| `/plan` | 进入 plan-mode（只读规划态，等价于模型调用 EnterPlanMode） |
| `/exit` / `/quit` | 离开 TUI |

### Plan-mode（规划态）

对齐 kimi-code 的 `EnterPlanMode` / `ExitPlanMode` 工具：

1. **进入**：模型在 nontrivial 任务前主动调用 `EnterPlanMode`，或用户在 TUI 里输入 `/plan`。进入后：
   - 顶部状态栏显示 `[PLAN MODE]` 横幅；
   - 系统提示被注入只读工作流（探索 → 设计 → 写 plan 文件 → `ExitPlanMode`）；
   - **只读约束**：`write_file` / `edit_file` 只允许写当前 plan 文件，写其它文件会被循环直接拒绝（对齐 `plan-mode-guard-deny` 策略）；`bash` 仍走正常审批。
2. **写 plan**：模型用 `write_file` / `edit_file` 把方案写到 plan 文件（路径在提醒里给出，默认 `<config-dir>/plans/<id>.md`）。
3. **退出审阅**：模型调用 `ExitPlanMode`（可带 `options` 列举多套方案），TUI 弹出 plan 审阅模态：
   - `y` 批准；若给了多套方案，`1`/`2`/`3` 直接批准对应方案；
   - `n` 拒绝（留在 plan-mode，可改后重提）；
   - `e` 拒绝并退出 plan-mode；
   - `r` 请求修订（留 plan-mode，附反馈）；
   - `Esc` 忽略（留 plan-mode）。
   - 非交互模式（`kimi -p`）自动批准，不会卡住等待 UI。

Flags：

| Flag | 默认 |
|---|---|
| `--prompt` / `-p` | 必填 |
| `--model` | env: `KIMI_MODEL` |
| `--api-base` | env: `KIMI_API_BASE` (默认 `https://api.openai.com`) |
| `--api-key` | env: `KIMI_API_KEY` |
| `--provider` | `openai-compat` |
| `--system` | env: `KIMI_SYSTEM_PROMPT` |
| `--max-turns` | `32` |
| `--max-tokens` | `4096` |
| `--log-level` | env: `KIMI_LOG_LEVEL` |

### 审批 & sandbox

默认 `bash` / `write_file` / `edit_file` / `web_fetch` 跑前会弹模态要 y/n（`read_file` /
`glob` / `grep` 走 auto-allow）。要自定义把列表写到 `config.toml`：

```toml
risky_tools = ["bash"]              # 只要 bash 问；其它写操作放行
# risky_tools = []                  # 全放行（不推荐）
# risky_tools = ["bash", "web_fetch"]  # 只问这两个
```

或者环境变量（逗号分隔，CI / 临时实验方便）：

```sh
KIMI_RISKY_TOOLS="bash,web_fetch" ./bin/kimi
```

`write_file` / `edit_file` 还会被 sandbox 拦在 session cwd 之外 —— `..` 逃逸、
绝对路径指别处、共享前缀的兄弟目录（`/sandbox-evil` vs `/sandbox`）一律拒绝，
错误信息直接告诉模型为什么。`bash` 暂不做 sandbox（解析 shell 成本太高，
自用靠审批 + 自己眼睛看）。

### 流式 vs HTTPS 说明

- **`http://` URL**：走 `streaming.v` 的裸 TCP + SSE 路径，token-by-token 实时输出
- **`https://` URL**：走 `streaming.v` 的 OpenSSL（`net.openssl`）路径，TLS 握手后真流式，token-by-token 输出
- **fallback**：非 http/https 的奇怪 scheme 退到 P0 的 `http.fetch` 整包拉（应用层模拟流式）
- 自签名证书默认接受（`SSLConnectConfig{}` 没传 `verify`）；生产可传 `verify: '/path/to/ca.pem'`

---

## 文件清单

```
kimi-v/
├── PLAN.md              # 完整实现计划（P0–P6）
├── README.md            # 本文件
├── v.mod
├── Makefile
│
├── main.v               # CLI 入口
│
├── llm_types.v          # Message / ToolCall / ChatEvent / FinishEvent
├── llm_provider.v       # Provider interface
├── llm_openai_compat.v  # OpenAI 兼容实现（dispatch HTTP→stream, HTTPS→buffered）
├── streaming.v          # 裸 TCP HTTP client + SSE 状态机 + tool_call 累积
│
├── agent.v              # Agent struct + step
├── agent_session.v      # Session 纯数据
├── agent_loop.v         # think-act-observe 主循环
├── agent_tool_registry.v
│
├── tools.v              # 内置工具 + 手写 match_glob（grep 已接 rg/regex）
├── tools_web_fetch.v    # web_fetch 实现（HTTP + HTML→text）
├── tools_web_search.v   # web_search 实现（DuckDuckGo HTML 解析）
├── tools_todo.v          # TodoWrite / TodoRead（会话任务清单）
├── tools_ask_user.v      # AskUserQuestion（交互式提问）
├── tools_plan.v           # EnterPlanMode / ExitPlanMode（规划态）
├── tools_mcp.v            # McpTool：把远程 MCP 工具适配为本地 Tool 接口
├── mcp.v                 # MCP 客户端管理：connect / list_tools / call_tool（基于 vlib/mcp）
│
├── config_loader.v      # 多层 config（含 [[mcp]] 服务器配置）
├── config_paths.v
│
├── session_store.v
│
├── sandbox.v            # write_file/edit_file cwd 边界检查
├── approval.v           # risky-tool 审批流（pure helpers + channel struct）
├── compaction.v         # context-window 压缩（60% 触发）
│
├── tui.v                # P1 TUI: ANSI helpers, raw mode, alt screen
├── tui_input.v          # StdinReader (fd_read), KeyEvent, InputBuf + history
├── tui_render.v         # 全帧渲染: header / status / blocks / separator / input
├── tui_loop.v           # main loop: key/status/approval channels, slash commands
│
├── util_log.v
└── util_jsonrpc.v       # JSON-RPC（MCP/ACP 用，P3/P4）
```

---

## 数据流（P0.5 流式）

```
main()
  │
  ├─ load_config(CLI overrides)
  │
  ├─ OpenAICompatProvider{model, api_base, api_key}
  │
  ├─ Agent(provider, system)
  │     .registry = default_registry(cwd)
  │     .on_delta = stdout printer
  │
  └─ Agent.run(mut session)
       for turn in 0..max_turns:
         │
         ├─ step():
         │    ch := chan ChatEvent{}
         │    go provider.chat(req, ch)        ← streams to ch
         │
         │    for ev in ch:
         │      delta   → on_delta(chunk)        ← print to stdout
         │      tool    → buffer tool_call
         │      finish  → break, close channel
         │      err     → return error
         │
         ├─ if no tool_calls → return .finished
         │
         └─ for each tool_call (parallel via go):
                execute_tool(call, args, ctx)
                session.append_tool_result(...)
```

### streaming.v 内部（HTTP 路径）

```
Provider.chat()
  │
  ├─ parse_url(api_base)        ← 检测 http/https
  │
  ├─ if HTTP:
  │     │
  │     ├─ http_post_streaming(url, body, headers)
  │     │    net.dial_tcp("host:port")
  │     │    write("POST /v1/chat/completions HTTP/1.1\r\n...")
  │     │    read status line → assert 2xx
  │     │    read headers → skip until empty line
  │     │    return HttpStreamReader
  │     │
  │     └─ read_sse_stream(reader, out)
  │          for line := reader.read_line():
  │            "" → dispatch current_data
  │            "data: ..." → accumulate
  │            "[DONE]" → return
  │
  └─ if HTTPS:
        chat_buffered_https()    ← P0 fallback (http.fetch + 整包解码)
```

### SSE Parser 关键细节

`SseParser.feed()` 处理单个 SSE event 数据：

1. 解码 `OaiStreamChunk` JSON
2. 对每个 choice：
   - `delta.content` 非空 → emit `.delta`
   - `delta.tool_calls` → 按 `index` 累积到 `tool_calls[index]`
     - 累积 `id`、`name`、append `arguments`（多次）
   - `finish_reason` 非空 → flush 累积的 tool_calls（如果 reason == `tool_calls`），emit `.finish`
3. Usage（如有）暂时仅占位，P0.6 会附加到 finish event

---

## 已知的限制

- **Bash 不做 sandbox**：解析 shell 太复杂，靠审批 + 用户眼睛盯。`write_file` / `edit_file` 已做路径边界
- **审批每次都问**：还没实现"approve for the rest of the session"（`ApprovalDecision.remember` 字段已预留）
- **Grep 是字串匹配**：没接正则（`name.matches(rx)` 在 V 0.5 里不可用，手写 glob 已经替换）
- **Glob 手写**：`*` `?` 支持，复杂模式不支持
- **TLS 证书验证**：默认接受所有证书（自签名友好），生产用法需要传 `SSLConnectConfig{ verify: '/path/to/ca.pem' }`
- **Agent 的 channel lifecycle**：provider goroutine 在写完所有事件后 close channel；Agent.step 读 `.end_of_stream` sentinel 后退出
- **V test 框架对 spawn goroutine 不友好**：跑完测试后 spawned goroutine 不退出，整个 process 会 hang。channel-based 的端到端测试只能手动验；policy / helper 走单测。

---

## License

MIT.