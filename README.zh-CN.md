# mt7902 —— MediaTek MT7902（Filogic 310）内核外无线网卡驱动

[English](README.md) | 简体中文

本仓库是 [hmtheboy154/mt7902](https://github.com/hmtheboy154/mt7902)（原作者已归档）的 fork，修掉了两个让板载 MT7902 在 **Ubuntu 22.04 + 6.8 系列 HWE 内核**上没法用的缺陷，并补上 DKMS 打包。

| # | 修复 | 修好之前的现象 |
| --- | --- | --- |
| 1 | `mt76_vif_phy()` 在信道上下文尚未建立时返回默认 PHY，而不是 `NULL` | 能扫描、连不上。报 `failed to insert STA entry for the AP (error -22)`，2.4G/5G 一样 |
| 2 | 6.9 以下内核的兼容层不再把 `init_dummy_netdev()` 当成 `alloc_netdev()` 的回调 | 关机和 `rmmod` 永久卡死，`dev_addr_check` 空指针，只能长按电源键 |

上游要到 **Linux 7.1** 才支持这张卡，而 Ubuntu 22.04 不会升到那个版本，所以只能用内核外驱动。

验证环境：`6.8.0-138-generic`，ASUS B760M-AYW WIFI D4，MT7902 PCIe 版（`14c3:7902`）。

---

## 一、快速开始

```bash
# 1. 依赖
sudo apt-get install build-essential linux-headers-$(uname -r) dkms zstd

# 2. 先看清现状（只读，不改任何东西）
./tools/check-mt7902.sh

# 3. 编译
make -j$(nproc)

# 4. 安装（注册 DKMS，以后内核升级自动重编）
sudo ./dkms/install-dkms.sh install --yes
./dkms/install-dkms.sh verify
```

加载不需要重启：

```bash
sudo modprobe mt7902e && iw dev
```

> **不要执行 `update-initramfs -u`**。udev 会依据 `modules.alias` 加载模块，动 initramfs 只会多一个把系统搞到开不了机的途径。

装好后把连接交给 NetworkManager 就行，不用手工配。

## 二、推荐：让 AI 助手替你装

这个仓库的文档是写给 AI 助手看的。把下面这段提示词发给你的助手（Claude Code、Codex、WorkBuddy 等能操作终端的都行），它会自己读文档、自己判断、自己收尾：

```text
请帮我在 Ubuntu 22.04 上用 https://github.com/Payton9000/mt7902 这个仓库修复板载
MediaTek MT7902 无线网卡（PCI 14c3:7902）。

先完整读一遍仓库里的 README.zh-CN.md 和 docs/troubleshooting.md，再动手。

按这个顺序做，每步做完把关键输出贴给我：
1. 只读体检：uname -r；lspci -nn -s 05:00.0；
   grep 'v000014C3d00007902' /lib/modules/$(uname -r)/modules.alias
2. 装依赖并编译：
   sudo apt-get install build-essential linux-headers-$(uname -r) dkms zstd && make -j$(nproc)
3. 装之前先确认模块能加载：python3 ./tools/check-module-symbols.py ./mt7902e.ko
4. 安装：sudo ./dkms/install-dkms.sh install --yes，然后 ./dkms/install-dkms.sh verify
5. 验收：./tools/check-mt7902.sh；并确认
   modinfo -k $(uname -r) -F srcversion mt7902e 输出 726032A9C67CCFF9695720B

约束：
- 这台机器要保持联网，不要断开或改动现有网络；不要卸载任何系统模块
- 不要执行 update-initramfs -u
- 不要执行 apt purge linux-modules-extra-*（会删掉几千个内核模块）

遇到任何报错，先查 docs/troubleshooting.md 里的对照表再动手，不要自己猜。
最后把「做了什么 / 当前模块版本 / 是否出现无线接口 / 有没有报错」整理成一段给我。
```

## 三、装不上怎么办

绝大多数报错在 [`docs/troubleshooting.md`](docs/troubleshooting.md) 里都有对照表，含完整报错原文。最常见的四个：

| 现象 | 原因 |
| --- | --- |
| `echo <bdf> > .../mt7921e/bind` 返回 `ENODEV` | 这是**正确的**内核行为 —— 6.8 的 ID 表里没有 `7902`。不是 BIOS、不是 rfkill |
| `modprobe` 报 `Unknown symbol in module` | 用了 `insmod`，它不解析依赖。改用 `modprobe`，或先 `modprobe mac80211` |
| 装完没变化 | 换掉磁盘上的 `.ko` 不会换掉内存里已加载的模块。重启，或 `modprobe -r mt7902e && modprobe mt7902e` |
| 编译过程报莫名其妙的错 | 别用主线同版本号源码，发行版回移很多。始终对着 `/lib/modules/$(uname -r)/build` 编译 |

**确认跑的是修复版**：`modinfo -k $(uname -r) -F srcversion mt7902e` 应该是 `726032A9C67CCFF9695720B`。

## 四、两个缺陷的技术要点

完整推导（含内核日志原文、上游 commit 对照、静态验证方法）在 [`docs/troubleshooting.md`](docs/troubleshooting.md) 与 [`docs/ubuntu-22.04-fixes.zh-CN.md`](docs/ubuntu-22.04-fixes.zh-CN.md)。

**缺陷一：关联失败** —— `src/mac80211.c` 的 `mt76_vif_phy()`：

```diff
         if (!mlink->ctx)
-                return NULL;
+                return hw->priv;
```

单射频网卡的早期 STA 事件里 `chanctx` 还没建立，返回 `NULL` 被调用方当成 `-EINVAL`。改法就是回退到默认 PHY —— 与内核 ≥6.15 的多射频路径一致。对应 [上游 issue #11][issue11]。

[issue11]: https://github.com/hmtheboy154/mt7902/issues/11

**缺陷二：关机 oops** —— `src/dma.c` 的兼容层把 `init_dummy_netdev()` 当作 `alloc_netdev()` 的 setup 回调，而它第一句是 `memset(dev, 0, sizeof(struct net_device))`，会清掉刚建好的 `dev->dev_addr` 等字段，于是释放时 `dev_addr_check()` 对 `NULL` 做 `memcmp` → oops。因为发生在 PID 1 的关机路径上，`panic_timeout=0` 就变成永久冻结。

```c
static void compat_init_dummy_netdev(struct net_device *dev)
{
        set_bit(__LINK_STATE_PRESENT, &dev->state);
        set_bit(__LINK_STATE_START,   &dev->state);
}
```

注意：6.8 上**不能**照抄上游 6.10 的 `init_dummy_netdev_core()`，因为该版本 `free_netdev()` 只接受 `NETREG_UNINITIALIZED`。

不需要重启就能验证修复：

```bash
nm -u ./mt7902e.ko | grep -i init_dummy_netdev      # 应该没有输出
```

## 五、仓库内容

```
src/            驱动源码（mt76 + MT7902 支持，含两处修复）
firmware/       MT7902 Wi-Fi 固件（上游原有）
patches/        两个修复的独立补丁；patches/btusb/ 是蓝牙补丁（未部署）
tools/          只读体检、符号可加载性检查、teardown 验收、蓝牙模块构建
dkms/           DKMS 打包（内核升级后自动重编）
docs/           排错对照表、蓝牙说明、完整中文记录、调研报告
```

脚本的路径都相对于仓库根，克隆下来即可直接跑；产物位置可用 `MT7902_ASSETS` / `MT7902_SRC` 等环境变量覆盖。

## 六、文档索引

| 文档 | 内容 |
| --- | --- |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | 按现象归类的报错对照表，全部是实际遇到的原文 |
| [`docs/bluetooth.md`](docs/bluetooth.md) | 蓝牙要替换内核 `btusb.ko`（风险更高），含「两张设备表」陷阱 |
| [`docs/ubuntu-22.04-fixes.zh-CN.md`](docs/ubuntu-22.04-fixes.zh-CN.md) | 完整中文排查与修复记录 |
| [`docs/MT7902-调研报告.md`](docs/MT7902-调研报告.md) | 上游支持状态、硬件实测、各方案横向对比 |
| [`patches/`](patches/) | 两个修复的独立补丁 |

## 七、许可证

逐文件的上游许可证保持不变：`mt76` 源码遵循 `SPDX-License-Identifier: BSD-3-Clause-Clear`，模块声明 `MODULE_LICENSE("Dual BSD/GPL")`。本仓库不对上游代码做任何重新授权。本 fork 新增的脚本、文档与补丁同样按 `BSD-3-Clause-Clear` 提供。

详见 [`LICENSING.md`](LICENSING.md) 与 [`NOTICE.md`](NOTICE.md)。

网卡能工作起来的根本原因是上游的工作，尤其是 **hmtheboy154** 的 backport、**Sean Wang（MediaTek）** 合入 Linux 7.1 的 11 篇补丁，以及 **Breno Leitao** 在 6.10 对 dummy netdev 分配器的重构。
