#!/bin/sh
#
# Check the built images against the SSC30KQ's *actual* vendor partition table.
#
#   0x000000040000-0x000000050000 : "env"
#   0x000000050000-0x000000250000 : "kernel"       2048KB
#   0x000000250000-0x000000750000 : "rootfs"       5120KB
#   0x000000750000-0x000001000000 : "rootfs_data"  8896KB
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
ROOTFS_LIMIT=$((5120 * 1024))

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
