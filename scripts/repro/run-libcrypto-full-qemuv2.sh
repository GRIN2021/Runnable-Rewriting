#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$ROOT/Runnable-Rewriting"
RUN_ROOT="${RUNNABLE_LIBCRYPTO_RUN_ROOT:-$ROOT/runs-libcrypto}"
IMAGE="${RUNNABLE_QEMU_V2_IMAGE:-rr_qemu_v2_runtime:latest}"
PLATFORM="${RUNNABLE_DOCKER_PLATFORM:-linux/amd64}"

FULL_MEM_GB="${RUNNABLE_LIBCRYPTO_FULL_MEM_GB:-32}"
FULL_CPUS="${RUNNABLE_LIBCRYPTO_FULL_CPUS:-30}"
RUN_LABEL="${RUNNABLE_LIBCRYPTO_RUN_LABEL:-libcrypto-full-$(date +%Y%m%d-%H%M%S)}"
BUILD_MODE="${RUNNABLE_LIBTINYCODE_BUILD_MODE:-stage-bundled}"

usage() {
  cat <<'EOF'
Usage:
  ./run-libcrypto-full-qemuv2.sh

This runs the full libcrypto.so QEMU V2 dynamic-parallel experiment and the
precision/recall compare phase.

Environment overrides:
  RUNNABLE_LIBCRYPTO_RUN_ROOT     Output root. Default: ./runs-libcrypto
  RUNNABLE_QEMU_V2_IMAGE          Docker image tag. Default: rr_qemu_v2_runtime:latest
  RUNNABLE_DOCKER_PLATFORM        Docker platform. Default: linux/amd64
  RUNNABLE_LIBTINYCODE_BUILD_MODE stage-bundled or rebuild. Default: stage-bundled
  RUNNABLE_LIBCRYPTO_RUN_LABEL    Run label. Default: libcrypto-full-<timestamp>
  RUNNABLE_LIBCRYPTO_FULL_MEM_GB  Docker memory limit. Default: 32
  RUNNABLE_LIBCRYPTO_FULL_CPUS    Docker CPU limit. Default: 30
  RUNNABLE_LIBCRYPTO_SKIP_CMP     Set to 1 to skip precision/recall compare.
  RUNNABLE_LIBCRYPTO_NO_DOCKER    Set to 1 to force native WSL/host mode.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

mkdir -p "$RUN_ROOT"

use_docker=1
if [[ "${RUNNABLE_LIBCRYPTO_NO_DOCKER:-0}" == "1" ]] || ! command -v docker >/dev/null 2>&1; then
  use_docker=0
fi

if [[ "$use_docker" -eq 1 || "${RUNNABLE_LIBCRYPTO_REBUILD:-0}" == "1" || ! -x "$ROOT/prebuilt/shared-install-runnable/bin/runnable-lift" ]]; then
  echo "== Build/stage QEMU V2 libtinycode =="
  RUNNABLE_LIBCRYPTO_RUN_ROOT="$RUN_ROOT" \
  RUNNABLE_QEMU_V2_IMAGE="$IMAGE" \
  RUNNABLE_DOCKER_PLATFORM="$PLATFORM" \
  RUNNABLE_LIBCRYPTO_NO_DOCKER="${RUNNABLE_LIBCRYPTO_NO_DOCKER:-0}" \
    "$ROOT/build-libtinycode-qemuv2.sh" "$BUILD_MODE"
fi

if [[ "$use_docker" -eq 0 && "${RUNNABLE_LIBCRYPTO_REBUILD:-0}" != "1" && -x "$ROOT/prebuilt/shared-install-runnable/bin/runnable-lift" ]]; then
  echo "== Docker unavailable/disabled: use bundled prebuilt runnable-lift =="
  mkdir -p "$RUN_ROOT"
  rm -rf "$RUN_ROOT/shared-install-runnable"
  cp -a "$ROOT/prebuilt/shared-install-runnable" "$RUN_ROOT/shared-install-runnable"
elif [[ "$use_docker" -eq 0 ]]; then
  echo "== Build/stage QEMU V2 libtinycode =="
  RUNNABLE_LIBCRYPTO_NO_DOCKER=1 "$ROOT/build-libtinycode-qemuv2.sh" stage-bundled
fi

if [[ "$use_docker" -eq 0 ]]; then
  echo "== Docker unavailable/disabled: run host-native shard orchestrator =="
  B="$RR_DIR/build-codex-dynamic-current"
  LLVM_LIBDIR="$(llvm-config --libdir 2>/dev/null || llvm-config-18 --libdir 2>/dev/null || true)"

  PREBUILT_PREFIX="$RUN_ROOT/shared-install-runnable"
  if [[ -x "$PREBUILT_PREFIX/bin/runnable-lift" && "${RUNNABLE_LIBCRYPTO_REBUILD:-0}" != "1" ]]; then
    export LD_LIBRARY_PATH="$PREBUILT_PREFIX/lib:$PREBUILT_PREFIX/lib/runnable/analyses${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export PATH="$PREBUILT_PREFIX/bin:$PATH"
    LIFT_PREFIX="$PREBUILT_PREFIX"
    LIBTINYCODE_PATH="$PREBUILT_PREFIX/bin/libtinycode-x86_64.so"
    LIBTINYCODE_HELPERS_PATH="$PREBUILT_PREFIX/bin/libtinycode-helpers-x86_64.ll"
  else
    export LD_LIBRARY_PATH="$B/lib/StackAnalysis:$B/lib/BasicAnalyses:$B/lib/Support${LLVM_LIBDIR:+:$LLVM_LIBDIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export PATH="$B/tools/runnable-lift:$PATH"
    LIFT_PREFIX="$B"
    LIBTINYCODE_PATH="$B/tools/runnable-lift/libtinycode-x86_64.so"
    LIBTINYCODE_HELPERS_PATH="$B/tools/runnable-lift/libtinycode-helpers-x86_64.ll"
  fi

  HOST_ARGS=(
    --workspace-root "$ROOT"
    --repo-root "$RR_DIR"
    --groudtruth-repo-root "$ROOT/GroudTruth"
    --hdd-root "$RUN_ROOT"
    --run-label "$RUN_LABEL"
    --no-streaming-merge
    --parallel-workers "${RUNNABLE_LIBCRYPTO_HOST_PARALLEL_WORKERS:-1}"
    --max-seeds "${RUNNABLE_LIBCRYPTO_MAX_SEEDS:-0}"
    --max-concurrent-coordinators "${RUNNABLE_LIBCRYPTO_HOST_SHARD_CONCURRENCY:-6}"
    --shard-concurrency "${RUNNABLE_LIBCRYPTO_HOST_SHARD_CONCURRENCY:-6}"
    --worker-memory-gb 1
    --lift-timeout-sec "${RUNNABLE_LIBCRYPTO_LIFT_TIMEOUT_SEC:-1800}"
    --merge-workers 2
    --merge-batch-size 2
    --execution-model host-shards
    --range-mode "${RUNNABLE_LIBCRYPTO_RANGE_MODE:-seed}"
    --no-rebuild-lift
    --all-symbols
    --libtinycode-path "$LIBTINYCODE_PATH"
    --libtinycode-helpers-path "$LIBTINYCODE_HELPERS_PATH"
  )
  if [[ "${RUNNABLE_LIBCRYPTO_SKIP_CMP:-0}" == "1" ]]; then
    HOST_ARGS+=(--skip-cmp)
  fi

  python3 "$RR_DIR/runnable/scripts/libcrypto_dynamic_parallel_lift.py" "${HOST_ARGS[@]}"

  RUN_DIR="$RUN_ROOT/runs/$RUN_LABEL"
  echo "== Run directory =="
  echo "$RUN_DIR"
  if [[ -f "$RUN_DIR/eval/cmp.verdict.txt" ]]; then
    echo "== Precision/recall verdict =="
    cat "$RUN_DIR/eval/cmp.verdict.txt"
  fi
  exit 0
fi

COMMON_ARGS=(
  --workspace-root "$ROOT"
  --repo-root "$RR_DIR"
  --groudtruth-repo-root "$ROOT/GroudTruth"
  --hdd-root "$RUN_ROOT"
  --docker-image "$IMAGE"
  --run-label "$RUN_LABEL"
  --streaming-merge
  --parallel-workers 5
  --max-concurrent-coordinators 6
  --shard-concurrency 6
  --container-memory-limit-gb "$FULL_MEM_GB"
  --container-cpus "$FULL_CPUS"
  --worker-memory-gb 1
  --lift-timeout-sec 1800
  --merge-workers 2
  --merge-batch-size 2
  --execution-model single-container-shards
  --no-rebuild-lift
  --all-symbols
  --libtinycode-path "$RR_DIR/build-codex-dynamic-current/tools/runnable-lift/libtinycode-x86_64.so"
  --libtinycode-helpers-path "$RR_DIR/build-codex-dynamic-current/tools/runnable-lift/libtinycode-helpers-x86_64.ll"
)

if [[ "${RUNNABLE_LIBCRYPTO_SKIP_CMP:-0}" == "1" ]]; then
  COMMON_ARGS+=(--skip-cmp)
fi

echo "== Run full libcrypto.so experiment =="
python3 "$RR_DIR/runnable/scripts/libcrypto_dynamic_parallel_lift.py" "${COMMON_ARGS[@]}"

RUN_DIR="$RUN_ROOT/runs/$RUN_LABEL"
echo "== Run directory =="
echo "$RUN_DIR"

if [[ -f "$RUN_DIR/eval/cmp.verdict.txt" ]]; then
  echo "== Precision/recall verdict =="
  cat "$RUN_DIR/eval/cmp.verdict.txt"
fi
