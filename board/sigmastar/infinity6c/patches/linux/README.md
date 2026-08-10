# Kernel patches — Infinity6C

The directory has to exist regardless of contents: `core-sigmastar.fragment`
sets `BR2_LINUX_KERNEL_PATCH` for every SigmaStar family, and `linux.mk` errors
on a path that is neither a file nor a directory.

## 0001 — armthumb BCJ filter

Same patch as Infinity6E and Infinity6B0, applied unchanged. This family meets
its preconditions exactly:

    CONFIG_KERNEL_XZ=y
    CONFIG_THUMB2_KERNEL=y

`scripts/xz_wrap.sh` picks the BCJ filter from `SRCARCH` alone, so any ARM
target gets `--arm`, which rewrites A32 branches. A Thumb-2 kernel is T32, so
that filter matches almost nothing while still disturbing the entropy model.
`lib/decompress_unxz.c` then has to agree, because it compiles in exactly one
BCJ decoder.

It applies to 5.10 with no change from the 4.9 version -- both files carry
identical context in the two trees.

This was originally recorded here as *not needed*, on the grounds that the
`CONFIG_XZ_DEC_*` symbols left unset in `ssc377de.config` govern only the
runtime XZ decoder used by squashfs. That is true and irrelevant: the patch
changes a `#define` inside `lib/decompress_unxz.c` selected by `#ifdef
CONFIG_ARM`, which no Kconfig XZ symbol reaches.

Nothing here is a correctness fix. Compressor and decompressor agree either
way, so an unpatched kernel boots -- it is just larger, which matters because
the kernel partition is 2048k and the unpatched image leaves 63,960 bytes spare.

## Anything else

The kernel is pinned to OpenIPC's `sigmastar-infinity6c` branch, which already
carries seven fixes above the BSP import -- lzma uImage, spinand probe-on-type,
mtdparts identifier, watchdog magic close, python3 scripts, i2c warnings,
regulatory defaults. A new patch here should be something that branch does not
already have.
