################################################################################
#
# sigmastar-sdk
#
# The kernel side of the SigmaStar vendor stack: prebuilt MI modules, sensor
# drivers built from source, and the tuning and firmware blobs the ISP and
# encoder read at runtime. Userspace lives in sigmastar-lib.
#
# The split follows thingino's Ingenic convention -- ingenic-lib is prebuilt
# userspace, ingenic-sdk is kernel-side and mixes prebuilt firmware archives
# with source compiled at build time. This does the same.
#
# One package per repository, deliberately: two packages pinning one repo means
# two clones and two hashes that can drift apart.
#
################################################################################

SIGMASTAR_SDK_SITE_METHOD = git
SIGMASTAR_SDK_SITE = https://github.com/johnchia/sigmastar-sdk
SIGMASTAR_SDK_SITE_BRANCH = drop-1230
SIGMASTAR_SDK_VERSION = bdfbbdd67407974372e1f07478b1edb2e22fce1a
SIGMASTAR_SDK_LICENSE = PROPRIETARY (mi modules), GPL-2.0 (sensor drivers)
SIGMASTAR_SDK_REDISTRIBUTE = NO

SIGMASTAR_SDK_DEPENDENCIES = linux

# Two kernel releases that must agree, from two different places.
#
# KREL is where the modules go on the target, and has to match what uname
# reports. LINUX_VERSION_PROBED gives that -- but it expands to a *backquoted
# shell command*, not a $(shell), so it only works inside a recipe. It must not
# reach anything make consumes directly: in MODULE_SUBDIRS the backticks never
# run and the embedded $(MAKE) leaks through as a path.
#
# SIGMASTAR_KREL is where the payload sits inside the repo, a property of the
# fetched tree. soc/sigmastar/<family>.mk states it.
#
# They are required to be equal: the vendor modules are prebuilt and insmod
# checks vermagic, which is why core-sigmastar.fragment pins the kernel. A
# mismatch fails loudly here, at a path that does not exist, rather than on the
# board.
#
# KERNEL_VERSION is deliberately NOT used for either. thingino.mk sets it to
# "4.9" for this vendor, which only names an output directory.
SIGMASTAR_SDK_KREL = $(LINUX_VERSION_PROBED)

# The repository is keyed by family first: every artifact below is built for one
# chip. Indexing without $(SOC_FAMILY) is what previously let an Infinity6B0
# build resolve Infinity6E's MI modules.
SIGMASTAR_SDK_FAMILY = $(@D)/$(SOC_FAMILY)

# Prebuilt vendor modules, keyed by the build they came from and not merely by
# kernel release. Across a single vendor release the <libc>/<gcc> trees are not
# one source built several ways: mi_sys.ko differs by 27-29 imported kernel
# symbols between them, differs in `depends=`, and the trees ship different
# module sets. vermagic is byte-identical across all of them and
# CONFIG_MODVERSIONS is off, so insmod accepts a foreign module and it fails
# later at symbol resolution, or misbehaves. Nothing at load time catches it,
# which is why the whole flavour is spelled out in the path.
#
# The components come from soc/sigmastar/<family>.mk, which is also where
# sigmastar-lib reads them: the two repositories hold halves of one vendor build
# and a single definition keeps their pins in step. See the repo's PROVENANCE.
SIGMASTAR_SDK_KMOD = $(SIGMASTAR_SDK_FAMILY)/kmod-$(SIGMASTAR_KREL)-$(SIGMASTAR_DROP)-$(SIGMASTAR_LIBC)-$(SIGMASTAR_GCC)

# The runtime blobs are keyed by drop as well as by family. All three are read
# by the drop that ships them and two are validated: the encoder refuses a
# chagall.bin from another drop outright, and the ISP refuses a sensor-iq bin
# whose major version does not match -- then falls back to generic tuning and
# comes up with visibly wrong colour rather than failing. See the repo's
# PROVENANCE.
SIGMASTAR_SDK_BLOB = $(SIGMASTAR_SDK_FAMILY)/$(1)/$(SIGMASTAR_DROP)

# Sensor drivers. Source-built for every drop whose headers are available, which
# is why this is family-keyed rather than drop-keyed -- see the repo's
# PROVENANCE for the one case where it is not enough.
#
# Every driver the family has is built and installed. Selecting one is a runtime
# decision made by load_sigmastar from the U-Boot `sensor` variable; narrowing
# the build to the sensor on the development board is exactly what this must not
# do. INSTALL_MOD_DIR puts them in /lib/modules/<release>/sigmastar, alongside
# the prebuilt vendor modules and where load_sigmastar looks.
#
# A drop that sets SIGMASTAR_SENSOR := prebuilt ships its own drivers in the
# kmod directory instead, and the source build is skipped entirely: the two
# install to the same names, so building both would overwrite the vendor's copy
# with one compiled against the wrong ms_cus_sensor layout -- which fails
# silently, at MI_SNR_QueryResCount, rather than at load.
ifneq ($(SIGMASTAR_SENSOR),prebuilt)
SIGMASTAR_SDK_MODULE_SUBDIRS = $(SOC_FAMILY)/sensor-src
SIGMASTAR_SDK_MODULE_MAKE_OPTS = \
	SENSOR_VERSION=$(SOC_FAMILY) \
	INSTALL_MOD_DIR=$(SOC_VENDOR) \
	KSRC=$(LINUX_DIR)
endif

# Board-specific tuning, path relative to the BR2_EXTERNAL root as ingenic-sdk
# reads it. Left unset the stock blob is installed.
ifneq ($(call qstrip,$(BR2_SENSOR_1_IQ_FILE)),)
SIGMASTAR_SDK_IQ_OVERRIDE = \
	$(BR2_EXTERNAL_THINGINO_PATH)/$(call qstrip,$(BR2_SENSOR_1_IQ_FILE))
endif

define SIGMASTAR_SDK_INSTALL_TARGET_CMDS
	$(INSTALL) -m 755 -d $(TARGET_DIR)/lib/modules/$(SIGMASTAR_SDK_KREL)/sigmastar
	$(INSTALL) -m 644 -t $(TARGET_DIR)/lib/modules/$(SIGMASTAR_SDK_KREL)/sigmastar \
		$(SIGMASTAR_SDK_KMOD)/*

	# /etc/firmware is what MI_ISP_GetIspRoot reports on this board, so CUS3A
	# reads iqfile0.bin from here at AE init. chagall.bin is VENC firmware and
	# only shares the directory.
	#
	# Both are per drop as well as per chip -- the encoder rejects a chagall.bin
	# from another drop by version.
	$(INSTALL) -m 755 -d $(TARGET_DIR)/etc/firmware
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc/firmware \
		$(call SIGMASTAR_SDK_BLOB,iqfile)/*
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc/firmware \
		$(call SIGMASTAR_SDK_BLOB,venc_fw)/*

	# mi.ko reads this at insmod via g_ModParamPath, whose compiled-in default
	# is a /config path thingino does not have. Only drops that ship one have
	# the directory; 0907 passes the same settings as module parameters.
	if [ -d "$(call SIGMASTAR_SDK_BLOB,modparam)" ]; then \
		$(INSTALL) -m 644 -t $(TARGET_DIR)/etc/firmware \
			$(call SIGMASTAR_SDK_BLOB,modparam)/*; \
	fi

	# One sensor per target, in the shape ingenic-sdk installs: the blob under
	# /usr/share/sensor, an /etc/sensor symlink, and a model file.
	#
	# The plain <sensor>.bin name is required. raptor resolves the tuning by
	# the lowercased driver-module name, so ingenic-sdk's -$(SOC_FAMILY) suffix
	# would not be found and the board would come up on the generic tuning with
	# visibly wrong colour.
	#
	# All the family's bins stay in the repo -- another target selects its own.
	if [ -n "$(SENSOR_1_MODEL)" ]; then \
		$(INSTALL) -m 755 -d $(TARGET_DIR)/usr/share/sensor; \
		ln -sf /usr/share/sensor $(TARGET_DIR)/etc/sensor; \
		if [ -n "$(SIGMASTAR_SDK_IQ_OVERRIDE)" ] && \
		   [ -f "$(SIGMASTAR_SDK_IQ_OVERRIDE)" ]; then \
			$(INSTALL) -D -m 644 $(SIGMASTAR_SDK_IQ_OVERRIDE) \
				$(TARGET_DIR)/usr/share/sensor/$(SENSOR_1_MODEL).bin; \
		elif [ -f "$(call SIGMASTAR_SDK_BLOB,sensor-iq)/$(SENSOR_1_MODEL).bin" ]; then \
			$(INSTALL) -D -m 644 \
				$(call SIGMASTAR_SDK_BLOB,sensor-iq)/$(SENSOR_1_MODEL).bin \
				$(TARGET_DIR)/usr/share/sensor/$(SENSOR_1_MODEL).bin; \
		else \
			echo "WARNING: sigmastar-sdk: no IQ tuning for $(SENSOR_1_MODEL) on"\
			     "$(SOC_FAMILY) drop $(SIGMASTAR_DROP). The sensor is driven, but"\
			     "the ISP falls back to generic tuning and colour will be visibly"\
			     "wrong. Supply one via BR2_SENSOR_1_IQ_FILE, or add"\
			     "$(SOC_FAMILY)/sensor-iq/$(SIGMASTAR_DROP)/$(SENSOR_1_MODEL).bin"\
			     "to sigmastar-sdk."; \
		fi; \
		echo $(SENSOR_1_MODEL) > $(TARGET_DIR)/usr/share/sensor/model; \
	fi

	$(INSTALL) -m 755 -d $(TARGET_DIR)/usr/bin
	$(INSTALL) -m 755 -t $(TARGET_DIR)/usr/bin \
		$(SIGMASTAR_SDK_PKGDIR)/files/script/*

	$(INSTALL) -D -m 755 $(SIGMASTAR_SDK_PKGDIR)/files/S20sigmastar \
		$(TARGET_DIR)/etc/init.d/S20sigmastar
endef

# Only when there is something to compile. kernel-module with no MODULE_SUBDIRS
# builds $(@D) itself, and the repository root has no Kbuild.
ifneq ($(SIGMASTAR_SENSOR),prebuilt)
$(eval $(kernel-module))
endif
$(eval $(generic-package))
