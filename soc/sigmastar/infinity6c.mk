# SigmaStar Infinity6C family. Included for every board; the filter
# below is what limits it to this family's models.
ifneq ($(filter $(SOC_MODEL),ssc377de),)

SOC_FAMILY := infinity6c
# Selects a board/kernel subdirectory. For Ingenic that is an ISA shared by
# several families; here the family is the finest split that exists, so the two
# coincide.
SOC_ARCH   := infinity6c

# ARMv7-A, like the other two families, and this is measured rather than
# inferred from the part number. OpenIPC's ssc377de defconfig says
# BR2_cortex_a35, which disagrees with every artifact that has to run here:
#
#   vendor mi_sys.ko      Tag_CPU_name "7-A"  Tag_CPU_arch v7  FP VFPv2
#   vendor libmi_sys.so   Tag_CPU_name "7-A"  Tag_CPU_arch v7  FP VFPv4
#                         Tag_Advanced_SIMD_arch NEONv1 with Fused-MAC
#   OpenIPC's own mi.ko   Tag_CPU_name "7-A"  Tag_CPU_arch v7
#   kernel config         CONFIG_CPU_V7=y, VFPv3, NEON -- no CPU_V8, in both
#                         OpenIPC's tree and the vendor SDK's own
#   module vermagic       "5.10.61 preempt mod_unload ARMv7 thumb2 p2v8"
#
# The libraries' VFPv4 plus NEONv1-with-Fused-MAC is exactly cortex-a7 with
# neon-vfpv4, which is what we link against, so matching it is not a
# conservative choice but the correct one.
#
# Building as cortex_a35 makes GCC report __ARM_ARCH 8, which is enough for
# mbedTLS to select its ARMv8 AES path and then fail to inline vaesdq_u8 --
# an ARMv8 instruction this stack never uses.
SOC_CPU    := cortex_a7
SOC_FPU    := NEON_VFPV4

# 128MB is what SSC377DE carries. In-package, so a board cannot choose it.
SOC_RAM_MB := 128

# No SOC_UBOOT_*: this vendor keeps its bootloader on the chip and does not use
# BR2_TARGET_UBOOT.

# 5.10, not the 4.9 the other two families run. thingino.mk sets 4.9 for this
# vendor before including these files, so this overrides it. It names an output
# directory and the board/sigmastar/<family>/kernel/<ver>/ subdirectory.
KERNEL_VERSION := 5.10

# OpenIPC's infinity6c branch, pinned. Unlike the other two families this is
# vanilla plus a BSP patch rather than a vendor tree: b335d21 applies
# 0000-infinity6c-kernel-5.10.61.patch directly on Linux 5.10.61, with seven
# OpenIPC commits after it. See sigmastar-sdk's infinity6c/PROVENANCE -- that
# BSP is NOT the one release_0907's modules were built against, and the pairing
# is argued there rather than assumed.
KERNEL_SITE := https://github.com/johnchia/linux
KERNEL_HASH := d17f67f1f90259dab41b6b6abb28fb64348d83e9

# The vendor build the prebuilt halves come from -- see infinity6e.mk for why
# this lives here rather than in either package.
#
# glibc rather than uclibc because the toolchain is glibc and these libraries
# are loaded into our processes. Both variants exist in both repositories; the
# kernel modules barely differ between them, the userspace libraries genuinely
# do.
SIGMASTAR_DROP := 0907
SIGMASTAR_LIBC := glibc
SIGMASTAR_GCC  := 11.1.0
SIGMASTAR_KREL := 5.10.61

endif
