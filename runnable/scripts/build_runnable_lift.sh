#!/usr/bin/env bash
#
# build_runnable_lift.sh — rebuild runnable-lift INSIDE the bionic image.
#
# runnable-lift must be compiled inside the Ubuntu-18.04 image
# (rr_bionic_exportfs:2026-04-14). A host-native build links against the
# host glibc/libstdc++ (GLIBC_2.34, GLIBCXX_3.4.32) and FAILS to load inside
# the bionic container that the lift pipeline actually runs in.
#
# Prebuilt LLVM/QEMU/Boost dependencies live at /root/Runnable-Rewriting/root
# inside the image. The workspace is bind-mounted at /workspace so build output
# lands on the host.
#
# The canonical artifact is the BUILD-TREE binary:
#   <build-dir>/runnable-lift
# `cmake --install` does not install the runnable-lift target; the libcrypto
# orchestrator (probe_build_tree_runnable_lift) reads it straight from the
# build tree.
#
# Usage:
#   runnable/scripts/build_runnable_lift.sh [build-dir-name]
#
# Defaults:
#   build-dir-name = build-bionic   (relative to Runnable-Rewriting/)
#
set -euo pipefail

# Resolve Runnable-Rewriting/ from this script's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"          # .../Runnable-Rewriting
WORKSPACE_ROOT="$(cd "$RR_DIR/.." && pwd)"          # parent that gets mounted at /workspace

IMAGE="${RUNNABLE_BUILD_IMAGE:-rr_bionic_exportfs:2026-04-14}"
BUILD_NAME="${1:-build-bionic}"
JOBS="${RUNNABLE_BUILD_JOBS:-$(nproc)}"

echo "Runnable-Rewriting : $RR_DIR"
echo "mounted workspace  : $WORKSPACE_ROOT -> /workspace"
echo "image              : $IMAGE"
echo "build dir          : $RR_DIR/$BUILD_NAME"
echo "parallel jobs      : $JOBS"

docker run --rm \
  -v "$WORKSPACE_ROOT":/workspace \
  -w /workspace/Runnable-Rewriting \
  "$IMAGE" bash -lc '
set -euo pipefail
BUILD=/workspace/Runnable-Rewriting/'"$BUILD_NAME"'
DEPS=/root/Runnable-Rewriting/root
mkdir -p "$BUILD"
cd "$BUILD"
cmake /workspace/Runnable-Rewriting/runnable \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_INSTALL_PREFIX="$BUILD/install" \
  -DQEMU_INSTALL_PATH="$DEPS" \
  -DLLVM_DIR="$DEPS/lib/cmake/llvm" \
  -DBOOST_ROOT="$DEPS" \
  -DBoost_NO_SYSTEM_PATHS=On \
  -DCMAKE_CXX_LINK_FLAGS="-static-libgcc -static-libstdc++" \
  -DCMAKE_C_LINK_FLAGS="-static-libgcc"
# cmake 3.10 does not accept "cmake --build -j"; pass jobs to the native tool.
cmake --build . -- -j'"$JOBS"'
echo "BUILD_OK -> $BUILD/runnable-lift"
'

echo
echo "Built binary: $RR_DIR/$BUILD_NAME/runnable-lift"
echo "Canonical runnable-lift artifact: $RR_DIR/$BUILD_NAME/runnable-lift"
echo "Do not default to source-tree runnable/tools/runnable-lift/runnable-lift; that binary may be stale."
echo "Verify inside the container with:"
echo "  runnable/scripts/build_runnable_lift.sh --verify $BUILD_NAME   # (see SKILL.md)"
