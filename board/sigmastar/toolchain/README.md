# Rebuilding the SigmaStar ARM toolchain

The board's toolchain is published as a release asset and consumed by the
camera defconfig through `BR2_TOOLCHAIN_EXTERNAL_URL`. This directory is the
recipe that produces it, so the asset is reproducible rather than a binary
nobody can rebuild.

## What it is

The three versions that must not drift, read back from the toolchain the board
currently builds with:

```
arm-thingino-linux-gnueabihf-gcc.br_real (Buildroot 2026.05-610-g9bc585a804) 15.3.0
GNU ld (GNU Binutils) 2.44
GNU C Library (Buildroot) stable release version 2.43.
```

The Buildroot version in the first line is the pinned `buildroot/` submodule,
not a separate checkout. That is deliberate: gcc 15.3.0 and binutils 2.44 are
the versions `configs/github/toolchain_*_gcc15_defconfig` already selects for
every Ingenic toolchain, so matching them is what lets this producer run in
upstream's own toolchain workflow rather than by hand.

## Building

```sh
cp board/sigmastar/toolchain/thingino_infinity6e_glibc_gcc15_defconfig \
   buildroot/configs/
cd buildroot
make thingino_infinity6e_glibc_gcc15_defconfig
make && make sdk
```

Output is `output/images/arm-thingino-linux-gnueabihf_sdk-buildroot.tar.gz`.
Rename it to the convention the `ext-*.fragment` URLs use — the release tag
names the build host, the filename names the target — and upload it:

```sh
mv output/images/arm-thingino-linux-gnueabihf_sdk-buildroot.tar.gz \
   thingino-toolchain-x86_64_infinity6e_glibc_gcc15-linux-arm.tar.gz
gh release upload toolchain-x86_64 thingino-toolchain-*.tar.gz --clobber
```

## Checking a build

```sh
./output/host/bin/arm-thingino-linux-gnueabihf-gcc --version   # 15.3.0
./output/host/bin/arm-thingino-linux-gnueabihf-ld  --version   # 2.44
strings output/host/*/sysroot/lib/libc.so.6 | grep 'GNU C Library'  # 2.43
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
and filters on `gcc15`, so a producer placed in that directory is built and
published with no workflow change. Two things are still needed first:

- this defconfig gains the wrapper symbols the Ingenic producers carry —
  `BR2_GLOBAL_PATCH_DIR`, `BR2_THINGINO_TOOLCHAIN_BUILD`, and the rest;
- the workflow's rename and upload steps stop hardcoding `mipsel`. It locates
  the SDK with `-name "mipsel-thingino-linux-*_sdk-buildroot.tar.gz"` and names
  the asset `...-linux-mipsel.tar.gz`, neither of which matches an ARM build.
