################################################################################
#
# ipctool
#
# Ported from OpenIPC. Two differences from their version:
#
#   - Pinned rather than HEAD, for the same reason as sigmastar-osdrv-sensors:
#     an unpinned package makes two builds of the same commit of this tree
#     ship different binaries.
#   - Target only. OpenIPC also installs libipchw.a to staging; nothing in
#     this tree links it, and an unused staging artifact is one more thing
#     to keep working. Add it back when something needs it.
#
# Only `ipcinfo` is installed. The `ipctool` binary itself is an interactive
# dumper that would earn its space on a bench image, not on this one.
#
################################################################################

IPCTOOL_VERSION = a12cf0045398d56fe5de703af7401e2b5661098a
IPCTOOL_SITE = $(call github,openipc,ipctool,$(IPCTOOL_VERSION))
IPCTOOL_LICENSE = MIT
IPCTOOL_LICENSE_FILES = LICENSE

# SKIP_VERSION stops the build shelling out to git for a version string; the
# Buildroot source tree has no .git, so without it the build either fails or
# bakes in "unknown" depending on the cmake version.
IPCTOOL_CONF_OPTS += -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release -DSKIP_VERSION=ON

define IPCTOOL_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/ipcinfo $(TARGET_DIR)/usr/bin/ipcinfo
endef

$(eval $(cmake-package))
