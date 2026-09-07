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
| 3 | `use_regex` 走 ICU 正则；`whole_word` 是 `\b(?:转义pattern)\b`（Unicode `\w`） | 已有最小正则子集：`.` `^` `$` `\b` `\w` `\s` `\d` 转义与 `[...]`，由 `find_substring_match` 分派到 `find_regex_match`（`text_buffer.v:2481`）；`whole_word` 仍只看 ASCII `is_word_byte`（`text_buffer.v:2506`），无量词/分组/或 | 部分降级 |
| 4 | 大小写不敏感 = ICU CASE_INSENSITIVE（Unicode 折叠） | `fold_ascii` 只折 A-Z | 非 ASCII 不匹配 |
| 5 | 失败时 needle 框变红（`search_success`） | 已对齐：prompt 行变红（`main.v:274`）+ status 行 `not found:` | V 更强，保持 |
| 6 | replacement 框 `Ctrl+Alt+Enter` = ReplaceAll（`draw_editor.rs:109`） | 仅菜单 Edit > Replace All | 快捷键缺 |
| 7 | 常驻搜索面板（needle/replacement/复选框/Replace All/Close 按钮，Esc 关） | 底部单行 prompt + 上方选项行，Enter 即退出 | 依赖 tui.rs 布局引擎，未移植 |
| 8 | 每次搜索走 ICU `UText`/`URegularExpression`（零拷贝、可 reset 续搜） | 每次 `read_all()` 整文档拷贝（`text_buffer.v:2444`/`2569`），不区分大小写再多两份折叠拷贝；朴素 O(n·m) 匹配 | 性能 O(n²) |
| 9 | 替换 `$1`/`\n` 组引用（依赖 regex） | 无（纯文本替换） | 依赖 ICU，不做 |
| 10 | `find_and_replace_all` 返回 `()` | 返回 count 并显示 `replaced N occurrences` | V 更好，保持 |

## 查找功能优化计划

P0 — 语义/交互对齐
- [x] 增量搜索：prompt 文本变化后调 `run_prompt_search()`（`main.v:594` 之后）
- [x] `use_regex` 最小子集已接通；剩余是把 `whole_word` 的 `\b` 语义对齐（见 P0 末条）
- [x] Ctrl+F/Ctrl+R 有选区时用选区填 needle（复用 `extract_user_selection` 等价路径）
- [x] 搜索失败视觉反馈：not found 时 prompt 行变红（对齐 `search_success`）
- [x] F3 在 prompt 内也生效，用当前 needle 找下一个（Rust `main.rs:410` 是全局 F3）
- [x] **零宽正则命中后 F3 原地打转**：`find_select_next` 命中时 `next_search_offset = range_end`，零宽（`^`/`$`/`\b`）时 `range_end == range_beg`，下一次还从同一处搜，永远停在首行。Rust 靠 ICU `regex.next()` 自动前进。修法：命中后若 `range_end == range_beg`，改用现成的 `find_advance_past_zero_width(range_end)`（`text_buffer.v:2887`）推进（已修）
- [x] **replacement 段 `Ctrl+Alt+Enter` = ReplaceAll**：Rust `draw_editor.rs:109`；`input.v:278` 已把 `ESC \n` 解析为 `kbmod_ctrl_alt | vk_return`，在 `handle_prompt_key` 的 `vk_return` 分支加 `kbmod_ctrl_alt` 即可（置 `ed.replace_all = true` 再走 `confirm_prompt`，已修）
- [x] **Esc 取消搜索不记住刚输入的 needle**：Rust 的 editline 直接写 `state.search_needle`，边打字边更新，Esc 关面板后 F3 用最后输入的词；V 只有回车才写 `last_search`。修法：`run_prompt_search()` 里同步 `ed.last_search = needle`（已修）
- [x] **查找跳转的可见区域没扣面板行**：`make_cursor_visible` 用 `height - 2`（`main.v:1646`），但 prompt 打开时底部还有选项行（`status_y-1`）和 prompt 行（`status_y`），文本区又画到 `height-1`（`main.v:1679`），命中落在底部 1–2 行会被面板盖住。Rust 用 `height_reduction`（Search 4 / Replace 5，`draw_editor.rs:21-25`）。修法：`viewport_height` 按 `ed.mode == .prompt` 再减 1（已修；用 `== .prompt && != .goto_line`，仅扣选项行；prompt 行本来就在 status 行之上覆盖文本最后一行的等价处理）
- [x] **空 needle 回车**：Rust `find_and_select("")` 会清选区并把光标移到选区起点（`buffer/mod.rs:1126-1130`）；V 的 `confirm_prompt`/`find_next` 走 `move_cursor_to_selection_beg()`（`main.v:847`、`:911`，已修）
- [x] **Ctrl+R 且已有选区时**：Rust 把焦点直接放到 replacement 框（needle 已由选区填好，`draw_editor.rs:59-62`）；V 的 `start_replace()` 跳过 needle 段直接开 replacement 框（`main.v:699`，已修）
- [x] **prompt 单行编辑能力**：Rust 的 editline 是完整单行 TextBuffer（←/→、Home/End、Delete、Ctrl+V、Ctrl+A、行内选区、粘贴 strip 换行）；现在 `Editor.prompt_cursor`（`main.v:102`）+ UTF-8 走 `prompt_prev_codepoint` / `prompt_next_codepoint`（`main.v:752` / `:771`）+ `handle_prompt_key` 增 `vk_left` / `vk_right` / `vk_home` / `vk_end` / `vk_delete` / `Ctrl+A` 跳首 / `Ctrl+K` 删到尾 / `Ctrl+U` 删整行（`main.v:944-989`），`draw_prompt_line` 改用 `prompt_text[..off]` 重新走 `MeasurementConfig` 算光标列。粘贴换行 strip 已有（`main.v:629`）。行内选区暂不做（Rust 单行 TextBuffer 也不带选区，模型一致即可）。
- [x] `whole_word` 边界扩展到非 ASCII：非 ASCII 码点视为词字符（`text_buffer.v:2362` `is_word_rune` 把 `cp >= 0x80` 当词字符；`is_word_byte` 同样，`find_substring_match` / `re_seq_match` 用它做 `\b` 边界）
- [x] 大小写折叠扩展到 Latin-1/希腊/西里尔常用区段（`text_buffer.v:2423` `fold_rune`：ASCII + Latin-1 `À-Ö Ø-Þ` + Greek `Α-Ω` + Cyrillic `А-Я`；`fold_text` 编码后字节数相等，所以可安全复用 `text_buffer.v:2485` 的折叠后位置）

P1 — 性能
- [ ] `find_substring_match` 改分块流式匹配：走 `gap_buffer.read_forward` 零拷贝视图，不再 `read_all()`
- [ ] 折叠按需进行：只折叠与 pattern 等长的窗口，或按块折叠，不再整文档两份拷贝
- [ ] 首字节 `memchr` 快速跳过 + 长 needle 加 Boyer-Moore-Horspool
- [ ] 折叠结果按 `GapBuffer.generation` 缓存，连续 F3 不重复折叠
- [ ] `find_and_replace_all` 去掉循环内 `read_all()`：一次扫描收集全部命中区间，再按累计偏移 delta 逐个替换

P2 — 可选增强
- [ ] Shift+F3 反向查找（Rust 无，V 侧自加）
- [ ] 命中计数显示（如 `3/17`）
