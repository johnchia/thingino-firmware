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

| artifact | offset in the full image | partition | if this write goes wrong |
|---|---|---|---|
| `u-boot-ssc30kq-nor.bin` | 0x000000 | mtd0 `boot` | **board is silent — clip only** |
| `u-boot-env.bin` | 0x040000 | mtd1 `env` | may not boot — clip |
| `uImage` | 0x050000 | mtd2 `kernel` | may not boot — clip |
| `rootfs.squashfs` | 0x250000 | mtd3 `rootfs` | may not boot — clip |

Without a serial console every one of those failures looks the same from the
outside: the camera does not come back on the network. The difference is only
how much has to be written back, which is why stage 0 keeps both a full dump and
a 256KB bootloader-only dump.

`uenv.txt` is the same environment in text form: what to read when you want to
know what the build decided, and the input to `fw_setenv`.

`u-boot-ssc30kq-nor.bin` is the mask-ROM container — IPL, MXP_SF and IPL_CUST at
fixed offsets in the first 128KB, with the compressed U-Boot appended. It is not
`u-boot.bin`, and writing that instead produces a board that does not boot and
cannot be recovered over the network.

## The partition table

Generated per build by `board/sigmastar/post-image.sh`, sized to the images:

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
scp thingino-<camera>.bin uenv.txt u-boot-ssc30kq-nor.bin root@<camera>:/tmp/
```

## Stage 0 — take the dump. This is not optional.

With no serial console attached, a camera that fails to boot tells you nothing:
it simply does not appear on the network. There is no console to interrupt, no
message to read, and no software path back in. **The clip and a known-good dump
are the entire recovery story**, so the dump is taken before anything is
written, not after something goes wrong.

Power the board down, clip the NOR chip, and read the whole 16MB:

```sh
flashrom -p <programmer> -r ssc30kq-oem-full.bin
cp ssc30kq-oem-full.bin ssc30kq-oem-full.bin.keep    # never write to the original
```

Check it before trusting it. A short or all-0xFF read looks like a file until
the day you need it:

```sh
stat -c%s ssc30kq-oem-full.bin                       # expect 16777216
xxd -s 4      -l 4 -p ssc30kq-oem-full.bin           # expect 49504c5f  ("IPL_")
xxd -s $((0x250000)) -l 4 -p ssc30kq-oem-full.bin    # expect 68737173  ("hsqs")
```

Also keep the bootloader alone. Restoring 256KB is much faster than 16MB, and
it is the only region any of the stages below can break irrecoverably:

```sh
dd if=ssc30kq-oem-full.bin of=ssc30kq-oem-mtd0.bin bs=64k count=4
```

**Recovery, at any point from here on:** clip, write `ssc30kq-oem-mtd0.bin` back
to offset 0 if only the bootloader is suspect, or `ssc30kq-oem-full.bin` whole
if you want the board exactly as it started.

## Before you touch anything

Save the MAC:

```sh
fw_printenv ethaddr
```

Losing it costs nothing at boot. `S03mac` does not read `ethaddr` at all — it
derives the MAC from the SoC's OTP die ID, which is burned at the fab rather
than stored in flash, so the address is the same before and after any erase.
Save it because the environment is the *only* record of the assigned address,
and this is the last moment it exists: nothing on the camera will reproduce it
once mtd1 is overwritten.

If you want it back later, the web UI's network page accepts a MAC and writes
`eth.mac`, which takes precedence over the derived one. That is the intended
route for a unit under a DHCP reservation made against the assigned address —
and it has to be re-entered after any full upgrade, since the overlay holding
`eth.mac` is erased along with everything else.

`sensor` needs no saving at all. `load_sigmastar` probes i2c through `ipcinfo`
whenever the variable is empty and writes the answer back, so it repairs itself
on the next boot.

**The hostname comes from the same place and does not track the MAC.**
`S04hostname` builds the name from the last four hex digits of `soc -s`, falling
back to the MAC only if that fails, so this unit is `ing-noname-ssc30kq-FA37`
from the die ID rather than the `-CD96` its assigned MAC would have given.
Setting `eth.mac` in the web UI does not rename it back.

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

If the camera does not come back, the environment is the only thing that
changed. mtd0 is untouched, so the bootloader still works and its compiled
defaults still describe the OEM table — clip and restore the full dump to get
back to a booting system, then re-apply a corrected `uenv.txt`.

## Stage 1.5 — the bootloader on its own

This exists because the bootloader is the only component that has never
executed. Everything else has been running on this board for weeks. Flashing it
by itself means that if the camera goes quiet, exactly one thing changed, and
the fix is a 256KB write rather than a diagnosis.

```sh
flashcp -v /tmp/u-boot-ssc30kq-nor.bin /dev/mtd0
reboot
```

**Not `sysupgrade -b`.** That option resolves its payload from GitHub releases,
not from a local file — `handle_payload` only honours a path argument when the
mode is `local` — so on this fork it fails before reaching the flash. It also
truncates its input to 256KB in place, which happens to be right for this board
and wrong for Ingenic's 320KB boot partition. `flashcp` avoids both.

Stage 1.5 succeeds if the camera comes back on the network at all. It is booting
a bootloader built here rather than the vendor's, so a successful ssh login is
the whole test — the kernel, rootfs and environment are unchanged from stage 1.

If it does not come back: clip, write `ssc30kq-oem-mtd0.bin` to offset 0, and
the board is back to its stage-1 state. Nothing else needs restoring, because
nothing else was touched.

## Stage 2 — the full image

By the time you get here, stage 1.5 has already written and booted this exact
bootloader, so stage 2 introduces no new component at all — it writes the same
mtd0 a second time, alongside a kernel and rootfs already proven in stage 1.
That is the point of the ordering: the risky write happens once, alone, in
stage 1.5, where a failure has exactly one cause.

```sh
sysupgrade /tmp/thingino-<camera>.bin
```

sysupgrade prints its own warning and gives you ten seconds to cancel, then
erases the `all` partition and writes the image over it, bootloader included.

**A failed run consumes the image.** The file is *moved* to
`/tmp/sysupgrade/fw.bin`, not copied, and `cleanup` removes that directory on
any error — so the copy you uploaded is gone and has to be sent again before
retrying. Keep it somewhere else on the camera if you expect more than one
attempt.

**If it says `Unknown file`, the script that rejected it was not this one.**
Upstream's `update_self` downloads sysupgrade and sysupgrade-stage2 from
themactep's `stable` branch and execs what it fetched, discarding the SigmaStar
image check along with every other local change. This tree defaults
`selfupdate="false"` to prevent that. On a camera running an older image, force
it per-run:

```sh
sysupgrade -x /tmp/thingino-<camera>.bin
```

The stage 2 download also lands in `/sbin/sysupgrade-stage2` rather than the
work directory, so upstream's copy persists in the overlay afterwards. It is
harmless — the patch is entirely in stage 1 — but it is why the file can differ
from the built image on a camera that has run an upgrade.

What stage 2 actually proves is the update path, not the image: that a full
`.bin` is recognised, staged, and flashed end to end. If it fails, the recovery
is the same clip and the same full dump.

Do not run stage 2 to fix a problem from an earlier stage. Nothing that goes
wrong in stage 1 is caused by the bootloader, and nothing that goes wrong in
stage 1.5 is fixed by also rewriting the kernel.

## Recovery

There is no serial console in this procedure, so a failed boot is silent — the
camera simply does not appear on the network. That is the whole diagnostic. The
clip is the way back in, which is why stage 0 is mandatory rather than advisory.

| symptom | restore |
|---|---|
| quiet after stage 1 | nothing — mtd0 is untouched, the bootloader still works. Re-apply a corrected environment |
| quiet after stage 1.5 | `ssc30kq-oem-mtd0.bin` to offset 0 (256KB) |
| quiet after stage 2 | `ssc30kq-oem-full.bin` whole (16MB) |

Restoring only the first 256KB is worth trying first in every case: it is the
fastest write, and the bootloader is the only region whose failure is silent
rather than diagnosable from a booting system.

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

The consequence is that **an upgrade keeps nothing.** A full image is written to
`all`, which spans the whole chip, and stage 2 erases the partition before
writing it — so `data` goes with everything else, and `data` is the jffs2 volume
that backs the overlayfs holding every writable file under `/etc`. Settings,
accounts, ssh host keys and hand-edited files are all overlay diffs and all go.
The web UI says so on the option it recommends; the "partial update" radio that
promises to keep the overlay still maps to the disabled `-p` and will fail.

The only path back is manual, and it has to be taken *before* the upgrade: the
web UI's backup button is `tar -cf - /etc | gzip` streamed to the browser, with
no restore counterpart, so untarring it afterwards is by hand. (`restore.cgi` is
unrelated — it copies a single file back from `/rom` to undo an overlay edit.)

This is not a SigmaStar limitation and needs no fix here. It is only worth
stating because it is what decides where the MAC comes from. An Ingenic camera
survives the erase looking identical to a fresh one, since everything genuinely
per-unit is re-derived from silicon on each boot. This board could have
preferred the assigned `ethaddr`, but that address lives in the environment and
nowhere else, so a camera that preferred it would run one MAC until its first
update and a derived one forever after — changing identity on the network at the
worst possible moment, under whatever DHCP reservation was made against the old
value. `S03mac` therefore derives from the die ID unconditionally and never
reads `ethaddr`: one address, the same before and after every update.

The cost is that the assigned MAC is not used even when it is present, and a
site that needs it must re-enter it on the network page after each full upgrade.
That is a deliberate trade — a 48-bit fab-burned die ID makes collisions
vanishingly unlikely, and the derived address is locally-administered, so it
never claims to be globally unique. `sensor` needs no equivalent treatment;
`load_sigmastar` re-probes i2c whenever the variable is empty and writes it back.

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
