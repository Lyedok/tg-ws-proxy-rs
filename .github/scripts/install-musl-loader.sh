#!/usr/bin/env bash
#
# Make a dynamically linked musl binary runnable under qemu-user on the runner.
#
#   install-musl-loader.sh <binary> <cross-image>
#
# qemu-user resolves the binary's ELF interpreter at the exact absolute path in
# PT_INTERP, and the mips musl targets are dynamically linked against
# /lib/ld-musl-mips*-sf.so.1 (see release.yml for why that cannot just be turned
# off). No Ubuntu package ships a mips musl loader, so take it from the same
# cross image that produced the binary. For musl the loader *is* libc, so this
# one file is the entire dependency.
#
# A statically linked binary needs none of this and is left alone, so the same
# step is safe to run for every target.
set -euo pipefail

BIN="$1"
IMAGE="$2"

INTERP="$(readelf -l "$BIN" | sed -n 's/.*interpreter: \([^]]*\)\].*/\1/p')"
if [[ -z "$INTERP" ]]; then
    echo "$BIN is statically linked; no loader needed"
    exit 0
fi
echo "PT_INTERP: $INTERP"

docker pull -q "$IMAGE"
# `cat` rather than `find -type f` on purpose: inside a sysroot the loader is
# usually a symlink to libc.so, which -type f would skip.
docker run --rm --entrypoint sh "$IMAGE" -c \
    "find / -name '$(basename "$INTERP")' 2>/dev/null | head -n 1 | xargs -r cat" > loader.bin

if [[ ! -s loader.bin ]]; then
    echo "::error::could not find $(basename "$INTERP") inside $IMAGE"
    exit 1
fi

sudo install -D -m 0755 loader.bin "$INTERP"
echo "installed $(stat -c %s loader.bin) bytes at $INTERP"
