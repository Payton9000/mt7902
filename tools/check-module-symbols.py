#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验出树模块的未定义符号是否全部可解析（预测能否 insmod / modprobe 成功）。

解析来源：
  1) /proc/kallsyms            —— 内核内建符号 + 已加载模块符号
  2) 依赖链上各 .ko 的导出符号  —— 通过 modules.dep 求传递闭包后静态提取

不加载任何模块、不修改任何文件。
"""
import os
import re
import subprocess
import sys


def kver() -> str:
    return os.uname().release


def kallsyms() -> set:
    syms = set()
    try:
        with open("/proc/kallsyms", encoding="utf-8", errors="replace") as f:
            for line in f:
                p = line.split()
                if len(p) >= 3:
                    syms.add(p[2])
    except OSError:
        pass
    return syms


def modules_dep(k: str) -> dict:
    """返回 {模块名: [依赖模块名...]}"""
    dep = {}
    path = f"/lib/modules/{k}/modules.dep"
    if not os.path.exists(path):
        return dep
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if ":" not in line:
                continue
            left, right = line.split(":", 1)
            name = os.path.basename(left.strip())
            if name.endswith((".ko", ".ko.xz", ".ko.zst", ".ko.gz")):
                name = name.rsplit(".ko", 1)[0]
            deps = []
            for d in right.split():
                b = os.path.basename(d)
                if b.endswith((".ko", ".ko.xz", ".ko.zst", ".ko.gz")):
                    b = b.rsplit(".ko", 1)[0]
                deps.append(b)
            dep[name] = deps
    return dep


def ko_path(k: str, name: str):
    base = f"/lib/modules/{k}"
    for root, _dirs, files in os.walk(base):
        for fn in files:
            stem = fn.rsplit(".ko", 1)[0] if ".ko" in fn else None
            if stem == name:
                return os.path.join(root, fn)
    return None


def undefined(ko: str) -> set:
    try:
        out = subprocess.run(["nm", "--undefined-only", ko],
                             capture_output=True, text=True, timeout=60).stdout
    except Exception:
        return set()
    syms = set()
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 2:
            syms.add(p[-1])
    return syms


def exported(ko: str) -> set:
    """静态提取 .ko 导出的符号（__ksymtab_<sym> 形式）"""
    try:
        out = subprocess.run(["nm", "--defined-only", ko],
                             capture_output=True, text=True, timeout=60).stdout
    except Exception:
        return set()
    syms = set()
    for line in out.splitlines():
        p = line.split()
        if len(p) < 3:
            continue
        n = p[-1]
        m = re.match(r"^__(?:ksymtab|ksymtab_gpl|ksymtab_strings)_(.+)$", n)
        if m:
            syms.add(m.group(1).lstrip("_"))
    return syms


def own_depends(ko: str) -> list:
    """从 .ko 自身的 modinfo 读出 depends（模块未安装时 modules.dep 里没有它）"""
    try:
        out = subprocess.run(["modinfo", "-F", "depends", ko],
                             capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception:
        return []
    if not out:
        return []
    return [x.strip().replace("-", "_") for x in out.split(",") if x.strip()]


def main():
    if len(sys.argv) < 2:
        print("用法: check_module_symbols.py <a.ko> [b.ko ...]")
        return 1
    k = kver()
    ks = kallsyms()
    dep = modules_dep(k)
    print(f"内核 {k}    kallsyms 符号 {len(ks)} 个   modules.dep 条目 {len(dep)} 个\n")

    rc = 0
    for ko in sys.argv[1:]:
        name = os.path.basename(ko).rsplit(".ko", 1)[0]
        print(f"══ {os.path.basename(ko)} ══")
        und = undefined(ko)
        # 起点：.ko 自己的 modinfo depends ∪ modules.dep（两者取并集，避免漏依赖）
        seeds = set(own_depends(ko)) | set(dep.get(name, []))
        seen, stack = set(), list(seeds)
        while stack:
            d = stack.pop()
            if d in seen:
                continue
            seen.add(d)
            stack.extend(dep.get(d, []))
        avail = set(ks)
        loaded = []
        for d in sorted(seen):
            p = ko_path(k, d)
            if p:
                e = exported(p)
                avail |= e
                loaded.append(f"{d}({len(e)})")
        print(f"  未定义符号: {len(und)}")
        print(f"  依赖闭包  : {' '.join(loaded) if loaded else '(无)'}")

        missing = sorted(s for s in und if s not in avail)
        # 过滤掉 toolchain 内部符号
        missing = [s for s in missing if not s.startswith("__") and s not in ("_GLOBAL_OFFSET_TABLE_",)]
        if missing:
            print(f"  ✗ 无法解析 {len(missing)} 个:")
            for s in missing[:25]:
                print(f"      {s}")
            rc = 1
        else:
            print("  ✓ 全部未定义符号均可解析 → 可以加载")
        print()
    return rc


if __name__ == "__main__":
    sys.exit(main())
