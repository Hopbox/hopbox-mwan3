#
# Copyright (C) 2006-2014 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=hopbox-mwan3
PKG_VERSION:=3.0.0
PKG_RELEASE:=1
PKG_MAINTAINER:=Hopbox Firmware <firmware@hopbox.in>
PKG_LICENSE:=GPL-2.0

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/hopbox-mwan3
   CATEGORY:=hopbox
   DEPENDS:= \
     +ip \
     +kmod-nft-core \
     +nftables-json \
     +kmod-nf-conntrack \
     +conntrack \
     +rpcd \
     +jshn
   TITLE:=Multiwan hotplug script with nftables support
   MAINTAINER:=Hopbox Firmware <firmware@hopbox.in>
   PKGARCH:=all
   CONFLICTS:=mwan3
   PROVIDES:=mwan3
endef

define Package/hopbox-mwan3/description
Hotplug script which makes configuration of multiple WAN interfaces simple
and manageable. With loadbalancing/failover support for up to 250 wan
interfaces, connection tracking and an easy to manage traffic ruleset.

This is the Hopbox fork with native nftables support (no iptables/ipset
dependency), selective conntrack flush, and automatic WireGuard re-handshake
on WAN failover.
endef

define Package/hopbox-mwan3/conffiles
/etc/config/mwan3
/etc/mwan3.user
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/hopbox-mwan3/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	/etc/init.d/rpcd restart
fi
exit 0
endef

define Package/hopbox-mwan3/postrm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	/etc/init.d/rpcd restart
fi
exit 0
endef

define Package/hopbox-mwan3/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/mwan3 $(1)/etc/config/

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_DATA) ./files/etc/hotplug.d/iface/15-mwan3 \
		$(1)/etc/hotplug.d/iface/
	$(INSTALL_DATA) ./files/etc/hotplug.d/iface/16-mwan3 \
		$(1)/etc/hotplug.d/iface/
	$(INSTALL_DATA) ./files/etc/hotplug.d/iface/16-mwan3-user \
		$(1)/etc/hotplug.d/iface/
	$(INSTALL_DATA) ./files/etc/hotplug.d/iface/17-mwan3-hotplug-openvpn \
		$(1)/etc/hotplug.d/iface/

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/mwan3 $(1)/etc/init.d/

	$(INSTALL_DIR) $(1)/etc
	$(INSTALL_DATA) ./files/etc/mwan3.user $(1)/etc/

	$(INSTALL_DIR) $(1)/lib/mwan3
	$(INSTALL_DATA) ./files/lib/mwan3/common.sh $(1)/lib/mwan3/
	$(INSTALL_DATA) ./files/lib/mwan3/mwan3.sh $(1)/lib/mwan3/
	$(INSTALL_BIN) ./files/lib/mwan3/mwan3-fw-include.sh $(1)/lib/mwan3/
	$(INSTALL_BIN) ./files/lib/mwan3/mwan3-fw-rebuild.sh $(1)/lib/mwan3/

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/mwan3-firewall-include \
		$(1)/etc/uci-defaults/
	$(INSTALL_BIN) ./files/etc/uci-defaults/mwan3-migrate-flush_conntrack \
		$(1)/etc/uci-defaults/

	$(INSTALL_DIR) $(1)/usr/share/nftables.d/table-post
	$(INSTALL_DATA) ./files/usr/share/nftables.d/table-post/10-mwan3.nft \
		$(1)/usr/share/nftables.d/table-post/

	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/mwan3 $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/usr/sbin/mwan3track $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/usr/sbin/mwan3rtmon $(1)/usr/sbin/

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/mwan3 $(1)/usr/libexec/rpcd/
endef

$(eval $(call BuildPackage,hopbox-mwan3))
