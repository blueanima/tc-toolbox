FROM debian:bookworm

# We build the NetBSD/evbarm cross-toolchain here. Debian 12/bookworm is used
# (NOT bullseye): bullseye is EOL and its debian-security pool .deb files have
# been purged (404), so the pre-installed u14 libc6 on the bullseye image could
# never be matched by any apt source. bookworm is current stable, its archive is
# complete and internally consistent (base image == bookworm/main suite), so apt
# just works.
#
# NETWORKING: the container has no usable direct egress (its DNS hijacks every
# host to a dead capture proxy at 198.18.24.68:80). The only working outbound
# path is the Mac's Surge proxy at host.docker.internal:6152 (HTTP) / :6153
# (SOCKS5). We therefore route apt through it. We use HTTPS (a CONNECT tunnel
# the proxy cannot tamper with) and disable TLS peer/host verification because
# the base image ships no ca-certificates; apt still validates the InRelease
# GPG signature with the Debian keyring in the image. The Tuna mirror is fast
# through Surge from this location (deb.debian.org was ~6 KB/s and timed out).
ENV http_proxy=http://host.docker.internal:6152
ENV https_proxy=http://host.docker.internal:6152
ENV HTTP_PROXY=http://host.docker.internal:6152
ENV HTTPS_PROXY=http://host.docker.internal:6152
ENV no_proxy=localhost,127.0.0.1,host.docker.internal
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
ENV PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

RUN printf '%s\n' \
       'deb https://mirrors.tuna.tsinghua.edu.cn/debian bookworm main' \
       > /etc/apt/sources.list \
    && rm -f /etc/apt/sources.list.d/*.list 2>/dev/null \
    && printf '%s\n' \
       'Acquire::Check-Valid-Until "false";' \
       'Acquire::https::Verify-Peer "false";' \
       'Acquire::https::Verify-Host "false";' \
       > /etc/apt/apt.conf.d/99-no-proxy

# Host compiler is bookworm's default gcc-12. Its default C++ standard is
# gnu++17, which breaks NetBSD 7's gcc-4.8-era C++ sources (e.g. "bool++").
# We wrap g++ so that, for EVERY g++ invocation, "-std=gnu++14 -fpermissive" is
# APPENDED (the last -std on the command line wins). gnu++14 is a superset of
# C++11/14, so it does NOT break the modern host tools (gmake/binutils/gmp/
# mpfr/mpc) while allowing the old gcc sources to compile (bool++ becomes a
# warning). The wrapper execs the real g++-12 by absolute path to avoid PATH
# recursion.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        gcc-12 g++-12 \
        bison flex \
        libgmp-dev libmpfr-dev libmpc-dev \
        zlib1g-dev \
        texinfo \
        curl git ca-certificates \
        python3 python-is-python3 \
        pkg-config \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/make /usr/bin/gmake \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 90 \
    && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 90 \
    && update-alternatives --install /usr/bin/cc cc /usr/bin/gcc-12 90 \
    && printf '%s\n' \
       '#!/bin/sh' \
       'exec /usr/bin/g++-12 "$@" -std=gnu++14 -fpermissive' \
       > /usr/local/bin/g++ \
    && printf '%s\n' \
       '#!/bin/sh' \
       'exec /usr/bin/g++-12 "$@" -std=gnu++14 -fpermissive' \
       > /usr/local/bin/c++ \
    && chmod +x /usr/local/bin/g++ /usr/local/bin/c++

WORKDIR /buildroot
