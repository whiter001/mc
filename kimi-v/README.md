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
- ✅ **Anthropic provider**（`--provider anthropic`，Claude 系列；流式 SSE + 工具调用）
- ✅ **多层 config**（CLI > env > project > user > default）
- ✅ **跨平台路径**（XDG / macOS / Windows）
- ✅ **Session 持久化**（写 TOML）
- ✅ **P1 TUI**：alt-screen + raw mode + 30fps 全帧重绘
- ✅ **P1.5**：流式 token 实时渲染 / Ctrl-C 中断 / 多行输入 / 历史持久化 / **context 压缩（60% 触发）**
- ✅ **P2 审批**：`bash` / `write_file` / `edit_file` / `web_fetch` 走 TUI 模态 y/n
- ✅ **P2 配置化审批**：`risky_tools` via `config.toml` 或 `KIMI_RISKY_TOOLS`
- ✅ **P2 权限规则引擎**：`[[permission.rules]]` 定义 deny / allow / ask 规则（`Tool(glob)` 模式），deny 无条件优先，allow 免弹窗、ask 强制弹窗
- ✅ **P2 审批记忆**：审批模态按 `a` 记住「always allow」，持久化到 `<config-dir>/approved_tools`，重启自动加载；`/approvals` 查看、`/approvals clear` 清空
- ✅ **AGENTS.md 指令加载**：启动时把 `<config-dir>/AGENTS.md`、`~/.agents/AGENTS.md`、`<cwd>/.kimi/AGENTS.md`、`<cwd>/AGENTS.md` 按序拼进 system prompt（用户 `--system` 之后；-p 与 TUI 均生效）
- ✅ **瞬态错误自动重试**：`[loop_control] max_retries_per_step`（默认 10，env `KIMI_LOOP_MAX_RETRIES_PER_STEP` 可覆盖），429 / 5xx / 连接失败指数退避（0.5s/1s/2s…上限 32s，+25% jitter）重试整个 step；Ctrl-C 可打断退避
- ✅ **Bash 工具超时**：`timeout_ms` 参数生效（默认 60s，上限 5min），超时 kill 整个进程组并返回带「timed out after N ms」的错误结果，模型可调大重试
- ✅ **P2 sandbox**：`write_file` / `edit_file` 拒绝 `..` 逃逸到 cwd 外
- ✅ **Plan-mode**：`/plan` 进入只读规划态；`EnterPlanMode` / `ExitPlanMode` 工具；规划态下除 plan 文件外禁止写文件；`ExitPlanMode` 弹出 plan 审阅模态（y 批准 / n 拒绝 / e 拒绝并退出 / r 修订 / Esc 忽略；多方案可数字键选）
- ✅ **Slash 命令**：`/help` `/clear` `/new` `/sessions` `/login` `/model` `/plan` `/goal` `/tokens` `/usage` `/compact` `/exit`
- ✅ **Goal 系统**：`CreateGoal` / `GetGoal` / `UpdateGoal` / `SetGoalBudget` 工具；goal active 时 loop 自动续跑直到模型裁决 complete/blocked 或触及 turns/tokens/wall-clock 预算；Ctrl-C 自动暂停；goal 随 session 持久化（metadata base64 JSON），恢复时 active 降级为 paused；TUI header 显示 `[GOAL <status> · N turns]` 徽章，`/goal [pause|resume|cancel]` 查看与控制
- ✅ **Cron 定时任务**：`CronCreate` / `CronList` / `CronDelete` 工具（5 字段 cron 表达式：分 时 日 月 周，本地时间；每 session 上限 50）；TUI 调度器每秒检查到期任务，包成 `<cron-fire>` 消息注入为一个 turn（agent 忙时排队、多个到期合并为最新一条）；one-shot 触发即删，recurring 跨过多个 fire 点只补一次；任务按 session 持久化到 `<config-dir>/cron/<session-id>.json`；headless `-p` / ACP 可用工具但不跑调度器
- ✅ **Checkpoint/Undo**：`write_file` / `edit_file` 写盘前自动快照到 `<config-dir>/checkpoints/<session-id>/`（manifest + `<seq>.bak`，每 session 上限 50、超出淘汰最旧）；TUI `/undo` 撤销最近一次文件修改（已有文件恢复原文、新建文件删除），`/undo list` 查看快照列表；checkpoint 失败只告警不阻断写入
- ✅ **键盘**：字符输入 / Enter / Backspace / Ctrl-A / Ctrl-E / Ctrl-U / Ctrl-W / Esc Esc 退出
- ✅ **OAuth 登录**：RFC 8628 device flow（`kimi login --oauth`，浏览器授权）；凭据存 `<config-dir>/credentials.json`（文件 0600、目录 0700）；access token 过期后自动用 refresh token 续期；`kimi logout` 删除凭据

### 还差（按 PLAN.md 阶段）

- [x] P3 多 provider：Anthropic ✅（`--provider anthropic`；OAuth ✅ 见下；Google 未做）
- [x] P4 ACP server ✅
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
- [x] P4 ACP server ✅
  - ACP v1（Agent Client Protocol）stdio server：`kimi acp` 启动，stdin/stdout 走 newline-delimited JSON-RPC（每行一帧、即时 flush），日志只进 stderr，不污染协议流
  - 实现方法：`initialize` / `notifications/initialized` / `authenticate` / `session/new` / `session/load` / `session/prompt` / `session/cancel`
  - 提示在会话 cwd 下运行 agent（加载该目录 AGENTS.md、config.toml 的 MCP 服务器、skills、hooks）；无凭据时 `authenticate` 返回 -32001 并提示先 `kimi login` 或设 `KIMI_API_KEY`
  - 流式输出：回复以 `agent_message_chunk` 文本增量实时推送 `session/update`，结束时回 `{"stopReason":"end_turn"|"max_turn_requests"}`；`session/load` 重放会话文本历史
  - 子集限制：仅支持 `text` content block；thinking / tool-call 流式 update 未实现；`mcpServers` 字段接受但不转发；`session/close` / `session/list` / `session/delete` 及 fs / terminal 能力未实现；同一会话并发 prompt 返回 -32602

  Zed `agent_servers` 配置示例（把 `/path/to/kimi` 换成实际路径）：
  ```json
  {
    "agent_servers": {
      "kimi": {
        "command": ["/path/to/kimi", "acp"],
        "transport": "stdio"
      }
    }
  }
  ```
  协议文档：<https://agentclientprotocol.com/protocol/v1/overview>
- [x] P5 子 agent（coder/explore/plan）+ hooks + skills ✅
  - **子 agent**：`Agent` 工具派发 `coder` / `explore` / `plan` 三种预设 profile，独立 Session 递归运行，结果回流父 agent
  - **后台子 agent**：`Agent` 工具 `run_in_background: true` 时丢进 goroutine 异步执行，主循环不阻塞、可继续干活；`TaskList` 工具随时查看运行中/已完成任务及结果，完成结果以 `<background-agent-result>` 消息自动注入会话
  - **resume**：`Agent` 工具传 `resume: <agent-id>` 从持久化 session（`<config-dir>/sessions/subagents/`）续跑超时/中断的子 agent；与 `subagent_type` 互斥
  - **AgentSwarm**：一次派发多个子 agent —— `prompt_template` + `items` 批量展开（也可 `resume_agent_ids` 批量续跑），展开重复/缺占位符/未知类型在启动前校验；前台串行、后台（`run_in_background`）goroutine 并行，结束后汇总逐条结果
  - **Hooks**：15 类生命周期事件（tool / turn / session / message / agent / file / error / approval），fail-open，exit 0=allow / 2=block，支持 `permissionDecision:deny` 结构化拦截
  - **Skills**：`SKILL.md`（front matter + markdown body）loader，从 `~/.kimi/skills/` 与 `./.kimi/skills/` 装载，`/skill:NAME` 斜杠命令注入 system prompt，支持 `$ARGUMENTS` / `$N` / `$name` / `${KIMI_SKILL_DIR}` 占位符
- [x] Plan-mode（`/plan` + EnterPlanMode/ExitPlanMode）✅
- [ ] P6 Web / Desktop

### 本轮补齐的工具能力（parity 小步快跑）

对齐 `kimi-code` 的 `builtin/*` 工具集，补了 4 块日常高频能力：

- **`grep` 升级为正则**：优先调用 `rg`（ripgrep，与上游一致，跳过 VCS/隐藏文件、支持 glob、`-i` 大小写不敏感）；`rg` 不可用时回退到 V 自带 `regex` 模块逐行匹配，仍无效则退到字串匹配。schema 新增 `include` 与 `i` 参数。
- **`web_search`**：后端 provider 可配置 —— 默认走 DuckDuckGo HTML 端点免 key 联网搜索（复用 `web_fetch` 的 HTML→text 管线解析结果）；也可切到 Moonshot 托管搜索 API（`[web_search]` 表配置 provider/base_url/api_key，见 `config.example.toml`）。返回带标题/URL/摘要的编号列表。
- **`TodoWrite` / `TodoRead`**：会话级任务清单，状态存在 `Agent.todos` 上（Agent 已是 per-session 单例），`TodoWrite` 整体覆盖、`TodoRead` 读取并以 Markdown 渲染。
- **`AskUserQuestion`**：模型向用户提问（单选/多选）。TUI 里渲染底部模态、数字键选择、逗号多选、Esc 跳过；`-p` 非交互模式超时返回提示，不阻塞。

#### 新文件

```
tools_web_search.v   # 可配置搜索 provider（DDG 默认 / Moonshot 托管）
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
# 1) 凭证（二选一）
#    API key 方式（写入 config.toml）：
./bin/kimi login
#    OAuth 方式（浏览器授权；凭据写入 credentials.json，不碰 config.toml）：
./bin/kimi login --oauth
#       OAuth 登录后使用 Kimi coding 端点需要设置：
#       export KIMI_API_BASE=https://api.kimi.com/coding/v1
#       export KIMI_MODEL=你的模型名
#    删除 OAuth 凭据：
./bin/kimi logout

# 2) 单次任务
./bin/kimi -p "list every .v file in this directory and count lines"

# 3) 交互式 TUI（默认，无 -p）
./bin/kimi

# 4) env + flags
KIMI_API_KEY=$YOUR_KEY \
KIMI_API_BASE=https://api.moonshot.cn/v1 \
KIMI_MODEL=moonshot-v1-8k \
./bin/kimi -p "summarize README.md"

# 5) Anthropic（`--provider anthropic`；key 走 ANTHROPIC_API_KEY，base 默认 api.anthropic.com）
ANTHROPIC_API_KEY=$ANTHROPIC_KEY \
./bin/kimi --provider anthropic --model claude-sonnet-4-5 -p "summarize README.md"
```

### OAuth 配置项

`kimi login --oauth` 走 RFC 8628 device flow，端点默认对齐 kimi-code（`https://auth.kimi.com`），
全部可用环境变量覆盖（测试 / 自建网关用）：

| 环境变量 | 默认 |
|---|---|
| `KIMI_CODE_OAUTH_HOST` / `KIMI_OAUTH_HOST` | `https://auth.kimi.com` |
| `KIMI_OAUTH_DEVICE_URL` | `<host>/api/oauth/device_authorization` |
| `KIMI_OAUTH_TOKEN_URL` | `<host>/api/oauth/token` |
| `KIMI_OAUTH_CLIENT_ID` | `17e5f671-d194-4dfb-9706-5516cb48c098`（kimi-code 同款） |
| `KIMI_OAUTH_NO_BROWSER` | `1`/`true` 时不再自动打开浏览器（脚本/CI） |

access token 15 分钟过期（TTL 与上游一致），过期后下次启动自动用 refresh token 续期并
回写 `credentials.json`；refresh 失败会提示重新 `kimi login --oauth`。OAuth 凭据与
`config.toml` 的 `api_key` 相互独立：只要配置了 `api_key`（或 `KIMI_API_KEY`），OAuth
不参与。

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
| `/new` | `/clear` 的别名 |
| `/sessions` | 浏览并切换持久化 session（数字键选择） |
| `/login` | 提示去另一个 shell 跑 `kimi login --oauth`（TUI 暂不读密码） |
| `/logout` | 删除 OAuth 凭据（重启 TUI 生效） |
| `/model NAME` | 切换模型 |
| `/tokens` / `/usage` | 显示当前 session 累计 token 用量 |
| `/compact [instruction]` | 立即强制压缩当前 session（跳过自动 60% 阈值；可选附加指令引导摘要侧重点） |
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
| `--api-base` | env: `KIMI_API_BASE`（openai-compat 默认 `https://api.openai.com`；anthropic 默认 `https://api.anthropic.com`，可用 `ANTHROPIC_BASE_URL` 覆盖） |
| `--api-key` | env: `KIMI_API_KEY`；anthropic 用 `ANTHROPIC_API_KEY` |
| `--provider` | `openai-compat` (默认) / `anthropic` |
| `--system` | env: `KIMI_SYSTEM_PROMPT` |
| `--max-turns` | `32` |
| `--max-tokens` | `4096` |
| `--log-level` | env: `KIMI_LOG_LEVEL` |
| `--oauth`（仅 `login`） | 用 OAuth device flow 登录（浏览器授权） |

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

要更精细的策略，用 `[[permission.rules]]` 定义 deny / allow / ask 规则。每条规则一个
`Tool(glob)` 模式（工具名大小写不敏感，写注册表全名：`bash` / `write_file` /
`edit_file` / `web_fetch`；裸工具名 = 匹配该工具的所有调用），按 deny → allow → ask
顺序求值，deny 无条件优先（yolo 也不放过），并附上 reason 喂回给模型：

```toml
[[permission.rules]]
decision = "deny"
pattern  = "Bash(rm -rf *)"          # 任何 rm -rf 直接拦下，不弹窗
reason   = "protect against accidental rm -rf"

[[permission.rules]]
decision = "deny"
pattern  = "Write_file(/etc/**)"     # 写 /etc 直接拦下
reason   = "never touch system config"

[[permission.rules]]
decision = "allow"
pattern  = "Bash(git *)"             # git 命令免弹窗

[[permission.rules]]
decision = "ask"
pattern  = "Bash(npm install *)"     # 装包强制弹窗确认
```

非法的规则条目（decision 不是 allow/deny/ask、pattern 解析不了）会在加载时
warning 跳过 —— fail-open，写错也不会锁死或崩掉。

**审批记忆**：审批模态里按 `a` = 批准本次并记住该工具「always allow」。记住的列表
持久化在 `<config-dir>/approved_tools`（每行一个工具名，可用 `KIMI_APPROVED_TOOLS_FILE`
环境变量覆盖路径），下次启动自动加载；敏感模式（`rm -rf`、`sudo`、`/etc/*` 等）
即使在已批准列表里也仍会重新弹窗。TUI 里 `/approvals` 查看当前列表、`/approvals clear`
清空（下一条指令的下一 turn 生效）。`-p` 单发模式没有「记住」入口，但会加载持久化
列表并执行 deny/allow/ask 规则。

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
├── llm_anthropic.v      # Anthropic 实现（/v1/messages 流式 + tool_use 增量累积）
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
├── subagent.v             # 子 agent 运行器：run_subagent / 后台任务 / 结果回流
├── subagent_profiles.v    # coder / explore / plan 预设 profile
├── tools_subagent.v       # Agent 工具（run_in_background / resume / 结果格式化）
├── tools_subagent_tasklist.v  # TaskList 工具（查看后台子 agent 任务）
├── tools_subagent_swarm.v     # AgentSwarm 工具（批量派发 / 批量续跑）
│
├── config_loader.v      # 多层 config（含 [[mcp]] 服务器配置）
├── config_paths.v
├── oauth.v              # Kimi Code OAuth 登录（RFC 8628 device flow + refresh）
├── oauth_test.v         # OAuth 单测（凭据存取/权限/过期/轮询状态机）
│
├── session_store.v
├── session_switch.v      # /sessions 切换 + /compact 控制通道（SessionControl）
│
├── sandbox.v            # write_file/edit_file cwd 边界检查
├── approval.v           # risky-tool 审批流（pure helpers + channel struct）
├── permissions.v        # [[permission.rules]] 规则引擎 + approved_tools 持久化
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
  ├─ make_provider(cfg)   # OpenAICompat 或 Anthropic
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
- **Permission 模式不含嵌套括号**：`Tool(glob)` 只认第一个 `(` 与末尾 `)`，glob 内不能有 `)`（如 `Bash(cd /a && rm -rf *)` 里的括号不解析，会 warning 跳过）；含 `)` 的路径模式建议用通配写法覆盖
- **`/approvals clear` 下一 turn 生效**：agent 在每 turn 开头重载持久化列表，所以 clear 后正在进行的 turn 里已批准的调用仍放行
- **Grep 回退链**：优先 `rg`，`rg` 不可用回退 V `regex` 模块逐行匹配，正则编译失败退到字串匹配；`glob` 工具仍是手写 `*` `?`，复杂模式不支持
- **TLS 证书验证**：默认接受所有证书（自签名友好），生产用法需要传 `SSLConnectConfig{ verify: '/path/to/ca.pem' }`
- **Agent 的 channel lifecycle**：provider goroutine 在写完所有事件后 close channel；Agent.step 读 `.end_of_stream` sentinel 后退出
- **V test 框架对 spawn goroutine 不友好**：跑完测试后 spawned goroutine 不退出，整个 process 会 hang。channel-based 的端到端测试只能手动验；policy / helper 走单测。

---

## License

MIT.