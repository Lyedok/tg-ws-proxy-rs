# SPDX-License-Identifier: MIT

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for tg-ws-proxy
LUCI_DEPENDS:=+luci-base +tg-ws-proxy
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-tg-ws-proxy
PKG_VERSION:=2.2.2
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Lyedok

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
