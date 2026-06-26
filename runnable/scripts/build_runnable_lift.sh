#!/usr/bin/env bash
#
# Compatibility wrapper for the old runnable-lift build entrypoint.
#
# The default build path now uses the QEMU V2 Ubuntu 24.04 runtime image and
# the system LLVM package discovered by build_runnable_lift_v2.sh. Set
# RUNNABLE_BUILD_IMAGE explicitly if you need to point this wrapper at a custom
# or legacy image.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

IMAGE="${RUNNABLE_BUILD_IMAGE:-${RUNNABLE_QEMU_V2_IMAGE:-rr_qemu_v2_runtime:latest}}"
BUILD_NAME="${RUNNABLE_BUILD_DIR:-build-qemu-v2}"
JOBS="${RUNNABLE_BUILD_JOBS:-}"

FORWARD_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir)
      BUILD_NAME="${2:?missing value for --build-dir}"
      shift 2
      ;;
    --image)
      IMAGE="${2:?missing value for --image}"
      shift 2
      ;;
    --jobs|-j)
      JOBS="${2:?missing value for --jobs}"
      shift 2
      ;;
    --llvm-root|--llvm-dir|--qemu-install-path|--build-type)
      FORWARD_ARGS+=("$1" "${2:?missing value for $1}")
      shift 2
      ;;
    --no-docker|--skip-image-build|--verify|-h|--help)
      FORWARD_ARGS+=("$1")
      shift
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == -* ]]; then
          FORWARD_ARGS+=("$1")
        else
          BUILD_NAME="$1"
        fi
        shift
      done
      ;;
    -*)
      FORWARD_ARGS+=("$1")
      shift
      ;;
    *)
      BUILD_NAME="$1"
      shift
      ;;
  esac
done

ARGS=()

ARGS+=(--build-dir "$BUILD_NAME")
ARGS+=(--image "$IMAGE")

if [[ -n "$JOBS" ]]; then
  ARGS+=(--jobs "$JOBS")
fi

exec "$SCRIPT_DIR/build_runnable_lift_v2.sh" "${ARGS[@]}" "${FORWARD_ARGS[@]}"
