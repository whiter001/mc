#!/usr/bin/env bash
# build.sh — kimi-v 的统一构建脚本
#
# V 本身支持三种主要 build 模式：
#   - dev   默认 `v .`，带运行时检查（边界、算术溢出、断言），编译快
#   - debug `v -debug .`，保留符号信息和源码映射，便于 lldb/gdb 调试
#   - prod  `v -prod .`，开启 -O3、死代码消除、去掉运行时检查，二进制最小
#
# 用法：
#   ./build.sh              # dev build（默认）
#   ./build.sh dev          # 同上
#   ./build.sh debug        # debug build（保留符号）
#   ./build.sh prod         # prod build（-O3 + strip）
#   ./build.sh cross        # 交叉编译三大平台
#   ./build.sh test         # 跑单元测试
#   ./build.sh fmt          # v fmt -w .
#   ./build.sh vet          # 静态检查
#   ./build.sh clean        # 清理构建产物
#   ./build.sh install      # 安装到 PREFIX/bin（默认 /usr/local）
#   ./build.sh uninstall    # 卸载
#   ./build.sh help         # 帮助
#
# 环境变量：
#   V=v                    # 指定 v 编译器路径（默认：PATH 里的 v）
#   PREFIX=/path           # install 前缀（默认：/usr/local）
#   JOBS=N                 # 并行编译（默认：nproc）
#   DEBUG_FLAGS=...        # 附加到 v -debug 的 flag

set -euo pipefail

# ---------- 配置 -----------------------------------------------------------

PROJECT_NAME="kimi"
BIN_DIR="bin"
V="${V:-v}"

# 交叉编译目标：os:arch:ext
# 注意 macOS / Windows 交叉编译可能需要对应 SDK
TARGETS=(
    "linux:amd64:"
    "linux:arm64:"
    "darwin:amd64:"
    "darwin:arm64:"
    "windows:amd64:.exe"
)

# ---------- 工具函数 ------------------------------------------------------

# 颜色（仅在交互终端启用）
if [[ -t 1 ]]; then
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RESET=$'\033[0m'
else
    C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_RESET=""
fi

log()   { echo "${C_DIM}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }
warn()  { echo "${C_YELLOW}warn:${C_RESET} $*" >&2; }
fail()  { echo "${C_BOLD}${0##*/}:${C_RESET} $*" >&2; exit 1; }

require_v() {
    if ! command -v "$V" >/dev/null 2>&1; then
        fail "找不到 v 编译器：$V（设置 V 环境变量或安装 V：https://vlang.io）"
    fi
}

host_arch() {
    uname -m
}

# ---------- Build 模式 ----------------------------------------------------

# dev build：默认模式，最快编译，保留运行时检查
# 适合日常开发循环。
build_dev() {
    log "dev build"
    mkdir -p "$BIN_DIR"
    "$V" -o "$BIN_DIR/$PROJECT_NAME" .
    report_size "$BIN_DIR/$PROJECT_NAME"
}

# debug build：保留符号和源码映射，便于 lldb/gdb 调试
# 不会做 -O3 优化。
build_debug() {
    log "debug build（保留符号）"
    mkdir -p "$BIN_DIR"
    local extra=""
    if [[ -n "${DEBUG_FLAGS:-}" ]]; then
        extra="$DEBUG_FLAGS"
    fi
    # shellcheck disable=SC2086
    "$V" -debug $extra -o "$BIN_DIR/$PROJECT_NAME-debug" .
    report_size "$BIN_DIR/$PROJECT_NAME-debug"
    echo "  用法: lldb $BIN_DIR/$PROJECT_NAME-debug"
}

# prod build：开 -O3、死代码消除、关掉运行时检查
# 二进制最小、运行最快。日常发布用这个。
build_prod() {
    log "prod build（-O3 + strip）"
    mkdir -p "$BIN_DIR"
    "$V" -prod -o "$BIN_DIR/$PROJECT_NAME" .
    # 再次 strip 保险（V -prod 通常已经 strip，但显式更稳）
    if command -v strip >/dev/null 2>&1; then
        strip "$BIN_DIR/$PROJECT_NAME" 2>/dev/null || true
    fi
    report_size "$BIN_DIR/$PROJECT_NAME"
}

# cross-compile 三个主流平台。
build_cross() {
    log "cross-compile"
    mkdir -p "$BIN_DIR"
    local host_os host_arch_
    host_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$(host_arch)" in
        x86_64)  host_arch_="amd64" ;;
        aarch64|arm64) host_arch_="arm64" ;;
        *)       host_arch_="amd64" ;;
    esac

    for target in "${TARGETS[@]}"; do
        IFS=':' read -r os arch ext <<< "$target"
        # 跳过当前主机平台（已经在 prod build 里出过了）
        if [[ "$os" == "$host_os" && "$arch" == "$host_arch_" ]]; then
            echo "  ${C_DIM}skip $os/$arch (host target, see prod build)${C_RESET}"
            continue
        fi
        local out="$BIN_DIR/${PROJECT_NAME}-${os}-${arch}${ext}"
        echo -n "  → $out ... "
        if "$V" -prod -os "$os" -o "$out" . 2>/dev/null; then
            echo "${C_GREEN}ok${C_RESET}"
        else
            echo "${C_YELLOW}skipped (target not supported on this host)${C_RESET}"
        fi
    done
}

# 跑 vitest。
run_tests() {
    log "tests"
    "$V" test .
}

# v fmt -w .
fmt_sources() {
    log "fmt"
    "$V" fmt -w .
}

# 静态检查。V 0.5 没有官方的 vet，但 oxlint 能 catch 一些风格问题。
vet_sources() {
    log "vet"
    if command -v oxlint >/dev/null 2>&1; then
        oxlint --type-aware . || true
    fi
    "$V" -check . 2>&1 || true
}

# ---------- 安装 ----------------------------------------------------------

install_prod() {
    local prefix="${PREFIX:-/usr/local}"
    local bin="$prefix/bin"
    log "install to $bin"
    build_prod
    mkdir -p "$bin"
    install -m 0755 "$BIN_DIR/$PROJECT_NAME" "$bin/$PROJECT_NAME"
    echo "  ${C_GREEN}installed $bin/$PROJECT_NAME${C_RESET}"
    echo "  运行: $PROJECT_NAME --version"
}

uninstall() {
    local prefix="${PREFIX:-/usr/local}"
    local bin="$prefix/bin/$PROJECT_NAME"
    if [[ -f "$bin" ]]; then
        log "removing $bin"
        rm -f "$bin"
        echo "  ${C_GREEN}uninstalled${C_RESET}"
    else
        warn "not installed: $bin"
    fi
}

# ---------- 工具 ----------------------------------------------------------

clean_all() {
    log "clean"
    rm -rf "$BIN_DIR"
}

report_size() {
    local f="$1"
    if [[ -f "$f" ]]; then
        local size
        size=$(ls -lh "$f" | awk '{print $5}')
        echo "  ${C_GREEN}${f}${C_RESET} (${size})"
    fi
}

usage() {
    cat <<EOF
用法: $0 <mode>

Modes:
  dev           dev build（默认）—— 最快编译，保留运行时检查
  debug         debug build —— 保留符号，便于 lldb/gdb 调试
  prod          prod build —— -O3 + strip，二进制最小
  cross         交叉编译 linux / darwin / windows
  test          跑单元测试
  fmt           v fmt -w .
  vet           静态检查
  clean         清理 $BIN_DIR/
  install       安装 prod binary 到 PREFIX/bin
  uninstall     从 PREFIX/bin 移除
  help          本帮助

环境变量:
  V=path        v 编译器路径（默认：PATH 里的 v）
  PREFIX=path   install 前缀（默认：/usr/local）
  DEBUG_FLAGS   附加到 v -debug 的 flag，例如 DEBUG_FLAGS="-cflags -g"

Examples:
  $0                    # 快速 dev build
  $0 prod               # 出 release binary
  $0 debug              # 调试用，保留符号
  $0 cross              # 一次出三个平台
  PREFIX=~/.local $0 install
EOF
}

# ---------- 入口 ----------------------------------------------------------

require_v

case "${1:-dev}" in
    dev)         build_dev ;;
    debug)       build_debug ;;
    prod)        build_prod ;;
    cross)       build_cross ;;
    test)        run_tests ;;
    fmt)         fmt_sources ;;
    vet)         vet_sources ;;
    clean)       clean_all ;;
    install)     install_prod ;;
    uninstall)   uninstall ;;
    help|-h|--help) usage ;;
    *) fail "未知 mode: $1（试试 '$0 help'）" ;;
esac