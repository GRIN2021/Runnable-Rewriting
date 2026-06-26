#!/usr/bin/env bash
#
# build-runnable-lift-host.sh — build the QEMU-v2-line runnable-lift NATIVELY on
# an Ubuntu 24.04 host, without Docker.
#
# This is a thin host-side wrapper around the existing
# runnable/scripts/build_runnable_lift_v2.sh --no-docker, which is the single
# source of truth for the CMake configure/build and the canonical artifact path.
# This wrapper adds:
#
#   * Ubuntu 24.04 host defaults that use the system llvm-config/LLVM package;
#   * a friendly reminder that the libtinycode runtime artifacts must be staged
#     for runnable-lift to actually lift anything;
#   * sane host defaults (build dir, jobs).
#
# Usage:
#   bash runnable/scripts/host-build/build-runnable-lift-host.sh [--verify]
#        [--llvm-dir DIR] [--llvm-root DIR] [--build-dir DIR] [--jobs N]
#        [--build-type TYPE]
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
LLVM_ROOT_OVERRIDE=""
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
                     default system llvm-config --cmakedir detection.
  --llvm-root DIR    LLVM/Clang prefix with lib/cmake/llvm. Compatibility path
                     for legacy repo-local root/ or explicit /usr/lib/llvm-18.
                     Not required on Ubuntu 24.04 with llvm-dev installed.
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

abs_path() {
  local input="$1"
  if [[ "$input" = /* ]]; then
    printf '%s\n' "$input"
  else
    printf '%s/%s\n' "$RR_DIR" "$input"
  fi
}

find_system_llvm_config() {
  if command -v llvm-config >/dev/null 2>&1; then
    command -v llvm-config
    return 0
  fi
  if command -v llvm-config-18 >/dev/null 2>&1; then
    command -v llvm-config-18
    return 0
  fi
  return 1
}

resolve_llvm_dir_from_root() {
  local llvm_root="$1"
  local candidate
  local -a candidates=(
    "$llvm_root/lib/cmake/llvm"
    "$llvm_root/share/llvm/cmake"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate/LLVMConfig.cmake" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  {
    echo "LLVM CMake directory not found under --llvm-root: $llvm_root"
    echo "Checked:"
    for candidate in "${candidates[@]}"; do
      echo "  $candidate"
    done
  } >&2
  return 1
}

infer_llvm_root_from_dir() {
  local llvm_dir="$1"
  case "$llvm_dir" in
    */lib/cmake/llvm)
      printf '%s\n' "${llvm_dir%/lib/cmake/llvm}"
      ;;
    */share/llvm/cmake)
      printf '%s\n' "${llvm_dir%/share/llvm/cmake}"
      ;;
    *)
      return 1
      ;;
  esac
}

join_by_colon() {
  local IFS=:
  printf '%s\n' "$*"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir)    BUILD_DIR="${2:?missing value for --build-dir}"; shift 2 ;;
    --llvm-dir)     LLVM_DIR_OVERRIDE="${2:?missing value for --llvm-dir}"; shift 2 ;;
    --llvm-root)    LLVM_ROOT_OVERRIDE="${2:?missing value for --llvm-root}"; shift 2 ;;
    --build-type)   BUILD_TYPE="${2:?missing value for --build-type}"; shift 2 ;;
    --jobs|-j)      JOBS="${2:?missing value for --jobs}"; shift 2 ;;
    --verify)       RUN_VERIFY=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "unknown argument: $1" ;;
  esac
done

[[ -f "$V2_BUILD" ]] || die "underlying build wrapper not found: $V2_BUILD"
[[ -f "$RR_DIR/runnable/CMakeLists.txt" ]] || die "not a Runnable-Rewriting checkout: $RR_DIR"

# --- Pre-check 1: LLVM -------------------------------------------------------
# Ubuntu 24.04 host builds default to the distro LLVM package (usually LLVM 18).
# Legacy repo-local root/ is still available, but only when explicitly selected
# with --llvm-root root or --llvm-dir root/lib/cmake/llvm.
note "Resolve LLVM"
LLVM_DIR_EFFECTIVE=""
LLVM_ROOT_EFFECTIVE=""
LLVM_LIBDIR=""

if [[ -n "$LLVM_ROOT_OVERRIDE" ]]; then
  LLVM_ROOT_EFFECTIVE="$(abs_path "$LLVM_ROOT_OVERRIDE")"
fi

if [[ -n "$LLVM_DIR_OVERRIDE" ]]; then
  LLVM_DIR_EFFECTIVE="$(abs_path "$LLVM_DIR_OVERRIDE")"
  [[ -f "$LLVM_DIR_EFFECTIVE/LLVMConfig.cmake" ]] || die "LLVMConfig.cmake not found in --llvm-dir: $LLVM_DIR_EFFECTIVE"
  if [[ -z "$LLVM_ROOT_EFFECTIVE" ]]; then
    LLVM_ROOT_EFFECTIVE="$(infer_llvm_root_from_dir "$LLVM_DIR_EFFECTIVE" || true)"
  fi
  echo "  using explicit --llvm-dir: $LLVM_DIR_EFFECTIVE"
elif [[ -n "$LLVM_ROOT_EFFECTIVE" ]]; then
  LLVM_DIR_EFFECTIVE="$(resolve_llvm_dir_from_root "$LLVM_ROOT_EFFECTIVE")"
  echo "  using explicit --llvm-root: $LLVM_ROOT_EFFECTIVE"
else
  LLVM_CONFIG="$(find_system_llvm_config)" || {
    cat >&2 <<EOF
error: system llvm-config not found.

  Install the Ubuntu 24.04 host dependencies:

      sudo bash runnable/scripts/host-build/install-host-deps.sh

  Or point at a specific LLVM install:

      bash $(basename "${BASH_SOURCE[0]}") --llvm-dir /path/to/dir-with-LLVMConfig.cmake
      bash $(basename "${BASH_SOURCE[0]}") --llvm-root /usr/lib/llvm-18

  Legacy repo-local root/ is supported only when explicitly selected:

      bash $(basename "${BASH_SOURCE[0]}") --llvm-root root
EOF
    exit 1
  }
  LLVM_DIR_EFFECTIVE="$("$LLVM_CONFIG" --cmakedir)"
  [[ -f "$LLVM_DIR_EFFECTIVE/LLVMConfig.cmake" ]] || die "$LLVM_CONFIG --cmakedir did not point at LLVMConfig.cmake: $LLVM_DIR_EFFECTIVE"
  LLVM_ROOT_EFFECTIVE="$("$LLVM_CONFIG" --prefix)"
  LLVM_LIBDIR="$("$LLVM_CONFIG" --libdir)"
  echo "  llvm-config : $LLVM_CONFIG"
  echo "  version     : $("$LLVM_CONFIG" --version)"
fi

if [[ -n "$LLVM_ROOT_EFFECTIVE" && -z "$LLVM_LIBDIR" ]]; then
  LLVM_LIBDIR="$LLVM_ROOT_EFFECTIVE/lib"
fi
echo "  LLVM_DIR    : $LLVM_DIR_EFFECTIVE"
if [[ -n "$LLVM_ROOT_EFFECTIVE" ]]; then
  echo "  LLVM root   : $LLVM_ROOT_EFFECTIVE"
fi
if [[ -n "$LLVM_LIBDIR" ]]; then
  echo "  LLVM libdir : $LLVM_LIBDIR"
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
      early-linked-x86_64.ll   (auto-generated by the build from LLVM's clang)

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
  --llvm-dir "$LLVM_DIR_EFFECTIVE"
)
[[ -n "$LLVM_ROOT_EFFECTIVE" ]] && ARGS+=(--llvm-root "$LLVM_ROOT_EFFECTIVE")
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
LD_PARTS=(
  "$BUILD_DIR_ABS/lib/StackAnalysis"
  "$BUILD_DIR_ABS/lib/BasicAnalyses"
  "$BUILD_DIR_ABS/lib/Support"
)
[[ -n "$LLVM_LIBDIR" ]] && LD_PARTS+=("$LLVM_LIBDIR")
LD_PATH="$(join_by_colon "${LD_PARTS[@]}")"

note "Host summary"
cat <<EOF

Runnable-lift binary:
  $ARTIFACT

To run it directly, export:
  export LD_LIBRARY_PATH="$LD_PATH\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"

Then smoke it:
  bash runnable/scripts/host-build/smoke-tiny-elf-host.sh
EOF
