include $(TOPDIR)/rules.mk

PKG_NAME:=mm-watchdog
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=Proprietary

include $(INCLUDE_DIR)/package.mk


define Package/mm-watchdog
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Podbox ModemManager watchdog
  DEPENDS:=+modemmanager +uclient-fetch
endef


define Package/mm-watchdog/description
  Production ModemManager watchdog with automatic cellular recovery
  and remote diagnostic reporting.
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

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/mm-watchdog \
		$(1)/etc/init.d/mm-watchdog

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/mm-watchdog \
		$(1)/etc/config/mm-watchdog
endef


$(eval $(call BuildPackage,mm-watchdog))