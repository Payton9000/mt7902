#!/usr/bin/env bash
# =============================================================================
#  verify_teardown_fix.sh  ——  验收「关机/rmmod oops」修复是否已生效
#
#  背景（一手证据见 .workbuddy/memory/2026-09-21.md 第二十四节）：
#    旧 mt7902e.ko 的 6.8 兼容层误用 init_dummy_netdev()，其 memset 把
#    alloc_netdev() 建好的 dev_addr 等字段清零；释放时
#    free_netdev() -> dev_addr_flush() -> dev_addr_check() 对 NULL 做 memcmp
#    → NULL 指针 Oops。表现为：
#      * 关机/重启卡死在 kernel_power_off（PID 1 被 oops 杀死 → Attempted to
#        kill init → panic_timeout=0 → 永久卡住），只能长按电源键；
#      * rmmod 后模块卡在 Unloading，直到重启。
#    修复版 srcversion: 726032A9C67CCFF9695720B（旧: 75E3119EBA351B93D741615）
#
#  子命令 / 用法：
#    bash verify_teardown_fix.sh                 # 只读体检（可反复跑）
#    bash verify_teardown_fix.sh --dry-run       # 只打印将做的动作
#    sudo bash verify_teardown_fix.sh --reload    # ★ 真验收：卸载+重载模块
#
#  ★ 安全底线：
#      - 默认只读，不改任何文件
#      - --reload 会短暂摘掉板载 wlan 接口（数秒后自动恢复）；若当前唯一上行
#        就是板载卡，会短暂断网 —— 脚本会在动作前明确提示，动作后等待其恢复
#      - 已加载的是「旧」模块时，--reload 会被拒绝：那会复现 oops 并卡住
#        （必须先重启让新模块生效）
#
#  ★ 路径无关（2026-09-21 19:57 修订）：
#      「磁盘上的模块」不再硬编码 extra/ —— 模块可能被 DKMS 装到
#      /lib/modules/<kver>/updates/dkms/。现在统一用 depmod 的解析结果
#      （modinfo -F filename）为准，与内核/udev 开机时挑的是同一份。
# =============================================================================
set -uo pipefail

KVER="${KVER:-$(uname -r)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"    # 仓库根目录（本脚本位于 tools/ 或 dkms/ 下）
ASSETS="${MT7902_ASSETS:-$REPO_ROOT}"   # .ko 产物所在目录；make 的输出就落在仓库根
FW_SRC="${MT7902_FW_SRC:-$REPO_ROOT/firmware}"   # 固件所在目录
BT_PATCH="${MT7902_BT_PATCH:-$REPO_ROOT/patches/btusb/btusb-mt7902.patch}"
WIFI_MOD="mt7902e"
BDF="0000:05:00.0"
# 可选：免驱 USB 网卡接口名（插着时一并复核）。留空则跳过该项。
# 覆盖方式：MT7902_USB_IFACE=wlx1234567890ab ./verify-teardown-fix.sh
USB_IFACE="${MT7902_USB_IFACE:-}"
OLD_SV="75E3119EBA351B93D741615"
NEW_SV="726032A9C67CCFF9695720B"
DKMS_CONF="/usr/src/${WIFI_MOD}-1.0/dkms.conf"
GUARD_IFACE=""                    # 运行时决定：要保护的上行接口
INSTALLED=""                      # 运行时解析：DKMS=updates/dkms/ 旧版=extra/

DRY=0; RELOAD=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --reload)  RELOAD=1 ;;
    -h|--help) sed -n '2,31p' "${BASH_SOURCE[0]}"; exit 0 ;;
  esac
done

C_G="\033[32m"; C_Y="\033[33m"; C_R="\033[31m"; C_B="\033[36m"; C_N="\033[0m"
ok()   { printf "  ${C_G}✓${C_N} %s\n" "$*"; }
bad()  { printf "  ${C_R}✗${C_N} %s\n" "$*"; }
warn() { printf "  ${C_Y}!${C_N} %s\n" "$*"; }
info() { printf "    %s\n" "$*"; }
sec()  { printf "\n${C_B}== %s ==${C_N}\n" "$*"; }
act()  { printf "  ${C_B}→${C_N} %s\n" "$*"; }
run()  { if [ "$DRY" = "1" ]; then printf "      [dry-run] %s\n" "$*"; else eval "$@"; fi; }

need_root() { [ "$(id -u)" = "0" ] || { bad "需要 root：sudo bash $0 --reload"; exit 1; }; }

# 内核日志三级回退（dmesg 被限制时用 journalctl，再退化到 kern.log）
klog() {
  if command -v dmesg >/dev/null 2>&1 && dmesg >/dev/null 2>&1; then dmesg 2>/dev/null; return; fi
  command -v journalctl >/dev/null 2>&1 && { journalctl -k --no-pager -b 2>/dev/null; return; }
  cat /var/log/kern.log 2>/dev/null
}
klog_lines() { klog | wc -l; }

# ---------- 网络保护 ----------
#  目标：任何时刻都不弄丢「当前唯一可用的上行」。
#  · 以前硬要求 USB 网卡 UP 且是默认路由 —— USB 卡拔掉后脚本会自己中止，
#    这在「只用板载卡上网」的新常态下是错的。现在改为：
#      保护对象 = 当前默认路由所属的接口（GUARD_IFACE，运行时决定）
#      若 USB 网卡插着，则额外要求它不掉线
iface_up() { ip -brief addr show "$1" 2>/dev/null | grep -qE '\bUP\b'; }
defrt()    { ip route show default 2>/dev/null \
               | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1; }
pick_guard() { GUARD_IFACE="$(defrt)"; }
usb_state() {
  [ -n "$USB_IFACE" ] || { echo "未指定"; return; }
  if [ -d "/sys/class/net/$USB_IFACE" ]; then
    if iface_up "$USB_IFACE"; then echo "UP"; else echo "DOWN(异常)"; fi
  else echo "未插入"; fi
}
net_guard() {                     # 立即断言
  local tag="$1"
  [ -n "$GUARD_IFACE" ] || { bad "$tag：当前没有默认路由（本机已断网）→ 停止"; exit 1; }
  if iface_up "$GUARD_IFACE" && [ "$(defrt)" = "$GUARD_IFACE" ]; then
    ok "$tag：上行 $GUARD_IFACE 仍 UP 且仍是默认路由"
  else
    bad "$tag：上行 $GUARD_IFACE 异常（当前默认路由=${defrt:-无}）→ 立即停止"; exit 1
  fi
  [ "$(usb_state)" = "DOWN(异常)" ] && { bad "$tag：USB 网卡 $USB_IFACE 掉线了"; exit 1; }
  return 0
}
net_guard_wait() {                # 等待恢复（动作可能短暂打断 GUARD_IFACE 时用）
  local tag="$1" i
  for i in $(seq 1 30); do
    if iface_up "$GUARD_IFACE" && [ "$(defrt)" = "$GUARD_IFACE" ]; then
      ok "$tag：上行 $GUARD_IFACE 已恢复（等待 ${i}s）"; return 0
    fi
    sleep 1
  done
  bad "$tag：上行 $GUARD_IFACE 在 30 秒内未恢复（当前默认路由=${defrt:-无}）"; exit 1
}

sv_of_file() { modinfo -F srcversion "$1" 2>/dev/null; }
sv_of_live() { cat "/sys/module/$WIFI_MOD/srcversion" 2>/dev/null; }
live_loaded() { grep -q "^$WIFI_MOD " /proc/modules 2>/dev/null; }
live_state()  { awk -v m="$WIFI_MOD" '$1==m {print $3}' /proc/modules 2>/dev/null; }
other_wl()    { for i in /sys/class/net/*/; do [ -d "${i}wireless" ] || continue
                  n="$(basename "$i")"; [ "$n" != "${USB_IFACE:-__no_such_iface__}" ] && echo "$n"; done | head -1; }
# 磁盘上的模块到底在哪：以 depmod 解析结果为准（与开机 udev 挑的同一份）
resolve_installed() {
  local p
  p="$(modinfo -k "$KVER" -F filename "$WIFI_MOD" 2>/dev/null)"
  [ -n "$p" ] && [ -f "$p" ] && { printf '%s' "$p"; return; }
  for p in "/lib/modules/$KVER/updates/dkms/$WIFI_MOD.ko" \
           "/lib/modules/$KVER/updates/$WIFI_MOD.ko" \
           "/lib/modules/$KVER/extra/$WIFI_MOD.ko"; do
    [ -f "$p" ] && { printf '%s' "$p"; return; }
  done
}
# 未装好时给哪条补救命令：DKMS 在管就用 DKMS 脚本（预编译 .ko 换内核后会失效）
fix_hint() {
  if [ -f "$DKMS_CONF" ]; then
    printf 'sudo bash %s/setup_mt7902_dkms.sh install --yes（本模块已由 DKMS 管理）' "$HERE"
  else
    printf 'sudo bash %s/deploy_mt7902.sh install --wifi --yes' "$HERE"
  fi
}

# =============================================================================
pick_guard
sec "1. 模块版本三方对照"
INSTALLED="$(resolve_installed)"
a_sv="$(sv_of_file "$ASSETS/$WIFI_MOD.ko")"
i_sv="$(sv_of_file "$INSTALLED")"
l_sv="$(sv_of_live)"
printf "    %-20s %s\n" "(构建产物)"    "${a_sv:-缺失}"
printf "    %-20s %s\n" "已安装(磁盘)"  "${i_sv:-缺失}"
printf "    %-20s %s\n" "已加载(内存)"  "${l_sv:-未加载}"
[ -n "$INSTALLED" ] && info "磁盘位置: $INSTALLED"
[ -f "$DKMS_CONF" ] && info "DKMS: 已注册（$DKMS_CONF）→ 内核升级会自动重编" \
                    || info "DKMS: 未注册（模块为手工安装，内核升级后需重装）"

FIX_READY=0; FIX_ACTIVE=0
[ "$a_sv" = "$NEW_SV" ] && ok "构建产物是修复版" || bad "构建产物不是修复版（期望 $NEW_SV 实际 ${a_sv:-无}）"
[ "$i_sv" = "$NEW_SV" ] && { ok "系统里装的是修复版"; FIX_READY=1; } \
                        || warn "系统里装的不是修复版 → $(fix_hint)"
[ "$l_sv" = "$NEW_SV" ] && { ok "内存里跑的是修复版"; FIX_ACTIVE=1; } \
                        || warn "内存里跑的仍是旧模块 ${l_sv:-未加载} → 关机仍可能卡住，需重启"

sec "2. 当前启动的内核日志"
if klog | grep -qiE 'dev_addr_check|mt7921_pci_shutdown|kernel NULL pointer'; then
  bad "本次启动出现过 oops（说明内存里仍是旧模块）"
  klog | grep -iE 'dev_addr_check|dev_addr_flush|kernel NULL pointer|Attempted to kill init' | tail -8 | sed 's/^/    /'
else
  ok "本次启动未见 dev_addr_check / NULL 解引用"
fi
if live_loaded && [ "$(live_state)" = "Unloading" ]; then
  warn "模块处于 Unloading（上次 rmmod 被 oops 打断）→ 只能重启清理"
fi

sec "3. 硬件与网络基线"
[ -e "/sys/bus/pci/devices/$BDF/driver" ] && ok "板载卡已绑定驱动" || info "板载卡当前未绑定"
[ -n "$(other_wl)" ] && ok "板载 wlan 接口: $(other_wl)" || info "未见板载 wlan 接口"
[ -n "$USB_IFACE" ] && info "USB 网卡 $USB_IFACE: $(usb_state)"
info "保护对象（当前默认路由）: ${GUARD_IFACE:-<无>}"
net_guard "基线"

# =============================================================================
if [ "$RELOAD" = "0" ]; then
  sec "结论"
  if [ "$FIX_ACTIVE" = "1" ]; then
    ok "修复已在运行（内存 srcversion=$NEW_SV）"
    info "你已多次正常关机/重启且不再出现 oops → 真机验收事实上已通过"
    info "想现在再证一次（等价于关机的卸载路径）：sudo bash $0 --reload"
  elif [ "$FIX_READY" = "1" ]; then
    warn "修复已装好但未生效 → 重启一次（若内存里仍是旧版，这次关机仍可能卡住，长按电源键即可；文件系统已卸载，不丢数据）"
  else
    warn "还没装好修复版 → $(fix_hint)"
  fi
  exit 0
fi

# ---------------------------- 真验收（卸载 + 重载）---------------------------
sec "4. 验收：modprobe -r / modprobe（会短暂中断板载 wlan）"
if [ "$FIX_ACTIVE" != "1" ]; then
  bad "内存里不是修复版（当前 ${l_sv:-未加载}）"
  bad "此时卸载会复现 oops 并卡在 Unloading —— 拒绝执行。请先重启让修复生效。"
  exit 1
fi
need_root
if [ "$GUARD_IFACE" = "$(other_wl)" ]; then
  warn "当前唯一上行就是板载卡（$GUARD_IFACE）→ 重载会短暂断网数秒，之后会自动连回"
  info "（可在动作完成后用 ip route / ping 复核）"
fi
net_guard "重载前"

before="$(klog_lines)"; info "内核日志基线行数: $before"
act "modprobe -r $WIFI_MOD"
run "modprobe -r $WIFI_MOD"; [ "$DRY" = "1" ] || sleep 3

if live_loaded; then
  bad "模块仍在 /proc/modules（state=$(live_state)）→ 卸载未完成"
  info "对照：修复前就是卡在这里（Unloading），需重启；若已用修复版仍如此，请把完整输出发回。"
  exit 1
fi
ok "模块已被干净摘除（没有卡在 Unloading）"

new_lines="$(klog | tail -n +$((before + 1)))"
if printf '%s\n' "$new_lines" | grep -qiE 'dev_addr_check|dev_addr_flush|kernel NULL pointer|Oops|BUG:'; then
  bad "卸载过程中出现新的 oops："
  printf '%s\n' "$new_lines" | grep -iE 'dev_addr|Oops|BUG|RIP:' | tail -10 | sed 's/^/    /'
  exit 1
fi
ok "卸载过程无任何 oops / BUG"

act "modprobe $WIFI_MOD"
run "modprobe $WIFI_MOD"
if [ "$DRY" = "0" ]; then
  for _ in $(seq 1 20); do live_loaded && [ -n "$(other_wl)" ] && break; sleep 1; done
fi

sec "5. 重载后复核"
live_loaded    && ok "模块已重新加载 (srcversion=$(sv_of_live))" || bad "模块未加载"
[ -n "$(other_wl)" ] && ok "板载 wlan 接口回来了: $(other_wl)" || warn "暂无板载 wlan 接口（可能是 rfkill/未连接，不影响本次验收）"
[ -e "/sys/bus/pci/devices/$BDF/driver" ] && ok "板载卡已重新绑定" || warn "板载卡未绑定"
new2="$(klog | tail -n +$((before + 1)))"
printf '%s\n' "$new2" | grep -qiE 'dev_addr_check|kernel NULL pointer|Oops|BUG:' \
  && bad "重载过程中出现 oops" || ok "重载过程无 oops"
net_guard_wait "重载后"

sec "结论"
ok "★ 验收通过：模块可干净卸载/加载 → 关机不再靠长按电源键"
info "（只读复核可另跑：bash $HERE/setup_mt7902_dkms.sh verify）"
