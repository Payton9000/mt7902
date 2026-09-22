#!/usr/bin/env bash
# =============================================================================
#  check_mt7902.sh  ——  MT7902 板载网卡 只读体检 / 前置核查脚本
#
#  设计原则（遵守用户三条硬约束）：
#    * 不安装任何驱动  * 不修改任何系统文件  * 不重启  * 不影响现有 USB 网卡
#    本脚本只做「读」操作：读 sysfs / proc / modinfo / 已装包清单。
#    唯一例外是 `dmesg` 子命令（读内核日志），需要 sudo，但依然只读。
#
#  用法：
#    bash check_mt7902.sh            全方位只读体检
#    bash check_mt7902.sh env        仅查编译环境
#    bash check_mt7902.sh net        仅查网络与 USB 网卡状态
#    bash check_mt7902.sh card       仅查板载卡硬件与 ID 表匹配
#    bash check_mt7902.sh bt         仅查板载蓝牙
#    bash check_mt7902.sh assets     校验固件与已构建模块的 sha256
#    bash check_mt7902.sh modinfo    仅查 mt7902e.ko 兼容性
#    bash check_mt7902.sh dmesg      采集真实内核日志（建议 sudo；本次调研唯一缺口）
#
#  作者注：本脚本不区分沙箱/真实终端；在真实终端运行结果更完整。
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"    # 仓库根目录（本脚本位于 tools/ 或 dkms/ 下）
ASSETS="${MT7902_ASSETS:-$REPO_ROOT}"   # .ko 产物所在目录；make 的输出就落在仓库根
FW_SRC="${MT7902_FW_SRC:-$REPO_ROOT/firmware}"   # 固件所在目录
BT_PATCH="${MT7902_BT_PATCH:-$REPO_ROOT/patches/btusb/btusb-mt7902.patch}"
PCI_BDF="0000:05:00.0"
# 可选：USB 网卡接口名（用于额外确认它没被影响）。留空则跳过该项检查。
# 覆盖方式：MT7902_USB_IFACE=wlx1234567890ab ./check-mt7902.sh
USB_WLAN_IFACE="${MT7902_USB_IFACE:-}"

KERNEL="$(uname -r)"

C_G="\033[32m"; C_Y="\033[33m"; C_R="\033[31m"; C_B="\033[36m"; C_N="\033[0m"
ok()   { printf "  ${C_G}✓${C_N} %s\n" "$*"; }
warn() { printf "  ${C_Y}!${C_N} %s\n" "$*"; }
bad()  { printf "  ${C_R}✗${C_N} %s\n" "$*"; }
info() { printf "  ${C_B}·${C_N} %s\n" "$*"; }
sec()  { printf "\n${C_B}══ %s ══${C_N}\n" "$*"; }

# ---------------------------------------------------------------------------
cmd_env() {
  sec "编译环境"
  printf "  运行内核: %s\n" "$KERNEL"
  printf "  内核编译器: %s\n" "$(grep -oP 'gcc-\d+' /proc/version | head -1)"

  local B="/lib/modules/${KERNEL}/build"
  if [ -e "$B" ]; then ok "内核头文件目录存在: $(readlink -f "$B")"; else bad "缺少内核头文件（/lib/modules/${KERNEL}/build）"; fi

  local f
  for f in Makefile Module.symvers .config scripts/mod/modpost; do
    [ -e "$B/$f" ] && ok "$f" || bad "$f 缺失（出树编译会失败）"
  done

  local t
  for t in gcc-12 gcc make bc dkms git; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t: $(command -v "$t")"; else warn "$t 未安装"; fi
  done
  command -v flex  >/dev/null 2>&1 || info "flex 未安装（本驱动编译不需要，可忽略）"
  command -v bison >/dev/null 2>&1 || info "bison 未安装（本驱动编译不需要，可忽略）"

  sec "内核安全策略"
  grep -qE '^CONFIG_MODULE_SIG_FORCE=y' "$B/.config" 2>/dev/null \
    && bad "CONFIG_MODULE_SIG_FORCE=y → 未签名模块无法加载" \
    || ok "CONFIG_MODULE_SIG_FORCE 未设置 → 未签名模块可加载"
  if [ -d /sys/firmware/efi ]; then
    if command -v mokutil >/dev/null 2>&1; then
      info "Secure Boot: $(mokutil --sb-state 2>/dev/null)"
    else
      info "mokutil 不可用，无法判定 Secure Boot"
    fi
  else
    ok "传统 BIOS 启动 → Secure Boot 不适用"
  fi
  local lk; lk="$(cat /sys/kernel/security/lockdown 2>/dev/null)"
  [ -n "$lk" ] && info "lockdown: $lk" || info "lockdown: 不可读或未启用"

  sec "资源"
  info "已装内核: $(ls /lib/modules/ 2>/dev/null | tr '\n' ' ')"
  info "CPU 核心: $(nproc)"
  df -h / | tail -1 | awk '{printf "  磁盘 /: 已用 %s / 共 %s（可用 %s）\n", $3, $2, $4}'
}

# ---------------------------------------------------------------------------
cmd_net() {
  sec "网络接口"
  ip -brief addr show 2>/dev/null | grep -v '^lo' | sed 's/^/  /'
  printf "  默认路由: %s\n" "$(ip route show default 2>/dev/null)"

  sec "USB 网卡（AIC8800）保护基线"
  lsmod 2>/dev/null | awk '/^aic/{printf "  %s\n",$0}'
  if [ -n "$USB_WLAN_IFACE" ]; then
    if ip link show "$USB_WLAN_IFACE" >/dev/null 2>&1; then
      ok "$USB_WLAN_IFACE 存在"
    else
      warn "$USB_WLAN_IFACE 不存在（名字可能已变，请以上面接口列表为准）"
    fi
  else
    info "未指定 USB 网卡接口（设 MT7902_USB_IFACE 可额外复核它）"
  fi
  info "aic8800_fdrv 依赖: $(modinfo -F depends aic8800_fdrv 2>/dev/null)"
  if [ -n "$USB_WLAN_IFACE" ]; then
    if ip route show default 2>/dev/null | grep -q "$USB_WLAN_IFACE"; then
      ok "默认路由仍走 USB 网卡 → 联网通道安全"
    else
      warn "默认路由未走 $USB_WLAN_IFACE，请确认是否还有其他联网通道"
    fi
  fi
}

# ---------------------------------------------------------------------------
cmd_card() {
  sec "板载卡（MT7902）硬件状态"
  if [ ! -d "/sys/bus/pci/devices/$PCI_BDF" ]; then
    bad "$PCI_BDF 不存在 → 卡未枚举（可能被 BIOS 禁用或未插好）"
    return
  fi
  lspci -nn -s "${PCI_BDF#0000:}" 2>/dev/null | sed 's/^/  /'
  local f
  for f in vendor device subsystem_vendor subsystem_device modalias enable irq power_state; do
    printf "  %-18s = %s\n" "$f" "$(cat "/sys/bus/pci/devices/$PCI_BDF/$f" 2>&1)"
  done
  if [ -e "/sys/bus/pci/devices/$PCI_BDF/driver" ]; then
    ok "已绑定驱动: $(basename "$(readlink -f "/sys/bus/pci/devices/$PCI_BDF/driver")")"
  else
    bad "无驱动绑定（尚未被任何驱动认领）"
  fi
  info "PCIe 链路: $(cat /sys/bus/pci/devices/$PCI_BDF/current_link_speed 2>/dev/null) ×$(cat /sys/bus/pci/devices/$PCI_BDF/current_link_width 2>/dev/null)"

  sec "ID 表匹配判定（决定性）"
  if modinfo mt7921e 2>/dev/null | grep -q 'v000014C3d00007902'; then
    ok "内核自带 mt7921e 已支持 14c3:7902 → 无需安装任何东西"
  else
    bad "内核自带 mt7921e 不支持 14c3:7902 → 需要 backport"
    printf "    mt7921e 支持的 ID: %s\n" "$(modinfo -F alias mt7921e 2>/dev/null | grep -oP 'd\K[0-9A-F]{8}' | tr '\n' ' ')"
  fi
  modinfo mt7925e 2>/dev/null | grep -q 'v000014C3d00007902' && warn "mt7925e 也声明支持（异常）" \
    || printf "    mt7925e 支持的 ID: %s\n" "$(modinfo -F alias mt7925e 2>/dev/null | grep -oP 'd\K[0-9A-F]{8}' | tr '\n' ' ')"

  sec "固件现状"
  local n; n=$(find /lib/firmware -iname '*7902*' 2>/dev/null | wc -l)
  if [ "$n" -eq 0 ]; then
    bad "/lib/firmware 中没有 MT7902 固件（需要放入 2 个 WiFi 固件）"
  else
    ok "找到 $n 个 MT7902 相关固件文件:"
    find /lib/firmware -iname '*7902*' 2>/dev/null | sed 's/^/    /'
  fi
  printf "  内核自带 mt7921e 期望的固件名:\n"
  modinfo -F firmware mt7921e 2>/dev/null | sed 's/^/    /'
  printf "  内核自带 mt7925e 期望的固件名:\n"
  modinfo -F firmware mt7925e 2>/dev/null | sed 's/^/    /'

  sec "是否已安装第三方模块"
  n=$(find /lib/modules -iname '*mt7902*' 2>/dev/null | wc -l)
  [ "$n" -eq 0 ] && ok "系统中无 mt7902 模块（尚未安装）" || { warn "发现 $n 个 mt7902 相关模块:"; find /lib/modules -iname '*mt7902*' 2>/dev/null | sed 's/^/    /'; }
  lsmod 2>/dev/null | grep -E '^mt7902|^mt79' | sed 's/^/  已加载: /' || true
}

# ---------------------------------------------------------------------------
cmd_bt() {
  sec "板载蓝牙（走 USB）"
  local btpath
  for d in /sys/bus/usb/devices/*/; do
    [ -f "${d}idVendor" ] || continue
    if [ "$(cat "${d}idVendor" 2>/dev/null)" = "13d3" ]; then
      btpath="$d"
      printf "  USB 路径: %s\n" "$(basename "$d")"
      printf "  USB ID  : %s:%s\n" "$(cat "${d}idVendor")" "$(cat "${d}idProduct")"
      printf "  厂商串  : %s\n" "$(cat "${d}manufacturer" 2>/dev/null)"
      printf "  产品串  : %s\n" "$(cat "${d}product" 2>/dev/null)"
    fi
  done
  [ -z "${btpath:-}" ] && warn "未找到 13d3:* 设备（板载蓝牙可能未枚举）"

  sec "hci 设备状态"
  if [ -d /sys/class/bluetooth/hci0 ]; then
    if command -v hciconfig >/dev/null 2>&1; then
      hciconfig -a 2>&1 | sed 's/^/  /'
      echo
      local addr; addr="$(hciconfig hci0 2>/dev/null | grep -oP 'BD Address: \K[0-9A-F:]+')"
      case "$addr" in
        00:00:00:00:00:00|"") bad "BD Address 全零 → 控制器未初始化（固件未加载）" ;;
        *) ok "BD Address = $addr → 控制器已初始化" ;;
      esac
    else
      warn "hciconfig 未安装"
    fi
  else
    warn "无 hci0 设备"
  fi
  printf "  btmtk 内含的固件名:\n"
  modinfo -F firmware btmtk 2>/dev/null | sed 's/^/    /'
  if modinfo -F firmware btmtk 2>/dev/null | grep -q 'MT7902'; then
    ok "内核自带 btmtk 已含 MT7902 固件名"
  else
    bad "内核自带 btmtk 不含 MT7902 固件名 → 蓝牙需要 backport btusb/btmtk"
  fi

  sec "rfkill"
  for r in /sys/class/rfkill/*/; do
    [ -d "$r" ] || continue
    printf "  %-8s name=%-8s type=%-10s soft=%s hard=%s\n" \
      "$(basename "$r")" "$(cat "$r/name" 2>/dev/null)" "$(cat "$r/type" 2>/dev/null)" \
      "$(cat "$r/soft" 2>/dev/null)" "$(cat "$r/hard" 2>/dev/null)"
  done
}

# ---------------------------------------------------------------------------
cmd_assets() {
  sec "校验固件与模块资产"
  local want_fw=(     # 必需：Wi-Fi 固件
    "WIFI_MT7902_patch_mcu_1_1_hdr.bin:d73ba9e982f781221a2b9f10c42031f20a9dce046929fc0d55c791a417efe30a"
    "WIFI_RAM_CODE_MT7902_1.bin:b5958ac72c71fb8405e080f52d378d02b484812b9f1010c8843727056bbfc998"
  )
  local opt_fw=(      # 可选：蓝牙固件（只有做蓝牙方案才需要）
    "BT_RAM_CODE_MT7902_1_1_hdr.bin:4f53b5e02fbd933172e18caf952bda410a877eaad00561781528cb4aff58dc38"
  )
  local e name expect got
  for e in "${want_fw[@]}"; do
    name="${e%%:*}"; expect="${e##*:}"
    if [ ! -f "$FW_SRC/$name" ]; then bad "$name 缺失（$FW_SRC）"; continue; fi
    got="$(sha256sum "$FW_SRC/$name" | cut -d' ' -f1)"
    if [ "$got" = "$expect" ]; then ok "$name  大小=$(stat -c%s "$FW_SRC/$name")  sha256 一致"
    else bad "$name  sha256 不一致！期望 ${expect:0:16}… 实际 ${got:0:16}…"; fi
  done
  for e in "${opt_fw[@]}"; do
    name="${e%%:*}"; expect="${e##*:}"
    if [ ! -f "$FW_SRC/$name" ]; then info "$name 未放在 $FW_SRC（蓝牙方案可选，见 docs/bluetooth.md）"; continue; fi
    got="$(sha256sum "$FW_SRC/$name" | cut -d' ' -f1)"
    if [ "$got" = "$expect" ]; then ok "$name  大小=$(stat -c%s "$FW_SRC/$name")  sha256 一致"
    else bad "$name  sha256 不一致！期望 ${expect:0:16}… 实际 ${got:0:16}…"; fi
  done

  # 模块是构建产物，由 make 生成，没有固定 sha256 可对
  local ko="$ASSETS/mt7902e.ko"
  if [ -f "$ko" ]; then ok "mt7902e.ko  存在（$(stat -c%s "$ko") 字节）"
  else info "尚无 mt7902e.ko —— 先执行 make -j\$(nproc) 生成"; fi

  section_modinfo
}

section_modinfo() {
  sec "mt7902e.ko 兼容性自检"
  local ko="$ASSETS/mt7902e.ko"
  [ -f "$ko" ] || { warn "无 mt7902e.ko，跳过"; return; }
  printf "  name     : %s\n" "$(modinfo -F name "$ko")"
  printf "  alias    : %s\n" "$(modinfo -F alias "$ko")"
  printf "  vermagic : %s\n" "$(modinfo -F vermagic "$ko")"
  printf "  depends  : %s\n" "$(modinfo -F depends "$ko")"
  printf "  运行内核 : %s\n" "$KERNEL"
  if modinfo -F vermagic "$ko" | grep -q "${KERNEL}"; then
    ok "vermagic 与运行内核匹配"
  else
    bad "vermagic 不匹配 → 内核变动后需重新 make（约 4 秒）"
  fi
  modinfo -F alias "$ko" | grep -q 'v000014C3d00007902' \
    && ok "alias 命中 14c3:7902 → 能认板载卡" \
    || bad "alias 未命中 14c3:7902"
}

# ---------------------------------------------------------------------------
cmd_dmesg() {
  sec "内核日志采集（只读）"
  local PAT='mt79|14c3|05:00|btusb|btmtk|hci0|firmware|Opcode'
  local log="" src=""

  # 途径 1: dmesg（常因 kernel.dmesg_restrict=1 失败）
  if command -v dmesg >/dev/null 2>&1 && dmesg >/dev/null 2>&1; then
    log="$(dmesg 2>/dev/null)"; src="dmesg"
  fi
  # 途径 2: journalctl -k（本机验证：普通用户即可读，dmesg_restrict 拦不住它）
  if [ -z "$log" ] && command -v journalctl >/dev/null 2>&1; then
    log="$(journalctl -k --no-pager 2>/dev/null)"; [ -n "$log" ] && src="journalctl -k"
  fi
  # 途径 3: /var/log/kern.log（需在 adm 组）
  if [ -z "$log" ] && [ -r /var/log/kern.log ]; then
    log="$(cat /var/log/kern.log 2>/dev/null)"; src="/var/log/kern.log"
  fi

  if [ -z "$log" ]; then
    bad "三条途径都读不到内核日志。请以 sudo 运行："
    printf "\n    sudo journalctl -k --no-pager -b | grep -iE '%s' | tail -80\n\n" "$PAT"
    return
  fi
  info "日志来源: $src"

  local out; out="$(printf '%s\n' "$log" | grep -iE "$PAT" | tail -80)"
  if [ -z "$out" ]; then
    warn "未匹配到相关日志条目"
  else
    printf "%s\n" "$out" | sed 's/^/  /'
  fi

  sec "关键错误模式判读"
  printf '%s\n' "$log" | grep -qi 'driver own failed' \
    && bad "发现 'driver own failed' → 设备可能处于锁死状态，需彻底断电恢复" \
    || ok "未见 'driver own failed'（设备未锁死）"

  printf '%s\n' "$log" | grep -qi 'Unsupported hardware variant' \
    && warn "发现 'Unsupported hardware variant' → btusb 已走 MediaTek 路径，但固件表里没有该芯片" \
    || ok "未见 'Unsupported hardware variant'"

  printf '%s\n' "$log" | grep -qiE 'Kernel panic|BUG: kernel NULL' \
    && bad "发现 panic / NULL 解引用记录！" \
    || ok "未见 panic 记录"

  echo "  --- Wi-Fi 侧：是否曾被驱动尝试 probe ---"
  local n; n="$(printf '%s\n' "$log" | grep -iE '05:00\.0' | grep -icE 'enabling device|probe')"
  if [ "$n" -eq 0 ]; then
    bad "板载 Wi-Fi 从未被任何驱动尝试 probe（问题在 ID 表，硬件正常）"
  else
    warn "板载 Wi-Fi 有过 $n 次 probe 尝试（需进一步看失败原因）"
  fi

  echo "  --- 蓝牙侧：HCI 初始化命令是否超时 ---"
  local bt; bt="$(printf '%s\n' "$log" | grep -iE 'hci0: Opcode 0x0c03 failed' | tail -1)"
  if [ -n "$bt" ]; then
    bad "HCI Reset 超时（-110）→ 控制器未加载固件，属预期现象"
  else
    ok "未见 HCI Reset 超时"
  fi
}

# ---------------------------------------------------------------------------
cmd_all() {
  printf "${C_B}MT7902 只读体检报告${C_N}\n"
  printf "时间: %s\n" "$(date '+%F %T')"
  cmd_env
  cmd_net
  cmd_card
  cmd_bt
  cmd_assets
  sec "下一步"
  cat <<'EOT'
  1) 若上方提示「内核自带 mt7921e 已支持 14c3:7902」→ 什么都不用装
  2) 否则需要 backport。完整流程见同目录 MT7902_调研报告.md §9
  3) 缺失的关键信息是 dmesg，请运行：  bash check_mt7902.sh dmesg   （可加 sudo）
  4) 安装前务必先跑一次本脚本，保存输出作为「变更前基线」
EOT
}

case "${1:-all}" in
  all|check)  cmd_all ;;
  env)        cmd_env ;;
  net)        cmd_net ;;
  card)       cmd_card ;;
  bt)         cmd_bt ;;
  assets)     cmd_assets ;;
  dmesg)      cmd_dmesg ;;
  modinfo)    section_modinfo ;;
  *)          sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
esac
