#!/usr/bin/env bash
# =============================================================================
#  lib/portable_timeout.sh — 可移植超时执行器（macOS 默认环境可用）
#
#  为什么需要它：
#    macOS 默认没有 GNU coreutils 的 `timeout` / `gtimeout`。
#    原脚本 `timeout 15 lsof ...` 在真实 Mac 上会直接 command not found，
#    关键采集命令根本没运行，但脚本仍然以 0 退出 → 报告显示"成功"。
#
#  设计：
#    1. 若系统恰好有 gtimeout/timeout，仍然优先用它（更快、无 fork 泄漏）。
#    2. 否则用内置 watchdog：后台起一个子 shell 睡 N 秒后对目标进程组发信号。
#       目标命令用 setsid/set -m 进入独立进程组，kill 时用 -PGID 整组终止，
#       避免"只杀最外层 bash，管道里的 lsof 继续跑"。
#    3. 输出重定向到临时文件，超时/成功都从文件读取，不会因管道截断丢失。
#
#  退出码契约（与 lib/status.js 对齐）：
#     0   正常完成
#     124 超时（GNU timeout 兼容值）
#     125 watchdog 自身故障
#     126 无法执行（权限/不存在）
#     127 命令不存在
#     其他 命令自身的退出码
# =============================================================================

# 防止重复 source
if [ "${__MSC_PORTABLE_TIMEOUT_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi
__MSC_PORTABLE_TIMEOUT_LOADED=1

MSC_TIMEOUT_EXIT=124
MSC_TIMEOUT_WATCHDOG_FAIL=125

# ── 探测可用的原生超时工具（只探测一次）──
_msc_detect_timeout_tool() {
  if [ -n "${MSC_TIMEOUT_TOOL:-}" ]; then
    echo "$MSC_TIMEOUT_TOOL"
    return 0
  fi
  local c
  for c in gtimeout timeout; do
    if command -v "$c" >/dev/null 2>&1; then
      # 排除同名 shell function（某些环境里有人写了假 timeout）
      if ! type -t "$c" 2>/dev/null | grep -q '^function$'; then
        MSC_TIMEOUT_TOOL="$c"
        echo "$c"
        return 0
      fi
    fi
  done
  MSC_TIMEOUT_TOOL="__none__"
  echo "__none__"
  return 0
}

# 内部使用：探测实际可用的 kill 方式
_msc_has_kill_group() {
  if command -v setsid >/dev/null 2>&1; then
    echo "setsid"
  elif (set -m) 2>/dev/null; then
    echo "setm"
  else
    echo "plain"
  fi
}

# _msc_native_timeout <exit_code> <stdout_file> <stderr_file> <seconds> <cmd...>
# 用原生 gtimeout/timeout 执行，输出直接重定向到文件。
# 超时后原生 timeout 只杀直接子进程，我们仍额外补一次进程组清理。
_msc_native_timeout() {
  local rc_file="$1"; shift
  local out_file="$1"; shift
  local err_file="$1"; shift
  local secs="$1"; shift
  local tool; tool=$(_msc_detect_timeout_tool)
  local wrapper=""
  case "$(_msc_has_kill_group)" in
    setsid) wrapper="setsid" ;;
    setm)   wrapper="setm" ;;
  esac

  local rc
  if [ "$wrapper" = "setsid" ]; then
    # setsid 让命令成为新会话/进程组 leader；timeout 杀掉的是 setsid 的父进程，
    # 所以我们让 timeout 直接包裹真正的命令，但仍记录 PGID 以便兜底清理。
    command "$tool" -s TERM -k 2 "$secs" "$@" >"$out_file" 2>"$err_file"
    rc=$?
  elif [ "$wrapper" = "setm" ]; then
    ( set -m; command "$tool" -s TERM -k 2 "$secs" "$@" ) >"$out_file" 2>"$err_file"
    rc=$?
  else
    command "$tool" -s TERM -k 2 "$secs" "$@" >"$out_file" 2>"$err_file"
    rc=$?
  fi
  printf '%s' "$rc" > "$rc_file"
  return 0
}

# _msc_builtin_timeout <rc_file> <out_file> <err_file> <seconds> <cmd...>
# 纯 bash 实现：不依赖任何外部 timeout 工具。
_msc_builtin_timeout() {
  local rc_file="$1"; shift
  local out_file="$1"; shift
  local err_file="$1"; shift
  local secs="$1"; shift

  local rc
  case "$(_msc_has_kill_group)" in
    setsid)
      # setsid 会把命令放到新会话；$! 即新会话 leader 的 pid == pgid
      setsid "$@" >"$out_file" 2>"$err_file" &
      local pid=$!
      _msc_watchdog "$pid" "$secs" &
      local wd=$!
      wait "$pid" 2>/dev/null
      rc=$?
      # 关闭 watchdog（若还在睡）
      kill "$wd" >/dev/null 2>&1 || true
      wait "$wd" 2>/dev/null || true
      # watchdog 命中超时会写 rc_file=124；这里以它为准
      if [ -s "$rc_file" ]; then
        rc=$(cat "$rc_file")
      fi
      ;;
    *)
      # 没有 setsid 的极端情况：用 set -m 启动，使后台作业成为独立进程组
      ( set -m; exec "$@" ) >"$out_file" 2>"$err_file" &
      local pid=$!
      _msc_watchdog "$pid" "$secs" &
      local wd=$!
      wait "$pid" 2>/dev/null
      rc=$?
      kill "$wd" >/dev/null 2>&1 || true
      wait "$wd" 2>/dev/null || true
      if [ -s "$rc_file" ]; then
        rc=$(cat "$rc_file")
      fi
      ;;
  esac
  printf '%s' "$rc" > "$rc_file"
  return 0
}

# _msc_watchdog <pid> <secs>
# 睡 secs 秒；醒来后若目标仍存活，先 TERM 整个进程组，宽限 2 秒再 KILL。
# 命中超时写入 "$MSC_TIMEOUT_RC_FILE" 供上层读取。
_msc_watchdog() {
  local pid="$1"; local secs="$2"
  local i=0
  while [ "$i" -lt "$secs" ]; do
    sleep 1
    kill -0 "$pid" 2>/dev/null || return 0   # 已正常结束
    i=$((i + 1))
  done
  # 超时
  _msc_kill_group "$pid" TERM
  local j=0
  while [ "$j" -lt 2 ]; do
    sleep 1
    kill -0 "$pid" 2>/dev/null || break
    j=$((j + 1))
  done
  kill -0 "$pid" 2>/dev/null && _msc_kill_group "$pid" KILL
  # 记录超时状态 + 硬杀标记
  printf '124' > "${MSC_TIMEOUT_RC_FILE:-/dev/null}"
  if kill -0 "$pid" 2>/dev/null; then
    printf '1' > "${MSC_TIMEOUT_HARD_KILL_FILE:-/dev/null}"
  fi
  return 0
}

# _msc_kill_group <pid> <SIG>
_msc_kill_group() {
  local pid="$1"; local sig="$2"
  # 负号 = 整个进程组；失败再退回单 pid
  kill -"$sig" -- "-$pid" 2>/dev/null || kill -"$sig" "$pid" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# 公共 API
# ─────────────────────────────────────────────────────────────────────────────
#
# msc_run <timeout_secs> <stdout_file> <stderr_file> <cmd...>
#   执行命令，返回真实退出码（0/124/其他）。
#   不打印任何东西，由调用方决定如何呈现。
msc_run() {
  local secs="$1"; shift
  local out_file="$1"; shift
  local err_file="$1"; shift
  local rc_file="$1"; shift

  : > "$out_file"
  : > "$err_file"
  : > "$rc_file"

  export MSC_TIMEOUT_RC_FILE="$rc_file"
  export MSC_TIMEOUT_HARD_KILL_FILE="${rc_file}.hardkill"

  local tool; tool=$(_msc_detect_timeout_tool)
  local rc=0
  if [ "$tool" != "__none__" ]; then
    _msc_native_timeout "$rc_file" "$out_file" "$err_file" "$secs" "$@" || true
    rc=$(cat "$rc_file" 2>/dev/null || echo 1)
  else
    _msc_builtin_timeout "$rc_file" "$out_file" "$err_file" "$secs" "$@" || true
    rc=$(cat "$rc_file" 2>/dev/null || echo 1)
  fi
  unset MSC_TIMEOUT_RC_FILE MSC_TIMEOUT_HARD_KILL_FILE
  return "$rc"
}

# msc_capture <timeout_secs> <max_lines> <footer_label> <cmd...>
#   执行命令并把「最多 max_lines 行」写入 stdout（供模块函数直接追加到汇总文件）。
#   若输出被截断，会在末尾追加 "…[输出被截断: 仅保留前 N 行]"。
#   超时/失败信息追加为 "# [<label>] status=... exit_code=..."。
msc_capture() {
  local secs="$1"; shift
  local max_lines="$1"; shift
  local label="$1"; shift

  local tmpd
  tmpd=$(msc_tmpdir)
  local out="$tmpd/out" err="$tmpd/err" rc="$tmpd/rc"

  local rcval=0
  msc_run "$secs" "$out" "$err" "$rc" "$@" || rcval=$?
  rcval=$(cat "$rc" 2>/dev/null || echo "$rcval")

  local total_lines
  total_lines=$(wc -l < "$out" 2>/dev/null | tr -d ' ')
  total_lines=${total_lines:-0}

  if [ "$total_lines" -gt 0 ]; then
    if [ "$max_lines" = "0" ] || [ "$total_lines" -le "$max_lines" ]; then
      cat "$out"
    else
      head -n "$max_lines" "$out"
      printf '\n…[输出被截断: 共 %s 行, 仅保留前 %s 行]\n' "$total_lines" "$max_lines"
    fi
  fi

  # stderr 摘要（只留前 5 行，避免刷屏）
  if [ -s "$err" ]; then
    printf '\n# [%s] stderr(前5行):\n' "$label"
    head -n 5 "$err" | sed 's/^/#   /'
  fi

  local status_word="success"
  if [ "$rcval" -eq 124 ]; then
    status_word="timed_out"
  elif [ "$rcval" -ne 0 ]; then
    status_word="failed"
  fi
  if [ "$status_word" != "success" ]; then
    printf '\n# [%s] status=%s exit_code=%s\n' "$label" "$status_word" "$rcval"
  fi

  msc_rmtmp "$tmpd"
  return 0
}

# msc_tmpdir — 创建私有临时目录（权限 700）
msc_tmpdir() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/msc.XXXXXX") || d="/tmp/msc.$$.$RANDOM"
  mkdir -p "$d" 2>/dev/null
  echo "$d"
}

msc_rmtmp() {
  [ -n "${1:-}" ] && [ -d "$1" ] && rm -rf "$1" 2>/dev/null
  return 0
}

# ── 最简包装：_msc_pt_exec <secs> <cmd...> ─────────────────────────────────
#   执行命令，stdout/stderr 合并回调用方（重定向即可），返回真实退出码。
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
