#!/bin/bash
# =============================================================================
#  mac_collect_offline.sh — 离线阶段：文件/日志/启动项/账号 深度取证
#
#  与在线阶段的区别：
#    * 不做网络快照（假设已断网/已隔离）
#    * 更长的日志回溯窗口、更深的持久化检查、IOC 文件取证
#    * 输出到同一个证据根目录（phase=offline），manifest 合并
#
#  仍然：不使用 sudo、不依赖 GNU timeout/jq、不用 set -e。
# =============================================================================

MSC_VERSION="1.0.0"
MSC_PHASE="offline"
MSC_TOTAL_STEPS=14

_self="${BASH_SOURCE[0]:-$0}"
_self_dir=$(cd "$(dirname "$_self")" 2>/dev/null && pwd)
MSC_SCRIPT_DIR="$_self_dir"
MSC_LIB_DIR="$_self_dir/lib"
MSC_IOC_DIR="$_self_dir/ioc"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"
export LC_ALL="en_US.UTF-8"
export LANG="en_US.UTF-8"
export PAGER=cat

for _lib in portable_timeout modules permissions ioc evidence; do
  if [ -f "$MSC_LIB_DIR/$_lib.sh" ]; then
    # shellcheck disable=SC1090
    . "$MSC_LIB_DIR/$_lib.sh"
  else
    echo "✗ 缺少运行库: lib/$_lib.sh" >&2
    exit 78
  fi
done

MSC_LOG_WINDOW_DAYS="${MSC_LOG_WINDOW_DAYS:-7}"
MSC_LOG_TIMEOUT="${MSC_LOG_TIMEOUT:-300}"
MSC_CMD_TIMEOUT="${MSC_CMD_TIMEOUT:-30}"

OUT_DIR="${1:-}"
if [ -z "$OUT_DIR" ]; then
  echo "用法: mac_collect_offline.sh <输出目录>" >&2
  exit 64
fi
mkdir -p "$OUT_DIR" 2>/dev/null || { echo "✗ 无法创建输出目录" >&2; exit 73; }
OUT_DIR=$(cd "$OUT_DIR" && pwd)

MSC_EVIDENCE_ROOT="$OUT_DIR"
msc_init_evidence_layout "$OUT_DIR"
MSC_MODULES_FILE="$OUT_DIR/.modules.tsv"
touch "$MSC_MODULES_FILE" 2>/dev/null

_step_no=0
step() {
  _step_no=$((_step_no + 1))
  echo "[$_step_no/$MSC_TOTAL_STEPS] 【$1】"
}

msc_module_run() {
  local id="$1"; local critical="$2"; local tmo="$3"; local outfile="$4"
  shift 4
  msc_begin "$id" "$MSC_PHASE"

  local tmpf="$OUT_DIR/.msc_tmp_$$_$id"
  local rc=0
  _msc_pt_exec "$tmo" "$@" > "$tmpf" 2>&1
  rc=$?

  local status
  if [ $rc -eq 0 ]; then status="success"
  elif [ $rc -eq 124 ]; then status="timed_out"
  elif [ $rc -eq 127 ]; then status="unsupported"
  else status="failed"; fi

  if [ "$status" = "success" ] && [ ! -s "$tmpf" ]; then status="partial"; fi
  if [ "$status" != "success" ] && grep -qiE "operation not permitted|permission denied|not authorized" "$tmpf" 2>/dev/null; then
    status="permission_denied"
  fi

  if ! cat "$tmpf" >> "$outfile" 2>/dev/null; then
    status="failed"
    echo "✗ 无法写入 $outfile" >&2
  fi
  local sz; sz=$(wc -c < "$tmpf" 2>/dev/null | tr -d ' ')
  rm -f "$tmpf" 2>/dev/null

  if [ $rc -ne 0 ]; then
    printf '\n# [MSC] 状态=%s 退出码=%s 字节=%s\n' "$status" "$rc" "${sz:-0}" >> "$outfile"
  fi
  msc_end "$id" "$status" "$rc" "bytes=${sz:-0} critical=$critical"
  [ "$status" = "success" ] && return 0
  return 1
}

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  MacSecCollect 离线采集 v$MSC_VERSION                       ║"
echo "║  阶段：离线深度取证（只读，不使用 sudo）                ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "提示：离线采集建议在断网/隔离后进行。本工具不会修改或删除系统文件。"
echo ""

HAS_FDA=$(msc_has_full_disk_access)

# ── 1. 权限环境记录 ──
step "记录离线采集权限环境"
PERM_FILE="$OUT_DIR/system/permissions_offline.txt"
msc_begin "offline-permissions" "$MSC_PHASE"
{
  echo "collected_at: $(msc_now_iso)"
  echo "user: $(id -un)  uid: $(id -u)"
  echo "is_root: $(msc_is_root)"
  echo "full_disk_access: $HAS_FDA"
  echo "network_state: $(ifconfig 2>/dev/null | grep -c 'status: active') 个活动接口"
} > "$PERM_FILE" 2>&1
msc_end "offline-permissions" "success" 0 "fda=$HAS_FDA"
echo "✓ 权限环境"

# ── 2. 系统与硬件基线 ──
step "采集系统与硬件基线"
SYS_FILE="$OUT_DIR/system/system_baseline.txt"
msc_module_run "system-baseline" 0 "$MSC_CMD_TIMEOUT" "$SYS_FILE" \
  bash -c 'echo "== sw_vers =="; sw_vers; echo; echo "== SystemVersion.plist =="; defaults read /System/Library/CoreServices/SystemVersion.plist 2>/dev/null; echo; echo "== SIP 状态 =="; csrutil status 2>&1; echo; echo "== Gatekeeper =="; spctl --status 2>&1; echo; echo "== 文件保险箱 =="; fdesetup status 2>&1; echo; echo "== 已安装内核扩展 =="; kmutil showloaded --list-only 2>/dev/null | head -20 || kextstat 2>/dev/null | head -20'
echo "✓ 系统基线"

# ── 3. 持久化：全面检查 ──
step "全面检查持久化项"
PERSIST_FILE="$OUT_DIR/persistence/persistence_deep.txt"
msc_begin "persistence-deep" "$MSC_PHASE"
{
  echo "# 生成时间: $(msc_now_iso)"
  echo "# 说明：非 Apple 签名的 LaunchDaemon 不等于恶意，需结合路径/签名/时间线判断"
  echo ""
  for _dir in "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons; do
    echo "════ 目录: $_dir ════"
    if [ ! -d "$_dir" ]; then
      echo "  NOT_PRESENT"
    elif [ ! -r "$_dir" ]; then
      echo "  PERMISSION_DENIED（需要完全磁盘访问或管理员权限）"
    else
      ls -la@ "$_dir" 2>&1 | head -60
      echo ""
      echo "  -- 每个 plist 的签名与 Label --"
      for _f in "$_dir"/*.plist; do
        [ -f "$_f" ] || continue
        echo "  --- $(basename "$_f")"
        /usr/libexec/PlistBuddy -c 'Print :Label' "$_f" 2>/dev/null | sed 's/^/      Label: /'
        /usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$_f" 2>/dev/null | tr '\n' ' ' | cut -c1-200 | sed 's/^/      Args: /'
        echo ""
        codesign -dv --verbose=2 "$_f" 2>&1 | grep -E 'Authority|TeamIdentifier|Identifier' | head -3 | sed 's/^/      /'
        _bin=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$_f" 2>/dev/null)
        if [ -n "$_bin" ] && [ -f "$_bin" ]; then
          echo "      二进制: $_bin"
          codesign -dv --verbose=2 "$_bin" 2>&1 | grep -E 'Authority|TeamIdentifier' | head -2 | sed 's/^/        /'
        fi
      done
    fi
    echo ""
  done

  echo "════ 登录项 (System Events) ════"
  osascript -e 'tell application "System Events" to get the name of every login item' 2>&1 | head -5
  echo ""

  echo "════ 第三方登录项 / 后台项 (sfltool) ════"
  sfltool dumpbtm 2>&1 | grep -E 'Name:|Developer Name:|Type:|Disposition:|URL:' | head -120
  echo ""

  echo "════ Cron ════"
  crontab -l 2>&1 | head -30
  echo "--- /etc/crontab ---"
  grep -v '^#' /etc/crontab 2>/dev/null | grep -v '^$' | head -20 || echo "  (空或不可读)"
  echo "--- /usr/lib/cron/tabs ---"
  ls -la /usr/lib/cron/tabs 2>&1 | head -20
  echo ""

  echo "════ 用户 LaunchAgents 目录概览（所有用户可见的）════"
  ls -la /var/at/tabs 2>&1 | head -5
  echo ""

  echo "════ 周期性任务 (/etc/periodic) ════"
  ls -laR /etc/periodic 2>&1 | head -30
} > "$PERSIST_FILE" 2>&1
msc_end "persistence-deep" "success" 0 "LaunchAgents/Daemons/登录项/btm/cron"
echo "✓ 持久化深度检查"

# ── 4. Shell 配置文件与启动脚本 ──
step "检查 Shell 初始化配置"
SHELLRC_FILE="$OUT_DIR/persistence/shell_profiles.txt"
msc_begin "shell-profiles" "$MSC_PHASE"
{
  echo "# 生成时间: $(msc_now_iso)"
  echo "# 说明：Shell 配置是常见持久化位置；私有/不可读配置文件会如实标注"
  echo ""
  for _f in "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.zlogin" \
            "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile" \
            "$HOME/.config/zsh/.zshrc" "/etc/zshrc" "/etc/zshenv" "/etc/profile" "/etc/bashrc"; do
    echo "════ $_f ════"
    if [ ! -e "$_f" ]; then
      echo "  NOT_PRESENT"
    elif [ ! -r "$_f" ]; then
      echo "  PERMISSION_DENIED"
    else
      ls -la@ "$_f" 2>&1
      echo "  -- 内容（前 80 行）--"
      head -80 "$_f" 2>&1 | sed 's/^/    /'
      echo "  -- 可疑行（下载/执行/编码/远程）--"
      grep -nE 'curl|wget|base64|eval|nc |netcat|/dev/tcp|python.*-c|perl.*-e|osascript' "$_f" 2>/dev/null | head -20 | sed 's/^/    /' || echo "    (无)"
    fi
    echo ""
  done
} > "$SHELLRC_FILE" 2>&1
msc_end "shell-profiles" "success" 0 "含可疑行筛查"
echo "✓ Shell 配置"

# ── 5. SSH 配置与 authorized_keys ──
step "检查 SSH 配置与授权密钥"
SSH_FILE="$OUT_DIR/persistence/ssh_config.txt"
msc_begin "ssh-config" "$MSC_PHASE"
{
  echo "# 说明：authorized_keys 存在公钥本身不是后门证据，需看身份/来源/时间"
  echo "收集时间: $(msc_now_iso)"
  echo ""
  echo "════ ~/.ssh 目录 ════"
  ls -la@ "$HOME/.ssh" 2>&1 | head -40
  echo ""
  echo "════ authorized_keys ════"
  for _k in "$HOME/.ssh/authorized_keys" "$HOME/.ssh/authorized_keys2"; do
    if [ -f "$_k" ]; then
      echo "--- $_k (共 $(wc -l < "$_k" 2>/dev/null) 行)"
      ls -la "$_k" 2>&1
      echo "  内容（注释字段可辨识身份）:"
      awk '{print NR": "$1" "substr($2,1,20)"... "$3}' "$_k" 2>/dev/null | head -20 | sed 's/^/    /'
    else
      echo "--- $_k : NOT_PRESENT"
    fi
  done
  echo ""
  echo "════ ssh_config / sshd_config ════"
  for _c in "$HOME/.ssh/config" "/etc/ssh/ssh_config" "/etc/ssh/sshd_config"; do
    if [ -r "$_c" ]; then
      echo "--- $_c"
      grep -vE '^\s*#|^\s*$' "$_c" 2>/dev/null | head -30 | sed 's/^/    /'
    else
      echo "--- $_c : NOT_PRESENT 或 PERMISSION_DENIED"
    fi
  done
  echo ""
  echo "════ 私钥文件（仅列名字与是否加密，不输出内容）════"
  for _p in "$HOME/.ssh"/id_*; do
    [ -f "$_p" ] || continue
    case "$_p" in *.pub) continue;; esac
    _enc=$(head -3 "$_p" 2>/dev/null | grep -c 'ENCRYPTED' || true)
    echo "  $_p encrypted=$([ "${_enc:-0}" -gt 0 ] && echo yes || echo no)"
    ls -la "$_p" 2>&1 | sed 's/^/    /'
  done
  echo ""
  echo "════ 远程登录服务状态 ════"
  systemsetup -getremotelogin 2>&1 | head -3
} > "$SSH_FILE" 2>&1
msc_end "ssh-config" "success" 0 "不输出私钥内容"
echo "✓ SSH 配置"

# ── 6. 账号与管理员组变动 ──
step "检查账号与管理员组"
ACCT_FILE="$OUT_DIR/system/accounts_deep.txt"
msc_begin "accounts-deep" "$MSC_PHASE"
{
  echo "════ 管理员组成员 ════"
  dscl . -read /Groups/admin GroupMembership 2>&1
  echo ""
  echo "════ 所有本地用户 ════"
  dscl . -list /Users UniqueID 2>/dev/null | awk '$2>=500 && $2<1000' | head -30
  echo ""
  echo "════ 每个用户的关键属性 ════"
  for _u in $(dscl . -list /Users UniqueID 2>/dev/null | awk '$2>=500 && $2<1000 {print $1}'); do
    echo "--- $_u"
    dscl . -read "/Users/$_u" UserShell RealName IsHidden 2>/dev/null | sed 's/^/    /'
  done
  echo ""
  echo "════ sudoers（仅列文件，不改不读明细）════"
  ls -la /etc/sudoers /etc/sudoers.d 2>&1 | head -20
  echo ""
  echo "════ 最近登录 ════"
  last -20 2>&1 | head -25
} > "$ACCT_FILE" 2>&1
msc_end "accounts-deep" "success" 0 "不读 sudoers 明细"
echo "✓ 账号检查"

# ── 7. 统一日志：执行与安装相关（长窗口）──
step "采集统一日志（执行/安装相关，${MSC_LOG_WINDOW_DAYS} 天）"
LOG_EXEC="$OUT_DIR/logs/unified_log_execution.txt"
msc_begin "unified-log-exec" "$MSC_PHASE"
{
  echo "# 窗口: last ${MSC_LOG_WINDOW_DAYS}d（Unified Logging 会轮转，窗口外已丢失）"
  echo "# 收集时间: $(msc_now_iso)"
  echo ""
  portable_timeout "$MSC_LOG_TIMEOUT" log show --last "${MSC_LOG_WINDOW_DAYS}d" --style syslog \
    --predicate 'process == "Terminal" OR process == "iTerm2" OR process == "bash" OR process == "zsh" OR process == "sudo" OR eventMessage CONTAINS "com.apple.security" OR eventMessage CONTAINS "Gatekeeper" OR eventMessage CONTAINS "installer"' \
    2>&1 | head -5000
} > "$LOG_EXEC" 2>&1
_rc=$?
if [ $_rc -eq 124 ]; then
  msc_end "unified-log-exec" "timed_out" 124 "log show 超时"
  echo "⚠ 日志采集超时（结果不完整）"
else
  _lines=$(wc -l < "$LOG_EXEC" | tr -d ' ')
  if [ "${_lines:-0}" -lt 2 ]; then
    msc_end "unified-log-exec" "not_collected" 1 "无输出（日志可能已轮转或不可读）"
    echo "⚠ 日志无内容"
  else
    msc_end "unified-log-exec" "success" 0 "lines=$_lines"
    echo "✓ 日志 ($_lines 行)"
  fi
fi

# ── 8. 统一日志：TCC 隐私授权事件 ──
step "采集 TCC 授权事件"
LOG_TCC="$OUT_DIR/logs/unified_log_tcc.txt"
msc_begin "unified-log-tcc" "$MSC_PHASE"
{
  echo "# 查 TCC 相关（哪些进程获得了终端/文件/屏幕权限）"
  portable_timeout 120 log show --last "${MSC_LOG_WINDOW_DAYS}d" --style syslog \
    --predicate 'subsystem == "com.apple.TCC" OR process == "tccd"' 2>&1 | head -2000
} > "$LOG_TCC" 2>&1
_rc=$?
if [ $_rc -eq 124 ]; then
  msc_end "unified-log-tcc" "timed_out" 124 "TCC 日志超时"
elif [ "$(wc -l < "$LOG_TCC" | tr -d ' ')" -lt 2 ]; then
  msc_end "unified-log-tcc" "not_collected" 1 "TCC 日志不可读或已轮转"
else
  msc_end "unified-log-tcc" "success" 0 "tccd 事件"
fi
echo "✓ TCC 日志"

# ── 9. Shell 历史深度检索 ──
step "深度检索 Shell 历史"
HIST_FILE="$OUT_DIR/logs/shell_history_deep.txt"
msc_begin "shell-history-deep" "$MSC_PHASE"
{
  echo "# 重要：历史可被关闭(HISTFILE=)/清空/编辑；未出现≠未执行"
  echo "# 收集时间: $(msc_now_iso)"
  echo ""
  for _h in "$HOME/.zsh_history" "$HOME/.bash_history" "$HOME/.zhistory"; do
    echo "════ $_h ════"
    if [ ! -e "$_h" ]; then echo "  NOT_PRESENT"; echo ""; continue; fi
    ls -la@ "$_h" 2>&1
    echo "  大小/行数: $(wc -l < "$_h" 2>/dev/null) 行"
    echo "  -- 远程下载并执行（高危模式）--"
    grep -anE '(curl|wget)[^|]*\|[[:space:]]*(ba)?sh' "$_h" 2>/dev/null | head -20 | cut -c1-300 | sed 's/^/    /' || echo "    (无)"
    echo "  -- Zeff / installer 相关 --"
    grep -aniE 'zeff|/tmp/installer|Installer\.file' "$_h" 2>/dev/null | head -20 | cut -c1-300 | sed 's/^/    /' || echo "    (无)"
    echo "  -- chmod +x / nohup 执行临时文件 --"
    grep -anE 'chmod \+x|nohup ' "$_h" 2>/dev/null | head -20 | cut -c1-300 | sed 's/^/    /' || echo "    (无)"
    echo ""
  done

  echo "════ zsh 会话记录（可能包含未写入 .zsh_history 的命令）════"
  if [ -d "$HOME/.zsh_sessions" ]; then
    ls -la "$HOME/.zsh_sessions" 2>&1 | head -20
    for _s in "$HOME"/.zsh_sessions/*.history; do
      [ -f "$_s" ] || continue
      echo "--- $_s"
      grep -aniE 'zeff|/tmp/installer|curl.*\|.*(bash|sh)' "$_s" 2>/dev/null | head -10 | cut -c1-300 | sed 's/^/    /' || true
    done
  else
    echo "  NOT_PRESENT"
  fi
} > "$HIST_FILE" 2>&1
msc_end "shell-history-deep" "success" 0 "含高危模式与 IOC 检索"
echo "✓ 历史深度检索"

# ── 10. IOC 文件取证 ──
step "IOC 文件取证（Zeff 等）"
IOC_FILES="$OUT_DIR/ioc/ioc_files.txt"
msc_begin "ioc-files" "$MSC_PHASE"
{
  echo "# 生成时间: $(msc_now_iso)"
  echo "# 对 IOC 定义的路径逐个取证：存在性/大小/属主/权限/时间戳/SHA-256/类型/xattr/Gatekeeper/签名"
  echo "# 注意：只读取，绝不执行可疑文件"
  echo ""
  for _j in "$MSC_IOC_DIR"/*.json; do
    [ -f "$_j" ] || continue
    echo "════════ IOC: $(basename "$_j") ════════"
    msc_ioc_scan "$_j"
    echo ""
  done
} > "$IOC_FILES" 2>&1
msc_end "ioc-files" "success" 0 "文件取证（只读）"
echo "✓ IOC 文件取证"

# ── 11. 已安装应用与最近下载 ──
step "检查已安装应用与最近下载"
APPS_FILE="$OUT_DIR/system/apps_and_downloads.txt"
msc_begin "apps-downloads" "$MSC_PHASE"
{
  echo "════ 已安装第三方应用（非 Apple 签名）════"
  for _a in /Applications/*.app; do
    [ -d "$_a" ] || continue
    echo "--- $(basename "$_a")"
    codesign -dv --verbose=2 "$_a" 2>&1 | grep -E 'Authority=|TeamIdentifier' | head -2 | sed 's/^/    /'
    _md=$(mdls -name kMDItemDateAdded -name kMDItemLastUsedDate "$_a" 2>/dev/null | tr '\n' ' ')
    echo "    $_md"
  done
  echo ""
  echo "════ ~/Downloads 最近 60 天文件 ════"
  if [ -d "$HOME/Downloads" ]; then
    find "$HOME/Downloads" -maxdepth 1 -type f -mtime -60 2>/dev/null | head -60 | while read -r _f; do
      ls -la@ "$_f" 2>&1 | head -1
      _wf=$(xattr -p com.apple.metadata:kMDItemWhereFroms "$_f" 2>/dev/null | head -2 | tr '\n' ' ')
      echo "    wherefrom: ${_wf:-无}"
    done
  else
    echo "  NOT_PRESENT"
  fi
  echo ""
  echo "════ 事件窗口内新建的可执行文件（/tmp, /var/tmp, ~/Library/Caches）════"
  for _d in /tmp /var/tmp "$HOME/Library/Caches"; do
    [ -d "$_d" ] || continue
    echo "--- $_d"
    find "$_d" -maxdepth 2 -type f -perm +111 -mtime -"${MSC_LOG_WINDOW_DAYS}" 2>/dev/null | head -30
  done
} > "$APPS_FILE" 2>&1
msc_end "apps-downloads" "success" 0 "最近 60 天下载 + 事件窗口可执行文件"
echo "✓ 应用与下载"

# ── 12. 触发型证据（浏览器扩展、LaunchServices）──
step "检查浏览器扩展与 LaunchServices 注册"
BROWSER_FILE="$OUT_DIR/system/browser_extensions.txt"
msc_begin "browser-extensions" "$MSC_PHASE"
{
  echo "# 隐私提示：仅列扩展名称与路径，不读取浏览历史/Cookie/密码"
  echo "收集时间: $(msc_now_iso)"
  echo ""
  for _b in "Google/Chrome" "Microsoft Edge" "BraveSoftware/Brave-Browser" "Firefox"; do
    _p="$HOME/Library/Application Support/$_b"
    echo "════ $_b ════"
    if [ ! -d "$_p" ]; then echo "  NOT_PRESENT"; echo ""; continue; fi
    if [ ! -r "$_p" ]; then echo "  PERMISSION_DENIED（需完全磁盘访问）"; echo ""; continue; fi
    if [ -d "$_p/Default/Extensions" ]; then
      ls -1 "$_p/Default/Extensions" 2>/dev/null | head -30 | sed 's/^/    ext_id: /'
    fi
    if [ -d "$_p/Profiles" ]; then
      ls -1 "$_p/Profiles" 2>/dev/null | head -10 | sed 's/^/    profile: /'
    fi
    echo ""
  done
  echo "════ Safari 扩展 ════"
  ls -la "$HOME/Library/Safari/Extensions" 2>&1 | head -20
} > "$BROWSER_FILE" 2>&1
msc_end "browser-extensions" "success" 0 "仅列扩展，不读浏览数据"
echo "✓ 浏览器扩展"

# ── 13. 事件时间线汇总 ──
step "生成事件时间线"
TIMELINE="$OUT_DIR/logs/timeline.txt"
msc_begin "timeline" "$MSC_PHASE"
{
  echo "# 事件时间线（统一 UTC，来源可追溯）"
  echo "# 说明：仅收录与 IOC / 可疑执行 / 持久化 / 授权相关的条目，不罗列日常日志"
  echo ""
  {
    # 关键文件的修改时间
    for _f in /tmp/installer /private/tmp/installer "$HOME/Downloads/Zeff.dmg"; do
      [ -e "$_f" ] || continue
      _ts=$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%SZ' "$_f" 2>/dev/null)
      echo "$_ts | $(_f= ; echo "$_f") | file_mtime"
    done
    # Shell 历史中的 IOC 行
    for _h in "$HOME/.zsh_history" "$HOME/.bash_history"; do
      [ -f "$_h" ] || continue
      grep -aiE 'zeff|/tmp/installer|Installer\.file' "$_h" 2>/dev/null | head -10 | while read -r _l; do
        _t=$(echo "$_l" | grep -oE '^: [0-9]+:' | grep -oE '[0-9]+' | head -1)
        [ -n "$_t" ] && _iso=$(date -u -r "$_t" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || _iso="unknown"
        echo "$_iso | $_h | history_ioc"
      done
    done
    # 日志中的 IOC 行
    for _lf in "$OUT_DIR"/logs/unified_log_*.txt; do
      [ -f "$_lf" ] || continue
      grep -aiE 'zeff|installer' "$_lf" 2>/dev/null | head -20 | while read -r _l; do
        echo "log_time_unknown | $(basename "$_lf") | log_ioc | $(echo "$_l" | cut -c1-160)"
      done
    done
  } | sort -r 2>/dev/null | head -100
} > "$TIMELINE" 2>&1
msc_end "timeline" "success" 0 "按时间倒序，来源可追溯"
echo "✓ 时间线"

# ── 14. checksums + 合并 manifest ──
step "生成校验清单与合并清单"
# 复制 AI 提示词模板
PROMPT_SRC="$MSC_SCRIPT_DIR/templates/AI_ANALYSIS_PROMPT.md"
if [ -f "$PROMPT_SRC" ]; then
  cp "$PROMPT_SRC" "$OUT_DIR/AI_ANALYSIS_PROMPT.md" 2>/dev/null
fi

# 合并 online 阶段的模块记录（若存在）后再写 manifest
MSC_END_ISO=$(msc_now_iso)
MANIFEST="$OUT_DIR/manifest.json"
{
  echo "{"
  echo "  \"tool\": \"MacSecCollect\","
  echo "  \"tool_version\": \"$MSC_VERSION\","
  echo "  \"phase\": \"online+offline\","
  echo "  \"host\": \"$(hostname 2>/dev/null)\","
  echo "  \"os\": \"$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)\","
  echo "  \"user\": \"$(id -un)\","
  echo "  \"timezone\": \"$(date +%Z%z)\","
  echo "  \"log_window_days\": $MSC_LOG_WINDOW_DAYS,"
  echo "  \"finished_at\": \"$MSC_END_ISO\","
  echo "  \"full_disk_access\": \"$HAS_FDA\","
  echo "  \"caveat\": \"checksums 只能发现传输损坏或后续改动，不能证明采集主机未被攻陷\","
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

# 写 summary.json（整体状态 + 缺口清单）
SUMMARY="$OUT_DIR/summary/summary.json"
{
  echo "{"
  echo "  \"overall\": \"$(msc_overall_status)\","
  echo "  \"generated_at\": \"$(msc_now_iso)\","
  echo "  \"gaps\": ["
  awk -F'\t' '
    $5!="success" { printf "    {\"module\":\"%s\",\"status\":\"%s\",\"summary\":\"%s\"},\n", $1,$5,$9 }
  ' "$MSC_MODULES_FILE" | sed '$ s/,$//'
  echo "  ]"
  echo "}"
} > "$SUMMARY" 2>/dev/null

# checksums —— 必须先写完 manifest/summary/AI prompt，再做校验清单，
# 否则清单会与内容不一致（自己把自己写进去后哈希变了）
msc_begin "evidence-integrity" "$MSC_PHASE"
msc_write_checksums "$OUT_DIR" > "$OUT_DIR/.cksum_log" 2>&1
_cks=$?
cat "$OUT_DIR/.cksum_log" 2>/dev/null | sed 's/^/  /'
rm -f "$OUT_DIR/.cksum_log"

if [ $_cks -eq 0 ]; then
  msc_end "evidence-integrity" "success" 0 "checksums 已生成"
else
  msc_end "evidence-integrity" "failed" 1 "checksums 生成失败或为空"
fi
echo "✓ 校验清单"

echo ""
echo "──────────────────────────────────────────────"
echo "离线采集完成。输出: $OUT_DIR"
echo "──────────────────────────────────────────────"
exit 0
