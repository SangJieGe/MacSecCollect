#!/usr/bin/env bash
# =============================================================================
#  lib/evidence.sh — 证据目录、校验清单、manifest 与打包
#
#  原则：
#    * 默认保留原始证据目录；清理必须显式开启，且清理前验证归档。
#    * 归档失败、校验失败必须报错，绝不静默成功。
#    * 区分 raw/ 原始证据 与 summary/ 工具生成摘要。
# =============================================================================

if [ "${__MSC_EVIDENCE_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi
__MSC_EVIDENCE_LOADED=1

# ── 建立标准证据目录（与现有扁平文件兼容：根目录仍放 01-14 的 .txt）──
msc_init_evidence_layout() {
  local root="$1"
  mkdir -p "$root"/{system,process,network,persistence,logs,ioc,summary} 2>/dev/null
  mkdir -p "$root/raw" 2>/dev/null
}

# ── 生成 checksums.sha256（相对路径，便于跨机校验）──
# msc_write_checksums <evidence_root> <output_file>
msc_write_checksums() {
  local root="$1"; local out="$2"
  local rel="$root/checksums.sha256"
  [ -n "$out" ] && rel="$out"

  ( cd "$root" 2>/dev/null || exit 1
    find . -type f ! -name 'checksums.sha256' ! -name '.modules.tsv' ! -name '.msc_tmp_*' ! -name '.cksum_log' 2>/dev/null \
      | LC_ALL=C sort \
      | while IFS= read -r f; do
          h=$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')
          [ -n "$h" ] && printf '%s  %s\n' "$h" "${f#./}"
        done ) > "$rel" 2>/dev/null

  local n
  n=$(wc -l < "$rel" 2>/dev/null | tr -d ' ')
  echo "checksums: $n 个文件"
  if [ "${n:-0}" -eq 0 ]; then
    return 1
  fi
  return 0
}

# ── 校验 checksums.sha256 ──
msc_verify_checksums() {
  local root="$1"
  local file="$root/checksums.sha256"
  [ -f "$file" ] || { echo "MISSING:$file"; return 2; }
  local bad=0 total=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    total=$((total + 1))
    local expect="${line%%  *}"
    local rel="${line#*  }"
    local actual
    actual=$(shasum -a 256 "$root/$rel" 2>/dev/null | awk '{print $1}')
    if [ -z "$actual" ] || [ "$actual" != "$expect" ]; then
      echo "MISMATCH:$rel"
      bad=$((bad + 1))
    fi
  done < "$file"
  echo "VERIFIED:$((total - bad))/$total"
  [ "$bad" -eq 0 ] && return 0 || return 1
}

# ── 归档并验证 ──
# msc_archive <evidence_root> <dest_zip>
# 返回: 0 成功（并且验证通过）/ 1 打包失败 / 2 打包成功但校验失败
msc_archive() {
  local root="$1"; local dest="$2"
  local parent base
  parent=$(dirname "$root")
  base=$(basename "$root")

  rm -f "$dest" 2>/dev/null
  if ! ( cd "$parent" && zip -r -q -y "$dest" "$base" 2>/tmp/msc_zip_err.$$ ); then
    echo "ARCHIVE_FAILED: $(head -3 /tmp/msc_zip_err.$$ 2>/dev/null | tr '\n' ' ')"
    rm -f /tmp/msc_zip_err.$$
    return 1
  fi
  rm -f /tmp/msc_zip_err.$$

  # zip -T 完整性测试
  if ! unzip -t -q "$dest" >/dev/null 2>&1; then
    echo "ARCHIVE_CORRUPT: unzip -t 失败"
    return 2
  fi

  # 条目数与 checksums 行数一致性（宽松校验：归档内文件数 >= 清单条目数）
  local zip_count
  zip_count=$(unzip -Z1 "$dest" 2>/dev/null | grep -v '/$' | wc -l | tr -d ' ')
  local manifest_count=0
  [ -f "$root/checksums.sha256" ] && manifest_count=$(wc -l < "$root/checksums.sha256" | tr -d ' ')
  if [ "${zip_count:-0}" -lt "${manifest_count:-0}" ]; then
    echo "ARCHIVE_INCOMPLETE: 归档 ${zip_count} 个文件 < 清单 ${manifest_count} 条"
    return 2
  fi

  local zhash
  zhash=$(shasum -a 256 "$dest" 2>/dev/null | awk '{print $1}')
  echo "ARCHIVE_OK: $(basename "$dest") sha256=$zhash size=$(stat -f '%z' "$dest" 2>/dev/null || stat -c '%s' "$dest" 2>/dev/null)"
  return 0
}

# ── 安全清理（默认不调用；仅在 UI 显式勾选后由 Node 调用）──
# 清理前必须：归档存在 + unzip -t 通过 + 归档内包含 checksums.sha256
msc_safe_cleanup() {
  local root="$1"; local archive="$2"
  [ -f "$archive" ] || { echo "REFUSE: 归档不存在，拒绝清理原始证据"; return 1; }
  unzip -t -q "$archive" >/dev/null 2>&1 || { echo "REFUSE: 归档损坏，拒绝清理"; return 1; }
  unzip -Z1 "$archive" 2>/dev/null | grep -q 'checksums.sha256' || {
    echo "REFUSE: 归档内缺少 checksums.sha256，拒绝清理"; return 1; }
  rm -rf "$root"
  echo "CLEANED: $root（归档已验证）"
  return 0
}
