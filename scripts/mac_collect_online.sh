#!/usr/bin/env bash
# =============================================================================
#  MacSecCollect v2.1 — 联网采集阶段
#  采集需要网络连接才能获取的数据（断网后会消失的瞬时状态）
#  目标：30秒内完成
#  用法：mac_collect_online.sh <输出目录>
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── 输出目录（由 Electron 传入，或自动生成）──
if [ -n "${1:-}" ]; then
  OUTPUT_DIR="$1"
else
  TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
  HOSTNAME=$(hostname -s 2>/dev/null || echo "mac")
  OUTPUT_DIR="${HOME}/Desktop/MacSecCollect_${HOSTNAME}_${TIMESTAMP}"
fi

mkdir -p "${OUTPUT_DIR}"

# ── AI 分析提示词（随压缩包一起打包）──
cat > "${OUTPUT_DIR}/AI_ANALYSIS_PROMPT.md" << 'PROMPT_EOF'
# MacSecCollect 安全分析请求

## 你的角色
你是一名专业的 macOS 安全分析师。你收到了来自 MacSecCollect 工具采集的压缩包。
该工具分两阶段采集：联网阶段抓取实时网络状态，断网阶段采集本地系统数据。
请对所有文件进行全面安全分析。

## 需要判断的威胁类型
1. 木马/恶意软件 — 可疑进程、异常路径运行的程序、不明二进制
2. 持久化后门 — LaunchAgent/LaunchDaemon/LoginItem 中的可疑条目
3. 肉鸡/C2控制 — 异常出站连接、反向shell、隐藏代理、穿透工具
4. 权限篡改 — sudoers异常、SSH authorized_keys有陌生公钥
5. 远程控制 — 未经授权开启的SSH/VNC/ARD/屏幕共享
6. 信息窃取 — 可疑浏览器扩展、异常的数据访问行为
7. 系统篡改 — SIP被关闭、hosts文件被改、shell配置被植入后门

## 文件说明
| 文件 | 内容 | 重点关注 |
|------|------|---------|
| 00_SUMMARY.md | 快速摘要 | 先看这个，有关键指标 |
| 01_connections.txt | 活跃网络连接+进程名 | ESTABLISHED出站连接 |
| 02_listening.txt | 监听端口 | 非常用端口 |
| 03_dns.txt | DNS配置 | 是否被篡改 |
| 04_proxy.txt | 系统代理设置 | 有无异常代理 |
| 05_tunnels.txt | 穿透工具检查 | ngrok/frp/zerotier |
| 06_system.txt | 系统版本+SIP+内核扩展 | SIP状态、非Apple内核扩展 |
| 07_processes.txt | 进程列表 | 非系统路径的进程、/tmp运行的进程 |
| 08_persistence.txt | 所有自启动项 | ⚠️最重要！非Apple的LaunchAgent/Daemon |
| 09_auth.txt | 用户/SSH/sudo | authorized_keys有无陌生公钥 |
| 10_remote.txt | 远程访问服务状态 | SSH/VNC/ARD是否开启 |
| 11_logs.txt | 系统日志 | 异常认证、sudo滥用 |
| 12_files.txt | 可疑路径+Shell配置 | .zshrc等有无后门命令 |
| 13_security.txt | Gatekeeper+XProtect+IOC | 安全机制是否被绕过 |
| 14_crashes.txt | 崩溃报告 | 异常崩溃模式 |

## 分析重点提示
- **08_persistence.txt 最重要**，90%的持久化后门在这里
- **01_connections.txt** 看有无连接到非知名IP的进程
- **09_auth.txt** 里如果 authorized_keys 有内容必须重点分析
- **12_files.txt** 里检查 .zshrc/.bash_profile 有无 curl|wget|exec 等命令
- 进程路径在 /tmp/、/var/tmp/、隐藏目录（.开头）的高度可疑

## 输出格式（请用中文）

### 🔴 高危发现（需立即处理）
如有，列出最严重的威胁，说明位于哪个文件哪一行。

### 🟡 可疑项目（需关注）
值得怀疑但需进一步验证的内容。

### 🟢 总体安全状态
一句话总结：设备整体是否安全。

### 📋 逐文件分析
按文件逐一说明发现了什么。

### 🔧 建议操作
具体的验证或修复步骤，按优先级排列。
PROMPT_EOF
ok "AI 分析提示词已生成"

# ── 进度 ──
STEP=0; TOTAL=5
step() { STEP=$((STEP+1)); echo -e "\n${CYAN}[${STEP}/${TOTAL}]${RESET} ${BOLD}$1${RESET}"; }
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $1"; }

# ── 超时执行 ──
run() {
  local desc="$1"; local outfile="$2"; shift 2
  timeout 15 bash -c "$*" > "${outfile}" 2>/dev/null && ok "${desc}" || warn "${desc} (超时或受限)"
}

echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║   MacSecCollect v2.1 — 联网采集阶段                  ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
echo -e "  采集时间: $(date)"
echo -e "  输出目录: ${OUTPUT_DIR}\n"

# ═══════════════════════════════════════════════════════════════════════════════
step "【网络连接】活跃连接 + 进程名"
{
  echo "=== 活跃网络连接（含进程名）==="
  echo "格式: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME"
  timeout 10 lsof -i -n -P 2>/dev/null | head -100
  echo -e "\n=== ESTABLISHED 出站连接（重点：可疑外联）==="
  netstat -an 2>/dev/null | grep ESTABLISHED | head -50
} > "${OUTPUT_DIR}/01_connections.txt" 2>/dev/null
ok "网络连接"

# ═══════════════════════════════════════════════════════════════════════════════
step "【监听端口】所有 LISTEN 状态"
{
  echo "=== 监听端口（TCP）==="
  netstat -an 2>/dev/null | grep LISTEN | head -40
  echo -e "\n=== UDP 监听 ==="
  netstat -an 2>/dev/null | grep udp | head -20
  echo -e "\n=== 监听端口对应进程（lsof -i -s）==="
  timeout 10 lsof -i -s -n -P 2>/dev/null | grep LISTEN | head -30
} > "${OUTPUT_DIR}/02_listening.txt" 2>/dev/null
ok "监听端口"

# ═══════════════════════════════════════════════════════════════════════════════
step "【DNS 配置】解析设置 + hosts"
{
  echo "=== DNS 服务器配置 ==="
  scutil --dns 2>/dev/null | grep -E "nameserver|resolver" | head -20
  echo -e "\n=== /etc/hosts（检查是否被篡改重定向）==="
  grep -v "^#\|^$" /etc/hosts 2>/dev/null || echo "(只有默认项)"
  echo -e "\n=== /etc/resolv.conf ==="
  cat /etc/resolv.conf 2>/dev/null
} > "${OUTPUT_DIR}/03_dns.txt" 2>/dev/null
ok "DNS 配置"

# ═══════════════════════════════════════════════════════════════════════════════
step "【代理设置】系统代理 + 环境变量"
{
  echo "=== 系统网络代理配置 ==="
  scutil --proxy 2>/dev/null
  echo -e "\n=== 环境变量中的代理 ==="
  env | grep -i proxy 2>/dev/null || echo "无代理环境变量"
} > "${OUTPUT_DIR}/04_proxy.txt" 2>/dev/null
ok "代理设置"

# ═══════════════════════════════════════════════════════════════════════════════
step "【穿透工具】ngrok/frp/zerotier/tailscale 进程"
{
  echo "=== 穿透工具进程检查 ==="
  ps aux 2>/dev/null | grep -iE "ngrok|frp[c]?|zerotier|tailscale|hamachi|playit|cloudflared|bore|localtunnel" \
    | grep -v grep || echo "未发现穿透工具进程"
  echo -e "\n=== 穿透工具自启动项 ==="
  ls ~/Library/LaunchAgents/ /Library/LaunchAgents/ /Library/LaunchDaemons/ 2>/dev/null \
    | grep -iE "ngrok|frp|zerotier|tailscale|hamachi|playit|cloudflared" || echo "未发现穿透工具自启动项"
} > "${OUTPUT_DIR}/05_tunnels.txt" 2>/dev/null
ok "穿透工具检查"

# ── 完成 ──
echo -e "\n${GREEN}${BOLD}✅ 联网采集完成！${RESET}"
echo -e "${YELLOW}${BOLD}⚠️  请立即断开网络连接！${RESET}"
echo -e "  输出目录: ${OUTPUT_DIR}"

# 输出目录路径给 Electron 读取
echo "OUTPUT_DIR:${OUTPUT_DIR}"
