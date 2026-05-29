#!/usr/bin/env bash
# =============================================================================
#  MacSecCollect — macOS Security Forensic Data Collector
#  Version: 1.0.0
#  作者: 为 AI 分析准备的取证数据采集脚本
#  用途: 采集 Mac 安全相关数据，打包后发给 AI (Claude/GPT/Hermes) 分析
#  注意: 本工具只负责复制/采集，不联网，不做判断，不全盘扫描
# =============================================================================

set -uo pipefail

# ── 颜色定义 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── 目录设置 ──────────────────────────────────────────────────────────────────
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
HOSTNAME=$(hostname -s 2>/dev/null || echo "mac")
OUTPUT_DIR="${HOME}/Desktop/MacSecCollect_${HOSTNAME}_${TIMESTAMP}"
ARCHIVE_NAME="MacSecCollect_${HOSTNAME}_${TIMESTAMP}.zip"
ARCHIVE_PATH="${HOME}/Desktop/${ARCHIVE_NAME}"

# ── 进度计数 ──────────────────────────────────────────────────────────────────
STEP=0
TOTAL=20

step() {
  STEP=$((STEP + 1))
  echo -e "\n${CYAN}[${STEP}/${TOTAL}]${RESET} ${BOLD}$1${RESET}"
}

ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
err()  { echo -e "  ${RED}✗${RESET}  $1"; }

# ── 安全执行：失败不中断 ───────────────────────────────────────────────────────
run() {
  local desc="$1"; shift
  local outfile="$1"; shift
  if "$@" > "${outfile}" 2>/dev/null; then
    ok "${desc}"
  else
    warn "${desc} (部分权限受限，已保存可用数据)"
  fi
}

# ── 追加执行 ──────────────────────────────────────────────────────────────────
append() {
  local desc="$1"; shift
  local outfile="$1"; shift
  if "$@" >> "${outfile}" 2>/dev/null; then
    ok "${desc}"
  else
    warn "${desc} (部分受限)"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║     MacSecCollect — macOS 安全取证数据采集工具        ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
echo -e "  采集时间: $(date)"
echo -e "  主机名称: ${HOSTNAME}"
echo -e "  输出目录: ${OUTPUT_DIR}"
echo -e "  ${YELLOW}本工具不联网 · 不全盘扫描 · 只采集 · 不判断${RESET}\n"

# ── 通过 osascript 弹窗获取管理员密码 ──
# Electron 环境没有交互终端，必须用 GUI 方式获取密码
PASSWORD=""
if [ -t 0 ]; then
  # 有终端时直接 sudo -v
  sudo -v 2>/dev/null || warn "未获得 sudo 权限，部分系统级数据将跳过"
else
  # Electron 调用时：osascript 弹窗获取密码
  PASSWORD=$(osascript -e '
    tell application "System Events"
      display dialog "请输入管理员密码以采集系统安全数据" ¬
        with hidden answer ¬
        default answer "" ¬
        buttons {"取消", "确定"} ¬
        default button 2 ¬
        with title "MacSecCollect"
    end tell
    text returned of result
  ' 2>/dev/null) || true

  if [ -n "$PASSWORD" ]; then
    echo "$PASSWORD" | sudo -S -v 2>/dev/null || warn "密码验证失败，部分系统级数据将跳过"
  else
    warn "未输入密码，部分系统级数据将跳过"
  fi
fi

# 保持 sudo 会话（后台刷新）
if sudo -n true 2>/dev/null; then
  ( while true; do sudo -n true; sleep 50; done ) 2>/dev/null &
  SUDO_PID=$!
else
  SUDO_PID=""
fi
trap 'kill $SUDO_PID 2>/dev/null; echo -e "\n${RED}中断，已清理后台进程${RESET}"' EXIT INT TERM

# ── 创建目录结构 ───────────────────────────────────────────────────────────────
mkdir -p "${OUTPUT_DIR}"/{01_system_info,02_processes,03_network,04_persistence,05_users_auth,\
06_remote_access,07_logs,08_files_dirs,09_browser_artifacts,10_malware_hints}

# ═══════════════════════════════════════════════════════════════════════════════
# 00. META — 给 AI 的说明文件
# ═══════════════════════════════════════════════════════════════════════════════
cat > "${OUTPUT_DIR}/AI_ANALYSIS_PROMPT.md" << 'PROMPT_EOF'
# MacSecCollect 安全分析请求

## 你是谁 / 你需要做什么

你是一名专业的 macOS 安全分析师。你收到了来自 MacSecCollect 工具采集的压缩包内容。
该工具在用户的 Mac 电脑上运行，**只做数据采集，不做判断**。
现在需要你对这些数据进行全面安全分析，判断该设备是否存在以下威胁：

1. **木马 / 恶意软件** — 可疑进程、异常父子进程关系、不明二进制
2. **持久化后门** — 自启动项（LaunchAgent/LaunchDaemon/LoginItem）中的可疑条目
3. **肉鸡控制** — C2 通信迹象、异常出站连接、反向 shell、隐藏代理
4. **权限篡改** — sudoers 修改、SSH 密钥异常、用户账号变化
5. **远程控制** — 未经授权的 SSH/VNC/屏幕共享/ARD 开启
6. **信息窃取** — 对浏览器 Cookies/密码数据库的异常访问
7. **内核级威胁** — 可疑的内核扩展、驱动、系统完整性状态

## 分析结构

请按以下结构输出报告（中文）：

### 🔴 高危发现（如有）
列出最严重的威胁迹象，需要立即处理。

### 🟡 可疑项目（需关注）
列出值得怀疑但需进一步验证的内容。

### 🟢 正常 / 低风险
总结整体安全状态。

### 📋 详细分析
按各数据类别逐项分析。

### 🔧 建议操作
具体的修复/验证步骤。

## 压缩包目录说明

| 目录 | 内容 |
|------|------|
| 01_system_info/ | 系统版本、SIP状态、硬件信息、已安装应用 |
| 02_processes/ | 当前进程列表、进程树、开放文件句柄 |
| 03_network/ | 活跃连接、监听端口、路由、DNS、防火墙 |
| 04_persistence/ | 所有自启动项（LaunchAgent/Daemon/LoginItem/cron） |
| 05_users_auth/ | 用户账号、SSH密钥、sudo配置、认证日志 |
| 06_remote_access/ | ARD/VNC/SSH状态、屏幕共享配置 |
| 07_logs/ | 系统日志、安全日志、登录历史 |
| 08_files_dirs/ | 临时目录内容、可疑路径、隐藏文件 |
| 09_browser_artifacts/ | 浏览器扩展列表（非内容） |
| 10_malware_hints/ | macOS安全工具（XProtect/MRT/Gatekeeper）状态 |

---
*由 MacSecCollect v1.0 生成 · 采集时间见各文件头部*
PROMPT_EOF

ok "已生成 AI 分析提示词文件"

# ═══════════════════════════════════════════════════════════════════════════════
# 01. 系统基础信息
# ═══════════════════════════════════════════════════════════════════════════════
step "【系统信息】收集基础系统信息"
DIR="${OUTPUT_DIR}/01_system_info"

{
  echo "=== macOS 版本 ==="
  sw_vers 2>/dev/null
  echo ""
  echo "=== 系统正常运行时间 ==="
  uptime 2>/dev/null
  echo ""
  echo "=== 硬件概览 ==="
  system_profiler SPHardwareDataType 2>/dev/null
  echo ""
  echo "=== 内核版本 ==="
  uname -a 2>/dev/null
} > "${DIR}/system_overview.txt" 2>/dev/null
ok "系统概览"

# SIP 状态
run "系统完整性保护 (SIP) 状态" "${DIR}/sip_status.txt" csrutil status

# 已安装应用（不含内容，只列表）
{
  echo "=== /Applications 目录应用列表 ==="
  ls -la /Applications/ 2>/dev/null
  echo ""
  echo "=== ~/Applications 目录应用列表 ==="
  ls -la ~/Applications/ 2>/dev/null
  echo ""
  echo "=== Homebrew 安装的软件包 ==="
  brew list 2>/dev/null || echo "(Homebrew 未安装或不可用)"
  echo ""
  echo "=== Mac App Store 安装记录 ==="
  find /private/var/folders -name "*.receipt" -maxdepth 8 2>/dev/null | head -50
} > "${DIR}/installed_apps.txt" 2>/dev/null
ok "已安装应用列表"

# 内核扩展
{
  echo "=== 已加载内核扩展 ==="
  kextstat 2>/dev/null || echo "kextstat 不可用 (macOS 12+ 使用 systemextensionsctl)"
  echo ""
  echo "=== 系统扩展 ==="
  systemextensionsctl list 2>/dev/null
} > "${DIR}/kernel_extensions.txt" 2>/dev/null
ok "内核扩展/系统扩展"

# ═══════════════════════════════════════════════════════════════════════════════
# 02. 进程信息
# ═══════════════════════════════════════════════════════════════════════════════
step "【进程】采集所有运行进程"
DIR="${OUTPUT_DIR}/02_processes"

# 详细进程列表（包含用户、PID、CPU、内存、启动时间、命令行）
run "完整进程列表 (ps aux)" "${DIR}/ps_aux.txt" \
  ps aux

# 进程树
run "进程树 (ps axjf 风格)" "${DIR}/ps_tree.txt" \
  ps axo pid,ppid,user,stat,start,time,comm,args

# 按 CPU 使用率排序
{
  echo "=== 按 CPU 使用率排序的进程 (Top 50) ==="
  ps aux --sort=-%cpu 2>/dev/null | head -51 || \
  ps aux -r 2>/dev/null | head -51
} > "${DIR}/top_cpu_processes.txt" 2>/dev/null
ok "CPU占用 Top 进程"

# 开放文件句柄（重点：网络 socket、可执行文件、删除的文件）
{
  echo "=== 所有开放文件句柄 (lsof) ==="
  echo "注意：(deleted) 标记的可执行文件可能是内存中运行的恶意程序"
  lsof 2>/dev/null
} > "${DIR}/lsof_all.txt" 2>/dev/null &   # 后台运行，lsof 较慢
ok "开放文件句柄（后台采集中）"

# 正在运行的可执行文件路径
{
  echo "=== 当前进程的可执行文件路径 ==="
  ps axo pid,comm,args | grep -v "^PID" 2>/dev/null
} > "${DIR}/process_executables.txt" 2>/dev/null
ok "进程可执行路径"

# ═══════════════════════════════════════════════════════════════════════════════
# 03. 网络信息
# ═══════════════════════════════════════════════════════════════════════════════
step "【网络】采集网络连接与配置"
DIR="${OUTPUT_DIR}/03_network"

# 活跃网络连接（最重要：看 ESTABLISHED 和 CLOSE_WAIT）
{
  echo "=== 活跃网络连接 (netstat) ==="
  netstat -anv 2>/dev/null
} > "${DIR}/netstat_all.txt" 2>/dev/null
ok "netstat 活跃连接"

# lsof 网络连接（包含进程名）
{
  echo "=== 网络连接 + 对应进程 (lsof -i) ==="
  echo "格式: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME"
  lsof -i -n -P 2>/dev/null
} > "${DIR}/lsof_network.txt" 2>/dev/null
ok "lsof 网络连接（含进程名）"

# 监听端口
{
  echo "=== 所有监听端口 ==="
  netstat -an 2>/dev/null | grep LISTEN
  echo ""
  echo "=== UDP 监听 ==="
  netstat -an 2>/dev/null | grep udp
} > "${DIR}/listening_ports.txt" 2>/dev/null
ok "监听端口"

# 网络接口
{
  echo "=== 网络接口配置 ==="
  ifconfig 2>/dev/null
  echo ""
  echo "=== 路由表 ==="
  netstat -rn 2>/dev/null
  echo ""
  echo "=== ARP 缓存 ==="
  arp -a 2>/dev/null
} > "${DIR}/network_interfaces.txt" 2>/dev/null
ok "网络接口与路由"

# DNS 配置
{
  echo "=== DNS 服务器配置 ==="
  scutil --dns 2>/dev/null
  echo ""
  echo "=== /etc/hosts 文件 ==="
  cat /etc/hosts 2>/dev/null
  echo ""
  echo "=== /etc/resolv.conf ==="
  cat /etc/resolv.conf 2>/dev/null
} > "${DIR}/dns_config.txt" 2>/dev/null
ok "DNS 配置与 hosts 文件"

# 防火墙状态
{
  echo "=== macOS 应用防火墙状态 ==="
  /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null
  /usr/libexec/ApplicationFirewall/socketfilterfw --listapps 2>/dev/null
  echo ""
  echo "=== pfctl 包过滤防火墙 ==="
  sudo pfctl -s rules 2>/dev/null || echo "(需要 sudo 权限或 pf 未启用)"
  echo ""
  echo "=== 防火墙配置文件 ==="
    sudo defaults read /Library/Preferences/com.apple.alf 2>/dev/null || true
} > "${DIR}/firewall_status.txt" 2>/dev/null
ok "防火墙状态"

# 系统代理设置
{
  echo "=== 系统网络代理配置 ==="
  scutil --proxy 2>/dev/null
  echo ""
  echo "=== 环境变量中的代理 ==="
  env | grep -i proxy 2>/dev/null || echo "无代理环境变量"
} > "${DIR}/proxy_settings.txt" 2>/dev/null
ok "代理设置"

# ═══════════════════════════════════════════════════════════════════════════════
# 04. 持久化 / 自启动项（关键！）
# ═══════════════════════════════════════════════════════════════════════════════
step "【持久化】采集所有自启动项（LaunchAgent/Daemon/LoginItem/cron）"
DIR="${OUTPUT_DIR}/04_persistence"

# LaunchAgents — 用户级
{
  echo "=== 用户 LaunchAgents (~/) ==="
  ls -la ~/Library/LaunchAgents/ 2>/dev/null && \
  cat ~/Library/LaunchAgents/*.plist 2>/dev/null || echo "(空)"
  echo ""
  echo "=== 系统 LaunchAgents (/Library/) ==="
  ls -la /Library/LaunchAgents/ 2>/dev/null
  echo ""
  for f in /Library/LaunchAgents/*.plist 2>/dev/null; do
    [ -f "$f" ] && echo "--- $f ---" && cat "$f" 2>/dev/null
  done
} > "${DIR}/launch_agents.txt" 2>/dev/null
ok "LaunchAgents"

# LaunchDaemons — 系统级（高权限）
{
  echo "=== 系统 LaunchDaemons (/Library/) ==="
  ls -la /Library/LaunchDaemons/ 2>/dev/null
  echo ""
  for f in /Library/LaunchDaemons/*.plist 2>/dev/null; do
        [ -f "$f" ] && echo "--- $f ---" && sudo cat "$f" 2>/dev/null || true
  done
  echo ""
  echo "=== /System/Library/LaunchDaemons (系统自带，通常可信) ==="
  ls /System/Library/LaunchDaemons/ 2>/dev/null | head -30
  echo "... (仅显示前30项，系统内置项)"
} > "${DIR}/launch_daemons.txt" 2>/dev/null
ok "LaunchDaemons"

# 登录项（Login Items）
{
  echo "=== 登录项 (osascript) ==="
  osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null
  echo ""
  echo "=== 服务管理框架登录项 (SMAppServiceStatusEnabled) ==="
  # macOS 13+ 新机制
  sfltool dumpfull 2>/dev/null | grep -A5 "loginItems" | head -50 || echo "(不适用)"
  echo ""
  echo "=== /Library/LaunchDaemons 和 /Library/LaunchAgents 的非Apple签名项 ==="
  ls -la /Library/LaunchDaemons/ /Library/LaunchAgents/ 2>/dev/null | grep -v "com.apple"
} > "${DIR}/login_items.txt" 2>/dev/null
ok "登录项"

# Crontab
{
  echo "=== 当前用户 crontab ==="
  crontab -l 2>/dev/null || echo "(无 crontab)"
  echo ""
  echo "=== root crontab ==="
  sudo crontab -l 2>/dev/null || echo "(无 root crontab 或权限不足)"
  echo ""
  echo "=== /etc/crontab ==="
  cat /etc/crontab 2>/dev/null || echo "(不存在)"
  echo ""
  echo "=== /etc/periodic/ ==="
  ls -la /etc/periodic/daily/ /etc/periodic/weekly/ /etc/periodic/monthly/ 2>/dev/null
  echo ""
  echo "=== /var/at/tabs/ ==="
  sudo ls -la /var/at/tabs/ 2>/dev/null || echo "(权限不足)"
} > "${DIR}/crontab_periodic.txt" 2>/dev/null
ok "Crontab 和定期任务"

# StartupItems（老版本 macOS）
{
  echo "=== StartupItems (Legacy) ==="
  ls -la /Library/StartupItems/ 2>/dev/null || echo "(目录不存在)"
  ls -la /System/Library/StartupItems/ 2>/dev/null || echo "(目录不存在)"
} > "${DIR}/startup_items_legacy.txt" 2>/dev/null
ok "StartupItems (旧版)"

# ═══════════════════════════════════════════════════════════════════════════════
# 05. 用户 & 认证
# ═══════════════════════════════════════════════════════════════════════════════
step "【用户认证】采集用户账号、SSH 配置、sudo 权限"
DIR="${OUTPUT_DIR}/05_users_auth"

# 用户列表
{
  echo "=== 本地用户账号 (dscl) ==="
  dscl . list /Users 2>/dev/null
  echo ""
  echo "=== 用户详情（admin组成员）==="
  dscl . read /Groups/admin GroupMembership 2>/dev/null
  echo ""
  echo "=== /etc/passwd ==="
  cat /etc/passwd 2>/dev/null
  echo ""
  echo "=== 用户登录 Shell ==="
  dscl . -list /Users UserShell 2>/dev/null
  echo ""
  echo "=== 最近创建的用户 ==="
  ls -lt /Users/ 2>/dev/null
} > "${DIR}/user_accounts.txt" 2>/dev/null
ok "用户账号信息"

# SSH 配置（重要！检查授权密钥）
{
  echo "=== SSH 客户端配置 (~/.ssh/config) ==="
  cat ~/.ssh/config 2>/dev/null || echo "(不存在)"
  echo ""
  echo "=== 已授权公钥 (~/.ssh/authorized_keys) ==="
  echo "【警告】以下公钥被允许免密码 SSH 登录本机！"
  cat ~/.ssh/authorized_keys 2>/dev/null || echo "(不存在)"
  echo ""
  echo "=== SSH 公钥列表 (~/.ssh/) ==="
  ls -la ~/.ssh/ 2>/dev/null || echo "(目录不存在)"
  echo ""
  echo "=== /etc/ssh/sshd_config ==="
  sudo cat /etc/ssh/sshd_config 2>/dev/null || cat /etc/ssh/sshd_config 2>/dev/null || echo "(权限不足)"
  echo ""
  echo "=== root SSH 授权密钥 ==="
  sudo cat /root/.ssh/authorized_keys 2>/dev/null || echo "(不存在或权限不足)"
  echo ""
  echo "=== 系统级 authorized_keys ==="
  sudo find /etc /private/etc -name "authorized_keys" 2>/dev/null | while read f; do
        echo "--- $f ---"; sudo cat "$f" 2>/dev/null || true
  done
} > "${DIR}/ssh_config.txt" 2>/dev/null
ok "SSH 配置与授权密钥"

# Sudo 配置
{
  echo "=== /etc/sudoers ==="
  sudo cat /etc/sudoers 2>/dev/null || echo "(权限不足)"
  echo ""
  echo "=== /etc/sudoers.d/ ==="
    sudo ls -la /etc/sudoers.d/ 2>/dev/null || true
  for f in $(sudo ls /etc/sudoers.d/ 2>/dev/null); do
    echo "--- /etc/sudoers.d/$f ---"
        sudo cat "/etc/sudoers.d/$f" 2>/dev/null || true
  done
} > "${DIR}/sudoers.txt" 2>/dev/null
ok "Sudo 配置"

# 认证日志（过去 72 小时）
{
  echo "=== 最近 SSH 登录历史 ==="
  last 2>/dev/null | head -50
  echo ""
  echo "=== 最近失败的登录尝试 ==="
  lastb 2>/dev/null | head -30 || echo "(lastb 不可用)"
  echo ""
  echo "=== who 当前登录 ==="
  who 2>/dev/null
  echo ""
  echo "=== w 当前会话 ==="
  w 2>/dev/null
} > "${DIR}/login_history.txt" 2>/dev/null
ok "登录历史"

# 认证日志文件
{
  echo "=== /var/log/auth.log (最后 200 行) ==="
  sudo tail -200 /var/log/auth.log 2>/dev/null || echo "(不存在)"
  echo ""
  echo "=== 通过 log 命令查询认证事件 (最近72小时) ==="
  log show --predicate 'eventMessage contains "authentication"' \
    --last 72h 2>/dev/null | tail -100 || echo "(log 命令失败)"
  echo ""
  echo "=== sudo 使用历史 ==="
  log show --predicate 'eventMessage contains "sudo"' \
    --last 72h 2>/dev/null | tail -50 || echo "(log 命令失败)"
} > "${DIR}/auth_logs.txt" 2>/dev/null
ok "认证日志"

# ═══════════════════════════════════════════════════════════════════════════════
# 06. 远程访问服务
# ═══════════════════════════════════════════════════════════════════════════════
step "【远程访问】检查 SSH/VNC/屏幕共享/ARD 状态"
DIR="${OUTPUT_DIR}/06_remote_access"

{
  echo "=== SSH 服务 (Remote Login) 状态 ==="
  sudo systemsetup -getremotelogin 2>/dev/null || \
  launchctl list com.openssh.sshd 2>/dev/null || echo "无法获取 SSH 状态"
  echo ""
  
  echo "=== 屏幕共享 / VNC 服务状态 ==="
  sudo launchctl list com.apple.screensharing 2>/dev/null || echo "屏幕共享未运行"
  sudo defaults read /var/db/launchd.db/com.apple.launchd/overrides.plist 2>/dev/null | \
    grep -A2 "screensharing" || echo "(无法读取)"
  echo ""
  
  echo "=== Apple Remote Desktop (ARD) 状态 ==="
  sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -configure -access -on 2>/dev/null | head -5 || echo "ARD 未安装或未运行"
  sudo launchctl list com.apple.RemoteDesktop.agent 2>/dev/null || echo "ARD Agent 未运行"
  echo ""
  
  echo "=== 远程管理系统偏好 ==="
  sudo defaults read /Library/Preferences/com.apple.RemoteDesktop.plist 2>/dev/null || \
    echo "(ARD plist 不存在)"
  echo ""
  
  echo "=== 所有正在监听的网络服务（用于确认哪些远程访问端口开放）==="
  netstat -an 2>/dev/null | grep LISTEN
  echo ""
  
  echo "=== 检查 5900 端口 (VNC) ==="
  netstat -an 2>/dev/null | grep "5900\|22\|5988\|3283" || echo "相关端口无监听"
  echo ""
  
  echo "=== Sharing 偏好设置 ==="
  sudo systemsetup -printSettings 2>/dev/null || echo "(无法获取)"
  
  echo ""
  echo "=== 检查 ngrok / frp / zerotier 等穿透工具进程 ==="
  ps aux 2>/dev/null | grep -E "ngrok|frp|zerotier|tailscale|hamachi|playit" | grep -v grep || echo "未发现已知穿透工具进程"
  
  echo ""
  echo "=== 检查常见穿透工具自启动项 ==="
  ls ~/Library/LaunchAgents/ /Library/LaunchAgents/ /Library/LaunchDaemons/ 2>/dev/null | \
    grep -E "ngrok|frp|zerotier|tailscale|hamachi" || echo "未发现穿透工具自启动项"
} > "${DIR}/remote_access_status.txt" 2>/dev/null
ok "远程访问服务状态"

# ═══════════════════════════════════════════════════════════════════════════════
# 07. 系统日志
# ═══════════════════════════════════════════════════════════════════════════════
step "【日志】采集系统日志、安全日志"
DIR="${OUTPUT_DIR}/07_logs"

# 统一日志系统（最近48小时关键事件）
{
  echo "=== 系统错误和警告（最近48小时）==="
  log show --last 48h --predicate 'messageType == 16 or messageType == 17' \
    2>/dev/null | tail -200 || echo "(log 命令不可用)"
} > "${DIR}/system_errors_48h.txt" 2>/dev/null
ok "系统错误日志"

{
  echo "=== 进程启动/终止日志（最近48小时）==="
  log show --last 48h --predicate 'subsystem == "com.apple.launchd"' \
    2>/dev/null | tail -500 || echo "(log 命令不可用)"
} > "${DIR}/launchd_log_48h.txt" 2>/dev/null
ok "launchd 日志"

{
  echo "=== 安全相关日志（SIP/Gatekeeper/XProtect）==="
  log show --last 72h \
    --predicate 'subsystem contains "security" or subsystem contains "xprotect" or subsystem contains "gatekeeper"' \
    2>/dev/null | tail -200 || echo "(log 命令不可用)"
} > "${DIR}/security_framework_logs.txt" 2>/dev/null
ok "安全框架日志"

# /var/log/ 下的传统日志
{
  echo "=== /var/log/ 目录列表 ==="
  ls -lt /var/log/ 2>/dev/null
  echo ""
  echo "=== /var/log/system.log (最后200行) ==="
  sudo tail -200 /var/log/system.log 2>/dev/null || echo "(不存在或权限不足)"
  echo ""
  echo "=== /var/log/install.log (最近安装记录) ==="
  sudo tail -100 /var/log/install.log 2>/dev/null || echo "(不存在)"
} > "${DIR}/var_log_files.txt" 2>/dev/null
ok "/var/log 系统日志"

# 应用崩溃报告（可能包含恶意软件迹象）
{
  echo "=== 最近的崩溃报告 ==="
  ls -lt ~/Library/Logs/DiagnosticReports/ 2>/dev/null | head -30
  ls -lt /Library/Logs/DiagnosticReports/ 2>/dev/null | head -20
} > "${DIR}/crash_reports_list.txt" 2>/dev/null
ok "崩溃报告列表"

# ═══════════════════════════════════════════════════════════════════════════════
# 08. 文件系统可疑路径
# ═══════════════════════════════════════════════════════════════════════════════
step "【文件】检查可疑路径和临时目录"
DIR="${OUTPUT_DIR}/08_files_dirs"

# 临时目录内容（恶意软件常驻留于此）
{
  echo "=== /tmp/ 目录内容 ==="
  ls -laR /tmp/ 2>/dev/null | head -100
  echo ""
  echo "=== /var/tmp/ 目录内容 ==="
  ls -laR /var/tmp/ 2>/dev/null | head -50
  echo ""
  echo "=== ~/Downloads/ 最近文件（最近30天）==="
  find ~/Downloads -newer ~/Downloads -maxdepth 2 -type f 2>/dev/null | head -50
  find ~/Downloads -maxdepth 2 -type f -mtime -30 2>/dev/null | head -50
} > "${DIR}/temp_and_downloads.txt" 2>/dev/null
ok "临时目录与下载"

# 隐藏文件/目录
{
  echo "=== 主目录下的隐藏文件 ==="
  ls -la ~/ 2>/dev/null | grep "^\."
  echo ""
  echo "=== /Library/ 下异常目录 ==="
  ls -la /Library/ 2>/dev/null
  echo ""
  echo "=== ~/Library/ 下目录列表 ==="
  ls -la ~/Library/ 2>/dev/null
} > "${DIR}/hidden_files_dirs.txt" 2>/dev/null
ok "隐藏文件检查"

# 最近修改的系统文件（可能被篡改）
{
  echo "=== 最近7天被修改的 /usr/local/bin/ 文件 ==="
  find /usr/local/bin /usr/local/sbin -type f -mtime -7 2>/dev/null | head -30
  echo ""
  echo "=== 最近7天被修改的 /etc/ 文件 ==="
  find /etc /private/etc -type f -mtime -7 2>/dev/null | head -30
  echo ""
  echo "=== 最近7天 /Library/LaunchAgents/ 变化 ==="
  find /Library/LaunchAgents ~/Library/LaunchAgents -type f -mtime -7 2>/dev/null | head -20
  echo ""
  echo "=== 最近7天 /Library/LaunchDaemons/ 变化 ==="
  find /Library/LaunchDaemons -type f -mtime -7 2>/dev/null | head -20
} > "${DIR}/recently_modified.txt" 2>/dev/null
ok "最近修改的关键文件"

# 可执行的可疑位置
{
  echo "=== /usr/local/bin/ 内容 ==="
  ls -la /usr/local/bin/ 2>/dev/null
  echo ""
  echo "=== ~/bin/ 内容（如果存在）==="
  ls -la ~/bin/ 2>/dev/null || echo "(不存在)"
  echo ""
  echo "=== PATH 环境变量 ==="
  echo $PATH
  echo ""
  echo "=== .bash_profile / .zshrc / .profile 内容 ==="
  echo "--- ~/.bash_profile ---"
  cat ~/.bash_profile 2>/dev/null || echo "(不存在)"
  echo "--- ~/.zshrc ---"
  cat ~/.zshrc 2>/dev/null || echo "(不存在)"
  echo "--- ~/.profile ---"
  cat ~/.profile 2>/dev/null || echo "(不存在)"
  echo "--- ~/.bashrc ---"
  cat ~/.bashrc 2>/dev/null || echo "(不存在)"
  echo "--- ~/.zprofile ---"
  cat ~/.zprofile 2>/dev/null || echo "(不存在)"
} > "${DIR}/executables_and_shell_config.txt" 2>/dev/null
ok "可执行文件路径与 Shell 配置"

# ═══════════════════════════════════════════════════════════════════════════════
# 09. 浏览器相关（仅扩展列表，不含密码内容）
# ═══════════════════════════════════════════════════════════════════════════════
step "【浏览器】采集浏览器扩展列表"
DIR="${OUTPUT_DIR}/09_browser_artifacts"

{
  echo "=== Chrome 扩展目录 ==="
  ls ~/Library/Application\ Support/Google/Chrome/Default/Extensions/ 2>/dev/null || echo "(Chrome 未安装)"
  echo ""
  echo "=== Chrome 扩展 manifest.json 摘要 (名称) ==="
  find ~/Library/Application\ Support/Google/Chrome/Default/Extensions/ \
    -name "manifest.json" -maxdepth 3 2>/dev/null | \
    xargs grep -l '"name"' 2>/dev/null | head -20 | \
    xargs -I{} sh -c 'echo "=={}: "; python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get(\"name\",\"?\"), \"|version:\", d.get(\"version\",\"?\"), \"|permissions:\", d.get(\"permissions\",[]))" "$@"' -- {} 2>/dev/null | head -100
  echo ""
  echo "=== Safari 扩展 ==="
  ls ~/Library/Safari/Extensions/ 2>/dev/null || echo "(无 Safari 扩展)"
  echo ""
  echo "=== Firefox 扩展 ==="
  find ~/Library/Application\ Support/Firefox/Profiles/ \
    -name "extensions.json" -maxdepth 4 2>/dev/null | \
    xargs grep -o '"name":"[^"]*"' 2>/dev/null | head -30 || echo "(Firefox 未安装)"
  echo ""
  echo "=== Chrome 历史文件修改时间（不读内容）==="
  ls -la ~/Library/Application\ Support/Google/Chrome/Default/History 2>/dev/null
  echo ""
  echo "=== 注意：浏览器 Cookies/密码等敏感文件不在采集范围内 ==="
} > "${DIR}/browser_extensions.txt" 2>/dev/null
ok "浏览器扩展列表"

# ═══════════════════════════════════════════════════════════════════════════════
# 10. macOS 内置安全工具状态
# ═══════════════════════════════════════════════════════════════════════════════
step "【安全机制】检查 macOS 内置安全工具状态"
DIR="${OUTPUT_DIR}/10_malware_hints"

{
  echo "=== Gatekeeper 状态 ==="
  spctl --status 2>/dev/null || echo "无法获取"
  echo ""
  
  echo "=== XProtect 版本 ==="
  defaults read /Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Resources/XProtect.meta.plist \
    2>/dev/null || echo "(无法读取 XProtect 元数据)"
  echo ""
  
  echo "=== MRT (Malware Removal Tool) 版本 ==="
  defaults read /Library/Apple/System/Library/CoreServices/MRT.app/Contents/version.plist \
    2>/dev/null || echo "(无法读取 MRT 版本)"
  echo ""
  
  echo "=== 隔离标志扩展属性（Quarantine）检查 ==="
  echo "以下为 ~/Downloads 中有隔离标志的最近文件："
  find ~/Downloads -xattr 2>/dev/null | xargs xattr -l 2>/dev/null | \
    grep -B1 "com.apple.quarantine" | head -30 || echo "(无法获取)"
  echo ""
  
  echo "=== 检查 /private/var/db/ 下的 XProtect 扫描日志 ==="
  ls -la /private/var/db/xprotect/ 2>/dev/null || echo "(目录不存在)"
  echo ""
  
  echo "=== 用户通知中心权限（可能被滥用）==="
  sqlite3 ~/Library/Containers/com.apple.notificationcenter/Data/Library/Application\ Support/\
com.apple.notificationcenter/db2/db \
    "SELECT app_id, flags FROM app_info LIMIT 30" 2>/dev/null || echo "(数据库不可访问)"
  echo ""
  
  echo "=== 检查是否有可疑进程持有 TCC 权限 ==="
  # TCC = Transparency, Consent, and Control (隐私权限数据库)
  sudo sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
    "SELECT client, service, auth_value FROM access WHERE auth_value=2 LIMIT 50" \
    2>/dev/null || echo "(需要 Full Disk Access 权限)"
  echo ""
  
  echo "=== Keychain 访问日志迹象 ==="
  log show --last 24h \
    --predicate 'subsystem == "com.apple.securityd" and eventMessage contains "keychain"' \
    2>/dev/null | tail -30 || echo "(log 命令失败)"
  echo ""
  
  echo "=== 剪贴板历史（用于检查 ClickFix 类攻击迹象）==="
  echo "注意：ClickFix 攻击会诱导用户从剪贴板粘贴并执行恶意命令"
  osascript -e 'the clipboard' 2>/dev/null | head -5 || echo "(无法获取剪贴板)"
  echo ""
  
  echo "=== 检查 /tmp/ 中的可执行文件（恶意软件常见驻留点）==="
  find /tmp /var/tmp -type f -perm +111 2>/dev/null | head -20 || echo "(无可执行文件)"
  echo ""
  
  echo "=== 检查 ~/Library/Application Support/ 下的异常目录 ==="
  ls -lt ~/Library/Application\ Support/ 2>/dev/null | head -30
} > "${DIR}/macos_security_tools.txt" 2>/dev/null
ok "macOS 安全机制状态"

# 额外：检查常见 macOS 恶意软件 IOC 路径
{
  echo "=== 常见 macOS 恶意软件 IOC 路径检查 ==="
  echo "(以下路径如果存在文件，可能是已知恶意软件的驻留点)"
  
  SUSPICIOUS_PATHS=(
    "/Library/LaunchAgents/com.adobe.GC.Invoker-1.0.plist"
    "/Library/LaunchAgents/com.apple.Safari.plist"
    "/Library/LaunchDaemons/com.apple.updated.plist"
    "/Library/LaunchDaemons/com.apple.mdworker.plist"
    "~/.config/autostart"
    "/tmp/runner"
    "/tmp/payload"
    "~/Library/LaunchAgents/com.apple.mail.plist"
    "/Library/Application Support/com.apple.TCC/TCC.db"
    "~/Library/Application Support/Google/Chrome/Default/Extensions/cjpalhdlnbpafiamejdnhcphjbkeiagm"
  )
  
  for path in "${SUSPICIOUS_PATHS[@]}"; do
    expanded_path=$(eval echo "$path")
    if [ -e "$expanded_path" ]; then
      echo "[存在!] $path"
      ls -la "$expanded_path" 2>/dev/null
    else
      echo "[ 正常] $path (不存在)"
    fi
  done
  
  echo ""
  echo "=== 非 Apple 签名的 LaunchDaemons（重点检查）==="
  for f in /Library/LaunchDaemons/*.plist; do
    [ -f "$f" ] && codesign -v "$f" 2>&1 | grep -q "Apple" && echo "[Apple签名] $f" || echo "[非Apple/未签名] $f"
  done 2>/dev/null
  
} > "${DIR}/ioc_path_check.txt" 2>/dev/null
ok "IOC 路径检查"

# ═══════════════════════════════════════════════════════════════════════════════
# 等待 lsof 后台任务完成
# ═══════════════════════════════════════════════════════════════════════════════
step "等待后台采集任务完成..."
wait
ok "所有采集任务完成"

# ═══════════════════════════════════════════════════════════════════════════════
# 生成摘要索引
# ═══════════════════════════════════════════════════════════════════════════════
step "生成数据摘要"

{
  echo "# MacSecCollect 采集摘要"
  echo ""
  echo "**采集时间**: $(date)"
  echo "**主机名**: ${HOSTNAME}"
  echo "**macOS 版本**: $(sw_vers -productVersion 2>/dev/null)"
  echo "**当前用户**: $(whoami)"
  echo ""
  echo "## 采集文件清单"
  echo ""
  find "${OUTPUT_DIR}" -type f | sort | while read f; do
    size=$(du -h "$f" 2>/dev/null | cut -f1)
    echo "- \`${f#${OUTPUT_DIR}/}\` (${size})"
  done
  echo ""
  echo "## 快速关注点"
  echo ""
  echo "### 网络连接数量"
  wc -l < "${OUTPUT_DIR}/03_network/netstat_all.txt" 2>/dev/null | xargs -I{} echo "- netstat 行数: {}"
  echo ""
  echo "### 监听端口"
  grep "LISTEN" "${OUTPUT_DIR}/03_network/listening_ports.txt" 2>/dev/null | head -20
  echo ""
  echo "### LaunchAgents 数量（用户级）"
  ls ~/Library/LaunchAgents/ 2>/dev/null | wc -l | xargs -I{} echo "- 用户 LaunchAgents: {} 个"
  ls /Library/LaunchAgents/ 2>/dev/null | wc -l | xargs -I{} echo "- 系统 LaunchAgents: {} 个"
  ls /Library/LaunchDaemons/ 2>/dev/null | wc -l | xargs -I{} echo "- 系统 LaunchDaemons: {} 个"
  echo ""
  echo "### SSH 配置"
  if [ -f ~/.ssh/authorized_keys ]; then
    echo "- ⚠️  存在 authorized_keys 文件！$(wc -l < ~/.ssh/authorized_keys) 行"
  else
    echo "- ✓  无 authorized_keys 文件"
  fi
} > "${OUTPUT_DIR}/SUMMARY.md" 2>/dev/null
ok "摘要索引生成完成"

# ═══════════════════════════════════════════════════════════════════════════════
# 打包压缩
# ═══════════════════════════════════════════════════════════════════════════════
step "压缩打包所有采集数据"

cd "${HOME}/Desktop"
zip -r "${ARCHIVE_NAME}" "$(basename ${OUTPUT_DIR})" -q 2>/dev/null && \
  rm -rf "${OUTPUT_DIR}" && \
  ok "压缩完成，原始目录已清理" || \
  warn "压缩失败，原始目录保留在 ${OUTPUT_DIR}"

# ═══════════════════════════════════════════════════════════════════════════════
# 完成
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║              ✅  采集完成！                           ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo -e ""
echo -e "  ${BOLD}压缩包位置:${RESET} ${HOME}/Desktop/${ARCHIVE_NAME}"
ARCHIVE_SIZE=$(du -h "${HOME}/Desktop/${ARCHIVE_NAME}" 2>/dev/null | cut -f1)
echo -e "  ${BOLD}压缩包大小:${RESET} ${ARCHIVE_SIZE}"
echo -e ""
echo -e "${BOLD}下一步操作:${RESET}"
echo -e "  1. 解压压缩包 → 将整个文件夹拖入 Claude/GPT 对话框（文件上传）"
echo -e "  2. 或者：先发送 ${CYAN}AI_ANALYSIS_PROMPT.md${RESET} 的内容作为提示词"
echo -e "  3. 再逐一上传各个 .txt 文件让 AI 分析"
echo -e "  4. AI 将给出完整的安全分析报告"
echo -e ""
echo -e "  ${YELLOW}注意: 压缩包包含系统信息，请只发给你信任的 AI 服务${RESET}"
echo -e ""

# 在 Finder 中显示
open -R "${HOME}/Desktop/${ARCHIVE_NAME}" 2>/dev/null || true

kill $SUDO_PID 2>/dev/null || true
trap - EXIT
