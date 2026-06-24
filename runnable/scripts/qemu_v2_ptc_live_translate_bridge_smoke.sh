#!/usr/bin/env bash
#
# Minimal bridge spike: regenerate the live QEMU walker/model immediately
# before building and running the existing dynamic ptc_translate smoke.
#
# This does not yet embed live translation inside ptc_translate. It proves the
# bridge path is not stale by chaining the real walker smoke and the dynamic
# library smoke in one end-to-end run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_PTC_LIVE_BRIDGE_ROOT:-/tmp/rr-qemu-v2-upstream-probes/ptc-live-translate-bridge-smoke}"
QEMU_SRC="${RUNNABLE_QEMU_V2_UPSTREAM_SRC:-/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3}"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-3}"
FRESH=0

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_ptc_live_translate_bridge_smoke.sh [options]

Options:
  --scratch-root DIR  Output/build scratch root.
                      Default: /tmp/rr-qemu-v2-upstream-probes/ptc-live-translate-bridge-smoke
  --qemu-src DIR      Existing unpatched QEMU 10.2.3 source tree to copy when available.
                      Default: /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3
  --jobs N, -j N      QEMU/ninja parallelism. Default: 3 or RUNNABLE_QEMU_V2_JOBS.
  --fresh             Remove this smoke's scratch root before running.
  -h, --help          Show this help.

Outputs:
  $SCRATCH_ROOT/real/
  $SCRATCH_ROOT/dynamic/
  $SCRATCH_ROOT/qemu_v2_ptc_live_translate_bridge_smoke.summary.json
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

abs_path() {
  local input="$1"
  if [[ "$input" = /* ]]; then
    printf '%s\n' "$input"
  else
    printf '%s/%s\n' "$PWD" "$input"
  fi
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scratch-root)
      SCRATCH_ROOT="$(abs_path "${2:?missing value for --scratch-root}")"
      shift 2
      ;;
    --qemu-src)
      QEMU_SRC="$(abs_path "${2:?missing value for --qemu-src}")"
      shift 2
      ;;
    --jobs|-j)
      JOBS="${2:?missing value for --jobs}"
      shift 2
      ;;
    --fresh)
      FRESH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [[ "$JOBS" -lt 1 ]]; then
  die "--jobs must be a positive integer: $JOBS"
fi

SCRATCH_ROOT="$(abs_path "$SCRATCH_ROOT")"
QEMU_SRC="$(abs_path "$QEMU_SRC")"
REAL_ROOT="$SCRATCH_ROOT/real"
DYNAMIC_ROOT="$SCRATCH_ROOT/dynamic"
REAL_SUMMARY_JSON="$REAL_ROOT/dumps/scalar-simple.smoke-summary.json"
MODEL_JSON="$REAL_ROOT/dumps/scalar-simple.ptc-conversion-model.json"
DYNAMIC_SUMMARY_JSON="$DYNAMIC_ROOT/qemu_v2_ptc_dynamic_scalar_translate_smoke.summary.json"
BRIDGE_SUMMARY_JSON="$SCRATCH_ROOT/qemu_v2_ptc_live_translate_bridge_smoke.summary.json"

if [[ "$FRESH" -eq 1 ]]; then
  rm -rf "$SCRATCH_ROOT"
fi
mkdir -p "$SCRATCH_ROOT"

require_tool python3
require_tool bash

log "Regenerating live walker/model evidence"
real_args=(
  "--scratch-root" "$REAL_ROOT"
  "--qemu-src" "$QEMU_SRC"
  "--jobs" "$JOBS"
  "--fresh"
)
bash "$SCRIPT_DIR/qemu_v2_ptc_real_translate_scalar_smoke.sh" "${real_args[@]}"

[[ -s "$MODEL_JSON" ]] || die "live scalar model is missing or empty after real smoke: $MODEL_JSON"

log "Building and running dynamic ptc_translate smoke from the freshly regenerated model"
dynamic_args=(
  "--scratch-root" "$DYNAMIC_ROOT"
  "--scalar-smoke-root" "$REAL_ROOT"
  "--model-json" "$MODEL_JSON"
  "--qemu-src" "$QEMU_SRC"
  "--jobs" "$JOBS"
  "--fresh"
)
bash "$SCRIPT_DIR/qemu_v2_ptc_dynamic_scalar_translate_smoke.sh" "${dynamic_args[@]}"

[[ -s "$REAL_SUMMARY_JSON" ]] || die "missing real-smoke summary: $REAL_SUMMARY_JSON"
[[ -s "$DYNAMIC_SUMMARY_JSON" ]] || die "missing dynamic-smoke summary: $DYNAMIC_SUMMARY_JSON"

python3 - "$REAL_SUMMARY_JSON" "$DYNAMIC_SUMMARY_JSON" "$BRIDGE_SUMMARY_JSON" "$SCRATCH_ROOT" "$MODEL_JSON" <<'PY'
import json
import sys
from pathlib import Path

real_summary_path = Path(sys.argv[1])
dynamic_summary_path = Path(sys.argv[2])
bridge_summary_path = Path(sys.argv[3])
scratch_root = Path(sys.argv[4])
model_path = Path(sys.argv[5])

with real_summary_path.open() as stream:
    real_summary = json.load(stream)
with dynamic_summary_path.open() as stream:
    dynamic_summary = json.load(stream)

bridge_summary = {
    "status": "passed",
    "scratch_root": str(scratch_root),
    "live_walker_regenerated_same_run": True,
    "real_summary_json": str(real_summary_path),
    "dynamic_summary_json": str(dynamic_summary_path),
    "model_json": str(model_path),
    "live_real": real_summary,
    "dynamic": dynamic_summary,
    "limitations": [
        "ptc_translate still uses the regenerated scalar-model-backed payload",
        "the live QEMU walker/model step is still outside the dynamic library itself",
        "this is an end-to-end freshness bridge, not a live translation bridge",
    ],
}
bridge_summary_path.parent.mkdir(parents=True, exist_ok=True)
with bridge_summary_path.open("w") as stream:
    json.dump(bridge_summary, stream, indent=2, sort_keys=True)
    stream.write("\n")
print(json.dumps({
    "scratch_root": str(scratch_root),
    "live_walker_regenerated_same_run": True,
    "real_instruction_count": real_summary.get("instruction_count"),
    "real_argument_count": real_summary.get("argument_count"),
    "real_temp_count": real_summary.get("temp_count"),
    "dynamic_instruction_count": dynamic_summary.get("instruction_count"),
    "dynamic_argument_count": dynamic_summary.get("argument_count"),
    "dynamic_temp_count": dynamic_summary.get("temp_count"),
    "library_path": dynamic_summary.get("library_path"),
}, sort_keys=True))
PY

cat <<EOF
bridge smoke ok:
  scratch_root=$SCRATCH_ROOT
  live_walker_regenerated_same_run=1
  real_summary=$REAL_SUMMARY_JSON
  dynamic_summary=$DYNAMIC_SUMMARY_JSON
  bridge_summary=$BRIDGE_SUMMARY_JSON
EOF
