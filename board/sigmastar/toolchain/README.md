# Rebuilding the SigmaStar ARM toolchain

The board's toolchain is published as a release asset and consumed by the
camera defconfig through `BR2_TOOLCHAIN_EXTERNAL_URL`. This directory is the
recipe that produces it, so the asset is reproducible rather than a binary
nobody can rebuild.

## What it is

The three versions that must not drift, read back from the toolchain the board
currently builds with:

```
arm-thingino-linux-gnueabihf-gcc.br_real (Buildroot 2026.05-610-g9bc585a804) 16.1.0
GNU ld (GNU Binutils) 2.45.1
GNU C Library (Buildroot) stable release version 2.43.
```

glibc did not move with the compiler — the same submodule supplies it, so the
prebuilt vendor `.so` the Raptor HAL dlopens still see 2.43.

The Buildroot version in the first line is the pinned `buildroot/` submodule,
not a separate checkout. That is deliberate: gcc 16.1.0 and binutils 2.45.1 are
the versions `configs/github/toolchain_*_gcc16_defconfig` already selects for
every Ingenic toolchain, so matching them is what lets this producer run in
upstream's own toolchain workflow rather than by hand.

## Building

The producer lives at `configs/github/toolchain_infinity6e_glibc_gcc16_defconfig`,
alongside the Ingenic ones, which is what puts it in the `toolchain-x86_64`
matrix. Build it the way the workflow does:

```sh
BOARD=toolchain_infinity6e_glibc_gcc16 GROUP=github make sdk
```

`GROUP=github` points `CAMERA_SUBDIR` at `configs/github`, and a defconfig with
no `FRAGMENTS` puts the build in `RAW_DEFCONFIG_MODE` — the defconfig becomes
the `.config` directly, with no toolchain or SoC fragment layered on.

Output is
`output/<branch>/toolchain_infinity6e_glibc_gcc16-*/images/arm-thingino-linux-gnueabihf_sdk-buildroot.tar.gz`.
The workflow renames it to the convention the `ext-*.fragment` URLs use — the
release tag names the build host, the filename names the target. By hand:

```sh
mv .../images/arm-thingino-linux-gnueabihf_sdk-buildroot.tar.gz \
   thingino-toolchain-x86_64_infinity6e_glibc_gcc16-linux-arm.tar.gz
gh release upload toolchain-x86_64 thingino-toolchain-*.tar.gz --clobber
```

## Checking a build

```sh
./output/host/bin/arm-thingino-linux-gnueabihf-gcc --version   # 16.1.0
./output/host/bin/arm-thingino-linux-gnueabihf-ld  --version   # 2.45.1
strings output/host/*/sysroot/lib/libc.so.6 | grep 'GNU C Library'  # 2.43
grep LINUX_VERSION_CODE output/host/*/sysroot/usr/include/linux/version.h  # 264532 = 4.9.84
```

The sysroot must stay **bare** — glibc, libstdc++, libgcc and kernel headers,
nothing else. The OpenIPC toolchain this replaced bundled prebuilt mbedTLS,
curl, json-c, libevent, libubox, opus, ogg, yaml and zlib into its sysroot.
Buildroot's per-package rsync replays the toolchain *after* the package
directories, so those overwrote freshly built copies and the failure surfaced in
a different package as an undefined symbol that did exist in the version that
was built. A stock Buildroot toolchain has none of them, which is why no pruning
step is needed here.

## Taking this upstream

`toolchain-x86_64.yaml` name-globs `configs/github/*defconfig` for its matrix
and filters on `gcc16`, so a producer placed in that directory is selected with
no workflow change. Both prerequisites are now met, and the workflow half is
the part that touches Ingenic:

- the defconfig carries the wrapper symbols the Ingenic producers carry.
  `BR2_THINGINO_DEV_PACKAGES` and `BR2_THINGINO_TOOLCHAIN_BUILD` are the
  load-bearing pair — the second lives inside `if BR2_THINGINO_DEV_PACKAGES`
  and is dropped without the first, and it is what clears the `default y` on
  System Packages and Streamer Packages. Without it the producer configures 273
  packages instead of 140 and tries to build raptor with an Ingenic HAL on ARM.
- the rename and upload steps derive the architecture instead of hardcoding
  `mipsel`: the SDK is located with `*-thingino-linux-*_sdk-buildroot.tar.gz`
  and `TC_ARCH` comes from the tuple's first field, so Ingenic still resolves
  to `mipsel` and nothing about their assets changes.

Still outstanding: the four checkouts pinned `ref: "master"`, now
`${{ github.ref_name }}`. On `schedule` that is the default branch, so upstream
behaviour is unchanged; it is what lets a fork dispatch the workflow from a
branch and have the matrix see that branch's `configs/github`.
