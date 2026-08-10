# Kernel patches — Infinity6C

None. The directory has to exist regardless: `core-sigmastar.fragment` sets
`BR2_LINUX_KERNEL_PATCH` for every SigmaStar family, and `linux.mk` errors on a
path that is neither a file nor a directory.

## Do not add the armthumb BCJ patch here

Infinity6E and Infinity6B0 carry `0001-xz-use-the-armthumb-bcj-filter-on-thumb2-kernels.patch`.
It does not belong on this family, and adding it is worse than useless.

Those families wrap a **zImage** — `uImage` is `zImage` plus a 64-byte header,
`-C none`, and the kernel decompresses itself. `scripts/xz_wrap.sh` and
`lib/decompress_unxz.c` are both live on that path.

Infinity6C does not. OpenIPC's `3473bad24` rewrites the rule in
`arch/arm/boot/Makefile` to compress `Image` directly:

    xz -z -k -f $(obj)/Image
    ${MKIMAGE_BIN} ... -C lzma -d $(obj)/Image.xz $(obj)/uImage

`xz_wrap.sh` is never called, so the patch cannot reach the shipped image, and
**u-boot** does the decompressing, not the kernel — so `decompress_unxz.c` is
not involved either.

That matters because u-boot cannot decode a BCJ-filtered stream. It ships no
`lib/xz/xz_dec_bcj.c`, every `XZ_DEC_*` filter is commented out in
`lib/xz/xz_config.h`, and no BCJ symbol is linked into the binary. A filtered
stream fails the `Filter ID = LZMA2` test in `xz_dec_stream.c`.

And it fails **silently**. In `common/bootm.c` the `IH_COMP_LZMA` case — which
SigmaStar redefined to mean XZ, so the `-C lzma` label is deliberate — has its
error check commented out, and never sets `*load_end`. u-boot prints a return
code and boots whatever is at the load address. No `BOOTM_ERR_RESET`, unlike
every neighbouring case.

So: filtering the stream to save ~55KB bricks the board with no diagnostic.
Doing it needs `xz_dec_bcj.c` added to u-boot first.

Also note `xz_wrap.sh`'s `lc=1,pb=0` tuning is matched to BCJ output. Applied
here without the filter it *costs* ~32KB against plain `xz -z`.

## Anything else

The kernel is pinned to OpenIPC's `sigmastar-infinity6c` branch, which already
carries seven fixes above the BSP import — lzma uImage, spinand probe-on-type,
mtdparts identifier, watchdog magic close, python3 scripts, i2c warnings,
regulatory defaults. A new patch here should be something that branch does not
already have.
