#!/usr/bin/env bash
# =============================================================================
#  lib/portable_timeout.sh — 可移植超时执行器（macOS 默认环境可用）
#
#  为什么需要它：
#    macOS 默认没有 GNU coreutils 的 `timeout` / `gtimeout`。
#    原脚本 `timeout 15 lsof ...` 在真实 Mac 上会直接 command not found，
#    关键采集命令根本没运行，但脚本仍然以 0 退出 → 报告显示"成功"。
#
#  设计要点（v2）：
#    1. 不依赖 setsid / gtimeout / jq。macOS 默认没有 setsid 命令。
#       用 `( set -m; ... ) &` 让后台作业成为独立进程组（bash job control）。
#    2. 超时判定用「单调时间 + 轮询」，不靠子进程退出码猜。
#       watchdog 一旦命中就写标记文件；上层**以标记优先**，
#       避免 `wait` 拿到的 143(SIGTERM) 覆盖真正的超时语义。
#    3. 清理用**递归进程树**：先收集 pid 的全部后代，再按「后代→根」顺序
#       发信号。即使管道里的 sleep 已经脱离进程组，也能通过父子链查到并终止。
#    4. 输出先落临时文件，再整份读回，避免管道被 kill 时截断丢证据。
#
#  退出码契约（与 lib/status.js 对齐）：
#     0   正常完成
#     124 超时（GNU timeout 兼容值），实际信号记录在 .signal 标记里
#     125 watchdog 自身故障
#     126 无法执行（权限/非可执行）
#     127 命令不存在
#     130/143 等  命令自身被信号终止的退出码（非超时情况下透传）
#     其他 命令自身的退出码
# =============================================================================

if [ "${__MSC_PORTABLE_TIMEOUT_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi
__MSC_PORTABLE_TIMEOUT_LOADED=1

MSC_TIMEOUT_EXIT=124
MSC_TIMEOUT_WATCHDOG_FAIL=125
MSC_KILL_GRACE_SECS="${MSC_KILL_GRACE_SECS:-2}"

# ── 临时目录 ──
msc_tmpdir() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/msc_pt.XXXXXX" 2>/dev/null) || d="/tmp/msc_pt.$$.$RANDOM"
  mkdir -p "$d" 2>/dev/null
  printf '%s' "$d"
}
msc_rmtmp() { [ -n "${1:-}" ] && rm -rf "$1" 2>/dev/null; return 0; }

# ── 探测可用的原生超时工具（只探测一次）──
# 注意：这里只用它做「可选加速」，核心路径必须能在 __none__ 下工作。
_msc_detect_timeout_tool() {
  if [ -n "${MSC_TIMEOUT_TOOL:-}" ]; then
    printf '%s' "$MSC_TIMEOUT_TOOL"
    return 0
  fi
  local c
  for c in gtimeout timeout; do
    if command -v "$c" >/dev/null 2>&1; then
      # 排除同名 shell function（某些环境有人写了假的 timeout 函数）
      if [ "$(type -t "$c" 2>/dev/null)" != "function" ]; then
        MSC_TIMEOUT_TOOL="$c"
        printf '%s' "$c"
        return 0
      fi
    fi
  done
  MSC_TIMEOUT_TOOL="__none__"
  printf '%s' "__none__"
}

# ── 进程树收集 ───────────────────────────────────────────────────────────────
# _msc_children <pid> → 每行一个直接子进程 pid
# macOS 与 Linux 的 ps 参数不同，两种都试。
_msc_children() {
  local pid="$1"
  ps -o pid= -o ppid= -A 2>/dev/null | awk -v p="$pid" '$2==p {print $1}'
}

# _msc_collect_tree <pid> → 深度优先输出该 pid 及其全部后代（父在前）
_msc_collect_tree() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null || return 0
  printf '%s\n' "$pid"
  local c
  for c in $(_msc_children "$pid"); do
    _msc_collect_tree "$c"
  done
}

# _msc_kill_tree <pid> <SIG>
#   先收集完整树，再按「叶子→根」顺序发信号，避免杀掉父进程后子进程被
#   init 收养而失去可发现的父子链。
_msc_kill_tree() {
  local pid="$1"; local sig="$2"
  [ -z "$pid" ] && return 0

  # 进程组：若 pid 是组长则整组发信号（覆盖已脱离父子链的同组成员）
  local pgid
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  if [ -n "$pgid" ] && [ "$pgid" = "$pid" ]; then
    kill -"$sig" -- "-$pgid" 2>/dev/null || true
  fi

  # 进程树：叶子优先
  local tree
  tree=$(_msc_collect_tree "$pid")
  [ -z "$tree" ] && { kill -"$sig" "$pid" 2>/dev/null || true; return 0; }

  local ordered
  ordered=$(printf '%s\n' "$tree" | awk '{a[NR]=$0} END {for(i=NR;i>=1;i--) print a[i]}')
  local p
  for p in $ordered; do
    kill -"$sig" "$p" 2>/dev/null || true
  done
  return 0
}

# _msc_tree_alive <pid> → 0 表示树中仍有存活进程
_msc_tree_alive() {
  local pid="$1"
  local p
  for p in $(_msc_collect_tree "$pid"); do
    kill -0 "$p" 2>/dev/null && return 0
  done
  return 1
}

# ── watchdog ────────────────────────────────────────────────────────────────
# _msc_watchdog <pid> <secs> <rc_file> <signal_file> <hardkill_file>
#   用单调轮询计时；命中超时后终止整棵树并写标记。
#   标记文件是「超时」的唯一权威来源（上层以此为优先）。
_msc_watchdog() {
  local pid="$1"; local secs="$2"
  local rc_file="$3"; local sig_file="$4"; local hard_file="$5"

  local i=0
  while [ "$i" -lt "$secs" ]; do
    sleep 1
    # 整棵树都已退出 → 正常结束，不写任何超时标记
    _msc_tree_alive "$pid" || return 0
    i=$((i + 1))
  done

  # ── 命中超时 ──
  printf '124' > "$rc_file" 2>/dev/null
  printf 'TERM' > "$sig_file" 2>/dev/null

  _msc_kill_tree "$pid" TERM
  local j=0
  while [ "$j" -lt "$MSC_KILL_GRACE_SECS" ]; do
    sleep 1
    _msc_tree_alive "$pid" || return 0
    j=$((j + 1))
  done

  # 宽限期后仍有存活 → 升级 KILL
  printf 'KILL' > "$sig_file" 2>/dev/null
  _msc_kill_tree "$pid" KILL
  local k=0
  while [ "$k" -lt 3 ]; do
    sleep 1
    _msc_tree_alive "$pid" || break
    k=$((k + 1))
  done
  _msc_tree_alive "$pid" && printf '1' > "$hard_file" 2>/dev/null
  return 0
}

# ── 核心：内置超时执行（不依赖任何外部 timeout）─────────────────────────────
# _msc_builtin_timeout <rc_file> <out_file> <err_file> <secs> <sig_file> <hard_file> <cmd...>
#   返回 0（结果全部写入 rc_file，由调用方读取）
_msc_builtin_timeout() {
  local rc_file="$1"; shift
  local out_file="$1"; shift
  local err_file="$1"; shift
  local secs="$1"; shift
  local sig_file="$1"; shift
  local hard_file="$1"; shift

  : > "$rc_file"; : > "$sig_file"; : > "$hard_file"

  # 用 job control 让后台作业自成一个进程组。
  # set -m 在脚本里也能生效，且 macOS/Linux 都有（不需要 setsid 命令）。
  local pid
  ( set -m; exec "$@" ) >"$out_file" 2>"$err_file" </dev/null &
  pid=$!

  _msc_watchdog "$pid" "$secs" "$rc_file" "$sig_file" "$hard_file" &
  local wd=$!

  local wait_rc=0
  wait "$pid" 2>/dev/null
  wait_rc=$?

  # 关掉 watchdog（命令正常结束时它还在睡）
  kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true

  # ── 关键：超时标记优先 ──
  # watchdog 命中时会写 124。此时 wait 拿到的可能是 143(SIGTERM) / 137(SIGKILL)，
  # 那是「被我们杀掉」的副产物，不能当成命令自己的退出码，也不能覆盖超时语义。
  if [ -s "$rc_file" ]; then
    local marked; marked=$(cat "$rc_file" 2>/dev/null)
    if [ "$marked" = "124" ]; then
      # 超时：清理可能残留的后代（父进程已被 wait 回收，但孤儿可能还在）
      local leftovers
      leftovers=$(ps -o pid= -o ppid= -A 2>/dev/null | awk -v p="$pid" '$2==p {print $1}')
      [ -n "$leftovers" ] && _msc_kill_tree "$pid" KILL
      return 0
    fi
  fi

  # 非超时：透传命令真实退出码
  printf '%s' "$wait_rc" > "$rc_file"
  return 0
}

# ── 核心：使用原生 timeout 工具（可选路径）──────────────────────────────────
# _msc_native_timeout <rc_file> <out_file> <err_file> <secs> <sig_file> <hard_file> <cmd...>
_msc_native_timeout() {
  local rc_file="$1"; shift
  local out_file="$1"; shift
  local err_file="$1"; shift
  local secs="$1"; shift
  local sig_file="$1"; shift
  local hard_file="$1"; shift
  local tool; tool=$(_msc_detect_timeout_tool)

  : > "$rc_file"; : > "$sig_file"; : > "$hard_file"

  local pid
  ( set -m; exec "$tool" -s TERM -k "$MSC_KILL_GRACE_SECS" "$secs" "$@" ) \
    >"$out_file" 2>"$err_file" </dev/null &
  pid=$!

  local wait_rc=0
  wait "$pid" 2>/dev/null
  wait_rc=$?

  # GNU timeout 超时返回 124；-k 生效杀子进程时也可能 137。
  # 只要超时工具报 124，就按超时处理。
  if [ "$wait_rc" = "124" ]; then
    printf '124' > "$rc_file" 2>/dev/null
    printf 'TERM' > "$sig_file" 2>/dev/null
    # 兜底清理整棵树（原生 timeout 只杀直接子进程）
    _msc_kill_tree "$pid" KILL
  else
    printf '%s' "$wait_rc" > "$rc_file"
  fi
  return 0
}

# ── 公共入口 ────────────────────────────────────────────────────────────────
# msc_run <secs> <out_file> <err_file> <rc_file> <cmd...>
#   执行命令，stdout→out_file，stderr→err_file，退出码→rc_file。
#   另外写两个旁路文件供审计：
#     ${rc_file}.signal    超时时的实际信号（TERM/KILL），未超时为空
#     ${rc_file}.hardkill  "1" 表示宽限期后仍存活并升级 KILL
#   返回命令退出码（超时为 124）。
msc_run() {
  local secs="$1"; shift
  local out_file="$1"; shift
  local err_file="$1"; shift
  local rc_file="$1"; shift

  : > "$out_file" 2>/dev/null
  : > "$err_file" 2>/dev/null
  : > "$rc_file" 2>/dev/null

  local sig_file="${rc_file}.signal"
  local hard_file="${rc_file}.hardkill"

  # 超时值健全性检查
  case "$secs" in
    ''|*[!0-9]*) secs=30 ;;
  esac
  [ "$secs" -lt 1 ] && secs=1

  local tool; tool=$(_msc_detect_timeout_tool)
  if [ "$tool" != "__none__" ]; then
    _msc_native_timeout "$rc_file" "$out_file" "$err_file" "$secs" "$sig_file" "$hard_file" "$@" || true
  else
    _msc_builtin_timeout "$rc_file" "$out_file" "$err_file" "$secs" "$sig_file" "$hard_file" "$@" || true
  fi

  local rc; rc=$(cat "$rc_file" 2>/dev/null)
  [ -z "$rc" ] && rc=1
  return "$rc"
}

# msc_run_status <rc_file>
#   → success | timed_out | failed | unsupported
msc_run_status() {
  local rc_file="$1"
  local rc; rc=$(cat "$rc_file" 2>/dev/null)
  case "$rc" in
    0)              printf 'success' ;;
    124)            printf 'timed_out' ;;
    126|127)        printf 'unsupported' ;;
    *)              printf 'failed' ;;
  esac
}

# ── 最简包装：_msc_pt_exec <secs> <cmd...> ─────────────────────────────────
#   执行命令，stdout/stderr 合并输出，返回真实退出码（超时=124）。
#   供采集脚本的模块包装函数使用。
_msc_pt_exec() {
  local secs="$1"; shift
  local tmpd; tmpd=$(msc_tmpdir)
  local out="$tmpd/o" err="$tmpd/e" rc="$tmpd/r"
  msc_run "$secs" "$out" "$err" "$rc" "$@" || true
  local rcval; rcval=$(cat "$rc" 2>/dev/null || echo 1)
  [ -s "$out" ] && cat "$out"
  [ -s "$err" ] && cat "$err" >&2
  msc_rmtmp "$tmpd"
  return "${rcval:-1}"
}

# 兼容旧名
portable_timeout() { _msc_pt_exec "$@"; }
