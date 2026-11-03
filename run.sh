#!/bin/sh
# Host launcher: build the Docker image and run the cross-build container.
#
# Self-contained: it mounts the repo's ./build (env.sh + config.guess/config.sub)
# into the container as /work and /buildroot respectively, so the NetBSD 7 SDK
# build works WITHOUT the external TimeCapsuleSMB project. All build artifacts
# persist under ./buildroot (host bind mount) and the tc_wb volume (case-sensitive
# container-local tree where NetBSD src/obj/sysroot live).
#
# By default only the 48 core utilities are built. Set EXTRA=1 to ALSO build
# nc / diff / od / hexdump (which are missing from the curated netbsd-7 tree).
#
# Usage:
#   ./run.sh            # build the 48 core static binaries
#   EXTRA=1 ./run.sh    # build core + nc/diff/od/hexdump
set -e
IMG=tcbuild
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
BUILDROOT="$SCRIPT_DIR/buildroot"
mkdir -p "$BUILDROOT"

echo "==> building docker image $IMG"
docker build -t "$IMG" "$SCRIPT_DIR" >>"$BUILDROOT/build.log" 2>&1

echo "==> ensure persistent case-sensitive build volume"
docker volume create tc_wb >/dev/null 2>&1 || true

# fetch_src.sh downloads the NetBSD 7 tarball (idempotent: skips if already
# extracted). build_toolbox.sh builds the toolchain + 48 core static utils.
# With EXTRA=1, build_extra.sh additionally builds nc/diff/od/hexdump.
CMD='sh /fetch_src.sh && sh /build_toolbox.sh'
if [ "${EXTRA:-0}" = "1" ]; then
    CMD="$CMD && sh /build_extra.sh"
fi

echo "==> running container (logs -> $BUILDROOT/build.log)"
# Optional outbound proxy: pass -e http_proxy=... -e https_proxy=... at run time
# if your build environment requires one; the image otherwise uses direct egress.
docker run --rm \
  -v "$BUILDROOT:/buildroot" \
  -v "tc_wb:/wb-build" \
  -v "$SCRIPT_DIR/build:/work:ro" \
  -v "$SCRIPT_DIR/build/config.guess:/buildroot/config.guess:ro" \
  -v "$SCRIPT_DIR/build/config.sub:/buildroot/config.sub:ro" \
  -v "$SCRIPT_DIR/build_toolbox.sh:/build_toolbox.sh:ro" \
  -v "$SCRIPT_DIR/fetch_src.sh:/fetch_src.sh:ro" \
  -v "$SCRIPT_DIR/build_extra.sh:/build_extra.sh:ro" \
  "$IMG" sh -c "$CMD" >>"$BUILDROOT/build.log" 2>&1

echo "==> container finished; staged binaries at $BUILDROOT/stage/bin"
echo "    (copy them into ./bin with: cp buildroot/stage/bin/* bin/)"
