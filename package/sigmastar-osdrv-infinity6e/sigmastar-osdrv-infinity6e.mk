################################################################################
#
# sigmastar-osdrv-infinity6e
#
# The SigmaStar vendor MI bundle, ported from OpenIPC's package of the same
# name. Prebuilt binaries, so there is nothing to compile -- the package is a
# fetch plus an install step.
#
# The binaries are fetched from johnchia/sigmastar-osdrv rather than checked in
# here, following ingenic-lib. 6.9 MB of PROPRIETARY payload in this tree made
# REDISTRIBUTE = NO untrue: git redistributes it on every clone, which is the
# thing that flag exists to prevent.
#
# Pinned by hash, never a branch -- a branch would let the payload change under
# a build with nothing in the image recording which one was used.
#
# Fetched payload, one directory per family ($(@D)/$(SOC_FAMILY)):
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
#
# Kept in this package ($(PKGDIR)/files): load_sigmastar, which does the insmod
# ordering, zoom.sh, and the S20sigmastar init script. They are ours and are
# text, so they belong where they can be reviewed and diffed.
#
################################################################################

SIGMASTAR_OSDRV_INFINITY6E_SITE_METHOD = git
SIGMASTAR_OSDRV_INFINITY6E_SITE = https://github.com/johnchia/sigmastar-osdrv
SIGMASTAR_OSDRV_INFINITY6E_SITE_BRANCH = main
SIGMASTAR_OSDRV_INFINITY6E_VERSION = f4c94a041796b1d07aeb730702f445c8ba171d41
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

# The fetched tree holds one directory per Infinity family, so adding a family
# to the blob repo needs no change here. Config.sigmastar.in only selects this
# package when BR2_SOC_FAMILY is "infinity6e", so the two always agree.
SIGMASTAR_OSDRV_INFINITY6E_BLOBS = $(@D)/$(SOC_FAMILY)

# Board-specific tuning, path relative to the BR2_EXTERNAL root as ingenic-sdk
# reads it. Left unset the stock blob is installed.
ifneq ($(call qstrip,$(BR2_SENSOR_1_IQ_FILE)),)
SIGMASTAR_OSDRV_INFINITY6E_IQ_OVERRIDE = \
	$(BR2_EXTERNAL_THINGINO_PATH)/$(call qstrip,$(BR2_SENSOR_1_IQ_FILE))
endif

define SIGMASTAR_OSDRV_INFINITY6E_INSTALL_TARGET_CMDS
	$(INSTALL) -m 755 -d $(TARGET_DIR)/lib/modules/$(SIGMASTAR_OSDRV_INFINITY6E_KREL)/sigmastar
	$(INSTALL) -m 644 -t $(TARGET_DIR)/lib/modules/$(SIGMASTAR_OSDRV_INFINITY6E_KREL)/sigmastar \
		$(SIGMASTAR_OSDRV_INFINITY6E_BLOBS)/kmod/*

	$(INSTALL) -m 755 -d $(TARGET_DIR)/usr/lib
	$(INSTALL) -m 644 -t $(TARGET_DIR)/usr/lib \
		$(SIGMASTAR_OSDRV_INFINITY6E_BLOBS)/lib/*

	$(INSTALL) -m 755 -d $(TARGET_DIR)/etc/firmware
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc/firmware \
		$(SIGMASTAR_OSDRV_INFINITY6E_BLOBS)/sensor/firmware/*

	# One sensor per target, in the shape ingenic-sdk installs: the blob under
	# /usr/share/sensor, an /etc/sensor symlink, and a model file.
	#
	# The plain <sensor>.bin name is required. raptor resolves the tuning by
	# the lowercased driver-module name, so ingenic-sdk's -$(SOC_FAMILY) suffix
	# would not be found and the board would come up on the generic tuning with
	# visibly wrong colour.
	#
	# All six blobs stay checked in -- another SSC30KQ target selects its own.
	if [ -n "$(SENSOR_1_MODEL)" ]; then \
		$(INSTALL) -m 755 -d $(TARGET_DIR)/usr/share/sensor; \
		ln -sf /usr/share/sensor $(TARGET_DIR)/etc/sensor; \
		if [ -n "$(SIGMASTAR_OSDRV_INFINITY6E_IQ_OVERRIDE)" ] && \
		   [ -f "$(SIGMASTAR_OSDRV_INFINITY6E_IQ_OVERRIDE)" ]; then \
			$(INSTALL) -D -m 644 $(SIGMASTAR_OSDRV_INFINITY6E_IQ_OVERRIDE) \
				$(TARGET_DIR)/usr/share/sensor/$(SENSOR_1_MODEL).bin; \
		else \
			$(INSTALL) -D -m 644 \
				$(SIGMASTAR_OSDRV_INFINITY6E_BLOBS)/sensor/configs/$(SENSOR_1_MODEL).bin \
				$(TARGET_DIR)/usr/share/sensor/$(SENSOR_1_MODEL).bin; \
		fi; \
		echo $(SENSOR_1_MODEL) > $(TARGET_DIR)/usr/share/sensor/model; \
	fi

	$(INSTALL) -m 755 -d $(TARGET_DIR)/usr/bin
	$(INSTALL) -m 755 -t $(TARGET_DIR)/usr/bin \
		$(SIGMASTAR_OSDRV_INFINITY6E_PKGDIR)/files/script/*

	$(INSTALL) -D -m 755 $(SIGMASTAR_OSDRV_INFINITY6E_PKGDIR)/files/S20sigmastar \
		$(TARGET_DIR)/etc/init.d/S20sigmastar
endef

$(eval $(generic-package))
