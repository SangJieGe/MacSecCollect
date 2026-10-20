#!/usr/bin/env bash
# =============================================================================
#  lib/modules.sh — 采集模块状态记录器
#
#  每个采集模块必须：
#    1. msc_begin <id>                       写开始时间
#    2. 真正采集（用 msc_capture / msc_guarded 等）
#    3. msc_end <id> <status> <exit_code> [error_summary]
#
#  状态值必须与 lib/status.js 的 STATUS 完全一致：
#    success | partial | failed | timed_out | permission_denied
#    not_collected | unsupported
#
#  记录格式：每行一条 TSV，写入 $MSC_MODULES_FILE
#    id \t phase \t start_iso \t end_iso \t status \t exit_code \t duration_ms \t critical \t summary
# =============================================================================

if [ "${__MSC_MODULES_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi
__MSC_MODULES_LOADED=1

MSC_VALID_STATUS="success partial failed timed_out permission_denied not_collected unsupported"

# ── 时间（统一 UTC ISO8601，报告里同时给出本地时区）──
msc_now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ"
}
# macOS date 支持 -j -f；Linux 支持 -d。两者都尝试，失败则退回 perl。
msc_epoch_from_iso() {
  local iso="$1"
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null \
    || date -u -d "$iso" +%s 2>/dev/null \
    || perl -MTime::Piece -e 'print Time::Piece->strptime($ARGV[0],"%Y-%m-%dT%H:%M:%SZ")->epoch-0' "$iso" 2>/dev/null \
    || echo ""
}

# ── 关键模块表（与 lib/status.js MODULE_CRITICAL 保持一致）──
# 输出 1/0（供 TSV 与整体状态计算共用；lib/status.js 中是布尔，二者语义一致）
msc_is_critical() {
  case "$1" in
    network-connections|network-listeners|system-info|processes|persistence|ioc-zeff|ioc-scanner|evidence-integrity)
      echo "1" ;;
    *) echo "0" ;;
  esac
}

msc_status_valid() {
  local s="$1" v
  for v in $MSC_VALID_STATUS; do
    [ "$s" = "$v" ] && return 0
  done
  return 1
}

# ── 模块开始 ──
msc_begin() {
  local id="$1"
  local phase="${MSC_PHASE:-unknown}"
  local now; now=$(msc_now_iso)
  MSC_CURRENT_MODULE="$id"
  MSC_CURRENT_START="$now"
  MSC_CURRENT_START_EPOCH=$(msc_epoch_from_iso "$now")
  # 按 id 保存，避免连续/嵌套 begin-end 互相覆盖
  eval "MSC_START_$(echo "$id" | tr -c 'a-zA-Z0-9_' '_')=\"$now\""
  printf '%s\t%s\t%s\t\t\t\t\t\t\n' "$id" "$phase" "$now" >> "$MSC_MODULES_FILE"
}

# ── 模块结束 ──
# msc_end <id> <status> [exit_code] [summary]
msc_end() {
  local id="$1"; local status="$2"; local code="${3:-0}"; local summary="${4:-}"
  if ! msc_status_valid "$status"; then
    summary="invalid-status($status) ${summary}"
    status="failed"
  fi
  local now; now=$(msc_now_iso)
  local dur=0
  local end_epoch
  end_epoch=$(msc_epoch_from_iso "$now")
  # 按 id 取回开始时间（比全局变量可靠）
  local _key _start
  _key="MSC_START_$(echo "$id" | tr -c 'a-zA-Z0-9_' '_')"
  eval "_start=\${$_key:-}"
  if [ -n "$_start" ]; then
    local s_epoch
    s_epoch=$(msc_epoch_from_iso "$_start")
    if [ -n "$s_epoch" ] && [ -n "$end_epoch" ]; then
      dur=$((end_epoch - s_epoch))
      [ "$dur" -lt 0 ] && dur=0
    fi
  fi
  local critical; critical=$(msc_is_critical "$id")
  summary=$(printf '%s' "$summary" | tr '\t\n' '  ' | cut -c1-300)

  # 删除本模块最后一个「未完成」占位行（纯 bash，避免 awk 单行无换行/字段问题）
  if [ -s "$MSC_MODULES_FILE" ]; then
    local tmp="${MSC_MODULES_FILE}.tmp"
    : > "$tmp"
    local _lastidx=0 _i=0 _line
    while IFS= read -r _line; do
      _i=$((_i + 1))
      case "$_line" in
        "$id"$'\t'*)
          # 第 4 字段为空 → 是未完成的 begin 占位行
          local _f4
          _f4=$(printf '%s' "$_line" | awk -F'\t' '{print $4}')
          [ -z "$_f4" ] && _lastidx=$_i
          ;;
      esac
      printf '%s\n' "$_line" >> "$tmp"
    done < "$MSC_MODULES_FILE"

    if [ "$_lastidx" -gt 0 ]; then
      local tmp2="${MSC_MODULES_FILE}.tmp2"
      : > "$tmp2"
      _i=0
      while IFS= read -r _line; do
        _i=$((_i + 1))
        [ "$_i" -eq "$_lastidx" ] && continue
        printf '%s\n' "$_line" >> "$tmp2"
      done < "$tmp"
      mv "$tmp2" "$tmp" 2>/dev/null
    fi
    mv "$tmp" "$MSC_MODULES_FILE" 2>/dev/null
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "${MSC_PHASE:-unknown}" "${_start:-$MSC_CURRENT_START}" "$now" "$status" "$code" "$dur" "$critical" "$summary" \
    >> "$MSC_MODULES_FILE"

  # 进度输出给 Electron
  echo "MODULE:${id}:${status}"
  MSC_CURRENT_MODULE=""
}

# ── 便捷包装：捕获命令输出到某个分片文件 ──
# msc_module_cmd <module_id> <timeout_secs> <out_file> <cmd...>
# 根据退出码自动推导状态：
#   0 → success（若输出被截断由调用方后续升级为 partial）
#   124 → timed_out
#   126/127 → failed
#   其他 → failed
# 若 stderr 包含权限关键词 → permission_denied
msc_module_cmd() {
  local id="$1"; shift
  local secs="$1"; shift
  local out_file="$1"; shift

  local tmpd; tmpd=$(msc_tmpdir)
  local errf="$tmpd/err" rcf="$tmpd/rc"

  msc_begin "$id"
  local rc=0
  msc_run "$secs" "$out_file" "$errf" "$rcf" "$@" || rc=$?
  rc=$(cat "$rcf" 2>/dev/null || echo "$rc")

  local status="success"
  local summary=""
  if [ "$rc" -eq 124 ]; then
    status="timed_out"
    summary="命令超过 ${secs}s 被终止"
  elif [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
    status="failed"
    summary="无法执行或命令不存在 (exit=$rc)"
  elif [ "$rc" -ne 0 ]; then
    if grep -qiE "operation not permitted|permission denied|not permitted|must be root" "$errf" "$out_file" 2>/dev/null; then
      status="permission_denied"
      summary="权限不足 (exit=$rc)"
    else
      status="failed"
      summary="命令返回 $rc"
    fi
  elif grep -qiE "operation not permitted|permission denied" "$errf" 2>/dev/null; then
    status="partial"
    summary="部分内容因权限被拒"
  fi

  msc_end "$id" "$status" "$rc" "$summary"
  msc_rmtmp "$tmpd"
  return 0
}

# ── 首个模块的开始时间（manifest 的 started_at）──
msc_iso_of_first() {
  local f="${MSC_MODULES_FILE:-}"
  [ -f "$f" ] || { echo ""; return 1; }
  head -1 "$f" | awk -F'\t' '{print $3}'
}

# ── 整体状态计算 ──────────────────────────────────────────────────────────
# 规则（与 lib/status.js 的 computeOverall 保持一致）：
#   * 任一「关键模块」不是 success/partial → incomplete（不得宣称成功）
#   * 非关键模块失败数 >= 30%，或失败+未采集 >= 50% → incomplete
#   * 有任一非 success → partial
#   * 全部 success → success
msc_overall_status() {
  local f="${MSC_MODULES_FILE:-}"
  [ -s "$f" ] || { echo "failed"; return; }

  local total critical_bad failed other_ok
  total=$(wc -l < "$f" | tr -d ' ')
  # 关键模块状态不达标
  critical_bad=$(awk -F'\t' '$8=="1" && $5!="success" && $5!="partial"' "$f" | wc -l | tr -d ' ')
  # 非关键模块中非 success 的数量
  failed=$(awk -F'\t' '$8!="1" && $5!="success" && $5!="partial"' "$f" | wc -l | tr -d ' ')

  if [ "${critical_bad:-0}" -gt 0 ]; then
    echo "incomplete"; return
  fi
  if [ "$total" -gt 0 ]; then
    local pct=$((failed * 100 / total))
    [ "$pct" -ge 30 ] && { echo "incomplete"; return; }
  fi
  if [ "${failed:-0}" -gt 0 ]; then
    echo "partial"; return
  fi
  echo "success"
}
