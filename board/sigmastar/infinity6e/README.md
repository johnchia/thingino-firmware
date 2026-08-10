# SSC30KQ (Infinity6E)

## Images

`thingino-<camera>.bin` is the whole flash, laid out as the table below. It
contains the bootloader, so a full sysupgrade replaces mtd0 — the one write on
this board that cannot be undone in software. It stops at the end of the rootfs
rather than padding to 16MB; sysupgrade erases the partition before writing, so
the overlay area is already erased and `/init` formats it on first boot.

The pieces are emitted separately as well:

| artifact | offset | partition |
|---|---|---|
| `u-boot-ssc30kq-nor.bin` | 0x000000 | mtd0 `boot` |
| `u-boot-env.bin` | 0x040000 | mtd1 `env` |
| `uImage` | 0x050000 | mtd2 `kernel` |
| `rootfs.squashfs` | 0x250000 | mtd3 `rootfs` |

`u-boot-ssc30kq-nor.bin` is the mask-ROM container — IPL, MXP_SF and IPL_CUST at
fixed offsets in the first 128KB with the compressed U-Boot appended. It is not
`u-boot.bin`, and writing that instead produces a board that does not boot and
cannot be recovered over the network.

## Partitions

Generated per build by `ssc30kq-post-image.sh`, sized to the images:

```
NOR_FLASH:256k(boot),64k(env),<kernel>k(kernel),<rootfs>k(rootfs),<data>k(data),16384k@0(all)
```

`boot` and `env` are fixed: the bootloader is compiled with `CONFIG_ENV_OFFSET
0x40000` and `CONFIG_ENV_SIZE 0x10000`, so changing either means changing
`sstar-common.h` to match. `kernel` and `rootfs` are cut to the images and
64KB-aligned, `data` is the remainder, and `all` overlaps the whole chip because
`thingino-sysupgrade` refuses to run without it.

`data` replaces the OEM's `rootfs_data`, and the name is load-bearing: `/init`
matches the overlay loosely as `/data/` in `mount_jffs2` but strictly as
`/"data"/` in `format_overlay`, so under the OEM name the format-on-corruption
recovery path resolves to an empty device and fails.

Sizing to the images means offsets move when the images do. If the kernel or
rootfs crosses a 64KB boundary every partition after it shifts, and the
environment describing them is correct only for that one build — so kernel,
rootfs and environment are flashed together, which is what the full image does.

## If the environment is lost

A bad CRC in mtd1 makes the bootloader fall back to its compiled defaults, which
still carry the OEM table and a 5120k rootfs. A larger rootfs then reads as
truncated: it appears to mount and fails later, looking like filesystem
corruption rather than a partition problem. Re-apply `uenv.txt` before
concluding anything about the image.

This is worse under our own bootloader than under the OEM one, because
`0001-cmd_sf-drop-retrospective-rootfs-auto-sizing.patch` also removes the
accident that used to rescue it — the OEM `sf probe` would read the real rootfs
and raise `rootmtd`, where ours leaves the compiled value standing. That patch
is still correct: the auto-sizing described the image already on the chip rather
than the one being written, so it sized every partition for the previous image
and no image could ever cross the threshold.

## Kernel source

`core-sigmastar.fragment` pins `github.com/johnchia/linux` at a full commit SHA.
That repo forks `OpenIPC/linux`, whose `sigmastar-infinity6e` branch is four
things stacked in order:

1. `5f5a8f461` "Linux 4.9.84" — an orphan commit with no parents, but its tree
   hash is `4012348742232876ebb74356e08ec3482624e15a`, identical to the tree of
   Greg KH's `v4.9.84` tag. The base is vanilla kernel.org, imported flat.
2. `f298e3da4` — the SigmaStar vendor BSP as a single commit: +839,504/-4,054
   lines over at least 300 files, 27MB as a diff. This is the port. There is no
   other source for it; the vendor SDK is not published anywhere durable, which
   is why OpenIPC is the de-facto mirror.
3. Fifteen OpenIPC commits, ~400 lines total.
4. One commit of ours, `d85ef37e8`.

### What is above the BSP

| commit | change | keep? |
|---|---|---|
| `49d071f5c` | `python` → `python3` in the vendor Makefiles | required — `python` is absent on current distros |
| `d85ef37e8` | ARM `.section` flags, backport of upstream ARM 8933/1 | required — binutils ≥2.42 rejects the Sun-style `#alloc` and we ship 2.44 |
| `311476c2b` | spinand probe bails unless the chip is SPINAND-ECC | yes — we build `CONFIG_MS_SPINAND=y` on a NOR board |
| `e7d6fa3a1` | jffs2 `.rename2` + `RENAME_WHITEOUT` | yes — the overlay upperdir is jffs2 and overlayfs needs whiteout |
| `eb50a943c` | jffs2 `RENAME_EXCHANGE` | yes — completes the pair above |
| `7e5e24a7f` | un-comments watchdog magic close | yes — restores mainline semantics the vendor disabled |
| `8b10f7dcf` | fuart off `PAD_PM_GPIO0` | yes, as a set |
| `fde587733` | amp-gpio off `PAD_PM_GPIO1` | yes, as a set |
| `5f98178a2` | I2S claims `PAD_PM_GPIO0..3` | yes, as a set |
| `07e821ac9` | UART rx-trigger sysfs knob, forces `use_dma = 0` in C | yes, but squashed |
| `461b7c681` | removes that hack, moves it to the dtsi as `dma = <0>` | yes, but squashed |
| `c5c06376b` | I2C NAK logging `pr_info` → `pr_debug` | yes — sensor probing NAKs are normal and spam the console |
| `b6d62526c` | `--strip-unneeded` for modules | yes — smaller modules on flash |
| `318571c83` | ehci power-enable-pad → `PAD_UNKNOWN`, silences a printk | probably — verify a downstream USB device still powers up |
| `0455c0330` | initramfs `/init` → `/sbin/init`, mounts devtmpfs | no — see below |
| `677b1ce7a` | ath9k and regulatory-domain patches | no — see below |

The three pin commits are one reassignment and cannot be separated: the first two
free `PM_GPIO0` and `PM_GPIO1`, the third claims `PM_GPIO0..3` for I2S. Taking
only the third double-assigns both pins. `infinity6e-ssc012b-s01a.dts` includes
both `infinity6e.dtsi` and `infinity6e-padmux-qfn.dtsi` and overrides none of
these properties, so all of it lands in our DTB unmediated.

The two UART commits belong as one patch. The first adds the sysfs knob and also
force-clears `use_dma` for every port in C; the second deletes that and sets
`dma = <0>` in the dtsi instead. Carrying both preserves a hack that the second
one undoes.

`0455c0330` is a no-op here twice over: `CONFIG_INITRAMFS_SOURCE` is empty so
there is no initramfs to exec into, and we boot `root=/dev/mtdblock3
rootfstype=squashfs` through `prepare_namespace()`. `CONFIG_DEVTMPFS_MOUNT`
already handles `/dev`. It encodes an OpenIPC init convention we do not follow.

`677b1ce7a` cannot build here — eight of its ten files are ath9k, and both
`CONFIG_WLAN` and `CONFIG_MAC80211` are off. Of the rest, `net/wireless/db.txt`
is dead with `CFG80211_INTERNAL_REGDB` off, and the `reg.c` change relaxes
regulatory limits, which is not something to ship on purpose.

### On replacing the pin with a tarball and in-tree patches

The argument for it is not integrity. `BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION` is
a full 40-char SHA and git verifies object hashes on checkout, so the pin is
already a content hash over the whole tree — as binding as a tarball's sha256.

What it would actually buy is that upstream stops depending on a personal GitHub
account, and that the kernel delta becomes visible where it is reviewed. Today a
kernel change reaches a firmware PR as one line moving, and no reviewer can see
what happened without diffing two hashes in another repo by hand.

The cost is that the 27MB BSP patch would live in this tree forever, and it is
the one part of the stack nobody can review — 839,504 lines. Paying permanent
repo weight to make ~400 lines visible, by carrying a blob that cannot be
checked, is a poor trade. It also makes bumping the BSP a matter of regenerating
a 27MB file, and Buildroot applies patches with `patch -p1`, which fails on fuzz
where git does not.

The version that gets nearly all of it: pin the repo at `f298e3da4` — vanilla
plus the BSP, nothing else — and carry every commit above it as a patch in
`patches/linux/`, next to the armthumb one already there. Then every change
thingino makes to this kernel is reviewable in the firmware tree, the base stays
SHA-pinned, and no blob enters the repo. Forking `OpenIPC/linux` into the
thingino org and pinning that removes the personal-account dependency
separately, which is the part actually worth fixing.

### This is not a SigmaStar peculiarity

Ingenic is the same arrangement. `gtxaspec/thingino-linux` is a standalone
import, not a fork of anything, and its `ingenic-t31` branch carries
`arch/mips/xburst`, which vanilla `v3.10.14` does not have. The Ingenic BSP is
committed into that repo exactly as the SigmaStar BSP is committed into this
one; it is only invisible from here because it is history in another repo rather
than a file in this tree. `core.fragment` sets `BR2_LINUX_KERNEL_CUSTOM_GIT` for
every Ingenic kernel including 3.10.14, so no target in this project builds from
a kernel.org tarball.

The version-keyed patch directories are not evidence to the contrary, because
none of them are reached. `pkg-utils.mk` resolves a package's patch directory to
`<dir>/<version>` if that exists and otherwise to `<dir>`, and `linux/Config.in`
sets `LINUX_VERSION` to the repo hash under `BR2_LINUX_KERNEL_CUSTOM_GIT`. So
`package/all-patches/linux/3.10.14`, `/4.4.94` and `/7.1-rc1` are looked up under
a hash that never matches, and the fallback holds no patches.
`board/ingenic/xburst1/patches/linux` is referenced by nothing at all. Both are
leftovers from before those fixes became commits in the gtxaspec repo. The
comment in `Makefile` claiming 3.10.14 uses a kernel.org tarball describes an
arrangement that no longer exists.

`BR2_LINUX_KERNEL_PATCH` in `core-sigmastar.fragment` is the only kernel patch
mechanism in this project that actually applies. Moving this board to a vanilla
tarball would therefore not bring it into line with Ingenic — it would make it
the first target to work that way, and leave Ingenic as the one still to
convert. That may be the right direction, but it is a precedent rather than a
correction.
