# Kernel patches — Infinity6C

Empty on purpose, and the directory has to exist: `core-sigmastar.fragment`
sets `BR2_LINUX_KERNEL_PATCH` for every SigmaStar family, and `linux.mk` errors
on a path that is neither a file nor a directory. An empty directory applies
nothing.

Unlike the other two families this one starts unpatched. Infinity6E and
Infinity6B0 carry an XZ/Thumb-2 decompressor fix; the equivalent is not needed
here, because the `CONFIG_XZ_DEC_*` symbols left unset in `ssc377de.config`
govern the runtime XZ decoder used by squashfs, not the boot decompressor in
`arch/arm/boot/compressed`.

The kernel is pinned to OpenIPC's `sigmastar-infinity6c` branch, which already
carries seven fixes above the BSP import — lzma uImage, spinand probe-on-type,
mtdparts identifier, watchdog magic close, python3 scripts, i2c warnings,
regulatory defaults. Anything landing here should be something that branch does
not already have.
