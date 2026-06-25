#!/usr/bin/env bash
#
# install-host-deps.sh — install the Ubuntu 24.04 build dependencies for
# runnable-lift, so it can be compiled and run NATIVELY on the host (no Docker).
#
# Why this exists: the qemu-v2-runtime Docker image ships the same package set
# for container builds. On Ubuntu 24.04 you can build and run in the same
# environment, so the glibc/libstdc++ drift that forces the Docker image on
# other hosts does not apply here.
#
# Usage:
#   sudo bash runnable/scripts/host-build/install-host-deps.sh
#
# Safe to re-run (idempotent apt-get install).
#
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  cat >&2 <<'EOF'
error: must run as root (need apt). Re-run with:

    sudo bash runnable/scripts/host-build/install-host-deps.sh
EOF
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "== apt-get update =="
apt-get update

echo "== install build dependencies =="
# Package set mirrors docker/qemu-v2-runtime/Dockerfile, with python2 and the
# QEMU-only libs dropped (runnable-lift itself only needs LLVM + headers).
# clang is required because runnable/CMakeLists.txt generates early-linked-*.ll
# and support-*.ll by invoking clang at build time.
apt-get install -y --no-install-recommends \
  build-essential \
  ca-certificates \
  ccache \
  clang \
  cmake \
  file \
  gawk \
  gdb \
  git \
  libglib2.0-dev \
  libtool \
  ninja-build \
  patch \
  perl \
  pkg-config \
  python3 \
  python3-pip \
  python3-setuptools \
  python3-venv \
  rsync \
  xz-utils \
  zlib1g-dev

echo
echo "== install-host-deps: done =="
echo "Next: build runnable-lift with"
echo "  bash runnable/scripts/host-build/build-runnable-lift-host.sh --verify"
