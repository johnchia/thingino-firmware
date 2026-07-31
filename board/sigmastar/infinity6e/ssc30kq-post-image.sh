#!/bin/sh
#
# Size the SSC30KQ's flash partitions to the built images and emit the U-Boot
# environment that describes them.
#
# The partition table is a property of the environment, not of the board. The
# kernel takes it from the cmdline (CONFIG_MTD_CMDLINE_PARTS=y,
# CONFIG_MTD_OF_PARTS unset), U-Boot builds the cmdline from ${bootargs}, and
# this script writes ${bootargs}. Nothing reads a device tree for it.
#
#   mtd0  "boot"     256KB   fixed -- mask-ROM container, see sigmastar-uboot.mk
#   mtd1  "env"       64KB   fixed -- must match the bootloader's CONFIG_ENV_*
#   mtd2  "kernel"           sized to uImage, 64KB-aligned
#   mtd3  "rootfs"           sized to rootfs.squashfs, 64KB-aligned
#   mtd4  "data"             the remainder; jffs2 overlay upperdir
#   mtd5  "all"       16MB   whole chip at offset 0, overlapping the rest
#
# The two fixed sizes are not free choices. The bootloader is compiled with
# CONFIG_ENV_OFFSET 0x40000 and CONFIG_ENV_SIZE 0x10000, so "boot" must be
# exactly 256KB and "env" exactly 64KB or the environment is read from the
# wrong place. Changing either means changing sstar-common.h to match.
#
# "all" is what thingino-sysupgrade requires: check_upgrade_partitions() hard
# fails without a partition named "all", and a full image is flashed to it --
# which is to say a full sysupgrade rewrites the bootloader, and is only
# meaningful because the bootloader in that image is one we build.
#
# ("upgrade", which sysupgrade also looks for, is deliberately absent. It is a
# real partition, but a historical one: the compiled default table in the
# 2013.07 U-Boot carries 15872k@0x80000(upgrade) -- everything past the
# bootloader, env and config -- which is what let a partial image be flashed
# without touching mtd0. The modern generated table dropped it, and sysupgrade
# disabled partial upgrades outright in cd645cae6, so `-p` now exits 1 before
# any partition is looked up. Adding one here would resurrect a path no board
# takes.)
#
# "data" replaces the OEM's "rootfs_data". The name matters: /init matches the
# overlay partition with a loose /data/ in mount_jffs2 but a strict /"data"/ in
# format_overlay, so under the OEM name the format-on-corruption recovery path
# resolves to an empty device and fails.
#
# SIZING THE KERNEL AND ROOTFS PARTITIONS TO THE IMAGES MOVES THE OFFSET OF
# EVERY PARTITION AFTER THEM. The environment written here describes one exact
# set of images. Flashing a kernel that crosses a 64KB boundary without
# reflashing the environment leaves the table describing the previous image,
# and the rootfs offset then points into the middle of nothing. Kernel, rootfs
# and environment are flashed together or not at all.
#
# LX_MEM/mma_heap/cma are the SigmaStar memory carveout, and without them the
# MI drivers get no contiguous memory and nothing streams. They are written as
# ${memlx}/${memsz} rather than literals because the bootloader sets those from
# the RAM size it detects at runtime (infinity6e/chip.c), so one image serves
# every DRAM population of this SoC.

set -eu

BINARIES_DIR="$1"
IMAGE_NAME="ssc30kq_${OPENIPC_VARIANT:-image}"

ALIGN=65536
FLASH_KB=$((${FLASH_SIZE_MB:-16} * 1024))
BOOT_KB=256
ENV_KB=64

rc=0

align_up() {
	echo $((($1 + ALIGN - 1) / ALIGN * ALIGN))
}

# For partitions whose size is fixed by something outside this build -- the
# mask ROM's container, the bootloader's compiled CONFIG_ENV_*. Here a
# percentage is a real measure of remaining headroom, so it is worth a warning.
check_fixed() {
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

	printf '%s %-24s %8d / %8d bytes (%d%%, %d free)\n' \
		"$IMAGE_NAME" "$name" "$size" "$limit" "$pct" "$free"

	if [ "$pct" -ge 95 ]; then
		echo "WARNING: $name is at ${pct}% of its partition -- only $free bytes spare." >&2
	fi

	return 0
}

# For partitions cut to fit the image they hold. These are always ~100% full by
# construction, so a percentage measures alignment slack and nothing else --
# reporting one as though it were headroom would be worse than saying nothing.
# What these images actually compete for is the overlay, checked once below.
report_sized() {
	printf '%s %-24s %8d bytes -> %8d partition (%d slack)\n' \
		"$IMAGE_NAME" "$1" "$2" "$3" "$(($3 - $2))"
}

KERNEL_BIN="$BINARIES_DIR/uImage"
ROOTFS_BIN="$BINARIES_DIR/rootfs.squashfs"

for f in "$KERNEL_BIN" "$ROOTFS_BIN"; do
	if [ ! -f "$f" ]; then
		echo "ERROR: $IMAGE_NAME expected $(basename "$f") at $f" >&2
		exit 1
	fi
done

KERNEL_PART=$(align_up "$(wc -c <"$KERNEL_BIN")")
ROOTFS_PART=$(align_up "$(wc -c <"$ROOTFS_BIN")")

KERNEL_KB=$((KERNEL_PART / 1024))
ROOTFS_KB=$((ROOTFS_PART / 1024))
DATA_KB=$((FLASH_KB - BOOT_KB - ENV_KB - KERNEL_KB - ROOTFS_KB))

# The bootloader is compiled before the kernel size is known, so its built-in
# kernaddr/rootaddr are only correct while the kernel partition happens to be
# 2048KB. The values written below are authoritative and replace them.
KERN_ADDR=$(((BOOT_KB + ENV_KB) * 1024))
ROOT_ADDR=$((KERN_ADDR + KERNEL_PART))
DATA_ADDR=$((ROOT_ADDR + ROOTFS_PART))

if [ "$DATA_KB" -le 0 ]; then
	echo "ERROR: $IMAGE_NAME kernel ${KERNEL_KB}KB + rootfs ${ROOTFS_KB}KB leave no room for the overlay in ${FLASH_KB}KB of flash." >&2
	exit 1
fi

report_sized "uImage" "$(wc -c <"$KERNEL_BIN")" "$KERNEL_PART"
report_sized "rootfs.squashfs" "$(wc -c <"$ROOTFS_BIN")" "$ROOTFS_PART"

# Built only when sigmastar-uboot is selected, and building it is not flashing
# it -- the board boots whatever is already in mtd0. Checked because it has the
# least headroom of the three artifacts and its overflow is the one discovered
# latest: nothing reads it until someone writes the single partition that
# cannot be recovered in software.
for boot_bin in "$BINARIES_DIR"/u-boot-*-nor.bin; do
	[ -f "$boot_bin" ] || continue
	check_fixed "$(basename "$boot_bin")" "$boot_bin" $((BOOT_KB * 1024)) || rc=1
done

MTDPARTS="NOR_FLASH:${BOOT_KB}k(boot),${ENV_KB}k(env),${KERNEL_KB}k(kernel),${ROOTFS_KB}k(rootfs),${DATA_KB}k(data),${FLASH_KB}k@0(all)"

BOOTARGS="console=ttyS0,115200 panic=20 root=/dev/mtdblock3 rootfstype=squashfs init=/init"
BOOTARGS="$BOOTARGS mtdparts=$MTDPARTS"
BOOTARGS="$BOOTARGS LX_MEM=\${memlx} mma_heap=mma_heap_name0,miu=0,sz=\${memsz} cma=2M"

UENV_TXT="$BINARIES_DIR/uenv.txt"

# ethaddr and sensor are deliberately absent. They are per-unit values the OEM
# wrote once, S03mac reads ethaddr rather than inventing a MAC, and writing
# this environment over the old one destroys both. Read them off the running
# camera and put them back after flashing mtd1 -- see the camera README.
{
	echo "baseaddr=0x21000000"
	echo "kernaddr=$(printf '0x%x' "$KERN_ADDR")"
	echo "kernsize=$(printf '0x%x' "$KERNEL_PART")"
	echo "rootaddr=$(printf '0x%x' "$ROOT_ADDR")"
	echo "rootsize=$(printf '0x%x' "$ROOTFS_PART")"
	echo "dataaddr=$(printf '0x%x' "$DATA_ADDR")"
	echo "datasize=$(printf '0x%x' $((DATA_KB * 1024)))"
	echo "mtdparts=$MTDPARTS"
	echo "bootargs=$BOOTARGS"
	echo "bootcmd=sf probe 0; setenv setargs setenv bootargs \${bootargs}; run setargs; sf read \${baseaddr} \${kernaddr} \${kernsize}; bootm \${baseaddr}"
} >"$UENV_TXT"

# mkenvimage pads to the partition size and prepends the CRC the bootloader
# checks. A plain text file written to mtd1 would be rejected as corrupt and
# silently replaced by the compiled-in defaults, which still carry the OEM
# table -- a failure that looks like the new table never having been written.
MKENVIMAGE="${HOST_DIR:-}/bin/mkenvimage"
if [ -x "$MKENVIMAGE" ]; then
	"$MKENVIMAGE" -s $((ENV_KB * 1024)) -o "$BINARIES_DIR/u-boot-env.bin" "$UENV_TXT"
	# mkenvimage pads to exactly -s, so this is an assertion that the tool did
	# what was asked, not a headroom measurement. A short image would be read
	# as a bad CRC and fall back to the compiled-in OEM table.
	env_size=$(wc -c <"$BINARIES_DIR/u-boot-env.bin")
	if [ "$env_size" -ne $((ENV_KB * 1024)) ]; then
		echo "ERROR: $IMAGE_NAME u-boot-env.bin is $env_size bytes, expected $((ENV_KB * 1024))." >&2
		rc=1
	else
		printf '%s %-24s %8d bytes (%d vars)\n' \
			"$IMAGE_NAME" "u-boot-env.bin" "$env_size" "$(wc -l <"$UENV_TXT")"
	fi
else
	echo "ERROR: $IMAGE_NAME mkenvimage not found at $MKENVIMAGE -- cannot build u-boot-env.bin." >&2
	echo "       Enable BR2_PACKAGE_HOST_UBOOT_TOOLS_ENVIMAGE in the camera defconfig." >&2
	rc=1
fi

printf '%s %-24s %s\n' "$IMAGE_NAME" "partitions" "$MTDPARTS"
printf '%s %-24s %dKB (%d%% of flash)\n' \
	"$IMAGE_NAME" "overlay (data)" "$DATA_KB" "$((DATA_KB * 100 / FLASH_KB))"

# The overlay is what the kernel and rootfs grow into, so it is the one number
# here that measures anything scarce. sysupgrade stages in /tmp rather than the
# overlay, so this budget is for /etc and user data, not for updates.
if [ "$DATA_KB" -lt 1024 ]; then
	echo "WARNING: overlay is down to ${DATA_KB}KB -- kernel and rootfs growth comes out of it." >&2
fi

exit $rc
