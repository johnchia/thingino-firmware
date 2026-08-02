# Vendor-neutral fixes worth offering upstream

Findings from the SigmaStar port that are **not** SigmaStar-specific. Each is a
bug on stock Ingenic hardware too, and each can be described without mentioning
that this fork exists — which matters, because the repo describes itself as
firmware for Ingenic SoC IP cameras and a scope conversation is a separate
thing from a bug report.

Order matters. Land the uncontroversial ones first; they establish that the
reports are worth reading before any question of multi-SoC support is raised.

---

## 1. "Wipe overlay" in the web UI erases the kernel

**Severity: destructive, one click, no confirmation beyond the UI's own.**

`package/thingino-webui/files/www/x/firmware-reset.cgi:71`

```sh
action_command="flash_eraseall -j /dev/mtd2"
```

The action is labelled *"Wipe overlay — Erase data stored in the overlay
partition."* But the generated partition table (`Makefile:1131`) is

```
<uboot>k(boot),<env>k(env),<kernel>k(kernel),<rootfs>k(rootfs),<data>k(data),<flash>k@0(all)
```

so the indices are `mtd0` boot, `mtd1` env, **`mtd2` kernel**, `mtd3` rootfs,
`mtd4` data, `mtd5` all. The overlay is `mtd4`. `mtd2` is the kernel.

### Why the index is stale rather than simply wrong

It used to be right. Commit `3b7997b46`, *"merge config and extras partitions
into a larger unified data overlay at the end of the firmware"*, moved the
overlay to the end of flash. Before that the config partition sat at `mtd2` and
this CGI erased exactly the right thing. The layout changed; the hardcoded index
did not.

### The fix, and why it needs no new machinery

`package/thingino-system/files/firstboot` already resolves the overlay by name
and is the model to copy:

```sh
data_dev=$(awk -F: '/"data"/{print $1}' /proc/mtd)
```

`/init:17` does the same. So the correct pattern exists twice in the tree; the
CGI is the outlier. Resolving by name is also what makes the action survive the
next layout change.

### Confirmed / not confirmed

Confirmed: the index arithmetic against the generated table, the shipped CGI
inside `rootfs.squashfs` (not just the source), and the commit that moved the
overlay.

**Not** confirmed on a running Ingenic camera. Do that before filing — the claim
is that a shipped button destroys the kernel on every current board, and it
should be demonstrated rather than derived. A camera with a serial console and a
flash clip attached, on a build that can be restored, is the right place.

### Blast radius when it fires

`flash_eraseall` on the kernel partition leaves U-Boot and the environment
intact, so the board drops to a U-Boot prompt rather than bricking. Recovery is
`uknor`/TFTP or an external programmer — both of which need physical access, and
on a camera with no Ethernet and no header, that means opening the case. For an
end user the device is dead.

---

## 2. `sysupgrade` replaces its own patched self before running

`package/thingino-sysupgrade/files/sysupgrade` — `update_self` fetches both
stages from themactep's `stable` branch and `exec`s the download, reverting any
downstream patch moments before it is used.

This is a bug for *any* fork, not just this one: it means a downstream fix to
sysupgrade cannot take effect, silently. Already defaulted off in this tree.
Vendor-neutral, needs no SigmaStar context, and is the natural opener.

---

## 3. `sysupgrade` cannot recognise a non-Ingenic image

Same file: it dispatches on the first four bytes being Ingenic's `06050403`.
`image_starts_with_bootloader` generalises the check. Less obviously useful to
upstream than the two above — it is not specific to this board, only to not
being Ingenic — so it goes last, and only if the earlier ones land well.

---

## 4. `mac80211` is forced on for a driver that never uses it

`package/wifi-rtl8188fu/wifi-rtl8188fu.mk` enables `CONFIG_MAC80211` and the
minstrel rate-control options. Realtek's out-of-tree stack talks to `cfg80211`
directly and implements its own MLME and rate control, so nothing it registers
reaches mac80211. The cost is roughly 500KB of kernel text on every board
shipping this driver.

Guarded rather than removed in this tree, because a straight removal is a claim
about hardware nobody here can test. Offering it upstream means asking someone
with an Ingenic board and this Wi-Fi part to confirm the association still comes
up — which is the right conversation to have, but it is a request for testing
rather than a patch to merge.

---

## Not on this list

**The compiled-in partition table going stale** (`THINGINO_PATCH_DEV_ENV` in
`package/thingino-uboot/thingino-uboot.mk`) is a real defect — it is a
`UBOOT_PRE_BUILD_HOOK` guarded on `uImage` and `rootfs.squashfs`, neither of
which exists when U-Boot compiles on a clean build, and pre-build hooks do not
re-run once the package is stamped. So the fallback table is likely wrong on
Ingenic too.

It is left off this list deliberately: on Ingenic the environment is
regenerable and almost always intact, so the fallback is rarely exercised, and
the fix is entangled with how Buildroot orders package builds against image
assembly. Reporting it well means proposing a solution, and the solution this
fork adopted (a *recovery* table rather than an exact one — see
`package/sigmastar-uboot/sigmastar-uboot.mk`) is shaped by a constraint Ingenic
does not have. Revisit once that design has hardware mileage.
