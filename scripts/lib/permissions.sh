#!/usr/bin/env bash
# =============================================================================
#  lib/permissions.sh — 权限探测（不做任何提权）
#
#  硬约束：
#    * 绝不调用 sudo。Electron 从 Finder 启动时没有交互式 TTY，脚本里的
#      `sudo -v` 会失败或挂起，`sudo -n` 则静默失败 —— 这正是原脚本
#      "管理员命令没跑但报成功" 的根因。
#    * 需要管理员权限的模块一律标记 permission_denied，交由 UI 提示用户
#      手动授权（或在终端里自行以管理员身份运行只读命令）。
#    * 不缓存、不记录、不传输任何密码。
# =============================================================================

if [ "${__MSC_PERMISSIONS_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi
__MSC_PERMISSIONS_LOADED=1

# msc_is_root → 0/1
msc_is_root() {
  [ "$(id -u 2>/dev/null)" = "0" ] && echo 1 || echo 0
}

# msc_can_sudo_nopass → 0/1（不提示、不阻塞）
msc_can_sudo_nopass() {
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    echo 1
  else
    echo 0
  fi
}

# msc_has_full_disk_access → 0/1
# 判定方式：尝试读取系统 TCC 数据库；能读到即认为进程有 FDA。
# （读取失败可能是 FDA 缺失，也可能是文件不存在 —— 两者都按"无 FDA"处理并记录原因）
msc_has_full_disk_access() {
  local tcc="/Library/Application Support/com.apple.TCC/TCC.db"
  if [ -r "$tcc" ]; then
    echo 1
  else
    echo 0
  fi
}

# 探测结果写入 $MSC_PERM_FILE（JSON 片段，由调用方拼接）
msc_probe_permissions() {
  local is_root; is_root=$(msc_is_root)
  local sudo_np; sudo_np=$(msc_can_sudo_nopass)
  local fda; fda=$(msc_has_full_disk_access)
  local sudo_present=0
  command -v sudo >/dev/null 2>&1 && sudo_present=1

  MSC_IS_ROOT="$is_root"
  MSC_SUDO_NOPASS="$sudo_np"
  MSC_HAS_FDA="$fda"

  if [ -n "${MSC_PERM_FILE:-}" ]; then
    mkdir -p "$(dirname "$MSC_PERM_FILE")" 2>/dev/null
    {
      printf '{\n'
      printf '  "is_root": %s,\n' "$([ "$is_root" = 1 ] && echo true || echo false)"
      printf '  "sudo_binary_present": %s,\n' "$([ "$sudo_present" = 1 ] && echo true || echo false)"
      printf '  "passwordless_sudo": %s,\n' "$([ "$sudo_np" = 1 ] && echo true || echo false)"
      printf '  "full_disk_access_heuristic": %s,\n' "$([ "$fda" = 1 ] && echo true || echo false)"
      printf '  "notes": [\n'
      printf '    "本工具从不调用 sudo，也不会缓存或记录任何密码。",\n'
      printf '    "从 Finder 双击启动时没有交互式终端，管理员权限命令不会被执行。",\n'
      printf '    "full_disk_access_heuristic 仅根据能否读取系统 TCC.db 推断，可能误判。"\n'
      printf '  ]\n'
      printf '}\n'
    } > "$MSC_PERM_FILE"
  fi
}

# 需要管理员权限时的统一状态判定
# 用法: msc_admin_gate → 打印 success/not_collected
msc_admin_gate() {
  if [ "$(msc_is_root)" = "1" ] || [ "$(msc_can_sudo_nopass)" = "1" ]; then
    echo "success"
  else
    echo "not_collected"
  fi
}
