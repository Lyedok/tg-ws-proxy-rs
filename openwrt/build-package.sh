#!/usr/bin/env bash
# Build standalone OpenWrt APK/IPK packages around a prebuilt static binary.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENWRT_DIR="$ROOT/openwrt"
LUCI_DIR="$OPENWRT_DIR/luci-app"
OUTPUT_DIR="$ROOT/dist/openwrt"
FORMAT=both
BINARY=""
APK_ARCH=""
IPK_ARCH=""
APK_TOOL="${APK_TOOL:-}"
IPKG_BUILD="${IPKG_BUILD:-}"
APK_SIGN_KEY="${APK_SIGN_KEY:-}"
PRERELEASE=""
FAKEROOT="${FAKEROOT:-}"
FAKEROOT_STAGING_DIR_HOST=""

usage() {
    cat <<'EOF'
Usage: openwrt/build-package.sh --binary PATH [options]

Required:
  --binary PATH              Static tg-ws-proxy binary to package

Options:
  --format apk|ipk|both      Package formats (default: both)
  --apk-arch ARCH            Core APK ABI, e.g. aarch64_cortex-a53
  --ipk-arch ARCH            IPK ABI, e.g. aarch64_cortex-a53
  --output DIR               Output directory (default: dist/openwrt)
  --apk-tool PATH            apk-tools 3.x executable with `mkpkg`
  --ipkg-build PATH          OpenWrt ipkg-build script
  --sign-key PATH            Optional APK private signing key
  --prerelease beta.N        Encode a format-native beta package version
  -h, --help                 Show this help

Tool paths may also be supplied through APK_TOOL, IPKG_BUILD,
APK_SIGN_KEY, and OPENWRT_SDK environment variables.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary) BINARY="${2-}"; shift 2;;
        --format) FORMAT="${2-}"; shift 2;;
        --apk-arch) APK_ARCH="${2-}"; shift 2;;
        --ipk-arch) IPK_ARCH="${2-}"; shift 2;;
        --output) OUTPUT_DIR="${2-}"; shift 2;;
        --apk-tool) APK_TOOL="${2-}"; shift 2;;
        --ipkg-build) IPKG_BUILD="${2-}"; shift 2;;
        --sign-key) APK_SIGN_KEY="${2-}"; shift 2;;
        --prerelease) PRERELEASE="${2-}"; shift 2;;
        -h|--help) usage; exit 0;;
        *) die "unknown argument: $1";;
    esac
done

[[ "$FORMAT" == apk || "$FORMAT" == ipk || "$FORMAT" == both ]] || die "invalid format: $FORMAT"
[[ -z "$PRERELEASE" || "$PRERELEASE" =~ ^beta\.[1-9][0-9]*$ ]] || \
    die "invalid prerelease: $PRERELEASE"
[[ -n "$BINARY" ]] || die "--binary is required"
[[ -f "$BINARY" && -x "$BINARY" ]] || die "binary is missing or not executable: $BINARY"

cargo_version="$(python3 -c 'import tomllib,sys; print(tomllib.load(open(sys.argv[1], "rb"))["package"]["version"])' "$ROOT/Cargo.toml")"
package_version="$(sed -n 's/^PKG_VERSION:=//p' "$OPENWRT_DIR/Makefile")"
package_release="$(sed -n 's/^PKG_RELEASE:=//p' "$OPENWRT_DIR/Makefile")"
luci_version="$(sed -n 's/^PKG_VERSION:=//p' "$LUCI_DIR/Makefile")"
luci_release="$(sed -n 's/^PKG_RELEASE:=//p' "$LUCI_DIR/Makefile")"
[[ -n "$package_version" && -n "$package_release" ]] || die "package version metadata is incomplete"
[[ "$cargo_version" == "$package_version" ]] || die "Cargo version $cargo_version != OpenWrt package version $package_version"
[[ "$cargo_version" == "$luci_version" ]] || die "Cargo version $cargo_version != LuCI package version $luci_version"
[[ "$package_release" == "$luci_release" ]] || die "core release $package_release != LuCI release $luci_release"
if [[ -n "$PRERELEASE" ]]; then
    beta_number="${PRERELEASE#beta.}"
    apk_full_version="${package_version}_beta${beta_number}-r${package_release}"
    ipk_full_version="${package_version}~${PRERELEASE}-r${package_release}"
    # GitHub Release replaces '~' in asset names with '.', which otherwise
    # leaves downloaded checksum sidecars pointing at a nonexistent filename.
    # Keep '~beta' inside the IPK metadata for correct opkg ordering, but use a
    # GitHub-safe artifact filename which will survive upload unchanged.
    ipk_filename_version="${package_version}.${PRERELEASE}-r${package_release}"
else
    apk_full_version="${package_version}-r${package_release}"
    ipk_full_version="$apk_full_version"
    ipk_filename_version="$ipk_full_version"
fi

if [[ "$FORMAT" == apk || "$FORMAT" == both ]]; then
    [[ -n "$APK_ARCH" ]] || die "--apk-arch is required for APK output"
    if [[ -z "$APK_TOOL" && -n "${OPENWRT_SDK:-}" ]]; then
        APK_TOOL="$OPENWRT_SDK/staging_dir/host/bin/apk"
    fi
    if [[ -z "$APK_TOOL" ]]; then APK_TOOL="$(command -v apk || true)"; fi
    [[ -x "$APK_TOOL" ]] || die "apk tool not found; use --apk-tool or OPENWRT_SDK"
fi

if [[ "$FORMAT" == ipk || "$FORMAT" == both ]]; then
    [[ -n "$IPK_ARCH" ]] || die "--ipk-arch is required for IPK output"
    if [[ -z "$IPKG_BUILD" && -n "${OPENWRT_SDK:-}" ]]; then
        IPKG_BUILD="$OPENWRT_SDK/scripts/ipkg-build"
    fi
    if [[ -z "$IPKG_BUILD" ]]; then IPKG_BUILD="$(command -v ipkg-build || true)"; fi
    [[ -x "$IPKG_BUILD" ]] || die "ipkg-build not found; use --ipkg-build or OPENWRT_SDK"
fi

if [[ -z "$FAKEROOT" && -n "${OPENWRT_SDK:-}" ]]; then
    FAKEROOT="$OPENWRT_SDK/staging_dir/host/bin/fakeroot"
    FAKEROOT_STAGING_DIR_HOST="$OPENWRT_SDK/staging_dir/host"
fi
if [[ -z "$FAKEROOT" ]]; then FAKEROOT="$(command -v fakeroot || true)"; fi
[[ -x "$FAKEROOT" ]] || die "fakeroot not found; package payload ownership cannot be normalized"

if [[ -n "$APK_SIGN_KEY" ]]; then
    [[ -f "$APK_SIGN_KEY" ]] || die "APK signing key not found: $APK_SIGN_KEY"
fi

binary_kind="$(file -b "$BINARY")"
[[ "$binary_kind" == *ELF* ]] || die "binary is not ELF: $binary_kind"
if readelf -d "$BINARY" 2>/dev/null | grep -q NEEDED; then
    die "binary has dynamic dependencies; OpenWrt package requires a static ELF"
fi

mkdir -p "$OUTPUT_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
artifacts=()
ROOT_TAR="$tmp/tar-root-owner"
HOST_TAR="$(command -v tar)"
cat > "$ROOT_TAR" <<EOF
#!/bin/sh
exec "$HOST_TAR" --owner=0 --group=0 "\$@"
EOF
chmod 0755 "$ROOT_TAR"

stage_payload() {
    local stage="$1"
    mkdir -p "$stage/usr/bin" "$stage/etc/config" "$stage/etc/init.d" "$stage/lib/upgrade/keep.d"
    install -m 0755 "$BINARY" "$stage/usr/bin/tg-ws-proxy"
    install -m 0600 "$OPENWRT_DIR/files/tg-ws-proxy.config" "$stage/etc/config/tg-ws-proxy"
    install -m 0755 "$OPENWRT_DIR/files/tg-ws-proxy.init" "$stage/etc/init.d/tg-ws-proxy"
    printf '/etc/config/tg-ws-proxy\n' > "$stage/lib/upgrade/keep.d/tg-ws-proxy"
    chmod 0644 "$stage/lib/upgrade/keep.d/tg-ws-proxy"
}

stage_luci_payload() {
    local stage="$1"
    [[ -d "$LUCI_DIR/htdocs" && -d "$LUCI_DIR/root" ]] || die "LuCI package payload is incomplete"
    mkdir -p "$stage/www"
    cp -a "$LUCI_DIR/htdocs/." "$stage/www/"
    cp -a "$LUCI_DIR/root/." "$stage/"
    chmod 0755 "$stage/etc/uci-defaults/95_luci-tg-ws-proxy"
}

run_with_root_ownership() {
    local stage="$1"
    shift
    # shellcheck disable=SC2016 # Variables expand in the inner fakeroot shell, not here.
    local fake_script='
        stage="$1"
        shift
        chown -R 0:0 "$stage"
        exec "$@"
    '
    if [[ -n "$FAKEROOT_STAGING_DIR_HOST" ]]; then
        STAGING_DIR_HOST="$FAKEROOT_STAGING_DIR_HOST" \
            "$FAKEROOT" -- sh -c "$fake_script" sh "$stage" "$@"
    else
        "$FAKEROOT" -- sh -c "$fake_script" sh "$stage" "$@"
    fi
}

build_apk() {
    local stage="$tmp/apk-root"
    local scripts="$tmp/apk-scripts"
    local output="$OUTPUT_DIR/tg-ws-proxy_${apk_full_version}_${APK_ARCH}.apk"
    stage_payload "$stage"
    mkdir -p "$stage/lib/apk/packages" "$scripts"

    (
        cd "$stage"
        find . \( -type f -o -type l \) -printf '/%P\n' | LC_ALL=C sort > "lib/apk/packages/tg-ws-proxy.list"
    )
    printf '/etc/config/tg-ws-proxy\n' > "$stage/lib/apk/packages/tg-ws-proxy.conffiles"
    (
        cd "$stage"
        sha256sum etc/config/tg-ws-proxy > "lib/apk/packages/tg-ws-proxy.conffiles_static"
    )

    cat > "$scripts/post-install" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT:-}" = "1" ] && exit 0
[ -s "${IPKG_INSTROOT:-}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT:-}/lib/functions.sh"
export root="${IPKG_INSTROOT:-}"
export pkgname="tg-ws-proxy"
add_group_and_user
default_postinst
EOF
    cat > "$scripts/post-upgrade" <<'EOF'
#!/bin/sh
export PKG_UPGRADE=1
[ "${IPKG_NO_SCRIPT:-}" = "1" ] && exit 0
[ -s "${IPKG_INSTROOT:-}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT:-}/lib/functions.sh"
export root="${IPKG_INSTROOT:-}"
export pkgname="tg-ws-proxy"
add_group_and_user
default_postinst
EOF
    cat > "$scripts/pre-deinstall" <<'EOF'
#!/bin/sh
[ -s "${IPKG_INSTROOT:-}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT:-}/lib/functions.sh"
export root="${IPKG_INSTROOT:-}"
export pkgname="tg-ws-proxy"
default_prerm
EOF
    chmod 0755 "$scripts"/*

    apk_args=(
        mkpkg
        --info "name:tg-ws-proxy"
        --info "version:$apk_full_version"
        --info "description:Telegram MTProto WebSocket bridge proxy"
        --info "arch:$APK_ARCH"
        --info "origin:tg-ws-proxy"
        --info "url:https://github.com/valnesfjord/tg-ws-proxy-rs"
        --info "maintainer:Lyedok"
        --info "license:MIT"
        --script "post-install:$scripts/post-install"
        --script "post-upgrade:$scripts/post-upgrade"
        --script "pre-deinstall:$scripts/pre-deinstall"
        --files "$stage"
        --output "$output"
    )
    if [[ -n "$APK_SIGN_KEY" ]]; then
        apk_args+=(--sign-key "$APK_SIGN_KEY")
    fi
    run_with_root_ownership "$stage" "$APK_TOOL" "${apk_args[@]}"
    artifacts+=("$output")
}

build_luci_apk() {
    local stage="$tmp/luci-apk-root"
    local scripts="$tmp/luci-apk-scripts"
    local output="$OUTPUT_DIR/luci-app-tg-ws-proxy_${apk_full_version}_noarch.apk"
    stage_luci_payload "$stage"
    mkdir -p "$stage/lib/apk/packages" "$scripts"

    (
        cd "$stage"
        find . \( -type f -o -type l \) -printf '/%P\n' | LC_ALL=C sort > \
            "lib/apk/packages/luci-app-tg-ws-proxy.list"
    )

    cat > "$scripts/post-install" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT:-}" = "1" ] && exit 0
[ -s "${IPKG_INSTROOT:-}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT:-}/lib/functions.sh"
export root="${IPKG_INSTROOT:-}"
export pkgname="luci-app-tg-ws-proxy"
default_postinst
EOF
    cat > "$scripts/post-upgrade" <<'EOF'
#!/bin/sh
export PKG_UPGRADE=1
[ "${IPKG_NO_SCRIPT:-}" = "1" ] && exit 0
[ -s "${IPKG_INSTROOT:-}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT:-}/lib/functions.sh"
export root="${IPKG_INSTROOT:-}"
export pkgname="luci-app-tg-ws-proxy"
default_postinst
EOF
    cat > "$scripts/pre-deinstall" <<'EOF'
#!/bin/sh
[ -s "${IPKG_INSTROOT:-}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT:-}/lib/functions.sh"
export root="${IPKG_INSTROOT:-}"
export pkgname="luci-app-tg-ws-proxy"
default_prerm
EOF
    chmod 0755 "$scripts"/*

    luci_apk_args=(
        mkpkg
        --info "name:luci-app-tg-ws-proxy"
        --info "version:$apk_full_version"
        --info "description:LuCI support for tg-ws-proxy"
        --info "arch:noarch"
        --info "origin:luci-app-tg-ws-proxy"
        --info "url:https://github.com/valnesfjord/tg-ws-proxy-rs"
        --info "maintainer:Lyedok"
        --info "license:MIT"
        --info "depends:tg-ws-proxy luci-base"
        --script "post-install:$scripts/post-install"
        --script "post-upgrade:$scripts/post-upgrade"
        --script "pre-deinstall:$scripts/pre-deinstall"
        --files "$stage"
        --output "$output"
    )
    if [[ -n "$APK_SIGN_KEY" ]]; then
        luci_apk_args+=(--sign-key "$APK_SIGN_KEY")
    fi
    run_with_root_ownership "$stage" "$APK_TOOL" "${luci_apk_args[@]}"
    artifacts+=("$output")
}

build_ipk() {
    local stage="$tmp/ipk-root"
    local build_out="$tmp/ipk-output"
    local output="$OUTPUT_DIR/tg-ws-proxy_${ipk_filename_version}_${IPK_ARCH}.ipk"
    stage_payload "$stage"
    mkdir -p "$stage/CONTROL" "$build_out"

    cat > "$stage/CONTROL/control" <<EOF
Package: tg-ws-proxy
Version: $ipk_full_version
Source: https://github.com/valnesfjord/tg-ws-proxy-rs
SourceName: tg-ws-proxy
Section: net
Architecture: $IPK_ARCH
Maintainer: Lyedok
License: MIT
Installed-Size: TO-BE-FILLED-BY-IPKG-BUILD
Description: Telegram MTProto WebSocket bridge proxy
 A low-memory MTProto proxy with WebSocket, FakeTLS, Cloudflare,
 MTProto-proxy, and HTTP/SOCKS outbound fallback support.
EOF
    printf '/etc/config/tg-ws-proxy\n' > "$stage/CONTROL/conffiles"
    cat > "$stage/CONTROL/postinst" <<'EOF'
#!/bin/sh
[ -s "${IPKG_INSTROOT:-}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT:-}/lib/functions.sh"
default_postinst "$0" "$@"
EOF
    cat > "$stage/CONTROL/prerm" <<'EOF'
#!/bin/sh
[ -s "${IPKG_INSTROOT:-}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT:-}/lib/functions.sh"
default_prerm "$0" "$@"
EOF
    chmod 0644 "$stage/CONTROL/control" "$stage/CONTROL/conffiles"
    chmod 0755 "$stage/CONTROL/postinst" "$stage/CONTROL/prerm"

    run_with_root_ownership "$stage" env TAR="$ROOT_TAR" \
        "$IPKG_BUILD" -m "" "$stage" "$build_out"
    built="$build_out/tg-ws-proxy_${ipk_full_version}_${IPK_ARCH}.ipk"
    [[ -f "$built" ]] || die "ipkg-build did not create the expected artifact"
    mv "$built" "$output"
    artifacts+=("$output")
}

build_luci_ipk() {
    local stage="$tmp/luci-ipk-root"
    local build_out="$tmp/luci-ipk-output"
    local output="$OUTPUT_DIR/luci-app-tg-ws-proxy_${ipk_filename_version}_all.ipk"
    stage_luci_payload "$stage"
    mkdir -p "$stage/CONTROL" "$build_out"

    cat > "$stage/CONTROL/control" <<EOF
Package: luci-app-tg-ws-proxy
Version: $ipk_full_version
Source: https://github.com/valnesfjord/tg-ws-proxy-rs
SourceName: luci-app-tg-ws-proxy
Section: luci
Architecture: all
Depends: tg-ws-proxy, luci-base
Maintainer: Lyedok
License: MIT
Installed-Size: TO-BE-FILLED-BY-IPKG-BUILD
Description: LuCI support for tg-ws-proxy
 Web configuration, service status and controls for tg-ws-proxy.
EOF
    cat > "$stage/CONTROL/postinst" <<'EOF'
#!/bin/sh
[ -s "${IPKG_INSTROOT:-}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT:-}/lib/functions.sh"
default_postinst "$0" "$@"
EOF
    cat > "$stage/CONTROL/prerm" <<'EOF'
#!/bin/sh
[ -s "${IPKG_INSTROOT:-}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT:-}/lib/functions.sh"
default_prerm "$0" "$@"
EOF
    chmod 0644 "$stage/CONTROL/control"
    chmod 0755 "$stage/CONTROL/postinst" "$stage/CONTROL/prerm"

    run_with_root_ownership "$stage" env TAR="$ROOT_TAR" \
        "$IPKG_BUILD" -m "" "$stage" "$build_out"
    built="$build_out/luci-app-tg-ws-proxy_${ipk_full_version}_all.ipk"
    [[ -f "$built" ]] || die "ipkg-build did not create the expected LuCI artifact"
    mv "$built" "$output"
    artifacts+=("$output")
}

case "$FORMAT" in
    apk) build_apk; build_luci_apk;;
    ipk) build_ipk; build_luci_ipk;;
    both) build_apk; build_luci_apk; build_ipk; build_luci_ipk;;
esac

: > "$OUTPUT_DIR/SHA256SUMS"
for artifact in "${artifacts[@]}"; do
    (
        cd "$OUTPUT_DIR"
        name="$(basename "$artifact")"
        sha256sum "$name" | tee -a SHA256SUMS > "$name.sha256"
    )
done

printf 'Built:\n'
printf '  %s\n' "${artifacts[@]}"
