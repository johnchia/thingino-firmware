WIFI_RTL8188FU_SITE_METHOD = git
WIFI_RTL8188FU_SITE = https://github.com/gtxaspec/rtl8188ftv-wifi
WIFI_RTL8188FU_SITE_BRANCH = master
WIFI_RTL8188FU_VERSION = 6e3c1c2d244f5056d2a7ade3dbcf9daa3876fc06

WIFI_RTL8188FU_LICENSE = GPL-2.0
WIFI_RTL8188FU_LICENSE_FILES = COPYING

RTL8188FU_MODULE_NAME = 8188fu
RTL8188FU_MODULE_OPTS =

WIFI_RTL8188FU_MODULE_MAKE_OPTS = \
	CONFIG_RTL8188FU=m

# mac80211 is not used by this driver. Realtek's out-of-tree stack talks to
# cfg80211 directly and implements its own MLME and rate control, so nothing
# it registers ever reaches mac80211 or minstrel.
#
# Enabling it anyway costs roughly 500KB of kernel text. That is invisible on
# a board whose kernel partition is sized generously and fatal on one where
# the kernel and rootfs share an 8MB part, so the block is guarded rather
# than deleted: BR2_SOC_SIGMASTAR is the only vendor here with that problem
# today, and the guard evaluates true on every Ingenic build, leaving them
# byte-for-byte as they were.
#
# Worth offering upstream as a straight removal for every board rather than a
# guard -- but that is a claim about hardware nobody here can test, so it is
# scoped to the vendor that can.
ifeq ($(BR2_SOC_SIGMASTAR),y)
define WIFI_RTL8188FU_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_WLAN)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIRELESS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIRELESS_EXT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_CORE)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_PROC)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_PRIV)
	$(call KCONFIG_SET_OPT,CONFIG_CFG80211,y)
endef
else
define WIFI_RTL8188FU_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_WLAN)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIRELESS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIRELESS_EXT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_CORE)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_PROC)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_PRIV)
	$(call KCONFIG_SET_OPT,CONFIG_CFG80211,y)
	$(call KCONFIG_SET_OPT,CONFIG_MAC80211,y)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211_RC_MINSTREL)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211_RC_MINSTREL_HT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211_RC_DEFAULT_MINSTREL)
	$(call KCONFIG_SET_OPT,CONFIG_MAC80211_RC_DEFAULT,"minstrel_ht")
endef
endif

define WIFI_RTL8188FU_INSTALL_CONFIGS
	$(INSTALL) -D -m 0644 $(WIFI_RTL8188FU_PKGDIR)/files/PHY_REG_PG.txt \
		$(TARGET_DIR)/usr/lib/firmware/PHY_REG_PG.txt
endef

WIFI_RTL8188FU_POST_INSTALL_TARGET_HOOKS += WIFI_RTL8188FU_INSTALL_CONFIGS

$(eval $(kernel-module))
$(eval $(generic-package))
