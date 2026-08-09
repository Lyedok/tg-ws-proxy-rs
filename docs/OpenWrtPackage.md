# OpenWrt packages

This repository contains a standalone packaging workflow for OpenWrt. It does
not depend on, or publish to, the official `openwrt/packages` feed.

The workflow publishes one core APK/IPK for each actually different release
binary: `aarch64`, `armv7`, `mips`, `mipsel` and `x86_64`. LuCI is published once
per package format because it is architecture-independent. The direct package
assets share one `SHA256SUMS`; there are no bundle archives or duplicated
per-microarchitecture payloads. The top-level [`install.sh`](../install.sh)
supports both local and release packages.

No package script creates firewall rules or changes HomeProxy/nftables. Opening
the listening port and selecting an outbound route remain explicit OpenWrt UCI
administrator decisions.

## Package contents

| Path | Purpose |
|---|---|
| `/usr/bin/tg-ws-proxy` | Static proxy binary |
| `/etc/init.d/tg-ws-proxy` | procd service |
| `/etc/config/tg-ws-proxy` | UCI configuration and persistent secret |
| `/lib/upgrade/keep.d/tg-ws-proxy` | sysupgrade retention rule |

The companion `luci-app-tg-ws-proxy` package contains the LuCI JavaScript view,
`Services → Telegram WS Proxy` menu entry, RPC ACL and ucitrack metadata. It is
architecture-independent and depends on both `luci-base` and `tg-ws-proxy`.

`/etc/config/tg-ws-proxy` is a package conffile. Upgrades preserve local
settings. The packaged default is disabled, while `install.sh` enables the
service after configuration/migration succeeds.

## Build prerequisites

1. A static musl binary for the target CPU.
2. `apk-tools` 3.x with `apk mkpkg` for APK output.
3. OpenWrt's `scripts/ipkg-build` for IPK output.
4. `fakeroot` to normalize package payload ownership to `root:root`.

An OpenWrt SDK supplies both package tools. The standalone builder uses only its
host-side `apk`, `ipkg-build` and `fakeroot`; it does not compile target code.
Consequently release CI can use one checksum-verified SDK host-tools bundle to
package multiple target binaries. The static Rust binary's CPU ISA must still
match the destination device.

The application can be cross-compiled with any documented method in
[Building.md](Building.md). One isolated Docker example is:

```bash
sudo docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp -e CARGO_HOME=/tmp/cargo \
  -e CARGO_TARGET_DIR=/project/target/musl-cross \
  -e CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=aarch64-unknown-linux-musl-gcc \
  -e CC_aarch64_unknown_linux_musl=aarch64-unknown-linux-musl-gcc \
  -e AR_aarch64_unknown_linux_musl=aarch64-unknown-linux-musl-ar \
  -v "$PWD:/project" -w /project \
  messense/rust-musl-cross:aarch64-musl \
  cargo build --release --locked --target aarch64-unknown-linux-musl
```

For reproducible automation, pin the container image digest used by CI or the
build host.

## Build APK and IPK

```bash
export OPENWRT_SDK=/path/to/openwrt-sdk-25.12.5-mediatek-filogic
PACKAGE_ARCH=aarch64  # use one ISA from openwrt/release-architectures.tsv

openwrt/build-package.sh \
  --binary target/musl-cross/aarch64-unknown-linux-musl/release/tg-ws-proxy \
  --apk-arch "$PACKAGE_ARCH" \
  --ipk-arch "$PACKAGE_ARCH" \
  --format both
```

Artifacts land in `dist/openwrt/` and are intentionally ignored by Git.
`openwrt/build-package.sh` refuses a dynamically linked ELF and refuses a
version/release mismatch between `Cargo.toml`, `openwrt/Makefile` and
`openwrt/luci-app/Makefile`. APK staging is built under the SDK's fakeroot
environment; IPK tar metadata is additionally forced to numeric owner/group 0.
This is required because rpcd refuses to control an init script that is not
owned by `root:root`.

To sign the APK, pass `--sign-key PATH` or set `APK_SIGN_KEY`. Never commit the
private key. A local package that is not in an APK repository is installed with
`--force-non-repository`; without a signing key the installer additionally
falls back to `--allow-untrusted`. The shared `SHA256SUMS` still detects
transport/file corruption but is not a substitute for an authenticated
signature.

## Install a local build

Copy the package and installer to the router. Minimal OpenWrt images may not
have an SFTP server, so piping over SSH is reliable:

```bash
ROUTER=root@openwrt.lan
PACKAGE_ISA=aarch64
CORE="tg-ws-proxy_2.2.2-r1_${PACKAGE_ISA}.apk"
LUCI=luci-app-tg-ws-proxy_2.2.2-r1_noarch.apk

ssh "$ROUTER" "dd of=/tmp/$CORE 2>/dev/null" < "dist/openwrt/$CORE"
ssh "$ROUTER" "dd of=/tmp/$LUCI 2>/dev/null" < "dist/openwrt/$LUCI"
ssh "$ROUTER" 'dd of=/tmp/SHA256SUMS 2>/dev/null' < dist/openwrt/SHA256SUMS
ssh "$ROUTER" 'dd of=/tmp/install-tg-ws-proxy.sh 2>/dev/null' < install.sh
ssh "$ROUTER" "chmod 700 /tmp/install-tg-ws-proxy.sh && /tmp/install-tg-ws-proxy.sh --package /tmp/$CORE"
```

The installer:

1. detects APK/opkg and maps `DISTRIB_ARCH` to one of five CPU ISAs;
2. downloads only the matching core package, LuCI and `SHA256SUMS`, then verifies
   both packages;
3. creates a root-only rollback directory under
   `/root/tg-ws-proxy-backups/`;
4. captures known `TG_*` values from an active manual deployment without
   printing them;
5. installs the core package and migrates those values into UCI;
6. enables/restarts the service and checks procd plus the configured listener;
7. installs LuCI, clears its menu cache and reloads rpcd;
8. on a failed fresh/manual migration, removes the newly introduced packages and
   restores the previous files; on a failed package upgrade, restores UCI and
   the previous enable/running state without copying old files over the new
   package database.

Use `install.sh --dry-run --package ... --arch ... --package-manager ...` to
exercise resolution without requiring OpenWrt or making changes.

Legacy opkg commonly accepts only an exact OpenWrt optimization label such as
`aarch64_cortex-a53`, while release IPKs use the real payload ISA (`aarch64`).
Before invoking `opkg --force-architecture`, the installer reads the IPK metadata
and requires it to equal either the device's exact `DISTRIB_ARCH` or the mapped
ISA. A mismatched package is rejected before opkg runs.

## Install from GitHub Releases

The same `vX.Y.Z` release workflow publishes Rust binaries and direct OpenWrt
packages for the five ISAs in `openwrt/release-architectures.tsv`. Device-specific
OpenWrt optimization labels map to those ISAs in the installer instead of
creating duplicate package payloads.

The installer resolves the latest stable release by default:

```bash
wget -qO- https://raw.githubusercontent.com/valnesfjord/tg-ws-proxy-rs/main/install.sh | sh
```

Beta tags use `vX.Y.Z-beta.N` and create an ordinary GitHub prerelease with the
same direct package set. Beta packages use each package manager's native prerelease
ordering: `X.Y.Z_betaN-rM` for APK and `X.Y.Z~beta.N-rM` for IPK. Both sort
below the corresponding stable package. Beta installation is explicit:

```bash
wget -qO- https://raw.githubusercontent.com/valnesfjord/tg-ws-proxy-rs/main/install.sh | \
  sh -s -- --channel beta
```

GitHub's stable `releases/latest` endpoint excludes prereleases, so publishing a
beta does not move stable-channel clients. Set
`TG_WS_PROXY_REPOSITORY=owner/repository` when testing a fork release. If GitHub
downloads are blocked, set `GH_MIRROR` when running a downloaded copy. Only
architectures explicitly listed in the release map can use remote install;
other targets continue to use `--package`.

## Configure with LuCI

Install the companion package and open:

```text
Services → Telegram WS Proxy
```

The page exposes the UCI settings, service status/PID and restricted
Start/Restart/Stop controls. Save & Apply commits only `tg-ws-proxy` UCI and
uses the procd reload trigger. The proxy secret is rendered as a password field.

The **Logging & security** tab includes a live viewer for entries matching
`tg-ws-proxy` in the OpenWrt system log, manual refresh and polling. ACL access
is limited to the exact `/sbin/logread -e tg-ws-proxy` command; arbitrary command
execution is not allowed.

The same tab exposes one **Log level** selector backed by Rust's native
`RUST_LOG` / `tracing_subscriber::EnvFilter` levels: `off`, `error`, `warn`,
`info`, `debug` and `trace`. For `info`, `debug` and `trace`, the selected level
applies to `tg_ws_proxy` / `tg_ws_proxy_rs`; dependency crates remain at `warn`
to avoid low-level TLS/runtime noise.

The viewer removes the duplicate tracing UTC timestamp and the logd
facility/process prefix, retaining the router-local time, level, Rust target and
message. For example:

```text
Aug  9 12:17:51 [DEBUG] tg_ws_proxy_rs::pool — WS pool warmup complete
```

## OpenWrt system log

The packaged service does not set `TG_LOG_FILE`. procd captures stderr/stdout and
forwards it to OpenWrt `logd`, whose ring buffer is bounded by the router's normal
system logging configuration. No application-specific rotation, cron process or
restart is required, and no log file consumes unbounded tmpfs memory.

LuCI obtains only matching entries with:

```sh
logread -e tg-ws-proxy
```

There is intentionally no **Clean log** button because `logd` is shared by the
whole router and must not be cleared for one application. The init script also
removes the former `/var/run/tg-ws-proxy/tg-ws-proxy.log` and `.log.1` files
left by earlier local package builds.

## Configure with UCI

Example configuration:

```bash
uci set tg-ws-proxy.main.enabled='1'
uci set tg-ws-proxy.main.host='0.0.0.0'
uci set tg-ws-proxy.main.port='3443'
uci set tg-ws-proxy.main.link_ip='proxy.example.net'
uci set tg-ws-proxy.main.outbound_proxy='socks5h://127.0.0.1:5330'
uci -q delete tg-ws-proxy.main.cf_worker_domain
uci add_list tg-ws-proxy.main.cf_worker_domain='worker.example.workers.dev'
uci set tg-ws-proxy.main.log_level='info'
uci commit tg-ws-proxy
/etc/init.d/tg-ws-proxy restart
```

If `secret` is empty on first start, the init script reads 16 random bytes from
`/dev/urandom`, stores the resulting 32 lowercase hex characters in UCI, and
reuses it across restarts/upgrades. Do not paste `/etc/config/tg-ws-proxy` into
public logs because it contains this credential.

Repeatable values use UCI lists:

```bash
uci -q delete tg-ws-proxy.main.dc_ip
uci add_list tg-ws-proxy.main.dc_ip='2:149.154.167.220'
uci add_list tg-ws-proxy.main.dc_ip='4:149.154.167.220'
uci add_list tg-ws-proxy.main.cf_domain='one.example'
uci add_list tg-ws-proxy.main.cf_domain='two.example'
uci commit tg-ws-proxy
/etc/init.d/tg-ws-proxy restart
```

## Firewall and outbound routing

The package only starts a listener. If clients connect through a WAN zone, add
a narrowly scoped UCI firewall input rule for the selected TCP port and verify
it independently. Do not embed ad-hoc nft commands in this package.

When `outbound_proxy` points to a local HomeProxy SOCKS listener, HomeProxy must
route `web.telegram.org` through an upstream that preserves WebSocket traffic.
That routing policy is not owned by this package.

## Upgrade, uninstall, and rollback

Upgrade by running `install.sh --package` with a newer artifact. UCI is a
conffile and remains intact.

```bash
# APK
apk del luci-app-tg-ws-proxy tg-ws-proxy

# IPK
opkg remove luci-app-tg-ws-proxy tg-ws-proxy
```

Package-manager removal normally preserves a modified conffile; delete it only
when the secret and settings are intentionally no longer needed. On a failed
upgrade of an already packaged installation, recovery restores the previous UCI
and service state while leaving the package-manager transaction internally
consistent. Reinstall the previous core and LuCI APK/IPK artifacts when a full
binary downgrade is required. Recovery backups are not automatically deleted.

## Validation

Repository checks:

```bash
shellcheck -s sh install.sh openwrt/files/tg-ws-proxy.init \
  openwrt/luci-app/root/etc/uci-defaults/95_luci-tg-ws-proxy
shellcheck -s bash openwrt/build-package.sh openwrt/tests/*.sh
node --check openwrt/luci-app/htdocs/luci-static/resources/view/tg-ws-proxy/settings.js
openwrt/tests/run.sh
cargo test --locked
```

For an ARM64 artifact also run:

```bash
file target/musl-cross/aarch64-unknown-linux-musl/release/tg-ws-proxy
readelf -d target/musl-cross/aarch64-unknown-linux-musl/release/tg-ws-proxy
qemu-aarch64 target/musl-cross/aarch64-unknown-linux-musl/release/tg-ws-proxy --help
```

`readelf -d` must show no dynamic section/`NEEDED` entries. Device validation
must include `root:root` package ownership, procd and `rc.init` controls, the
listener, LuCI menu/route/static view, restricted filtered-log exec ACL, exact
running ELF checksum, and an actual Telegram client handshake/data transfer.
