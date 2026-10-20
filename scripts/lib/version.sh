#!/usr/bin/env bash
# =============================================================================
#  lib/version.sh — 单一版本来源
#
#  唯一可信来源是仓库根目录的 VERSION 文件。
#  package.json 的 version 字段必须与之相同（由 scripts/sync-version.js 同步，
#  并由 tests 校验；不一致时测试失败）。
#
#  Shell 脚本不得硬编码版本号，一律 source 本文件取 $MSC_VERSION。
#
#  为什么：此前 package.json=2.5.0、两个采集脚本=1.0.0，
#  导致报告里的 tool_version 与用户看到的应用版本对不上，取证时无法判断
#  到底跑的是哪一版工具。
# =============================================================================

if [ "${__MSC_VERSION_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi
__MSC_VERSION_LOADED=1

# 定位仓库根：本文件在 <root>/scripts/lib/ 下
_msc_version_root() {
  local d
  d=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)
  [ -n "$d" ] && printf '%s' "$d"
}

MSC_VERSION_FILE="${MSC_VERSION_FILE:-$(_msc_version_root)/VERSION}"

MSC_VERSION=""
if [ -f "$MSC_VERSION_FILE" ]; then
  MSC_VERSION=$(tr -d ' \t\r\n' < "$MSC_VERSION_FILE" 2>/dev/null)
fi
# 兜底：VERSION 缺失时明确标注，绝不静默填一个看起来正常的版本号
[ -z "$MSC_VERSION" ] && MSC_VERSION="0.0.0-unknown"

# 报告用：显示版本 + 版本来源，便于事后核对
msc_version_string() {
  printf '%s' "$MSC_VERSION"
}
