# SPDX-License-Identifier: MIT

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-tg-ws-proxy
PKG_VERSION:=$(if $(TG_PACKAGE_VERSION),$(TG_PACKAGE_VERSION),2.2.3)
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Lyedok

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-tg-ws-proxy
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for tg-ws-proxy
  DEPENDS:=+luci-base
  PKGARCH:=all
endef

define Package/luci-app-tg-ws-proxy/description
 LuCI interface and OpenWrt service integration for a separately installed
 tg-ws-proxy release binary.
endef

define Build/Compile
endef

define Package/luci-app-tg-ws-proxy/conffiles
/etc/config/tg-ws-proxy
endef

define Package/luci-app-tg-ws-proxy/install
	$(INSTALL_DIR) $(1)/etc $(1)/usr/share $(1)/www
	$(CP) ./root/etc/* $(1)/etc/
	$(CP) ./root/usr/share/* $(1)/usr/share/
	$(CP) ./htdocs/* $(1)/www/
endef

$(eval $(call BuildPackage,luci-app-tg-ws-proxy))
