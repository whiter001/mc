# TODO

- [x] Go to File 文档切换器
- [x] 搜索面板选项
- [x] 文档去重打开
- [x] 语言 picker（状态栏按钮 + 弹窗，V 端口不上 ICU 故跳过 encoding picker）
- [x] 大剪贴板警告（≥128 KiB OSC 52 同步前确认）
- [x] redirected stdin 读入文档
- [x] 文件选择器补全
- [x] settings / preferences
- [x] 错误日志与标题同步
- [x] dirty-close / quit 三按钮模态（替代当前内联 status 文字）

## 查找功能：与 Rust 版差异

参考 `crates/edit/src/buffer/mod.rs:1117-1478`、`crates/edit/src/bin/edit/draw_editor.rs:38-192`。
V 侧对应 `text_buffer.v:2348-2601`、`main.v:626-819`。

| # | Rust | V 现状 | 差异 |
|---|------|--------|------|
| 1 | editline 内容变化即触发 `SearchAction::Search`（边打字边跳） | 已对齐：prompt 文本变化即 `run_prompt_search()`（`main.v:637`） | — |
| 2 | 有选区时 Ctrl+F 用选区文本填 needle；无选区时沿用上次 needle（`state.search_needle`） | 已对齐：选区优先，否则 `.search`/`.replace` 都预填 `last_search`（`main.v:673`） | — |
| 3 | `use_regex` 走 ICU 正则；`whole_word` 是 `\b(?:转义pattern)\b`（Unicode `\w`） | `use_regex` 完全无效（选项可见但 `find_substring_match` 不读它）；`whole_word` 只看 ASCII `is_word_byte`（`text_buffer.v:2348`） | 语义缺失/降级 |
| 4 | 大小写不敏感 = ICU CASE_INSENSITIVE（Unicode 折叠） | `fold_ascii` 只折 A-Z | 非 ASCII 不匹配 |
| 5 | 失败时 needle 框变红（`search_success`） | 只在 status 行写 `not found:` | 反馈弱 |
| 6 | replacement 框 `Ctrl+Alt+Enter` = ReplaceAll（`draw_editor.rs:109`） | 仅菜单 Edit > Replace All | 快捷键缺 |
| 7 | 常驻搜索面板（needle/replacement/复选框/Replace All/Close 按钮，Esc 关） | 底部单行 prompt + 上方选项行，Enter 即退出 | 依赖 tui.rs 布局引擎，未移植 |
| 8 | 每次搜索走 ICU `UText`/`URegularExpression`（零拷贝、可 reset 续搜） | 每次 `read_all()` 整文档拷贝（`text_buffer.v:2444`/`2569`），不区分大小写再多两份折叠拷贝；朴素 O(n·m) 匹配 | 性能 O(n²) |
| 9 | 替换 `$1`/`\n` 组引用（依赖 regex） | 无（纯文本替换） | 依赖 ICU，不做 |
| 10 | `find_and_replace_all` 返回 `()` | 返回 count 并显示 `replaced N occurrences` | V 更好，保持 |

## 查找功能优化计划

P0 — 语义/交互对齐
- [x] 增量搜索：prompt 文本变化后调 `run_prompt_search()`（`main.v:594` 之后）
- [ ] `use_regex` 处理：实现最小正则子集（`. ^ $ \b \w \s [...]`、转义）或把选项改为不可选，避免"开关无效"
- [x] Ctrl+F/Ctrl+R 有选区时用选区填 needle（复用 `extract_user_selection` 等价路径）
- [x] 搜索失败视觉反馈：not found 时 prompt 行变红（对齐 `search_success`）
- [x] F3 在 prompt 内也生效，用当前 needle 找下一个（Rust `main.rs:410` 是全局 F3）
- [ ] `whole_word` 边界扩展到非 ASCII：非 ASCII 码点视为词字符
- [ ] 大小写折叠扩展到 Latin-1/希腊/西里尔常用区段

P1 — 性能
- [ ] `find_substring_match` 改分块流式匹配：走 `gap_buffer.read_forward` 零拷贝视图，不再 `read_all()`
- [ ] 折叠按需进行：只折叠与 pattern 等长的窗口，或按块折叠，不再整文档两份拷贝
- [ ] 首字节 `memchr` 快速跳过 + 长 needle 加 Boyer-Moore-Horspool
- [ ] 折叠结果按 `GapBuffer.generation` 缓存，连续 F3 不重复折叠
- [ ] `find_and_replace_all` 去掉循环内 `read_all()`：一次扫描收集全部命中区间，再按累计偏移 delta 逐个替换

P2 — 可选增强
- [ ] replacement 段 `Ctrl+Alt+Enter` = ReplaceAll
- [ ] Shift+F3 反向查找（Rust 无，V 侧自加）
- [ ] 命中计数显示（如 `3/17`）
