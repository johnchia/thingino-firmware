################################################################################
#
# sigmastar-lib
#
# Prebuilt SigmaStar MI userspace libraries. Nothing to compile -- the package
# is a fetch plus an install step.
#
# Companion to sigmastar-sdk, which holds the kernel side. The split follows
# thingino's Ingenic convention: ingenic-lib is prebuilt userspace, ingenic-sdk
# is kernel-side.
#
# The Raptor HAL *dlopens* these rather than linking them, so nothing here is a
# link-time dependency -- but an image without them has daemons that start and
# then fail at the first HAL call.
#
################################################################################

SIGMASTAR_LIB_SITE_METHOD = git
SIGMASTAR_LIB_SITE = https://github.com/johnchia/sigmastar-lib
SIGMASTAR_LIB_SITE_BRANCH = main
SIGMASTAR_LIB_VERSION = cd3c621fdb9e60e7f567ec6146af44ebeddc2630
SIGMASTAR_LIB_LICENSE = PROPRIETARY
SIGMASTAR_LIB_REDISTRIBUTE = NO

# Same shape as ingenic-lib.mk resolves: family, content type, then release,
# C library and toolchain version. A second family, release or libc is a
# directory in the repo rather than a change here.
#
# The last three come from soc/sigmastar/<family>.mk, which is also where
# sigmastar-sdk reads them for its kernel modules. They describe the *vendor's*
# build, not ours -- these libraries were compiled with GCC 9.1.0 against glibc
# long before this tree's toolchain existed, and the path has to name what is in
# the repo. The vendor names a drop by its build date, so 0607 is 2022-06-07,
# read from the stamp the libraries carry rather than inferred:
#
#   strings libmi_sys.so | grep 'Sigmastar Module'
#
# Defining them once, outside both packages, is what stops this repository and
# sigmastar-sdk being pinned to different vendor builds -- a pairing insmod
# accepts and that then fails at symbol resolution.
#
# Not SIGMASTAR_LIB_DIR: pkg-generic.mk defines <PKG>_DIR as the package build
# directory, so that name is silently overwritten and the path collapses to
# $(@D). ingenic-lib.mk calls its equivalent SDK_LIB_DIR for the same reason.
SIGMASTAR_LIB_BLOBS = $(@D)/$(SOC_FAMILY)/lib/$(SIGMASTAR_DROP)/$(SIGMASTAR_LIBC)/$(SIGMASTAR_GCC)

define SIGMASTAR_LIB_INSTALL_TARGET_CMDS
	$(INSTALL) -m 755 -d $(TARGET_DIR)/usr/lib
	$(INSTALL) -m 644 -t $(TARGET_DIR)/usr/lib $(SIGMASTAR_LIB_BLOBS)/*.so
endef

$(eval $(generic-package))
