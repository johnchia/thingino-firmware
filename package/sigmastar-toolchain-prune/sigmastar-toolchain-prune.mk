################################################################################
#
# sigmastar-toolchain-prune
#
# Not a package -- just a hook. external.mk includes every package/*/*.mk, which
# makes this the least invasive place to put it.
#
# The OpenIPC ARM toolchain is not a bare toolchain. Its sysroot ships OpenIPC's
# prebuilt dependency set alongside glibc:
#
#   libmbedtls/libmbedcrypto/libmbedx509 2.25.0 (Dec 2020), libcurl, libevent
#   (incl. libevent_mbedtls), libjson-c, libubox (+libblobmsg_json,
#   libjson_script), libopus, libogg, libyaml, libz
#
# Buildroot copies that sysroot into staging, and its per-package rsync replays
# the toolchain directory *after* the package directories. So a package that
# Buildroot built from source gets its headers overwritten by the toolchain's
# older copies. That is what this looks like:
#
#   mbedtls-certgen.c:403: warning: implicit declaration of function
#       'mbedtls_x509write_crt_set_serial_raw'
#   ld: undefined reference to 'mbedtls_x509write_crt_set_serial_raw'
#
# mbedtls 3.6.6 had been built and installed correctly; the toolchain's 2.25
# x509_crt.h then landed on top of it, and 2.25 has no set_serial_raw.
#
# Each library is pruned ONLY when Buildroot is configured to build its own.
# That matters in both directions:
#
#   - Pruning unconditionally would delete libraries nothing replaces, and the
#     build would then fail to link.
#
#     An earlier version of this comment went further and called the unreplaced
#     toolchain copies "legitimately linked against". That was wrong, and it hid
#     a whole class of bug. Linking against them succeeds; SHIPPING them does
#     not happen. Buildroot's toolchain-external copies only a fixed set of
#     runtime libraries into the target -- libc, libm, libgcc_s, libstdc++ and
#     friends -- and never the extra libraries a vendor sysroot happens to
#     bundle. So a package that links the toolchain's libz gets DT_NEEDED
#     libz.so.1 and no libz.so.1 in the rootfs, and fails at exec time with
#     nothing in the build log.
#
#     That is what happened to /usr/bin/curl and, through libcurl, to
#     telegrambot. The rule is: every bundled library that anything links must
#     either be built by Buildroot (then pruned here) or named in
#     BR2_TOOLCHAIN_EXTRA_LIBS so it is copied to the target. Leaving it to the
#     toolchain alone is never correct.
#
#     Check with: for every ELF in $(TARGET_DIR), confirm each DT_NEEDED
#     resolves under target/lib or target/usr/lib. That audit is what found
#     libz after uhttpd's libjson-c; it takes seconds and catches the class
#     rather than one instance.
#   - Pruning conditionally keeps working as the config grows. Phase 2 turns on
#     Raptor, which wants opus and ogg; the moment Buildroot builds them, the
#     stale bundled copies start being removed without anyone remembering to
#     come back here.
#
# glibc, libstdc++ and the kernel headers are never touched. Keeping this
# toolchain rather than switching to a bare one (Bootlin) is deliberate: the
# SigmaStar vendor MI libraries the Raptor HAL dlopens are built against exactly
# this glibc. Swapping toolchains would trade a build-time collision, which
# fails loudly and once, for a runtime ABI mismatch, which does not.
#
################################################################################

SIGMASTAR_TOOLCHAIN_PRUNE_LIBS =
SIGMASTAR_TOOLCHAIN_PRUNE_INCLUDES =
SIGMASTAR_TOOLCHAIN_PRUNE_PC =

ifeq ($(BR2_PACKAGE_MBEDTLS),y)
SIGMASTAR_TOOLCHAIN_PRUNE_LIBS += libmbedtls libmbedcrypto libmbedx509
SIGMASTAR_TOOLCHAIN_PRUNE_INCLUDES += mbedtls psa
SIGMASTAR_TOOLCHAIN_PRUNE_PC += mbedtls mbedcrypto mbedx509
endif

ifeq ($(BR2_PACKAGE_LIBCURL),y)
SIGMASTAR_TOOLCHAIN_PRUNE_LIBS += libcurl
SIGMASTAR_TOOLCHAIN_PRUNE_INCLUDES += curl
SIGMASTAR_TOOLCHAIN_PRUNE_PC += libcurl
endif

ifeq ($(BR2_PACKAGE_ZLIB),y)
SIGMASTAR_TOOLCHAIN_PRUNE_LIBS += libz
SIGMASTAR_TOOLCHAIN_PRUNE_INCLUDES += zlib.h zconf.h
SIGMASTAR_TOOLCHAIN_PRUNE_PC += zlib
endif

# Two packages can be the json-c provider, and thingino's default is the second.
#
# thingino-jct is a drop-in replacement: it builds libjct.so.1.0.0 and then
# symlinks libjson-c.so, libjson.so, libjson-c.a and libjson.a onto it in both
# staging and target, so `-ljson-c` resolves to a library whose SONAME is
# libjct.so.1. Nothing on a thingino image ships a libjson-c.so.5 at all.
#
# Gating this block on BR2_PACKAGE_JSON_C alone therefore never fired here, and
# the toolchain's own libjson-c.so -> libjson-c.so.5 survived into staging and
# overwrote jct's symlink of the same name. uhttpd and jshn linked against it
# and came out NEEDING libjson-c.so.5, which does not exist on the target:
#
#   /etc/init.d/S60uhttpd start
#   SSL startup failed, falling back to HTTP-only...
#   FAIL
#
# The loader failure is silent from the init script's point of view -- it only
# checks pgrep and netstat, so a binary that cannot resolve its DT_NEEDED looks
# identical to one that started and refused to listen.
ifneq ($(BR2_PACKAGE_JSON_C)$(BR2_PACKAGE_THINGINO_JCT),)
SIGMASTAR_TOOLCHAIN_PRUNE_LIBS += libjson-c libjson
SIGMASTAR_TOOLCHAIN_PRUNE_INCLUDES += json-c
SIGMASTAR_TOOLCHAIN_PRUNE_PC += json-c
endif

# libevent_mbedtls goes with libevent: it is OpenIPC's build of libevent linked
# against the bundled mbedtls 2.25, so it is stale for the same reason.
ifeq ($(BR2_PACKAGE_LIBEVENT),y)
SIGMASTAR_TOOLCHAIN_PRUNE_LIBS += libevent libevent_core libevent_extra \
	libevent_pthreads libevent_mbedtls
SIGMASTAR_TOOLCHAIN_PRUNE_INCLUDES += event2 event.h evdns.h evhttp.h evrpc.h evutil.h
SIGMASTAR_TOOLCHAIN_PRUNE_PC += libevent libevent_core libevent_extra libevent_pthreads
endif

ifeq ($(BR2_PACKAGE_OPUS),y)
SIGMASTAR_TOOLCHAIN_PRUNE_LIBS += libopus
SIGMASTAR_TOOLCHAIN_PRUNE_INCLUDES += opus
SIGMASTAR_TOOLCHAIN_PRUNE_PC += opus
endif

ifeq ($(BR2_PACKAGE_LIBOGG),y)
SIGMASTAR_TOOLCHAIN_PRUNE_LIBS += libogg
SIGMASTAR_TOOLCHAIN_PRUNE_INCLUDES += ogg
SIGMASTAR_TOOLCHAIN_PRUNE_PC += ogg
endif

ifeq ($(BR2_PACKAGE_LIBYAML),y)
SIGMASTAR_TOOLCHAIN_PRUNE_LIBS += libyaml libyaml-0
SIGMASTAR_TOOLCHAIN_PRUNE_INCLUDES += yaml.h
SIGMASTAR_TOOLCHAIN_PRUNE_PC += yaml-0.1
endif

ifeq ($(BR2_PACKAGE_THINGINO_LIBUBOX),y)
SIGMASTAR_TOOLCHAIN_PRUNE_LIBS += libubox libblobmsg_json libjson_script
SIGMASTAR_TOOLCHAIN_PRUNE_INCLUDES += libubox
endif

define SIGMASTAR_TOOLCHAIN_PRUNE_STAGING
	@echo "sigmastar: pruning bundled libs from toolchain sysroot:" \
		"$(if $(strip $(SIGMASTAR_TOOLCHAIN_PRUNE_LIBS)),$(SIGMASTAR_TOOLCHAIN_PRUNE_LIBS),none)"
	$(Q)for l in $(SIGMASTAR_TOOLCHAIN_PRUNE_LIBS); do \
		rm -f $(STAGING_DIR)/usr/lib/$$l.so* $(STAGING_DIR)/usr/lib/$$l.a \
		      $(STAGING_DIR)/lib/$$l.so* ; \
	done
	$(Q)for i in $(SIGMASTAR_TOOLCHAIN_PRUNE_INCLUDES); do \
		rm -rf $(STAGING_DIR)/usr/include/$$i ; \
	done
	$(Q)for p in $(SIGMASTAR_TOOLCHAIN_PRUNE_PC); do \
		rm -f $(STAGING_DIR)/usr/lib/pkgconfig/$$p.pc ; \
	done
endef

TOOLCHAIN_EXTERNAL_CUSTOM_POST_INSTALL_STAGING_HOOKS += SIGMASTAR_TOOLCHAIN_PRUNE_STAGING
