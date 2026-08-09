# OpenWrt installation

OpenWrt uses the normal static musl binaries already published by this project.
The proxy binary is **not** wrapped in APK/IPK. Only the architecture-independent
LuCI and service integration is packaged:

- OpenWrt 25.12+: `luci-app-tg-ws-proxy` APK (`noarch` metadata);
- OpenWrt 24.10: `luci-app-tg-ws-proxy` IPK (`all` metadata).

The single package recipe declares `PKGARCH:=all`. OpenWrt 25.12's package
backend converts that declaration to APK's native `noarch` metadata; the 24.10
backend keeps IPK's `all` metadata.

No installer or package script creates firewall rules or modifies
HomeProxy/nftables. Listening-port exposure and outbound routing remain explicit
administrator decisions.

## Installed files

The release binary is installed directly as:

```text
/usr/bin/tg-ws-proxy
```

The LuCI/integration package owns:

```text
/etc/init.d/tg-ws-proxy
/etc/config/tg-ws-proxy
/usr/share/luci/menu.d/luci-app-tg-ws-proxy.json
/usr/share/rpcd/acl.d/luci-app-tg-ws-proxy.json
/usr/share/ucitrack/luci-app-tg-ws-proxy.json
/www/luci-static/resources/view/tg-ws-proxy/settings.js
```

`/etc/config/tg-ws-proxy` is a conffile. Package upgrades preserve it. Secret
generation and legacy logging migration run from versioned OpenWrt installation
hooks or `install.sh`; the procd init script only reads UCI and starts the
process.

## Release assets

Each GitHub release contains the existing regular and UPX Linux musl archives
for these Rust targets:

- `aarch64-unknown-linux-musl`;
- `armv7-unknown-linux-musleabihf`;
- `mips-unknown-linux-musl`;
- `mipsel-unknown-linux-musl`;
- `x86_64-unknown-linux-musl`.

It additionally contains one LuCI APK, one LuCI IPK and a shared `SHA256SUMS`
covering all ten Linux archives and both LuCI packages. There are no core APKs,
core IPKs, per-router optimization wrappers or package feeds.

## Install or upgrade

Run on the router as root:

```sh
wget -qO- https://raw.githubusercontent.com/valnesfjord/tg-ws-proxy-rs/main/install.sh | sh
```

The regular binary is the default. UPX is an explicit choice because it saves
flash space at the cost of higher non-evictable runtime memory:

```sh
wget -qO- https://raw.githubusercontent.com/valnesfjord/tg-ws-proxy-rs/main/install.sh | \
  sh -s -- --upx
```

Install the latest beta, optionally with UPX:

```sh
wget -qO- https://raw.githubusercontent.com/valnesfjord/tg-ws-proxy-rs/main/install.sh | \
  sh -s -- --channel beta --upx
```

Environment equivalents are available for automation:

```sh
TG_WS_PROXY_RELEASE_CHANNEL=beta TG_WS_PROXY_UPX=1 sh install.sh
```

Set `TG_WS_PROXY_REPOSITORY=owner/repository` to test a fork release. Set
`GH_MIRROR=https://mirror.example` when GitHub release downloads need a mirror.

The installer:

1. detects APK/opkg and maps `DISTRIB_ARCH` to the compatible Rust musl target;
2. selects the regular or `-upx` archive and the matching LuCI APK/IPK;
3. verifies both against the release `SHA256SUMS`;
4. extracts the archive and runs the staged binary with `--version` before
   touching the running service;
5. backs up the previous binary, UCI config and service state under
   `/root/tg-ws-proxy-backups/`;
6. installs the LuCI package, migrates a known manual `TG_*` configuration and
   atomically replaces `/usr/bin/tg-ws-proxy`;
7. enables/restarts procd and verifies both the process and listening socket.

If the new binary cannot start, the previous binary, UCI config and service state
are restored. A newly introduced LuCI package is removed as well. When an
already-installed LuCI package was upgraded, it remains upgraded because neither
APK nor opkg guarantees that the previous package artifact is locally available;
the installer reports this limitation instead of claiming a full package
rollback.

## Local assets

Put the archive, LuCI package and `SHA256SUMS` in one directory and copy them to
the router. Minimal images may lack SFTP, so stdin over SSH is reliable:

```bash
ROUTER=root@openwrt.lan
ARCHIVE=tg-ws-proxy-aarch64-unknown-linux-musl.tar.gz
LUCI=luci-app-tg-ws-proxy-2.2.3-r1.apk # use the .ipk on OpenWrt 24.10

ssh "$ROUTER" "dd of=/tmp/$ARCHIVE 2>/dev/null" < "$ARCHIVE"
ssh "$ROUTER" "dd of=/tmp/$LUCI 2>/dev/null" < "$LUCI"
ssh "$ROUTER" 'dd of=/tmp/SHA256SUMS 2>/dev/null' < SHA256SUMS
ssh "$ROUTER" 'dd of=/tmp/install.sh 2>/dev/null' < install.sh
ssh "$ROUTER" "chmod 700 /tmp/install.sh && /tmp/install.sh \
  --archive /tmp/$ARCHIVE --luci-package /tmp/$LUCI"
```

`--dry-run`, `--arch` and `--package-manager` are available for deterministic
asset-resolution checks without installation.

## Package trust

The LuCI APK is intentionally installed with `--allow-untrusted`; this project
does not operate an APK signing-key lifecycle. The installer does not perform a
misleading strict-signature attempt first. It verifies `SHA256SUMS`, then invokes
APK with the accepted trust policy explicitly. In this model, repository control
and GitHub HTTPS are the source-authentication boundary; the checksum detects
asset corruption but is not an independent package signature.

IPK installation uses ordinary `opkg install`. Because the IPK contains only
architecture-independent integration files, no `--force-architecture` bypass is
required.

## Configure and operate

Open:

```text
Services → Telegram WS Proxy
```

The page exposes UCI settings, status/control actions and a live filtered view of
the bounded OpenWrt `logd` ring buffer. The log-level selector maps to
`off|error|warn|info|debug|trace`; application debug/trace can be enabled without
turning on dependency-crate noise.

Example UCI changes:

```sh
uci set tg-ws-proxy.main.enabled='1'
uci set tg-ws-proxy.main.host='0.0.0.0'
uci set tg-ws-proxy.main.port='3443'
uci set tg-ws-proxy.main.outbound_proxy='socks5h://127.0.0.1:5330'
uci set tg-ws-proxy.main.log_level='info'
uci commit tg-ws-proxy
/etc/init.d/tg-ws-proxy restart
```

The secret is persistent in `/etc/config/tg-ws-proxy`; do not include that file
in public logs.

## Uninstall

Remove the LuCI/integration package and the separately managed binary:

```sh
if command -v apk >/dev/null 2>&1; then
  apk del luci-app-tg-ws-proxy
else
  opkg remove luci-app-tg-ws-proxy
fi
rm -f /usr/bin/tg-ws-proxy
```

Package-manager removal may preserve the modified UCI conffile. Delete it only
when its secret and settings are intentionally no longer needed.

## Build and validate the LuCI packages

Use the matching official SDK; no application binary is compiled or packaged:

```bash
openwrt/build-luci-package.sh \
  --sdk /path/to/openwrt-sdk-25.12.5 \
  --version 2.2.3 --format apk

openwrt/build-luci-package.sh \
  --sdk /path/to/openwrt-sdk-24.10.5 \
  --version 2.2.3 --format ipk
```

The script copies the single recipe into the SDK, invokes the normal OpenWrt
package target and validates package name, version and architecture metadata.
Repository checks are:

```bash
shellcheck install.sh openwrt/build-luci-package.sh openwrt/luci-app/root/etc/init.d/tg-ws-proxy \
  openwrt/luci-app/root/etc/uci-defaults/95_luci-tg-ws-proxy openwrt/tests/*.sh
node --check openwrt/luci-app/htdocs/luci-static/resources/view/tg-ws-proxy/settings.js
openwrt/tests/run.sh
```
