#!/usr/bin/env bash
#
# build-runnable-lift-host.sh — build the QEMU-v2-line runnable-lift NATIVELY on
# an Ubuntu 24.04 host, without Docker.
#
# This is a thin host-side wrapper around the existing
# runnable/scripts/build_runnable_lift_v2.sh --no-docker, which is the single
# source of truth for the CMake flags, LLVM directory resolution, and the
# canonical artifact path. This wrapper adds:
#
#   * a hard pre-check that the non-git dependency tree `root/` is present;
#   * a friendly reminder that the libtinycode runtime artifacts must be staged
#     for runnable-lift to actually lift anything;
#   * sane host defaults (build dir, jobs).
#
# Usage:
#   bash runnable/scripts/host-build/build-runnable-lift-host.sh [--verify]
#        [--llvm-dir DIR] [--build-dir DIR] [--jobs N] [--build-type TYPE]
#
# See BUILD-HOST-UBUNTU-24.04.md for the full walkthrough.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# host-build -> scripts -> runnable -> repo root
RR_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"       # .../Runnable-Rewriting
V2_BUILD="$RR_DIR/runnable/scripts/build_runnable_lift_v2.sh"

BUILD_DIR="build-codex-dynamic-current"
LLVM_DIR_OVERRIDE=""
JOBS="$(nproc)"
BUILD_TYPE="Debug"
RUN_VERIFY=0

usage() {
  cat <<EOF
Usage:
  bash $(basename "${BASH_SOURCE[0]}") [options]

Options:
  --build-dir DIR    Build directory (relative to repo root or absolute).
                     Default: build-codex-dynamic-current
  --llvm-dir DIR     Exact directory containing LLVMConfig.cmake. Overrides the
                     default root/lib/cmake/llvm auto-detection.
  --build-type TYPE  CMake build type. Default: Debug
  --jobs N, -j N     Parallel build jobs. Default: $(nproc)
  --verify           After build, run ldd and runnable-lift --help smoke.
  -h, --help         Show this help.

The canonical artifact is the build-tree binary:
  <build-dir>/tools/runnable-lift/runnable-lift
EOF
}

die() { echo "error: $*" >&2; exit 1; }
note() { printf '\n== %s ==\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir)    BUILD_DIR="${2:?missing value for --build-dir}"; shift 2 ;;
    --llvm-dir)     LLVM_DIR_OVERRIDE="${2:?missing value for --llvm-dir}"; shift 2 ;;
    --build-type)   BUILD_TYPE="${2:?missing value for --build-type}"; shift 2 ;;
    --jobs|-j)      JOBS="${2:?missing value for --jobs}"; shift 2 ;;
    --verify)       RUN_VERIFY=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "unknown argument: $1" ;;
  esac
done

[[ -f "$V2_BUILD" ]] || die "underlying build wrapper not found: $V2_BUILD"
[[ -f "$RR_DIR/runnable/CMakeLists.txt" ]] || die "not a Runnable-Rewriting checkout: $RR_DIR"

# --- Pre-check 1: root/ (prebuilt LLVM 7) -----------------------------------
# root/ is the prebuilt LLVM/Clang dependency tree. It is NOT in git
# (.gitignore excludes /root/), so a fresh clone does not have it. CMake's
# find_package(LLVM) resolves against root/lib/cmake/llvm, and the
# early-linked-*.ll / support-*.ll modules are generated with root/bin/clang.
note "Check dependency tree root/"
LLVM_CONFIG="$RR_DIR/root/bin/llvm-config"
LLVM_CMAKE_DEFAULT="$RR_DIR/root/lib/cmake/llvm/LLVMConfig.cmake"
if [[ ! -x "$LLVM_CONFIG" ]] && [[ -z "$LLVM_DIR_OVERRIDE" ]]; then
  cat >&2 <<EOF
error: prebuilt LLVM dependency tree not found at: $RR_DIR/root

  root/ is NOT in git and must be staged from an existing environment that has
  already built runnable (e.g. the rr_bionic_exportfs Docker image, or another
  machine with a working checkout). Copy the whole root/ directory to:

      $RR_DIR/root

  Expected contents:
      root/bin/llvm-config            (executable)
      root/bin/clang                  (used to generate early-linked-*.ll)
      root/lib/cmake/llvm/LLVMConfig.cmake

  If your LLVM install lives elsewhere, point at its CMake dir directly:

      bash $(basename "${BASH_SOURCE[0]}") --llvm-dir /path/to/dir-with-LLVMConfig.cmake
EOF
  exit 1
fi
if [[ -z "$LLVM_DIR_OVERRIDE" ]]; then
  echo "  ok: $RR_DIR/root (llvm-config + cmake/llvm present)"
else
  echo "  using explicit --llvm-dir: $LLVM_DIR_OVERRIDE"
fi

# --- Pre-check 2 (advisory): libtinycode runtime artifacts ------------------
# runnable-lift dlopens libtinycode-<arch>.so at runtime (see
# runnable/tools/runnable-lift/Main.cpp:findFiles). These are NOT git-tracked
# and are produced by the classic QEMU build (support/components/qemu.mk),
# not by runnable's own CMake. A build + --help will still succeed without
# them (findFiles runs after option parsing), but an actual lift will fail
# with "Couldn't find libtinycode and the helpers" until they are staged.
note "Check libtinycode runtime artifacts (advisory)"
SRC_LIFT_DIR="$RR_DIR/runnable/tools/runnable-lift"
if [[ -f "$SRC_LIFT_DIR/libtinycode-x86_64.so" ]] \
   && [[ -f "$SRC_LIFT_DIR/libtinycode-helpers-x86_64.ll" ]]; then
  echo "  ok: libtinycode-x86_64.so + helpers-x86_64.ll present in source tree"
  echo "      (they will be copied next to the binary on build, see CMakeLists.txt POST_BUILD)"
else
  cat >&2 <<EOF
warning: libtinycode runtime artifacts missing under:
      $SRC_LIFT_DIR

  runnable-lift --help will work, but an actual lift will fail until these are
  staged alongside the binary:
      libtinycode-x86_64.so
      libtinycode-helpers-x86_64.ll
      early-linked-x86_64.ll   (auto-generated by the build from root/bin/clang)

  These come from a QEMU build (out of scope here). See BUILD-HOST-UBUNTU-24.04.md.
EOF
fi

# --- Delegate to the existing native build wrapper --------------------------
note "Build runnable-lift (native, no Docker)"
ARGS=(
  --build-dir "$BUILD_DIR"
  --build-type "$BUILD_TYPE"
  --jobs "$JOBS"
  --no-docker
)
[[ -n "$LLVM_DIR_OVERRIDE" ]] && ARGS+=(--llvm-dir "$LLVM_DIR_OVERRIDE")
[[ "$RUN_VERIFY" -eq 1 ]] && ARGS+=(--verify)

bash "$V2_BUILD" "${ARGS[@]}"

# --- Print the host-relevant paths for the user -----------------------------
# Resolve the artifact the same way the v2 wrapper reports it.
if [[ "$BUILD_DIR" = /* ]]; then
  BUILD_DIR_ABS="$BUILD_DIR"
else
  BUILD_DIR_ABS="$RR_DIR/$BUILD_DIR"
fi
ARTIFACT="$BUILD_DIR_ABS/tools/runnable-lift/runnable-lift"
LD_PATH="$BUILD_DIR_ABS/lib/StackAnalysis:$BUILD_DIR_ABS/lib/BasicAnalyses:$BUILD_DIR_ABS/lib/Support:$RR_DIR/root/lib"

note "Host summary"
cat <<EOF

Runnable-lift binary:
  $ARTIFACT

To run it directly, export:
  export LD_LIBRARY_PATH="$LD_PATH\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"

Then smoke it:
  bash runnable/scripts/host-build/smoke-tiny-elf-host.sh
EOF
