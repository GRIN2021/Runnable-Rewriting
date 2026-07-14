#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$ROOT/Runnable-Rewriting"
RUN_ROOT="${RUNNABLE_LIBCRYPTO_RUN_ROOT:-$ROOT/runs-libcrypto}"
IMAGE="${RUNNABLE_QEMU_V2_IMAGE:-rr_qemu_v2_runtime:latest}"
PLATFORM="${RUNNABLE_DOCKER_PLATFORM:-linux/amd64}"
MODE="${1:-stage-bundled}"

cpu_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu
  elif command -v getconf >/dev/null 2>&1; then
    getconf _NPROCESSORS_ONLN
  else
    echo 1
  fi
}

JOBS="${RUNNABLE_QEMU_V2_JOBS:-$(cpu_count)}"
LIBCRYPTO_BINARY="$ROOT/GroudTruth/groundtruth-gap-analysis-skill/results/libcrypto-artifacts/libcrypto.so.3"
LIBCRYPTO_SMOKE_ENTRY="${RUNNABLE_LIBCRYPTO_SMOKE_ENTRY:-0x500cf4b0}"
LIBCRYPTO_GUEST_BASE="${RUNNABLE_LIBCRYPTO_GUEST_BASE:-0x50000000}"

usage() {
  cat <<'EOF'
Usage:
  ./build-libtinycode-qemuv2.sh [stage-bundled|rebuild|build-only]

Modes:
  stage-bundled  Build runnable-lift, then stage the bundled full QEMU V2
                 libtinycode assets into the runnable-lift build tree. Uses
                 Docker when available, otherwise builds natively on WSL/host.
  rebuild        Build Docker image and runnable-lift, then rebuild QEMU V2
                 libtinycode from QEMU 10.2.3 using the package scripts.
  build-only     Build runnable-lift only.

Environment overrides:
  RUNNABLE_QEMU_V2_IMAGE       Docker image tag. Default: rr_qemu_v2_runtime:latest
  RUNNABLE_DOCKER_PLATFORM     Docker platform. Default: linux/amd64
  RUNNABLE_QEMU_V2_JOBS        Build parallelism. Default: detected CPU count
  RUNNABLE_LIBCRYPTO_RUN_ROOT  Output root. Default: ./runs-libcrypto
  RUNNABLE_LIBCRYPTO_NO_DOCKER Set to 1 to force native WSL/host build.
EOF
}

case "$MODE" in
  -h|--help)
    usage
    exit 0
    ;;
  stage-bundled|rebuild|build-only)
    ;;
  *)
    echo "error: unknown mode: $MODE" >&2
    usage >&2
    exit 2
    ;;
esac

use_docker=1
if [[ "${RUNNABLE_LIBCRYPTO_NO_DOCKER:-0}" == "1" ]] || ! command -v docker >/dev/null 2>&1; then
  use_docker=0
fi

libtinycode_is_real() {
  local lib="$1"
  [[ -f "$lib" ]] || return 1
  grep -aFq "real_translation=false" "$lib" && return 1
  grep -aFq "REAL_PTC_TRANSLATION=not-migrated-empty-stub" "$lib" && return 1
  if grep -aFq "real_translation=true" "$lib"; then
    return 0
  fi
  [[ "$(wc -c < "$lib")" -gt 1000000 ]] || return 1
  grep -aFq "qemu_get_cpu" "$lib" || return 1
  grep -aFq "tcg_gen_code" "$lib" || return 1
}

stage_runtime() {
  local lib="$1"
  local helpers="$2"
  local build_dir="$RR_DIR/build-codex-dynamic-current"
  local lift_dir="$build_dir/tools/runnable-lift"
  local early_linked="$build_dir/early-linked-x86_64.ll"

  libtinycode_is_real "$lib" || {
    echo "error: libtinycode does not look like a real QEMU V2 runtime: $lib" >&2
    exit 1
  }
  [[ -f "$helpers" ]] || {
    echo "error: helper IR missing: $helpers" >&2
    exit 1
  }

  if [[ ! -f "$early_linked" ]]; then
    cmake --build "$build_dir" \
      --target early-linked-module-early-linked-x86_64.ll \
      -- -j "$JOBS"
  fi
  [[ -f "$early_linked" ]] || {
    echo "error: early-linked IR missing after build: $early_linked" >&2
    exit 1
  }

  mkdir -p "$lift_dir"
  cp -a "$lib" "$lift_dir/libtinycode-x86_64.so"
  cp -a "$helpers" "$lift_dir/libtinycode-helpers-x86_64.ll"
  cp -a "$early_linked" "$lift_dir/early-linked-x86_64.ll"
}

mkdir -p "$RUN_ROOT"

if [[ "$use_docker" -eq 1 ]]; then
  echo "== Build Ubuntu 24.04 runtime image =="
  docker build --platform "$PLATFORM" -t "$IMAGE" "$RR_DIR/docker/qemu-v2-runtime"

  echo "== Build runnable-lift inside the runtime image =="
  RUNNABLE_QEMU_V2_IMAGE="$IMAGE" RUNNABLE_DOCKER_PLATFORM="$PLATFORM" RUNNABLE_QEMU_V2_JOBS="$JOBS" \
    "$RR_DIR/runnable/scripts/build_runnable_lift_v2.sh" --skip-image-build --verify
else
  echo "== Docker unavailable/disabled: build runnable-lift natively on WSL/host =="
  if ! command -v llvm-config >/dev/null 2>&1 && ! command -v llvm-config-18 >/dev/null 2>&1; then
    cat >&2 <<EOF
error: llvm-config not found. Install host dependencies first:

  sudo bash "$RR_DIR/runnable/scripts/host-build/install-host-deps.sh"

Then re-run:

  RUNNABLE_LIBCRYPTO_NO_DOCKER=1 ./build-libtinycode-qemuv2.sh stage-bundled
EOF
    exit 1
  fi
  bash "$RR_DIR/runnable/scripts/host-build/build-runnable-lift-host.sh" --verify --jobs "$JOBS"
fi

if [[ "$MODE" == "build-only" ]]; then
  echo "BUILD_ONLY_OK=1"
  exit 0
fi

if [[ "$MODE" == "rebuild" ]]; then
  if [[ "$use_docker" -eq 0 ]]; then
    cat >&2 <<EOF
error: rebuild mode without Docker is intentionally not automated in this
package. Use the bundled QEMU V2 libtinycode runtime:

  RUNNABLE_LIBCRYPTO_NO_DOCKER=1 ./build-libtinycode-qemuv2.sh stage-bundled

or install Docker and run:

  ./build-libtinycode-qemuv2.sh rebuild
EOF
    exit 1
  fi
  echo "== Rebuild request-aware libcrypto QEMU V2 libtinycode =="
  install_dir="$RUN_ROOT/shared-install-runnable"
  RUNNABLE_QEMU_V2_IMAGE="$IMAGE" RUNNABLE_DOCKER_PLATFORM="$PLATFORM" RUNNABLE_QEMU_V2_JOBS="$JOBS" \
    "$RR_DIR/runnable/scripts/build_qemu_libtinycode_v2.sh" \
      --libtinycode \
      --download-qemu \
      --skip-image-build \
      --build-dir "$RUN_ROOT/build-qemu-v2-libtinycode" \
      --install-dir "$install_dir" \
      --external-binary "$LIBCRYPTO_BINARY" \
      --external-entry "$LIBCRYPTO_SMOKE_ENTRY" \
      --external-label "libcrypto" \
      --external-run-dir "$(dirname "$LIBCRYPTO_BINARY")" \
      --guest-base "$LIBCRYPTO_GUEST_BASE"
  stage_runtime "$install_dir/lib/libtinycode-x86_64.so" "$install_dir/lib/libtinycode-helpers-x86_64.ll"
else
  echo "== Stage bundled full QEMU V2 libtinycode =="
  stage_runtime \
    "$RR_DIR/runnable/tools/runnable-lift/libtinycode-x86_64.so" \
    "$RR_DIR/runnable/tools/runnable-lift/libtinycode-helpers-x86_64.ll"
fi

echo "== Staged runtime assets =="
sha256sum \
  "$RR_DIR/build-codex-dynamic-current/tools/runnable-lift/libtinycode-x86_64.so" \
  "$RR_DIR/build-codex-dynamic-current/tools/runnable-lift/libtinycode-helpers-x86_64.ll" \
  "$RR_DIR/build-codex-dynamic-current/tools/runnable-lift/early-linked-x86_64.ll"
