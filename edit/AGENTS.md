# edit (V) agent 指南

本项目是 microsoft/edit（Rust，/Volumes/Extreme/github2/edit，只读参考）的 V 语言重写。
第一版范围：核心编辑器，仅 macOS/Linux，UTF-8 only，无 ICU / i18n / SIMD。

## 资源限制（必须遵守）

当前 V 工具链可能不稳定，编译或测试进程有时会失控占满 CPU，拖垮整个系统。
**凡是跑 V 编译 / 测试 / 静态检查的命令，一律用 `cpulimit` 包一层限制 CPU 占用**：

```bash
cpulimit -l 200 -z -- ./build.sh        # dev build，限制在约 2 核
cpulimit -l 200 -z -- ./build.sh test   # 跑测试
cpulimit -l 200 -z -- ./build.sh prod   # prod build
cpulimit -l 200 -z -- v fmt -w .        # fmt / vet 等直接调 v 的命令同理
```

- `-l N`：允许的 CPU 百分比，按核数计（0–800，即 100 = 1 核）。默认用 200。
- `-z`：目标进程退出后 cpulimit 自动退出，不会残留。
- cpulimit 不在 PATH 里时先问用户，不要自己安装。
- 限制的只是构建/测试进程；对最终产出的二进制正常运行不加限制。
- 内存限制已内置于 `build.sh`：编译和测试命令自带内存看门狗，进程树 RSS 超限会被整树杀掉。
  build 用 `MEMLIMIT_MB`（默认 2048MB），`v test` 单独用 `TEST_MEMLIMIT_MB`（默认 4096MB）；
  `MEMLIMIT_MB=0` 整体关闭。
- 直接调用 `v` 的命令（如 `v fmt -w .`）没有经过 build.sh，没有内存限制，至少仍要包 `cpulimit`。

## 构建

全部走 `./build.sh`（dev/debug/prod/test/fmt/vet/clean/install/uninstall），产物在 `bin/edit`。

端到端冒烟用 `tools/smoke.py`（pty 驱动）：`python3 tools/smoke.py <文件1:文件2...> <hex按键>`，
按键 hex 用 `--` 分段；每段发送后等输出静默 0.3s 再发下一段（给 100ms 的 ESC 超时
冲刷留时间，固定 sleep 的旧写法会踩这个时序）。干净退出标志：输出尾部有
`\x1b[?1049l` 且最后一行 `=== editor exit code: 0`。注意菜单栏占行 0，
文本区的 SGR 鼠标行号从 2（1 基）开始。

## 代码约定

- 扁平 `.v` 文件，统一 `module main`，测试为 `*_test.v`。
- gap buffer 等裸内存操作集中在 unsafe 块内，用 `C.malloc/C.realloc/C.free`，绕开 GC 扫描。
- 参考源码只读：不得修改 /Volumes/Extreme/github2/edit。

## 移植状态（2026-08）

已实现：`main.v`（主循环：多文档 Ctrl+N/O/W/P/Ctrl+PgUp/PgDn、状态栏模态输入行
搜索 Ctrl+F+F3/替换 Ctrl+R（两段输入：先 needle 后 replacement，语义对齐
Rust 的首次只选中、再次才替换；needle 和 replacement 都跨调用记忆，重复
Ctrl+R+Enter+Enter 即重复上次替换）/跳转 Ctrl+G、鼠标点击定位+滚轮+左键拖拽
选择、脏文件关闭/退出二次确认、底部状态栏）、`menubar.v`（菜单栏
File/Edit/View/Help + 下拉 + About 对话框：F10 聚焦、方向键导航、鼠标点击，
是 tui.rs 菜单的务实简化版而非布局引擎移植；行 0 为菜单栏，文本区从行 1
开始；Edit > Replace All 走 replace 双段 prompt + find_and_replace_all，
对齐 Rust SearchAction::ReplaceAll 无确认框）、`filepicker.v`（打开/另存
文件选择器：居中模态、目录列表 ../目录/文件 分组排序、Up/Down 选择、
Enter 进目录或接受、空名 Backspace 或 Alt+Up 上级、鼠标点项直接激活、
另存覆盖 y/n 警告；裁剪了自动补全和 ICU 排序；Ctrl+O/Ctrl+Shift+S/无路径
Ctrl+S 均走 picker，状态行 open/save_as prompt 已删除）、
`text_buffer.v`（TextBuffer 全量移植，查找为纯子串语义）、`gap_buffer.v`、
`measurement.v`、`document.v`、`framebuffer.v`、`oklab.v`、`sys.v`（raw mode、
stdin 读取、SIGWINCH）、`input.v`（VT 输入解析）、`vt.v`、`navigation.v`、
`clipboard.v`、`helpers.v`、`unicode_tables.v`、lsh 语法高亮（
`lsh_runtime.v` VM 移植自 crates/lsh/src/runtime.rs、`highlighter.v` 移植自
highlighter.rs+cache.rs+stdext/glob.rs；`lsh_tables.v` 是离线生成的字节码
表——lsh 编译器本身未移植，表由 `tools/lsh_tables_to_v.py` 从
`lsh-bin compile` 的输出转换而来，重新生成方式见该脚本头部注释；
`text_buffer.v` 的 `language` 是 lsh_languages 下标（-1=无），
打开文件时按 glob 关联自动检测，编辑从受损行起失效缓存）。
未做：TUI 布局引擎（tui.rs 4112 行，含本地化/焦点系统）、lsh 编译器。

## V 工具链 / vlib 坑（踩过的）

- `os.File.read()` 到 EOF 会返回 `os.Eof{}` 错误（空消息 code=0），不是返回 0；
  读文件循环必须 `if err is os.Eof { break }`。
- `import os` 在场时 `u64(C.A | C.B)` 组合表达式会触发编译器报错，要逐项
  `u64(C.A) | u64(C.B)`（见 sys.v）。
- 定长数组字面量要加 `!` 后缀；`string([]u8)` 用 `.bytestr()`；`insert` 只插单元素，
  拼大片段用 `<<`；参数名不能用 `default` 等 C 关键字；mut 参数会级联到调用处。
- `TIOCGWINSZ` 等含 sizeof 的 C 宏无法透传，按平台硬编码 ABI 值（见 sys.v）。
- V 无析构：Rust 的 Drop 守卫（终端恢复）要在每条退出路径显式调 `restore_terminal()`。
- V 的 `int(u32值)` 对 > i32 max 的值会环绕成负数；Rust `u32 as usize` 不会。
  解释器/字节码里当索引用的 u32 要先钳制再转（见 lsh_runtime.v `lsh_reg_as_off`）。
- `asm` 是 V 保留字，不能当变量名；`[]u8.index(x)` 返回 int（-1 表未找到），
  不带 Option；for 区间循环只接受整数类型，`CoordType`（i32 别名）要先 `int()`；
  数值强转枚举要包 `unsafe {}`；接口引用字段在结构体字面量里赋值也要 `unsafe { }`。
