#!/usr/bin/env bash
# =============================================================================
#  MacSecCollect v2.0 — 快速版（目标：2分钟内完成）
#  精简策略：每项限时15秒，日志只取最近24h，输出截断到关键量
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
HOSTNAME=$(hostname -s 2>/dev/null || echo "mac")
OUTPUT_DIR="${HOME}/Desktop/MacSecCollect_${HOSTNAME}_${TIMESTAMP}"
ARCHIVE_NAME="MacSecCollect_${HOSTNAME}_${TIMESTAMP}.zip"

STEP=0; TOTAL=11

step() { STEP=$((STEP+1)); echo -e "\n${CYAN}[${STEP}/${TOTAL}]${RESET} ${BOLD}$1${RESET}"; }
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $1"; }

# 带超时的安全执行，超时自动截断
run() {
  local desc="$1"; local outfile="$2"; shift 2
  timeout 15 bash -c "$*" > "${outfile}" 2>/dev/null && ok "${desc}" || warn "${desc} (超时或受限，已保留部分数据)"
}

# ── 创建目录 ──────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║   MacSecCollect v2.0 — 快速安全取证采集工具      ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${RESET}"
echo -e "  采集时间: $(date)\n  ${YELLOW}⚠ 请保持网络连接状态下扫描，扫描完成后再断网隔离${RESET}\n"

sudo -v 2>/dev/null || true
( while true; do sudo -n true; sleep 50; done ) 2>/dev/null &
SUDO_PID=$!
trap 'kill $SUDO_PID 2>/dev/null' EXIT INT TERM

mkdir -p "${OUTPUT_DIR}"

# ── AI 提示词 ─────────────────────────────────────────────────────────────────
cat > "${OUTPUT_DIR}/AI_ANALYSIS_PROMPT.md" << 'PROMPT_EOF'
# MacSecCollect v2.0 安全分析请求

你是专业的 macOS 安全分析师。以下是 MacSecCollect 快速取证工具的采集数据。
请分析是否存在：木马/后门/肉鸡控制/权限篡改/远程控制/信息窃取。

输出格式（中文）：
### 🔴 高危发现
### 🟡 可疑项目  
### 🟢 总体状态
### 🔧 建议操作

## 文件说明
- 01_system.txt     系统版本、SIP状态、内核扩展
- 02_processes.txt  进程列表（重点看非系统进程）
- 03_network.txt    网络连接+监听端口（重点看 ESTABLISHED 出站）
- 04_persistence.txt 所有自启动项（最重要！）
- 05_auth.txt       用户/SSH/sudo配置
- 06_remote.txt     远程访问服务状态
- 07_logs.txt       最近24h关键日志
- 08_files.txt      可疑路径+Shell配置
- 09_security.txt   Gatekeeper/XProtect/IOC检查
PROMPT_EOF
ok "AI 提示词生成完成"

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
} > "${OUTPUT_DIR}/01_system.txt" 2>/dev/null
ok "系统信息"

# ═══════════════════════════════════════════════════════════════════════════════
step "【进程】运行中的进程（非系统进程优先）"
{
  echo "=== 所有进程（按CPU排序 Top 80）==="
  ps aux -r 2>/dev/null | head -81
  echo -e "\n=== 进程树（关注异常父子关系）==="
  ps axo pid,ppid,user,stat,comm,args 2>/dev/null | head -80
  echo -e "\n=== 非Apple路径的进程（重点）==="
  ps aux 2>/dev/null | grep -v -E "com\.apple|/usr/bin|/usr/sbin|/bin/|/sbin/|/System/|/Library/Apple" | head -40
  echo -e "\n=== /tmp 或隐藏路径运行的进程（高危）==="
  ps aux 2>/dev/null | grep -E "/tmp/|/var/tmp/|\\.([^/]+)/" | grep -v grep | head -20
} > "${OUTPUT_DIR}/02_processes.txt" 2>/dev/null
ok "进程列表"

# ═══════════════════════════════════════════════════════════════════════════════
step "【网络】连接 + 端口（含进程名）"
{
  echo "=== 活跃网络连接（含进程名）==="
  timeout 10 lsof -i -n -P 2>/dev/null | head -80
  echo -e "\n=== 监听端口 ==="
  netstat -an 2>/dev/null | grep LISTEN | head -30
  echo -e "\n=== ESTABLISHED 出站连接（重点：看有无可疑IP）==="
  netstat -an 2>/dev/null | grep ESTABLISHED | head -40
  echo -e "\n=== /etc/hosts（检查是否被篡改）==="
  cat /etc/hosts 2>/dev/null
  echo -e "\n=== DNS 配置 ==="
  scutil --dns 2>/dev/null | grep "nameserver" | head -10
  echo -e "\n=== 系统代理设置 ==="
  scutil --proxy 2>/dev/null | head -20
  echo -e "\n=== 穿透工具进程检查（ngrok/frp/zerotier）==="
  ps aux 2>/dev/null | grep -E "ngrok|frp|zerotier|tailscale|hamachi|playit" | grep -v grep || echo "未发现"
} > "${OUTPUT_DIR}/03_network.txt" 2>/dev/null
ok "网络连接"

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
    [ -f "$f" ] && echo "--- $f ---" && cat "$f" 2>/dev/null && echo ""
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
} > "${OUTPUT_DIR}/04_persistence.txt" 2>/dev/null
ok "持久化/自启动项"

# ═══════════════════════════════════════════════════════════════════════════════
step "【用户认证】账号 + SSH 授权密钥 + sudo"
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

  echo -e "\n=== 最近登录历史 ==="
  last 2>/dev/null | head -20
} > "${OUTPUT_DIR}/05_auth.txt" 2>/dev/null
ok "用户认证"

# ═══════════════════════════════════════════════════════════════════════════════
step "【远程访问】SSH/VNC/ARD/屏幕共享"
{
  echo "=== SSH 服务状态 ==="
  sudo systemsetup -getremotelogin 2>/dev/null || launchctl list com.openssh.sshd 2>/dev/null || echo "未运行"

  echo -e "\n=== 屏幕共享/VNC 状态 ==="
  sudo launchctl list com.apple.screensharing 2>/dev/null || echo "未运行"

  echo -e "\n=== ARD 远程管理状态 ==="
  sudo launchctl list com.apple.RemoteDesktop.agent 2>/dev/null || echo "未运行"

  echo -e "\n=== 监听的远程访问端口（22/5900/3283）==="
  netstat -an 2>/dev/null | grep -E "\.22 |\.5900 |\.3283 |\.5988 " | grep LISTEN || echo "相关端口无监听"

  echo -e "\n=== 穿透工具自启动项 ==="
  ls ~/Library/LaunchAgents/ /Library/LaunchAgents/ /Library/LaunchDaemons/ 2>/dev/null | grep -iE "ngrok|frp|zerotier|tailscale|hamachi" || echo "未发现"
} > "${OUTPUT_DIR}/06_remote.txt" 2>/dev/null
ok "远程访问服务"

# ═══════════════════════════════════════════════════════════════════════════════
step "【日志】最近24小时关键事件"
{
  echo "=== 认证事件（最近24h）==="
  timeout 20 log show --last 24h \
    --predicate 'eventMessage contains "authentication" or eventMessage contains "sudo" or eventMessage contains "ssh"' \
    2>/dev/null | tail -60 || echo "(log 命令超时)"

  echo -e "\n=== 安全框架事件（Gatekeeper/XProtect）==="
  timeout 15 log show --last 24h \
    --predicate 'subsystem contains "gatekeeper" or subsystem contains "xprotect"' \
    2>/dev/null | tail -30 || echo "(log 命令超时)"

  echo -e "\n=== launchd 启动事件（最近24h）==="
  timeout 15 log show --last 24h \
    --predicate 'subsystem == "com.apple.launchd"' \
    2>/dev/null | tail -50 || echo "(log 命令超时)"

  echo -e "\n=== 最近安装记录 ==="
  tail -50 /var/log/install.log 2>/dev/null || echo "(不存在)"

  echo -e "\n=== 应用崩溃报告（最近7天）==="
  ls -lt ~/Library/Logs/DiagnosticReports/ 2>/dev/null | head -15
} > "${OUTPUT_DIR}/07_logs.txt" 2>/dev/null
ok "系统日志"

# ═══════════════════════════════════════════════════════════════════════════════
step "【文件】可疑路径 + Shell配置 + 临时目录"
{
  echo "=== /tmp/ 可执行文件（高危）==="
  find /tmp /var/tmp -type f -perm +111 2>/dev/null | head -20 || echo "(无可执行文件，正常)"

  echo -e "\n=== /tmp/ 目录内容 ==="
  ls -la /tmp/ 2>/dev/null | head -30

  echo -e "\n=== 最近7天修改的自启动相关文件 ==="
  find ~/Library/LaunchAgents /Library/LaunchAgents /Library/LaunchDaemons \
    -type f -mtime -7 2>/dev/null | head -20 || echo "(无最近修改)"

  echo -e "\n=== 最近7天修改的 /etc/ 文件 ==="
  find /private/etc -type f -mtime -7 2>/dev/null | head -15

  echo -e "\n=== Shell 配置文件完整内容 ==="
  for f in ~/.zshrc ~/.bashrc ~/.bash_profile ~/.zprofile ~/.profile; do
    [ -f "$f" ] && echo "--- $f ---" && cat "$f" 2>/dev/null && echo ""
  done

  echo -e "\n=== PATH 环境变量 ==="
  echo $PATH

  echo -e "\n=== ~/Downloads 最近30天文件 ==="
  find ~/Downloads -maxdepth 2 -type f -mtime -30 2>/dev/null | head -30
} > "${OUTPUT_DIR}/08_files.txt" 2>/dev/null
ok "文件系统检查"

# ═══════════════════════════════════════════════════════════════════════════════
step "【安全机制】Gatekeeper + XProtect + IOC"
{
  echo "=== Gatekeeper 状态 ==="
  spctl --status 2>/dev/null

  echo -e "\n=== SIP 详细状态 ==="
  csrutil status 2>/dev/null

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
} > "${OUTPUT_DIR}/09_security.txt" 2>/dev/null
ok "安全机制检查"

# ═══════════════════════════════════════════════════════════════════════════════
step "【摘要】生成快速摘要"
{
  echo "# MacSecCollect v2.0 采集摘要"
  echo "采集时间: $(date)"
  echo "主机名: ${HOSTNAME}"
  echo "macOS: $(sw_vers -productVersion 2>/dev/null)"
  echo "当前用户: $(whoami)"
  echo ""
  echo "## 快速关注点"
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
} > "${OUTPUT_DIR}/00_SUMMARY.md" 2>/dev/null
ok "摘要生成完成"

# ═══════════════════════════════════════════════════════════════════════════════
step "【打包】压缩所有数据"
kill $SUDO_PID 2>/dev/null || true
trap - EXIT

cd "${HOME}/Desktop"
zip -r "${ARCHIVE_NAME}" "$(basename ${OUTPUT_DIR})" -q 2>/dev/null && \
  rm -rf "${OUTPUT_DIR}" && ok "打包完成" || warn "打包失败，请手动压缩 ${OUTPUT_DIR}"

echo -e "\n${GREEN}${BOLD}✅ 完成！${RESET}"
echo -e "  压缩包: ${HOME}/Desktop/${ARCHIVE_NAME}"
echo -e "  大小: $(du -h "${HOME}/Desktop/${ARCHIVE_NAME}" 2>/dev/null | cut -f1)"
echo -e "\n  ${YELLOW}下一步: 解压后将文件发给 Claude/GPT 分析${RESET}\n"

open -R "${HOME}/Desktop/${ARCHIVE_NAME}" 2>/dev/null || true
