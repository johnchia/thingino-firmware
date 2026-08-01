#!/bin/sh
#
# Patch the SigmaStar bootloader's compiled-in partition table so that a board
# whose environment has been erased still boots.
#
# Called from sigmastar-uboot.mk as a pre-build hook, before U-Boot compiles.
#
#   $1  path to include/configs/sstar-common.h in the U-Boot build tree
#   $2  path to the built uImage
#   $3  flash size in MB
#
# WHAT THIS IS FOR
#
# The real partition table is written by post-image.sh into the environment and
# flashed to mtd1. What is compiled into the bootloader is read only when that
# environment is gone -- a bad CRC, or an erase.
#
# Losing it is not hypothetical: the web UI's "Reset firmware" runs
# `firstboot -f`, a 20-second hold of the physical button runs the same, and
# neither can pass `-e`. firstboot erases /dev/mtd1 unless given one. On Ingenic
# that is harmless because the table is compiled in and the environment is a
# convenience; on this board the environment was the only copy, so a factory
# reset left the bootloader describing the OEM layout -- 2048k kernel, 5120k
# rootfs -- with the rootfs offset landing inside the kernel. panic=20 turned
# that into a reboot loop recoverable only over serial.
#
# WHY A RECOVERY TABLE AND NOT AN EXACT COPY
#
# An exact copy needs the rootfs partition size, which needs rootfs.squashfs,
# which does not exist when this runs: Buildroot assembles the root filesystem
# after every package is built, and the bootloader is a package. Only the kernel
# can be measured, and only because sigmastar-uboot.mk declares linux as a
# dependency.
#
# Upstream's equivalent for Ingenic (THINGINO_PATCH_DEV_ENV in
# thingino-uboot.mk) writes the full table and guards on both images existing,
# so on a clean build the guard is false and it silently does nothing -- and
# being a pre-build hook it does not re-run once the package is stamped either.
# Copying that shape would reintroduce the failure being fixed, one level down.
#
# So this claims only what the build can prove:
#
#   256k(boot),64k(env),<measured>k(kernel),-(rootfs)
#
# Four partitions, no `data`, no `all`. Every offset is exact and stays exact
# for any rootfs, because it makes no claim about where the rootfs ends.
#
# WHAT BOOTING ON IT LOOKS LIKE
#
# Read-only. /init cannot find a partition named `data`, calls die(), and its
# EXIT trap execs /sbin/init anyway (overlay/init) -- so the board comes up on
# the serial console with a squashfs root instead of looping. Expect no network:
# dropbear generates host keys into /etc, and wlan0 needs a wpa_supplicant.conf
# that lives in the overlay. It is a recovery mode, exited by re-flashing
# uenv.txt.
#
# CONFIG_BOOTCOMMAND ends with `saveenv`, so the first boot after an erase
# writes this environment back to mtd1. That is the vendor's choice, and useful
# here: the state becomes explicit rather than a CRC failure repeating forever.
#
# ON THE BACKSLASHES
#
# The C source must contain \\${memlx} -- two backslash characters. The compiler
# turns that into \${memlx} in the string, and U-Boot's parser stores ${memlx}
# unexpanded so `run setargs` can expand it at boot against the value chip.c
# sets from detected DRAM. Getting this wrong yields a bootloader that looks
# correct and passes LX_MEM= with nothing after it, so the substitution is
# asserted at the end rather than assumed.

set -eu

HEADER="$1"
UIMAGE="$2"
FLASH_MB="$3"

ALIGN=65536
BOOT_KB=256
ENV_KB=64

for f in "$HEADER" "$UIMAGE"; do
	if [ ! -f "$f" ]; then
		echo "sigmastar-uboot: $f is missing -- cannot build the recovery table." >&2
		echo "  linux is a declared dependency of sigmastar-uboot, so a missing" >&2
		echo "  uImage means the build order changed rather than that the kernel" >&2
		echo "  was not built." >&2
		exit 1
	fi
done

KERNEL_PART=$(( ($(wc -c <"$UIMAGE") + ALIGN - 1) / ALIGN * ALIGN ))
KERNEL_KB=$((KERNEL_PART / 1024))
KERN_ADDR=$(((BOOT_KB + ENV_KB) * 1024))
ROOT_ADDR=$((KERN_ADDR + KERNEL_PART))
ROOT_SIZE=$((FLASH_MB * 1024 * 1024 - ROOT_ADDR))

if [ "$ROOT_SIZE" -le 0 ]; then
	echo "sigmastar-uboot: a ${KERNEL_KB}KB kernel leaves no room for a rootfs in ${FLASH_MB}MB." >&2
	exit 1
fi

# Single-quoted so the shell leaves both the backslashes and the ${} alone. This
# is the exact text the C file must contain.
MEMLX='\\${memlx}'
MEMSZ='\\${memsz}'

BOOTARGS="console=ttyS0,115200 panic=20 root=/dev/mtdblock3 rootfstype=squashfs init=/init"
BOOTARGS="$BOOTARGS mtdparts=NOR_FLASH:${BOOT_KB}k(boot),${ENV_KB}k(env),${KERNEL_KB}k(kernel),-(rootfs)"
BOOTARGS="$BOOTARGS LX_MEM=$MEMLX mma_heap=mma_heap_name0,miu=0,sz=$MEMSZ cma=2M"

# awk rather than sed, because sed would consume the backslashes a second time
# on the way out. Two things here are load-bearing and were both got wrong first
# time round:
#
#   ENVIRON rather than -v. awk processes backslash escapes in a -v assignment,
#   so a value containing \\ arrives as \ and LX_MEM silently loses an escape.
#   ENVIRON is passed through untouched.
#
#   First occurrence only. sstar-common.h defines CONFIG_BOOTARGS and the
#   CONFIG_ENV_* offsets three times -- once for NOR, once under
#   CONFIG_MS_SPINAND, once for MMC. Only the NOR block describes this board,
#   and it is the first. Replacing all three quietly rewrites the NAND layout
#   with NOR offsets, which costs nothing on this board and would be a trap on
#   the next one.
patch_define() {
	pd_name="$1"
	PD_VALUE="$2"
	export PD_VALUE
	awk -v name="$pd_name" '
		!done && $0 ~ "^#define " name " " {
			print "#define " name " " ENVIRON["PD_VALUE"]
			done = 1
			next
		}
		{ print }
	' "$HEADER" >"$HEADER.tmp"
	mv "$HEADER.tmp" "$HEADER"
	unset PD_VALUE
}

patch_define CONFIG_ENV_KERNSIZE "$(printf '0x%x' "$KERNEL_PART")"
patch_define CONFIG_ENV_ROOTADDR "$(printf '0x%x' "$ROOT_ADDR")"
patch_define CONFIG_ENV_ROOTSIZE "$(printf '0x%x' "$ROOT_SIZE")"
patch_define CONFIG_BOOTARGS "\"$BOOTARGS\""

# rootmtd was the indirection the OEM table used for the rootfs size. Nothing
# expands it now -- the table above is literal, and the auto-sizing that used to
# set it was removed in 0001-cmd_sf-drop-retrospective-rootfs-auto-sizing.patch.
# Left in place it would be a stored variable that looks authoritative and is
# read by nothing, which is how it misled once already.
grep -v '"rootmtd=5120k\\0" \\' "$HEADER" >"$HEADER.tmp"
mv "$HEADER.tmp" "$HEADER"

# Assertions, not decoration. Each of these has a silent failure mode: a table
# that boots the wrong offset, or an LX_MEM with nothing after it.
fail=0

grep -q "^#define CONFIG_BOOTARGS .*${KERNEL_KB}k(kernel),-(rootfs)" "$HEADER" || {
	echo "sigmastar-uboot: CONFIG_BOOTARGS does not carry the recovery table." >&2
	fail=1
}

# Two literal backslashes before ${memlx}, checked as characters rather than by
# eye, and scoped to the line just written. The NAND and MMC definitions carry
# the same escaping untouched, so counting matches across the whole file passes
# whether or not the rewrite kept it.
if [ "$(grep -F -- '-(rootfs)' "$HEADER" | grep -cF 'LX_MEM=\\${memlx}')" != "1" ]; then
	echo 'sigmastar-uboot: the recovery CONFIG_BOOTARGS lost its \\${memlx}' >&2
	echo "  escaping -- LX_MEM would reach the kernel empty, the MI drivers would" >&2
	echo "  get no carveout, and nothing would stream." >&2
	fail=1
fi

grep -q '^#define CONFIG_ENV_ROOTADDR' "$HEADER" || {
	echo "sigmastar-uboot: CONFIG_ENV_ROOTADDR is missing from $HEADER." >&2
	fail=1
}

# Exactly one CONFIG_BOOTARGS may carry the recovery table. The NAND and MMC
# definitions describe boot media this board does not have, and rewriting them
# with NOR offsets would be invisible here and wrong on the board that used them.
if [ "$(grep -c '^#define CONFIG_BOOTARGS .*-(rootfs)' "$HEADER")" != "1" ]; then
	echo "sigmastar-uboot: the recovery table was written to more than one" >&2
	echo "  CONFIG_BOOTARGS -- the NAND or MMC block was overwritten." >&2
	fail=1
fi

grep -q '^#define CONFIG_BOOTARGS .*ubi\.mtd=' "$HEADER" || {
	echo "sigmastar-uboot: the CONFIG_MS_SPINAND CONFIG_BOOTARGS was overwritten." >&2
	fail=1
}

if [ "$fail" -ne 0 ]; then
	exit 1
fi

printf 'sigmastar-uboot recovery table  %dk(boot),%dk(env),%dk(kernel),-(rootfs)  rootaddr=0x%x\n' \
	"$BOOT_KB" "$ENV_KB" "$KERNEL_KB" "$ROOT_ADDR"
