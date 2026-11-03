#!/bin/sh
# Build static NetBSD/evbarm utilities for the Time Capsule inside this Linux
# container. Reuses the TimeCapsuleSMB project's netbsd7 SDK (NetBSD 7 sources
# cross-compiled for the NetBSD 6.0 device).
#
# IMPORTANT: the *entire* build tree (src, tools, obj, sysroot) lives in
# /wb-build, which is a container-local (case-SENSITIVE) filesystem. The host
# bind-mount (/buildroot) is case-INsensitive APFS, and NetBSD's src tree has
# files that differ only by case -> extracting there would corrupt the build.
# Only the final staged binaries are written to /buildroot/stage (shared with
# the host so deploy.sh can scp them to the Time Capsule).
set -e

# Fallback toolchain triple, used only if ./build/env.sh is absent. run.sh mounts
# the repo's build/ as /work, so env.sh is normally present and overrides this.
select_tool_triple() { echo "armv4--netbsdelf-eabi"; }

# The container's host compiler is gcc-10 (see Dockerfile), whose default C++
# standard is gnu++03, so NetBSD 7's old sources build without the gcc-12 C++17
# breakage. We still force -fcommon (gcc-10 defaults to -fno-common) and
# -fgnu89-inline for the old code.
#
# --- overrides (set before sourcing env.sh; env.sh uses :- defaults) ---
export NETBSD7_ROOT=/wb-build/netbsd7
export NETBSD7_OUT=/wb-build/tc-earmv4-netbsd7
export SERVICE_STAGE_NETBSD7=/buildroot/stage
export HOST_CC=/usr/bin/gcc
# g++ is wrapped (see Dockerfile): the wrapper appends "-std=gnu++14 -fpermissive"
# so gcc-12's default gnu++17 no longer breaks NetBSD 7's old C++ sources.
export HOST_CXX=/usr/local/bin/g++
export HOST_CFLAGS="-O -fcommon -fgnu89-inline -Wno-error"
export HOST_CXXFLAGS="-O -fcommon -fgnu89-inline -Wno-error"
export HOST_CPPFLAGS="-D__GNUC_GNU_INLINE__ -D__STDC_WANT_LIB_EXT1__=1"
# gcc 4.8-era sources use 'bool++' which is forbidden under the C++17 default
# of the host g++-12; force gnu++14 (still permits it, compatible with gcc's
# own sources) for the gcc cross-compiler build.
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

# Re-point everything to the case-sensitive container-local tree.
SRC=/wb-build/src
OBJ=/wb-build/tc-earmv4-netbsd7/obj
TOOLS=/wb-build/tc-earmv4-netbsd7/tools
SYSROOT="$OBJ/destdir.evbarm"
export SRC OBJ TOOLS
TGZ=/buildroot/netbsd7/src-netbsd-7.tar.gz

echo "SRC=$SRC"
echo "OBJ=$OBJ"
echo "TOOLS=$TOOLS"
echo "SYSROOT=$SYSROOT"
echo "TGZ=$TGZ"

mkdir -p "$SERVICE_STAGE_NETBSD7/bin"

# ---------------------------------------------------------------- [1] src
echo "=== [1/4] prepare netbsd-7 src (tarball) ==="
if [ -f "$SRC/build.sh" ]; then
    echo "src already present at $SRC; skipping extract"
else
    if [ ! -s "$TGZ" ]; then
        echo "FATAL: $TGZ missing; download it on the host first" >&2
        exit 1
    fi
    echo "verifying gzip ..."
    gzip -t "$TGZ" || { echo "FATAL: $TGZ is not a valid gzip"; exit 1; }
    echo "extracting (case-sensitive /wb-build) ..."
    rm -rf /wb-build/src-netbsd-7* "$SRC"
    mkdir -p /wb-build
    tar xzf "$TGZ" -C /wb-build
    d=$(ls -d /wb-build/src-netbsd-7* 2>/dev/null | head -1)
    if [ -z "$d" ]; then
        echo "FATAL: unexpected tarball top-level dir"; ls -la /wb-build; exit 1
    fi
    mv "$d" "$SRC"
    if [ ! -f "$SRC/build.sh" ]; then
        echo "FATAL: build.sh not found after extract"; exit 1
    fi
    echo "src ready at $SRC"
fi

# ---------------------------------------------------------- [2] toolchain
echo "=== [2/4] build cross toolchain (tools) ==="
# Force a clean (re)configure of gcc ONLY when explicitly requested (e.g.
# after changing CXXFLAGS). On a normal resume the cross gcc is already built
# with the correct flags, so we keep it to avoid a long rebuild. Set
# FORCE_GCC_RECONF=1 in the environment to wipe and rebuild gcc.
if [ -n "$FORCE_GCC_RECONF" ]; then
    rm -rf "$OBJ/tools/gcc" 2>/dev/null || true
    echo "FORCE_GCC_RECONF set: removed $OBJ/tools/gcc for clean reconfigure"
fi
# gcc-12 cannot build the host 'texinfo' (and we don't need it or a cross
# gdb); drop them from the tools SUBDIR so the meta target doesn't abort.
mf="$SRC/tools/Makefile"
if [ -f "$mf" ]; then
    sed -i -E 's/(^|[[:space:]])(texinfo|gdb|groff)([[:space:]]|$)/\1\3/g' "$mf"
    echo "patched $mf: removed texinfo/gdb/groff from tools SUBDIR"
fi

# gmake's own Makefile hard-codes 'MAKE_ARGS= MAKEINFO=${TOOL_MAKEINFO:Q}',
# i.e. it always invokes the NetBSD-built 'nbmakeinfo' to generate its info
# manual. We dropped the texinfo tool above (gcc-12 can't build it, and we
# don't need it), so nbmakeinfo is absent and gmake's doc step fails with
# 'nbmakeinfo: not found' (exit 127), aborting the whole 'tools' target.
# Point MAKEINFO at /bin/true instead: the doc rule becomes a no-op (exit 0),
# and doc/Makefile.in's install-info-am silently skips the missing make.info
# (its loop does 'else : ;' and post-install uses '|| :'). This mirrors the
# existing 'BISON=true' idiom already used in Makefile.gnuhost.
gmf="$SRC/tools/gmake/Makefile"
if [ -f "$gmf" ]; then
    sed -i -E 's|MAKE_ARGS=[[:space:]]*MAKEINFO=\$\{TOOL_MAKEINFO:Q\}|MAKE_ARGS= MAKEINFO=/bin/true|' "$gmf"
    echo "patched $gmf: MAKEINFO -> /bin/true (skip gmake doc without texinfo)"
fi

# The NetBSD 7 src tree ships 2002-era config.guess/config.sub that cannot
# recognise aarch64 / Linux 7.x, so every autoconf host tool (gmake, gmp,
# mpfr, mpc, binutils, gcc) fails configure. Swap in modern ones.
CG=/buildroot/config.guess
CS=/buildroot/config.sub
if [ -f "$CG" ] && [ -f "$CS" ]; then
    echo "=== injecting modern config.guess/config.sub into src tree ==="
    ncg=$(find "$SRC" -name config.guess | wc -l)
    ncs=$(find "$SRC" -name config.sub | wc -l)
    find "$SRC" -name config.guess -exec cp -f "$CG" {} \;
    find "$SRC" -name config.sub -exec cp -f "$CS" {} \;
    echo "replaced $ncg config.guess, $ncs config.sub"
    # drop any stale configure caches from a prior failed run
    find "$OBJ" -name config.cache -delete 2>/dev/null || true
fi
cd "$SRC"
env HOST_CC="$HOST_CC" HOST_CXX="$HOST_CXX" HOST_CFLAGS="$HOST_CFLAGS" \
    HOST_CXXFLAGS="$HOST_CXXFLAGS" HOST_CPPFLAGS="$HOST_CPPFLAGS" \
    ./build.sh -U -u -j "$SDK_JOBS" -m evbarm -a earmv4 \
    -V NO_PTHREADS="$NO_PTHREADS" -O "$OBJ" -T "$TOOLS" tools

TRIPLE="$(select_tool_triple)"
NBMAKE="$TOOLS/bin/nbmake-evbarm"
STRIP="$TOOLS/bin/$TRIPLE-strip"
OBJUMP="$TOOLS/bin/$TRIPLE-objdump"
echo "TRIPLE=$TRIPLE"
# Make the cross tools visible to both nbmake and the raw 'make' we use below
# to build libgcc out of the gcc build tree.
export PATH="$TOOLS/bin:$PATH"

# ---------------------------------------------- [3] headers + static libs
echo "=== [3/4] sysroot hierarchy + headers + static libs ==="
# NetBSD 7's build.sh has no standalone 'includes'/'libs'/'headers' operation
# (only tools / distribution / release exist), so headers and libraries must be
# installed with nbmake directly. Two things the normal 'make build' flow does
# for us, which we must do by hand here:
#   1) The DESTDIR directory tree must already exist. The install tool does not
#      create subdirectories in METALOG mode, so we recreate the hierarchy from
#      the mtree specs (base + earm). We only need the dirs to exist as root,
#      which is fine for a cross sysroot.
#   2) Libraries must be built STATIC only (MKPIC=no): the shared .so link
#      fails to build under this setup and is unnecessary for static binaries.
MTREE_COMBINED="$OBJ/mtree-NetBSD.dist.combined"
cat "$SRC/etc/mtree/NetBSD.dist.base" "$SRC/etc/mtree/NetBSD.dist.earm" \
    > "$MTREE_COMBINED" 2>/dev/null || echo "WARN could not combine mtree specs"
if [ -f "$MTREE_COMBINED" ]; then
    awk 'NF && $1 ~ /^\.\// && $0 !~ /type=file/ { sub(/^\./, "", $1); print $1 }' \
        "$MTREE_COMBINED" | while read -r d; do mkdir -p "$SYSROOT$d"; done
    echo "OK   created $(find "$SYSROOT" -type d 2>/dev/null | wc -l) dirs in sysroot"
else
    echo "WARN mtree specs missing; header/lib install may fail on subdirs"
fi

# Install headers (top-level 'includes' target). -k keeps going if one subtree
# fails; with the tree present this normally completes with zero errors.
cd "$SRC"
if $NBMAKE -k DESTDIR="$SYSROOT" MKUPDATE=yes includes >/dev/null 2>&1; then
    echo "OK   includes installed to $SYSROOT"
else
    echo "WARN includes reported errors; continuing"
fi

# Build & install the static libraries the utilities link against. MKPIC=no
# => build only the static .a (skip the shared .so, which fails to link and is
# not needed). Each lib is verified to have landed in the sysroot.
# Each entry is "relative-source-dir:libname". libname is only used to verify
# the .a landed in the sysroot; csu is special (it produces crt0.o, not a .a).
LIBS="lib/csu:csu
lib/libc:libc
lib/libm:libm
lib/libutil:libutil
lib/libcrypt:libcrypt
lib/libz:libz
lib/libkvm:libkvm
lib/libpthread:libpthread
lib/libterminfo:libterminfo
lib/libprop:libprop
lib/libbz2:libbz2
external/public-domain/xz/lib:liblzma
external/bsd/libarchive/lib/libarchive:libarchive
external/bsd/libarchive/lib/libarchive_fe:libarchive_fe"
for entry in $LIBS; do
    d="$SRC/${entry%%:*}"; lb="${entry##*:}"
    [ -d "$d" ] || { echo "SKIP  $lb (no src $d)"; continue; }
    if ( cd "$d" && $NBMAKE DESTDIR="$SYSROOT" MKPIC=no obj >/dev/null 2>&1 && \
         $NBMAKE DESTDIR="$SYSROOT" MKPIC=no dependall >/dev/null 2>&1 && \
         $NBMAKE DESTDIR="$SYSROOT" MKPIC=no install >/dev/null 2>&1 ); then
        if [ "$lb" = csu ]; then
            if [ -f "$SYSROOT/usr/lib/crt0.o" ]; then
                echo "OK   lib $lb (crt0.o present)"
            else
                echo "WARN lib $lb built but crt0.o not found"
            fi
        elif [ -f "$SYSROOT/usr/lib/$lb.a" ]; then
            echo "OK   lib $lb ($(stat -c%s "$SYSROOT/usr/lib/$lb.a") bytes)"
        else
            echo "WARN lib $lb built but $lb.a not found in sysroot"
        fi
    else
        echo "FAIL lib $lb"
    fi
done

# ----------------------------------------- libgcc (compiler runtime)
# NetBSD's 'build.sh tools' deliberately does NOT build the target libgcc (it has
# a chicken/egg problem with shared libraries), yet every static program needs
# libgcc.a AND libgcc_eh.a at link time. We build them from the cross gcc's own
# build tree (the standard "gcc cross-compiler" method, independent of the
# NetBSD libgcc.mk glue that mknative would normally generate) and install them
# into the compiler's private libdir (auto-searched by gcc) and the sysroot
# /usr/lib. bootstrap-libgcc configures target libgcc + arch glue; the build
# dir's libgcc is then compiled with C_INCLUDE_PATH pointing at the sysroot
# headers and gcc's ginclude (for ARM EH headers like unwind-arm-common.h).
LIBDIR="$TOOLS/lib/gcc/$TRIPLE/4.8.5"
GINCLUDE="$SRC/external/gpl3/gcc/dist/gcc/ginclude"
if [ -f "$LIBDIR/libgcc.a" ] && [ -f "$LIBDIR/libgcc_eh.a" ]; then
    echo "OK   libgcc already present in $LIBDIR, skipping rebuild"
else
    echo "--- building libgcc (target runtime) ---"
    cd "$SRC/tools/gcc"
    $NBMAKE DESTDIR="$SYSROOT" HAVE_GCC=48 bootstrap-libgcc >/dev/null 2>&1 \
        || echo "WARN bootstrap-libgcc reported errors"
    GB="$OBJ/tools/gcc/build/$TRIPLE/libgcc"
    ( cd "$GB" && C_INCLUDE_PATH="$SYSROOT/usr/include:$GINCLUDE" \
        make libgcc.a libgcc_eh.a ) >/dev/null 2>&1 \
        || echo "FAIL libgcc build"
    mkdir -p "$LIBDIR" "$SYSROOT/usr/lib"
    cp -f "$GB/libgcc.a" "$GB/libgcc_eh.a" "$LIBDIR"/ 2>/dev/null || true
    cp -f "$GB/libgcc.a" "$GB/libgcc_eh.a" "$SYSROOT/usr/lib"/ 2>/dev/null || true
    if [ -f "$LIBDIR/libgcc.a" ] && [ -f "$LIBDIR/libgcc_eh.a" ]; then
        echo "OK   libgcc.a + libgcc_eh.a installed ($(stat -c%s "$LIBDIR/libgcc.a") bytes)"
    else
        echo "FAIL libgcc install"
    fi
fi

echo "--- sanity: key static libs present? ---"
for l in libc.a libm.a libutil.a libcrypt.a libz.a; do
    if [ -f "$SYSROOT/usr/lib/$l" ]; then echo "OK   $l"; else echo "MISS $l"; fi
done

# ---------------------------------------------------- [4] static utils
echo "=== [4/4] build static utilities ==="
# Start from a clean staging dir so the manifest reflects exactly what built.
rm -rf "$SERVICE_STAGE_NETBSD7/bin"
mkdir -p "$SERVICE_STAGE_NETBSD7/bin"

build_one() {
    name="$1"
    # Locate the utility's source directory. Prefer the real base-system trees;
    # the 'tests/' subtree holds regression programs, not the actual commands,
    # so it is excluded. NetBSD 7 scatters these across bin/, sbin/, usr.bin/
    # and external/bsd/libarchive/bin/ (bsdtar), so we discover the path instead
    # of hard-coding it (several names move between dirs between releases).
    sdir=""
    for base in bin sbin usr.bin usr.sbin libexec external/bsd/libarchive/bin; do
        if [ -d "$SRC/$base/$name" ]; then sdir="$SRC/$base/$name"; break; fi
    done
    if [ -z "$sdir" ]; then
        sdir=$(cd "$SRC" && find . -maxdepth 3 -type d -name "$name" 2>/dev/null \
               | grep -v '/tests/' \
               | grep -E "/(bin|sbin|usr.bin|usr.sbin|libexec|external)/$name$" \
               | head -1)
        sdir="${sdir#./}"; [ -n "$sdir" ] && sdir="$SRC/$sdir"
    fi
    [ -n "$sdir" ] || { echo "SKIP  $name (no src found)"; return; }
    echo "--- building $name ($sdir) ---"
    cd "$sdir"
    $NBMAKE obj >/dev/null 2>&1 || true
    # LDSTATIC=-static forces a static executable. MKRUMP=no skips the rump.*
    # variants some utils also build (e.g. dd's rump.dd needs librumpclient,
    # which we don't ship). MKINFO=no avoids building texinfo docs (the texinfo
    # tool was dropped from the cross tools, so 'make awk.info' would fail).
    if $NBMAKE LDSTATIC="-static" MKLINT=no MKPIC=no MKPROFILE=no MKDEBUG=no \
            MKRUMP=no MKINFO=no >"$SERVICE_STAGE_NETBSD7/log.$name" 2>&1; then
        rel="${sdir#$SRC/}"
        bin="$OBJ/$rel/$name"
        [ -x "$bin" ] || bin=$(find "$sdir" -type f -perm -u+x -name "$name" 2>/dev/null | head -1)
        if [ -n "$bin" ] && [ -x "$bin" ]; then
            $STRIP --strip-unneeded "$bin" 2>/dev/null || true
            cp "$bin" "$SERVICE_STAGE_NETBSD7/bin/$name"
            echo "OK    $name  ($(stat -c%s "$SERVICE_STAGE_NETBSD7/bin/$name") bytes)"
        else
            echo "FAIL  $name (binary not found)"
        fi
    else
        echo "FAIL  $name (build error)"; tail -n 5 "$SERVICE_STAGE_NETBSD7/log.$name"
    fi
}

# Flat list of desired utilities. Names with no base-system source (e.g.
# realpath/nc/which/od/sum/id/diff are absent from this NetBSD 7 tree) are
# reported as SKIP and simply omitted from the toolbox.
UTILS="ls cp mv rm cat dd echo mkdir rmdir ln chmod chown chflags df pwd sync stty \
       test sleep date env kill ps expr touch printf grep sed awk find gzip \
       head tail sort cut tr uniq wc patch basename dirname tee yes jot du cksum tar"
for p in $UTILS; do
    build_one "$p"
done

# NetBSD has no seq(1); provide jot as a stand-in if it built.
[ -x "$SERVICE_STAGE_NETBSD7/bin/jot" ] && cp "$SERVICE_STAGE_NETBSD7/bin/jot" "$SERVICE_STAGE_NETBSD7/bin/seq" && echo "OK    seq (alias of jot)"

# ---------------------------------------------------- verify + manifest
echo "=== static check ==="
bad=0
for b in "$SERVICE_STAGE_NETBSD7/bin"/*; do
    [ -f "$b" ] || continue
    if $OBJUMP -p "$b" 2>/dev/null | grep -Eq '^[[:space:]]*(INTERP|DYNAMIC)'; then
        echo "NOT-STATIC: $(basename "$b")"; bad=1
    fi
done
[ "$bad" = 0 ] && echo "All staged binaries are statically linked."

echo "=== manifest ==="
ls -l "$SERVICE_STAGE_NETBSD7/bin" | awk 'NR>1{printf "%-12s %8d\n", $9, $5}'
echo "TOTAL: $(ls "$SERVICE_STAGE_NETBSD7/bin" 2>/dev/null | wc -l) binaries in $SERVICE_STAGE_NETBSD7/bin"
echo "BUILD_DONE"
