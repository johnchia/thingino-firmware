# SSC333 (Infinity6B0) — TP-Link Kasa KD110 v2

**Verified on hardware.** The board boots to a serial login, brings up Wi-Fi
without any GPIO intervention, and serves its captive portal.

The unit arrived running OpenIPC with **no working ethernet and no working
Wi-Fi**, reachable only over a serial console. That single fact set the whole
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
make CAMERA=tplink_kasa_kd110v2_ssc333_rtl8188ftv br-all WORKFLOW=1
```

In `output/<branch>/tplink_kasa_kd110v2_ssc333_rtl8188ftv-4.9-musl/images/`:

| file | what |
|---|---|
| `thingino-tplink_kasa_kd110v2_ssc333_rtl8188ftv.bin` | the full image — boot + env + kernel + rootfs |
| `u-boot-ssc333-nor.bin` | the boot container alone, 93% of its 256KB partition |
| `u-boot-env.bin` | the environment alone, 64KB, carrying the partition table |
| `uImage`, `rootfs.squashfs` | the pieces |
| `uenv.txt` | the environment as text, i.e. what was flashed |

Kernel and rootfs are sized to the images, so those numbers move with every
build and the overlay absorbs the difference — it is the only figure that
measures anything scarce. Read the exact table from `uenv.txt` rather than from
here. As measured with the vendor MI bundle and one sensor blob installed:

```
NOR_FLASH:256k(boot),64k(env),1792k(kernel),4992k(rootfs),1088k(data),8192k@0(all)
```

### The space budget, and whether a streamer fits

The vendor bundle is what makes this part tight: 5.3MB uncompressed, 1.6MB of
the rootfs. Almost all of it is the `mi_*` kernel modules (3.3MB) and the MI
userspace libraries (1.5MB); the sensor blobs, narrowed to one, are 92KB.

Raptor was measured against the Infinity6E target rather than estimated, since
it cannot be built for this family yet (see Notes). Its whole payload — eight
daemons, `librss_*`, `raptor.conf`, the OSD fonts — is 771KB uncompressed and
**288KB** in squashfs. Adding ONVIF and the audio codecs takes it to 1.7MB
uncompressed and **662KB** compressed.

Rounded to the 64KB erase block, that lands as:

| build | rootfs | data (overlay) |
|---|---|---|
| today, no streamer | 4992k | 1088k |
| \+ raptor, no ONVIF or audio | 5312k | 768k |
| \+ raptor, ONVIF and audio | 5632k | 448k |

So it fits, and there is a further lever in reserve if it stops fitting. Raptor
dlopens nine MI libraries by name — `libmi_{sys,vif,vpe,venc,isp,sensor,rgn}`,
`libispalgo`, `libcam_os_wrapper`, plus `libmi_ai` for audio. Six of the shipped
libraries are referenced by nothing in the image: `libmi_ive` (700KB on its own),
`libmi_vdf`, `libmi_iqserver`, `libmi_ao`, `libmi_shadow`, `libmi_divp` — 963KB
raw, **309KB** compressed. They are still installed deliberately, because "no
current caller" is not the same as "no future caller": `ive` and `vdf` back
motion detection and `ao` backs speaker output, all of which are plausible on
this hardware. Drop them when the space is actually needed, not before.

Worth watching: the boot container is at 93% of a partition whose size is not
negotiable (the bootloader is compiled with `CONFIG_ENV_OFFSET 0x40000`). The
post-image script fails the build if it ever overflows.

The full image **stops at the end of the rootfs** rather than padding out to
8MB. That is deliberate — everything past it is the overlay, which `/init`
formats on first boot — but it means the file is shorter than the chip and most
programmers will refuse it or misalign it. Pad it first, with `0xFF` rather
than zeros, because `0xFF` is what erased NOR reads as:

```sh
dd if=/dev/zero bs=1M count=8 | tr '\000' '\377' > flash-8m.bin
dd if=thingino-tplink_kasa_kd110v2_ssc333_rtl8188ftv.bin of=flash-8m.bin conv=notrunc
stat -c%s flash-8m.bin        # expect 8388608
```

`truncate -s 8M` is the wrong tool: it pads with `0x00`, which the JFFS2
formatter has to erase anyway and which makes a dump harder to read.

Sanity-check the padded file before it goes near the chip. Each of these is a
piece landing exactly where the flashed environment says it does, so together
they check the image against its own partition table. Take the two middle
offsets from `uenv.txt` (`kernaddr`, `rootaddr`) rather than copying them:

```sh
xxd -s 4        -l 4 -p flash-8m.bin    # 49504c5f  "IPL_"   boot container
xxd -s $kernaddr -l 4 -p flash-8m.bin   # 27051956           uImage
xxd -s $rootaddr -l 4 -p flash-8m.bin   # 68737173  "hsqs"   squashfs
xxd -s 0x7ffff0 -l 8 -p flash-8m.bin    # ffffffffffffffff   erased tail
```

## Stage 0 — take the facts off the running board first

Anything still running on the board is a data-collection opportunity that stops
existing the moment the chip is rewritten. Capture this before touching
anything:

```sh
cat /proc/mtd                 # the OEM partition table
cat /proc/cmdline             # LX_MEM, mma_heap, and where the table came from
cat /proc/cpuinfo
cat /proc/meminfo             # confirms which memlx/memsz tier the SoC detects
fw_printenv                   # the whole OEM environment, once
dmesg | grep -i -e usb -e mtd -e spi
```

Then the registers this tree explicitly does not know the answer to. They are
read-only OTP and reading them changes nothing:

```sh
devmem 0x1F003C00 32          # generation tag; reads 0xF1 on Infinity6E
devmem 0x1F203150 32          # 48-bit die ID, low 16 bits of each word
devmem 0x1F203154 32
devmem 0x1F203158 32
```

Why it matters: this board's `overlay/usr/sbin/soc` deliberately returns
nothing for `soc -s`, because the die-ID registers have only ever been verified
on Infinity6E and `S03mac` *persists* what it is handed. If the tag is neither
`0x0000` nor `0xFFFF` and the three words are neither all-zero nor all-ones,
the block is real and the Infinity6E implementation can be adopted with this
tag added to its accepted set. Nothing on this board needs it — there is no
wired interface — so this is groundwork for the next Infinity6B0.

## Stage 1 — dump the flash. This is not optional.

The clip is the entire recovery story, so the dump is taken before anything is
written, not after something goes wrong.

```sh
flashrom -p <programmer> -r kd110v2-oem-full.bin
cp kd110v2-oem-full.bin kd110v2-oem-full.bin.keep    # never write the original
```

Check it before trusting it — a short or all-`0xFF` read looks like a file
until the day you need it:

```sh
stat -c%s kd110v2-oem-full.bin                       # expect 8388608
xxd -s 4 -l 4 -p kd110v2-oem-full.bin                # expect 49504c5f  "IPL_"
grep -abo hsqs kd110v2-oem-full.bin | head           # squashfs, at the OEM rootfs offset
```

Keep the bootloader alone as well. Restoring 256KB is much faster than 8MB, and
it is the only region whose loss is unrecoverable without the clip:

```sh
dd if=kd110v2-oem-full.bin of=kd110v2-oem-mtd0.bin bs=64k count=4
```

## Stage 2 — write the image

```sh
flashrom -p <programmer> -w flash-8m.bin
flashrom -p <programmer> -r readback.bin
cmp flash-8m.bin readback.bin && echo "image written"
```

Verify by reading back rather than trusting the programmer's own verify pass.

## Stage 3 — first boot

Serial console is **115200 8N1** on `ttyS0`; the generated `bootargs` sets
`console=ttyS0,115200`, so U-Boot and the kernel share the port.

- login `root`, password `root` (`BR2_TARGET_GENERIC_ROOT_PASSWD` in
  `core-sigmastar.fragment`)
- hostname `ing-tplink-kasa`, built from the first two underscore-separated
  fields of the target name by `scripts/rootfs_script.sh`

**The first boot is slow, and it looks like a hang.** It is not. This kernel
has no usable hardware RNG and the board has almost no interrupt traffic to
seed from — no ethernet, no disk, and `wlan0` does not exist yet. `S02ssl` runs
at position 02 and generates the uhttpd certificate through mbedTLS, whose
entropy poll uses a blocking `getrandom()`, so init waits there for a CRNG that
only the later stages of the same init sequence could seed.

It resolves on its own. **Typing on the serial console gets past it
immediately**, because keypress timing feeds the entropy pool. `S01seedrng`
persists a seed afterwards, so later boots are fast — but a fresh flash is a
first boot every time. See the defconfig for why this is documented rather than
fixed.

Confirm the table took:

```sh
cat /proc/mtd                 # expect boot, env, kernel, rootfs, data, all
cat /proc/cmdline
mount | grep overlay          # /overlay on the data partition
```

## Stage 4 — Wi-Fi

**Wi-Fi comes up on its own.** No GPIO poking is needed on this board — the
module is powered and enumerates without help, and `S36wireless` loads
`8188fu` and brings up `wlan0`.

**A fresh unit boots into the captive portal, not into a client.** The shipped
`/etc/wpa_supplicant.conf` is an AP config with `ssid="THINGINO-"`, `mode=2`
and no `psk=` line. `S38wpa_supplicant` picks its mode by grepping that file,
finds no `psk=`, and chooses `portal`. So the board:

- broadcasts an open AP named `THINGINO-<last two octets of the wlan0 MAC>`
- assigns itself **172.16.0.1**, serves DHCP on 172.16.0.0/24 and runs `dnsd`
- and `S60uhttpd` binds `UHTTPD_PORTAL_HTTP_LISTEN=172.16.0.1:80`, serving
  `/var/www-portal`

**That is why the web UI appears on a 172.x address.** It is not an ethernet
fallback and not a fault in this port — it is thingino's designed state for an
unconfigured camera. Join the AP and browse to `http://172.16.0.1/`, or
configure from the serial console:

```sh
wlan configure "<ssid>" "<passphrase>"
reboot
```

`wlan configure` derives the PSK with `wpa_passphrase` and rewrites
`/etc/wpa_supplicant.conf` so it now has a `psk=` line and no `mode=2` —
which is what makes the next boot choose `client` instead of `portal`.
Rebooting is the reliable way to apply it; the portal owns interface state,
addresses and routes that a restart in place does not fully unwind.

Then SSH in on the address it gets. Dropbear is started by **`S30dropbear`**.

Useful: `wlan` also has `setup` (interactive), `info`, `rssi` and `reset`, via
symlinks `wlansetup`, `wlaninfo`, `wlanrssi`, `wlanreset`.

One caveat on builds without audio, which includes this one: the portal's
10-minute auto-shutdown is `sleep 600 && play <sound> && $0 stop`, and `play`
does not exist here, so the `&&` chain stops and **the portal stays up
indefinitely**. Convenient on the bench, but it means an open unauthenticated
AP does not close itself. Upstream bug, not carried as a local patch.

## Resetting to a fresh state

`firstboot` erases the overlay and reboots — the way to retest first-boot
behaviour including the portal. It erases `/dev/mtd1` too unless given `-e`,
and on this board mtd1 is the env holding the generated partition table.

```sh
firstboot -e        # -e: do NOT erase /dev/mtd1.  -f: skip the confirmation
```

**`-e` is now a convenience rather than a requirement**, on a board flashed
with a bootloader from this tree. The compiled-in fallback used to be the OEM's

```
mtdparts=NOR_FLASH:256k(boot),64k(env),2048k(kernel),${rootmtd}(rootfs),-(rootfs_data)
```

— a fixed 2048k kernel where this build's is 1792k, so the rootfs offset landed
inside the kernel and `panic=20` turned it into a reboot loop. It is now sized
to the kernel this build produced, by
`board/sigmastar/uboot-recovery-table.sh`:

```
mtdparts=NOR_FLASH:256k(boot),64k(env),1792k(kernel),-(rootfs)
```

Losing the environment therefore costs a read-only boot, not a loop: mtdblock3
lands exactly on the real rootfs, `/init` fails to find a partition named `data`
and its EXIT trap execs `/sbin/init` anyway. Expect a serial console and no
network — dropbear wants to write host keys into `/etc`, and wlan0 wants a
`wpa_supplicant.conf` from the overlay. Write `u-boot-env.bin` back to offset
`0x40000`, or re-flash, to leave that state.

**Why this matters beyond the bench.** The web UI's *Reset firmware* runs
`firstboot -f`, and a 20-second hold of the physical button runs the same
command. Neither can pass `-e`. Before this fix, a factory reset from the web UI
left the board recoverable only over serial.

> **Unrelated and still live: do not use the web UI's *Wipe overlay*.** It runs
> `flash_eraseall -j /dev/mtd2`, a hardcoded index that predates the layout
> change in `3b7997b46`. On this table mtd2 is the **kernel**, not the overlay.
> See `UPSTREAM-CANDIDATES.md`.

## If it does not come up

- **No U-Boot banner at all** — the boot container is wrong or misaligned.
  Write `kd110v2-oem-mtd0.bin` back to offset 0 and confirm the board is alive
  before looking further.
- **U-Boot but no kernel** — check `bootargs` and `mtdparts` in the running
  environment against `images/uenv.txt`, which is exactly what was flashed.
  Kernel and rootfs partitions are sized to the images, so an environment from
  a different build describes the wrong offsets.
- **Kernel but no login** — `/init` failing to mount the overlay. The rootfs is
  squashfs and mounts read-only regardless, so the console should still reach a
  shell; `init=/bin/sh` on the kernel command line isolates it.
- **Appears to hang late in init** — see the entropy note in Stage 3. Type on
  the console.

## Notes

**RAM and the multimedia carveout.** `arch/arm/cpu/armv7/infinity6b0/chip.c` in
the bootloader detects DRAM size and sets `memlx`/`memsz` itself — 256MB, 128MB
and 64MB tiers — and the generated `bootargs` reference those variables rather
than literals, so one image serves any DRAM population. On the 64MB tier that
leaves Linux roughly 32MB after a 32MB `mma_heap`. This target streams nothing
and that carveout is pure loss; shrinking it is a real tuning knob if memory
gets tight, at the cost of replacing an auto-detected value with a literal.

**The vendor MI bundle is installed, but nothing consumes it yet.**
`sigmastar-osdrv-infinity6b0` is selected, so the `mi_*` modules load at S20 and
the MI libraries are on disk. No process dlopens them — there is no streamer on
this board. They are here for sensor bring-up: `load_sigmastar` inserts
`mi_sensor`, without which the i2c probe behind `sensor` and `ipcinfo` has
nothing to talk to. Identifying what is actually fitted is the prerequisite for
deciding whether streaming is worth pursuing on an 8MB part.

**Raptor cannot be built for this family yet.** `thingino-raptor`'s
`VALID_PLATFORMS` has no `INFINITY6B0`, and mapping it onto `INFINITY6E` would
compile against the wrong vendor headers for silicon that merely resembles it.
That is a change to the raptor tree, which is owned elsewhere; a diagnosis is
written up in `~/raptor/HANDOFF-infinity6b0-platform.md`. The space budget above
is what that work would land in.

**What this board shares with the SSC30KQ.** The vendor seam in `thingino.mk`,
the Kconfig guards, `core-sigmastar.fragment`, `soc-sigmastar.fragment`,
`board/sigmastar/post-image.sh` and the whole `sigmastar-uboot` package are
common. The only per-family artifacts are this directory's `linux.config` and
the camera config. That was the point of the exercise: the second SigmaStar
family needed no new vendor plumbing, only data.
