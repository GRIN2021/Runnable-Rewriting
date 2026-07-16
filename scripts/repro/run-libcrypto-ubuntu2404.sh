#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$ROOT/Runnable-Rewriting"
RUN_ROOT="${RUNNABLE_LIBCRYPTO_RUN_ROOT:-$ROOT/runs-libcrypto}"
MODE="${1:-smoke}"

usage() {
  cat <<'EOF'
Usage:
  ./run-libcrypto-ubuntu2404.sh [smoke|full|build-only]

This is the compatibility entrypoint for the WSL repro package. It uses Docker
when available, and automatically falls back to native WSL/host execution when
Docker is unavailable or RUNNABLE_LIBCRYPTO_NO_DOCKER=1 is set.

Environment overrides:
  RUNNABLE_LIBCRYPTO_NO_DOCKER     Set to 1 to force native WSL/host mode.
  RUNNABLE_LIBCRYPTO_RUN_ROOT      Output root. Default: ./runs-libcrypto
  RUNNABLE_LIBTINYCODE_BUILD_MODE  stage-bundled or rebuild. Default: stage-bundled
  RUNNABLE_LIBCRYPTO_RUN_LABEL     Full-run label. Default: libcrypto-full-<timestamp>
  RUNNABLE_LIBCRYPTO_SKIP_CMP      Set to 1 to skip precision/recall compare.
  RUNNABLE_LIBCRYPTO_FULL_CPUS     Docker CPU limit for full mode. Default: 30
  RUNNABLE_LIBCRYPTO_FULL_MEM_GB   Docker memory limit for full mode. Default: 32

Modes:
  build-only  Build/stage runnable-lift and QEMU V2 libtinycode.
  smoke       Build/stage runtime assets, then run one small libcrypto shard.
  full        Run the full libcrypto.so QEMU V2 experiment and compare phase.
EOF
}

case "$MODE" in
  -h|--help)
    usage
    exit 0
    ;;
  smoke|full|build-only)
    ;;
  *)
    echo "error: unknown mode: $MODE" >&2
    usage >&2
    exit 2
    ;;
esac

run_build() {
  RUNNABLE_LIBCRYPTO_RUN_ROOT="$RUN_ROOT" \
    "$ROOT/build-libtinycode-qemuv2.sh" "${RUNNABLE_LIBTINYCODE_BUILD_MODE:-stage-bundled}"
}

if [[ "$MODE" == "build-only" ]]; then
  RUNNABLE_LIBCRYPTO_RUN_ROOT="$RUN_ROOT" \
    "$ROOT/build-libtinycode-qemuv2.sh" build-only
  exit 0
fi

if [[ "$MODE" == "full" ]]; then
  exec "$ROOT/run-libcrypto-full-qemuv2.sh"
fi

mkdir -p "$RUN_ROOT"
run_build

echo "== Run small libcrypto smoke =="
B="$RR_DIR/build-codex-dynamic-current"
LLVM_LIBDIR="$(llvm-config --libdir 2>/dev/null || llvm-config-18 --libdir 2>/dev/null || true)"
export LD_LIBRARY_PATH="$B/lib/StackAnalysis:$B/lib/BasicAnalyses:$B/lib/Support${LLVM_LIBDIR:+:$LLVM_LIBDIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$B/tools/runnable-lift:$PATH"

SMOKE_ARGS=(
  --workspace-root "$ROOT" \
  --repo-root "$RR_DIR" \
  --groudtruth-repo-root "$ROOT/GroudTruth" \
  --hdd-root "$RUN_ROOT" \
  --run-label "libcrypto-smoke-$(date +%Y%m%d-%H%M%S)" \
  --no-streaming-merge \
  --parallel-workers 1 \
  --max-seeds 1 \
  --max-concurrent-coordinators 1 \
  --shard-concurrency 1 \
  --worker-memory-gb 1 \
  --lift-timeout-sec "${RUNNABLE_LIBCRYPTO_LIFT_TIMEOUT_SEC:-900}" \
  --merge-workers 1 \
  --merge-batch-size 2 \
  --execution-model host-shards \
  --range-mode "${RUNNABLE_LIBCRYPTO_RANGE_MODE:-seed}" \
  --no-rebuild-lift \
  --libtinycode-path "$B/tools/runnable-lift/libtinycode-x86_64.so" \
  --libtinycode-helpers-path "$B/tools/runnable-lift/libtinycode-helpers-x86_64.ll"
)

if [[ "${RUNNABLE_LIBCRYPTO_SKIP_CMP:-0}" == "1" ]]; then
  SMOKE_ARGS+=(--skip-cmp)
fi

python3 "$RR_DIR/runnable/scripts/libcrypto_dynamic_parallel_lift.py" "${SMOKE_ARGS[@]}"
