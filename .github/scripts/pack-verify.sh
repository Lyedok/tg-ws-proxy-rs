#!/usr/bin/env bash
#
# Pack a release binary with UPX and prove the packed result still runs.
#
#   pack-verify.sh <binary> <qemu-binary|none>
#
# Shared by release.yml and release-dryrun.yml so the release path and the
# rehearsal cannot drift apart.
#
# `upx -t` only proves the payload round-trips. The failure that actually
# reaches users is a stub that packs cleanly and then dies on the target ABI,
# so the binary is executed for real -- before packing as well, because
# otherwise a broken emulator looks exactly like a passing check.
#
# `none` skips the execution checks and says so. It is used for the mips targets
# in release.yml: those binaries are dynamically linked, so running them needs a
# sysroot assembled from a container image, and that is too many moving parts to
# put in the path of a public release. release-dryrun.yml does run them, on the
# same artifact through the same UPX invocation, and is the gate for this.
set -euo pipefail

BIN="$1"
QEMU="$2"
OUT="$(mktemp -d)"

test -f "$BIN"

check_runs() {
    if [[ "$QEMU" == none ]]; then
        return 0
    fi
    # Not piped into grep: with `set -o pipefail` a short-circuiting `grep -q`
    # can take the producer down with SIGPIPE and fail the step spuriously.
    "$QEMU" "$BIN" --help > "${OUT}/$1.txt"
    grep -q "Usage: tg-ws-proxy" "${OUT}/$1.txt"
}

if [[ "$QEMU" == none ]]; then
    echo "::notice::${BIN}: execution check skipped, verification is upx -t only"
fi

check_runs plain
BEFORE="$(stat -c %s "$BIN")"

upx -9 --lzma "$BIN"
upx -t "$BIN"

check_runs packed
AFTER="$(stat -c %s "$BIN")"

echo "${BIN}: ${BEFORE} -> ${AFTER} bytes on flash"
