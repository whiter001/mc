# TODO

本文档只记录相对 `/Volumes/Extreme/github2/edit` 的剩余工作。已完成的核心编辑功能不再重复列为待办；详细设计和接口约束见 [PLAN.md](PLAN.md)。

## 当前基线

- [x] 多文档编辑：New/Open/Save/Save As/Close/Exit，文档去重，`Ctrl+PgUp/PgDn` 切换
- [x] Gap buffer、UTF-8 光标移动、选择、复制/剪切/粘贴、撤销/重做、覆盖模式
- [x] LF/CRLF、缩进类型和宽度、自动换行、行号、标尺、鼠标点击/滚轮/拖拽
- [x] 文件选择器：目录导航、打开、另存、覆盖确认、自动补全
- [x] Go to File、Go to Line、语言选择器、菜单栏、About、脏文档关闭/退出确认
- [x] OSC 52 剪贴板同步和大剪贴板确认、重定向 stdin、终端标题、错误日志
- [x] lsh 运行时和离线高亮表、按 glob 自动检测语言
- [x] 搜索的增量查找、F3/Shift+F3、大小写/整词/最小正则选项、命中计数、Replace All

## P0：用户可见的兼容性缺口

### CLI 参数和路径语义

- [x] 实现 `-v/--version`，版本号从单一构建元数据注入，About 与 CLI 共用
- [x] 实现 `-g/--goto FILE:LINE[:CHARACTER]`
- [x] 支持 `--` 结束选项解析，以及 `-` 作为 stdin 文件名
- [x] 启动参数为目录时进入 Open picker，并以该目录作为初始目录
- [x] 路径统一规范化为绝对路径；相对路径、符号链接和重复打开使用同一比较规则
- [x] 打开不存在的文件时创建"带目标路径的新文档"，而不是启动失败
- [x] CLI 参数错误输出到 stderr，返回非零退出码；`--help`/`--version` 不进入 raw mode

验收：覆盖 `edit --help`、`edit --version`、`edit -g file:3:4`、`edit -- -name`、目录参数、缺失文件和 stdin 管道。

### Go to Line 交互

- [x] Ctrl+G 接受 `line` 和 `line:column`
- [x] 校验非法输入并保留 prompt，合法输入后按 1-based 坐标定位
- [x] 明确列号超出行尾时钳制到行尾；不支持的负数输入给出可见错误

### 搜索/替换面板

- [x] 将临时双 prompt 改为常驻搜索面板：needle、replacement、选项、Replace All、Close
- [x] 面板打开期间 Enter 只执行操作，不关闭面板；Esc/Close 才关闭
- [x] 使用统一焦点状态保存 needle/replacement/当前控件，支持 Tab/Shift+Tab
- [x] 保留现有增量查找、选区预填、F3/Shift+F3、命中计数和零宽命中推进逻辑

### settings.json

- [x] 启动时加载平台对应的 `settings.json`
- [x] 解析 `files.associations`，支持与 Rust 版相同的 glob 规范化
- [x] 自定义关联优先于内置关联；语言 ID 无效或 JSON 根类型错误时进入错误日志
- [x] 打开 Preferences 后保存的设置在下一次启动生效
- [x] 不因配置文件不存在而报错；创建 Preferences 时保留 `{\n}\n` bootstrap

### 保存和文件错误

- [x] Save/Save As 自动创建缺失的父目录，与 Rust `open_for_writing` 一致
- [x] 写入失败时不改变文档路径、file id 或 dirty 状态
- [x] 覆盖确认、保存失败和打开失败统一进入错误日志/状态反馈

## P1：搜索语义和编码能力

### 正则语义（无 ICU fallback）

- [x] 为 `SearchOptions.use_regex` 定义 literal/regex 后端接口；无 ICU 时使用自包含 fallback
- [x] 支持 fallback 的分组、量词、交替、字符类和捕获组（look-around/backreference 仍明确不支持）
- [x] 支持替换模板 `$1`、`$$`、`\\n`、`\\r`、`\\t`
- [x] 非法正则显示错误且不破坏上一次有效搜索状态
- [x] 用回归测试覆盖 forward、reverse、wrap、zero-width 和 Replace All

### Unicode 大小写和整词（无 ICU）

- [x] 在没有 ICU 时采用并注明 ASCII、Latin-1、希腊和西里尔的 Case Folding 覆盖范围
- [x] 整词边界按 UTF-8 code point 和文档化 Unicode 范围近似，不再把所有非 ASCII 字节视为词字符
- [x] 增加希腊、西里尔、组合字符、emoji 和 CJK 的回归测试

### 编码 picker / 转换

- [ ] 状态栏显示当前编码并可打开编码 picker
- [ ] 支持 fuzzy 过滤、Reopen 和 Convert 两种动作
- [ ] 设计 UTF-8、UTF-8 BOM、UTF-16LE/BE、UTF-32LE/BE、GB18030 等编码的读写策略
- [ ] Reopen 前处理 dirty 文档；Convert 改变编码并标记 dirty
- [ ] 将编码错误映射到错误日志，禁止产生静默数据损坏

## P2：交互和维护性增强

- [ ] 引入统一 focus tree：菜单、搜索、picker、状态栏、模态框均支持 Tab/Shift+Tab
- [ ] 补回 View > Focus Statusbar，并支持键盘操作状态栏按钮
- [x] 错误日志容量与 Rust 对齐为 10 条
- [ ] 统一错误模态的按钮和关闭行为
- [ ] 未命名文档使用 `Untitled-N.txt`，状态栏显示 basename，Go to File 显示目录信息
- [ ] 自动检测语言时状态栏显示实际生效语言，显式 override 时显示 override
- [ ] About 和 `--version` 显示同一个构建版本，不保留硬编码 `0.1`
- [ ] 保存、搜索和高亮路径增加大文件基准；评估分块搜索是否值得实现

## 明确不纳入当前首版

- 范围外：完整 ICU/i18n 支持（除非项目范围改为“兼容 Rust 全功能”）
- 范围外：Windows 平台支持
- 范围外：SIMD 加速和 Rust 的虚拟地址预留策略
- 范围外：lsh 编译器；当前继续使用离线生成的 `lsh_tables.v`
- 范围外：Rust TUI 的全部通用布局 API；只实现编辑器实际需要的 focus/layout 子集

## 完成定义

每个 P0/P1 项必须同时具备：

1. 对应实现和简短注释。
2. 至少一个单元测试；涉及终端交互时增加 `tools/smoke.py` 场景。
3. 与 Rust 参考行为的差异说明被删除或更新。
4. 通过受 CPU 限制的 `./build.sh test` 和必要的 smoke 测试。
