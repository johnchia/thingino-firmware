# SSC30KQ — bootloader, partitions and updates

## What the build produces

Everything lands in `output/sigmastar-infinity6e/<camera>-4.9-glibc/images/`.

`thingino-<camera>.bin` is the deliverable — the whole flash laid out as the
table below describes it. `sysupgrade` writes it to the `all` partition. It
contains the bootloader, so a full sysupgrade replaces mtd0, the one write on
this board that cannot be undone in software.

It stops at the end of the rootfs rather than padding to 16MB. sysupgrade
erases the partition before writing, so the overlay area is already erased and
`/init` formats it on first boot.

The pieces are emitted separately too, for when you want to change one thing
rather than everything:

| artifact | offset in the full image | partition | recoverable? |
|---|---|---|---|
| `u-boot-ssc30kq-nor.bin` | 0x000000 | mtd0 `boot` | **no** |
| `u-boot-env.bin` | 0x040000 | mtd1 `env` | yes |
| `uImage` | 0x050000 | mtd2 `kernel` | yes |
| `rootfs.squashfs` | 0x250000 | mtd3 `rootfs` | yes |

`uenv.txt` is the same environment in text form: what to read when you want to
know what the build decided, and the input to `fw_setenv`.

`u-boot-ssc30kq-nor.bin` is the mask-ROM container — IPL, MXP_SF and IPL_CUST at
fixed offsets in the first 128KB, with the compressed U-Boot appended. It is not
`u-boot.bin`, and writing that instead produces a board that does not boot and
cannot be recovered over the network.

## The partition table

Generated per build by `ssc30kq-post-image.sh`, sized to the images:

```
NOR_FLASH:256k(boot),64k(env),<kernel>k(kernel),<rootfs>k(rootfs),<data>k(data),16384k@0(all)
```

`boot` and `env` are fixed, because the bootloader is compiled with
`CONFIG_ENV_OFFSET 0x40000` and `CONFIG_ENV_SIZE 0x10000`; changing either means
changing `sstar-common.h` to match. `kernel` and `rootfs` are cut to the images
and 64KB-aligned. `data` is the remainder. `all` overlaps the whole chip and
exists because `thingino-sysupgrade` refuses to run without it.

`data` replaces the OEM's `rootfs_data`. The name matters: `/init` matches the
overlay loosely as `/data/` in `mount_jffs2` but strictly as `/"data"/` in
`format_overlay`, so under the OEM name the format-on-corruption recovery path
resolves to an empty device and fails.

**Sizing to the images means offsets move when the images do.** If the kernel or
rootfs crosses a 64KB boundary, every partition after it shifts, and the
environment describing them is only correct for that one build. Kernel, rootfs
and environment are flashed together — which is what the full image does, and
the reason it is the preferred path.

## Getting the files onto the camera

The overlay has room, but `/tmp` is tmpfs and is where sysupgrade stages anyway:

```sh
scp thingino-<camera>.bin uenv.txt root@<camera>:/tmp/
```

## Before you touch anything

Save the MAC:

```sh
fw_printenv ethaddr
```

Losing it is no longer fatal — `S03mac` falls back to a MAC derived from the
SoC's OTP die ID, which is burned at the fab and not in flash, so a camera that
comes back from an upgrade with an erased environment still gets a stable
address rather than a new random one each boot. But the derived address is a
synthetic locally-administered `02:` one, not the board's assigned MAC, so
anything holding a DHCP reservation against the real one still wants it back.

`sensor` needs no saving at all. `load_sigmastar` probes i2c through `ipcinfo`
whenever the variable is empty and writes the answer back, so it repairs itself
on the next boot.

**Both fallbacks change the hostname.** `S04hostname` builds the name from the
last four hex digits of `soc -s`, falling back to the MAC, so this unit is
`ing-noname-ssc30kq-FA37` from the die ID rather than the `-CD96` its assigned
MAC gave. Worth knowing before an update rather than after.

**The overlay is about to be erased.** `data` moves when the rootfs partition is
resized, so its jffs2 contents no longer parse and `/init` reformats them.
Anything hand-edited under `/etc` on the running unit lives in that overlay and
will not survive — copy it off first.

## Stage 1 — the table, keeping the OEM bootloader

Fully recoverable: mtd0 is untouched throughout, so a bad outcome is fixed by
rewriting the environment from a booting system.

Use `fw_setenv`, not a raw write of `u-boot-env.bin`. A stored environment
replaces the bootloader's compiled defaults wholesale rather than merging with
them, and `u-boot-env.bin` holds only the variables this build generates. Writing
it raw therefore discards everything else the unit has — `ethaddr`, and also the
vendor's `soc`, `updatetool` and the `ubnor`/`uknor`/`urnor` TFTP recovery
helpers, which are exactly what you want available when a flash goes wrong. The
camera would still boot, since the generated `bootcmd` is self-contained; it
would just have lost its MAC and its recovery tooling.

`fw_setenv` is a read-modify-write, so all of that stays:

```sh
while IFS='=' read -r k v; do fw_setenv "$k" "$v"; done < /tmp/uenv.txt
fw_printenv mtdparts bootargs bootcmd     # read it back before rebooting
reboot
```

After the reboot `/proc/mtd` shows the new table. `/init` will have found the
moved overlay unparseable and reformatted it; if it did not, do it by hand:

```sh
flash_eraseall -j /dev/mtd4
```

**No image reflashing is needed for this step.** `boot`, `env`, `kernel` and
`rootfs` sit at identical offsets in the OEM table and the generated one — only
the rootfs partition's declared size changes, and only the overlay actually
moves. The bytes in flash are already where the new table says they are.

Stage 1 is done when the camera boots, streams, and `/proc/mtd` lists `data` and
`all`. `sysupgrade` now passes `check_upgrade_partitions`, which is the point: it
is the first moment the update path can be exercised at all.

## Stage 2 — the full image, which replaces the bootloader

Only after stage 1 is good, and only with the serial console attached and an SPI
flash clip within reach:

```sh
sysupgrade /tmp/thingino-<camera>.bin
```

sysupgrade prints its own warning and gives you ten seconds to cancel. It erases
the `all` partition and writes the image over it, bootloader included. Use `-b`
against the same image to write mtd0 alone, or `flashcp -v
u-boot-ssc30kq-nor.bin /dev/mtd0` to do it outside sysupgrade — but there is no
version of this step that leaves mtd0 untouched.

Do not write mtd0 to fix a problem in stage 1. Nothing that can go wrong in
stage 1 is caused by the bootloader.

## Recovery

Until mtd0 is written, there is nothing to recover from: the board boots the
bootloader it shipped with, and a bad environment or rootfs is fixed from a
serial console or by reflashing over a working boot.

After mtd0 is written, a failed boot means the SPI flash clip. Read the chip
back, restore `thingino-<camera>.bin` (or the OEM dump, if one was taken before
the first mtd0 write — worth doing), and start again. This is the only failure
mode in the project that software cannot reach, which is why stage 2 is last.

## Reference

### Why the environment can go in under the OEM bootloader

The generated `bootargs` carries literal partition sizes and never references
`${rootmtd}`. The stock OpenIPC bootloader's `sf probe` still recomputes
`rootmtd` and `rootsize` on every boot, but nothing in this boot path reads
them. Traced against a real image: it reads the squashfs superblock at
0x250000, matches the magic, and sets `rootmtd=8192k` and `rootsize=0x500000`,
both into the void.

`rootsize` is read by `run urnor` for TFTP rootfs writes, so that helper erases
the wrong length until mtd0 is replaced. It is the only thing the quirk still
breaks.

`${memlx}` and `${memsz}` never come from the stored environment at all.
`board_late_init()` in `infinity6e/chip.c` sets them from the detected RAM size
and runs before `main_loop()`, so the memory carveout is present whatever is in
mtd1 — and one image serves every DRAM population of this SoC.

### Why sysupgrade needed a patch to accept this image

sysupgrade identifies a full image by its first four bytes being Ingenic's
`06050403`. A SigmaStar boot container has no magic number there — it opens with
an ARM branch whose encoding moves with the branch offset (`060000ea` in this
build, `020000ea` in the vendor's own IPL blobs). The stable signature is `IPL_`
at offset 4.

Without that check sysupgrade rejects a correct image as `Unknown file`, and
`-b` fails the same way inside `extract_bootloader`.
`image_starts_with_bootloader` in `package/thingino-sysupgrade/files/sysupgrade`
checks both. It is written vendor-shaped rather than board-shaped and is worth
offering upstream — it is not specific to this camera, only to not being
Ingenic.

### Why only full upgrades

Partial upgrades are disabled upstream: `sysupgrade -p` prints "Partial upgrades
are not supported anymore" and exits. The `upgrade` partition they used is
historical — the 2013.07 U-Boot's compiled table declared
`15872k@0x80000(upgrade)`, everything past boot, env and config, which is how a
partial image was flashed without touching mtd0. The generated table dropped it.
Nothing here is missing it; the feature is off for every board.

### If the environment is lost

A bad CRC in mtd1 makes the bootloader fall back to its compiled defaults, which
still carry the OEM table with `${rootmtd}` and a 5120k rootfs. A larger rootfs
then reads as truncated — it will appear to mount and fail later, looking like
filesystem corruption rather than a partition problem.

Under our own bootloader this is slightly worse than under the OEM one, because
removing the auto-sizing also removed the accident that rescued it: the OEM
`sf probe` would read the real rootfs and raise `rootmtd` to 8192k, where ours
leaves the compiled 5120k standing. Re-apply `uenv.txt` before concluding
anything about the image.
