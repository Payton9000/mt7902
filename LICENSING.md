# Licensing

Short version: **this fork changes nothing about the licensing of upstream code, and adds no
restrictions of its own.** Everything is under the terms it arrived with.

## What the upstream code says

* Every `mt76` source file under `src/` carries a per-file
  `SPDX-License-Identifier: BSD-3-Clause-Clear` header.
* The built module declares:

  ```c
  MODULE_LICENSE("Dual BSD/GPL");
  ```

  which is `mt76`'s traditional dual declaration, and is what lets the module use GPL-only
  kernel exports (the module links against `mac80211` and `cfg80211`, which do export
  GPL-only symbols).
* Upstream (`hmtheboy154/mt7902`) ships **no** `LICENSE` file and **no** `COPYING` file. We
  didn't invent one for their code.

## What this fork adds

| Path | Contents | Terms |
|---|---|---|
| `src/**` | `mt76` sources, with two changed files (`mac80211.c`, `dma.c`) | unchanged upstream terms — `BSD-3-Clause-Clear` per file, module dual `BSD/GPL` |
| `patches/**` | the two fixes plus the optional Bluetooth patch, as diffs | `BSD-3-Clause-Clear` |
| `docs/**`, `tools/**`, `dkms/**`, `README.md`, `LICENSING.md` | write-up, verification tools, DKMS packaging written for this fork | `BSD-3-Clause-Clear` |

`BSD-3-Clause-Clear` is the same licence the upstream sources use, so there is no
incompatibility or mixed-licence question anywhere in the tree. The full text is in
[`LICENSE`](LICENSE); scope, exclusions and attribution are in [`NOTICE.md`](NOTICE.md).

## Why `BSD-3-Clause-Clear` and not something else

Choosing a licence for a **fork of kernel code** is not really a choice. The relevant
constraints:

* `mt76` is dual `BSD`/`GPL`. You may use either, but you may not narrow them.
* The module depends on GPL-only kernel symbols, so a build that actually loads is operating
  under the GPL arm — that's what `Dual BSD/GPL` declares and why it can't be relicensed to
  something GPL-incompatible (Apache-2.0, for instance).
* Relicensing upstream files under a different licence, even a permissive one, would be a
  copyright problem. So we didn't.

For the fork's own additions we picked `BSD-3-Clause-Clear` simply because it matches the
surrounding files. It adds no obligation beyond attribution, so it's the lowest-friction choice
for anyone who wants to reuse the write-up or the tools.

## What is *not* in this repository

* **No compiled modules.** `mt7902e.ko` and `btusb.ko` are not committed — they must be built
  against your own kernel headers, and a prebuilt module would only be vermagic-mismatched
  dead weight.
* **No firmware blobs**, other than the two Wi-Fi blobs upstream already carries in
  `firmware/` and that `make install_fw` requires. Those are distributed by
  [linux-firmware](https://gitlab.com/kernel-firmware/linux-firmware) under MediaTek's own
  redistributable terms. The size and sha256 of every firmware file you need are recorded in
  [`docs/troubleshooting.md`](docs/troubleshooting.md) and the main README, so you can verify
  what you downloaded.

## Attribution

The work that makes this card function at all is upstream's. See the *Credits and upstream*
section of the [README](README.md) for the specific people and projects — in particular
`hmtheboy154`, Sean Wang (MediaTek), and Breno Leitao.
