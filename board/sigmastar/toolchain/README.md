# Rebuilding the SigmaStar ARM toolchain

The board's toolchain is published as a release asset and consumed by the
camera defconfig through `BR2_TOOLCHAIN_EXTERNAL_URL`. This directory is the
recipe that produces it, so the asset is reproducible rather than a binary
nobody can rebuild.

## Why a separate Buildroot

`thingino_infinity6e_glibc_gcc13_defconfig` is built against **Buildroot
2024.02.10**, not the `buildroot/` submodule.

The board is validated on GCC 13.3.0 and binutils 2.40. The pinned submodule
offers neither — its oldest are GCC 14 and binutils 2.44 — and 2024.02.10 is
the last release carrying both. That version pin is not incidental: a 4.9
kernel under a newer compiler fails as rare-path miscompilation rather than a
build error, so "it compiles" is not evidence. Changing the compiler is its own
project with its own soak test on hardware.

Do **not** move this into `configs/github/`. Upstream's toolchain workflow globs
that directory and builds against the submodule, which would silently produce a
GCC 15 toolchain under a filename claiming GCC 13.

## Building

```sh
git clone --branch 2024.02.10 --depth 1 https://github.com/buildroot/buildroot br2024
cp board/sigmastar/toolchain/thingino_infinity6e_glibc_gcc13_defconfig \
   br2024/configs/
cd br2024
make thingino_infinity6e_glibc_gcc13_defconfig
make && make sdk
```

Output is `output/images/arm-thingino-linux-gnueabihf_sdk-buildroot.tar.gz`.
Rename it to the convention the `ext-*.fragment` URLs use — the release tag
names the build host, the filename names the target — and upload it:

```sh
mv output/images/arm-thingino-linux-gnueabihf_sdk-buildroot.tar.gz \
   thingino-toolchain-x86_64_infinity6e_glibc_gcc13-linux-arm.tar.gz
gh release upload toolchain-x86_64 thingino-toolchain-*.tar.gz --clobber
```

## Checking a build

The three versions that must not drift, and the tuple the camera defconfig's
`BR2_TOOLCHAIN_EXTERNAL_CUSTOM_PREFIX` has to match:

```sh
./output/host/bin/arm-thingino-linux-gnueabihf-gcc --version   # 13.3.0
./output/host/bin/arm-thingino-linux-gnueabihf-ld  --version   # 2.40
strings output/host/*/sysroot/lib/libc.so.6 | grep 'GNU C Library'  # 2.38
```

The sysroot must stay **bare** — glibc, libstdc++, libgcc and kernel headers,
nothing else. OpenIPC's toolchain, which this replaced, bundled prebuilt
mbedTLS, curl, json-c, libevent, libubox, opus, ogg, yaml and zlib into its
sysroot. Buildroot's per-package rsync replays the toolchain *after* the package
directories, so those overwrote freshly built copies and the failure surfaced in
a different package as an undefined symbol that did exist in the version that
was built. A stock Buildroot toolchain has none of them, which is why no pruning
step is needed here.

## Note on OpenIPC's overlay

OpenIPC build their equivalent from the same Buildroot release but overlay
`general/package/gcc`. That overlay is a single `Config.in.host` carrying no
patches: it flips the Kconfig default from GCC 12 to 13 and adds a GCC 8.x
`LEGACY` option for their Hisilicon and Goke targets. Selecting
`BR2_GCC_VERSION_13_X` explicitly gets the same compiler from a stock tree, so
none of it is reproduced here.
