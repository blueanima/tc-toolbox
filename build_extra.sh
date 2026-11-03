#!/bin/sh
# Build nc, diff, od that are missing from the curated netbsd-7 tree.
#   - nc: NetBSD 7 base has NO usr.bin/nc, so pull it from the netbsd-10 branch
#     (autoconf-free BSD Makefile, a few .c files) and cross-build statically.
#   - od: NetBSD 7 base has no od at all, but usr.bin/hexdump builds BOTH
#     hexdump and an od link (odsyntax.c switches on argv[0]); build hexdump
#     and copy the binary to od.
#   - diff: NetBSD 7 ships GNU diffutils at gnu/usr.bin/diffutils/diff.
# All are linked statically with the existing toolchain + sysroot.
# Results land in /buildroot/stage/bin (shared with the host for deploy.sh).
set -e

# Fallback toolchain triple, used only if ./build/env.sh is absent. run.sh mounts
# the repo's build/ as /work, so env.sh is normally present and overrides this.
select_tool_triple() { echo "armv4--netbsdelf-eabi"; }

export NETBSD7_ROOT=/wb-build/netbsd7
export NETBSD7_OUT=/wb-build/tc-earmv4-netbsd7
export SERVICE_STAGE_NETBSD7=/buildroot/stage
export HOST_CC=/usr/bin/gcc
export HOST_CXX=/usr/local/bin/g++
export HOST_CFLAGS="-O -fcommon -fgnu89-inline -Wno-error"
export HOST_CXXFLAGS="-O -fcommon -fgnu89-inline -Wno-error"
export HOST_CPPFLAGS="-D__GNUC_GNU_INLINE__ -D__STDC_WANT_LIB_EXT1__=1"
export CXXFLAGS="-std=gnu++14 -fcommon -Wno-error"
export NO_PTHREADS=1
export SDK_JOBS=12

# Source the SDK env (provides select_tool_triple + NetBSD7 defaults). It is
# mounted at /work/build/env.sh by run.sh; if it is missing we fall back to the
# built-in select_tool_triple above and the export defaults set below.
if cd /work 2>/dev/null; then
    # shellcheck disable=SC1091
    . ./build/env.sh 2>/dev/null || true
fi

SRC=/wb-build/src
OBJ=/wb-build/tc-earmv4-netbsd7/obj
TOOLS=/wb-build/tc-earmv4-netbsd7/tools
SYSROOT="$OBJ/destdir.evbarm"
export SRC OBJ TOOLS
TRIPLE="$(select_tool_triple)"
NBMAKE="$TOOLS/bin/nbmake-evbarm"
STRIP="$TOOLS/bin/$TRIPLE-strip"
OBJUMP="$TOOLS/bin/$TRIPLE-objdump"
export PATH="$TOOLS/bin:$PATH"
echo "TRIPLE=$TRIPLE"

# ------------------------------------------------------- fetch nc from netbsd-10
clone=/wb-build/netbsd-src-tmp
echo "=== prepare upstream clone (netbsd-7, no-checkout) ==="
if [ -d "$clone/.git" ]; then
    echo "reusing $clone"
else
    rm -rf "$clone"
    git clone --depth 1 --branch netbsd-7 --filter=blob:none --no-checkout \
        https://github.com/NetBSD/src.git "$clone" 2>&1 | tail -1
fi
cd "$clone"
echo "=== ensure netbsd-10 ref (for nc) ==="
git rev-parse -q --verify netbsd-10 >/dev/null 2>&1 || \
    git fetch origin netbsd-10:refs/heads/netbsd-10 --depth 1 2>&1 | tail -1
echo "=== checkout usr.bin/nc from netbsd-10 ==="
git checkout netbsd-10 -- usr.bin/nc 2>&1 | tail -2
if [ -d "usr.bin/nc" ] && [ -f "usr.bin/nc/Makefile" ]; then
    rm -rf "/wb-build/src/usr.bin/nc"
    cp -r "usr.bin/nc" "/wb-build/src/usr.bin/nc"
    echo "OK   copied usr.bin/nc -> $(ls /wb-build/src/usr.bin/nc | tr '\n' ' ')"
else
    echo "FAIL usr.bin/nc absent upstream"
fi

# ------------------------------------------------------- build_one
build_one() {
    name="$1"; sdir="$2"
    [ -n "$sdir" ] || { echo "SKIP  $name (no src)"; return; }
    echo "--- building $name ($sdir) ---"
    cd "$sdir"
    $NBMAKE obj >/dev/null 2>&1 || true
    if $NBMAKE LDSTATIC="-static" MKLINT=no MKPIC=no MKPROFILE=no MKDEBUG=no \
            MKRUMP=no MKINFO=no >"/buildroot/stage/log.$name" 2>&1; then
        rel="${sdir#$SRC/}"
        bin="$OBJ/$rel/$name"
        [ -x "$bin" ] || bin=$(find "$sdir" -type f -perm -u+x -name "$name" 2>/dev/null | head -1)
        if [ -n "$bin" ] && [ -x "$bin" ]; then
            $STRIP --strip-unneeded "$bin" 2>/dev/null || true
            cp "$bin" "/buildroot/stage/bin/$name"
            echo "OK    $name  ($(stat -c%s "/buildroot/stage/bin/$name") bytes)"
        else echo "FAIL  $name (binary not found)"; fi
    else echo "FAIL  $name (build error)"; tail -n 12 "/buildroot/stage/log.$name"; fi
}

build_one nc "$SRC/usr.bin/nc"
build_one hexdump "$SRC/usr.bin/hexdump"
[ -x "/buildroot/stage/bin/hexdump" ] && \
    cp "/buildroot/stage/bin/hexdump" "/buildroot/stage/bin/od" && \
    echo "OK    od  (alias of hexdump, $(stat -c%s /buildroot/stage/bin/od) bytes)"

# diff depends on libdiffutils.a, which is built by the parent Makefile's
# SUBDIR= lib .WAIT diff ... (building the diff subdir alone cannot find it).
echo "--- building diff (gnu/usr.bin/diffutils: lib + diff + diff3) ---"
cd "$SRC/gnu/usr.bin/diffutils"
$NBMAKE obj >/dev/null 2>&1 || true
if $NBMAKE LDSTATIC="-static" MKLINT=no MKPIC=no MKPROFILE=no MKDEBUG=no \
        MKRUMP=no MKINFO=no >"/buildroot/stage/log.diff" 2>&1; then
    bin="$OBJ/gnu/usr.bin/diffutils/diff/diff"
    [ -x "$bin" ] || bin=$(find "$SRC/gnu/usr.bin/diffutils/diff" -type f -perm -u+x -name diff 2>/dev/null | head -1)
    if [ -n "$bin" ] && [ -x "$bin" ]; then
        $STRIP --strip-unneeded "$bin" 2>/dev/null || true
        cp "$bin" "/buildroot/stage/bin/diff"
        echo "OK    diff  ($(stat -c%s "/buildroot/stage/bin/diff") bytes)"
    else echo "FAIL  diff (binary not found)"; fi
else echo "FAIL  diff (build error)"; tail -n 12 "/buildroot/stage/log.diff"; fi

# ------------------------------------------------------- static sanity
echo "=== static check ==="
for b in nc od diff; do
    f="/buildroot/stage/bin/$b"
    [ -f "$f" ] || { echo "MISSING: $b"; continue; }
    if $OBJUMP -p "$f" 2>/dev/null | grep -Eq '^[[:space:]]*(INTERP|DYNAMIC)'; then
        echo "NOT-STATIC: $b"
    else echo "STATIC: $b"; fi
done
echo "DONE_EXTRA"
