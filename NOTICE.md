# NOTICE

The [licence](LICENSE) in this repository covers **this fork's own additions**:

* the two changes in `src/mac80211.c` and `src/dma.c`
* everything under `patches/`, `tools/`, `dkms/` and `docs/`
* `README.md`, `LICENSING.md` and this file

## Upstream code keeps its own terms

Everything else under `src/` is `mt76`. It is not authored here and is **not** re-licensed by
this fork. Each of those files carries its own header:

```c
// SPDX-License-Identifier: BSD-3-Clause-Clear
```

and the module they build declares:

```c
MODULE_LICENSE("Dual BSD/GPL");
```

`BSD-3-Clause-Clear` is the same licence this fork's additions use, and the `GPL` arm of the
module's dual declaration is what permits linking against GPL-only kernel symbols exported by
`mac80211` and `cfg80211`. Nothing in this repository narrows either of those options.

See [`LICENSING.md`](LICENSING.md) for the full reasoning.

## What is not in this repository

* **Compiled modules.** `mt7902e.ko` and `btusb.ko` are not committed. They have to be built
  against your own kernel headers; a prebuilt one would only fail with a `vermagic` mismatch.
* **Firmware**, other than the two Wi-Fi blobs that upstream already carries in `firmware/`
  and that `make install_fw` requires. They come from
  [linux-firmware](https://gitlab.com/kernel-firmware/linux-firmware) under MediaTek's own
  redistributable terms. Sizes and sha256 sums are recorded in the README and
  `docs/troubleshooting.md` so you can verify what you download.

## Attribution

The work that makes this card function at all belongs to other people:

* [**hmtheboy154/mt7902**](https://github.com/hmtheboy154/mt7902) — the backport this is forked
  from.
* **Sean Wang (MediaTek)** and co-developers — the mainline patch series that added MT7902
  support, merged in Linux 7.1.
* **Breno Leitao** — the 6.10 `alloc_netdev_dummy()` rework that explains the teardown
  semantics behind the second fix.

## Trademarks

`MediaTek`, `Filogic`, `AzureWave`, `ASUS`, `Ubuntu` and other names that appear in the
documentation belong to their owners and are used descriptively to identify the hardware and
software involved. No endorsement or affiliation is implied.
