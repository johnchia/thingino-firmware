################################################################################
#
# sigmastar-uboot
#
# U-Boot for SigmaStar Infinity6-family SoCs, from OpenIPC's fork of the vendor
# tree. Builds a NOR boot image into images/ and installs nothing to the target.
#
# The artifact is not u-boot.bin. A SigmaStar NOR boot image is a container the
# mask ROM reads, assembled by make_boot_spinor.sh from four pieces at fixed
# offsets in the first 128KB -- IPL at 0, MXP_SF at 60k, IPL_CUST at 64k -- with
# the compressed U-Boot appended at 128k. The first three are vendor blobs
# carried in the tree; only the tail is built here. Flashing u-boot.bin instead
# produces a board that does not boot and cannot be recovered over the network.
#
# The SoC model reaches the compiler as a define rather than a defconfig: one
# defconfig covers the whole family and PRODUCT_SOC selects the DDR timing and
# pinmux within it. Both values come from the camera defconfig, so a second
# SigmaStar board needs no change here.
#
# Building this does not flash it, and nothing in the image references it. The
# boot partition is the only one on this board where a bad write cannot be
# undone in software.
#
################################################################################

SIGMASTAR_UBOOT_VERSION = bf77aff5d44f34d14b89b3f4014aa8dda9834794
SIGMASTAR_UBOOT_SITE = https://github.com/openipc/u-boot-sigmastar
SIGMASTAR_UBOOT_SITE_METHOD = git
SIGMASTAR_UBOOT_LICENSE = GPL-2.0+ (u-boot), PROPRIETARY (ipl/)
SIGMASTAR_UBOOT_LICENSE_FILES = Licenses/gpl-2.0.txt
SIGMASTAR_UBOOT_REDISTRIBUTE = NO
SIGMASTAR_UBOOT_INSTALL_IMAGES = YES
SIGMASTAR_UBOOT_INSTALL_TARGET = NO
SIGMASTAR_UBOOT_INSTALL_STAGING = NO

# From thingino.mk's exported environment, not from .config. The camera
# defconfig's BR2_SIGMASTAR_SOC_MODEL and _SOC_FAMILY are read by the outer
# make and are declared in no Kconfig, so Kconfig drops them and they are empty
# inside a package. Both are checked below because an empty one here builds a
# target named "_defconfig" and fails several steps later with nothing naming
# the cause.
SIGMASTAR_UBOOT_SOC_MODEL = $(SOC_MODEL)
SIGMASTAR_UBOOT_SOC_FAMILY = $(SOC_FAMILY)

ifeq ($(SIGMASTAR_UBOOT_SOC_MODEL),)
$(error sigmastar-uboot: SOC_MODEL is empty -- expected it exported by thingino.mk)
endif
ifeq ($(SIGMASTAR_UBOOT_SOC_FAMILY),)
$(error sigmastar-uboot: SOC_FAMILY is empty -- expected it exported by thingino.mk)
endif

# For mkenvimage, which the post-image script uses to build the environment
# image describing the partition table. host-uboot-tools installs it
# unconditionally. BR2_PACKAGE_HOST_UBOOT_TOOLS_ENVIMAGE is a different thing
# and not what is wanted here -- it asks Buildroot to generate an environment
# image from a static source file, which cannot express a table whose sizes
# come from the images this build produces.
#
# linux is a dependency for the recovery table below, not for the build. The
# kernel partition size is the one number that table cannot be correct without,
# and uImage is the only place it comes from.
SIGMASTAR_UBOOT_DEPENDENCIES = host-uboot-tools linux

SIGMASTAR_UBOOT_MAKE_ENV = ARCH=arm CROSS_COMPILE="$(TARGET_CROSS)"

define SIGMASTAR_UBOOT_CONFIGURE_CMDS
	$(SIGMASTAR_UBOOT_MAKE_ENV) $(MAKE1) -C $(@D) \
		$(SIGMASTAR_UBOOT_SOC_FAMILY)_defconfig
endef

# THE COMPILED-IN TABLE IS A RECOVERY TABLE, NOT A COPY OF THE REAL ONE.
#
# The real partition table lives in the environment, written by
# board/sigmastar/post-image.sh and flashed to mtd1. What is compiled in here
# is only ever read when that environment is gone -- a bad CRC, or an erase.
#
# It has to exist because losing the environment is a thing the firmware does to
# itself on request. The web UI's "Reset firmware" runs `firstboot -f`, and a
# 20-second hold of the physical button runs the same command; neither can pass
# `-e`, and firstboot erases /dev/mtd1 unless it is given one. On Ingenic that
# is harmless because the table is compiled into U-Boot and the environment is
# a convenience. On this board the environment was the only copy, so a factory
# reset left a bootloader describing the OEM's layout -- a 2048k kernel and a
# 5120k rootfs -- and the rootfs offset landed inside the kernel. panic=20 then
# turned that into a reboot loop recoverable only over serial.
#
# WHY RECOVERY AND NOT AN EXACT COPY
#
# An exact copy needs the rootfs partition size, which needs rootfs.squashfs,
# which does not exist yet: Buildroot assembles the root filesystem after every
# package has been built, and this is a package. Only the kernel can be
# measured here, and only because `linux` is a declared dependency above.
#
# Upstream's equivalent (THINGINO_PATCH_DEV_ENV in thingino-uboot.mk) writes the
# full table and guards on both images existing, so on a clean build the guard
# is false and the hook silently does nothing. It is a pre-build hook, so it
# does not re-run once the package is stamped either. Copying that would give
# this board a fallback that is usually stale -- which is the failure being
# fixed, reintroduced one level down.
#
# So the table compiled here claims only what this build can prove:
#
#   256k(boot),64k(env),<measured>k(kernel),-(rootfs)
#
# Four partitions, no `data`, no `all`. Every offset in it is exact, and it
# stays exact for any rootfs, because it makes no claim about where the rootfs
# ends. Booting on it gives a read-only system: /init cannot find a partition
# named `data`, calls die(), and its EXIT trap execs /sbin/init anyway (see
# overlay/init) -- so the board comes up on a serial console with a squashfs
# root instead of looping. Dropbear generates host keys into /etc and wlan0
# needs a wpa_supplicant.conf from the overlay, so expect no network. It is a
# recovery mode, and it is reached by re-flashing uenv.txt.
#
# CONFIG_BOOTCOMMAND ends with `saveenv`, so the first boot after an erase
# writes this recovery environment back to mtd1. That is deliberate on the
# vendor's part and useful here: the state is then explicit rather than a CRC
# failure repeating every boot.
#
# The arithmetic lives in a script rather than here because the string it has to
# emit contains backslash escapes that C, sed, the shell and make each claim.
# Building it inside a make recipe means four layers of quoting for one literal,
# and the failure mode of getting one wrong is a bootloader that looks fine and
# expands ${memlx} to nothing.
define SIGMASTAR_UBOOT_PATCH_ENV
	$(BR2_EXTERNAL_THINGINO_PATH)/board/sigmastar/uboot-recovery-table.sh \
		$(@D)/include/configs/sstar-common.h \
		$(BINARIES_DIR)/uImage \
		$(FLASH_SIZE_MB)
endef
SIGMASTAR_UBOOT_PRE_BUILD_HOOKS += SIGMASTAR_UBOOT_PATCH_ENV

define SIGMASTAR_UBOOT_BUILD_CMDS
	$(SIGMASTAR_UBOOT_MAKE_ENV) $(MAKE) -C $(@D) \
		KCFLAGS=-DPRODUCT_SOC=$(SIGMASTAR_UBOOT_SOC_MODEL)
	cd $(@D) && $(SHELL) make_boot_spinor.sh $(SIGMASTAR_UBOOT_SOC_FAMILY)
endef

define SIGMASTAR_UBOOT_INSTALL_IMAGES_CMDS
	$(INSTALL) -D -m 0644 $(@D)/BOOT.bin \
		$(BINARIES_DIR)/u-boot-$(SIGMASTAR_UBOOT_SOC_MODEL)-nor.bin
endef

$(eval $(generic-package))
