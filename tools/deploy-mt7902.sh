#!/usr/bin/env bash
# =============================================================================
#  deploy_mt7902.sh  ——  MT7902 板载网卡（Wi-Fi + 蓝牙）部署 / 校验 / 回滚
#
#  设计约定（遵循既有习惯）：
#    * 子命令： preflight | install | verify | uninstall
#    * 支持 --dry-run（只打印将执行的动作，不落盘）
#    * 破坏性动作需显式 --yes；默认拒绝执行
#    * 任何一步失败即停，并打印回滚命令
#
#  ★ 安全底线（本脚本强制遵守）：
#      - 不重启、不动 initramfs、不改 /etc、不 blacklist 任何模块
#      - 只「新增」文件；模块放 updates/ 与 extra/，绝不覆盖 kernel/ 下的原文件
#      - 安装前记录基线；uninstall 只删自己新增的东西
#      - 每一步都复核「当前默认路由所属接口」是否仍然正常（USB 卡拔掉后也成立）
#
#  ★ 与 DKMS 的关系（2026-09-21 19:57 修订，重要）：
#      本模块现已交由 DKMS 管理（源码 /usr/src/mt7902e-1.0，产物落在
#      /lib/modules/<kver>/updates/dkms/mt7902e.ko）。因此：
#        · 内核升级后请用 setup_mt7902_dkms.sh，不要用本脚本的 install ——
#          .ko 是为「某个具体内核」编译的，换内核后 vermagic
#          不匹配，拷进 extra/ 也加载不了（表现为"升级完开机网卡又没了"）。
#        · 本脚本 install --wifi 现已内置两道闸：
#            ① 检测到 DKMS 已注册 → 拒绝（可用 --force-extra 强行绕过）
#            ② 校验构建产物 vermagic 与当前内核一致 → 不一致即拒绝
#
#  用法：
#    bash deploy_mt7902.sh preflight              # 只读体检（可反复跑）
#    sudo bash deploy_mt7902.sh try --yes         # ★ 试加载 Wi-Fi（不持久化，防 panic 首选）
#    bash deploy_mt7902.sh install --wifi         # 装 Wi-Fi（需 --yes 才真做，会持久化）
#    bash deploy_mt7902.sh install --bt           # 装蓝牙（需 --yes）
#    bash deploy_mt7902.sh install --wifi --dry-run
#    bash deploy_mt7902.sh install --wifi --force-extra --yes   # 明知 DKMS 在管仍装 extra/
#    bash deploy_mt7902.sh verify
#    bash deploy_mt7902.sh uninstall --wifi --yes
#
#  ★ try 与 install 的区别（panic 防线）：
#      try     = insmod 直接加载构建产物；不拷贝进 /lib/modules、不跑 depmod
#                → 万一 panic，断电重启后系统干干净净，没有任何东西会自动加载
#      install = 拷贝进 /lib/modules/<kver>/extra/ + depmod → 以后每次开机自动加载
#                → 只应在 try 成功并稳定之后执行
#
#  作者注：本脚本为「交给下一个模型执行」而准备。它在设计上不主动重启系统。
# =============================================================================
set -uo pipefail

KVER="${KVER:-$(uname -r)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"    # 仓库根目录（本脚本位于 tools/ 或 dkms/ 下）
ASSETS="${MT7902_ASSETS:-$REPO_ROOT}"   # .ko 产物所在目录；make 的输出就落在仓库根
FW_SRC="${MT7902_FW_SRC:-$REPO_ROOT/firmware}"   # 固件所在目录
BT_PATCH="${MT7902_BT_PATCH:-$REPO_ROOT/patches/btusb/btusb-mt7902.patch}"
STATE="/var/tmp/mt7902-deploy.state"

WIFI_MOD="mt7902e"
WIFI_FW=(WIFI_MT7902_patch_mcu_1_1_hdr.bin WIFI_RAM_CODE_MT7902_1.bin)
BT_FW=BT_RAM_CODE_MT7902_1_1_hdr.bin
BT_MOD_FILE="btusb.ko"
# 可选：额外的 USB 网卡接口名。留空则只保护上行接口（默认路由所在接口）。
# 覆盖方式：MT7902_USB_IFACE=wlx1234567890ab sudo -E ./deploy-mt7902.sh ...
PROTECTED_IFACE="${MT7902_USB_IFACE:-}"
GUARD_IFACE=""          # 运行时决定：要保护的上行接口（= 当前默认路由所属接口）

DO_WIFI=0; DO_BT=0; DRY=0; YES=0; FORCE_EXTRA=0
DKMS_CONF="/usr/src/${WIFI_MOD}-1.0/dkms.conf"

for a in "$@"; do
  case "$a" in
    --wifi) DO_WIFI=1 ;;
    --bt) DO_BT=1 ;;
    --all) DO_WIFI=1; DO_BT=1 ;;
    --dry-run) DRY=1 ;;
    --yes|-y) YES=1 ;;
    --force-extra) FORCE_EXTRA=1 ;;
  esac
done

C_G="\033[32m"; C_Y="\033[33m"; C_R="\033[31m"; C_B="\033[36m"; C_N="\033[0m"
ok()   { printf "  ${C_G}✓${C_N} %s\n" "$*"; }
warn() { printf "  ${C_Y}!${C_N} %s\n" "$*"; }
bad()  { printf "  ${C_R}✗${C_N} %s\n" "$*"; }
info() { printf "  ${C_B}·${C_N} %s\n" "$*"; }
sec()  { printf "\n${C_B}══ %s ══${C_N}\n" "$*"; }
act()  { if [ "$DRY" = "1" ]; then printf "  ${C_Y}[dry-run]${C_N} %s\n" "$*"; else printf "  → %s\n" "$*"; fi; }

need_root() { [ "$DRY" = "1" ] && return 0; [ "$(id -u)" = "0" ] || { bad "该子命令需要 root（请用 sudo 运行）"; exit 1; }; }
need_yes()  { [ "$YES" = "1" ] || { warn "破坏性动作未加 --yes，已中止（先加 --dry-run 预览）"; exit 1; }; }

run() { if [ "$DRY" = "1" ]; then act "$*"; else "$@"; fi; }

# ---------------------------------------------------------------------------
#  网络保护：保护对象 = 当前默认路由所属的接口（USB 卡拔掉后依然可用）
#  以前硬要求 USB 网卡 UP 且是默认路由；现在是「只用板载卡」的常态，那会误判中止。
iface_up() { ip -brief addr show "$1" 2>/dev/null | grep -q 'UP'; }
defrt()    { ip route show default 2>/dev/null \
              | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1; }
pick_guard() { GUARD_IFACE="$(defrt)"; }
usb_state()  { [ -n "$PROTECTED_IFACE" ] || { echo "未指定"; return; }
               if [ -d "/sys/class/net/$PROTECTED_IFACE" ]; then
                 iface_up "$PROTECTED_IFACE" && echo UP || echo "DOWN(异常)"
               else echo "未插入"; fi; }
net_guard() {
  local tag="$1"
  [ -n "$GUARD_IFACE" ] || pick_guard
  [ -n "$GUARD_IFACE" ] || { bad "$tag：当前没有任何默认路由（已断网）→ 立即停止"; exit 1; }
  if iface_up "$GUARD_IFACE" && [ "$(defrt)" = "$GUARD_IFACE" ]; then
    ok "$tag：上行 $GUARD_IFACE 仍 UP 且仍是默认路由"
  else
    bad "$tag：上行 $GUARD_IFACE 异常（当前默认路由=${defrt:-无}）→ 立即停止"; exit 1
  fi
  [ "$(usb_state)" = "DOWN(异常)" ] && { bad "$tag：USB 网卡 $PROTECTED_IFACE 掉线了"; exit 1; }
  return 0
}
# 是否已交给 DKMS 管
dkms_managed() { [ -f "$DKMS_CONF" ] || ls /usr/src/"$WIFI_MOD"-*/dkms.conf >/dev/null 2>&1; }
# 构建产物是否与当前内核匹配（不匹配就别装）
assert_assets_matches_kernel() {
  local vm
  vm="$(modinfo -F vermagic "$ASSETS/$WIFI_MOD.ko" 2>/dev/null | awk '{print $1}')"
  [ -z "$vm" ] && { warn "读不到构建产物的 vermagic，跳过校验"; return 0; }
  if [ "$vm" = "$KVER" ]; then ok "构建产物与当前内核匹配（vermagic=$vm）"; return 0; fi
  bad "$ASSETS/$WIFI_MOD.ko 是为 $vm 编译的，当前内核是 $KVER → 拷进 extra/ 也加载不了"
  info "正确做法： sudo bash $HERE/setup_mt7902_dkms.sh install --yes（DKMS 会为 $KVER 重编）"
  [ "$FORCE_EXTRA" = "1" ] && { warn "--force-extra 已指定，继续（风险自负）"; return 0; }
  exit 1
}
# DKMS 守卫：已由 DKMS 管理时，手工装 extra/ 只会制造重复副本且换内核后失效
assert_not_dkms_managed() {
  dkms_managed || return 0
  bad "本模块已由 DKMS 管理（$DKMS_CONF）"
  info "内核升级后请用： sudo bash $HERE/setup_mt7902_dkms.sh install --yes"
  info "（若确实要手工装到 extra/，加 --force-extra）"
  [ "$FORCE_EXTRA" = "1" ] && { warn "--force-extra 已指定，继续（会与 DKMS 副本共存）"; return 0; }
  exit 1
}

# ---------------------------------------------------------------------------
cmd_preflight() {
  sec "0. 资产完整性"
  local f h
  for f in "$ASSETS/$WIFI_MOD.ko" "${WIFI_FW[@]/#/$FW_SRC/}"; do
    if [ -f "$f" ]; then ok "存在 $(basename "$f")  ($(stat -c%s "$f") 字节)"
    else bad "缺失（Wi-Fi 方案必需）: $f"; fi
  done
  for f in "$ASSETS/$BT_MOD_FILE" "$FW_SRC/$BT_FW"; do
    if [ -f "$f" ]; then ok "存在 $(basename "$f")  ($(stat -c%s "$f") 字节)"
    else warn "未提供 $(basename "$f") —— 蓝牙方案可选，见 docs/bluetooth.md"; fi
  done
  [ -f "$BT_PATCH" ] && ok "存在 btusb-mt7902.patch" || warn "缺蓝牙补丁 $BT_PATCH"
  info "（完整 sha256 校验：bash tools/check-mt7902.sh assets）"

  sec "1. 内核与编译环境"
  info "运行内核: $KVER"
  [ -e "/lib/modules/$KVER/build" ] && ok "内核头文件就绪" || bad "缺少内核头文件"
  grep -q '^CONFIG_BT_HCIBTUSB_MTK=y' "/lib/modules/$KVER/build/.config" 2>/dev/null \
    && ok "CONFIG_BT_HCIBTUSB_MTK=y（蓝牙补丁生效的前提）" \
    || warn "CONFIG_BT_HCIBTUSB_MTK 非 y/m → 蓝牙补丁不会生效"
  grep -q '^CONFIG_MODULE_SIG_FORCE=y' "/lib/modules/$KVER/build/.config" 2>/dev/null \
    && bad "MODULE_SIG_FORCE=y → 未签名模块无法加载" \
    || ok "MODULE_SIG_FORCE 未设置 → 未签名模块可加载"

  sec "2. 板载卡是否仍需要本方案"
  if modinfo mt7921e 2>/dev/null | grep -q 'v000014C3d00007902'; then
    bad "内核自带 mt7921e 已支持 14c3:7902 → 不需要安装任何东西！"
  else
    ok "内核自带 mt7921e 仍不支持 7902 → 需要本方案"
  fi
  [ -e /sys/bus/pci/devices/0000:05:00.0/driver ] \
    && warn "板载卡已被驱动绑定（可能已装过）" \
    || ok "板载卡当前无驱动绑定（符合预期）"

  sec "3. 模块可加载性（符号解析）"
  local SY="$HERE/check-module-symbols.py"
  if [ -f "$SY" ]; then
    if command -v python3 >/dev/null 2>&1; then
      python3 "$SY" "$ASSETS/$WIFI_MOD.ko" "$ASSETS/$BT_MOD_FILE" 2>&1 | sed 's/^/  /'
    else
      warn "无 python3，跳过符号检查"
    fi
  else
    warn "缺 tools/check-module-symbols.py，跳过"
  fi

  sec "4. 当前网络基线（安装后需与此一致）"
  [ -n "$PROTECTED_IFACE" ] && \
    ip -brief addr show "$PROTECTED_IFACE" 2>/dev/null | sed 's/^/  /'
  printf "  默认路由: %s\n" "$(ip route show default 2>/dev/null)"
  lsmod 2>/dev/null | awk '/^aic/{printf "  %s\n",$0}'
  net_guard "基线"

  sec "5. 结论"
  echo "  Wi-Fi：mt7902e.ko（make 产物） + firmware/ 下 2 个固件 → /lib/modules/$KVER/extra/ 与 /lib/firmware/mediatek/"
  echo "  蓝牙 ：btusb.ko（自行构建） + 1 个固件 → /lib/modules/$KVER/updates/ 与 /lib/firmware/mediatek/"
  echo "  两者都不需要 blacklist、不需要 update-initramfs、不需要重启。"
  echo
  warn "危险提示：本方案有「硬件锁死」先例 —— 若 dmesg 出现 'driver own failed'，"
  echo "           普通重启无效，必须彻底断电（拔电源/扣 CR2032）才能恢复。"
  echo "           建议先只装 Wi-Fi，验证稳定后再装蓝牙。"
}

# ---------------------------------------------------------------------------
#  try：试加载 Wi-Fi 模块，不做任何持久化（panic 安全网）
#    - 固件放进 /lib/firmware（惰性文件，不触发任何加载，重启无害）
#    - 模块用 insmod 直接加载构建产物；不拷进 /lib/modules、不跑 depmod
#    - 万一 panic：断电重启后系统恢复原样，没有任何东西会开机自动加载
# ---------------------------------------------------------------------------
cmd_try() {
  need_yes; need_root
  sec "试加载前基线"
  net_guard "试加载前"

  # ⚠ 不用 "lsmod | grep -q"：pipefail 下 grep -q 提前退出会让 lsmod 吃 SIGPIPE，
  #   管道返回 141 → 误判未加载。读 /proc/modules 是确定性的。
  if grep -q "^$WIFI_MOD " /proc/modules; then
    ok "$WIFI_MOD 已经加载过了，无需重复试加载"
  else
    sec "放置固件（惰性文件，仅新增）"
    for f in "${WIFI_FW[@]}"; do
      [ -f "$FW_SRC/$f" ] || { bad "缺固件 $f（$FW_SRC）"; exit 1; }
      if [ -f "/lib/firmware/mediatek/$f" ]; then info "已存在，跳过: $f"
      else act "install $f → /lib/firmware/mediatek/"; run install -Dm 644 "$FW_SRC/$f" "/lib/firmware/mediatek/$f"; fi
    done
    net_guard "固件放置后"

    sec "加载依赖（mac80211 / cfg80211 / libarc4）"
    act "modprobe mac80211（不影响 AIC8800 —— 它只用 cfg80211）"
    run modprobe mac80211
    net_guard "加载 mac80211 后"

    sec "试加载 $WIFI_MOD（insmod 直接加载构建产物，绝不持久化）"
    act "insmod $ASSETS/$WIFI_MOD.ko"
    if [ "$DRY" != "1" ]; then
      if insmod "$ASSETS/$WIFI_MOD.ko" 2>&1 | sed 's/^/    /'; then :; fi
      sleep 4
    fi
    net_guard "试加载后（USB 网卡必须仍然正常）"
  fi

  sec "试加载结果"
  if [ "$DRY" = "1" ]; then
    info "dry-run：此处将检查 驱动绑定 / 新无线接口 / 内核日志"
  else
    if [ -e /sys/bus/pci/devices/0000:05:00.0/driver ]; then
      ok "板载卡已绑定驱动: $(basename "$(readlink -f /sys/bus/pci/devices/0000:05:00.0/driver)")"
    else
      bad "板载卡仍未绑定 → 看下方内核日志找原因；可用 rmmod $WIFI_MOD 退出"
    fi
    local newif; newif="$(for i in /sys/class/net/*/; do
        [ -d "${i}wireless" ] && basename "$i"; done | grep -vx "${PROTECTED_IFACE:-__no_such_iface__}" | head -1)"
    [ -n "$newif" ] && ok "新无线接口出现: $newif" || warn "尚未出现新无线接口"
    local log=""
    dmesg >/dev/null 2>&1 && log="$(dmesg 2>/dev/null | tail -200)"
    [ -z "$log" ] && log="$(journalctl -k --no-pager -b 2>/dev/null | tail -200)"
    if [ -n "$log" ]; then
      printf '%s\n' "$log" | grep -iE 'mt7902|7902|05:00' | tail -12 | sed 's/^/    /'
      printf '%s\n' "$log" | grep -qi 'driver own failed' \
        && bad "出现 'driver own failed' → 需彻底断电恢复（拔电源/扣电池）" \
        || ok "未见 'driver own failed'"
    fi
  fi

  sec "下一步"
  echo "  若上面全部 ✓："
  echo "    1) 观察几分钟，确认网络稳定、无异常"
  echo "    2) bash $0 verify                        # 再复核一遍"
  echo "    3) sudo bash $0 install --wifi --yes     # 确认可用后才持久化（开机自动加载）"
  echo "  若出现异常（未 panic 的情况下）："
  echo "    sudo rmmod $WIFI_MOD                     # 立即卸载，回到原状"
  echo "  若发生 panic：直接断电重启 —— 本次试加载没有任何持久化，"
  echo "    重启后系统会自动回到只有 USB 网卡的状态。"
}

# ---------------------------------------------------------------------------
cmd_install() {
  need_yes
  [ "$DO_WIFI" = "0" ] && [ "$DO_BT" = "0" ] && { bad "未指定目标，请加 --wifi 或 --bt 或 --all"; exit 1; }
  need_root
  sec "安装前基线"
  net_guard "安装前"
  if [ "$DRY" = "1" ]; then
    act "写基线文件 $STATE（dry-run 跳过）"
  else
    { echo "KVER=$KVER"; echo "TIME=$(date -Is)"; echo "MODE=wifi:$DO_WIFI bt:$DO_BT";
      ls /lib/firmware/mediatek/ 2>/dev/null > "$STATE.fw-before"; } > "$STATE"
    ok "基线已记录: $STATE"
  fi

  if [ "$DO_WIFI" = "1" ]; then
    sec "安装 Wi-Fi"
    assert_not_dkms_managed
    assert_assets_matches_kernel
    act "mkdir -p /lib/modules/$KVER/extra"
    run install -d "/lib/modules/$KVER/extra"
    act "cp 固件 ×2 → /lib/firmware/mediatek/（仅新增，不覆盖）"
    for f in "${WIFI_FW[@]}"; do
      [ -f "$FW_SRC/$f" ] || { bad "缺固件 $f（$FW_SRC）"; exit 1; }
      if [ -f "/lib/firmware/mediatek/$f" ]; then info "已存在，跳过: $f"
      else run install -Dm 644 "$FW_SRC/$f" "/lib/firmware/mediatek/$f"; fi
    done
    act "cp 模块 → /lib/modules/$KVER/extra/$WIFI_MOD.ko"
    run install -Dm 644 "$ASSETS/$WIFI_MOD.ko" "/lib/modules/$KVER/extra/$WIFI_MOD.ko"
    act "depmod -a"
    run depmod -a "$KVER"
    ok "Wi-Fi 文件就位（尚未加载模块）"
    net_guard "Wi-Fi 文件就位后"
    act "modprobe $WIFI_MOD"
    if [ "$DRY" = "1" ]; then act "modprobe $WIFI_MOD"; else
      modprobe "$WIFI_MOD" 2>&1 | sed 's/^/    /'
      sleep 3
    fi
    net_guard "加载 Wi-Fi 模块后"
  fi

  if [ "$DO_BT" = "1" ]; then
    sec "安装蓝牙（替换内核自带 btusb）"
    local stock="/lib/modules/$KVER/kernel/drivers/bluetooth/btusb.ko"
    if [ -f "$stock" ] && [ ! -f "${stock}.mt7902-backup" ]; then
      act "备份原模块 → ${stock}.mt7902-backup"
      run cp -p "$stock" "${stock}.mt7902-backup"
    else
      info "已有备份或原模块不存在，跳过备份"
    fi
    if [ -f "/lib/firmware/mediatek/$BT_FW" ]; then info "蓝牙固件已存在，跳过"
    else run install -Dm 644 "$FW_SRC/$BT_FW" "/lib/firmware/mediatek/$BT_FW"; fi
    act "cp 模块 → /lib/modules/$KVER/updates/$BT_MOD_FILE（updates/ 优先于 kernel/）"
    run install -Dm 644 "$ASSETS/$BT_MOD_FILE" "/lib/modules/$KVER/updates/$BT_MOD_FILE"
    run depmod -a "$KVER"
    warn "重载 btusb 会短暂中断蓝牙；确认没有在用蓝牙输入设备"
    act "modprobe -r btusb && modprobe btusb"
    if [ "$DRY" != "1" ]; then
      modprobe -r btusb 2>/dev/null; sleep 1; modprobe btusb 2>&1 | sed 's/^/    /'; sleep 3
    fi
    net_guard "蓝牙操作后"
  fi

  sec "完成"
  echo "  下一步： bash $0 verify"
}

# ---------------------------------------------------------------------------
cmd_verify() {
  sec "Wi-Fi"
  if lsmod 2>/dev/null | grep -q "^$WIFI_MOD"; then
    ok "$WIFI_MOD 已加载"
    [ -e "/sys/bus/pci/devices/0000:05:00.0/driver" ] \
      && ok "板载卡已绑定: $(basename "$(readlink -f /sys/bus/pci/devices/0000:05:00.0/driver)")" \
      || warn "模块已加载但板载卡仍未绑定（看 dmesg 找原因）"
    local newif; newif="$(for i in /sys/class/net/*/; do
        [ -d "${i}wireless" ] && basename "$i"; done | grep -vx "${PROTECTED_IFACE:-__no_such_iface__}" | head -1)"
    [ -n "$newif" ] && ok "新无线接口: $newif" || warn "未见新的无线接口"
  else
    warn "$WIFI_MOD 未加载（尚未安装）"
  fi
  net_guard "Wi-Fi 校验"

  sec "蓝牙"
  if [ -f "/lib/modules/$KVER/updates/btusb.ko" ]; then
    ok "updates/btusb.ko 已就位"
    local sv; sv="$(modinfo -F srcversion "/lib/modules/$KVER/updates/btusb.ko" 2>/dev/null)"
    info "srcversion=$sv（系统自带为 336B8A418C3CF8CAEF8D88A）"
    if command -v hciconfig >/dev/null 2>&1; then
      local addr; addr="$(hciconfig hci0 2>/dev/null | grep -oP 'BD Address: \K[0-9A-F:]+')"
      case "$addr" in
        00:00:00:00:00:00|"") bad "BD Address 仍全零 → 固件未加载成功" ;;
        *) ok "BD Address=$addr → 蓝牙已初始化" ;;
      esac
    fi
  else
    warn "未安装蓝牙模块"
  fi

  sec "内核日志判读"
  local log=""
  command -v dmesg >/dev/null 2>&1 && dmesg >/dev/null 2>&1 && log="$(dmesg 2>/dev/null)"
  [ -z "$log" ] && command -v journalctl >/dev/null 2>&1 && log="$(journalctl -k --no-pager -b 2>/dev/null)"
  [ -z "$log" ] && [ -r /var/log/kern.log ] && log="$(cat /var/log/kern.log 2>/dev/null)"
  if [ -z "$log" ]; then warn "读不到内核日志（试试 sudo）"; else
    printf '%s\n' "$log" | grep -iE 'mt7902|mt79|hci0|btusb' | tail -15 | sed 's/^/    /'
    printf '%s\n' "$log" | grep -qi 'driver own failed' \
      && bad "出现 driver own failed → 硬件可能锁死，需彻底断电恢复" \
      || ok "未见 driver own failed"
    printf '%s\n' "$log" | grep -qiE 'Kernel panic|BUG: kernel NULL' \
      && bad "发现 panic 记录！" || ok "未见 panic"
  fi
  net_guard "最终校验"
}

# ---------------------------------------------------------------------------
cmd_uninstall() {
  need_yes; need_root
  [ "$DO_WIFI" = "0" ] && [ "$DO_BT" = "0" ] && { DO_WIFI=1; DO_BT=1; info "未指定目标，默认卸载全部"; }
  if [ "$DO_WIFI" = "1" ]; then
    sec "卸载 Wi-Fi"
    act "modprobe -r $WIFI_MOD"
    run modprobe -r "$WIFI_MOD"
    act "rm /lib/modules/$KVER/extra/$WIFI_MOD.ko"
    run rm -f "/lib/modules/$KVER/extra/$WIFI_MOD.ko"
    for f in "${WIFI_FW[@]}"; do act "rm /lib/firmware/mediatek/$f"; run rm -f "/lib/firmware/mediatek/$f"; done
    run depmod -a "$KVER"
    ok "Wi-Fi 已回滚"
  fi
  if [ "$DO_BT" = "1" ]; then
    sec "卸载蓝牙"
    act "rm /lib/modules/$KVER/updates/btusb.ko"
    run rm -f "/lib/modules/$KVER/updates/btusb.ko"
    run depmod -a "$KVER"
    act "modprobe -r btusb && modprobe btusb（恢复用系统自带模块）"
    if [ "$DRY" != "1" ]; then modprobe -r btusb 2>/dev/null; sleep 1; modprobe btusb 2>/dev/null; fi
    act "rm /lib/firmware/mediatek/$BT_FW"
    run rm -f "/lib/firmware/mediatek/$BT_FW"
    ok "蓝牙已回滚"
  fi

  sec "残留核查（与基线对比）"
  if [ -f "$STATE.fw-before" ]; then
    ls /lib/firmware/mediatek/ 2>/dev/null | diff "$STATE.fw-before" - \
      | sed 's/^/  /' || true
    info "（无输出 = 固件目录与安装前完全一致）"
  fi
  net_guard "回滚后"
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  preflight)  cmd_preflight ;;
  try)        cmd_try ;;
  install)    cmd_install ;;
  verify)     cmd_verify ;;
  uninstall)  cmd_uninstall ;;
  *)          sed -n '3,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
esac
