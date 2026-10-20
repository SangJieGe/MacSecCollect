#!/bin/bash
# =============================================================================
#  mac_collect_online.sh — 在线阶段：快速、低干扰的当前状态采集
#
#  设计原则：
#    * 不使用 sudo：Electron 从 Finder 启动无 TTY，sudo 会静默失败或挂起。
#      权限不足的模块如实标记 permission_denied。
#    * 不依赖 GNU timeout / jq：只用 macOS 自带的 bash 3.2 / BSD 工具。
#    * 不使用 set -e：单模块失败不影响其它模块，状态由 msc_end 显式记录。
#    * 每模块记录 start/end/status/exit_code，最终由 manifest 汇总。
#
#  进度协议（渲染层依赖）：输出 [N/TOTAL] 【描述】
# =============================================================================

# 版本号唯一来源：仓库根 VERSION 文件（见 scripts/lib/version.sh）
# shellcheck source=lib/version.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/version.sh"
MSC_PHASE="online"
MSC_TOTAL_STEPS=15

# ── 定位脚本根目录（兼容 Finder 启动时 PATH 极简）──
_self="${BASH_SOURCE[0]:-$0}"
_self_dir=$(cd "$(dirname "$_self")" 2>/dev/null && pwd)
MSC_SCRIPT_DIR="$_self_dir"
MSC_LIB_DIR="$_self_dir/lib"
MSC_IOC_DIR="$_self_dir/ioc"

# ── 补齐 PATH：Finder 启动的 app 只有 /usr/bin:/bin:/usr/sbin:/sbin ──
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"
export LC_ALL="en_US.UTF-8"
export LANG="en_US.UTF-8"
# 避免分页器阻塞（log show 等）
export PAGER=cat
export GIT_PAGER=cat

# ── 加载库 ──
for _lib in portable_timeout modules permissions ioc evidence; do
  if [ -f "$MSC_LIB_DIR/$_lib.sh" ]; then
    # shellcheck disable=SC1090
    . "$MSC_LIB_DIR/$_lib.sh"
  else
    echo "✗ 缺少运行库: lib/$_lib.sh" >&2
    exit 78
  fi
done

# ── 采集参数（可被环境变量覆盖）──
MSC_LOG_WINDOW_DAYS="${MSC_LOG_WINDOW_DAYS:-7}"
MSC_LOG_TIMEOUT="${MSC_LOG_TIMEOUT:-180}"
MSC_CMD_TIMEOUT="${MSC_CMD_TIMEOUT:-20}"

# ── 输出目录 ──
OUT_DIR="${1:-}"
if [ -z "$OUT_DIR" ]; then
  echo "用法: mac_collect_online.sh <输出目录>" >&2
  exit 64
fi
mkdir -p "$OUT_DIR" 2>/dev/null || {
  echo "✗ 无法创建输出目录: $OUT_DIR" >&2
  exit 73
}
OUT_DIR=$(cd "$OUT_DIR" && pwd)

MSC_EVIDENCE_ROOT="$OUT_DIR"
msc_init_evidence_layout "$OUT_DIR"
MSC_MODULES_FILE="$OUT_DIR/.modules.tsv"
: > "$MSC_MODULES_FILE" 2>/dev/null
MSC_MODULE_CRITICAL="network-connections:1 network-listeners:1 system-info:1 processes:1"

_step_no=0
step() {
  _step_no=$((_step_no + 1))
  echo "[$_step_no/$MSC_TOTAL_STEPS] 【$1】"
}

# ── 单模块执行包装 ──
# msc_module_run <module_id> <critical:0|1> <timeout_sec> <outfile> <command...>
# 记录状态并写出 <outfile>；返回 0 仅当 status=success
msc_module_run() {
  local id="$1"; local critical="$2"; local tmo="$3"; local outfile="$4"
  shift 4
  msc_begin "$id" "$MSC_PHASE"

  local tmpf="$OUT_DIR/.msc_tmp_$$_$id"
  local rc=0
  _msc_pt_exec "$tmo" "$@" > "$tmpf" 2>&1
  rc=$?

  local status
  if [ $rc -eq 0 ]; then
    status="success"
  elif [ $rc -eq 124 ]; then
    status="timed_out"
  elif [ $rc -eq 127 ]; then
    status="unsupported"
  else
    status="failed"
  fi

  # 命令正常但输出为空 → 视为 partial（可能权限受限或确实无数据）
  if [ "$status" = "success" ] && [ ! -s "$tmpf" ]; then
    status="partial"
  fi

  # stderr 里出现权限关键词 → permission_denied（但保留 exit code）
  if [ "$status" != "success" ] && grep -qiE "operation not permitted|permission denied|not authorized" "$tmpf" 2>/dev/null; then
    status="permission_denied"
  fi

  if ! cat "$tmpf" >> "$outfile" 2>/dev/null; then
    status="failed"
    echo "✗ 无法写入 $outfile" >&2
  fi
  local sz
  sz=$(wc -c < "$tmpf" 2>/dev/null | tr -d ' ')
  rm -f "$tmpf" 2>/dev/null

  if [ $rc -ne 0 ]; then
    printf '\n# [MSC] 该段采集状态=%s 退出码=%s 输出字节=%s\n' "$status" "$rc" "${sz:-0}" >> "$outfile"
  fi

  # 摘要给人看：只在非 success 时说明原因，不塞调试字段
  local _sum=""
  case "$status" in
    success)  _sum="" ;;
    partial)  _sum="输出为空或部分内容受限（${sz:-0} 字节）" ;;
    timed_out) _sum="命令超过 ${secs}s 未完成被终止（退出码 124）" ;;
    permission_denied) _sum="权限不足，该区域未采集（退出码 ${rc}）" ;;
    unsupported) _sum="命令不存在或不可执行（退出码 ${rc}）" ;;
    *)        _sum="命令失败（退出码 ${rc}，输出 ${sz:-0} 字节）" ;;
  esac
  msc_end "$id" "$status" "$rc" "$_sum"
  [ "$status" = "success" ] && return 0
  return 1
}

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  MacSecCollect 在线采集 v$MSC_VERSION                       ║"
echo "║  阶段：在线快速快照（只读，不使用 sudo）                ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── 权限与授权探测（先做，影响后续模块的状态判定）──
step "检测运行权限与系统授权"
PERM_FILE="$OUT_DIR/system/permissions.txt"
msc_begin "permissions-probe" "$MSC_PHASE"
{
  echo "collected_at: $(msc_now_iso)"
  echo "user: $(id -un)"
  echo "uid: $(id -u)"
  echo "is_root: $(msc_is_root)"
  echo "can_sudo_nopass: $(msc_can_sudo_nopass)"
  echo "full_disk_access: $(msc_has_full_disk_access)"
  echo "cwd_readable_probe: $( [ -r "$HOME" ] && echo yes || echo no )"
} > "$PERM_FILE" 2>&1
msc_end "permissions-probe" "success" 0 "user=$(id -un) fda=$(msc_has_full_disk_access)"

HAS_FDA=$(msc_has_full_disk_access)
if [ "$HAS_FDA" != "1" ]; then
  echo "⚠ 未获得「完全磁盘访问权限」(FDA)：~/Library/*、其他用户目录、部分系统数据库将无法读取"
  echo "  这些区域会在报告中标记为 permission_denied，不代表其中的内容安全"
fi
echo "✓ 当前身份: $(id -un) (uid=$(id -u))"

# ── 1. 系统基础信息 ──
step "采集系统基础信息"
SYS_FILE="$OUT_DIR/system/system_info.txt"
msc_module_run "system-info" 1 "$MSC_CMD_TIMEOUT" "$SYS_FILE" \
  bash -c 'echo "== date =="; date; echo; echo "== sw_vers =="; sw_vers; echo; echo "== uname =="; uname -a; echo; echo "== hardware =="; system_profiler SPHardwareDataType 2>/dev/null | head -25; echo; echo "== uptime =="; uptime; echo; echo "== locale/timezone =="; date +%Z%z; readlink /etc/localtime'
echo "✓ 系统信息"

# ── 2. 账号信息 ──
step "采集账号与权限组信息"
ACCT_FILE="$OUT_DIR/system/accounts.txt"
msc_module_run "accounts" 0 "$MSC_CMD_TIMEOUT" "$ACCT_FILE" \
  bash -c 'echo "== who =="; who 2>/dev/null; echo; echo "== last (10) =="; last -10 2>/dev/null; echo; echo "== admin group =="; dscl . -read /Groups/admin GroupMembership 2>/dev/null; echo; echo "== local users =="; dscl . -list /Users UniqueID 2>/dev/null | awk "\$2>=500 && \$2<1000"'
echo "✓ 账号信息"

# ── 3. 进程快照（含完整命令行与父进程）──
step "采集活跃进程与命令行"
PROC_FILE="$OUT_DIR/process/processes.txt"
msc_module_run "processes" 1 "$MSC_CMD_TIMEOUT" "$PROC_FILE" \
  bash -c 'echo "== ps aux (full) =="; ps -axo pid,ppid,user,uid,%cpu,%mem,etime,lstart,command 2>/dev/null'
echo "✓ 进程快照"

# ── 4. 可疑进程特征（临时目录执行 / 解释器 -c / 下载后执行）──
step "筛查可疑进程特征"
SUSP_FILE="$OUT_DIR/process/suspicious_processes.txt"
msc_begin "suspicious-procs" "$MSC_PHASE"
{
  echo "# 生成时间: $(msc_now_iso)"
  echo "# 规则：从 /tmp、/private/tmp、/var/folders、~/Downloads 执行的进程；"
  echo "#       bash/sh -c 携带 curl/wget；nohup 启动的非常规路径进程"
  echo ""
  if [ -f "$PROC_FILE" ]; then
    grep -E '/(tmp|private/tmp|var/folders)/' "$PROC_FILE" 2>/dev/null \
      | grep -vE '(com\.apple|Xcode|/Library/Caches/com\.apple)' || true
    echo ""
    echo "== 解释器 -c 携带下载命令 =="
    grep -E '(bash|sh|zsh)[^|]*-c[^|]*(curl|wget)' "$PROC_FILE" 2>/dev/null || true
    echo ""
    echo "== nohup 相关 =="
    grep -E 'nohup|setsid' "$PROC_FILE" 2>/dev/null || true
  else
    echo "!! 进程快照文件不存在，本模块无法执行"
    exit 3
  fi
} > "$SUSP_FILE" 2>&1
_sus_rc=$?
if [ $_sus_rc -eq 0 ] && [ -s "$SUSP_FILE" ]; then
  msc_end "suspicious-procs" "success" 0 "基于 process/processes.txt"
else
  msc_end "suspicious-procs" "failed" $_sus_rc "进程快照缺失"
fi
echo "✓ 可疑进程筛查"

# ── 5. 网络连接（当前快照，#1 关键项）──
step "采集当前网络连接"
NET_FILE="$OUT_DIR/network/connections.txt"
msc_module_run "network-connections" 1 "$MSC_CMD_TIMEOUT" "$NET_FILE" \
  bash -c 'echo "== lsof -i (top-level) =="; lsof -nP -i 2>/dev/null | head -400; echo; echo "== netstat -an =="; netstat -an -p tcp 2>/dev/null | head -200; echo; echo "== netstat udp =="; netstat -an -p udp 2>/dev/null | head -80'
echo "✓ 网络连接"

# ── 6. 监听端口 ──
step "采集监听端口"
LISTEN_FILE="$OUT_DIR/network/listeners.txt"
msc_module_run "network-listeners" 1 "$MSC_CMD_TIMEOUT" "$LISTEN_FILE" \
  bash -c 'echo "== lsof -iTCP -sTCP:LISTEN =="; lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null; echo; echo "== netstat listen =="; netstat -an 2>/dev/null | grep -i listen'
echo "✓ 监听端口"

# ── 7. 网络配置（接口/路由/DNS/代理）──
step "采集网络接口、路由与代理配置"
NETCFG_FILE="$OUT_DIR/network/config.txt"
msc_begin "network-config" "$MSC_PHASE"
{
  echo "== ifconfig (up) =="
  ifconfig 2>/dev/null | grep -E '^[a-z]|inet ' | head -80
  echo ""
  echo "== route -n get default =="
  route -n get default 2>/dev/null
  echo ""
  echo "== DNS resolvers (scutil --dns, 仅 resolver 摘要) =="
  scutil --dns 2>/dev/null | grep -E 'nameserver|domain|search' | head -40
  echo ""
  echo "== 系统代理配置（脱敏）=="
  for _svc in $(networksetup -listallnetworkservices 2>/dev/null | tail -n +2); do
    _p=$(networksetup -getwebproxy "$_svc" 2>/dev/null | tr '\n' ' ')
    _s=$(networksetup -getsecurewebproxy "$_svc" 2>/dev/null | tr '\n' ' ')
    echo "service=$_svc web_proxy=${_p}"
    echo "service=$_svc secure_proxy=${_s}"
  done
} > "$NETCFG_FILE" 2>&1
# 代理 URL 中的凭据脱敏（Node 侧 privacy.js 也会再处理一次）
if [ -f "$NETCFG_FILE" ]; then
  perl -pi -e 's#(https?://)([^:/\s@]+):([^@/\s]*)@#$1[REDACTED:USER]:[REDACTED:PASS]@#g' "$NETCFG_FILE" 2>/dev/null
fi
msc_end "network-config" "success" 0 "DNS 为配置而非查询历史"
echo "✓ 网络配置"

# ── 8. 建立网络连接与进程的关联 ──
step "关联网络连接与进程"
NETPROC_FILE="$OUT_DIR/network/connection_process_map.txt"
msc_begin "network-process-map" "$MSC_PHASE"
{
  echo "# 生成时间: $(msc_now_iso)"
  echo "# 说明：PID → 进程名 → 可执行路径 → 远端地址"
  echo ""
  lsof -nP -i 2>/dev/null | awk 'NR>1 {print $1, $2, $8, $9, $10}' | while read -r _cmd _pid _fd _proto _addr; do
    [ -z "$_pid" ] && continue
    _exe=$(ps -p "$_pid" -o comm= 2>/dev/null | head -1)
    _user=$(ps -p "$_pid" -o user= 2>/dev/null | head -1)
    printf 'pid=%s user=%s cmd=%s exe=%s proto=%s addr=%s\n' \
      "$_pid" "${_user:-?}" "$_cmd" "${_exe:-?}" "${_proto:-?}" "${_addr:-?}"
  done
} > "$NETPROC_FILE" 2>&1
msc_end "network-process-map" "success" 0 "lsof PID 关联"
echo "✓ 连接-进程关联"

# ── 9. 持久化项（LaunchAgents/Daemons/登录项）──
step "检查 LaunchAgents / LaunchDaemons / 登录项"
PERSIST_FILE="$OUT_DIR/persistence/persistence.txt"
msc_begin "persistence" "$MSC_PHASE"
{
  echo "== 用户 LaunchAgents =="
  ls -la "$HOME/Library/LaunchAgents" 2>&1 | head -60
  echo ""
  echo "== 系统 LaunchAgents =="
  ls -la /Library/LaunchAgents 2>&1 | head -60
  echo ""
  echo "== LaunchDaemons =="
  ls -la /Library/LaunchDaemons 2>&1 | head -80
  echo ""
  echo "== Apple 系统 Daemons（仅计数，供对比）=="
  ls /System/Library/LaunchDaemons 2>/dev/null | wc -l
  echo ""
  echo "== 登录项 (AppleScript API) =="
  osascript -e 'tell application "System Events" to get the name of every login item' 2>&1 | head -5
  echo ""
  echo "== 第三方非 Apple LaunchDaemons 明细（需人工判断，非自动恶意）=="
  for _p in /Library/LaunchDaemons/*.plist /Library/LaunchAgents/*.plist; do
    [ -f "$_p" ] || continue
    echo "--- $_p"
    codesign -dv --verbose=2 "$_p" 2>&1 | grep -E 'Authority|TeamIdentifier' | head -3
  done
} > "$PERSIST_FILE" 2>&1
msc_end "persistence" "success" 0 "列目录+签名，不自动判定恶意"
echo "✓ 持久化项"

# ── 10. 后台任务（sfltool dumpbtm）──
step "采集后台任务 (sfltool dumpbtm)"
BTM_FILE="$OUT_DIR/persistence/background_tasks.txt"
msc_module_run "btm" 0 "$MSC_CMD_TIMEOUT" "$BTM_FILE" \
  bash -c 'echo "== sfltool dumpbtm =="; sfltool dumpbtm 2>&1 | head -300'
echo "✓ 后台任务"

# ── 11. Shell 历史检索 ──
step "检索 Shell 历史中的 IOC"
HIST_FILE="$OUT_DIR/logs/shell_history.txt"
msc_begin "shell-history" "$MSC_PHASE"
{
  echo "# 生成时间: $(msc_now_iso)"
  echo "# 注意：历史可被关闭/清空/编辑，未出现不等于未执行"
  echo ""
  for _h in "$HOME/.zsh_history" "$HOME/.zsh_sessions" "$HOME/.bash_history" "$HOME/.bash_sessions" "$HOME/.history" "$HOME/.sh_history"; do
    if [ -e "$_h" ]; then
      echo "--- $_h"
      ls -la "$_h" 2>&1
      if [ -f "$_h" ]; then
        echo "[IOC 相关行]"
        grep -aiE 'zeff|macos\.zeff\.app|/tmp/installer|Installer\.file|curl.*\|.*(bash|sh)' "$_h" 2>/dev/null | head -40 || echo "(无命中)"
      fi
      echo ""
    else
      echo "--- $_h : NOT_PRESENT"
      echo ""
    fi
  done
  echo "== 历史相关环境变量（值已省略）=="
  for _v in HISTFILE HISTSIZE SAVEHIST HISTCONTROL; do
    eval "_val=\${$_v:-<unset>}"
    echo "$_v=$_val"
  done
} > "$HIST_FILE" 2>&1
msc_end "shell-history" "success" 0 "未出现≠未执行"
echo "✓ Shell 历史"

# ── 12. 统一日志采集（IOC 定向）──
step "采集统一日志（IOC 定向，${MSC_LOG_WINDOW_DAYS} 天）"
LOG_IOC_FILE="$OUT_DIR/logs/unified_log_ioc.txt"
msc_begin "unified-log-ioc" "$MSC_PHASE"
{
  echo "# 生成时间: $(msc_now_iso)"
  echo "# 回溯窗口: last ${MSC_LOG_WINDOW_DAYS}d"
  echo "# 说明：Unified Logging 会轮转，窗口外记录已丢失；不可读时本模块状态非 success"
  echo ""
  portable_timeout "$MSC_LOG_TIMEOUT" log show --last "${MSC_LOG_WINDOW_DAYS}d" --style syslog \
    --predicate 'eventMessage CONTAINS[c] "zeff" OR eventMessage CONTAINS[c] "installer"' 2>&1 | head -2000
} > "$LOG_IOC_FILE" 2>&1
_log_rc=$?
if [ $_log_rc -eq 124 ]; then
  msc_end "unified-log-ioc" "timed_out" 124 "log show 超时，日志未完整采集"
  echo "⚠ 统一日志采集超时，未完整"
elif [ -s "$LOG_IOC_FILE" ]; then
  msc_end "unified-log-ioc" "success" 0 "窗口 ${MSC_LOG_WINDOW_DAYS}d"
  echo "✓ 统一日志"
else
  msc_end "unified-log-ioc" "not_collected" 1 "log show 无输出或不可用"
  echo "⚠ 统一日志未采集到内容"
fi

# ── 13. 安装器/脚本执行痕迹（TCC、quarantine）──
step "检查安装器执行与隔离属性痕迹"
EXEC_FILE="$OUT_DIR/logs/execution_traces.txt"
msc_begin "exec-traces" "$MSC_PHASE"
{
  echo "== /tmp 与 /private/tmp 内容（寻找 installer 残留）=="
  ls -la@ /private/tmp 2>&1 | head -80
  echo ""
  echo "== quarantine 事件（LSUIElement/下载记录，尽力而为）=="
  sqlite3 "$HOME/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2" \
    "SELECT datetime(LSQuarantineTimeStamp+978307200,'unixepoch','localtime'), LSQuarantineAgentName, LSQuarantineDataURLString FROM LSQuarantineEvent ORDER BY LSQuarantineTimeStamp DESC LIMIT 50;" 2>&1 | head -60
  echo ""
  echo "== 已挂载卷 =="
  mount 2>/dev/null | grep -v '^/dev/disk1s1 on /' | head -20
  echo ""
  echo "== /Volumes =="
  ls -la /Volumes 2>&1 | head -20
} > "$EXEC_FILE" 2>&1
msc_end "exec-traces" "partial" 0 "quarantine 需 FDA，tmp 可能已被清理"
echo "✓ 执行痕迹"

# ── 14. IOC 检测（数据驱动）──
step "执行 IOC 检测 (Zeff 等)"
IOC_OUT="$OUT_DIR/ioc/ioc_matches.txt"
msc_begin "ioc-scan" "$MSC_PHASE"
{
  echo "# 生成时间: $(msc_now_iso)"
  echo "# 说明：命中=值得调查，不等于恶意；未命中≠系统干净"
  echo ""
  if [ -d "$MSC_IOC_DIR" ]; then
    for _f in "$MSC_IOC_DIR"/*.json; do
      [ -f "$_f" ] || continue
      ioc_scan_file "$_f"
    done
  else
    echo "!! IOC 定义目录不存在: $MSC_IOC_DIR"
  fi
} > "$IOC_OUT" 2>&1
msc_end "ioc-scan" "success" 0 "定义目录 $MSC_IOC_DIR"
echo "✓ IOC 检测"

# ── 15. 生成清单与摘要 ──
step "生成 manifest 与摘要"
MSC_END_ISO=$(msc_now_iso)

# ── 整体状态与各状态计数（必须在写 manifest 之前算好）──
OVERALL=$(msc_overall_status)
_cnt() { awk -F'\t' -v s="$1" '$5==s' "$MSC_MODULES_FILE" 2>/dev/null | wc -l | tr -d ' '; }
CNT_SUCCESS=$(_cnt success)
CNT_PARTIAL=$(_cnt partial)
CNT_FAILED=$(_cnt failed)
CNT_TIMED_OUT=$(_cnt timed_out)
CNT_PERM=$(_cnt permission_denied)
CNT_NOTCOL=$(_cnt not_collected)
CNT_UNSUP=$(_cnt unsupported)

# manifest.json
MANIFEST="$OUT_DIR/manifest.json"
{
  echo "{"
  echo "  \"tool\": \"MacSecCollect\","
  echo "  \"tool_version\": \"$MSC_VERSION\","
  echo "  \"phase\": \"$MSC_PHASE\","
  echo "  \"host\": \"$(hostname 2>/dev/null)\","
  echo "  \"os\": \"$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)\","
  echo "  \"arch\": \"$(uname -m 2>/dev/null)\","
  echo "  \"user\": \"$(id -un)\","
  echo "  \"timezone\": \"$(date +%Z%z)\","
  echo "  \"log_window_days\": $MSC_LOG_WINDOW_DAYS,"
  echo "  \"started_at\": \"$(msc_iso_of_first)\","
  echo "  \"finished_at\": \"$MSC_END_ISO\","
  echo "  \"full_disk_access\": \"$HAS_FDA\","
  echo "  \"overall_status\": \"$OVERALL\","
  echo "  \"status_counts\": {\"success\": $CNT_SUCCESS, \"partial\": $CNT_PARTIAL, \"failed\": $CNT_FAILED, \"timed_out\": $CNT_TIMED_OUT, \"permission_denied\": $CNT_PERM, \"not_collected\": $CNT_NOTCOL, \"unsupported\": $CNT_UNSUP},"
  echo "  \"modules\": ["
  awk -F'\t' '
    { rows[NR]=$0 }
    END {
      n=NR
      for (i=1; i<=n; i++) {
        split(rows[i], f, "\t")
        if (f[1]=="") continue
        printf "    {\"id\":\"%s\",\"phase\":\"%s\",\"start\":\"%s\",\"end\":\"%s\",\"status\":\"%s\",\"exit_code\":%s,\"duration_ms\":%s,\"critical\":%s,\"summary\":\"%s\"}%s\n", \
          f[1],f[2],f[3],f[4],f[5],(f[6]==""?"null":f[6]),(f[7]==""?"null":f[7]),(f[8]=="1"?"true":"false"),f[9],(i==n?"":",")
      }
    }' "$MSC_MODULES_FILE"
  echo "  ]"
  echo "}"
} > "$MANIFEST" 2>/dev/null
echo "✓ 清单"
echo ""
echo "──────────────────────────────────────────────"
echo "采集阶段完成。整体状态: $OVERALL"
echo "输出目录: $OUT_DIR"
echo "──────────────────────────────────────────────"

# 退出码反映整体状态：非 success 时返回非 0，让 Node 侧不会误判
case "$OVERALL" in
  success) exit 0 ;;
  partial) exit 20 ;;
  incomplete) exit 21 ;;
  *) exit 22 ;;
esac
