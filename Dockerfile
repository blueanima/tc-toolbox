FROM debian:bookworm

# We build the NetBSD/evbarm cross-toolchain here. Debian 12/bookworm is used
# (NOT bullseye): bullseye is EOL and its debian-security pool .deb files have
# been purged (404), so the pre-installed u14 libc6 on the bullseye image could
# never be matched by any apt source. bookworm is current stable, its archive is
# complete and internally consistent (base image == bookworm/main suite), so apt
# just works.
#
# NETWORKING: optional outbound HTTP proxy hook. If your build environment
# requires a proxy, pass it at build time via --build-arg BUILD_PROXY=... or at
# run time via -e http_proxy=...; otherwise it is left empty for direct egress.
# TLS peer/host verification is disabled because the base image ships no
# ca-certificates, but apt still validates the InRelease GPG signature with the
# Debian keyring; the Tuna mirror is used for apt speed.
ARG BUILD_PROXY=""
ENV http_proxy=$BUILD_PROXY
ENV https_proxy=$BUILD_PROXY
ENV HTTP_PROXY=$BUILD_PROXY
ENV HTTPS_PROXY=$BUILD_PROXY
ENV no_proxy=localhost,127.0.0.1
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
