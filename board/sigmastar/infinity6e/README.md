# SSC30KQ — bootloader and partition bring-up

The build produces four flashable artifacts. Only one of them can brick the
board, and it is flashed last, separately, after everything else has been shown
to work.

| artifact | goes to | recoverable in software? |
|---|---|---|
| `rootfs.squashfs` | mtd3 `rootfs` | yes |
| `uImage` | mtd2 `kernel` | yes |
| `u-boot-env.bin` | mtd1 `env` | yes — a working bootloader can rewrite it |
| `u-boot-ssc30kq-nor.bin` | mtd0 `boot` | **no** |

`uenv.txt` beside them is the same environment in text form. It is what to read
when you want to know what the build decided, and the input to `fw_setenv`.

## The table

Generated per build by `ssc30kq-post-image.sh`, sized to the images:

```
NOR_FLASH:256k(boot),64k(env),<kernel>k(kernel),<rootfs>k(rootfs),<data>k(data),16384k@0(all)
```

`boot` and `env` are fixed because the bootloader is compiled with
`CONFIG_ENV_OFFSET 0x40000` and `CONFIG_ENV_SIZE 0x10000`. `kernel` and `rootfs`
are cut to the images and 64KB-aligned. `data` is the remainder. `all` overlaps
the whole chip and exists because `thingino-sysupgrade` refuses to run without
it.

**The partitions after `kernel` move when `kernel` changes size.** The
environment describes one exact set of images; kernel, rootfs and environment
are flashed together or not at all.

## Why the environment can go in first, under the OEM bootloader

The generated `bootargs` carries literal partition sizes and never references
`${rootmtd}`. The stock OpenIPC bootloader's `sf probe` still recomputes
`rootmtd` and `rootsize` on every boot, but nothing in this boot path reads
them, so it writes two variables into the void and the boot proceeds on our
table. Traced against a real image: `sf probe` reads our squashfs superblock at
0x250000, matches the magic, and sets `rootmtd=8192k` and `rootsize=0x500000`.

`rootmtd` is referenced by nothing once `bootargs` stops using it. `rootsize` is
read by `run urnor` for TFTP rootfs writes, so that helper erases 5120k instead
of the real partition size until mtd0 is replaced -- the only thing the quirk
still breaks.

`${memlx}` and `${memsz}` do not come from the stored environment at all.
`board_late_init()` in `infinity6e/chip.c` sets them from the detected RAM size,
and it runs before `main_loop()`, so they are present whatever is in mtd1.

That is what makes a staged bring-up possible: the whole partition change can be
proven with the OEM bootloader still in mtd0 and the SPI clip still in the
drawer.

## Before anything

Save the two per-unit values the OEM wrote once. `S03mac` reads `ethaddr`
rather than inventing a MAC, and the sensor probe falls back to `sensor`:

```sh
fw_printenv ethaddr sensor
```

Also note that **the overlay is about to be erased.** `data` moves when the
rootfs partition is resized, so its jffs2 contents no longer parse and `/init`
reformats it. Anything hand-edited under `/etc` on the running unit lives in
that overlay and will not survive — copy it off first.

## Stage 1 — the table, keeping the OEM bootloader (recoverable)

Use `fw_setenv`, not a raw write of `u-boot-env.bin`. A stored environment
replaces the bootloader's compiled defaults wholesale rather than merging with
them, and `u-boot-env.bin` holds only the ten variables this build generates.
Writing it raw therefore discards everything else the unit's environment
currently has — `ethaddr` and `sensor`, but also the vendor's `soc`,
`updatetool` and the `ubnor`/`uknor`/`urnor` TFTP recovery helpers, which are
exactly what you want available when a flash goes wrong. The camera would still
boot, because the generated `bootcmd` is self-contained; it would just have lost
its recovery tooling.

`fw_setenv` is a read-modify-write, so all of that stays. Apply every line of
`uenv.txt`:

```sh
while IFS='=' read -r k v; do fw_setenv "$k" "$v"; done < uenv.txt
fw_printenv mtdparts bootargs bootcmd     # read it back before rebooting
reboot
```

After the reboot `/proc/mtd` shows the new table and the old rootfs still boots
— it is at the same offset, only the partition around it grew. Then flash the
matching images:

```sh
flashcp -v uImage          /dev/mtd2
flashcp -v rootfs.squashfs /dev/mtd3
flash_eraseall -j          /dev/mtd4
reboot
```

Stage 1 is done when the camera boots, streams, and `/proc/mtd` lists `data` and
`all`. `sysupgrade` should now pass `check_upgrade_partitions`.

## Stage 2 — the bootloader (not recoverable in software)

Only after stage 1 is good, and only with the serial console attached and an SPI
flash clip within reach:

```sh
flashcp -v u-boot-ssc30kq-nor.bin /dev/mtd0
```

`u-boot-ssc30kq-nor.bin` is the mask-ROM container — IPL, MXP_SF and IPL_CUST at
fixed offsets in the first 128KB with the compressed U-Boot appended. It is not
`u-boot.bin`; writing that instead produces a board that does not boot and
cannot be recovered over the network.

Do not write mtd0 to fix a problem in stage 1. Nothing stage 1 can go wrong with
is caused by the bootloader.

## If the environment is lost

A bad CRC in mtd1 makes the bootloader fall back to its compiled defaults, which
still carry the OEM table with `${rootmtd}` and a 5120k rootfs. A rootfs larger
than that then reads as truncated: it will appear to mount and fail later,
looking like filesystem corruption rather than a partition problem. Re-apply
`uenv.txt` before concluding anything about the image.
