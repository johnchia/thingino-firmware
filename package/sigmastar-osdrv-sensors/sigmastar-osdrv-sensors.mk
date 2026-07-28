################################################################################
#
# sigmastar-osdrv-sensors
#
# The sensor drivers, built from source against the configured kernel --
# unlike sigmastar-osdrv-infinity6e, which is prebuilt vendor binaries. That
# difference is why the two are separate packages rather than one: these have
# no vermagic problem because they are compiled here.
#
# Every driver the tree has for this family is built and installed. Selecting
# one is a runtime decision made by load_sigmastar from the U-Boot `sensor`
# variable, or from an `ipcinfo -s` probe when that is unset. Narrowing the
# build to the sensor on the development board is exactly the thing this
# target must not do.
#
################################################################################

# Pinned, not HEAD. OpenIPC's own package tracks HEAD, which means two builds
# a week apart can ship different drivers with nothing in the image to say so.
SIGMASTAR_OSDRV_SENSORS_VERSION = 8143e4da181d39d569572519595ce4b7e1a9a02d
SIGMASTAR_OSDRV_SENSORS_SITE = $(call github,openipc,sensors,$(SIGMASTAR_OSDRV_SENSORS_VERSION))
SIGMASTAR_OSDRV_SENSORS_LICENSE = GPL-2.0

# SOC_VENDOR/SOC_FAMILY are thingino.mk's, set from BR2_SIGMASTAR_SOC_MODEL in
# the camera defconfig -- the same two values OpenIPC spells OPENIPC_SOC_VENDOR
# and OPENIPC_SOC_FAMILY. INSTALL_MOD_DIR puts the .ko files in
# /lib/modules/<release>/sigmastar, which is where load_sigmastar looks and
# where the prebuilt vendor modules land too.
SIGMASTAR_OSDRV_SENSORS_MODULE_SUBDIRS = $(SOC_VENDOR)/$(SOC_FAMILY)
SIGMASTAR_OSDRV_SENSORS_MODULE_MAKE_OPTS = \
	SENSOR_VERSION=$(SOC_FAMILY) \
	INSTALL_MOD_DIR=$(SOC_VENDOR) \
	KSRC=$(LINUX_DIR)

$(eval $(kernel-module))
$(eval $(generic-package))
