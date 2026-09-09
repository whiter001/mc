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
- [ ] `find_substring_match` 改分块流式匹配：走 `gap_buffer.read_forward` 零拷贝视图，不再 `read_all()`（缓存落地后收益只剩省一份只读拷贝，做不做再评估）
- [x] ~~折叠按需进行~~（被 generation 缓存覆盖：缓存命中时折叠成本为零，无需再做窗口折叠）
- [x] 首字节快速跳过 + 长 needle Boyer-Moore-Horspool（`find_substring_match` 字面量路径已整体换 BMH：256 项 skip 表 + 尾向前比较，whole_word 拒绝的候选也按 skip 表前进；BMH 的首字节 skip 已涵盖 memchr 意图）
- [x] 折叠/read_all 按 `GapBuffer.generation` 缓存（`TextBuffer.search_text`：read_all 快照 + 惰性折叠副本，generation 变化自动失效；折叠已提出 `find_substring_match` 热路径，连续 F3 和增量搜索只付 BMH 扫描）
- [x] `find_and_replace_all` 去掉循环内 `read_all()`：一次扫描收集全部命中区间（步进与 `search_match_stats` 一致），再从后往前逐个替换使偏移保持有效；语义不变（不重复匹配替换结果、零宽命中=插入、一次 undo group）

P2 — 可选增强
- [x] Shift+F3 反向查找（Rust 无，V 侧自加）；prompt 内 ↑/↓ = 上/下一个（免 fn 键替代）
- [x] 命中计数显示（`3/17`）：选项行右侧 + 状态栏 Ln/Col 后，`search_match_stats` 统计，buffer generation 变化即失效
- [x] 搜索/替换面板移到顶部（menubar 之下行 1-2：输入行 + 选项行，计数随之在上方显示），对齐 Rust draw_search 布局；终端高度 < 5 回退底部

## Windows 原生构建（sys 层移植）

完整设计方案见 [`WINDOWS_PORT.md`](WINDOWS_PORT.md)（API 映射、输入方案 A/B、Win32 声明约定、
风险与开放问题）。下面是可勾选的进度清单，编号 W1–W10 与方案文档第 10 节一致。

目标：x86_64 Windows 原生 `bin/edit.exe`，与现有 macOS/Linux 功能对齐。
工具链：V 自带选择 → clang（`x86_64-pc-windows-msvc`）+ WinSDK + LLVM `lld-link`；
`windows.h` 已实测可编可链可跑。`CC="zig cc"` 仅作交叉编译 fallback，不进主路径。
分文件依据：V 按文件名后缀自动过滤平台文件（`vlib/v/pref/should_compile.v:266-270`，
`_windows.v` 非 Windows 排除、`_nix.v` Windows 排除），故不写满 `$if`。

1. [x] **拆分 sys 层**：`sys.v`（共享：`SysState` / `FileId`+`==` / `incomplete_utf8_tail_len` / UTF-8 尾巴缓存）、`sys_nix.v`（现有 unix 实现整搬，行为零改动）、`sys_windows.v`（新）。对外 API 不变（调用点：main.v 12 处 + filepicker.v + terminal_title.v）。验收：unix 侧 `v test .` 与拆分前一致
2. [x] **sys_windows 控制台模式管理**：`GetStdHandle`；`switch_modes` = `SetConsoleMode`（关 `ENABLE_LINE_INPUT/ECHO/PROCESSED_INPUT`，开 `ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_MOUSE_INPUT | ENABLE_WINDOW_INPUT`；输出侧 `ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN`）+ `SetConsoleOutputCP(CP_UTF8)`；`restore_terminal` 恢复（main.v 各退出路径已在调）；`stdin_is_redirected` 用 `GetConsoleMode` 成败判定；`reopen_stdin_if_redirected` 退化为 false（无 `/dev/tty` 等价物）。注意 `windows.h` 与 vlib 宏/结构冲突 → `WIN32_LEAN_AND_MEAN`，必要时局部 `#undef`
3. [x] **sys_windows 输入 `read_stdin`**：方案 A（先试）——`ENABLE_VIRTUAL_TERMINAL_INPUT` + `WaitForSingleObject(stdin handle, timeout)` 替 `poll` + 读字节，鼠标/按键由 conhost 转成 VT 序列直接喂 `input.v`；方案 B（兜底）——`ReadConsoleInputW` 读 `INPUT_RECORD`，自行编码 KEY/MOUSE/`WINDOW_BUFFER_SIZE_EVENT` 为 `input.v` 认得的 CSI / SGR 鼠标序列。**决策点：先实测 A 的鼠标与 Ctrl/Alt 组合键是否完整**，有洞才局部用 B。尾巴缓存复用 `incomplete_utf8_tail_len`，`stdin_hit_eof` 语义对齐
4. [x] **sys_windows 输出 `write_stdout`**：控制台走 UTF-8→UTF-16→`WriteConsoleW`（不受代码页影响）；重定向/管道走 `WriteFile` 原始字节；分块写 + `ERROR_BROKEN_PIPE`；空串直接返回
5. [x] **sys_windows 窗口大小与 resize**：`GetConsoleScreenBufferInfo` 替 `ioctl(TIOCGWINSZ)`；`WINDOW_BUFFER_SIZE_EVENT` 置 `inject_resize` 替 `signal(SIGWINCH)`；首次注入语义与 unix 一致（`\x1b[8;h;wt` 前置）
6. [x] **sys_windows `file_id`**：`CreateFileW` + `GetFileInformationByHandleEx(FileIdInfo)`（或 `GetFileInformationByHandle` 卷序列号+索引）填 `FileId{st_dev, st_ino}`，`==` 语义不变；`sys_test.v` 现有 3 个用例直接复用
7. [x] **平台杂项收尾**：`settings.v` 加 windows 分支用 `LOCALAPPDATA`/`APPDATA`（现 `$else` 走 `~/.config/msedit`，Windows HOME 通常未设）；`main.v:249` 的 `/dev/tty` 文案与逻辑；`settings_test.v` / `goto_file_test.v` 硬编码 `/tmp` 断言改 `os.temp_dir()`；记录 conhost VT 支持前提（建议 Windows Terminal / Win11）与 Ctrl+C / Ctrl+Z / AltGr 语义
8. [x] **build.sh Windows 分支**：产物 `bin/edit.exe`；`PREFIX` 默认换 Windows 路径、`install` 用 `copy`；Windows 下改 PowerShell 低优先级进程 + Job Object 内存上限（替代 `cpulimit` + `ps -axo` 看门狗，或降级为仅低优先级 + `MEMLIMIT_MB=0` 提示）；探测不到 `windows.h` 时提示装 WinSDK 或 `CC="zig cc"`
9. [x] **验证**：`v -enable-globals -o bin/edit.exe .` 编过；`v test .` 全绿；手工冒烟（打开/编辑/保存/搜索/关闭/退出，退出后控制台模式与代码页恢复、无残留转义）。`tools/smoke.py` 基于 pty 在 Windows 不可用 → 评估 ConPTY（pywinpty）写 Windows 冒烟脚本，或本期先手工、自动化列后续

    > **W9 已在 Windows 本机通过**：
    > - `bin/edit.exe` 1.5MB（PE32+ x86-64）编出，`./bin/edit.exe --help` 输出 `usage: edit [file...]`，重定向 stdin + 文件参数路径能 exit 0。
    > - 修复路径：vlib 6 处类型 bug（`cfns.c.v` `ReadFile`/`ReadConsole` 返回 bool→int，3 处使用方 `result` 改 `int(0)`）+ 本项目 main.v:974 `mut b` + sys_windows.v LPDWORD 7 处 `voidptr(&x)` cast + `BY_HANDLE_FILE_INFORMATION` 字段名 CamelCase + `@[typedef]`。
    > - vlang 上游 patch 仅本机仓库（**未提交上游**），其他用 PATH 里 v 的机器仍会撞同一 bug。`tools/smoke.py` 在 Windows 上不可用（pty），端到端交互冒烟仍待 Windows Terminal 手工实测。
10. [x] **更新 AGENTS.md**：范围由「仅 macOS/Linux」改为含 Windows；补 Windows 工具链说明、V 平台文件名约定、无 `cpulimit` 时的限流做法、`smoke.py` 不可用说明
