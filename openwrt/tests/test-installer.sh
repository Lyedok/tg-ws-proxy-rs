#!/usr/bin/env bash
# shellcheck disable=SC2034 # Globals are consumed by functions sourced from install.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/install.sh"
[[ -x "$INSTALLER" ]] || { printf 'FAIL: install.sh is missing or not executable\n' >&2; exit 1; }

help="$($INSTALLER --help)"
for token in '--archive' '--luci-package' '--upx' '--channel' 'stable' 'beta' 'apk' 'opkg'; do
    [[ "$help" == *"$token"* ]] || { printf 'FAIL: installer help misses %s\n' "$token" >&2; exit 1; }
done
[[ "$help" != *'--package PATH'* ]] || { printf 'FAIL: obsolete core package option remains\n' >&2; exit 1; }
if grep -Eq '(^|[[:space:]])install[[:space:]]+-m' "$INSTALLER"; then
    printf 'FAIL: installer requires the absent OpenWrt install command\n' >&2
    exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/core.tar.gz"
: > "$tmp/core-upx.tar.gz"
: > "$tmp/luci.apk"
: > "$tmp/luci.ipk"

out="$($INSTALLER --dry-run --archive "$tmp/core.tar.gz" --luci-package "$tmp/luci.apk" \
    --arch aarch64_cortex-a53 --package-manager apk)"
[[ "$out" == *'package_manager=apk'* && "$out" == *'target=aarch64-unknown-linux-musl'* && "$out" == *'variant=regular'* ]] || {
    printf 'FAIL: APK dry-run did not resolve regular AArch64 binary\n' >&2
    exit 1
}
out="$($INSTALLER --dry-run --archive "$tmp/core-upx.tar.gz" --luci-package "$tmp/luci.ipk" \
    --arch x86_64 --package-manager opkg)"
[[ "$out" == *'package_manager=opkg'* && "$out" == *'target=x86_64-unknown-linux-musl'* && "$out" == *'variant=upx'* ]] || {
    printf 'FAIL: IPK dry-run did not retain UPX selection\n' >&2
    exit 1
}

export TG_WS_PROXY_TEST_MODE=1
# shellcheck source=/dev/null
source "$INSTALLER"

for mapping in \
    aarch64_cortex-a53:aarch64-unknown-linux-musl \
    arm_cortex-a7_neon-vfpv4:armv7-unknown-linux-musleabihf \
    mips_24kc:mips-unknown-linux-musl \
    mipsel_24kc:mipsel-unknown-linux-musl \
    x86_64:x86_64-unknown-linux-musl; do
    arch="${mapping%%:*}"
    target="${mapping#*:}"
    [[ "$(binary_target "$arch")" == "$target" ]] || {
        printf 'FAIL: %s did not map to %s\n' "$arch" "$target" >&2
        exit 1
    }
done
if binary_target arm_arm1176jzf-s_vfp >/dev/null 2>&1; then
    printf 'FAIL: unsupported ARMv6 target was accepted\n' >&2
    exit 1
fi

TARGET=aarch64-unknown-linux-musl
USE_UPX=0
[[ "$(binary_archive_name)" == tg-ws-proxy-aarch64-unknown-linux-musl.tar.gz ]] || {
    printf 'FAIL: regular archive name is wrong\n' >&2; exit 1;
}
USE_UPX=1
[[ "$(binary_archive_name)" == tg-ws-proxy-aarch64-unknown-linux-musl-upx.tar.gz ]] || {
    printf 'FAIL: UPX archive name is wrong\n' >&2; exit 1;
}

APK_ARGS=''
OPKG_ARGS=''
apk() { APK_ARGS="$*"; }
opkg() { OPKG_ARGS="$*"; }
LUCI_PACKAGE_FILE=/tmp/luci-package
PM=apk
install_luci_package
[[ "$APK_ARGS" == "--allow-untrusted --force-non-repository add $LUCI_PACKAGE_FILE" ]] || {
    printf 'FAIL: APK trust policy changed: %s\n' "$APK_ARGS" >&2; exit 1;
}
PM=opkg
install_luci_package
[[ "$OPKG_ARGS" == "install $LUCI_PACKAGE_FILE" ]] || {
    printf 'FAIL: IPK install uses unexpected options: %s\n' "$OPKG_ARGS" >&2; exit 1;
}

printf 'binary archive\n' > "$tmp/archive"
printf 'luci package\n' > "$tmp/luci"
(
    cd "$tmp"
    sha256sum archive luci > SHA256SUMS
)
ARCHIVE_FILE="$tmp/archive"
LUCI_PACKAGE_FILE="$tmp/luci"
CHECKSUMS_FILE="$tmp/SHA256SUMS"
verify_assets >/dev/null

printf 'PASS: installer contract\n'
