#!/usr/bin/env bash
# =============================================================================
#  setup_mt7902_dkms.sh  ——  把 mt7902e 驱动注册为 DKMS 包（内核升级后自动重编）
#
#  背景：模块原本只是一份放在 /lib/modules/<kver>/extra/ 里的 .ko。
#        本机是 Ubuntu 22.04.5 LTS（HWE 内核 6.8），日常 `apt upgrade` 会带来
#        6.8.0-139、-140… 新内核；新内核目录下没有这个 .ko，板载网卡就会
#        重新变成「无驱动」。DKMS 解决方式：源码装进 /usr/src/mt7902e-1.0，
#        dkms add/build/install 之后，每次安装新内核，dkms 的 kernel hook
#        （/etc/kernel/postinst.d/dkms）会自动为新内核重编并安装。
#
#  ★ 本机实测的两条 Ubuntu 特性（已按此设计）：
#    1) dkms 会强制把安装目标改写成 /updates/dkms
#       （/usr/sbin/dkms 的 override_dest_module_location()：Ubuntu* → /updates/dkms），
#       dkms.conf 里写 /extra 或 /kernel/... 都无效。故本脚本明确用 /updates/dkms。
#    2) dkms 的 POST_INSTALL 只接受「可执行脚本文件」，不接内联命令
#       （run_build_script() 会 cwd 到 source/ 再 exec）。因此固件不交给 dkms，
#       由本脚本自己确保 /lib/firmware/mediatek/ 下两个 .bin 在位。
#
#  设计约定（与 deploy_mt7902.sh 一致）：
#    * 子命令： preflight | install | verify | uninstall
#    * --dry-run 只打印动作；破坏性动作（install/uninstall）必须加 --yes
#    * 任何一步失败即停，并打印回滚办法
#
#  ★ 安全底线：
#    - 不重启、不动 initramfs、不改 /etc、不 blacklist 任何模块
#    - 只写 /usr/src/mt7902e-1.0、/lib/modules/<kver>/updates/dkms/、/lib/firmware/mediatek/
#      （绝不触碰 kernel/ 下的原厂 mt76 模块）
#    - install 前把现有 extra/mt7902e.ko 备份到 /var/backups/mt7902/
#    - 顺序保证：先让 dkms 装好新副本并校验通过，再清理 extra/ 下的旧副本
#      → 任何时刻都至少有一份可用模块
#    - 每一步都复核「默认路由有没有变」，避免把仅有的一块网卡搞掉
#    - 最后断言 DKMS 产物的 srcversion == 构建产物已验收修复版的 srcversion
#
#  用法：
#    bash setup_mt7902_dkms.sh preflight                     # 只读体检（可反复跑）
#    sudo bash setup_mt7902_dkms.sh install --yes            # 注册 DKMS（不重启、不断网）
#    sudo bash setup_mt7902_dkms.sh install --yes --keep-extra   # 保留 extra/ 下旧副本
#    bash setup_mt7902_dkms.sh verify                        # 只读验收
#    sudo bash setup_mt7902_dkms.sh uninstall --yes          # 卸载 DKMS 注册
#
#  环境变量：MT7902_SRC=/path/to/mt7902  覆盖源码树位置
# =============================================================================
set -uo pipefail

KVER="${KVER:-$(uname -r)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 源码树 = 本仓库根目录（本脚本位于 dkms/ 下），可用 MT7902_SRC 覆盖。
SRC_TREE="${MT7902_SRC:-$(cd "$HERE/.." && pwd)}"
ASSETS="${MT7902_ASSETS:-$SRC_TREE}"   # .ko 产物目录；make 的输出落在仓库根

DKMS_MOD="mt7902e"
DKMS_VER="1.0"
DKMS_SRC="/usr/src/${DKMS_MOD}-${DKMS_VER}"
# Ubuntu 的 dkms 会强制覆盖成这个路径，这里与之一致，避免误解。
DKMS_DEST="/updates/dkms"
BACKUP_ROOT="/var/backups/mt7902"
FW_DIR="/lib/firmware/mediatek"
FW_FILES=(WIFI_MT7902_patch_mcu_1_1_hdr.bin WIFI_RAM_CODE_MT7902_1.bin)

DRY=0; YES=0; KEEP_EXTRA=0
for a in "$@"; do
  case "$a" in
    --dry-run)     DRY=1 ;;
    --yes|-y)      YES=1 ;;
    --keep-extra)  KEEP_EXTRA=1 ;;
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

ROUTE_BEFORE=""
snap_route() { ROUTE_BEFORE="$(ip route show default 2>/dev/null)"; }
route_guard() {
  local tag="$1" after
  after="$(ip route show default 2>/dev/null)"
  if [ "$after" = "$ROUTE_BEFORE" ]; then
    ok "默认路由未变（$tag）"
  else
    bad "默认路由发生变化（$tag）！"
    printf "      之前: %s\n      现在: %s\n" "${ROUTE_BEFORE:-<无>}" "${after:-<无>}"
    bad "请立刻检查网络；回滚：sudo bash $0 uninstall --yes"
    exit 1
  fi
}

expect_srcversion()    { modinfo "$ASSETS/mt7902e.ko" 2>/dev/null | awk '/^srcversion:/{print $2}'; }
installed_srcversion() { modinfo -k "$KVER" "$DKMS_MOD" 2>/dev/null | awk '/^srcversion:/{print $2}'; }
loaded_srcversion()    { cat "/sys/module/$DKMS_MOD/srcversion" 2>/dev/null; }

module_path_of() { modinfo -k "${1:-$KVER}" "$DKMS_MOD" 2>/dev/null | awk '/^filename:/{print $2}'; }

# 列出所有内核目录下的 mt7902e.ko（含 extra/ 与 updates/dkms/）
all_module_files() {
  find /lib/modules/*/extra/$DKMS_MOD.ko /lib/modules/*/updates/dkms/$DKMS_MOD.ko 2>/dev/null | sort
}

ensure_firmware() {
  local f
  for f in "${FW_FILES[@]}"; do
    if [ -f "$FW_DIR/$f" ]; then
      ok "$f 已在位"
    elif [ -f "$SRC_TREE/firmware/$f" ]; then
      run install -Dm 644 "$SRC_TREE/firmware/$f" "$FW_DIR/$f" && ok "已补装 $f"
    else
      bad "$f 缺失，且源码树里也没有（网卡将无法工作）"
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
cmd_preflight() {
  sec "1. 运行环境"
  info "内核: $KVER"
  info "源码树: $SRC_TREE"
  info "DKMS 目标: $DKMS_SRC   （包 $DKMS_MOD/$DKMS_VER，安装位置 $DKMS_DEST）"
  if [ -r /etc/os-release ]; then info "$(grep -m1 PRETTY_NAME /etc/os-release | cut -d'"' -f2)"; fi

  sec "2. DKMS 与内核头文件"
  if command -v dkms >/dev/null; then ok "dkms: $(dkms --version 2>&1)"; else bad "未安装 dkms（sudo apt install dkms）"; return 1; fi
  if [ -d "/lib/modules/$KVER/build" ]; then
    ok "内核头文件就绪: $(readlink -f /lib/modules/$KVER/build)"
  else
    bad "缺少 /lib/modules/$KVER/build（sudo apt install linux-headers-$KVER）"; return 1
  fi
  if [ -x /etc/kernel/postinst.d/dkms ]; then
    ok "dkms 内核钩子存在（装新内核时会自动触发重编）"
  else
    warn "未发现 /etc/kernel/postinst.d/dkms：内核升级后需手动 dkms autoinstall"
  fi

  sec "3. 源码树与补丁完整性"
  if [ -d "$SRC_TREE/src" ]; then ok "源码在: $SRC_TREE"; else bad "源码树不存在：$SRC_TREE"; return 1; fi
  if grep -q 'return hw->priv;' "$SRC_TREE/src/mac80211.c"; then
    ok "补丁① mt76_vif_phy() 修复在位（关联失败 bug）"
  else
    bad "补丁① 未打：src/mac80211.c 里没有 return hw->priv"; return 1
  fi
  if grep -Eq '^[[:space:]]*init_dummy_netdev[[:space:]]*\(' "$SRC_TREE/src/dma.c"; then
    bad "补丁② 未打：src/dma.c 仍在调用 init_dummy_netdev()（会复现关机 oops）"; return 1
  else
    ok "补丁② teardown 修复在位（未调用 init_dummy_netdev）"
  fi
  if grep -q 'set_bit(__LINK_STATE_PRESENT, &dev->state)' "$SRC_TREE/src/dma.c"; then
    ok "补丁② 内容正确（只置链路状态位，不 memset）"
  else
    warn "未找到 set_bit(__LINK_STATE_PRESENT,...)，建议人工复核 dma.c 兼容层"
  fi

  sec "4. 当前模块三方对照（构建产物 / 已安装 / 已加载）"
  local exp inst load
  exp="$(expect_srcversion)"; inst="$(installed_srcversion)"; load="$(loaded_srcversion)"
  info "构建产物（已验收修复版）: ${exp:-<缺>}"
  info "已安装（磁盘）        : ${inst:-<无>}   $(module_path_of)"
  info "已加载（内存）        : ${load:-<未加载>}"
  if [ -n "$exp" ] && [ "$exp" = "$inst" ]; then ok "磁盘上的模块就是修复版"; else warn "磁盘模块与 assets 不一致"; fi

  sec "5. 模块文件分布（应只有一份）"
  local files n
  files="$(all_module_files)"; n="$(printf '%s\n' "$files" | grep -c . || true)"
  if [ -n "$files" ]; then printf '%s\n' "$files" | sed 's/^/  /'; fi
  [ "$n" -le 1 ] && ok "只有 1 份模块文件" || warn "存在 $n 份模块文件（depmod 优先 updates/，安装 DKMS 后会清理 extra/ 下的旧副本）"

  sec "6. 固件"
  ensure_firmware >/dev/null 2>&1 && ok "两个固件均就位" || warn "固件不完整（install 时会尝试补装）"

  sec "7. 磁盘空间（/usr）"
  df -h /usr 2>/dev/null | sed 's/^/  /'
  local avail
  avail=$(df -Pk /usr 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "$avail" ] && [ "$avail" -gt 102400 ]; then ok "空间充足（>100MB）"; else warn "空间偏紧"; fi

  sec "8. 网络基线"
  snap_route
  ip -brief addr show 2>/dev/null | grep -E '^(wl|en)' | sed 's/^/  /' || true
  info "默认路由: ${ROUTE_BEFORE:-<无>}"

  sec "9. 现有 DKMS 注册"
  dkms status 2>/dev/null | sed 's/^/  /' || true
  local st; st="$(dkms status -m "$DKMS_MOD" -v "$DKMS_VER" 2>/dev/null)"
  if [ -n "$st" ]; then ok "已注册: $st"; else info "尚未注册 $DKMS_MOD/$DKMS_VER"; fi
}

# ---------------------------------------------------------------------------
write_dkms_conf() {
  cat > "$DKMS_SRC/dkms.conf" <<EOF
PACKAGE_NAME="$DKMS_MOD"
PACKAGE_VERSION="$DKMS_VER"

BUILT_MODULE_NAME[0]="$DKMS_MOD"
BUILT_MODULE_LOCATION[0]="."
# 说明：Ubuntu 版 dkms 会在内部把它改写成 $DKMS_DEST（override_dest_module_location），
# 这里如实写上实际位置，避免以后误判「为什么没装到 extra/」。
DEST_MODULE_LOCATION[0]="$DKMS_DEST"

MAKE[0]="make KVER=\$kernelver"
CLEAN="make clean || true"

# 固件不在此处理：dkms 的 POST_INSTALL 只接受可执行脚本文件，
# 而固件与内核版本无关（不会被内核升级影响），由安装脚本负责确保在位。
AUTOINSTALL="yes"
EOF
}

stage_source() {
  rm -rf "$DKMS_SRC"
  mkdir -p "$DKMS_SRC"
  tar -C "$SRC_TREE" -c \
      --exclude=.git --exclude='*.o' --exclude='*.ko' --exclude='*.cmd' \
      --exclude='*.mod' --exclude='*.mod.c' --exclude='Module.symvers' \
      --exclude='modules.order' --exclude='.tmp_versions' --exclude='*.tmp*' \
      . | tar -C "$DKMS_SRC" -x
}

cmd_install() {
  need_root; need_yes
  cmd_preflight || { bad "体检未通过，已中止"; exit 1; }
  route_guard "体检后"

  local ts backup_dir ko_extra
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_dir="$BACKUP_ROOT/$ts"
  ko_extra="/lib/modules/$KVER/extra/$DKMS_MOD.ko"

  sec "① 备份现有模块"
  run install -d -m 755 "$backup_dir"
  if [ -e "$ko_extra" ]; then
    run cp -a "$ko_extra" "$backup_dir/"
    ok "已备份: $backup_dir/$DKMS_MOD.ko"
  else
    info "extra/ 下暂无 $DKMS_MOD.ko（无需备份）"
  fi
  if [ "$DRY" = "1" ]; then
    act "写记录到 $backup_dir/README"
  else
    { echo "备份时间: $ts"; echo "内核: $KVER"
      echo "已安装 srcversion: $(installed_srcversion)"
      echo "已加载 srcversion: $(loaded_srcversion)"
      echo "恢复: sudo install -Dm 644 $backup_dir/$DKMS_MOD.ko $ko_extra && sudo depmod -a $KVER"
      echo "卸载 DKMS: sudo bash $HERE/setup_mt7902_dkms.sh uninstall --yes"; } > "$backup_dir/README"
  fi

  sec "② 部署源码到 $DKMS_SRC"
  if [ "$DRY" = "1" ]; then
    act "复制源码 $SRC_TREE → $DKMS_SRC（排除 .git/*.o/*.ko/*.cmd）"
    act "写入 dkms.conf（DEST_MODULE_LOCATION=$DKMS_DEST）"
  else
    stage_source && write_dkms_conf
    ok "源码就位: $(du -sh "$DKMS_SRC" 2>/dev/null | cut -f1)"
  fi

  sec "③ 注册并构建 DKMS 模块"
  if [ "$DRY" = "1" ]; then
    act "dkms remove -m $DKMS_MOD -v $DKMS_VER --all   （清掉旧注册，忽略报错）"
    act "dkms add     -m $DKMS_MOD -v $DKMS_VER"
    act "dkms build   -m $DKMS_MOD -v $DKMS_VER -k $KVER"
    act "dkms install -m $DKMS_MOD -v $DKMS_VER -k $KVER --force"
    act "depmod -a $KVER"
    act "清理 extra/ 下旧副本: rm -f $ko_extra"
    act "depmod -a $KVER"
    printf "\n  ${C_Y}[dry-run] 未做任何改动${C_N}\n"; return 0
  fi
  dkms remove -m "$DKMS_MOD" -v "$DKMS_VER" --all >/dev/null 2>&1 || true
  dkms add -m "$DKMS_MOD" -v "$DKMS_VER" >/dev/null || { bad "dkms add 失败"; exit 1; }
  ok "dkms add"
  dkms build -m "$DKMS_MOD" -v "$DKMS_VER" -k "$KVER" || { bad "dkms build 失败（见上方输出）；系统未受影响，extra/ 下的模块还在"; exit 1; }
  ok "dkms build"
  dkms install -m "$DKMS_MOD" -v "$DKMS_VER" -k "$KVER" --force || { bad "dkms install 失败；系统未受影响"; exit 1; }
  ok "dkms install"
  depmod -a "$KVER" && ok "depmod 已刷新"

  sec "④ 断言：装上去的就是已验收的修复版"
  local exp got path
  exp="$(expect_srcversion)"; got="$(installed_srcversion)"; path="$(module_path_of)"
  info "modprobe 现在解析到: ${path:-<未找到>}"
  info "srcversion: ${got:-<无>}  (期望 ${exp:-<无>})"
  if [ -n "$exp" ] && [ "$exp" = "$got" ]; then
    ok "srcversion 与已验收版本一致"
  else
    bad "srcversion 不一致！DKMS 产物可能不是你验证过的那份源码"
    printf "      期望: %s\n      实际: %s\n" "$exp" "$got"
    bad "建议回滚: sudo bash $0 uninstall --yes"
    exit 1
  fi
  if [ -n "$path" ] && nm -u "$path" 2>/dev/null | grep -qi 'init_dummy_netdev'; then
    bad "产物仍在引用 init_dummy_netdev —— teardown 修复未生效！"; exit 1
  else
    ok "产物未引用 init_dummy_netdev（teardown 修复就位）"
  fi

  sec "⑤ 清理 extra/ 下的旧副本（此时新副本已就位并校验通过）"
  if [ "$KEEP_EXTRA" = "1" ]; then
    warn "--keep-extra 已指定，保留 $ko_extra（两份内容相同，depmod 优先 updates/）"
  elif [ -f "$ko_extra" ]; then
    rm -f "$ko_extra" && depmod -a "$KVER"
    ok "已删除 $ko_extra（备份在 $backup_dir/）"
  else
    info "extra/ 下无旧副本"
  fi
  all_module_files | sed 's/^/  /'

  sec "⑥ 网络与持久化复核"
  ensure_firmware
  route_guard "安装后"
  info "已加载（内存）: $(loaded_srcversion)  ← 重启后才换成 DKMS 产物（内容相同，srcversion 一致）"
  dkms status -m "$DKMS_MOD" -v "$DKMS_VER" 2>/dev/null | sed 's/^/  /'
  if [ -x /etc/kernel/postinst.d/dkms ]; then ok "内核升级时会自动重编（dkms 钩子已就位）"; else warn "缺 dkms 内核钩子，升级内核后请手动跑 sudo dkms autoinstall"; fi

  printf "\n${C_G}══ 完成 ══${C_N}\n"
  printf "  以后 apt 升级内核，DKMS 会自动为新内核重编并安装本驱动。\n"
  printf "  现在可以正常重启；重启后跑只读验收： bash %s verify\n" "$0"
}

cmd_verify() {
  sec "1. DKMS 注册状态"
  dkms status 2>/dev/null | sed 's/^/  /' || true
  local st; st="$(dkms status -m "$DKMS_MOD" -v "$DKMS_VER" 2>/dev/null)"
  [ -n "$st" ] && ok "已注册 DKMS" || warn "未注册 DKMS"

  sec "2. 源码与补丁"
  if [ -d "$DKMS_SRC" ]; then
    ok "源码: $DKMS_SRC ($(du -sh "$DKMS_SRC" 2>/dev/null | cut -f1))"
    grep -q 'return hw->priv;' "$DKMS_SRC/src/mac80211.c" && ok "补丁① 在位" || bad "补丁① 缺失"
    grep -Eq '^[[:space:]]*init_dummy_netdev[[:space:]]*\(' "$DKMS_SRC/src/dma.c" && bad "补丁② 缺失" || ok "补丁② 在位"
    [ -f "$DKMS_SRC/dkms.conf" ] && info "dkms.conf 目的位置: $(awk -F'"' '/DEST_MODULE_LOCATION/{print $2}' "$DKMS_SRC/dkms.conf")"
  else
    warn "未部署 $DKMS_SRC"
  fi

  sec "3. 各内核下的模块文件"
  local k ko
  for k in /lib/modules/*/; do
    k="$(basename "$k")"
    ko="/lib/modules/$k/updates/dkms/$DKMS_MOD.ko"
    [ -e "$ko" ] || ko="/lib/modules/$k/extra/$DKMS_MOD.ko"
    if [ -e "$ko" ]; then
      printf "  %-22s %s  srcversion=%s\n" "$k" "${ko#/lib/modules/}" "$(modinfo -k "$k" "$DKMS_MOD" 2>/dev/null | awk '/^srcversion:/{print $2}')"
    else
      printf "  %-22s ${C_Y}无${C_N}（该内核下板载网卡没有驱动）\n" "$k"
    fi
  done

  sec "4. 三方对照"
  info "构建产物    : $(expect_srcversion)"
  info "已安装(磁盘): $(installed_srcversion)   $(module_path_of)"
  info "已加载(内存): $(loaded_srcversion)"
  [ "$(expect_srcversion)" = "$(installed_srcversion)" ] && ok "磁盘 = 构建产物" || warn "磁盘 ≠ 构建产物"

  sec "5. 固件 / 钩子 / 网络"
  ensure_firmware
  [ -x /etc/kernel/postinst.d/dkms ] && ok "dkms 内核钩子就位" || warn "缺 dkms 内核钩子"
  ip -brief addr show 2>/dev/null | grep -E '^(wl|en)' | sed 's/^/  /' || true
  ip route show default 2>/dev/null | sed 's/^/  /' || true

  printf "\n${C_B}══ 结论 ══${C_N}\n"
  if [ -n "$st" ] && [ "$(expect_srcversion)" = "$(installed_srcversion)" ]; then
    printf "  ${C_G}DKMS 已注册，磁盘上是修复版 → 内核升级会自动重编。${C_N}\n"
  else
    printf "  ${C_Y}尚未完成 DKMS 注册，请跑：sudo bash %s install --yes${C_N}\n" "$0"
  fi
}

cmd_uninstall() {
  need_root; need_yes
  snap_route
  sec "卸载 DKMS 注册"
  if [ "$DRY" = "1" ]; then
    act "dkms remove -m $DKMS_MOD -v $DKMS_VER --all"
    act "rm -rf $DKMS_SRC"
    act "depmod -a $KVER"
    printf "\n  ${C_Y}[dry-run] 未做任何改动${C_N}\n"; return 0
  fi
  dkms remove -m "$DKMS_MOD" -v "$DKMS_VER" --all && ok "已移除 DKMS 注册"
  rm -rf "$DKMS_SRC" && ok "已删除 $DKMS_SRC"
  depmod -a "$KVER" && ok "depmod 已刷新"
  route_guard "卸载后"
  warn "注意：模块文件也随之移除，板载网卡将失去驱动（直到恢复）"
  info "恢复办法：sudo install -Dm 644 $BACKUP_ROOT/<时间戳>/$DKMS_MOD.ko /lib/modules/$KVER/extra/ && sudo depmod -a"
  info "或重新注册：sudo bash $0 install --yes"
}

case "${1:-}" in
  preflight) cmd_preflight ;;
  install)   cmd_install ;;
  verify)    cmd_verify ;;
  uninstall) cmd_uninstall ;;
  *) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
esac
