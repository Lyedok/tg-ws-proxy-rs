#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_file() {
    [[ -f "$1" ]] || fail "missing file: ${1#"$ROOT"/}"
}

assert_contains() {
    local file="$1" pattern="$2"
    grep -Eq -- "$pattern" "$file" || fail "${file#"$ROOT"/} does not match: $pattern"
}

assert_file "$ROOT/openwrt/Makefile"
assert_file "$ROOT/openwrt/build-package.sh"
assert_file "$ROOT/openwrt/files/tg-ws-proxy.config"
assert_file "$ROOT/openwrt/files/tg-ws-proxy.init"
assert_file "$ROOT/install.sh"
assert_file "$ROOT/openwrt/release-architectures.tsv"
assert_file "$ROOT/.github/workflows/release.yml"

map_file="$ROOT/openwrt/release-architectures.tsv"
map_count="$(grep -Ec -v '^[[:space:]]*(#|$)' "$map_file")"
[[ "$map_count" -eq 5 ]] || fail "release architecture map must contain exactly 5 real CPU ISAs"
for mapping in \
    $'aarch64-unknown-linux-musl\taarch64' \
    $'armv7-unknown-linux-musleabihf\tarmv7' \
    $'mips-unknown-linux-musl\tmips' \
    $'mipsel-unknown-linux-musl\tmipsel' \
    $'x86_64-unknown-linux-musl\tx86_64'; do
    grep -Fxq "$mapping" "$map_file" || fail "release architecture map misses: $mapping"
done

release_workflow="$ROOT/.github/workflows/release.yml"
assert_contains "$release_workflow" 'sha256sum -- \*\.apk \*\.ipk > SHA256SUMS'
assert_contains "$release_workflow" 'gh release upload.*dist/openwrt/\*'
if grep -Eq 'tg-ws-proxy-openwrt-.*tar\.gz|tar .*openwrt.*bundle' "$release_workflow"; then
    fail "release workflow must publish direct ISA packages, not bundle archives"
fi

cargo_version="$(python3 -c 'import tomllib,sys; print(tomllib.load(open(sys.argv[1], "rb"))["package"]["version"])' "$ROOT/Cargo.toml")"
package_version="$(sed -n 's/^PKG_VERSION:=//p' "$ROOT/openwrt/Makefile")"
[[ -n "$package_version" ]] || fail "PKG_VERSION is missing"
[[ "$cargo_version" == "$package_version" ]] || fail "Cargo version $cargo_version != package version $package_version"

assert_contains "$ROOT/openwrt/Makefile" '^PKG_NAME:=tg-ws-proxy$'
assert_contains "$ROOT/openwrt/Makefile" '^PKG_RELEASE:=[0-9]+$'
assert_contains "$ROOT/openwrt/Makefile" '/etc/config/tg-ws-proxy'
assert_contains "$ROOT/openwrt/Makefile" '/etc/init.d/tg-ws-proxy'
assert_contains "$ROOT/openwrt/Makefile" '/usr/bin/tg-ws-proxy'

for option in enabled host port secret link_ip listen_faketls_domain outbound_proxy; do
    assert_contains "$ROOT/openwrt/files/tg-ws-proxy.config" "option ${option} "
done
assert_contains "$ROOT/openwrt/files/tg-ws-proxy.config" "list dc_ip "
assert_contains "$ROOT/openwrt/files/tg-ws-proxy.config" "list cf_worker_domain "

"$ROOT/openwrt/build-package.sh" --help >/dev/null
"$ROOT/openwrt/build-package.sh" --help | grep -Fq -- '--prerelease' || {
    printf 'FAIL: package builder cannot encode beta package versions\n' >&2
    exit 1
}
"$ROOT/install.sh" --help >/dev/null

printf 'PASS: package contract\n'
