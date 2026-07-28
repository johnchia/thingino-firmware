THINGINO_AGENT_SITE_METHOD = local
THINGINO_AGENT_SITE = $(THINGINO_AGENT_PKGDIR)/files
THINGINO_AGENT_LICENSE = MIT
ifeq ($(BR2_PACKAGE_MBEDTLS),y)
THINGINO_AGENT_DEPENDENCIES = thingino-core thingino-jct host-thingino-jct mbedtls mbedtls-certgen
else ifeq ($(BR2_PACKAGE_THINGINO_MBEDTLS),y)
THINGINO_AGENT_DEPENDENCIES = thingino-core thingino-jct host-thingino-jct thingino-mbedtls mbedtls-certgen
endif

define THINGINO_AGENT_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -o $(@D)/thingino-agentd-native \
		$(@D)/thingino-agentd-native.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -o $(@D)/thingino-agent-tls-proxy \
		$(@D)/thingino-agent-tls-proxy.c $(@D)/thingino-agent-tls-event.c \
		-lmbedtls -lmbedx509 -lmbedcrypto
endef

define THINGINO_AGENT_INSTALL_TARGET_CMDS
	$(HOST_DIR)/bin/jct $(TARGET_DIR)/etc/thingino.json import \
		$(THINGINO_AGENT_PKGDIR)/files/thingino-agent.json

	$(INSTALL) -D -m 0755 $(@D)/S95thingino-agent \
		$(TARGET_DIR)/etc/init.d/S95thingino-agent
	$(INSTALL) -D -m 0755 $(@D)/thingino-agentd \
		$(TARGET_DIR)/usr/sbin/thingino-agentd
	$(INSTALL) -D -m 0755 $(@D)/thingino-agentd-native \
		$(TARGET_DIR)/usr/libexec/thingino-agent/listener
	$(INSTALL) -D -m 0755 $(@D)/thingino-agent-tls-proxy \
		$(TARGET_DIR)/usr/libexec/thingino-agent/tls-proxy
	$(INSTALL) -D -m 0755 $(@D)/thingino-agentctl \
		$(TARGET_DIR)/usr/sbin/thingino-agentctl
	$(INSTALL) -D -m 0644 $(@D)/thingino-agent-lib \
		$(TARGET_DIR)/usr/libexec/thingino-agent/lib.sh
	$(INSTALL) -D -m 0644 $(@D)/thingino-agent-adapter-null \
		$(TARGET_DIR)/usr/libexec/thingino-agent/adapters/null.sh
	$(INSTALL) -D -m 0644 $(@D)/thingino-agent-adapter-prudynt \
		$(TARGET_DIR)/usr/libexec/thingino-agent/adapters/prudynt.sh
	$(INSTALL) -D -m 0644 $(@D)/thingino-agent-adapter-raptor \
		$(TARGET_DIR)/usr/libexec/thingino-agent/adapters/raptor.sh
endef

$(eval $(generic-package))

# /etc/thingino.json has three independent authors: thingino-core INSTALLs it
# from configs/common.thingino.json, then thingino-agent and thingino-ha each
# `jct import` their own top-level block into it.
#
# Under per-package directories every one of those writes lands in that
# package's PRIVATE target dir, and buildroot/Makefile:758 assembles the real
# tree with
#
#     $(call per-package-rsync,$(sort $(PACKAGES)),target,$(TARGET_DIR),copy)
#
# which is a single rsync fed a --files-from list of every package's private
# dir (pkg-utils.mk:270). It copies files; it does not merge JSON, so exactly
# one author's copy of this path survives. Which one is decided by rsync's
# duplicate handling over that list -- the list is sorted and then reversed by
# `tac`, and what comes out is thingino-ha's copy, verified by comparing the
# assembled file byte-for-byte against each per-package copy. The important
# property is that it is stable: the agent block loses on every build, not by
# luck of the dependency graph. The symptom is silent: the build is green,
# /etc/thingino.json looks well-formed, and S95thingino-agent reads
# agent.enabled as empty and logs "Disabled in /etc/thingino.json" while the
# listener never starts.
#
# TARGET_FINALIZE_HOOKS run at buildroot/Makefile:759, immediately after that
# rsync, which is the first and only point at which the assembled file exists.
# Re-import the same fragment there. `jct import` merges rather than replaces
# and is idempotent, so this stays a no-op if upstream ever gives the file a
# single owner.
#
# Scope note: thingino-core and thingino-button lose the same race, and
# thingino-uboot would also contend if it were built. Only the agent is
# fixed here because only the agent's loss is load-bearing for this board --
# core's content survives via ha's copy, and neither button nor uboot is built.
ifeq ($(BR2_PACKAGE_THINGINO_AGENT),y)
define THINGINO_AGENT_REIMPORT_CONFIG
	$(HOST_DIR)/bin/jct $(TARGET_DIR)/etc/thingino.json import \
		$(THINGINO_AGENT_PKGDIR)/files/thingino-agent.json
endef
TARGET_FINALIZE_HOOKS += THINGINO_AGENT_REIMPORT_CONFIG
endif
