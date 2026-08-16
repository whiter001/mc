#!/usr/bin/env bash
# build.sh — edit (V rewrite of microsoft/edit) 的统一构建脚本
#
# 用法：
#   ./build.sh              # dev build（默认）
#   ./build.sh dev          # 同上
#   ./build.sh debug        # debug build（保留符号，便于 lldb/gdb）
#   ./build.sh prod         # prod build（-O3 + strip）
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
#   DEBUG_FLAGS=...        # 附加到 v -debug 的 flag
#   MEMLIMIT_MB=2048       # 编译进程树内存上限（MB），0 = 关闭
#   TEST_MEMLIMIT_MB=4096  # v test 进程树内存上限（MB），MEMLIMIT_MB=0 时同样关闭

set -euo pipefail

# ---------- 配置 -----------------------------------------------------------

PROJECT_NAME="edit"
BIN_DIR="bin"
V="${V:-v}"
# measurement.v uses __global (Rust: static mut AMBIGUOUS_WIDTH).
VFLAGS="-enable-globals"

# ---------- 工具函数 ------------------------------------------------------

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

# ---------- 内存看门狗 -----------------------------------------------------
# V 工具链偶发内存失控，会把整机拖死。macOS 的 ulimit -v 不生效，所以用
# 轮询看门狗：后台跑命令，每秒统计其进程树 RSS 总量，超限就整树杀掉。
# MEMLIMIT_MB=0 关闭限制。

MEMLIMIT_MB="${MEMLIMIT_MB:-2048}"
TEST_MEMLIMIT_MB="${TEST_MEMLIMIT_MB:-4096}"

_tree_rss_kb() {
    local root="$1"
    ps -axo pid=,ppid=,rss= | awk -v root="$root" '
        { pid=$1+0; mem[pid]=$3+0; kids[$2+0] = kids[$2+0] " " pid }
        END {
            total = 0; n = 1; stack[1] = root
            while (n > 0) {
                p = stack[n]; n--
                total += mem[p]
                split(kids[p], arr, " ")
                for (i in arr) if (arr[i] != "") { n++; stack[n] = arr[i]+0 }
            }
            printf "%d", total
        }'
}

_tree_pids() {
    local root="$1"
    ps -axo pid=,ppid= | awk -v root="$root" '
        { pid=$1+0; kids[$2+0] = kids[$2+0] " " pid }
        END {
            n = 1; stack[1] = root
            while (n > 0) {
                p = stack[n]; n--
                print p
                split(kids[p], arr, " ")
                for (i in arr) if (arr[i] != "") { n++; stack[n] = arr[i]+0 }
            }
        }'
}

run_with_memlimit() {
    if [[ "$MEMLIMIT_MB" == "0" ]]; then
        "$@"
        return
    fi
    local limit_kb=$(( MEMLIMIT_MB * 1024 ))
    "$@" &
    local pid=$!
    local rc=0 rss=""
    while kill -0 "$pid" 2>/dev/null; do
        rss=$(_tree_rss_kb "$pid")
        if [[ "${rss:-0}" -gt "$limit_kb" ]]; then
            warn "内存超限：进程树 RSS $(( rss / 1024 ))MB > MEMLIMIT_MB=${MEMLIMIT_MB}MB，终止整棵进程树（可调大 MEMLIMIT_MB，或设 0 关闭）"
            local pids
            pids=$(_tree_pids "$pid")
            # shellcheck disable=SC2086
            kill $pids 2>/dev/null || true
            sleep 1
            # shellcheck disable=SC2086
            kill -9 $pids 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            exit 1
        fi
        sleep 1
    done
    wait "$pid" || rc=$?
    return "$rc"
}

# ---------- Build 模式 ----------------------------------------------------

build_dev() {
    log "dev build"
    mkdir -p "$BIN_DIR"
    run_with_memlimit "$V" $VFLAGS -o "$BIN_DIR/$PROJECT_NAME" .
    report_size "$BIN_DIR/$PROJECT_NAME"
}

build_debug() {
    log "debug build（保留符号）"
    mkdir -p "$BIN_DIR"
    local extra=""
    if [[ -n "${DEBUG_FLAGS:-}" ]]; then
        extra="$DEBUG_FLAGS"
    fi
    # shellcheck disable=SC2086
    run_with_memlimit "$V" $VFLAGS -debug $extra -o "$BIN_DIR/$PROJECT_NAME-debug" .
    report_size "$BIN_DIR/$PROJECT_NAME-debug"
    echo "  用法: lldb $BIN_DIR/$PROJECT_NAME-debug"
}

build_prod() {
    log "prod build（-O3 + strip）"
    mkdir -p "$BIN_DIR"
    run_with_memlimit "$V" $VFLAGS -prod -o "$BIN_DIR/$PROJECT_NAME" .
    if command -v strip >/dev/null 2>&1; then
        strip "$BIN_DIR/$PROJECT_NAME" 2>/dev/null || true
    fi
    report_size "$BIN_DIR/$PROJECT_NAME"
}

run_tests() {
    log "tests"
    local limit="$TEST_MEMLIMIT_MB"
    if [[ "$MEMLIMIT_MB" == "0" ]]; then limit=0; fi
    MEMLIMIT_MB="$limit" run_with_memlimit "$V" $VFLAGS test .
}

fmt_sources() {
    log "fmt"
    "$V" fmt -w .
}

vet_sources() {
    log "vet"
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
    echo "  运行: $PROJECT_NAME --help"
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
  MEMLIMIT_MB   编译进程树内存上限，MB（默认 2048，0 = 关闭）
  TEST_MEMLIMIT_MB  v test 进程树内存上限，MB（默认 4096；MEMLIMIT_MB=0 时同样关闭）
EOF
}

# ---------- 入口 ----------------------------------------------------------

require_v

case "${1:-dev}" in
    dev)         build_dev ;;
    debug)       build_debug ;;
    prod)        build_prod ;;
    test)        run_tests ;;
    fmt)         fmt_sources ;;
    vet)         vet_sources ;;
    clean)       clean_all ;;
    install)     install_prod ;;
    uninstall)   uninstall ;;
    help|-h|--help) usage ;;
    *) fail "未知 mode: $1（试试 '$0 help'）" ;;
esac
