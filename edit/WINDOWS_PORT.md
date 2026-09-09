# Windows 原生构建：sys 层移植设计

本文是把 `edit`（microsoft/edit 的 V 重写）从 macOS/Linux 扩展到 **Windows 原生 exe** 的完整
设计方案。目标是产出 `bin/edit.exe`，功能与现有 unix 版对齐；**不改动 unix 侧行为**。

配套的进度清单在 `TODO.md` 的「Windows 原生构建（sys 层移植）」小节（10 个勾选项，编号与
本文第 10 节 W1–W10 一一对应）。

---

## 1. 现状与阻塞点

### 1.1 实测结论（本机）

| 项 | 结果 |
|---|---|
| V 编译器 | `V 0.5.2 c0e47bf`（`/d/public/v` → `/d/work/github/vlang`），hello world 可编出 exe ✅ |
| C 工具链 | V 先试 bundled tcc（无 Win32 头，失败）→ 回退 `clang.exe`（LLVM，`/c/Program Files/LLVM/bin`） |
| clang target | `x86_64-pc-windows-msvc`，链接用 LLVM 自带 `lld-link`，WinSDK 10 已装 |
| POSIX 头 | `#include <termios.h>` → `builder error: Header file <termios.h> ... not found` ❌ |
| Win32 头 | `#include <windows.h>` 可编、可链、可运行 ✅ |
| `zig` | 0.16.0（`/d/soft/zig`），`CC="zig cc" v ...` 也能编过，作交叉编译 fallback |
| `cpulimit` | 无（Windows 上需替代方案，见 §8.3） |

### 1.2 唯一硬阻塞：sys.v 是纯 POSIX

`sys.v` 全文没有 Windows 分支，用到的全部是 unix API：

| sys.v 中的用法 | 位置 | Windows 无对应 |
|---|---|---|
| `#include <termios.h/unistd.h/fcntl.h/poll.h/sys/ioctl.h/sys/stat.h/signal.h>` | sys.v:17-23 | 头文件不存在 |
| `tcgetattr` / `tcsetattr` raw mode | sys.v:166,204 | — |
| `fcntl(F_GETFL/F_SETFL)` + `O_NONBLOCK` | sys.v:157,428 | — |
| `poll()` 超时等待 | sys.v:328 | — |
| `C.read(fd)` / `C.write(fd)` | sys.v:342,409 | fd 模型不同 |
| `ioctl(TIOCGWINSZ)` | sys.v:243 | — |
| `signal(SIGWINCH)` | sys.v:163 | 无 SIGWINCH |
| `fstat` → `st_dev`/`st_ino`（`FileId`） | sys.v:451 | 无 inode |
| `isatty` + `open("/dev/tty")` | sys.v:109,111 | 无 /dev/tty |
| `__errno_location()` / `__error()` | sys.v:34-36 | 用 `_errno()` |

其余代码（`text_buffer.v` / `framebuffer.v` / `main.v` / `filepicker.v` / `highlighter.v` /
`lsh_*` / `measurement.v` …）都是纯 V + `os` 模块，无平台耦合，理论上原样可编。

---

## 2. 工具链决策

**主路径：clang（`x86_64-pc-windows-msvc`）+ WinSDK + `lld-link`。**

1. 零安装：本机已具备，`windows.h` 实测编链跑全通。
2. 与 V 默认选择一致（tcc → clang 回退），build 脚本不用加 CC 探测/传参。
3. 与 Linux/macOS 用的 clang 同族：行为、报错、调试符号一致；`-enable-globals` 与
   `lsh_tables.v`（218 KB 大静态数组）这类边界情形与现有平台风险等同。
4. 头文件官方且完整：Rust 原版 Windows 后端就是 Win32 console API
   （`ReadConsoleInputW` / `SetConsoleMode` / `GetConsoleScreenBufferInfo` /
   `GetFileInformationByHandleEx`），MSVC 头不会有 mingw 头的声明缺失或签名差异。

**fallback：`CC="zig cc"`**（0.16 已实测可用）。只在需要「在非 Windows 上交叉编译出 exe」时使用；
zig 默认走 `*-windows-gnu`（UCRT/mingw 头），与 MSVC 路径二进制行为有细微差异，且带空格的
`CC` 传参不如 `-cc clang` 稳，故不进主路径。

---

## 3. 架构：按平台拆文件，而不是塞 `$if`

V 编译器按**文件名后缀**自动过滤平台文件（`vlib/v/pref/should_compile.v:266-270`）：

```v
if prefs.os == .windows && (file.ends_with('_nix.c.v') || file.ends_with('_nix.v'))     { return false }
if prefs.os != .windows && (file.ends_with('_windows.c.v') || file.ends_with('_windows.v')) { return false }
```

所以：

| 文件 | 内容 |
|---|---|
| `sys.v` | 共享：`SysState`、`FileId` + `==`、`incomplete_utf8_tail_len`、UTF-8 尾巴缓存逻辑、公共注释 |
| `sys_nix.v` | 现有 unix 实现**整搬**，行为零改动 |
| `sys_windows.v` | 新建，Windows 实现 |
| `sys_test.v` | 保留，两个平台都跑（`file_id` 3 个用例直接复用） |

好处：`sys.v` 不再被 `#include <termios.h>` 污染；不需要在两三处函数内部写 `$if`；
新增平台时再加一个文件即可。

### 3.1 sys 层对外 API 契约（实现 Windows 时必须逐条满足）

| 函数 | 契约 | 调用点 |
|---|---|---|
| `sys_init()` | 初始化全局状态（fd / handle） | main.v:212 |
| `stdin_is_redirected() bool` | stdin 非 tty 时 true | main.v:227 |
| `read_all_stdin() !string` | 重定向时把 stdin 全部读入（UTF-8，lossy） | main.v:229 |
| `reopen_stdin_if_redirected() !bool` | 重开 tty；Windows 无等价物 → 返回 `false`（并改 main.v:249 文案） | main.v:248 |
| `switch_modes() !` | 进入 raw 模式；失败要可报错退出 | main.v:254 |
| `restore_terminal()` | 恢复；**V 无析构，main.v 每条退出路径都要调**（main.v:272） | main.v:272 |
| `inject_window_size_into_stdin()` | 让下一次 `read_stdin` 前置窗口尺寸序列 | main.v:260 |
| `read_stdin(timeout_ms int) ?string` | `-1` 阻塞 / `0` 立即返回 / `>0` 超时毫秒；返回 `none`=错误或 EOF，`''`=超时；注入 resize 时前置 `ESC[8;h;wt` | main.v:492 |
| `stdin_hit_eof() bool` | 上次读是否 EOF | main.v:493 |
| `write_stdout(string)` | 写原始 UTF-8 字节（含 VT 序列），空串直接返回 | main.v:258,271,2161 等 |
| `file_id(path) !FileId` | 同文件同 id；不存在返回 error | main.v:417,1292 / filepicker.v:226 |

超时常量：`vt_no_timeout = -1`（vt.v:17，常态），`vt_esc_timeout_ms = 100`（ESC 待定时，
vt.v:104）。

---

## 4. sys_windows：句柄与控制台模式

### 4.1 声明约定（避开 V 的 C typedef 限制）

V 不会自动认识 `HANDLE` / `BOOL` 这类 C typedef，统一用基础类型：

```v
module main
#include <windows.h>

fn C.GetStdHandle(id u32) voidptr
fn C.GetConsoleMode(h voidptr, mode &u32) int
fn C.SetConsoleMode(h voidptr, mode u32) int
fn C.SetConsoleOutputCP(cp u32) int
fn C.WaitForSingleObject(h voidptr, ms u32) u32
fn C.ReadConsoleW(h voidptr, buf voidptr, n u32, read &u32, ovl voidptr) int
fn C.ReadFile(h voidptr, buf voidptr, n u32, read &u32, ovl voidptr) int
fn C.WriteConsoleW(h voidptr, buf voidptr, n u32, written &u32, ovl voidptr) int
fn C.WriteFile(h voidptr, buf voidptr, n u32, written &u32, ovl voidptr) int
fn C.GetConsoleScreenBufferInfo(h voidptr, info voidptr) int
fn C.MultiByteToWideChar(cp u32, flags u32, s &char, slen int, w &u16, wlen int) int
fn C.WideCharToMultiByte(cp u32, flags u32, w &u16, wlen int, s &char, slen int, d &char, used &int) int
```

用到的结构体自行按 Win32 布局声明（`CONSOLE_SCREEN_BUFFER_INFO`、`COORD`、`SMALL_RECT`、
`FILE_ID_INFO`、`INPUT_RECORD` …）。若需要 `WIN32_LEAN_AND_MEAN`，用
`-cflags -DWIN32_LEAN_AND_MEAN`（走 build.sh 的 VFLAGS），不要写在 `.v` 里。

### 4.2 状态与模式切换

`SysState` 增加 Windows 字段：`stdin_handle`、`stdout_handle`、`initial_in_mode`、
`initial_out_mode`、`initial_output_cp`、`is_console`（输出是否控制台）。

`switch_modes()`：

- 输入：`SetConsoleMode(in, initial_in & ~(ENABLE_LINE_INPUT|ENABLE_ECHO|ENABLE_PROCESSED_INPUT)
  | ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_MOUSE_INPUT | ENABLE_WINDOW_INPUT
  | ENABLE_EXTENDED_FLAGS)`，并清掉 `ENABLE_QUICK_EDIT_MODE(0x40)`
  （否则左键拖拽落进 conhost 的文本选择，编辑器的鼠标选区全废）
- 输出：`SetConsoleMode(out, initial_out | ENABLE_VIRTUAL_TERMINAL_PROCESSING(0x4)
  | DISABLE_NEWLINE_AUTO_RETURN(0x8))`，避免 `\n` 被自动补 `\r` 破坏帧渲染
- `SetConsoleOutputCP(CP_UTF8)`：主要照顾 V 自己的 `println`/`eprintln`（错误提示中文不乱码）；
  编辑器本体的输出走 `WriteConsoleW`，不依赖代码页

`restore_terminal()`：恢复两个 console mode + 原输出代码页。

`stdin_is_redirected()`：`GetConsoleMode(stdin)` 失败 ⇒ 视为重定向。`reopen_stdin_if_redirected()`
返回 `false`（Windows 无 `/dev/tty` 等价物；管道进来的内容已由 `read_all_stdin()` 处理）。

---

## 5. sys_windows：输入（最需要实测的一块）

### 5.1 方案 A（首选）：VT 直通

开 `ENABLE_VIRTUAL_TERMINAL_INPUT` 后，conhost 把按键、以及（若应用已发 DECSET 1000/1006）鼠标
事件都转成 VT 序列塞进控制台输入缓冲。于是 Windows 侧只需：

1. `WaitForSingleObject(stdin_handle, timeout_ms)` 替代 `poll()`；
   `timeout_ms == -1` 传 `INFINITE`（0xFFFFFFFF）
2. `ReadConsoleW`（控制台）或 `ReadFile`（管道/文件）取数据
3. `WideCharToMultiByte(CP_UTF8)` 转回 UTF-8，交给现有 `input.v` 解析器

优点：复用整套现有 VT/鼠标解析，代码量最小（预估 100 行以内），零语义漂移。
UTF-16 层给的一定是完整码点，因此 `incomplete_utf8_tail_len` 只在**管道读字节**路径才用得上。

### 5.2 方案 B（兜底）：`ReadConsoleInputW` 自行编码

读 `INPUT_RECORD`，把事件编码成 `input.v` 认得的序列：

- `KEY_EVENT_RECORD` → 可打印字符直接给码点；功能键/方向键 → CSI 序列
  （含 `CSI 1;<mod> X` 表达 Shift/Alt/Ctrl 修饰）
- `MOUSE_EVENT_RECORD` → SGR 鼠标 `CSI < cb ; cx ; cy M/m` 或 X10 `CSI M CbCxCy`
  （`input.v` 两条路都支持：见 `parse_xterm_mouse` 与 `parse_x10_mouse_coordinates`）
- `WINDOW_BUFFER_SIZE_EVENT` → 置 `inject_resize`

缺点：要自己维护一张按键映射表，容易与 `input.v` 的解析产生偏差，工作量大。

### 5.3 决策流程

先实现 A 并**实测三件事**：① 鼠标点击/拖拽/滚轮是否进得来；② Ctrl/Alt 组合键修饰位是否正确；
③ 中文输入法/粘贴是否 OK。**只有 A 出现硬缺口才局部切 B**（例如只对手尾事件用 B 补，
其余仍走 A）。

### 5.4 超时与返回值

- `timeout_ms == -1`：阻塞等待（`INFINITE`）
- `timeout_ms == 0`：`WaitForSingleObject(..., 0)`，超时即返回 `''`
- `>0`：按毫秒等；`WAIT_TIMEOUT(0x102)` ⇒ 返回 `''`；`WAIT_FAILED` ⇒ `none`
- `inject_resize` 置位时：按 unix 版语义把 `timeout` 强制为 0，并在返回串前置 `ESC[8;h;wt`
- `ReadFile` 返回 0 字节 ⇒ 置 `stdin_eof = true` 并返回 `none`

---

## 6. sys_windows：输出

`write_stdout(text string)`：

1. 空串直接返回（与 unix 版一致）
2. 输出句柄是控制台 ⇒ UTF-8 → UTF-16（`MultiByteToWideChar`）→ `WriteConsoleW`。
   绕开代码页，中文/框线字符不会受 CP936 影响
3. 输出被重定向/管道 ⇒ `WriteFile` 直接写原始 UTF-8 字节
4. 分块写循环（大帧可能超过一次写入），处理 `ERROR_BROKEN_PIPE`（管道对端关闭时静默返回，
   不要崩）

> 注：`main.v` 的 OSC 52 剪贴板序列（`\x1b]52;c;...`，main.v:520/2549）同样走这条路径，
> 在 Windows Terminal 下可用，conhost 忽略——属预期行为，不作为验收项。

---

## 7. sys_windows：窗口大小与 file_id

**尺寸**：`GetConsoleScreenBufferInfo(stdout, &csbi)` → 列/行取自
`srWindow` 的 `Right-Left+1` / `Bottom-Top+1`（不是 buffer size，否则滚动缓冲区会被算进去）。
与 unix 版一致保留「取不到时 80x24、重试若干次」的兜底。

**resize**：没有 SIGWINCH。两条路：① 事件驱动——收到 `WINDOW_BUFFER_SIZE_EVENT` 置
`inject_resize`（方案 B 路径天然可得；方案 A 下 conhost 会把它转成 VT 尺寸报告
`ESC[8;h;wt`，解析器自行处理）；② 兜底——每次 `read_stdin` 前比对一次尺寸，变化即注入。
启动时的首次尺寸注入仍由 `inject_window_size_into_stdin()` 触发（main.v:260）。

**file_id**：`CreateFileW(GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING)` +
`GetFileInformationByHandleEx(FileIdInfo)`（或 `GetFileInformationByHandle` 的
`dwVolumeSerialNumber` + `nFileIndexHigh/Low`）→ 填 `FileId{st_dev, st_ino}`。
唯一性语义与 unix 的 `(dev, ino)` 等价，跨硬链接同 id、不同文件不同 id。`sys_test.v`
现有 3 个用例（`test_file_id_same_file` / `test_file_id_different_files` /
`test_file_id_missing_file`）直接在 Windows 上跑通即可。

---

## 8. 其他平台差异与构建脚本

### 8.1 代码杂项

- `settings.v:17`：Windows 通常没有 `HOME`/`XDG_CONFIG_HOME`，现 `$else` 会退化到
  `~/.config/msedit`（多半不可用）→ 加 windows 分支用 `LOCALAPPDATA`（或 `APPDATA`）
- `main.v:249`：`edit: cannot reopen /dev/tty` 文案需按 Windows 改写（该函数已退化）
- `settings_test.v` / `goto_file_test.v`：硬编码 `/tmp` 的断言改成 `os.temp_dir()`，
  保证 `v test` 在 Windows 上可跑
- 键盘语义：记录 Ctrl+C（复制 vs 中断）、Ctrl+Z、AltGr 在 Windows 终端下的差异；
  老版 conhost 的 VT 支持不完整 → 文档建议 Windows Terminal / Win11

### 8.2 build.sh 的 Windows 分支

- 产物 `bin/edit.exe`（`$if windows` 下或按 `uname` 判断后缀）
- `PREFIX` 默认值换 Windows 路径（如 `%LOCALAPPDATA%\Programs\edit`），`install` 用 `copy`
- 探测不到 `windows.h` 时给提示：装 WinSDK，或 `CC="zig cc" ./build.sh`
- 编译器不显式指定，让 V 自己选到 clang

### 8.3 限流：`cpulimit` 的替代

AGENTS.md 要求跑 V 编译/测试必须限 CPU（Windows 上没有 `cpulimit`，`ps -axo` 看门狗也不可靠）。
方案：build.sh 的 Windows 分支调 PowerShell，用 `Start-Process -PriorityClass BelowNormal`
起编译进程并等待，同时用 Job Object（`AssignProcessToJobObject` +
`JOB_OBJECT_LIMIT_PROCESS_MEMORY`）实现内存上限；若 Job Object 太重，降级为「仅低优先级 +
保留 `MEMLIMIT_MB=0` 开关 + 提示」。**具体做法在实现 W8 时定，先把开关和提示位留好。**

---

## 9. 验证

1. **编译**：`v -enable-globals -o bin/edit.exe .`
2. **单测**：`v test .`（两个平台的 `file_id` 用例 + 全部既有测试）
3. **手工冒烟**：打开/编辑/保存/搜索/替换/多文档切换/关闭/退出；退出后确认
   ① 控制台模式与代码页已恢复 ② 无残留转义序列 ③ 鼠标点击定位可用
4. **自动化冒烟**：`tools/smoke.py` 基于 pty，Windows 不可用。评估 ConPTY
   （`pywinpty` 或 PowerShell 自建）写 Windows 版冒烟脚本；本期可先手工，自动化列为后续

---

## 10. 任务清单（与 TODO.md 条目对应）

| # | 任务 | 依赖 |
|---|---|---|
| W1 | 拆分 `sys.v` → `sys.v` / `sys_nix.v` / `sys_windows.v`，unix 侧 `v test` 结果与拆分前一致 | — |
| W2 | sys_windows：句柄与控制台模式（switch/restore/is_redirected） | W1 |
| W3 | sys_windows：输入 `read_stdin`（先做方案 A 并实测，有洞才局部用 B） | W1 |
| W4 | sys_windows：输出 `write_stdout`（WriteConsoleW / WriteFile） | W1 |
| W5 | sys_windows：窗口大小 + resize 注入（替代 SIGWINCH） | W1 |
| W6 | sys_windows：`file_id`（卷序列号 + 文件索引） | W1 |
| W7 | 杂项：settings 路径、`/dev/tty` 文案、测试里的 `/tmp` 断言、键盘语义记录 | W1 |
| W8 | build.sh Windows 分支（exe 后缀、install 前缀、限流替代） | — |
| W9 | 验证：编译 + `v test` + 手工冒烟（+ ConPTY 冒烟评估） | W2–W8 |
| W10 | 更新 AGENTS.md（范围、工具链、平台文件约定、限流、smoke 不可用） | W9 |

建议顺序：W1（先保 unix 行为不变）→ W2 → W3 → W4/W5/W6 → W7 → 中途编出 exe 手工试 → W8 → W9 → W10。

---

## 11. 风险与开放问题

1. **`windows.h` 与 vlib 冲突**：`import os` 传递进来的 vlib 声明可能与 Win32 宏
   （`min`/`max`、`GetMessage` 之类）撞名 → 需要 `-DWIN32_LEAN_AND_MEAN`，必要时局部 `#undef`
   或改名。开放问题：是否需要在 `sys_windows.v` 里避免 `import os`（改由调用方传参）？
2. **conhost 的 VT 输入完备性**：方案 A 完全依赖 conhost 的 VT 输入实现；若鼠标或修饰键有缺，
   需回退方案 B 的局部编码（W3 的实测决定）
3. **Quick Edit 模式**：不清掉会吞掉鼠标拖拽（§4.2 已列入）
4. **大帧写入性能**：`WriteConsoleW` 每帧一次调用可能偏慢；必要时做一次
   `MultiByteToWideChar` 全量转换 + 单次写入（现在 unix 侧也是分块循环，先对齐语义再谈优化）
5. **非目标**：不移植 Rust 的 TUI 布局引擎（tui.rs）；不为老版 conhost 的 VT 缺陷兜底；
   不改动 unix 侧既有行为
