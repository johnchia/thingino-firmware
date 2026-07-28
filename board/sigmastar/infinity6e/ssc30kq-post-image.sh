#!/bin/sh
#
# Check the built images against the SSC30KQ's vendor partition table.
#
# The table comes from the U-Boot bootargs (CONFIG_MTD_CMDLINE_PARTS=y,
# CONFIG_MTD_OF_PARTS unset), not from the device tree:
#
#   mtdparts=NOR_FLASH:256k(boot),64k(env),2048k(kernel),${rootmtd}(rootfs),-(rootfs_data)
#
# Note ${rootmtd}: the rootfs size is a U-Boot *variable*, not a literal, and
# rootfs_data is the "-" catch-all that absorbs whatever is left. So this layout
# is retuned by `fw_setenv rootmtd <size>` alone -- no bootargs edit, and the
# kernel load path (bootcmd's ${kernaddr}/${kernsize}) is never touched.
#
# ${rootmtd} is NOT read from the stored environment. OpenIPC's U-Boot
# (github.com/openipc/u-boot-sigmastar) re-derives it on every boot, in
# common/cmd_sf.c's `sf probe`:
#
#   spi_flash_read(flash, CONFIG_ENV_ROOTADDR, sizeof(buf), buf);
#   memcpy(&magic, &buf[0],  sizeof(magic));
#   memcpy(&bytes, &buf[40], sizeof(bytes));
#   if (magic == 0x73717368)                  /* "hsqs", squashfs superblock */
#       if (bytes + 0x1000 < 0x500000) setenv("rootmtd", "5120k");
#       else                           setenv("rootmtd", "8192k");
#
# It reads the squashfs superblock at the rootfs offset and sizes the partition
# from bytes_used. bootcmd begins with `sf probe 0`, so this runs before
# `run setargs` expands ${rootmtd}. Whatever is in the stored env is overwritten
# in RAM every boot -- `fw_setenv rootmtd` can never take effect, on any unit.
# (A stored 8192k is a fossil: CONFIG_BOOTCOMMAND does `sf probe 0; saveenv`, so
# a first boot with a larger image persisted it once and nothing rewrote it.)
#
# So the rootfs partition auto-sizes to the image, and the limit is a function
# of the image rather than a constant.
#
# THE AUTO-SIZING IS RETROSPECTIVE, NOT PROSPECTIVE, and an earlier version of
# this comment got that wrong. `sf probe` sizes the partition from the squashfs
# superblock ALREADY IN FLASH -- it describes the image that is there, not the
# one you are about to write. So the first image to cross the threshold cannot
# simply be flashed: mtd3 is still 5120k at that moment and flashcp refuses it
# with "rootfs.squashfs bigger than /dev/mtd3". The growth is a one-time
# bootstrap, paid once per unit:
#
#   dd if=rootfs.squashfs of=/dev/mtdblock3 bs=4096 count=1280
#   dd if=rootfs.squashfs of=/dev/mtdblock4 bs=4096 skip=1280
#
# i.e. split the write across mtd3 and mtd4 at the old 5120k boundary, since
# the two are contiguous in flash. The next boot's `sf probe` then reads the
# superblock of the now-complete image, sets rootmtd=8192k, and every later
# flash is a plain `flashcp -v rootfs.squashfs /dev/mtd3`.
#
# Erase mtd4 only AFTER that resize boot -- its offset moves when rootfs grows,
# so erasing first erases the wrong region.
#
#   mtd0  "boot"          256KB
#   mtd1  "env"            64KB
#   mtd2  "kernel"       2048KB   <- uImage goes here
#   mtd3  "rootfs"    5120/8192KB <- rootfs.squashfs here; sized by sf probe
#   mtd4  "rootfs_data"      rest <- jffs2 overlay upperdir, the "-" remainder
#
# Note mtd4's offset therefore moves with the rootfs size. Erase it after the
# rootfs is flashed and after the reboot that resizes the partition, not before.
#
# ROOTFS_LIMIT below mirrors the U-Boot arithmetic exactly rather than
# hardcoding either value, so it stays correct as the image grows.
#
# THIS IS A PROPERTY OF OPENIPC'S BOOTLOADER, NOT OF THE BOARD. The auto-sizing
# is code in OpenIPC's cmd_sf.c; mainline U-Boot and SigmaStar's vendor tree do
# not do it. When we build our own U-Boot and move to thingino's partition
# table, the rootfs partition gets sized to the built image at *build* time,
# this whole mechanism becomes redundant and then wrong, and rootfs_limit_for()
# must be deleted in the same commit -- otherwise the build keeps enforcing a
# limit that no longer describes the device, silently and permissively.
#
# Two things that look like state but are not, and cost a lot of debugging:
#
#   - /proc/cmdline is the expansion from the last boot. It is not updated by
#     fw_setenv, and /proc/mtd only catches up after a reboot.
#   - `fw_printenv rootmtd` is not authoritative for anything. It reports a
#     stored value that sf probe overwrites before it is ever used. Read the
#     image size, or /proc/cmdline after a boot, and ignore the stored variable.
#
# `rootsize` is likewise re-derived by sf probe (from ${filesize}). It is used
# by urwrite for TFTP rootfs writes.
#
# The version of this script carried over from OpenIPC checked rootfs against a
# flat 8MB and did not check the kernel at all. Neither is right here: the chip
# is 16MB but the rootfs partition is 5 or 8MB of it, so the limit cannot be
# derived from the flash size. Getting it wrong moves the failure from the
# build, where it is a number, to the flash, where it is a camera in an unknown
# state -- flashcp just refuses with "bigger than /dev/mtd3".

set -eu

BINARIES_DIR="$1"
IMAGE_NAME="ssc30kq_${OPENIPC_VARIANT:-image}"

KERNEL_LIMIT=$((2048 * 1024))

# Mirror cmd_sf.c: the partition U-Boot will hand us depends on the image size.
rootfs_limit_for() {
	if [ $(($1 + 0x1000)) -lt $((0x500000)) ]; then
		echo $((5120 * 1024))
	else
		echo $((8192 * 1024))
	fi
}

rc=0

check() {
	name="$1"
	path="$2"
	limit="$3"

	if [ ! -f "$path" ]; then
		echo "ERROR: $IMAGE_NAME expected $name at $path" >&2
		return 1
	fi

	size=$(wc -c <"$path")
	free=$((limit - size))
	pct=$((size * 100 / limit))

	if [ "$size" -gt "$limit" ]; then
		echo "ERROR: $IMAGE_NAME $name is $size bytes, over its ${limit}-byte partition by $((0 - free))." >&2
		return 1
	fi

	printf '%s %-16s %8d / %8d bytes (%d%%, %d free)\n' \
		"$IMAGE_NAME" "$name" "$size" "$limit" "$pct" "$free"

	# The kernel partition has almost no slack on this board. Warn while it is
	# still only a warning.
	if [ "$pct" -ge 95 ]; then
		echo "WARNING: $name is at ${pct}% of its partition -- only $free bytes spare." >&2
	fi

	return 0
}

check "uImage" "$BINARIES_DIR/uImage" "$KERNEL_LIMIT" || rc=1

ROOTFS_BIN="$BINARIES_DIR/rootfs.squashfs"
if [ -f "$ROOTFS_BIN" ]; then
	ROOTFS_LIMIT=$(rootfs_limit_for "$(wc -c <"$ROOTFS_BIN")")
	echo "$IMAGE_NAME rootfs partition will be $((ROOTFS_LIMIT / 1024))KB (sf probe sizes it from the image)"
else
	ROOTFS_LIMIT=$((5120 * 1024))
fi
check "rootfs.squashfs" "$ROOTFS_BIN" "$ROOTFS_LIMIT" || rc=1

exit $rc
