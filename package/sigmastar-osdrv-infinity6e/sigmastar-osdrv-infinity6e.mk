################################################################################
#
# sigmastar-osdrv-infinity6e
#
# The SigmaStar vendor MI bundle, ported from OpenIPC's package of the same
# name. Prebuilt binaries, so there is nothing to download and nothing to
# compile -- the whole package is an install step.
#
# It carries four kinds of payload, and they are not interchangeable:
#
#   kmod/    the mi_* and mhal kernel modules. Vendor-built against Linux
#            4.9.84; insmod verifies vermagic, so these only load on the
#            kernel core-sigmastar.fragment pins. This is the hard reason
#            the board cannot be moved to a newer kernel casually.
#   lib/     the MI userspace libraries. The Raptor HAL *dlopens* these
#            rather than linking them, so nothing here is a link-time
#            dependency -- but an image without them has daemons that start
#            and then fail at the first HAL call.
#   sensor/  per-sensor ISP tuning blobs (configs/) and the ISP firmware
#            plus IQ file (firmware/).
#   script/  load_sigmastar, which does the actual insmod ordering.
#
################################################################################

SIGMASTAR_OSDRV_INFINITY6E_VERSION = vendor
SIGMASTAR_OSDRV_INFINITY6E_SOURCE =
SIGMASTAR_OSDRV_INFINITY6E_LICENSE = PROPRIETARY
SIGMASTAR_OSDRV_INFINITY6E_REDISTRIBUTE = NO

# The modules land in a kernel-release directory, so the kernel has to be
# configured before this package installs -- LINUX_VERSION_PROBED is a $(shell)
# that asks the kernel tree for its own release string.
#
# KERNEL_VERSION is deliberately NOT used here. thingino.mk sets it to "4.9"
# for this vendor, which only names an output directory; the modules need the
# full "4.9.84" that uname reports, and getting that wrong puts the files
# somewhere modprobe and load_sigmastar will not look.
SIGMASTAR_OSDRV_INFINITY6E_DEPENDENCIES = linux
SIGMASTAR_OSDRV_INFINITY6E_KREL = $(LINUX_VERSION_PROBED)

define SIGMASTAR_OSDRV_INFINITY6E_INSTALL_TARGET_CMDS
	$(INSTALL) -m 755 -d $(TARGET_DIR)/lib/modules/$(SIGMASTAR_OSDRV_INFINITY6E_KREL)/sigmastar
	$(INSTALL) -m 644 -t $(TARGET_DIR)/lib/modules/$(SIGMASTAR_OSDRV_INFINITY6E_KREL)/sigmastar \
		$(SIGMASTAR_OSDRV_INFINITY6E_PKGDIR)/files/kmod/*

	$(INSTALL) -m 755 -d $(TARGET_DIR)/usr/lib
	$(INSTALL) -m 644 -t $(TARGET_DIR)/usr/lib \
		$(SIGMASTAR_OSDRV_INFINITY6E_PKGDIR)/files/lib/*

	$(INSTALL) -m 755 -d $(TARGET_DIR)/etc/firmware
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc/firmware \
		$(SIGMASTAR_OSDRV_INFINITY6E_PKGDIR)/files/sensor/firmware/*

	# ALL SIX sensor configs, always. OpenIPC's version of this package
	# narrows the glob with $(OPENIPC_SNS_MODEL) to install only the sensor
	# the developer's board happens to have. That knob is deliberately not
	# reproduced: this target is one image for any SSC30KQ board, and baking
	# in the dev unit's sensor would silently break every other board. The
	# whole directory is ~1MB raw and ~130KB once squashfs xz'es it, so
	# there is nothing to win by narrowing.
	$(INSTALL) -m 755 -d $(TARGET_DIR)/etc/sensors
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc/sensors \
		$(SIGMASTAR_OSDRV_INFINITY6E_PKGDIR)/files/sensor/configs/*.bin

	$(INSTALL) -m 755 -d $(TARGET_DIR)/usr/bin
	$(INSTALL) -m 755 -t $(TARGET_DIR)/usr/bin \
		$(SIGMASTAR_OSDRV_INFINITY6E_PKGDIR)/files/script/*

	$(INSTALL) -D -m 755 $(SIGMASTAR_OSDRV_INFINITY6E_PKGDIR)/files/S20sigmastar \
		$(TARGET_DIR)/etc/init.d/S20sigmastar
endef

$(eval $(generic-package))
