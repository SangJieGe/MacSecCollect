#!/usr/bin/env bash
# =============================================================================
#  lib/ioc.sh — 可维护的 IOC 检测模块
#
#  设计目标：
#    * IOC 定义与采集逻辑分离（数据驱动），以后加木马只需加一条 JSON 定义。
#    * 命中 ≠ 恶意。每条命中都带「匹配依据」和「需要人工确认的点」。
#    * 不编造哈希：只有规则里显式写了 sha256 才做哈希匹配。
#
#  IOC 定义文件格式（$MSC_IOC_DIR/<name>.json）：
#  {
#    "name": "zeff",
#    "title": "Zeff 木马（伪装安装器）",
#    "severity": "high",
#    "refs": ["https://x.threatbook.com/v5/..."],
#    "paths": [ {"path": "/tmp/installer", "note": "落地安装器"} ],
#    "path_globs": ["$HOME/Library/LaunchAgents/*zeff*"],
#    "strings": [ {"pattern": "macos.zeff.app", "where": ["logs","history","persistence","files"]} ],
#    "domains": ["macos.zeff.app"],
#    "urls": ["https://macos.zeff.app/v2/install"],
#    "sha256": []
#  }
#
# 说明：这里用 grep -F 做字面匹配，避免 regex 元字符在恶意字符串里引发误匹配。
# =============================================================================

if [ "${__MSC_IOC_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi
__MSC_IOC_LOADED=1

# ── 简易 JSON 取值（避免依赖 jq；macOS 默认无 jq）──
# 只支持本项目 IOC 文件使用的扁平结构。
_msc_json_array_strings() {
  # $1 = json file, $2 = key → 每行一个字符串（去掉引号/逗号）
  awk -v key="\"$2\"" '
    BEGIN { inside=0; depth=0 }
    {
      line=$0
      if (!inside) {
        idx = index(line, key)
        if (idx > 0) {
          rest = substr(line, idx + length(key))
          if (index(rest, "[") > 0) { inside=1; depth=1 }
          # 同一行就闭合的情况（空数组）
          if (inside && index(rest, "]") > 0) { inside=0 }
        }
        next
      }
      if (index(line, "]") > 0 && depth==1) { inside=0; next }
      gsub(/^[ \t]+|[ \t\r,]+$/, "", line)
      gsub(/^"|"$/, "", line)
      if (line != "") print line
    }' "$1" 2>/dev/null
}

# 从 paths 数组里抽 path 字段
_msc_json_object_field() {
  # $1 = json file, $2 = key(array), $3 = 希望取的对象字段
  awk -v key="\"$2\"" -v field="\"$3\"" '
    BEGIN { inside=0 }
    {
      line=$0
      if (!inside) { if (index(line, key) > 0) inside=1; next }
      if (index(line, "]") > 0 && index(line, field) == 0) { inside=0; next }
      idx = index(line, field)
      if (idx > 0) {
        rest = substr(line, idx + length(field))
        sub(/^[ \t]*:[ \t]*"/, "", rest)
        sub(/".*$/, "", rest)
        if (rest != "") print rest
      }
    }' "$1" 2>/dev/null
}

# ── 文件取证元数据（只读，绝不执行）──
# msc_file_forensics <file> → 追加到 stdout
msc_file_forensics() {
  local f="$1"
  echo "  path: $f"
  if [ -L "$f" ]; then
    echo "  type: symlink -> $(readlink "$f" 2>/dev/null)"
  elif [ -d "$f" ]; then
    echo "  type: directory"
  elif [ -f "$f" ]; then
    echo "  type: regular_file"
  else
    echo "  type: other"
  fi

  # 大小 / 权限 / 属主 / 时间（BSD stat）
  local meta
  meta=$(stat -f 'size=%z mode=%Sp uid=%u gid=%g mtime=%Sm birth=%SB' \
          -t '%Y-%m-%dT%H:%M:%S%z' "$f" 2>/dev/null) \
    || meta=$(stat -c 'size=%s mode=%A uid=%u gid=%g mtime=%y' "$f" 2>/dev/null)
  [ -n "$meta" ] && echo "  $meta"

  # 文件类型
  if command -v file >/dev/null 2>&1; then
    echo "  file: $(file -b "$f" 2>/dev/null | cut -c1-200)"
  fi

  # SHA-256（大文件跳过，避免把采集卡死；阈值 200MB）
  if [ -f "$f" ]; then
    local size
    size=$(stat -f '%z' "$f" 2>/dev/null || stat -c '%s' "$f" 2>/dev/null || echo 0)
    if [ "${size:-0}" -le 209715200 ]; then
      local hash
      hash=$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')
      [ -n "$hash" ] && echo "  sha256: $hash"
    else
      echo "  sha256: (跳过：文件 ${size} 字节，超过 200MB 阈值)"
    fi
  fi

  # 扩展属性（xattr）
  if command -v xattr >/dev/null 2>&1; then
    local xa
    xa=$(xattr -l "$f" 2>/dev/null | head -10)
    if [ -n "$xa" ]; then
      echo "  xattr:"
      echo "$xa" | sed 's/^/    /'
    fi
  fi

  # 代码签名
  if command -v codesign >/dev/null 2>&1; then
    local cs
    cs=$(codesign -dv --verbose=4 "$f" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier=|Signature|flags" | head -8)
    if [ -n "$cs" ]; then
      echo "  codesign:"
      echo "$cs" | sed 's/^/    /'
    else
      echo "  codesign: (无签名信息或无法读取)"
    fi
  fi

  # Gatekeeper 评估
  if command -v spctl >/dev/null 2>&1; then
    local gk
    gk=$(spctl --assess --type execute -vv "$f" 2>&1 | head -3)
    if [ -n "$gk" ]; then
      echo "  gatekeeper:"
      echo "$gk" | sed 's/^/    /'
    fi
  fi

  # 隔离属性（下载来源）
  if command -v mdls >/dev/null 2>&1; then
    local q
    q=$(mdls -name kMDItemWhereFroms "$f" 2>/dev/null | head -5)
    case "$q" in *"(null)"*) ;; *) [ -n "$q" ] && echo "  wherefrom:" && echo "$q" | sed 's/^/    /' ;; esac
  fi
}

# ── 进程命令行 IOC 匹配（只读 /bin/ps）──
# msc_ioc_proc_match <pattern> → 输出匹配行
msc_ioc_proc_match() {
  local pat="$1"
  ps axo pid,ppid,user,lstart,command 2>/dev/null \
    | grep -F -- "$pat" | grep -v "grep -F" | head -20
}

# ── 持久化文件 IOC 匹配 ──
# msc_ioc_persistence_match <pattern> <label> → 输出文件路径 + 命中行号/内容
msc_ioc_persistence_match() {
  local pat="$1"
  local label="$2"
  local dirs="$HOME/Library/LaunchAgents /Library/LaunchAgents /Library/LaunchDaemons $HOME/Library/LaunchAgents"
  local d f
  for d in $dirs; do
    [ -d "$d" ] || continue
    for f in "$d"/*.plist; do
      [ -f "$f" ] || continue
      [ -r "$f" ] || { echo "  [permission_denied] $f"; continue; }
      if grep -qF -- "$pat" "$f" 2>/dev/null; then
        echo "  命中[$label]: $f"
        grep -nF -- "$pat" "$f" 2>/dev/null | head -5 | sed 's/^/    /'
        msc_file_forensics "$f" | sed 's/^/  /'
      fi
    done
  done
  # 用户级后台任务 / 登录项数据库（btm）
  if [ -f "$HOME/Library/Application Support/com.apple.backgroundtaskmanagement/BTMItems.plist" ]; then
    if grep -qaF -- "$pat" "$HOME/Library/Application Support/com.apple.backgroundtaskmanagement/BTMItems.plist" 2>/dev/null; then
      echo "  命中[$label]: BTMItems.plist 包含该字符串（二进制 plist，需人工打开确认）"
    fi
  fi
  return 0
}

# ── Shell 历史 / 配置 IOC 匹配 ──
msc_ioc_history_match() {
  local pat="$1"
  local label="$2"
  local f
  for f in "$HOME/.zsh_history" "$HOME/.bash_history" "$HOME/.zhistory" \
           "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zprofile" "$HOME/.profile" \
           "$HOME/.zsh_sessions"; do
    [ -e "$f" ] || continue
    if [ -d "$f" ]; then
      if grep -rlF -- "$pat" "$f" 2>/dev/null | head -5 | grep -q .; then
        echo "  命中[$label] 目录内: $(grep -rlF -- "$pat" "$f" 2>/dev/null | head -3 | tr '\n' ' ')"
      fi
      continue
    fi
    [ -r "$f" ] || { echo "  [permission_denied] $f"; continue; }
    if grep -qF -- "$pat" "$f" 2>/dev/null; then
      echo "  命中[$label]: $f"
      grep -nF -- "$pat" "$f" 2>/dev/null | head -5 | sed 's/^/    /'
    fi
  done
  return 0
}

# ── 日志 IOC 匹配（在已采集的日志文本文件上做，不重复跑 log show）──
msc_ioc_file_grep_match() {
  local pat="$1"
  local label="$2"
  local dir="$3"
  [ -d "$dir" ] || return 0
  local hits
  hits=$(grep -rlF -- "$pat" "$dir" 2>/dev/null | head -10)
  if [ -n "$hits" ]; then
    echo "  命中[$label] 于已采集日志文件:"
    echo "$hits" | sed 's/^/    /'
    echo "$hits" | head -3 | while IFS= read -r hf; do
      echo "    --- $(basename "$hf") ---"
      grep -nF -- "$pat" "$hf" 2>/dev/null | head -3 | cut -c1-300 | sed 's/^/      /'
    done
  fi
  return 0
}

# ── 卷挂载状态 ──
msc_volume_status() {
  local name="$1"
  local m
  m=$(mount 2>/dev/null | grep -F "/Volumes/$name" | head -1)
  if [ -n "$m" ]; then
    echo "  mounted: $m"
  else
    echo "  mounted: no（卷未挂载；无法检查卷内文件，也不能证明文件曾不存在）"
  fi
}

# ── IOC 定义文件的统一执行入口 ─────────────────────────────────────────────
# msc_ioc_scan <ioc_json_file>
#   读取 IOC 定义，逐项检查：路径存在性、路径 glob、进程命令行、持久化项、
#   Shell 历史、已采集日志、卷挂载状态。输出人类可读结果到 stdout。
#   注意：命中仅代表「值得调查」，不做恶意判定。
msc_ioc_scan() {
  local file="$1"
  [ -f "$file" ] || { echo "!! IOC 文件不存在: $file"; return 1; }

  local name title severity
  name=$(_msc_json_top_field "$file" "name")
  title=$(_msc_json_top_field "$file" "title")
  severity=$(_msc_json_top_field "$file" "severity")

  echo "══════════════════════════════════════════════════════"
  echo "IOC 检测: ${title:-$name}  (severity=${severity:-unknown})"
  echo "定义文件: $(basename "$file")"
  echo "══════════════════════════════════════════════════════"

  local hit_count=0 checked=0

  # 1) 固定路径检查
  echo ""
  echo "-- [1] 固定路径 --"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    checked=$((checked + 1))
    if [ -e "$p" ]; then
      hit_count=$((hit_count + 1))
      echo "  [EXISTS] $p"
      msc_file_forensics "$p" | sed 's/^/    /'
    elif [ -L "$p" ]; then
      echo "  [BROKEN_SYMLINK] $p"
    else
      echo "  [ABSENT] $p  （当前不存在；不代表过去未存在）"
    fi
  done <<EOF
$(sed -n '/"paths"/,/\]/p' "$file" | grep -o '"path"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"//; s/"$//')
EOF

  # 2) 路径 glob 检查
  echo ""
  echo "-- [2] 路径通配 --"
  while IFS= read -r g; do
    [ -z "$g" ] && continue
    g_expanded=$(eval "echo $g" 2>/dev/null || echo "$g")
    local matched=0
    for m in $g_expanded; do
      [ -e "$m" ] || continue
      matched=1
      hit_count=$((hit_count + 1))
      echo "  [EXISTS] $m"
      msc_file_forensics "$m" | sed 's/^/    /'
    done
    [ "$matched" -eq 0 ] && echo "  [NO_MATCH] $g"
    checked=$((checked + 1))
  done <<EOF
$(sed -n '/"path_globs"/,/\]/p' "$file" | grep -o '"[^"]*[*][^"]*"' | tr -d '"')
EOF

  # 3) 字符串：进程 / 持久化 / 历史 / 日志
  echo ""
  echo "-- [3] 字符串搜索（进程 / 持久化 / 历史 / 日志）--"
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    checked=$((checked + 1))
    echo ""
    echo "  模式: \"$s\""
    local before_hits
    before_hits=$(msc_ioc_proc_match "$s" 2>/dev/null | wc -l | tr -d ' ')
    if [ "${before_hits:-0}" -gt 0 ]; then
      hit_count=$((hit_count + 1))
      echo "  [PROC_HIT] 进程命令行命中:"
      msc_ioc_proc_match "$s" 2>/dev/null | sed 's/^/    /'
    fi
    local ph
    ph=$(msc_ioc_persistence_match "$s" "persistence" 2>/dev/null)
    if [ -n "$ph" ]; then
      hit_count=$((hit_count + 1))
      echo "  [PERSIST_HIT]:"
      echo "$ph" | sed 's/^/  /'
    fi
    local hh
    hh=$(msc_ioc_history_match "$s" "history" 2>/dev/null)
    if [ -n "$hh" ]; then
      hit_count=$((hit_count + 1))
      echo "  [HISTORY_HIT]:"
      echo "$hh" | sed 's/^/  /'
    fi
    local lg
    lg=$(msc_ioc_file_grep_match "$s" "logs" "${MSC_EVIDENCE_ROOT:-.}/logs" 2>/dev/null)
    if [ -n "$lg" ]; then
      hit_count=$((hit_count + 1))
      echo "  [LOG_HIT]:"
      echo "$lg" | sed 's/^/  /'
    fi
    if [ "${before_hits:-0}" -eq 0 ] && [ -z "$ph" ] && [ -z "$hh" ] && [ -z "$lg" ]; then
      echo "  [NO_HIT] 当前可检查范围内未命中"
    fi
  done <<EOF
$(sed -n '/"strings"/,/\]/p' "$file" | grep -o '"pattern"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"//; s/"$//')
EOF

  # 4) 域名 / URL → 分发给网络与日志检查
  echo ""
  echo "-- [4] 域名 / URL --"
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    checked=$((checked + 1))
    echo "  检查: $d"
    local net_hit
    net_hit=$(grep -F -- "$d" "${MSC_EVIDENCE_ROOT:-.}/network/"*.txt 2>/dev/null | head -5)
    if [ -n "$net_hit" ]; then
      hit_count=$((hit_count + 1))
      echo "  [NET_HIT] 当前网络快照中出现:"
      echo "$net_hit" | sed 's/^/    /'
    else
      echo "  [NO_HIT] 当前网络快照中未出现（仅代表此刻无连接）"
    fi
    local log_hit
    log_hit=$(grep -rF -- "$d" "${MSC_EVIDENCE_ROOT:-.}/logs/" 2>/dev/null | head -5)
    if [ -n "$log_hit" ]; then
      hit_count=$((hit_count + 1))
      echo "  [LOG_HIT]:"
      echo "$log_hit" | sed 's/^/    /' | cut -c1-400
    fi
  done <<EOF
$(sed -n '/"domains"/,/\]/p; /"urls"/,/\]/p' "$file" | grep -o '"[^"]*\.[^"]*"' | tr -d '"' | sort -u)
EOF

  # 5) 哈希（仅在定义中显式给出时）
  echo ""
  echo "-- [5] 文件哈希比对 --"
  local hashes
  hashes=$(sed -n '/"sha256"/,/\]/p' "$file" | grep -oE '[a-f0-9]{64}' | head -20)
  if [ -z "$hashes" ]; then
    echo "  [SKIPPED] 该 IOC 未提供可信 SHA-256 规则，不进行哈希比对（不编造哈希）"
  else
    for p in /tmp/installer /private/tmp/installer; do
      [ -f "$p" ] || continue
      local h
      h=$(shasum -a 256 "$p" 2>/dev/null | awk '{print $1}')
      if echo "$hashes" | grep -qx "$h"; then
        hit_count=$((hit_count + 1))
        echo "  [HASH_MATCH] $p -> $h"
      else
        echo "  [HASH_NO_MATCH] $p -> ${h:-不可读}"
      fi
    done
  fi

  # 6) 卷状态（Volumes 相关）
  local vol
  vol=$(grep -o '/Volumes/[A-Za-z0-9._-]*' "$file" 2>/dev/null | head -1)
  if [ -n "$vol" ]; then
    echo ""
    echo "-- [6] 卷挂载状态 --"
    msc_volume_status "$(basename "$vol")"
  fi

  # 结论
  echo ""
  echo "── 小结: 检查项 $checked，命中 $hit_count ──"
  if [ "$hit_count" -gt 0 ]; then
    echo "结论: 有 $hit_count 项命中 → 值得调查，但命中不等于恶意。"
    echo "      需人工结合代码签名、文件时间线、父子进程、网络行为综合判断。"
    echo "      命中同样不等于已确认感染；未命中的其他 IOC 项仍不代表系统干净。"
    echo "      当前可检查范围内未命中的部分，不等于系统干净："
    echo "      - 已删除文件、已卸载卷、已轮转日志无法还原"
    echo "      - 权限不足的区域未采集（见 manifest.json 中 permission_denied 模块）"
    echo "      - 过去的网络外传无法用当前快照证明或排除"
  else
    echo "结论: 当前可检查范围内未命中。**这不等于系统干净**："
    echo "      - 已删除文件、已卸载卷、已轮转日志无法还原"
    echo "      - 权限不足的区域未采集（见 manifest.json 中 permission_denied 模块）"
    echo "      - 过去的网络外传无法用当前快照证明或排除"
  fi
  echo ""
  return 0
}

# 兼容旧调用名
ioc_scan_file() { msc_ioc_scan "$@"; }

# ── 顶层标量字段取值（如 "name": "zeff"）────────────────────────────────
_msc_json_top_field() {
  local file="$1" key="$2"
  grep -m1 "\"$key\"[[:space:]]*:[[:space:]]*\"" "$file" 2>/dev/null \
    | sed 's/.*:[[:space:]]*"//; s/",*[[:space:]]*$//'
}
