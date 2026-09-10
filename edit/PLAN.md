# edit V 版兼容性路线与详细设计

## 当前执行决策（2026-09-11）

阶段 B（常驻搜索/替换面板）已完成，实现在 `search_panel.v`，回归覆盖在 `search_panel_test.v`，
`./build.sh test` 为 21/21 通过。P0 至此全部完成。

2026-09-10 审查修复已完成：replacement 编辑不再推进搜索命中；面板非文本焦点和空白区域不会
穿透到正文；搜索/替换的正文视口、光标滚动、鼠标点击和拖拽统一使用实际面板高度；输入框恢复
Shift+方向键/Ctrl+A 选择替换语义；Search 模式 Close 控件可见可操作；窄终端保留状态栏并降级
为单行面板。新增回归测试覆盖这些事件路由和布局边界，PTY 冒烟验证 Ctrl+F/输入/Esc/Ctrl+Q。

面板落地的取舍：

1. 只改交互层，不动搜索后端：仍复用 `TextBuffer` 的增量查找、F3/Shift+F3、选项、命中统计、
   零宽命中推进和一次 undo group 的 Replace All。
2. 旧的双 prompt 分支（`run_prompt_search`、`toggle_search_option`、
   `handle_search_prompt_mouse`、`draw_search_prompt_options` 及 `PromptKind.search/.replace/
   .replace_with`）已删除，`PromptKind` 只剩 `.goto_line`，避免两套搜索状态并存。
3. 未提前实现全局 FocusManager：面板使用局部 `SearchPanelFocus` 枚举和显式路由；等文件/语言/
   编码 picker 也需要 Tab 导航时再抽取通用焦点树（见 P2）。

阶段 C（无 ICU 的正则/替换 fallback）已完成：`regex.v` 提供递归下降解析器、字节码 VM、
分组/量词/交替/字符类/捕获组和替换模板；搜索面板对非法正则给出可见错误并保留上一条有效
搜索。词边界已改为按 UTF-8 code point 的文档化 Unicode 范围近似，emoji 不再被当作词字符；
回归覆盖 forward/reverse/wrap/zero-width/Replace All 以及希腊、西里尔、组合字符和 CJK。
不支持 ICU 的 look-around、backreference 和完整 Unicode property，均在代码注释中明确说明。

下一项主线：P1 编码 picker/转换；其后再推进 P2 的统一焦点树。

## 1. 目标和边界

目标是让 V 版在 macOS/Linux、UTF-8 优先的首版范围内，覆盖 Rust 版 `edit` 的主要用户流程，并让有意保留的降级行为可预测、可测试。

当前边界：

- 只支持 macOS/Linux。
- 编辑缓冲区以 UTF-8 为主；非 UTF-8 转码需要独立后端，不在核心 gap buffer 中实现。
- lsh 使用离线生成的字节码表，编辑器运行时不编译 lsh 源码。
- 不复制 Rust 的完整通用 TUI 框架，只实现编辑器所需的布局、模态和焦点子集。

## 2. 现状和主要缺口

当前入口在 `main.v`，文档状态直接保存在 `Editor` 中，`TextBuffer` 负责内容、光标、选择、历史和搜索，`Framebuffer` 负责终端输出。这个结构适合继续增量移植，但需要把 CLI、配置、搜索面板和状态栏交互从主循环中进一步抽象出来。

优先级判断（按当前剩余工作）：

| 优先级 | 范围 | 原因 |
|---|---|---|
| P0 | 常驻搜索/替换面板 | 当前唯一尚未完成的核心日常工作流 |
| P1 | 正则/替换捕获组、Unicode 语义、编码 picker | 影响与 Rust 版的内容处理兼容性，存在数据安全风险 |
| P2 | 通用焦点树、显示细节、错误日志容量、性能 | 主要改善可访问性、可维护性和长文档体验 |

阶段 A（CLI、路径、Go to Line、settings、保存错误）视为已完成；后续提交不得重复扩展阶段 A，除非回归测试发现问题。

## 3. 总体架构调整

### 3.1 Editor 状态分层

保留 `Editor` 作为生命周期和事件路由对象，但将状态分成四组：

```text
Editor
├── SessionState       文档列表、active、quit、终端尺寸
├── ViewState          scroll、preferred_column、focus、菜单和模态
├── SearchState        needle、replacement、options、结果和面板焦点
└── SettingsState      settings 路径、解析结果、加载错误
```

第一阶段可以继续使用现有字段，先通过独立方法隔离读写；只有当焦点树或编码 picker 开始实现时，再将结构体拆成独立类型。

### 3.2 事件优先级

所有输入继续经过 `handle_event`，但固定以下优先级，避免模态互相抢事件：

1. resize
2. 大剪贴板警告
3. 错误日志
4. dirty close/quit
5. About
6. 编码/语言/文件 picker
7. 搜索面板
8. 菜单栏
9. 编辑区

每个模态必须实现同一组接口语义：`open`、`draw`、`handle_key`、`handle_text`、`handle_mouse`、`close`。关闭时清除焦点和临时输入，但不得意外修改文档内容。

## 4. CLI 和路径设计

### 4.1 参数解析

新增 `cli.v`，提供：

```text
parse_cli_args([]string, string) !CliOptions
cli_help_text() string
cli_version_text() string
parse_filename_goto(string) (string, GotoPoint, bool)
```

当前 `CliOptions` 包含 `action`、`paths []CliPath` 和 `stdin_input`；每个 `CliPath` 携带规范化路径、可选 `GotoPoint` 和 `has_goto`。解析规则与 Rust 版一致：

- `--` 后所有参数都视为路径。
- `-` 清空普通路径并设置 stdin 模式。
- `-g/--goto` 消耗下一个参数，格式为 `FILE:LINE[:CHARACTER]`。
- `-h/--help`、`-v/--version` 在 raw mode 之前直接输出并退出。
- 未知选项作为错误处理，不隐式当作文件名。

### 4.2 路径规范化

在 `add_document` 之前执行：

1. 相对路径以当前工作目录解析。
2. 清理 `.`、`..` 和重复分隔符。
3. 已存在文件使用 `file_id` 去重。
4. 不存在文件保留规范化后的目标路径，创建空 buffer 并标记为“新文件”。
5. 目录参数不创建文档，设置 picker 初始目录。

当前实现用 `has_file_id` 区分已存在文件，缺失文件使用规范化路径去重；是否增加独立的 `exists_on_disk` 字段延后到编码/保存模型重构时决定，阶段 A 不再扩大文档身份结构。

### 4.3 Go to 坐标

统一使用 1-based 输入坐标、0-based 内部坐标：

```text
GotoPoint { line: i32, column: i32 }
```

交互 Ctrl+G 接受 `LINE` 或 `LINE:COLUMN`。CLI `-g` 允许 Rust 版的负行号语义；列号必须非负。定位时：

- 行号小于 1（CLI 负数除外）报错。
- 超出文档末尾钳制到最后一行。
- 列号超出行尾钳制到行尾。
- 成功后调用 `make_cursor_visible`。

## 5. settings.json 设计

### 5.1 加载时机

启动顺序调整为：

```text
parse_cli
→ sys_init
→ load_settings
→ open initial documents
→ switch raw mode
```

配置文件不存在是正常情况；读取失败、JSON 非对象、`files.associations` 类型错误或未知语言 ID 写入错误日志，但不阻止编辑器启动。

### 5.2 数据模型

```text
Settings {
    path: string
    file_associations: []FileAssociation
}

FileAssociation {
    pattern: string
    language: int
}
```

没有 `/` 的模式自动变为 `**/<pattern>`，与 Rust 版一致。匹配顺序为：用户配置、内置表；每组内部保持 JSON/静态表顺序。

### 5.3 Preferences 工作流

- 菜单 File > Preferences 打开实际 settings 路径。
- 文件不存在时创建父目录和 `{\n}\n`。
- 保存后只影响后续打开的文档；当前文档不强制重载语言，避免覆盖用户显式选择。
- 下次启动重新解析并应用关联。

## 6. 搜索和替换设计

### 6.1 常驻面板状态

新增（建议放在 `search_panel.v`，不要继续扩大 `main.v`）：

```text
SearchPanelState {
    visible: bool
    kind: Search | Replace
    focus: Needle | Replacement | MatchCase | WholeWord | Regex | ReplaceAll | Close
    needle: string
    replacement: string
    options: SearchOptions
    success: bool
}
```

V 版第一阶段可用扁平字段实现，但字段语义必须与上面的状态一致：

```text
search_panel_open bool
search_panel_kind SearchPanelKind      // search / replace
search_panel_focus SearchPanelFocus    // needle / replacement / options / actions
search_panel_needle string
search_panel_replacement string
search_panel_error string
```

`last_search`、`last_replacement` 和现有 `SearchOptions` 继续保留在 `Editor`，作为跨面板记忆；面板关闭不清空它们。`search_panel_needle` 和 `search_panel_replacement` 是当前编辑态，只有确认或关闭时才同步到记忆字段。

打开面板时：

- 有选区：needle 预填选区文本。
- 无选区：needle 使用上次搜索词。
- Ctrl+R 且有选区：焦点直接落在 replacement。

### 6.2 操作语义

| 输入 | 行为 |
|---|---|
| 文字变化 | 增量 Search，更新成功状态和命中计数 |
| Enter（needle） | Search，不关闭面板 |
| Enter（replacement） | Replace 当前命中，不关闭面板 |
| Ctrl+Alt+Enter | Replace All，不关闭面板 |
| F3 / Shift+F3 | 下一个 / 上一个命中 |
| Esc / Close | 关闭面板，保留 last_search/last_replacement |
| 空 needle | 清除选择并回到选择起点，不执行替换 |

### 6.2.1 面板布局和焦点

终端高度足够时，面板固定在文本区上方，占 3 行：

```text
Search: <needle>       [Case] [Word] [Regex]       3/17
Replace: <replacement> [Replace] [Replace All] [Close]
```

窄终端按可用宽度裁剪标签和计数，但不得覆盖输入内容；终端高度不足 5 行时复用现有底部 prompt 回退布局。

局部焦点顺序固定为：

```text
needle -> replacement(if replace mode) -> match_case -> whole_word
-> regex -> replace -> replace_all -> close
```

`Tab`/`Shift+Tab` 在面板内部循环，`Esc` 关闭面板，面板打开时背景编辑区不接收普通编辑键。`F3`/`Shift+F3` 在任何面板焦点下继续执行前进/后退查找。

### 6.2.2 事件和状态转换

1. `Ctrl+F` 打开 Search 面板；选区存在时填充 needle，否则填充 `last_search`。
2. `Ctrl+R` 打开 Replace 面板；needle 使用选区或 `last_search`，焦点优先落在 replacement。
3. needle 文字变化触发增量查找；replacement 变化只更新编辑态，不重新查找。
4. Enter 根据焦点执行 Search、Replace 当前命中或 Replace All，执行后保持面板打开。
5. 搜索/替换失败只更新 `search_panel_error`，不破坏上一次有效命中和记忆值。
6. Esc/Close 关闭面板并恢复编辑区焦点；不撤销已完成的替换。

### 6.3 搜索后端接口

定义统一接口，避免 UI 依赖具体实现：

```text
SearchEngine.compile(pattern, options) !CompiledSearch
CompiledSearch.next(text, offset, wrap) ?Match
CompiledSearch.prev(text, offset, wrap) ?Match
CompiledSearch.captures() []Range
```

后端分两层：

1. `LiteralSearch`：当前 BMH + generation 缓存路径。
2. `RegexSearch`：未来 ICU 路径；没有 ICU 时使用当前最小正则并明确能力降级。

替换全部命中时先收集不可变的 byte ranges，再从后往前写入，保持一次 undo group；零宽命中必须调用 `find_advance_past_zero_width`，防止原地循环。

### 6.4 正则兼容策略

以 ICU 为目标语义：多行锚点、Unicode case-insensitive、Unicode `\\b/\\w`、分组、量词、交替、字符类和替换捕获组。当前首版不引入 ICU，已实现自包含 fallback：支持多行锚点、分组/量词/交替/字符类、捕获替换和非法模式错误展示；`\\b/\\w` 使用文档化的 code point 范围近似，look-around、backreference 和完整 property escape 明确报错。UI 不宣称 ICU 完整兼容。

### 6.5 阶段 B 的实现边界

阶段 B 只改造交互层，不扩大搜索语义：

- 保留当前 literal/最小正则实现，不在本阶段引入 ICU 或新的正则语法。
- 把现有 `start_prompt`、`confirm_prompt`、`replace_active` 和 `find_and_replace_all` 的调用收拢到面板动作函数。
- 统一面板关闭、窗口 resize、鼠标点击和文本粘贴路径，禁止某个入口遗留旧 prompt 状态。
- Replace All 必须复用现有一次 undo group 和零宽推进逻辑。
- 面板完成后删除或停用旧的双 prompt 专用分支，避免两套搜索状态同时存在。

阶段 B 完成标准：用户可以在不关闭面板的情况下连续执行搜索、下一命中、替换当前命中和全部替换；Esc 后回到编辑区，且原有搜索回归测试全部保持通过。

阶段 B 实测结果（已完成）：`search_panel.v` 提供状态、布局、绘制、键盘/鼠标路由和四个动作函数
（`run_panel_search` / `panel_action_replace` / `panel_action_replace_all` / `panel_action_activate`）。
终端高度 ≥ 5 时面板位于菜单栏与文本区之间（needle 行、选项+命中计数行、replacement+动作按钮行），
更矮时回落到状态栏上方。pty smoke 已验证 Ctrl+F 增量搜索 1/3→2/3→3/3、Esc 关闭回到编辑区，以及
Ctrl+R + Tab 导航到 [Replace All] 后一次替换三处，退出码均为 0。

## 7. 编码设计

### 7.1 状态栏和 picker

状态栏顺序与 Rust 版一致：Language、Newline、Encoding、Indentation、Location。Encoding 点击后打开浮动 picker：

- 空过滤显示 preferred encodings。
- 输入文字按 label/canonical name fuzzy 过滤。
- Reopen：对有路径文档重新从磁盘读取。
- Convert：保持当前文本，改变写出编码。
- Untitled 文档只能 Convert，不能 Reopen。

### 7.2 编码转换边界

编码转换不得放进 gap buffer；新增 `encoding.v`，提供：

```text
decode_file(bytes, encoding) !string
encode_text(text, encoding) ![]u8
```

核心缓冲区只存合法 UTF-8。读取时记录 `encoding`；UTF-8 用 `UTF-8` / `UTF-8 BOM` 区分是否写 BOM，
UTF-16/32 和 GB18030 写出时固定带 BOM，保证后续自动检测。任何解码错误必须可见地失败，不能把原始
UTF-16/GB18030 字节当 UTF-8 展示后再覆盖保存。

编码子阶段实测结果（已完成）：`encoding.v` 通过 `encoding.iconv` 提供严格解码和编码，支持 UTF-8、
UTF-8 BOM、UTF-16LE/BE、UTF-32LE/BE 和 GB18030；转换完成后才打开目标文件，编码失败不会截断原文件。
状态栏 Encoding 入口提供 Reopen/Convert 两阶段选择和 fuzzy 过滤；Untitled 只允许 Convert，Convert 会标记
dirty，Reopen 会先保存 dirty 文档，失败时保留内存文档并写入包含路径与编码的错误日志。单元测试覆盖 BOM、
round-trip、非法输入、过滤、dirty 和失败路径，PTY smoke 覆盖状态栏入口、Convert picker 与干净退出。

## 8. Focus tree 设计

### 8.1 最小模型

不移植完整 `tui.rs`，只实现：

```text
FocusNode { id, parent, children, focusable, focus_well }
FocusManager { active_path, next_tab(), prev_tab(), steal(), pop() }
```

每帧绘制 UI 时注册焦点节点；输入处理前根据 active path 路由。Tab/Shift+Tab 只在当前 focus well 内循环，模态打开时禁止逃逸到背景。

### 8.2 首批接入控件

按顺序接入搜索面板、文件 picker、语言/编码 picker、dirty modal、状态栏。菜单栏保留现有专用导航，待焦点管理器稳定后再接入。

View > Focus Statusbar 设置一次性 `focus_request = statusbar`，下一帧由 FocusManager 将焦点移到状态栏第一个按钮。

## 9. 错误、dirty 和文档身份

- 错误日志容量固定为 10，与 Rust 版一致。
- 错误消息必须包含操作（open/save/parse/encoding）和目标路径。
- 保存成功后才更新 `path`、`file_id`、dirty 状态。
- 关闭/退出 dirty modal 的 Save 失败时保持 modal 和文档，不得继续关闭。
- 文档身份优先使用 file id；不存在文件使用规范化路径；untitled 使用唯一显示名。

## 10. 测试计划

### 单元测试

- `cli_test.v`：所有参数组合、goto 解析、错误退出。
- `settings_test.v`：缺失文件、有效关联、非法 JSON、未知语言、优先级。
- `encoding_test.v`：BOM、UTF-16/GB18030 round-trip、解码错误。
- `text_buffer_test.v`：正则分组/量词/替换模板、Unicode case/word boundary、零宽和 Replace All。
- `focus_test.v`：Tab 循环、模态 focus well、状态栏 focus request。
- `search_panel_test.v`：打开时选区/历史预填、焦点循环、Enter 不关闭、Esc 关闭、空 needle、错误保留和 resize 回退。

### 端到端 smoke

使用 `tools/smoke.py` 覆盖：

1. `--help`/`--version` 不切 raw mode。
2. `-g` 启动定位和 Ctrl+G 交互定位。
3. 目录启动进入 picker，缺失文件可编辑并 Save As。
4. 常驻搜索面板中搜索、替换、Replace All、Esc 关闭。
5. 保存到嵌套目录、覆盖确认和保存失败。
6. settings 关联改变高亮语言。
7. dirty quit 的 Save/Discard/Cancel 三条路径。

### 资源限制

所有 V 编译、测试、fmt、vet 命令必须经过 `cpulimit -l 200 -z --`，例如：

```bash
cpulimit -l 200 -z -- ./build.sh test
cpulimit -l 200 -z -- ./build.sh vet
```

## 11. 分阶段实施顺序

### 阶段 A：P0 基础兼容（已完成）

1. `cli.v` 和路径规范化。
2. 新文档/目录参数/父目录创建。
3. Ctrl+G `line:column`。
4. settings 加载和自定义 glob。

阶段 A 完成后，CLI、打开、保存和配置相关 smoke 全部通过。

### 阶段 B：常驻搜索/替换面板（已完成）

1. **状态隔离**：新增 `SearchPanelKind`、`SearchPanelFocus` 和面板字段；实现 `open_search_panel`、`open_replace_panel`、`close_search_panel`。
2. **绘制替换**：新增 `draw_search_panel`，复用现有测量和 framebuffer API；实现 3 行布局、窄终端裁剪和高度不足回退。
3. **键盘/文本路由**：在 `handle_event` 中将面板置于菜单和编辑区之前；实现 Tab、Shift+Tab、Enter、Esc、F3/Shift+F3、Backspace、粘贴和 resize。
4. **动作适配**：把增量 Search、Replace 当前命中、Replace All、选项切换和命中计数接入面板；保持一次 undo group 和零宽推进。
5. **回归与清理**：补充 `search_panel_test.v` 和 smoke 场景，删除旧双 prompt 的不可达分支，更新 TODO 与本计划的完成状态。

阶段 B 的提交顺序必须保持可编译：先状态和测试夹具，再绘制，再事件路由，最后删除旧 prompt。每一步都使用受 CPU 限制的测试命令验证。

### 阶段 C：搜索语义（已完成）

1. 选择 ICU 或扩展 fallback 后端。
2. 完整正则和替换模板。
3. Unicode case/word boundary。
4. **转入 P2**：大文件基准和内存审查，不阻塞搜索语义阶段验收。

### 阶段 D：编码和焦点完善（当前执行）

1. **已完成**：`encoding.v` 解码/编码后端。
2. **已完成**：状态栏编码 picker、Reopen/Convert。
3. **下一项**：FocusManager 接入全部 modal/statusbar。
4. 显示细节、版本来源和错误日志容量收尾。

每个阶段结束时更新 `TODO.md` 的复选框和本文档的实际差异；如果某项被确认继续留在首版范围外，应移动到“明确不纳入当前首版”，而不是留下模糊的进行中状态。
