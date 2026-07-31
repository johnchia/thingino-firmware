# SSC333 (Infinity6B0) — first bring-up by external programmer

The target board runs OpenIPC, has **no working ethernet and no working Wi-Fi**,
and is reachable only over a serial console. That single fact sets the whole
procedure below, and it inverts the order the Infinity6E board was brought up
in.

On the SSC30KQ the bootloader was left alone for four phases because reflashing
kernel and rootfs over a working OEM bootloader was the recovery path. Here
there is no network in either firmware, so there is no software path to push an
image onto the board at all. The clip is not the last resort, it is the only
resort — which means there is no reason to write partitions one at a time.
**Write the whole chip once, from a full image this build produces, bootloader
included.**

## What the build produces

```sh
make CAMERA=noname_ssc333_rtl8188ftv br-all WORKFLOW=1
```

In `output/ssc333-infinity6b0/noname_ssc333_rtl8188ftv-4.9-musl/images/`:

| file | size | what |
|---|---|---|
| `thingino-noname_ssc333_rtl8188ftv.bin` | 6,029,312 | the full image — boot + env + kernel + rootfs |
| `u-boot-ssc333-nor.bin` | 244,624 | the boot container alone, 93% of its 256KB partition |
| `u-boot-env.bin` | 65,536 | the environment alone, carrying the partition table |
| `uImage` | 2,178,608 | |
| `rootfs.squashfs` | 3,432,448 | |
| `uenv.txt` | | the environment as text, i.e. what was flashed |

The table it generates for an 8MB part:

```
NOR_FLASH:256k(boot),64k(env),2176k(kernel),3392k(rootfs),2304k(data),8192k@0(all)
```

That leaves **2304KB of overlay**, 28% of the chip. Kernel and rootfs are sized
to the images, so those two numbers move with every build and the overlay
absorbs the difference — it is the only figure here that measures anything
scarce.

Worth watching: the boot container is at 93% of a partition whose size is not
negotiable (the bootloader is compiled with `CONFIG_ENV_OFFSET 0x40000`). The
post-image script fails the build if it ever overflows.

The kernel carries `CONFIG_MAC80211=y`, which the Wi-Fi driver package forces
on through its `LINUX_CONFIG_FIXUPS` even though Realtek's out-of-tree stack is
cfg80211-based and does not need it. It costs roughly 100KB against the
Infinity6E kernel. Left alone because changing it means touching a shared
package for every Ingenic board too; revisit if the overlay ever gets tight.

The full image **stops at the end of the rootfs** rather than padding out to
8MB. That is deliberate — everything past it is the overlay, which `/init`
formats on first boot — but it means the file is shorter than the chip and
most programmers will refuse it or misalign it. Pad it first, with `0xFF`
rather than zeros, because `0xFF` is what erased NOR reads as:

```sh
cd output/ssc333-infinity6b0/noname_ssc333_rtl8188ftv-4.9-musl/images
dd if=/dev/zero bs=1M count=8 | tr '\000' '\377' > flash-8m.bin
dd if=thingino-noname_ssc333_rtl8188ftv.bin of=flash-8m.bin conv=notrunc
stat -c%s flash-8m.bin        # expect 8388608
```

`truncate -s 8M` is the wrong tool here: it pads with `0x00`, which the JFFS2
formatter has to erase anyway and which makes a dump harder to read.

Sanity-check the padded file before it goes near the chip. Each of these is a
piece landing exactly where the flashed environment says it does, so together
they check the image against its own partition table:

```sh
xxd -s 4          -l 4 -p flash-8m.bin    # 49504c5f  "IPL_"   boot container
xxd -s 0x50000    -l 4 -p flash-8m.bin    # 27051956           uImage at kernaddr
xxd -s 0x270000   -l 4 -p flash-8m.bin    # 68737173  "hsqs"   squashfs at rootaddr
xxd -s 0x7ffff0   -l 8 -p flash-8m.bin    # ffffffffffffffff   erased tail
```

The two offsets come from `uenv.txt` (`kernaddr`, `rootaddr`) and move with
every build, so read them from the file rather than copying them from here.

## Stage 0 — take the facts off the running board first

The board currently runs OpenIPC with a working serial console. That is a
data-collection opportunity that stops existing the moment the chip is
rewritten, and three of the items below are things this tree currently has to
guess at. Capture all of it before touching anything:

```sh
cat /proc/mtd                 # the OEM partition table
cat /proc/cmdline             # LX_MEM, mma_heap, and where the table came from
cat /proc/cpuinfo
cat /proc/meminfo             # confirms which memlx/memsz tier the SoC detects
fw_printenv                   # the whole OEM environment, once
dmesg | grep -i -e usb -e mtd -e spi
ls /sys/bus/usb/devices/      # is the Wi-Fi module even enumerating today?
ipcinfo -c -l 2>/dev/null     # if OpenIPC's build has it
```

Then the two registers this tree explicitly does not know the answer to. They
are read-only OTP and reading them changes nothing:

```sh
devmem 0x1F003C00 32          # generation tag; reads 0xF1 on Infinity6E
devmem 0x1F203150 32          # 48-bit die ID, low 16 bits of each word
devmem 0x1F203154 32
devmem 0x1F203158 32
```

Why it matters: `overlay/usr/sbin/soc` in this board's camera config
deliberately returns nothing for `soc -s`, because the die-ID registers have
only ever been verified on Infinity6E and `S03mac` *persists* whatever it is
handed. If the tag is neither `0x0000` nor `0xFFFF` and the three words are
neither all-zero nor all-ones, the block is real and the Infinity6E
implementation can be adopted verbatim with this tag added to its accepted set.
Nothing on this board needs it — there is no wired interface — so this is
groundwork for the next Infinity6B0, not a blocker for this one.

## Stage 1 — dump the flash. This is not optional.

The clip is the entire recovery story, so the dump is taken before anything is
written, not after something goes wrong.

```sh
flashrom -p <programmer> -r ssc333-oem-full.bin
cp ssc333-oem-full.bin ssc333-oem-full.bin.keep    # never write to the original
```

Check it before trusting it — a short or all-`0xFF` read looks like a file
until the day you need it:

```sh
stat -c%s ssc333-oem-full.bin                      # expect 8388608
xxd -s 4 -l 4 -p ssc333-oem-full.bin               # expect 49504c5f  ("IPL_")
grep -abo hsqs ssc333-oem-full.bin | head          # squashfs, at the OEM rootfs offset
```

Keep the bootloader alone as well. Restoring 256KB is much faster than 8MB, and
it is the only region whose loss is unrecoverable without the clip:

```sh
dd if=ssc333-oem-full.bin of=ssc333-oem-mtd0.bin bs=64k count=4
```

## Stage 2 — write the image

```sh
flashrom -p <programmer> -w flash-8m.bin
```

Verify by reading back, rather than trusting the programmer's own verify pass:

```sh
flashrom -p <programmer> -r readback.bin
cmp flash-8m.bin readback.bin && echo "image written"
```

## Stage 3 — first boot

Serial console is **115200 8N1** on `ttyS0`; the generated `bootargs` sets
`console=ttyS0,115200`, so U-Boot and the kernel share the port.

What should appear, in order: the SigmaStar IPL, the U-Boot banner, `sf probe`,
a kernel decompress, and thingino's `/init` pivoting onto the overlay. Then a
login on the serial console.

- login `root`, password `root` (`BR2_TARGET_GENERIC_ROOT_PASSWD` in
  `core-sigmastar.fragment`)
- hostname `ing-noname-ssc333`, built from the first two underscore-separated
  fields of the target name by `scripts/rootfs_script.sh`

`panic=20` is in the bootargs, so a kernel that dies reboots after 20 seconds
instead of hanging silently. On this board that is a convenience rather than a
safety net — with no network, a reboot loop and a hang look the same from
anywhere except the console you are already watching.

Confirm the table took:

```sh
cat /proc/mtd                 # expect boot, env, kernel, rootfs, data, all
cat /proc/cmdline
mount | grep overlay          # /overlay on the data partition
```

## Stage 4 — Wi-Fi and SSH

Nothing is preconfigured, and there is no web UI to configure it from, because
the web UI needs the network this step is creating. Do it from the console:

```sh
lsusb                                    # or: cat /sys/bus/usb/devices/*/idVendor
modprobe 8188fu                          # S11modules should already have
dmesg | tail -30                         # look for the interface registering
ip link                                  # expect wlan0

wlan configure "<ssid>" "<passphrase>"   # writes /etc/wpa_supplicant.conf
/etc/init.d/S38wpa_supplicant restart
/etc/init.d/S40network restart
ip addr show wlan0
```

Then SSH in on the address it got. Dropbear is started by `S50dropbear`.

`wlan` also has `setup` (interactive), `info`, `rssi` and `reset`; the
non-interactive `configure` is the one that works over a serial line without
fighting the terminal.

## If it does not come up

- **No U-Boot banner at all** — the boot container is wrong or misaligned.
  Write `ssc333-oem-mtd0.bin` back to offset 0 and confirm the board is alive
  before looking any further.
- **U-Boot but no kernel** — check `bootargs` and `mtdparts` in the running
  environment against `images/uenv.txt`, which is exactly what was flashed.
  Kernel and rootfs partitions are sized to the images, so an environment from
  a different build describes the wrong offsets.
- **Kernel but no login** — `/init` failing to mount the overlay. The rootfs is
  squashfs and mounts read-only regardless, so the console should still reach a
  shell; `init=/bin/sh` on the kernel command line isolates it.
- **wlan0 never appears** — check whether the module has power. `S05usb` reads
  `gpio.usb_en` from `/etc/thingino.json` and this board's config does not set
  it, because the pin is not known. If the module is dark, find the enable pin
  and put it there; `gpio` is a sysfs helper and works unchanged on SigmaStar
  (`CONFIG_MS_GPIO=y`, `CONFIG_GPIO_SYSFS=y`).

## Notes

**RAM and the multimedia carveout.** `arch/arm/cpu/armv7/infinity6b0/chip.c` in
the bootloader detects DRAM size and sets `memlx`/`memsz` itself — 256MB, 128MB
and 64MB tiers — and the generated `bootargs` reference those variables rather
than literals, so one image serves any population. On the 64MB tier that leaves
Linux roughly 32MB after a 32MB `mma_heap`. This target streams nothing and
that carveout is pure loss; shrinking it is a real tuning knob if memory gets
tight, at the cost of replacing an auto-detected value with a literal.

**No vendor MI bundle.** `sigmastar-osdrv-infinity6b0` is not packaged in this
tree and is not selected. Nothing here dlopens the MI libraries, and the kernel
modules behind them are 5.1MB uncompressed — most of an 8MB part. Adding
streaming to an Infinity6B0 board means porting that package the way
`sigmastar-osdrv-infinity6e` was ported, and finding the space.

**What this board shares with the SSC30KQ.** The vendor seam in `thingino.mk`,
the Kconfig guards, `core-sigmastar.fragment`, `soc-sigmastar.fragment`,
`board/sigmastar/post-image.sh` and the whole `sigmastar-uboot` package are
common. The only per-family artifacts are this directory's `linux.config` and
the camera config. That was the point of the exercise: the second SigmaStar
family needed no new vendor plumbing, only data.
