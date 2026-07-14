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
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

mkdir -p "$RUN_ROOT"

echo "== Build/stage QEMU V2 libtinycode =="
RUNNABLE_LIBCRYPTO_RUN_ROOT="$RUN_ROOT" \
RUNNABLE_QEMU_V2_IMAGE="$IMAGE" \
RUNNABLE_DOCKER_PLATFORM="$PLATFORM" \
  "$ROOT/build-libtinycode-qemuv2.sh" "$BUILD_MODE"

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
