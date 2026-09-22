# Troubleshooting: the errors we actually hit

Every entry below is a real error text we saw, in the order we hit them. Grouped by symptom so
you can jump straight to yours. If your error isn't here, the `check-mt7902.sh` script
(`./tools/check-mt7902.sh dmesg`) collects the relevant log lines in one go.

---

## "The card is simply not there"

### `bind` returns `ENODEV`

```
$ echo 0000:05:00.0 > /sys/bus/pci/drivers/mt7921e/bind
bash: echo: 写入错误: 没有那个设备
```

**This is correct kernel behaviour, and trying again will not help.** Binding is only allowed
if the driver's ID table contains the device. On `6.8.0-138-generic`:

| Driver | Device IDs it claims |
|---|---|
| `mt7921e` | `0616`, `0608`, `0b48:7922`, `14c3:7922`, `14c3:7961` |
| `mt7925e` | `0717`, `7925` |

No `7902` anywhere. Scan the whole tree to confirm:

```bash
grep -rl '14c3' /lib/modules/$(uname -r)/modules.alias | head
grep 'v000014C3d00007902' /lib/modules/$(uname -r)/modules.alias   # expect: no match
```

**We got this wrong first.** The initial guess was BIOS, rfkill, or PCI power management,
because `lspci` shows the device as present but `enable` reads `0`. It isn't any of those —
`enable=0` is simply what an unbound PCI function looks like, and the same is true for the
onboard Realtek NIC on this board. The problem is one line of driver metadata.

### `enable=0` / `power_state: D0` / no `driver` symlink

Normal for a device with no driver bound. Nothing to fix.

### Firmware is missing entirely

```bash
find /lib/firmware -iname '*7902*'      # expect: nothing
```

Ubuntu 22.04 ships `linux-firmware 20220329.git681281e4-0ubuntu3.40` — a 2022 baseline. MT7902
firmware only landed in `linux-firmware` in 2026. And you can't substitute a file for a
missing name: the firmware filename is baked into the `.ko` by `MODULE_FIRMWARE()`, and 6.8's
`mt7921-common.ko` doesn't contain any MT7902 string at all:

```bash
strings /lib/modules/$(uname -r)/kernel/drivers/net/wireless/mediatek/mt7921/mt7921-common.ko* | grep -i 'WIFI_.*bin'
```

---

## "It loads, it scans, but it won't connect"

### `failed to insert STA entry for the AP (error -22)`

```
wlp5s0: failed to insert STA entry for the AP (error -22)
```

with, on the userspace side:

```
wpa_supplicant: SME: Authentication request to the driver failed
```

**This is Bug 1** — see the main README. Two things that make it hard to find:

* The log line starts with the **interface name** (`wlp5s0`), not `mt7902`. A
  `grep -i 'mt7902\|7902'` over the log will not match it. We lost a round to this.
* Because it happens before any frame is transmitted, there is nothing else in the log — no
  authentication failure, no deauth reason code. Silence is the signature.

Diagnose by ruling out the band: if 2.4 GHz and 5 GHz fail in exactly the same way, the
channel/frequency is not the variable. That points at the association path.

Confirm you're running the fixed module:

```bash
modinfo -k $(uname -r) -F srcversion mt7902e    # want 726032A9C67CCFF9695720B
```

### `80 MHz not supported, disabling VHT`

Informational. The driver downgrades the channel width. Not fatal, not related to Bug 1.

### WPA3 / SAE doesn't work

Use `wpa_supplicant`, which is Ubuntu's default. Several reports have WPA3 failing under `iwd`
with this chip family.

---

## "Shutdown hangs / rmmod hangs"

### `dev_addr_flush` → `free_netdev` call trace, then a frozen machine

```
BUG: kernel NULL pointer dereference, address: 0000000000000000
RIP: 0010:dev_addr_check+0x26/0x140      RAX=0
```

or, when it happens during shutdown, on screen only:

```
 dev_addr_flush+0x29/0xa0
 free_netdev+0x88/0x1f0
 mt792x_dma_cleanup+0x8f/0xb0 [mt7902e]
 mt7921_pci_remove+0xd7/0x1a0 [mt7902e]
 mt7921_pci_shutdown+0xe/0x20 [mt7902e]
```

**This is Bug 2** — see the main README for the root cause and the fix.

Things you need while debugging it:

**The shutdown-time oops is not in the journal, and never will be.** `journald` stops when
`systemd-shutdown` sends SIGTERM, and `device_shutdown()` runs after that. Your options are a
photograph of the screen, or reproducing the same path at runtime:

```bash
sudo rmmod mt7902e                     # the same codepath, and this one IS logged
journalctl -k -b -1 | grep -B8 -A45 'dev_addr_flush'
```

**Why a long-press of the power button is the only way out.** The oops happens in PID 1
(`__do_sys_reboot` is on the stack), so `do_exit()` runs `is_global_init()` and calls
`panic("Attempted to kill init!")`. With `panic_timeout=0` that never returns.

**Why your data is still safe.** `systemd-shutdown` prints
`Reached target Unmount All Filesystems` *before* the kernel's `device_shutdown()` phase. By the
time the oops happens, filesystems are already unmounted and synced. Long-pressing the power
button does not lose data.

**Module stuck at `Unloading`.** Because the oops happens on the `delete_module` path,
`rmmod mt7902e` leaves the module half-removed: the PCI device is unbound and the netdev
unregistered, but the exit function never returns, so `insmod` afterwards fails with
`File exists` and the name stays taken. The only recovery is a reboot.

Confirm you have the fixed build:

```bash
./tools/verify-teardown-fix.sh          # read-only; --reload to actually exercise it
```

The script refuses `--reload` when the module in memory is not the fixed one — running it
otherwise would faithfully reproduce the oops.

### "I installed the fix and the next shutdown still hung"

You were still running the **old** module. Replacing the file on disk does not replace what's
already loaded in memory. This is easy to misread as "the fix didn't work". Compare the
timestamps:

```bash
stat -c '%y %n' $(modinfo -k $(uname -r) -F filename mt7902e)
journalctl -k -b -1 | grep -i 'loading out-of-tree module'
```

In our case the installed file's `mtime` was later than the module-load time of the previous
boot, and the two boots were only **1 min 17 s** apart — the classic signature of "hung at
shutdown, long-pressed the power button". The oops was the old module's last hurrah, not a
failure of the fix.

---

## "The module won't load at all"

### `Unknown symbol in module`

```
mt7902e: Unknown symbol ieee80211_alloc_hw_nm (err -2)
```

You used `insmod`. `insmod` does **not** resolve dependencies; `modprobe` does. Any workflow
built on `insmod` has to load the dependency chain first:

```bash
sudo modprobe mac80211        # pulls in cfg80211 and libarc4
sudo insmod ./mt7902e.ko
```

This bit us specifically after a reboot: the earlier `try` path had a `modprobe mac80211` in
it, the later `reload` path didn't, and the failure looked like a broken module.

To catch this *before* loading anything, use the static checker:

```bash
python3 ./tools/check-module-symbols.py ./mt7902e.ko
```

### `insmod: ERROR: could not insert module ... File exists`

Either the module is genuinely loaded, or it's stuck in `Unloading` after a teardown oops. Do
**not** use `lsmod | grep -q` to tell them apart:

```bash
# broken under set -o pipefail
if lsmod | grep -q '^mt7902e'; then ...

# correct
if grep -q '^mt7902e ' /proc/modules; then ...
```

Why it's broken: `grep -q` exits as soon as it matches, `lsmod` gets SIGPIPE writing to the
now-closed pipe and exits 141, `pipefail` propagates that, and the condition evaluates as
false even though the module is right there. The longer the module list, the more likely the
race — which is why it can pass on one machine and fail on another.

### `vermagic` mismatch

```
mt7902e: version magic '6.8.0-40-generic SMP preempt mod_unload modversions' should be '6.8.0-138-generic ...'
```

You built against different headers than the kernel you booted. Check:

```bash
modinfo ./mt7902e.ko | grep vermagic
uname -r
```

Also relevant after a kernel upgrade: a prebuilt `.ko` from an older kernel will **always**
fail, which is exactly why `tools/deploy-mt7902.sh` refuses to install a module whose vermagic
doesn't match the running kernel.

### Module signature / `Required key not available`

```bash
grep CONFIG_MODULE_SIG_FORCE /boot/config-$(uname -r)   # want: not set / =n
mokutil --sb-state 2>/dev/null || cat /sys/kernel/security/lockdown
```

Out-of-tree modules aren't signed by your distro key. If `CONFIG_MODULE_SIG_FORCE=y` or
lockdown is in `confidentiality`/`integrity` mode, unsigned modules are refused. On the test
machine Secure Boot was off and lockdown was `none`, so unsigned modules loaded fine.

---

## Build problems

### Building against a mainline tarball of the same version number fails

This is the trap that cost the most time, on the Bluetooth side:

```
btusb.c:4321: error: 'struct hci_dev' has no member named 'dev_type'
btusb.c:4323: error: 'HCI_PRIMARY' undeclared
btusb.c:4507: error: 'HCI_QUIRK_VALID_LE_STATES' undeclared
```

The kernel is `6.8`, the mainline `v6.8` tag is also `6.8`, so it looks like they should match.
They don't: distributions backport aggressively during an LTS cycle. Ubuntu's 6.8 had already
absorbed the "remove HCI_AMP" and "`VALID_LE_STATES` → `BROKEN_LE_STATES`" changes. That is a
**533-line** difference in `btusb.c` alone (4822 → 5049 lines).

Ask the running kernel instead of guessing:

```bash
B=/lib/modules/$(uname -r)/build
grep -c 'HCI_AMP'                    $B/include/net/bluetooth/hci_core.h   # 0 — removed
grep -c 'HCI_QUIRK_BROKEN_LE_STATES' $B/include/net/bluetooth/hci_core.h   # 1 — renamed
```

**Always build against `/lib/modules/$(uname -r)/build`.** If you need the distro's full
source tree, get it from the distro's source package, not from kernel.org — see
`docs/bluetooth.md` for the exact `dpkg-source -x` recipe.

### `make` fails with `Error 1` and the real error is a temporary-file failure

If the build is running under a sandbox or wrapper that intercepts file deletion (some agent
harnesses hook `rm` to route files into a trash folder), a missing `HOME` can make the deletion
fail *closed*, and kernel's `Makefile.build` then reports a build error. The giveaway is noise
in the log about a trash directory and `XDG_DATA_HOME`/`HOME` not being set. Export a real
`HOME` before building:

```bash
export HOME=$(getent passwd $(id -u) | cut -d: -f6)
make -j$(nproc)
```

### `/tmp` silently truncates a copied file

On a system where `/tmp` is a small tmpfs, `cp` of a large `.ko` (ours are ~17 MB, unstripped)
can leave a short file with little or no error, especially if you redirected stderr. If a
freshly "copied" module fails to load for no apparent reason, compare sizes and hashes. Keep
intermediates in your home directory.

---

## Recovery: the card is wedged

After a failed init, the PCIe function can latch up in the board's power-management unit. A
normal reboot does not clear it. The fix is a full power drain:

1. Shut down completely.
2. Unplug the power cable.
3. Hold the power button for 30–40 seconds.
4. Plug back in and boot.

On this machine, shutting down while the card is in that state may itself hang (Bug 2), so
expect to long-press the power button and then do the drain above.

**Is the card in that state right now?** Check the kernel log for the classic marker:

```bash
journalctl -k --no-pager | grep -c 'driver own failed'    # 0 means you have a clean start
```

Before installing anything, it's worth knowing you have a clean start.

---

## Quick reference

| Command | What it tells you |
|---|---|
| `lspci -nn -s 05:00.0` | Is the card present, and is anything bound to it? |
| `grep 'v000014C3d00007902' /lib/modules/$(uname -r)/modules.alias` | Does this kernel know the card at all? |
| `modinfo -k $(uname -r) -F filename,srcversion,vermagic mt7902e` | Which build is on disk, and is it the right one? |
| `cat /sys/module/mt7902e/srcversion` | Which build is **in memory**? |
| `grep -q '^mt7902e ' /proc/modules` | Is it loaded? (never use `lsmod \| grep -q` here) |
| `journalctl -k -b -1 \| grep -A45 dev_addr_flush` | Look for a teardown oops from the previous boot |
| `iw dev` / `ip -br link` | Did an interface appear? |
| `./tools/check-mt7902.sh dmesg` | All of the above log checks in one command |
