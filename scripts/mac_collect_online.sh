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
