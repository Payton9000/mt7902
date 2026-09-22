#!/usr/bin/env bash
# =============================================================================
#  build_btusb_mt7902.sh  ——  为 Ubuntu 6.8 内核构建支持 MT7902 蓝牙的 btusb.ko
#
#  ★ 本脚本只构建，不安装。产物落在一个独立目录里，由你自行决定是否部署。
#
#  背景（一句话）：
#    内核自带 btusb 不认 13d3:3596（MT7902 的蓝牙），因为
#      (a) quirks_table 里没有 13d3:3596 这一条
#      (b) btusb_mtk_setup() 的 switch (dev_id) 里没有 case 0x7902
#    两处都补上即可。固件名由命名规律自动拼出，与 linux-firmware 的文件名一致。
#
#  ⚠ 极其重要：必须使用【发行版自己的源码】，不要用 torvalds/linux 的同版本 tag！
#     Ubuntu 在 6.8 的维护期里回移了大量上游改动（HCI_AMP 移除、
#     HCI_QUIRK_VALID_LE_STATES → BROKEN_LE_STATES 等），主线 v6.8 的 btusb.c
#     在这套头文件下【编译不过】。本脚本默认走发行版源码包路线。
#
#  用法：
#    bash build_btusb_mt7902.sh              # 全流程（需要已解包的 Ubuntu 源码树）
#    bash build_btusb_mt7902.sh --fetch-src   # 顺便下载并解包发行版源码（约 230MB）
#    bash build_btusb_mt7902.sh --verify      # 只校验已有产物
# =============================================================================
set -uo pipefail

KVER="${KVER:-$(uname -r)}"
WORK="${WORK:-$HOME/mt7902-bt}"
SRC_ROOT="${SRC_ROOT:-}"          # 指向解包后的发行版源码树（含 drivers/bluetooth）
PATCH="${PATCH:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../patches/btusb/btusb-mt7902.patch}"

# 发行版源码包坐标（Ubuntu 22.04 HWE 6.8）
UBUNTU_POOL="https://mirrors.tuna.tsinghua.edu.cn/ubuntu/pool/main/l/linux-hwe-6.8"
UBUNTU_VER="6.8.0-138.138~22.04.1"
UBUNTU_SRC_PKG="linux-hwe-6.8"

C_G="\033[32m"; C_Y="\033[33m"; C_R="\033[31m"; C_B="\033[36m"; C_N="\033[0m"
ok()   { printf "  ${C_G}✓${C_N} %s\n" "$*"; }
warn() { printf "  ${C_Y}!${C_N} %s\n" "$*"; }
bad()  { printf "  ${C_R}✗${C_N} %s\n" "$*"; }
info() { printf "  ${C_B}·${C_N} %s\n" "$*"; }
sec()  { printf "\n${C_B}══ %s ══${C_N}\n" "$*"; }

# ---------------------------------------------------------------------------
fetch_src() {
  sec "下载并解包发行版内核源码"
  mkdir -p "$WORK/src" && cd "$WORK/src"
  for f in "${UBUNTU_SRC_PKG}_${UBUNTU_VER}.dsc" \
           "${UBUNTU_SRC_PKG}_${UBUNTU_VER}.diff.gz" \
           "${UBUNTU_SRC_PKG}_6.8.0.orig.tar.gz"; do
    [ -f "$f" ] && { info "已存在 $f"; continue; }
    local enc; enc="$(printf '%s' "$f" | sed 's/~/%7E/g')"
    info "下载 $f"
    wget -q --timeout=900 --tries=2 -O "$f" "$UBUNTU_POOL/$enc" || { bad "下载失败: $f"; return 1; }
    ls -la "$f" | sed 's/^/    /'
  done
  if [ ! -d "${UBUNTU_SRC_PKG}-6.8.0" ]; then
    info "解包（dpkg-source -x，约 1.5GB，需要一两分钟）"
    dpkg-source -x "${UBUNTU_SRC_PKG}_${UBUNTU_VER}.dsc" >/dev/null 2>&1
  fi
  SRC_ROOT="$WORK/src/${UBUNTU_SRC_PKG}-6.8.0"
  if [ -f "$SRC_ROOT/drivers/bluetooth/btusb.c" ]; then
    ok "源码树就绪: $SRC_ROOT"
  else
    bad "解包失败，未找到 drivers/bluetooth/btusb.c"; return 1
  fi
}

# ---------------------------------------------------------------------------
resolve_src_root() {
  [ -n "$SRC_ROOT" ] && return 0
  local c
  for c in "$WORK/src/${UBUNTU_SRC_PKG}-6.8.0" \
           "$HOME/mt7902-experiment/ubuntu-kernel-src/${UBUNTU_SRC_PKG}-6.8.0"; do
    [ -f "$c/drivers/bluetooth/btusb.c" ] && { SRC_ROOT="$c"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
build() {
  sec "前置检查"
  info "目标内核: $KVER"
  local B="/lib/modules/$KVER/build"
  [ -e "$B" ] || { bad "缺少内核头文件 $B → 先装 linux-headers-$KVER"; return 1; }
  ok "内核头文件: $(readlink -f "$B")"
  command -v patch >/dev/null || { bad "缺 patch 命令"; return 1; }
  grep -q '^CONFIG_BT_HCIBTUSB_MTK=y' "$B/.config" 2>/dev/null \
    && ok "CONFIG_BT_HCIBTUSB_MTK=y（补丁生效的前提，已满足）" \
    || warn "CONFIG_BT_HCIBTUSB_MTK 非 y/m → 补丁不会生效"

  sec "定位发行版源码"
  if ! resolve_src_root; then
    bad "未找到发行版源码树。请先运行:  bash $0 --fetch-src"
    return 1
  fi
  local U="$SRC_ROOT/drivers/bluetooth"

  sec "源码正确性校验（判断是不是发行版打过补丁的那一份）"
  local n1 n2
  n1="$(grep -c 'HCI_AMP' "$U/btusb.c" 2>/dev/null)"
  n2="$(grep -c 'HCI_QUIRK_VALID_LE_STATES' "$U/btusb.c" 2>/dev/null)"
  if [ "$n1" -eq 0 ] && [ "$n2" -eq 0 ]; then
    ok "特征符合发行版版本（HCI_AMP / VALID_LE_STATES 已被回移移除）"
  else
    warn "特征不符合（HCI_AMP=$n1, VALID_LE_STATES=$n2）—— 可能拿的是主线源码，会编译失败"
  fi

  sec "准备构建目录"
  local W="$WORK/build-$KVER"
  mkdir -p "$W"
  local f
  for f in btusb.c btintel.h btbcm.h btrtl.h btmtk.h; do
    [ -f "$U/$f" ] || { bad "源码缺文件: $f"; return 1; }
    cp -f "$U/$f" "$W/$f"
  done
  ok "已复制 btusb.c 与 4 个头文件"

  sec "打补丁"
  if grep -q '0x13d3, 0x3596' "$W/btusb.c"; then
    info "补丁似已应用，跳过"
  else
    if patch --forward --silent -p0 "$W/btusb.c" < "$PATCH"; then
      ok "补丁已应用（2 处，共 +6 行）"
    else
      bad "补丁应用失败 —— 请检查 $PATCH 是否与你的源码匹配"
      return 1
    fi
  fi

  sec "校验补丁落点正确（必须在 quirks_table 内）"
  local qs qe n
  qs="$(grep -n 'static const struct usb_device_id quirks_table\[\]' "$W/btusb.c" | cut -d: -f1)"
  qe="$(awk -v s="$qs" 'NR>s && /^\};/ {print NR; exit}' "$W/btusb.c")"
  n="$(grep -n '0x13d3, 0x3596' "$W/btusb.c" | cut -d: -f1)"
  if [ -n "$qs" ] && [ -n "$n" ] && [ "$n" -gt "$qs" ] && [ "$n" -lt "$qe" ]; then
    ok "设备条目位于 quirks_table（第 $qs–$qe 行内的第 $n 行）—— 位置正确"
  else
    bad "设备条目不在 quirks_table 内，运行时不会生效！"
    return 1
  fi
  grep -q '	case 0x7902:' "$W/btusb.c" && ok "switch 中已加入 case 0x7902" || { bad "缺 case 0x7902"; return 1; }

  sec "编译"
  printf 'obj-m := btusb.o\nKDIR ?= /lib/modules/%s/build\nPWD := $(shell pwd)\nall:\n\t$(MAKE) -C $(KDIR) M=$(PWD) modules\nclean:\n\t$(MAKE) -C $(KDIR) M=$(PWD) clean\n' "$KVER" > "$W/Makefile"
  ( cd "$W" && make -j"$(nproc)" ) 2>&1 | tail -15
  [ -f "$W/btusb.ko" ] || { bad "编译失败，未生成 btusb.ko"; return 1; }
  ok "产物: $W/btusb.ko ($(stat -c%s "$W/btusb.ko") 字节)"

  verify "$W/btusb.ko"
}

# ---------------------------------------------------------------------------
verify() {
  local ko="${1:-}"
  if [ -z "$ko" ]; then
    local c
    for c in "$WORK/build-$KVER/btusb.ko" \
             "$HOME/mt7902-experiment/btusb-build-ubuntu/btusb.ko" \
             "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../btusb.ko"; do
      [ -f "$c" ] && { ko="$c"; break; }
    done
  fi
  sec "产物校验"
  [ -n "$ko" ] && [ -f "$ko" ] || { bad "找不到 btusb.ko，请先运行不带参数的构建流程"; return 1; }
  info "校验对象: $ko"
  printf '  name      : %s\n' "$(modinfo -F name "$ko")"
  printf '  vermagic  : %s\n' "$(modinfo -F vermagic "$ko")"
  printf '  depends   : %s\n' "$(modinfo -F depends "$ko")"
  modinfo -F vermagic "$ko" | grep -q "$KVER" && ok "vermagic 与运行内核匹配" || bad "vermagic 不匹配"
  printf '\n  %s\n' "对照：系统自带 btusb"
  printf '  depends   : %s\n' "$(modinfo -F depends /lib/modules/$KVER/kernel/drivers/bluetooth/btusb.ko 2>/dev/null)"
  echo
  info "alias 列表与系统自带一致是【正常的】—— 设备表 quirks_table 不通过"
  info "MODULE_DEVICE_TABLE 导出，因此不产生 alias。设备匹配在运行时由"
  info "btusb_probe() 内部对 quirks_table 的二次查找完成。"
  echo
  info "部署（需自行执行，本脚本不代劳）："
  cat <<EOT
    sudo cp $ko /lib/modules/$KVER/updates/btusb.ko     # updates/ 优先级高于 kernel/
    sudo depmod -a
    sudo modprobe -r btusb && sudo modprobe btusb       # 先确保无进程占用蓝牙
    hciconfig -a                                        # 期望 BD Address 不再是全零
EOT
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  --fetch-src)  fetch_src && build ;;
  --verify)     verify "${2:-}" ;;
  ""|--build)   build ;;
  *)            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
esac
