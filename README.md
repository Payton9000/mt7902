# mt7902 — MediaTek MT7902 (Filogic 310) out-of-tree Wi-Fi driver

English | [简体中文](README.zh-CN.md)

A fork of [hmtheboy154/mt7902](https://github.com/hmtheboy154/mt7902) (archived upstream) that fixes
two defects which made the onboard MT7902 unusable on **Ubuntu 22.04 with a 6.8-series HWE
kernel**, and adds DKMS packaging.

| # | Fix | Symptom before |
| --- | --- | --- |
| 1 | `mt76_vif_phy()` returns the default PHY instead of `NULL` when no channel context exists yet | Scans, never associates. `failed to insert STA entry for the AP (error -22)`, identical on 2.4 and 5 GHz |
| 2 | The pre-6.9 compat layer no longer passes `init_dummy_netdev()` as an `alloc_netdev()` setup callback | Shutdown and `rmmod` freeze permanently; NULL dereference in `dev_addr_check`; only a hard power-off recovers |

Upstream only gained MT7902 support in **Linux 7.1**, which Ubuntu 22.04 will never ship, so an
out-of-tree driver is the only route.

Verified on: `6.8.0-138-generic`, ASUS B760M-AYW WIFI D4, MT7902 PCIe (`14c3:7902`).

---

## 1. Quick start

```bash
# 1. Dependencies
sudo apt-get install build-essential linux-headers-$(uname -r) dkms zstd

# 2. See where the machine stands first (read-only, changes nothing)
./tools/check-mt7902.sh

# 3. Build
make -j$(nproc)

# 4. Install (registers DKMS, so later kernel upgrades rebuild automatically)
sudo ./dkms/install-dkms.sh install --yes
./dkms/install-dkms.sh verify
```

No reboot needed to load it:

```bash
sudo modprobe mt7902e && iw dev
```

> **Do not run `update-initramfs -u`.** udev loads the module from `modules.alias`; touching
> initramfs only adds a way to break your boot.

Then hand the connection to NetworkManager. Nothing needs configuring by hand.

## 2. Recommended: let an AI agent do it

The documentation here is written to be read by an agent. Paste this into yours (Claude Code,
Codex, WorkBuddy — anything that can drive a terminal):

```text
Using https://github.com/Payton9000/mt7902, fix the onboard MediaTek MT7902 Wi-Fi card
(PCI 14c3:7902) on this Ubuntu 22.04 machine.

Read the repository's README.md and docs/troubleshooting.md in full before touching anything.

Then, step by step, showing me the key output of each step:
1. Read-only survey: uname -r; lspci -nn -s 05:00.0;
   grep 'v000014C3d00007902' /lib/modules/$(uname -r)/modules.alias
2. Dependencies and build:
   sudo apt-get install build-essential linux-headers-$(uname -r) dkms zstd && make -j$(nproc)
3. Before installing, confirm the module can resolve its symbols:
   python3 ./tools/check-module-symbols.py ./mt7902e.ko
4. Install: sudo ./dkms/install-dkms.sh install --yes, then ./dkms/install-dkms.sh verify
5. Verify: ./tools/check-mt7902.sh, and confirm
   modinfo -k $(uname -r) -F srcversion mt7902e prints 726032A9C67CCFF9695720B

Constraints:
- This machine must stay online. Do not disconnect or reconfigure the existing network,
  and do not unload any system module.
- Do not run update-initramfs -u.
- Do not run apt purge linux-modules-extra-* (it removes several thousand kernel modules).

For any error, look it up in docs/troubleshooting.md first instead of guessing.
Finish by summarising: what you did, which module version is now in place, whether a wireless
interface appeared, and anything that failed.
```

## 3. When it doesn't work

Most errors are tabulated in [`docs/troubleshooting.md`](docs/troubleshooting.md) with the exact
text you will see. The four most common:

| Symptom | Cause |
| --- | --- |
| `echo <bdf> > .../mt7921e/bind` returns `ENODEV` | **Correct** kernel behaviour — 6.8's ID tables have no `7902`. Not a BIOS, rfkill or power-management problem |
| `modprobe` reports `Unknown symbol in module` | You used `insmod`, which does not resolve dependencies. Use `modprobe`, or `modprobe mac80211` first |
| Installed it and nothing changed | Replacing the file on disk does not replace the module already in memory. Reboot, or `modprobe -r mt7902e && modprobe mt7902e` |
| Build fails with unrelated-looking errors | Don't use a mainline tarball of the same version number; distributions backport heavily. Always build against `/lib/modules/$(uname -r)/build` |

**Confirm you are running the fixed build:** `modinfo -k $(uname -r) -F srcversion mt7902e`
should print `726032A9C67CCFF9695720B`.

## 4. The two fixes, briefly

Full derivations — kernel log excerpts, upstream commit comparisons, static verification
methods — are in [`docs/troubleshooting.md`](docs/troubleshooting.md) and
[`docs/ubuntu-22.04-fixes.zh-CN.md`](docs/ubuntu-22.04-fixes.zh-CN.md) (Chinese).

**Fix 1: association failure** — `mt76_vif_phy()` in `src/mac80211.c`:

```diff
         if (!mlink->ctx)
-                return NULL;
+                return hw->priv;
```

On a single-radio card the early STA events arrive before a channel context exists, and `NULL`
is collapsed into `-EINVAL` by the callers. Falling back to the default PHY matches what the
multi-radio path already does on kernels ≥ 6.15. This is [upstream issue #11][issue11].

[issue11]: https://github.com/hmtheboy154/mt7902/issues/11

**Fix 2: shutdown oops** — in `src/dma.c` the compat layer passed `init_dummy_netdev()` as the
`setup` callback of `alloc_netdev()`. Its first statement is
`memset(dev, 0, sizeof(struct net_device))`, which wipes the freshly initialised
`dev->dev_addr` and friends, so `free_netdev()` ends in `dev_addr_check()` doing `memcmp(NULL, …)`
→ oops. Because it happens in PID 1 during shutdown and `panic_timeout=0`, that becomes a
permanent freeze.

```c
static void compat_init_dummy_netdev(struct net_device *dev)
{
        set_bit(__LINK_STATE_PRESENT, &dev->state);
        set_bit(__LINK_STATE_START,   &dev->state);
}
```

Note you must **not** simply copy upstream's 6.10 `init_dummy_netdev_core()` here: this kernel's
`free_netdev()` only accepts `NETREG_UNINITIALIZED`.

Verify the fix without rebooting:

```bash
nm -u ./mt7902e.ko | grep -i init_dummy_netdev      # expect: no output
```

## 5. Repository layout

```
src/            driver sources (mt76 + MT7902 support, with both fixes applied)
firmware/       MT7902 Wi-Fi firmware (carried over from upstream)
patches/        the two fixes as standalone patches; patches/btusb/ holds the Bluetooth patch
tools/          read-only health check, symbol-resolution checker, teardown verifier, btusb builder
dkms/           DKMS packaging (rebuilds the module on kernel upgrades)
docs/           troubleshooting table, Bluetooth notes, full write-up, research report
```

Script paths are relative to the repository root, so a fresh clone works as-is. Artifact
locations can be overridden with `MT7902_ASSETS`, `MT7902_SRC`, and so on.

## 6. Documentation index

| Document | Contents |
| --- | --- |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | Errors grouped by symptom, all of them real captured text |
| [`docs/bluetooth.md`](docs/bluetooth.md) | Bluetooth requires replacing the kernel's `btusb.ko`; includes the two-device-table trap |
| [`docs/ubuntu-22.04-fixes.zh-CN.md`](docs/ubuntu-22.04-fixes.zh-CN.md) | Full Chinese write-up of the investigation (with `README.zh-CN.md` for the overview) |
| [`docs/MT7902-调研报告.md`](docs/MT7902-调研报告.md) | Upstream support status, hardware measurements, comparison of the driver options |
| [`patches/`](patches/) | The two fixes as standalone patches |

## 7. Licence

Per-file upstream licensing is unchanged: the `mt76` sources carry
`SPDX-License-Identifier: BSD-3-Clause-Clear`, and the module declares
`MODULE_LICENSE("Dual BSD/GPL")`. Nothing here re-licenses upstream code. This fork's own
scripts, documentation and patches are offered under `BSD-3-Clause-Clear` as well.

See [`LICENSING.md`](LICENSING.md) and [`NOTICE.md`](NOTICE.md).

The card works at all because of upstream work — in particular **hmtheboy154**'s backport,
the 11-patch series by **Sean Wang (MediaTek)** merged for Linux 7.1, and **Breno Leitao**'s
6.10 rework of the dummy net_device allocator.
