#!/usr/bin/env bash
# =============================================================================
#  MacSecCollect v2.2 — 断网采集阶段
#  采集不需要网络的本地系统数据（断网状态下采集更安全）
#  目标：1-3分钟完成
#  用法：mac_collect_offline.sh <输出目录>
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── 输出目录（由 Electron 传入）──
OUTPUT_DIR="${1:?用法: $0 <输出目录>}"
mkdir -p "${OUTPUT_DIR}"

# ── 进度（从 6 开始，接续联网阶段的 1-5，到 15 结束）──
STEP=5; TOTAL=15
step() { STEP=$((STEP+1)); echo -e "\n${CYAN}[${STEP}/${TOTAL}]${RESET} ${BOLD}$1${RESET}"; }
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $1"; }

# ── sudo 保持 ──
sudo -v 2>/dev/null || true
( while true; do sudo -n true; sleep 50; done ) 2>/dev/null &
SUDO_PID=$!
trap 'kill $SUDO_PID 2>/dev/null' EXIT INT TERM

echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║   MacSecCollect v2.2 — 断网采集阶段                  ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
echo -e "  采集时间: $(date)"
echo -e "  输出目录: ${OUTPUT_DIR}\n"

# ═══════════════════════════════════════════════════════════════════════════════
step "【系统】基础信息 + SIP + 内核扩展"
{
  echo "=== macOS 版本 ==="
  sw_vers
  echo -e "\n=== SIP 状态（关闭=高风险）==="
  csrutil status 2>/dev/null
  echo -e "\n=== 内核扩展（非Apple项重点关注）==="
  kextstat 2>/dev/null | grep -v "com.apple" | head -20
  echo -e "\n=== 系统扩展 ==="
  systemextensionsctl list 2>/dev/null | head -20
  echo -e "\n=== 最近安装的应用（7天内）==="
  find /Applications ~/Applications -name "*.app" -maxdepth 2 -mtime -7 2>/dev/null | head -15
  echo -e "\n=== 硬件概览 ==="
  system_profiler SPHardwareDataType 2>/dev/null | head -10
} > "${OUTPUT_DIR}/06_system.txt" 2>/dev/null
ok "系统信息"

# ═══════════════════════════════════════════════════════════════════════════════
step "【进程】运行中的进程 + 开放文件句柄"
{
  echo "=== 所有进程（按CPU排序 Top 80）==="
  ps aux -r 2>/dev/null | head -81
  echo -e "\n=== 进程树（关注异常父子关系）==="
  ps axo pid,ppid,user,stat,comm,args 2>/dev/null | head -80
  echo -e "\n=== 非Apple路径的进程（重点）==="
  ps aux 2>/dev/null | grep -v -E "com\.apple|/usr/bin|/usr/sbin|/bin/|/sbin/|/System/|/Library/Apple" | head -40
  echo -e "\n=== /tmp 或隐藏路径运行的进程（高危）==="
  ps aux 2>/dev/null | grep -E "/tmp/|/var/tmp/|\\.([^/]+)/" | grep -v grep | head -20
  echo -e "\n=== 进程可执行文件路径 ==="
  ps axo pid,comm,args 2>/dev/null | grep -v "^PID" | head -50
  echo -e "\n=== 开放文件句柄（非系统文件，timeout 60s）==="
  timeout 60 lsof 2>/dev/null | grep -v -E "com\.apple|/System/|/usr/lib" | head -500
} > "${OUTPUT_DIR}/07_processes.txt" 2>/dev/null
ok "进程列表 + 文件句柄"

# ═══════════════════════════════════════════════════════════════════════════════
step "【持久化】所有自启动项（最重要）"
{
  echo "=== 用户 LaunchAgents（高优先级检查）==="
  ls -la ~/Library/LaunchAgents/ 2>/dev/null || echo "(空)"
  echo ""
  for f in ~/Library/LaunchAgents/*.plist; do
    [ -f "$f" ] && echo "--- $f ---" && cat "$f" 2>/dev/null && echo ""
  done

  echo -e "\n=== 系统 LaunchAgents ==="
  ls -la /Library/LaunchAgents/ 2>/dev/null | grep -v "com.apple" || echo "(无非Apple项)"
  echo ""
  for f in /Library/LaunchAgents/*.plist; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    [[ "$fname" == com.apple.* ]] && continue
    echo "--- $f ---" && cat "$f" 2>/dev/null && echo ""
  done

  echo -e "\n=== 系统 LaunchDaemons（非Apple项）==="
  ls -la /Library/LaunchDaemons/ 2>/dev/null | grep -v "com.apple" || echo "(无非Apple项)"
  echo ""
  for f in /Library/LaunchDaemons/*.plist; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    [[ "$fname" == com.apple.* ]] && continue
    echo "--- $f ---" && sudo cat "$f" 2>/dev/null && echo ""
  done

  echo -e "\n=== 登录项 ==="
  osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null || echo "(无法获取)"

  echo -e "\n=== Crontab ==="
  crontab -l 2>/dev/null || echo "(无)"
  sudo crontab -l 2>/dev/null || echo "(root 无)"

  echo -e "\n=== Shell 配置中的异常（检查 PATH 劫持/alias 后门）==="
  grep -E "curl|wget|bash|sh |python|nc |ncat|exec" ~/.zshrc ~/.bashrc ~/.bash_profile ~/.zprofile ~/.profile 2>/dev/null | head -20 || echo "(无可疑内容)"
} > "${OUTPUT_DIR}/08_persistence.txt" 2>/dev/null
ok "持久化/自启动项"

# ═══════════════════════════════════════════════════════════════════════════════
step "【用户认证】账号 + SSH + sudo + 登录历史"
{
  echo "=== 本地用户列表 ==="
  dscl . list /Users 2>/dev/null | grep -v "^_"
  echo -e "\n=== Admin 组成员 ==="
  dscl . read /Groups/admin GroupMembership 2>/dev/null

  echo -e "\n=== SSH authorized_keys（⚠️ 有内容=存在免密登录后门风险）==="
  cat ~/.ssh/authorized_keys 2>/dev/null || echo "(不存在，正常)"
  sudo cat /root/.ssh/authorized_keys 2>/dev/null || echo "(root 无 authorized_keys)"

  echo -e "\n=== ~/.ssh/ 文件列表 ==="
  ls -la ~/.ssh/ 2>/dev/null || echo "(目录不存在)"

  echo -e "\n=== sshd_config 关键配置 ==="
  sudo grep -E "PermitRootLogin|PasswordAuthentication|AuthorizedKeysFile|Port" /etc/ssh/sshd_config 2>/dev/null | head -10

  echo -e "\n=== sudoers 非注释行 ==="
  sudo grep -v "^#\|^$" /etc/sudoers 2>/dev/null | head -20

  echo -e "\n=== 最近登录历史（50条）==="
  last 2>/dev/null | head -50

  echo -e "\n=== /var/log/auth.log（最后500行）==="
  sudo tail -500 /var/log/auth.log 2>/dev/null || echo "(不存在或权限不足)"

  echo -e "\n=== sudo 使用记录（最近72h）==="
  timeout 20 log show --last 72h \
    --predicate 'eventMessage contains "sudo"' \
    2>/dev/null | tail -100 || echo "(log 命令超时)"
} > "${OUTPUT_DIR}/09_auth.txt" 2>/dev/null
ok "用户认证 + 登录历史"

# ═══════════════════════════════════════════════════════════════════════════════
step "【远程访问】SSH/VNC/ARD/屏幕共享"
{
  echo "=== SSH 服务状态 ==="
  sudo systemsetup -getremotelogin 2>/dev/null || launchctl list com.openssh.sshd 2>/dev/null || echo "未运行"

  echo -e "\n=== 屏幕共享/VNC 状态 ==="
  sudo launchctl list com.apple.screensharing 2>/dev/null || echo "未运行"

  echo -e "\n=== ARD 远程管理状态 ==="
  sudo launchctl list com.apple.RemoteDesktop.agent 2>/dev/null || echo "未运行"

  echo -e "\n=== 远程访问端口监听状态（22/5900/3283）==="
  netstat -an 2>/dev/null | grep -E "\.22 |\.5900 |\.3283 |\.5988 " | grep LISTEN || echo "相关端口无监听"
} > "${OUTPUT_DIR}/10_remote.txt" 2>/dev/null
ok "远程访问服务"

# ═══════════════════════════════════════════════════════════════════════════════
step "【日志】最近72小时关键事件"
{
  echo "=== 认证事件（最近72h）==="
  timeout 45 log show --last 72h \
    --predicate 'eventMessage contains "authentication" or eventMessage contains "sudo" or eventMessage contains "ssh"' \
    2>/dev/null | tail -200 || echo "(log 命令超时)"

  echo -e "\n=== 安全框架事件（Gatekeeper/XProtect，最近72h）==="
  timeout 30 log show --last 72h \
    --predicate 'subsystem contains "gatekeeper" or subsystem contains "xprotect"' \
    2>/dev/null | tail -100 || echo "(log 命令超时)"

  echo -e "\n=== launchd 启动事件（最近72h）==="
  timeout 45 log show --last 72h \
    --predicate 'subsystem == "com.apple.launchd"' \
    2>/dev/null | tail -300 || echo "(log 命令超时)"

  echo -e "\n=== 最近安装记录 ==="
  tail -50 /var/log/install.log 2>/dev/null || echo "(不存在)"
} > "${OUTPUT_DIR}/11_logs.txt" 2>/dev/null
ok "系统日志（72h）"

# ═══════════════════════════════════════════════════════════════════════════════
step "【文件】可疑路径 + Shell配置 + 临时目录"
{
  echo "=== /tmp/ 可执行文件（高危）==="
  find /tmp /var/tmp -type f -perm +111 2>/dev/null | head -20 || echo "(无可执行文件，正常)"

  echo -e "\n=== /tmp/ 目录内容 ==="
  ls -la /tmp/ 2>/dev/null | head -30

  echo -e "\n=== 最近14天修改的自启动相关文件 ==="
  find ~/Library/LaunchAgents /Library/LaunchAgents /Library/LaunchDaemons \
    -type f -mtime -14 2>/dev/null | head -30 || echo "(无最近修改)"

  echo -e "\n=== 最近14天修改的 /etc/ 文件 ==="
  find /private/etc -type f -mtime -14 2>/dev/null | head -25

  echo -e "\n=== Shell 配置文件完整内容 ==="
  for f in ~/.zshrc ~/.bashrc ~/.bash_profile ~/.zprofile ~/.profile; do
    [ -f "$f" ] && echo "--- $f ---" && cat "$f" 2>/dev/null && echo ""
  done

  echo -e "\n=== PATH 环境变量 ==="
  echo $PATH

  echo -e "\n=== ~/Downloads 最近60天文件 ==="
  find ~/Downloads -maxdepth 2 -type f -mtime -60 2>/dev/null | head -50

  echo -e "\n=== /usr/local/bin/ 完整内容（检查异常二进制）==="
  ls -la /usr/local/bin/ 2>/dev/null | head -50 || echo "(目录不存在)"

  echo -e "\n=== ~/Library/Application Support/ 目录列表（检查异常目录）==="
  ls -la ~/Library/Application\ Support/ 2>/dev/null | head -40 || echo "(目录不存在)"
} > "${OUTPUT_DIR}/12_files.txt" 2>/dev/null
ok "文件系统检查"

# ═══════════════════════════════════════════════════════════════════════════════
step "【安全机制】Gatekeeper + XProtect + IOC"
{
  echo "=== Gatekeeper 状态 ==="
  spctl --status 2>/dev/null

  echo -e "\n=== XProtect 版本 ==="
  defaults read /Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Resources/XProtect.meta.plist 2>/dev/null | head -10 || echo "(无法读取)"

  echo -e "\n=== 已知恶意软件 IOC 路径检查 ==="
  SUSPICIOUS=(
    "/Library/LaunchAgents/com.apple.updated.plist"
    "/Library/LaunchAgents/com.apple.mdworker.plist"
    "/Library/LaunchDaemons/com.apple.updated.plist"
    "~/.config/autostart"
    "/tmp/runner"
    "/tmp/payload"
  )
  for p in "${SUSPICIOUS[@]}"; do
    ep=$(eval echo "$p")
    [ -e "$ep" ] && echo "[⚠️ 存在!] $p" || echo "[正常] $p"
  done

  echo -e "\n=== 非Apple签名的 LaunchDaemons ==="
  for f in /Library/LaunchDaemons/*.plist; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    [[ "$fname" == com.apple.* ]] || echo "[非Apple] $f"
  done 2>/dev/null || echo "(无非Apple项)"

  echo -e "\n=== TCC 已授权应用（隐私权限）==="
  sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
    "SELECT client, service FROM access WHERE auth_value=2 LIMIT 30" 2>/dev/null || echo "(需要完全磁盘访问权限)"

  echo -e "\n=== 浏览器扩展列表（Chrome）==="
  ls ~/Library/Application\ Support/Google/Chrome/Default/Extensions/ 2>/dev/null | head -20 || echo "(Chrome未安装)"
} > "${OUTPUT_DIR}/13_security.txt" 2>/dev/null
ok "安全机制检查"

# ═══════════════════════════════════════════════════════════════════════════════
step "【崩溃报告】最近15天 DiagnosticReports"
{
  echo "=== 最近15天崩溃报告列表 ==="
  ls -lt ~/Library/Logs/DiagnosticReports/ 2>/dev/null | head -20 || echo "(无崩溃报告)"

  echo -e "\n=== 最近3个崩溃报告内容摘要（前50行）==="
  CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
  if [ -d "$CRASH_DIR" ]; then
    count=0
    for f in $(ls -t "$CRASH_DIR" 2>/dev/null | head -3); do
      if [ $count -lt 3 ]; then
        echo -e "\n--- ${CRASH_DIR}/${f} ---"
        head -50 "${CRASH_DIR}/${f}" 2>/dev/null || echo "(无法读取)"
        count=$((count + 1))
      fi
    done
  else
    echo "(DiagnosticReports 目录不存在)"
  fi
} > "${OUTPUT_DIR}/14_crashes.txt" 2>/dev/null
ok "崩溃报告"

# ═══════════════════════════════════════════════════════════════════════════════
step "【摘要】生成快速摘要"
{
  HOSTNAME=$(hostname -s 2>/dev/null || echo "mac")
  echo "# MacSecCollect v2.2 采集摘要"
  echo "采集时间: $(date)"
  echo "主机名: ${HOSTNAME}"
  echo "macOS: $(sw_vers -productVersion 2>/dev/null)"
  echo "当前用户: $(whoami)"
  echo ""
  echo "## 快速关注点"
  echo ""
  echo "### 联网阶段数据（01-05）"
  echo "已由联网采集阶段完成"
  echo ""
  echo "### 监听端口数量"
  netstat -an 2>/dev/null | grep -c LISTEN || echo "0"
  echo ""
  echo "### 用户 LaunchAgents"
  ls ~/Library/LaunchAgents/ 2>/dev/null | wc -l | xargs echo "用户级:"
  ls /Library/LaunchAgents/ 2>/dev/null | grep -v "com.apple" | wc -l | xargs echo "系统级(非Apple):"
  echo ""
  echo "### SSH authorized_keys"
  [ -f ~/.ssh/authorized_keys ] && echo "⚠️ 存在! $(wc -l < ~/.ssh/authorized_keys) 行" || echo "✓ 不存在（正常）"
  echo ""
  echo "### SIP 状态"
  csrutil status 2>/dev/null
  echo ""
  echo "### /tmp 可执行文件"
  find /tmp /var/tmp -type f -perm +111 2>/dev/null | wc -l | xargs echo "数量:"
  echo ""
  echo "### 崩溃报告数量"
  ls ~/Library/Logs/DiagnosticReports/ 2>/dev/null | wc -l | xargs echo "数量:"
} > "${OUTPUT_DIR}/00_SUMMARY.md" 2>/dev/null
ok "摘要生成完成"

# ── 完成 ──
kill $SUDO_PID 2>/dev/null || true
trap - EXIT

echo -e "\n${GREEN}${BOLD}✅ 断网采集完成！${RESET}"
echo -e "  共采集 15 项数据"
echo -e "  输出目录: ${OUTPUT_DIR}"
