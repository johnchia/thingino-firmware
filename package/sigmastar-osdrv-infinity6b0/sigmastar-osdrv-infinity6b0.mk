################################################################################
#
# sigmastar-osdrv-infinity6b0
#
# The SigmaStar vendor MI bundle for Infinity6B0, ported from OpenIPC's package
# of the same name. Prebuilt binaries, so there is nothing to download and
# nothing to compile -- the whole package is an install step.
#
# Sibling to sigmastar-osdrv-infinity6e, not a generalisation of it. The two
# carry different vendor blobs built for different silicon, and the only thing
# they share is shape. Merging them would mean one package that installs the
# wrong .ko files if a variable is unset.
#
# It carries four kinds of payload, and they are not interchangeable:
#
#   kmod/    the mi_* and mhal kernel modules. Vendor-built against Linux
#            4.9.84; insmod verifies vermagic, so these only load on the
#            kernel core-sigmastar.fragment pins. This is the hard reason
#            the board cannot be moved to a newer kernel casually.
#   lib/     the MI userspace libraries. A streamer's HAL *dlopens* these
#            rather than linking them, so nothing here is a link-time
#            dependency -- but an image without them has daemons that start
#            and then fail at the first HAL call.
#   sensor/  per-sensor ISP tuning blobs (configs/) and the ISP firmware
#            plus IQ file (firmware/).
#   script/  load_sigmastar, which does the actual insmod ordering. This is
#            the vendor's Infinity6B0 script, which differs from the
#            Infinity6E one -- do not substitute.
#
################################################################################

SIGMASTAR_OSDRV_INFINITY6B0_VERSION = vendor
SIGMASTAR_OSDRV_INFINITY6B0_SOURCE =
SIGMASTAR_OSDRV_INFINITY6B0_LICENSE = PROPRIETARY
SIGMASTAR_OSDRV_INFINITY6B0_REDISTRIBUTE = NO

# The modules land in a kernel-release directory, so the kernel has to be
# configured before this package installs -- LINUX_VERSION_PROBED is a $(shell)
# that asks the kernel tree for its own release string.
#
# KERNEL_VERSION is deliberately NOT used here. thingino.mk sets it to "4.9"
# for this vendor, which only names an output directory; the modules need the
# full "4.9.84" that uname reports, and getting that wrong puts the files
# somewhere modprobe and load_sigmastar will not look.
SIGMASTAR_OSDRV_INFINITY6B0_DEPENDENCIES = linux
SIGMASTAR_OSDRV_INFINITY6B0_KREL = $(LINUX_VERSION_PROBED)

# Which sensor tuning blobs to install. Empty means all of them.
#
# The Infinity6E package has no such knob, and its comment explains why: one
# image per SoC, and baking in the dev unit's sensor silently breaks every
# other board. That reasoning has not changed -- what changed is the flash.
# The Infinity6E board is 16MB and the full set costs it nothing worth
# counting; the first Infinity6B0 board here is 8MB and cannot hold the vendor
# bundle, a kernel and a rootfs at full width.
#
# So this is a knob rather than a hardcoded name, it defaults to "all", and a
# board that narrows it has to say so in its own defconfig. That keeps the
# cost visible at the place the decision is made instead of buried here.
SIGMASTAR_OSDRV_INFINITY6B0_SENSORS = \
	$(call qstrip,$(BR2_PACKAGE_SIGMASTAR_OSDRV_INFINITY6B0_SENSORS))

ifeq ($(SIGMASTAR_OSDRV_INFINITY6B0_SENSORS),)
SIGMASTAR_OSDRV_INFINITY6B0_SENSOR_FILES = \
	$(SIGMASTAR_OSDRV_INFINITY6B0_PKGDIR)/files/sensor/configs/*.bin
else
SIGMASTAR_OSDRV_INFINITY6B0_SENSOR_FILES = $(foreach s, \
	$(SIGMASTAR_OSDRV_INFINITY6B0_SENSORS), \
	$(SIGMASTAR_OSDRV_INFINITY6B0_PKGDIR)/files/sensor/configs/$(s).bin)
endif

# A named sensor that does not exist would otherwise install nothing and fail
# at runtime on the board, which is the worst place to find out.
define SIGMASTAR_OSDRV_INFINITY6B0_CHECK_SENSORS
	$(foreach s,$(SIGMASTAR_OSDRV_INFINITY6B0_SENSORS), \
		test -f $(SIGMASTAR_OSDRV_INFINITY6B0_PKGDIR)/files/sensor/configs/$(s).bin || { \
			echo "sigmastar-osdrv-infinity6b0: no tuning blob for sensor '$(s)'" >&2; \
			exit 1; \
		};)
endef

define SIGMASTAR_OSDRV_INFINITY6B0_INSTALL_TARGET_CMDS
	$(SIGMASTAR_OSDRV_INFINITY6B0_CHECK_SENSORS)

	$(INSTALL) -m 755 -d $(TARGET_DIR)/lib/modules/$(SIGMASTAR_OSDRV_INFINITY6B0_KREL)/sigmastar
	$(INSTALL) -m 644 -t $(TARGET_DIR)/lib/modules/$(SIGMASTAR_OSDRV_INFINITY6B0_KREL)/sigmastar \
		$(SIGMASTAR_OSDRV_INFINITY6B0_PKGDIR)/files/kmod/*

	$(INSTALL) -m 755 -d $(TARGET_DIR)/usr/lib
	$(INSTALL) -m 644 -t $(TARGET_DIR)/usr/lib \
		$(SIGMASTAR_OSDRV_INFINITY6B0_PKGDIR)/files/lib/*

	$(INSTALL) -m 755 -d $(TARGET_DIR)/etc/firmware
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc/firmware \
		$(SIGMASTAR_OSDRV_INFINITY6B0_PKGDIR)/files/sensor/firmware/*

	$(INSTALL) -m 755 -d $(TARGET_DIR)/etc/sensors
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc/sensors \
		$(SIGMASTAR_OSDRV_INFINITY6B0_SENSOR_FILES)

	$(INSTALL) -m 755 -d $(TARGET_DIR)/usr/bin
	$(INSTALL) -m 755 -t $(TARGET_DIR)/usr/bin \
		$(SIGMASTAR_OSDRV_INFINITY6B0_PKGDIR)/files/script/*

	$(INSTALL) -D -m 755 $(SIGMASTAR_OSDRV_INFINITY6B0_PKGDIR)/files/S20sigmastar \
		$(TARGET_DIR)/etc/init.d/S20sigmastar
endef

$(eval $(generic-package))
