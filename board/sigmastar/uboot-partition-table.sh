#!/bin/sh
#
# Compile the real partition table into the SigmaStar bootloader.
#
# Called from sigmastar-uboot.mk as a pre-build hook.
#
#   $1  path to include/configs/sstar-common.h in the U-Boot build tree
#   $2  path to the table file post-image.sh writes, if it exists yet
#
# WHY THIS EXISTS
#
# U-Boot reads its partition table from one of two places: the environment in
# mtd1, or the defaults compiled into it. thingino writes the real table to the
# environment, but the environment is not durable -- the web UI's "Reset
# firmware" runs `firstboot -f`, a 20-second hold of the physical button runs
# the same, and neither can pass the `-e` that would spare mtd1.
#
# On Ingenic that is harmless because the compiled-in table is correct and the
# environment is a convenience. Making that true here is the whole point of this
# script: erase the environment and the board still boots, mounts its overlay
# and comes up on the network, exactly as a factory reset should behave.
#
# THE ORDERING PROBLEM, AND HOW UPSTREAM SOLVES IT
#
# The table cannot be known when a Buildroot package builds. The rootfs
# partition is sized to rootfs.squashfs, and Buildroot assembles the root
# filesystem after every package is built.
#
# thingino solves this in its own Makefile rather than in Buildroot, at
# Makefile:1143:
#
#   $(U_BOOT_BIN): $(U_BOOT_ENV_TXT)
#           ... uboot-dirclean uboot
#
# The chain is kernel -> rootfs -> uenv.txt -> U-Boot, and the recipe dirtycleans
# first so the build stamp cannot suppress the rebuild. U-Boot is therefore
# compiled last, when both images exist.
#
# Those rules key off the Ingenic artifact and the Ingenic uboot package, so a
# SigmaStar board never reaches them: `br-all` is a straight passthrough to
# Buildroot's `all` (Makefile:921), and our image assembly happens in
# post-image.sh. So post-image.sh re-invokes this package the same way, once the
# sizes are known. This script is what runs on that second pass.
#
# On the first pass the table file does not exist and the header is left alone.
# The bootloader built then is thrown away by the dirclean, so its contents do
# not matter -- but it must still build, which is why absence is not an error.
#
# ON THE BACKSLASHES
#
# The C source must contain \\${memlx} -- two backslash characters. The compiler
# turns that into \${memlx}, and U-Boot's parser stores ${memlx} unexpanded so
# `run setargs` can expand it at boot against the value chip.c sets from
# detected DRAM. Get this wrong and the bootloader looks correct while passing
# LX_MEM= with nothing after it, so it is asserted rather than assumed.

set -eu

HEADER="$1"
TABLE="${2:-}"

if [ ! -f "$HEADER" ]; then
	echo "sigmastar-uboot: $HEADER is missing -- the U-Boot tree changed shape." >&2
	exit 1
fi

if [ -z "$TABLE" ] || [ ! -f "$TABLE" ]; then
	echo "sigmastar-uboot: no partition table yet; building with vendor defaults."
	echo "  post-image.sh rebuilds this package once the rootfs is sized."
	exit 0
fi

# Written by post-image.sh, which owns the arithmetic. Deliberately not
# recomputed here: two implementations of the same sizing that drift apart would
# put one table in the environment and a different one in the bootloader, and
# the difference would only appear on a board that had lost its environment.
# shellcheck disable=SC1090
. "$TABLE"

for v in MTDPARTS KERN_ADDR KERNEL_PART ROOT_ADDR ROOTFS_PART; do
	eval "val=\${$v:-}"
	if [ -z "$val" ]; then
		echo "sigmastar-uboot: $TABLE does not define $v." >&2
		exit 1
	fi
done

# Single-quoted so the shell leaves both the backslashes and the ${} alone.
# This is the exact text the C file must contain.
MEMLX='\\${memlx}'
MEMSZ='\\${memsz}'

BOOTARGS="console=ttyS0,115200 panic=20 root=/dev/mtdblock3 rootfstype=squashfs init=/init"
BOOTARGS="$BOOTARGS mtdparts=$MTDPARTS"
BOOTARGS="$BOOTARGS LX_MEM=$MEMLX mma_heap=mma_heap_name0,miu=0,sz=$MEMSZ cma=2M"

# awk rather than sed, because sed would consume the backslashes a second time
# on the way out. Two things here are load-bearing:
#
#   ENVIRON rather than -v. awk processes backslash escapes in a -v assignment,
#   so a value containing \\ arrives as \ and LX_MEM silently loses an escape.
#
#   First occurrence only. sstar-common.h defines CONFIG_BOOTARGS and the
#   CONFIG_ENV_* offsets three times -- once for NOR, once under
#   CONFIG_MS_SPINAND, once for MMC. Only the NOR block describes this board,
#   and it is the first. Replacing all three quietly rewrites the NAND layout
#   with NOR offsets, which costs nothing here and would be a trap on the next
#   board.
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

patch_define CONFIG_ENV_KERNADDR "$(printf '0x%x' "$KERN_ADDR")"
patch_define CONFIG_ENV_KERNSIZE "$(printf '0x%x' "$KERNEL_PART")"
patch_define CONFIG_ENV_ROOTADDR "$(printf '0x%x' "$ROOT_ADDR")"
patch_define CONFIG_ENV_ROOTSIZE "$(printf '0x%x' "$ROOTFS_PART")"
patch_define CONFIG_BOOTARGS "\"$BOOTARGS\""

# rootmtd was the indirection the OEM table used for the rootfs size. The table
# above is literal, and the auto-sizing that used to set rootmtd was removed in
# 0001-cmd_sf-drop-retrospective-rootfs-auto-sizing.patch. Left in place it
# would be a stored variable that looks authoritative and is read by nothing,
# which is how it misled once already.
grep -v '"rootmtd=5120k\\0" \\' "$HEADER" >"$HEADER.tmp"
mv "$HEADER.tmp" "$HEADER"

# Assertions, not decoration. Each has a silent failure mode: a table that boots
# the wrong offset, or an LX_MEM with nothing after it.
fail=0

grep -qF -- "mtdparts=$MTDPARTS" "$HEADER" || {
	echo "sigmastar-uboot: CONFIG_BOOTARGS does not carry the generated table." >&2
	fail=1
}

# Exactly one CONFIG_BOOTARGS may carry it. The NAND and MMC definitions
# describe boot media this board does not have, and rewriting them with NOR
# offsets would be invisible here and wrong on the board that used them.
if [ "$(grep -cF -- "mtdparts=$MTDPARTS" "$HEADER")" != "1" ]; then
	echo "sigmastar-uboot: the table was written to more than one CONFIG_BOOTARGS" >&2
	echo "  -- the NAND or MMC block was overwritten." >&2
	fail=1
fi

grep -q '^#define CONFIG_BOOTARGS .*ubi\.mtd=' "$HEADER" || {
	echo "sigmastar-uboot: the CONFIG_MS_SPINAND CONFIG_BOOTARGS was overwritten." >&2
	fail=1
}

# Two literal backslashes before ${memlx}, checked as characters rather than by
# eye, and scoped to the line just written. The NAND and MMC definitions carry
# the same escaping untouched, so counting across the whole file would pass
# whether or not the rewrite kept it.
if [ "$(grep -F -- "mtdparts=$MTDPARTS" "$HEADER" | grep -cF 'LX_MEM=\\${memlx}')" != "1" ]; then
	echo 'sigmastar-uboot: the generated CONFIG_BOOTARGS lost its \\${memlx}' >&2
	echo "  escaping -- LX_MEM would reach the kernel empty, the MI drivers would" >&2
	echo "  get no carveout, and nothing would stream." >&2
	fail=1
fi

[ "$fail" -eq 0 ] || exit 1

printf 'sigmastar-uboot compiled-in table  %s\n' "$MTDPARTS"
