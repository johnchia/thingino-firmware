THINGINO_RAPTOR_HAL_VERSION = 7e62abede02b41ecfb097303b3103b1a5d8740a4
THINGINO_RAPTOR_HAL_SITE = https://github.com/gtxaspec/raptor-hal
THINGINO_RAPTOR_HAL_SITE_METHOD = git
THINGINO_RAPTOR_HAL_GIT_SUBMODULES = YES
THINGINO_RAPTOR_HAL_INSTALL_STAGING = YES
THINGINO_RAPTOR_HAL_INSTALL_TARGET = NO

# SigmaStar builds no Ingenic headers and links no vendor library: raptor-hal's
# Makefile leaves SDK_INCLUDE empty for that vendor and the MI ABI declarations
# plus their dlopen thunks live in src/star/ inside the tree. The
# INGENIC_HEADERS argument below is inert there for the same reason, so it is
# left alone rather than made conditional.
ifneq ($(BR2_SOC_SIGMASTAR),y)
THINGINO_RAPTOR_HAL_DEPENDENCIES = ingenic-lib
endif

THINGINO_RAPTOR_HAL_PLATFORM = $(shell echo $(SOC_FAMILY) | tr a-z A-Z)

define THINGINO_RAPTOR_HAL_BUILD_CMDS
	$(MAKE) -C $(@D) \
		PLATFORM=$(THINGINO_RAPTOR_HAL_PLATFORM) \
		CROSS_COMPILE=$(TARGET_CROSS) \
		INGENIC_HEADERS=$(@D)/ingenic-headers \
		$(if $(BR2_PACKAGE_THINGINO_RAPTOR_IVS_DETECT),\
			CXX=$(TARGET_CROSS)g++ \
			JZDL_INCLUDE=$(@D)/ingenic-headers/Txx/jzdl,) \
		$(if $(BR2_PACKAGE_THINGINO_RAPTOR_IVS_PERSONDET),PERSONDET=1,) \
		$(if $(BR2_PACKAGE_THINGINO_RAPTOR_DEBUG),DEBUG=1,)
endef

define THINGINO_RAPTOR_HAL_INSTALL_STAGING_CMDS
	$(INSTALL) -D -m 0644 $(@D)/libraptor_hal_video.a \
		$(STAGING_DIR)/usr/lib/libraptor_hal_video.a
	$(INSTALL) -D -m 0644 $(@D)/libraptor_hal_audio.a \
		$(STAGING_DIR)/usr/lib/libraptor_hal_audio.a
	$(INSTALL) -D -m 0644 $(@D)/include/raptor_hal.h \
		$(STAGING_DIR)/usr/include/raptor_hal.h
endef

# See the matching block in thingino-raptor.mk for why the SigmaStar source
# override lives at the bottom of the file rather than beside the pinned hash.
ifeq ($(BR2_SOC_SIGMASTAR),y)
THINGINO_RAPTOR_HAL_VERSION = 86e7cb487ff6102395a0bebf49de117841f2e85a
THINGINO_RAPTOR_HAL_SITE = https://github.com/johnchia/raptor-hal
endif

$(eval $(generic-package))
