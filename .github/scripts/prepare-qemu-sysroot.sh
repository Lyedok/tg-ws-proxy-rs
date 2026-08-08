#!/usr/bin/env bash
#
# Assemble the minimal sysroot qemu-user needs to run a dynamically linked
# target binary, taking the libraries out of the cross image that built it.
#
#   prepare-qemu-sysroot.sh <binary> <cross-image> <outdir>
#
# Prints the sysroot path on stdout (empty for a static binary); everything else
# goes to stderr, so the caller can do:
#
#   PREFIX="$(prepare-qemu-sysroot.sh "$BIN" "$IMAGE" "$PWD/sysroot")"
#   QEMU_LD_PREFIX="$PREFIX" pack-verify.sh "$BIN" qemu-mipsel-static
#
# The mips musl targets are not statically linked: crt-static is not their
# default, and it cannot simply be switched on because the cross image's
# mipsel-linux-muslsf-gcc ships no static CRT objects. They need musl's loader
# and libgcc_s.so.1 -- the unwinder -- present at runtime. No Ubuntu package
# provides either for a mips ABI, so they come out of the cross image.
#
# Files are placed at the exact paths the guest asks for rather than copying a
# whole sysroot, because the image's toolchain layout is not something to guess
# at.
set -euo pipefail

BIN="$1"
IMAGE="$2"
OUT="$3"

INTERP="$(readelf -l "$BIN" | sed -n 's/.*interpreter: \([^]]*\)\].*/\1/p')"
mapfile -t NEEDED < <(readelf -d "$BIN" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p')

if [[ -z "$INTERP" && ${#NEEDED[@]} -eq 0 ]]; then
    echo "$BIN is statically linked; no sysroot needed" >&2
    exit 0
fi

echo "PT_INTERP: ${INTERP:-none}" >&2
echo "DT_NEEDED: ${NEEDED[*]:-none}" >&2

docker pull -q "$IMAGE" >&2

# `cat` rather than `find -type f`: inside a sysroot these are usually symlinks,
# which -type f would skip.
fetch() {
    local name="$1" dest="${OUT}$2"
    mkdir -p "$(dirname "$dest")"
    docker run --rm --entrypoint sh "$IMAGE" -c \
        "find / -name '${name}' 2>/dev/null | head -n 1 | xargs -r cat" > "${dest}.part"
    if [[ ! -s "${dest}.part" ]]; then
        echo "::error::${name} not found inside ${IMAGE}" >&2
        exit 1
    fi
    mv "${dest}.part" "$dest"
    chmod 0755 "$dest"
    echo "  ${name} -> ${dest} ($(stat -c %s "$dest") bytes)" >&2
}

if [[ -n "$INTERP" ]]; then
    fetch "$(basename "$INTERP")" "$INTERP"
fi

for lib in "${NEEDED[@]}"; do
    # For musl, libc.so *is* the loader, already fetched above.
    if [[ "$lib" == libc.so ]]; then
        continue
    fi
    fetch "$lib" "/lib/${lib}"
done

echo "$OUT"
