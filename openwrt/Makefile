# SPDX-License-Identifier: MIT

include $(TOPDIR)/rules.mk

PKG_NAME:=tg-ws-proxy
PKG_VERSION:=2.2.2
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Lyedok
PKG_BUILD_FLAGS:=no-mips16

include $(INCLUDE_DIR)/package.mk

define Package/tg-ws-proxy
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=Telegram MTProto WebSocket bridge proxy
  URL:=https://github.com/valnesfjord/tg-ws-proxy-rs
endef

define Package/tg-ws-proxy/description
  A low-memory Telegram MTProto proxy that tunnels traffic through
  WebSocket connections to Telegram data centers, with optional FakeTLS,
  Cloudflare, MTProto proxy, and outbound HTTP/SOCKS proxy fallbacks.
endef

define Package/tg-ws-proxy/conffiles
/etc/config/tg-ws-proxy
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
	test -x $(CURDIR)/files/tg-ws-proxy
endef

define Package/tg-ws-proxy/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(CURDIR)/files/tg-ws-proxy $(1)/usr/bin/tg-ws-proxy
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(CURDIR)/files/tg-ws-proxy.config $(1)/etc/config/tg-ws-proxy
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/files/tg-ws-proxy.init $(1)/etc/init.d/tg-ws-proxy
endef

$(eval $(call BuildPackage,tg-ws-proxy))
