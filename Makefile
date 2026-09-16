include $(TOPDIR)/rules.mk

PKG_NAME:=mm-watchdog
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=LICENSE
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk


define Package/mm-watchdog
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Connectivity watchdog for ModemManager
  DEPENDS:=+modemmanager +jshn +uclient-fetch +ca-bundle
endef


define Package/mm-watchdog/description
  Monitors cellular Internet connectivity through ModemManager and
  performs staged, cooldown-aware recovery for mobile OpenWrt devices.
endef


define Package/mm-watchdog/conffiles
/etc/config/mm-watchdog
endef


define Build/Compile
endef


define Package/mm-watchdog/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/modem-watchdog \
		$(1)/usr/sbin/modem-watchdog

	$(INSTALL_DIR) $(1)/usr/lib/mm-watchdog
	$(INSTALL_DATA) ./files/usr/lib/mm-watchdog/config.sh \
		$(1)/usr/lib/mm-watchdog/config.sh
	$(INSTALL_DATA) ./files/usr/lib/mm-watchdog/webhook.sh \
		$(1)/usr/lib/mm-watchdog/webhook.sh
	$(INSTALL_DATA) ./files/usr/lib/mm-watchdog/watchdog.sh \
		$(1)/usr/lib/mm-watchdog/watchdog.sh

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/mm-watchdog \
		$(1)/etc/init.d/mm-watchdog

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/mm-watchdog \
		$(1)/etc/config/mm-watchdog
endef


$(eval $(call BuildPackage,mm-watchdog))
