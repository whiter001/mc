# Kimi-V Feature Parity Plan

> 从 P0–P1.5 现状出发，规划到"用户日常能感知的 kimi-code 特性基本都有"。
> 配套：原 [PLAN.md](./PLAN.md)（P0–P6 阶段划分 + 模块设计）。
> 上游基线：[MoonshotAI/kimi-code](https://github.com/MoonshotAI/kimi-code) v1.46+（架构参见 [kimi-cli/AGENTS.md](https://github.com/MoonshotAI/kimi-cli/blob/main/AGENTS.md)）。

---

## 0. Parity 的定义（先把"全量"圈清楚）

| 类别 | 进 parity | 显式划线 |
|---|---|---|
| Core agent loop / tools / session / config | ✅ | |
| TUI (raw mode, slash, status, streaming) | ✅ | |
| 6 个内置工具 + web_fetch | ✅ | |
| OpenAI 兼容（Kimi/OpenAI/DeepSeek/OpenRouter）+ Anthropic | ✅ | |
| MCP client（stdio + HTTP）+ /mcp-config | ✅ | |
| OAuth + API key 双认证 | ✅ | |
| ACP server（Zed/JetBrains 接入） | ✅ | |
| Subagents（coder / explore / plan）+ 持久化 + resume | ✅ | |
| Skills（SKILL.md loader）+ Hooks（生命周期） | ✅ | |
| Compaction（context 溢出压缩） | ✅ | |
| Tool call dedup（same-step / cross-step） | ✅ | |
| Approval lifecycle（per-tool 策略 + session 状态） | ✅ | |
| 多 slash（/usage /compact /upgrade /model picker） | ✅ | |
| Status bar 任务计数 / btw / plan-mode | ✅ | |
| **P6 Web / Desktop** | ❌ | 商业版功能，V 重写无意义 |
| **Telemetry server + 上报** | ❌ | 无服务端基建；本地日志已够 |
| **Marketplace 托管 / 一键安装** | ❌ | GitHub 直装就够用 |
| **Video input**（截屏/视频 → 代码） | ❌ | ffmpeg + vision API 重；niche |
| **DMail / checkpointed subagent** | defer | P5 阶段评估；P0 不做 |
| **Anthropic prompt cache / 1M context 等 provider 黑魔法** | defer | provider 层自然吸收 |

**一句话**：**对齐 kimi-code 的"日常 80% 用到的能力"**，不抄冷门和商业部分。

---

## 1. 现状盘点

| 阶段 | 状态 | 备注 |
|---|---|---|
| P0 MVP | ✅ | |
| P0.5 流式 | ✅ | 真 SSE，HTTP/HTTPS 都走通 |
| P0.6 Usage | ✅ | finish event 带 token |
| P1 TUI | ✅ | alt-screen + raw mode + 30fps 全帧 |
| **P1.5 TUI 打磨** | 🚧 2/4 | 已做：thinking 接线 + streaming delta 实时渲染；剩 Ctrl-C 取消 / 多行 / 历史 |
| P2 web_fetch + 审批 | ❌ | |
| P3 MCP + OAuth | ❌（v0.3 optional） | |
| P4 ACP | ❌ | |
| P5 subagents + hooks + skills | ❌ | |
| P6 Web/Desktop | ❌（划线） | |

**还有 5 块在 PLAN.md 里没写、但 upstream 有：**

1. **Compaction** — context 窗口超限自动总结（upstream `src/kimi_cli/soul/compaction.py`）
2. **Tool call dedup** — 同 step / 跨 step 重复检测
3. **Subagent 持久化 + resume by agent_id** — 不只是 spawn，session 目录里存
4. **Approval lifecycle** — session 级 pending 状态、cancel 反馈到 wire
5. **Stdin / TTY 健壮退出** — 管道断裂 / 信号 race

---

## 2. 阶段路线（从现在到 parity）

### Phase 1：TUI 打磨 + 闭环（P1.5 收尾 + 补漏）
**目标**：TUI 体感从"能用"到"愿意每天开"。
**估算**：2–3 个 session。

| 任务 | 状态 | 关键点 |
|---|---|---|
| streaming delta 实时渲染 | ✅ (2026-07-11) | `StatusKind.delta` / `.thinking_delta` + 状态机切到 `state.streaming` / `state.streaming_thinking`，render 区分静态/流式；back-pressure 走 `status_ch` 容量 |
| Ctrl-C 取消 | ⏳ | provider 加 cancellation flag，TCP read 走 ctx |
| 多行输入 | ⏳ | Shift+Enter / Ctrl-J 走 `KeyEvent.kind = .newline` |
| 历史持久化 | ⏳ | TUI 退出写 `~/.local/share/kimi/history`，启动时载入 |
| `/usage` `/compact` slash | ⏳ | `/usage` 调 `agent_loop` 的 usage 字段；`/compact` 走 compaction（见 Phase 1.5） |
| Stdin 健壮退出 | ⏳ | SIGPIPE / EIO 路径 `leave_tui` + 退码区分 |

### Phase 1.5：Compaction（独立小阶段）
**目标**：长 session 不会因 context 超限炸掉。
**估算**：2–3 个 session。

| 任务 | 关键点 |
|---|---|
| Token 计数预估 | 用 `tiktoken` 等价：V 自实现 BPE 太重，先粗估 4 char/token |
| 截断策略 | 当 estimated > N% context 窗口 → 触发 compaction |
| 总结 prompt | 内置一个 summarizer 系统消息模板 |
| 跨 session compaction | session 重启时如果超限自动先压缩 |

### Phase 2：web_fetch + 审批（P2）
**目标**：上 internet + 危险操作前要人确认。
**估算**：3–4 个 session。

| 任务 | 关键点 |
|---|---|
| `web_fetch` 工具 | 复用 `streaming.v` 的 HTTP 客户端，加 HTML→MD 转换（`html2text` 思路，自写或拉个 lib） |
| Approval TUI modal | 风险工具（`bash` / `write_file` / `edit_file` / `web_fetch`）调用前弹确认 |
| Per-tool 权限策略 | `~/.config/kimi/permissions.toml`：`{ tool: "bash", pattern: "rm *", action: "ask" }` |
| Sandbox（轻量） | cwd 边界 + 命令白名单，per session 配置 |

### Phase 3：MCP + 多 provider + OAuth（P3）
**目标**：可扩展（接任何 MCP server）+ 多家模型 + 浏览器登录。
**估算**：5–7 个 session（MCP 是大头）。

| 任务 | 关键点 |
|---|---|
| MCP client — stdio transport | 起子进程、JSON-RPC over stdin/stdout；`util_jsonrpc.v` 已有骨架 |
| MCP client — HTTP transport (SSE) | 长连接、SSE 推送 |
| `/mcp-config` 对话式配置 | 添加 server 走 TUI 表单；auth 流程也走 TUI |
| Anthropic provider | 新建 `llm_anthropic.v`；消息格式 + tool_use 块转换 |
| OAuth + 本地回调 | 起本地 HTTP server 接 auth code；refresh token 持久化 |
| `kimi login` 双模式 | `--oauth` / `--api-key` flag |

### Phase 4：ACP server（P4）
**目标**：Zed / JetBrains 跑通。
**估算**：3–4 个 session（协议清晰，模块化）。

| 任务 | 关键点 |
|---|---|
| `kimi acp` 子命令 | main.v 分流，stdio JSON-RPC |
| Schema 定义 | `acp_schema.v`：load_agent / prompt / cancel / session/list 等 |
| Session 复用 | 走 `session_store.v` |
| IDE 联调 | Zed settings.json + JetBrains 文档写一份 |

### Phase 5：Subagents + Skills + Hooks（P5）
**目标**：agent 派活 + 用户自定义能力 + 生命周期拦截。
**估算**：5–7 个 session。

| 任务 | 关键点 |
|---|---|
| LaborMarket（subagent 注册表） | 内置 `coder` / `explore` / `plan`；spec 用 TOML |
| Subagent 实例化 | 给 subagent 一个独立 Session，递归 `agent.run` |
| Subagent 持久化 | session 目录里 `subagents/<agent_id>/`，可 resume |
| `Agent` 工具 | 主 agent 用 `Agent` 工具派发 subagent，结果回流 |
| Skill loader | `SKILL.md`（TOML front matter + markdown body）；`~/.kimi/skills/` + `./.kimi/skills/` |
| Hook runner | `tool.pre_call` / `tool.post_call` / `turn.end` 三类；本地 shell 阻塞跑 |
| `/skill:NAME` slash | 装载 skill 内容到 system prompt |

### 跨阶段：Tool call dedup（独立小阶段）
**目标**：模型手抖重复发 tool call 不浪费 token。
**估算**：1 个 session。

| 任务 | 关键点 |
|---|---|
| Same-step dedup | 同一 step 内同 `(name, args_hash)` 合并，结果复用 |
| Cross-step dedup | 跨 step 重复且 args 完全相同 → 复用上次结果，给个 sparse 提醒 |

---

## 3. 关键决策（需要锁的）

> **2026-07-11 锁定的 4 个 open question 答案**（见 §7）：
> 1. **时间线** → v0.2 优先（Phase 1+1.5+2），其它按序
> 2. **MCP** → 降为 optional（推到 v0.3 之后再说；省 1 周）
> 3. **Subagent 持久化** → 先 spawn-and-forget；持久化留 v0.3+
> 4. **Skill 描述语言** → **YAML**（贴 upstream + Claude Code 生态，免写转换器）

| 决策点 | 默认方案 | 备选 | 影响 |
|---|---|---|---|
| Parity 范围 | 用户日常 80% | 全量含 video/telemetry | 工作量差 2-3x |
| Skill 描述语言 | **YAML front matter**（2026-07-11 锁定） | TOML（贴我们 config 习惯） | 写转换器 vs 不写 |
| MCP 优先级 | **optional**（2026-07-11 锁定，v0.3 再说） | 必做（P3 头号） | 砍掉少 1 周工作量 |
| Approval 机制 | TUI 内嵌 modal | shell 外部 prompt | 实现复杂度差 1x |
| ACP 范围 | 最小可用（load + prompt） | 全协议 | 工作量差 2x |
| Subagent 隔离 | 独立 Session + 独立 cwd | 共享 context | 实现差很多 |
| Subagent 持久化 | **spawn-and-forget**（2026-07-11 锁定） | session 目录存实例可 resume | 留 v0.3+ 实现 |

---

## 4. 时间线估算（**默认全栈 parity**）

| 阶段 | 任务量 | 累计 |
|---|---|---|
| Phase 1（TUI 收尾） | 2–3 session | 2–3 |
| Phase 1.5（Compaction） | 2–3 | 4–6 |
| Phase 2（web_fetch + 审批） | 3–4 | 7–10 |
| Phase 3（MCP + 多 provider + OAuth） | 5–7 | 12–17 |
| Phase 4（ACP） | 3–4 | 15–21 |
| Phase 5（subagents + skills + hooks） | 5–7 | 20–28 |
| 跨：dedup | 1 | 21–29 |
| **合计** | | **~25 个 session（每个 1–2h）** |

对应 milestone：
- **v0.2**（1 个月）= Phase 1+1.5+2：TUI 闭环 + 长 session 不爆 + web_fetch
- **v0.3**（1 季度）= 加 Phase 3：MCP + 多 provider + OAuth
- **v0.4**（再加 1–2 月）= 加 Phase 4：IDE 接入
- **v0.5**（再加 2 月）= 加 Phase 5：subagents + skills + hooks
- **v1.0** parity（不含 P6/video/telemetry/marketplace）= 累计 ~5–6 月

---

## 5. 风险

| 风险 | 触发条件 | 对策 |
|---|---|---|
| MCP stdio 在 V 上难稳定 | 进程管理 / EOF 处理 | 用 `os.process` + select，先 HTTP 路径，stdio 后做 |
| OAuth 跨平台回调 | Windows 防火墙 | 文档化 `KIMI_OAUTH_REDIRECT_URI` 可覆盖 |
| Anthropic tool_use 块格式与 OpenAI 不同 | 转换出错 | 写大量单测覆盖 edge case；先支持 message + tool_use 不带 thinking |
| TUI diff 渲染赶不上 streaming | 大量 chunk 涌入 | 先全帧 30fps，P5 升级 diff 渲染 |
| Skills 描述语言不一致 | 用户写 SKILL.md 时踩坑 | 文档化示例 + 错误提示 + 模板 |

---

## 6. 现在该怎么走

1. **确认 parity 范围**（表头那份"划线"清单 OK 吗）
2. **确认时间线目标**（v0.2 / v0.3 / v0.4 / v0.5 哪个先打）
3. 当前 session 我建议直接开 **Phase 1 第一项**（streaming delta 实时渲染）—— 上次 TODO 列表里就有，等于推进而不偏题

---

## 7. 已锁定的 open questions（2026-07-11）

| # | 问题 | 答案 | 备选 |
|---|---|---|---|
| 1 | 时间线目标 | **v0.2 优先**（Phase 1+1.5+2） | v0.3（MCP）前置 |
| 2 | MCP 必做还是可选 | **可选**（v0.3 再说；省 1 周） | 必做 |
| 3 | Subagent 持久化 | **先 spawn-and-forget**（v0.3+ 再做持久化） | session 目录存实例可 resume |
| 4 | Skills 描述语言 | **YAML**（贴 upstream + Claude Code 生态） | TOML（贴我们 config 习惯） |

落地：见 §3「关键决策」表中带 `2026-07-11 锁定` 标记的行。
