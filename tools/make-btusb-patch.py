#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""为 Linux 6.8 的 drivers/bluetooth/btusb.c 生成 MT7902 支持补丁。
锚点式插入（不依赖行号），生成标准 unified diff，并自校验唯一性。
"""
import sys
import difflib

SRC = sys.argv[1] if len(sys.argv) > 1 else "btusb.c"
PATCH = sys.argv[2] if len(sys.argv) > 2 else "btusb-mt7902.patch"

ANCHOR_TABLE = "\t/* MediaTek MT7922A Bluetooth devices */\n"
INSERT_TABLE = (
    "\t/* MediaTek MT7902 Bluetooth devices */\n"
    "\t{ USB_DEVICE(0x13d3, 0x3596), .driver_info = BTUSB_MEDIATEK |\n"
    "\t\t\t\t\t\t     BTUSB_WIDEBAND_SPEECH |\n"
    "\t\t\t\t\t\t     BTUSB_VALID_LE_STATES },\n"
    "\n"
)

ANCHOR_SWITCH = "\tcase 0x7922:\n\tcase 0x7961:\n\tcase 0x7925:\n"
INSERT_SWITCH = "\tcase 0x7902:\n" + ANCHOR_SWITCH


def main():
    with open(SRC, encoding="utf-8") as f:
        orig = f.read()

    # 唯一性校验 —— 锚点必须只出现一次，否则拒绝生成（避免改错位置）
    for name, anchor in (("device table", ANCHOR_TABLE), ("switch case", ANCHOR_SWITCH)):
        n = orig.count(anchor)
        if n != 1:
            print(f"ERROR: 锚点 '{name}' 出现 {n} 次（要求恰好 1 次），拒绝生成补丁")
            print(f"       锚点内容: {anchor!r}")
            return 1
    # 目标内容不应已存在
    if "0x13d3, 0x3596" in orig:
        print("ERROR: 设备表中已存在 0x13d3,0x3596 —— 该内核可能已支持，无需打补丁")
        return 1
    if "\tcase 0x7902:\n" in orig:
        print("ERROR: switch 中已存在 case 0x7902 —— 无需打补丁")
        return 1

    new = orig.replace(ANCHOR_TABLE, INSERT_TABLE + ANCHOR_TABLE, 1)
    new = new.replace(ANCHOR_SWITCH, INSERT_SWITCH, 1)

    diff = difflib.unified_diff(
        orig.splitlines(keepends=True),
        new.splitlines(keepends=True),
        fromfile="a/drivers/bluetooth/btusb.c",
        tofile="b/drivers/bluetooth/btusb.c",
        n=3,
    )
    text = "".join(diff)
    with open(PATCH, "w", encoding="utf-8") as f:
        f.write(text)

    added = sum(1 for l in text.splitlines() if l.startswith("+") and not l.startswith("+++"))
    removed = sum(1 for l in text.splitlines() if l.startswith("-") and not l.startswith("---"))
    print(f"OK  已生成 {PATCH}")
    print(f"    hunk 数: {text.count(chr(10) + '@@') + text.count('@@ ')}  新增 {added} 行  删除 {removed} 行")
    return 0


if __name__ == "__main__":
    sys.exit(main())
