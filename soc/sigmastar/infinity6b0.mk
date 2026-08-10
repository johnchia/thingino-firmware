# SigmaStar Infinity6B0 family. Included for every board; the filter
# below is what limits it to this family's models.
ifneq ($(filter $(SOC_MODEL),ssc333),)

SOC_FAMILY := infinity6b0
# Selects a board/kernel subdirectory. For Ingenic that is an ISA shared by
# several families; here the family is the finest split that exists, so the two
# coincide. Infinity6B0 and Infinity6E are both Cortex-A7 but carry separate
# vendor BSPs on separate kernel branches, so they cannot share this level.
SOC_ARCH   := infinity6b0

# The DRAM is inside the SoC package, so a board cannot choose it. The 64MB
# tier is what SSC333 ships; see the mma_heap carveout in package/sigmastar-uboot.
SOC_RAM_MB := 64

# No SOC_UBOOT_*: this vendor keeps its bootloader on the chip and does not use
# BR2_TARGET_UBOOT.

# This family's own kernel tree. Not the Infinity6E branch: same Cortex-A7 and
# same 4.9 line, but a separate vendor BSP, and building one against the other's
# headers fails quietly rather than loudly.
KERNEL_SITE := https://github.com/johnchia/linux
KERNEL_HASH := 289323e3301024554bb49652cd92960df459fe14

# Same 4.9.84 the vendor built its Infinity6E modules against, confirmed from
# this branch's own build rather than assumed from the 4.9 branch name.
SIGMASTAR_KREL := 4.9.84

# No SIGMASTAR_DROP/LIBC/GCC: this family has no vendor blobs yet. Neither
# sigmastar-sdk nor sigmastar-lib carries an infinity6b0 payload, so a build
# fails on an absent path -- which is the intent. Infinity6E's modules are built
# for a different chip and must not stand in; set these only alongside real
# Infinity6B0 payload in both repositories.

endif
