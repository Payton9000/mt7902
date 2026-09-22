# patches

Standalone patches, in case you'd rather apply the fixes to your own checkout than use this
fork's tree. They apply with `git apply -p1` or `patch -p1` from the repository root.

```bash
git apply --check patches/0001-*.patch patches/0002-*.patch   # dry run first
git apply          patches/0001-*.patch patches/0002-*.patch
```

| Patch | Target | What it does |
|---|---|---|
| `0001-mt76-vif-phy-fix-association-einval.patch` | `src/mac80211.c` | `mt76_vif_phy()` falls back to the default PHY when `mlink->ctx` is still `NULL`, instead of returning `NULL`. Without this, association always fails with `-EINVAL (-22)`. |
| `0002-mt76-dma-fix-teardown-null-deref.patch` | `src/dma.c` | The pre-6.9 compat layer stops passing `init_dummy_netdev()` as an `alloc_netdev()` setup callback, which was zeroing `dev->dev_addr` and causing a NULL-pointer dereference in `free_netdev()` on shutdown and `rmmod`. |
| `btusb/btusb-mt7902.patch` | `drivers/bluetooth/btusb.c` in the **kernel** source tree | Adds the `13d3:3596` entry to `quirks_table` plus `case 0x7902` in `btusb_mtk_setup()`, so the Bluetooth half of the card gets its firmware. **Not part of this repository's build** — see [`../docs/bluetooth.md`](../docs/bluetooth.md). Requires the distribution's kernel source, not mainline. |

The two `src/` patches are already applied in this tree; the files exist so you can review the
change in isolation, or carry it elsewhere.

`btusb-mt7902.patch` is not applied by anything here and is intentionally kept out of the
module build — it targets the kernel, not this driver.
