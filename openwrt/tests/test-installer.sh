#!/usr/bin/env bash
# shellcheck disable=SC2034 # Globals are consumed by functions sourced from install.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/install.sh"
[[ -x "$INSTALLER" ]] || { printf 'FAIL: install.sh is missing or not executable\n' >&2; exit 1; }

help="$($INSTALLER --help)"
for token in '--package' '--dry-run' '--channel' 'stable' 'beta' 'GH_MIRROR' 'apk' 'opkg'; do
    [[ "$help" == *"$token"* ]] || { printf 'FAIL: installer help misses %s\n' "$token" >&2; exit 1; }
done
grep -Fq 'TG_WS_PROXY_REPOSITORY:-valnesfjord/tg-ws-proxy-rs' "$INSTALLER" || {
    printf 'FAIL: remote installer does not default to upstream releases\n' >&2
    exit 1
}
grep -Fq 'TG_WS_PROXY_RELEASE_CHANNEL:-stable' "$INSTALLER" || {
    printf 'FAIL: remote installer does not default to the stable channel\n' >&2
    exit 1
}

# Dry-run with a local package must not require OpenWrt or mutate this host.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/tg-ws-proxy_2.2.2_aarch64.apk"
out="$(env -u TG_WS_PROXY_TEST_MODE "$INSTALLER" --dry-run --package "$tmp/tg-ws-proxy_2.2.2_aarch64.apk" --arch aarch64_cortex-a53 --package-manager apk)"
[[ "$out" == *'package_manager=apk'* ]] || { printf 'FAIL: dry-run did not resolve apk\n' >&2; exit 1; }
[[ "$out" == *'architecture=aarch64_cortex-a53'* ]] || { printf 'FAIL: dry-run did not resolve architecture\n' >&2; exit 1; }
[[ "$out" == *"package=$tmp/tg-ws-proxy_2.2.2_aarch64.apk"* ]] || { printf 'FAIL: dry-run did not keep local package\n' >&2; exit 1; }
[[ "$out" == *"luci_package=$tmp/luci-app-tg-ws-proxy_2.2.2_noarch.apk"* ]] || { printf 'FAIL: dry-run did not derive LuCI from generic ISA package\n' >&2; exit 1; }
grep -q -- '--force-non-repository' "$INSTALLER" || { printf 'FAIL: apk local install must allow a non-repository package\n' >&2; exit 1; }
grep -Fq "ARCH=\"\$DISTRIB_ARCH\"" "$INSTALLER" || { printf 'FAIL: installer must prefer OpenWrt DISTRIB_ARCH over apk binary architecture\n' >&2; exit 1; }
grep -Fq "if [ \"\$OLD_PACKAGE\" -eq 0 ]; then" "$INSTALLER" || { printf 'FAIL: installer must distinguish a manual-to-package migration\n' >&2; exit 1; }
grep -Fq 'rm -f /etc/init.d/tg-ws-proxy /etc/init.d/tg-ws-proxy.apk-new' "$INSTALLER" || { printf 'FAIL: installer must clear the protected legacy init before first package install\n' >&2; exit 1; }

# Source the installer without running main(), then exercise recovery policy
# through overridable boundaries instead of touching this host.
export TG_WS_PROXY_TEST_MODE=1
# shellcheck source=/dev/null
source "$INSTALLER"

# A manually downloaded direct package set uses the same shared SHA256SUMS as
# remote install; no per-package sidecars are published.
PACKAGE_FILE="$tmp/tg-ws-proxy_2.2.2_aarch64.apk"
printf '%s  %s\n' "$(sha256sum "$PACKAGE_FILE" | cut -d' ' -f1)" "${PACKAGE_FILE##*/}" > "$tmp/SHA256SUMS"
CHECKSUMS_FILE=''
resolve_local_checksums
[[ "$CHECKSUMS_FILE" == "$tmp/SHA256SUMS" ]] || {
    printf 'FAIL: local direct assets did not discover shared SHA256SUMS\n' >&2
    exit 1
}
rm -f "$tmp/SHA256SUMS"
CHECKSUMS_FILE=''

# GitHub may return compact one-line JSON. The resolver must enumerate direct
# package assets instead of letting a greedy sed expression keep only the last URL.
printf '%s\n' '{"assets":[{"browser_download_url":"https://example.invalid/tg-ws-proxy_2.2.2_beta5-r1_aarch64.apk"},{"browser_download_url":"https://example.invalid/tg-ws-proxy_2.2.2.beta.5-r1_armv7.ipk"},{"browser_download_url":"https://example.invalid/luci-app-tg-ws-proxy_2.2.2_beta5-r1_noarch.apk"},{"browser_download_url":"https://example.invalid/SHA256SUMS"}]}' > "$tmp/release.json"
asset_urls="$(release_asset_urls "$tmp/release.json")"
for expected_url in \
    'https://example.invalid/tg-ws-proxy_2.2.2_beta5-r1_aarch64.apk' \
    'https://example.invalid/tg-ws-proxy_2.2.2.beta.5-r1_armv7.ipk' \
    'https://example.invalid/luci-app-tg-ws-proxy_2.2.2_beta5-r1_noarch.apk' \
    'https://example.invalid/SHA256SUMS'; do
    [[ "$asset_urls" == *"$expected_url"* ]] || {
        printf 'FAIL: compact release JSON lost asset %s\n' "$expected_url" >&2
        exit 1
    }
done
[[ "$(find_release_asset "$tmp/release.json" 'tg-ws-proxy_' '_aarch64.apk')" == \
    'https://example.invalid/tg-ws-proxy_2.2.2_beta5-r1_aarch64.apk' ]] || {
    printf 'FAIL: direct AArch64 APK was not resolved\n' >&2
    exit 1
}
[[ "$(find_release_asset "$tmp/release.json" 'luci-app-tg-ws-proxy_' '_noarch.apk')" == \
    'https://example.invalid/luci-app-tg-ws-proxy_2.2.2_beta5-r1_noarch.apk' ]] || {
    printf 'FAIL: direct LuCI APK was not resolved\n' >&2
    exit 1
}
[[ "$(find_release_asset "$tmp/release.json" 'SHA256SUMS' '')" == \
    'https://example.invalid/SHA256SUMS' ]] || {
    printf 'FAIL: shared SHA256SUMS was not resolved\n' >&2
    exit 1
}

for mapping in \
    aarch64_generic:aarch64 \
    aarch64_cortex-a53:aarch64 \
    arm_cortex-a7_vfpv4:armv7 \
    mips_24kc:mips \
    mipsel_24kc:mipsel \
    x86_64:x86_64; do
    arch="${mapping%%:*}"
    isa="${mapping#*:}"
    [[ "$(package_isa "$arch")" == "$isa" ]] || {
        printf 'FAIL: architecture %s did not resolve to ISA %s\n' "$arch" "$isa" >&2
        exit 1
    }
done
for unsupported_arch in arm_arm1176jzf-s_vfp mips_mips32 mipsel_mips32; do
    if package_isa "$unsupported_arch" >/dev/null 2>&1; then
        printf 'FAIL: incompatible architecture %s was mapped to a release ISA\n' "$unsupported_arch" >&2
        exit 1
    fi
done

# Exercise the complete remote path against a deterministic fake release. The
# installer must download only the selected ISA package, LuCI and SHA256SUMS.
fixtures="$tmp/direct-assets"
mkdir -p "$fixtures"
core_name=tg-ws-proxy_2.2.2_beta5-r1_aarch64.apk
luci_name=luci-app-tg-ws-proxy_2.2.2_beta5-r1_noarch.apk
printf 'core package\n' > "$fixtures/$core_name"
printf 'luci package\n' > "$fixtures/$luci_name"
(
    cd "$fixtures"
    sha256sum "$core_name" "$luci_name" > SHA256SUMS
)
printf '%s\n' "{\"assets\":[{\"browser_download_url\":\"https://example.invalid/$core_name\"},{\"browser_download_url\":\"https://example.invalid/$luci_name\"},{\"browser_download_url\":\"https://example.invalid/SHA256SUMS\"}]}" > "$fixtures/release.json"
wget() {
    local out='' url=''
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -qO) out="$2"; shift 2 ;;
            --timeout=*) shift ;;
            *) url="$1"; shift ;;
        esac
    done
    case "$url" in
        */releases/latest) cp "$fixtures/release.json" "$out" ;;
        */"$core_name") cp "$fixtures/$core_name" "$out" ;;
        */"$luci_name") cp "$fixtures/$luci_name" "$out" ;;
        */SHA256SUMS) cp "$fixtures/SHA256SUMS" "$out" ;;
        *) return 1 ;;
    esac
}
TMP_DIR=''
CHANNEL=stable
REPOSITORY=example/repository
PM=apk
EXT=apk
ARCH=aarch64_cortex-a53
PACKAGE_FILE=''
PACKAGE_URL=''
LUCI_PACKAGE_FILE=''
LUCI_PACKAGE_URL=''
CHECKSUMS_FILE=''
resolve_remote_package
[[ "${PACKAGE_FILE##*/}" == "$core_name" ]] || {
    printf 'FAIL: remote resolver did not select generic AArch64 core package\n' >&2
    exit 1
}
[[ "${LUCI_PACKAGE_FILE##*/}" == "$luci_name" ]] || {
    printf 'FAIL: remote resolver did not select noarch LuCI package\n' >&2
    exit 1
}
[[ "${CHECKSUMS_FILE##*/}" == SHA256SUMS ]] || {
    printf 'FAIL: remote resolver did not download shared SHA256SUMS\n' >&2
    exit 1
}
verify_checksum >/dev/null
verify_luci_checksum >/dev/null
cleanup
TMP_DIR=''

# Generic-ISA IPKs require an explicit compatibility check before opkg is
# allowed to bypass its exact OpenWrt architecture label.
PACKAGE_ISA=aarch64
ARCH=aarch64_cortex-a53
MOCK_PACKAGE_ARCH=aarch64
# shellcheck disable=SC2329 # Called indirectly by validate_core_package_arch.
core_package_arch() { printf '%s\n' "$MOCK_PACKAGE_ARCH"; }
validate_core_package_arch
MOCK_PACKAGE_ARCH=mips
if (validate_core_package_arch >/dev/null 2>&1); then
    printf 'FAIL: incompatible generic-ISA package was accepted\n' >&2
    exit 1
fi
MOCK_PACKAGE_ARCH=aarch64
OPKG_ARGS=''
opkg() { OPKG_ARGS="$*"; }
PM=opkg
PACKAGE_FILE=/tmp/tg-ws-proxy_aarch64.ipk
install_package
[[ "$OPKG_ARGS" == "--force-architecture install $PACKAGE_FILE" ]] || {
    printf 'FAIL: opkg generic-ISA install did not use --force-architecture\n' >&2
    exit 1
}

printf '%s\n' '[{"tag_name":"v2.2.2","prerelease":false},{"tag_name":"v2.2.3-beta.2","prerelease":true},{"tag_name":"v2.2.3-beta.1","prerelease":true}]' > "$tmp/releases.json"
[[ "$(latest_beta_tag "$tmp/releases.json")" == 'v2.2.3-beta.2' ]] || {
    printf 'FAIL: latest beta tag was not selected\n' >&2
    exit 1
}

declare -a EVENTS=()
warn() { EVENTS+=("warn:$*"); }
service_control() { EVENTS+=("service:$*"); }
remove_core_package() { EVENTS+=("remove:core"); }
remove_luci_package() { EVENTS+=("remove:luci"); }
restore_core_backup_files() { EVENTS+=("restore:core-files"); }
restore_luci_backup_files() { EVENTS+=("restore:luci-files"); }
restore_config_backup() { EVENTS+=("restore:config"); }
restore_service_state() { EVENTS+=("restore:service-state"); }

has_event() {
    local expected="$1" event
    for event in "${EVENTS[@]-}"; do [[ "$event" == "$expected" ]] && return 0; done
    return 1
}

# shellcheck disable=SC2034 # Values are consumed by functions sourced from install.sh.
BACKUP_DIR=/tmp/test-backup
OLD_PACKAGE=1
OLD_LUCI_PACKAGE=1
EVENTS=()
rollback
has_event 'restore:config' || { printf 'FAIL: package upgrade recovery did not restore UCI\n' >&2; exit 1; }
has_event 'restore:service-state' || { printf 'FAIL: package upgrade recovery did not restore service state\n' >&2; exit 1; }
if has_event 'restore:core-files' || has_event 'restore:luci-files' || has_event 'remove:core' || has_event 'remove:luci'; then
    printf 'FAIL: package upgrade recovery desynchronizes package files from package database\n' >&2
    exit 1
fi

OLD_PACKAGE=0
OLD_LUCI_PACKAGE=0
EVENTS=()
rollback
for expected in 'remove:core' 'remove:luci' 'restore:core-files' 'restore:luci-files' 'restore:service-state'; do
    has_event "$expected" || { printf 'FAIL: fresh/manual recovery misses %s\n' "$expected" >&2; exit 1; }
done

printf 'PASS: installer contract\n'
