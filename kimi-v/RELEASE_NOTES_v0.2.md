# v0.2.0 — TUI 闭环 + 长 session + 安全审批

v0.2 = Phase 1（控制权给用户）+ Phase 1.5（context 不爆）+ Phase 2（internet + 审批 + sandbox）。
原计划估算 1 个月；v0.2.0 是这个里程碑的收尾快照。

---

## 主要变更

### TUI 打磨（Phase 1 收尾）

- **流式 token 实时渲染** — 之前的 TUI 只在 turn 结束时显示完整回复；现在
  thinking/reasoning/answer 三类 chunk 都走 `status_ch` → 状态机分流，30fps 重绘
  实时上屏（`fbdab98`）
- **Ctrl-C 中断 in-flight turn** — `Provider.chat` 增 `cancel_ch`，SSE parser
  在每行 / 每个 send 前 select 一下；agent `step()` 同步监听 cancel；TUI 用
  watcher goroutine 转发。partial thinking + answer 都会提升为 permanent block
  后插 `[cancelled]` system block（`f980673`）
- **多行输入** — Shift+Enter / Alt+Enter 触发 `KeyKind.insert_newline`；layout
  动态算 `input_rows`（cap = min(rows/4, 8)）。注意：粘贴多行仍会提前 submit
  （raw `\n` 映射成 `.enter`），bracketed paste mode 单独立 todo（`8958256`）
- **历史持久化** — `<config_dir>/history` 持久化，0x1E (RS) 分隔多行 prompt，
  save 时 dedup 保留最近 N 条（cap 500）；可用 `KIMI_HISTORY_FILE` 覆盖
  （`2a8823f`）
- **Codepoint 安全的编辑** — Backspace / Delete / cursor 按 UTF-8 codepoint 走，
  之前按 byte 走，emoji/CJK 会切一半（`72215d4`）
- **Slash 命令** — `/usage`（/tokens 别名）、`/compact`（手动触发 compaction）

### Compaction（Phase 1.5）

- **Context-window 压缩** — 60% 触发（自用激进档），粗估 token；自动在每个
  agent step 前跑；失败非致命（`62bfef8`）
- 总结 prompt 内置，压缩后不丢工具调用链

### Web fetch（Phase 2 上半）

- **`web_fetch` 工具** — HTTP(S) GET，HTML→text 自写状态机（strip
  script/style → block-tag 换行 → 实体解码 → 空白折叠）；1 MB 默认上限；
  不跟随 redirect 直接报（`3365126`）

### 审批 & Sandbox（Phase 2 下半）

- **Approval TUI modal** — `bash` / `write_file` / `edit_file` / `web_fetch`
  跑前弹模态，y/n/Esc；input 锁死防误输（`84aae80`）
- **可配置 risky_tools** — `config.toml` 加 `risky_tools = [...]` 数组，或
  `KIMI_RISKY_TOOLS=bash,web_fetch` 环境变量。空 = 用内置 default
  （`34f5360`）
- **write_file / edit_file sandbox** — `resolve_within` 拒绝 `..` 逃逸、绝对
  路径指别处、共享前缀的兄弟目录（`/sandbox-evil` vs `/sandbox`）。Symlink
  不跟（`34f5360`）
- `bash` 暂不做 sandbox（shell 解析太重，自用靠审批 + 用户眼睛看）

### Build hygiene

- 6 个 build notice 全清（tui.v 三个未用函数 + tui_render slice clone + cols）
- 22 个 web_fetch unit test
- 5 个 approval policy test
- 5 个 config_loader test
- 10 个 sandbox test

---

## 测试

7/7 单测文件全过，~9s 跑完：

```
sandbox_test.v          config_loader_test.v
tools_web_fetch_test.v  history_store_test.v
tui_input_test.v        compaction_test.v
approval_test.v
```

> V test 框架对 spawn goroutine 不友好（process 不退出），channel-based
> 端到端走手动 TUI 验证。

## 已知限制（带 v0.2 出货）

- **每次都问审批** — "approve for rest of session" 还没做（`remember` 字段
  已留），下个 session 收
- **Bash 无 sandbox** — 靠审批 + 眼睛
- **粘贴多行** — 提前 submit，bracketed paste mode 待做
- **Stdin 健壮退出** — SIGPIPE/EIO path 区分待做，30 min 收

## 升级 & 兼容性

- session 格式 v0.2 与 v0.1 不兼容（Phase 1.5 改了消息结构）
- `risky_tools` 之前硬编码，现在可配；默认行为不变
- 旧 `~/.config/kimi/config.toml` 继续生效，**不动**就有 v0.2 全部能力

## 下一步

v0.3 = Phase 3 = MCP client + 多 provider + OAuth（optional 锁已下；优先做
MCP stdio，HTTP transport 看情况）。
