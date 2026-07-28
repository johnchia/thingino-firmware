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
# rootmtd is 8192k, giving:
#
#   mtd0  "boot"          256KB
#   mtd1  "env"            64KB
#   mtd2  "kernel"       2048KB   <- uImage goes here
#   mtd3  "rootfs"       8192KB   <- rootfs.squashfs here
#   mtd4  "rootfs_data"  5824KB   <- jffs2 overlay upperdir, the "-" remainder
#
# Two traps this has already sprung:
#
#   - /proc/cmdline is the expansion from the last boot and does not track later
#     fw_setenv changes. It read 5120k while the env already said 8192k. Trust
#     `fw_printenv rootmtd`, not /proc/cmdline, and remember /proc/mtd only
#     catches up after a reboot.
#   - `rootsize` (0x500000) is a separate variable used by urwrite for TFTP
#     rootfs writes. It does not follow rootmtd. If rootmtd changes, rootsize
#     has to be changed with it or a TFTP write erases the wrong length.
#
# Re-read `fw_printenv rootmtd` before changing ROOTFS_LIMIT below.
#
# The version carried over from OpenIPC checked rootfs against a flat 8MB and
# did not check the kernel at all. Neither is right for this board: the chip is
# 16MB but the rootfs partition is 5MB of it, so the limit cannot be derived
# from the flash size. Getting it wrong moves the failure from the build, where
# it is a number, to the flash, where it is a camera in an unknown state --
# flashcp just refuses with "bigger than /dev/mtd3".
#
# Re-read /proc/mtd on the device before changing these.

set -eu

BINARIES_DIR="$1"
IMAGE_NAME="ssc30kq_${OPENIPC_VARIANT:-image}"

KERNEL_LIMIT=$((2048 * 1024))
ROOTFS_LIMIT=$((8192 * 1024))

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
check "rootfs.squashfs" "$BINARIES_DIR/rootfs.squashfs" "$ROOTFS_LIMIT" || rc=1

exit $rc
