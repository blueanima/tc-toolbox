#!/bin/sh
# Fetch the NetBSD 7 source tree as a single tarball from GitHub codeload.
# codeload does NOT honour HTTP Range (it returns the full stream), and the
# git pack protocol triggers an intermittent GnuTLS decode error in this
# environment, so a plain single GET of the tarball is the most reliable path.
# The connection is stable (only slow ~100-300 KB/s), so a long max-time lets
# it finish in one shot. Idempotent: skips if the tree is already extracted.
set -e

URL="https://codeload.github.com/NetBSD/src/tar.gz/refs/heads/netbsd-7"
DEST="/buildroot/netbsd7"
TGZ="$DEST/src-netbsd-7.tar.gz"
SRC="$DEST/usr/src"

if [ -f "$SRC/build.sh" ]; then
    echo "src already present at $SRC; skipping download"
    exit 0
fi

mkdir -p "$DEST"

for attempt in 1 2 3 4 5; do
    echo "=== attempt $attempt: downloading tarball (single GET, max 3h) ==="
    if curl -fsSL --retry 3 --retry-delay 10 --retry-all-errors \
            -o "$TGZ" --max-time 10800 "$URL"; then
        echo "download finished"
        break
    fi
    echo "attempt $attempt failed; cleaning and retrying"
    rm -f "$TGZ"
done

if [ ! -s "$TGZ" ]; then
    echo "FATAL: could not download source tarball"
    exit 1
fi

echo "=== verifying gzip ==="
if ! gzip -t "$TGZ" 2>/dev/null; then
    echo "FATAL: downloaded file is not a valid gzip archive"
    ls -l "$TGZ"
    exit 1
fi

echo "=== extracting to $DEST ==="
rm -rf "$SRC"
mkdir -p "$DEST"
tar xzf "$TGZ" -C "$DEST"
d=$(ls -d "$DEST"/src-netbsd-7-* 2>/dev/null | head -1)
if [ -z "$d" ]; then
    echo "FATAL: unexpected tarball top-level directory"
    ls -la "$DEST"
    exit 1
fi
mv "$d" "$SRC"
rm -f "$TGZ"

if [ ! -f "$SRC/build.sh" ]; then
    echo "FATAL: build.sh not found after extraction"
    exit 1
fi
echo "=== src ready at $SRC ==="
echo "SRC_DONE"
