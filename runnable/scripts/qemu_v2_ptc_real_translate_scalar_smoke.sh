#!/usr/bin/env bash
#
# Narrow PTC migration smoke: prove that real QEMU 10.2.3 TCG walker data can
# be converted into a non-empty PTCInstructionList-like JSON model for a
# scalar/simple subset. This intentionally remains a prototype model, not the
# runnable-lift in-memory PTC ABI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_PTC_REAL_SCALAR_ROOT:-/tmp/rr-qemu-v2-upstream-probes/ptc-real-translate-scalar-smoke}"
QEMU_SRC="${RUNNABLE_QEMU_V2_UPSTREAM_SRC:-/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3}"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-3}"
FRESH=0
SKIP_WALKER=0

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_ptc_real_translate_scalar_smoke.sh [options]

Options:
  --scratch-root DIR  Output/build scratch root.
                      Default: /tmp/rr-qemu-v2-upstream-probes/ptc-real-translate-scalar-smoke
  --qemu-src DIR      Existing unpatched QEMU 10.2.3 source tree to copy when available.
                      Default: /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3
  --jobs N, -j N      QEMU/ninja parallelism. Default: 3 or RUNNABLE_QEMU_V2_JOBS.
  --fresh             Remove this smoke's scratch root before running.
  --skip-walker       Reuse an existing walker dump under the scratch root.
  -h, --help          Show this help.

Outputs:
  $SCRATCH_ROOT/walker/dumps/avx2-vex.tcg-op-walk.jsonl
  $SCRATCH_ROOT/dumps/scalar-simple.tcg-op-walk.jsonl
  $SCRATCH_ROOT/dumps/scalar-simple.ptc-v2-manifest.json
  $SCRATCH_ROOT/dumps/scalar-simple.ptc-conversion-model.json
  $SCRATCH_ROOT/dumps/scalar-simple.smoke-summary.json
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
    --skip-walker)
      SKIP_WALKER=1
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
WALKER_ROOT="$SCRATCH_ROOT/walker"
OUT_DIR="$SCRATCH_ROOT/dumps"
WALKER_JSONL="$WALKER_ROOT/dumps/avx2-vex.tcg-op-walk.jsonl"
SCALAR_JSONL="$OUT_DIR/scalar-simple.tcg-op-walk.jsonl"
MANIFEST_JSON="$OUT_DIR/scalar-simple.ptc-v2-manifest.json"
MANIFEST_HEADER="$OUT_DIR/scalar-simple.ptc-v2-opc.h"
MODEL_JSON="$OUT_DIR/scalar-simple.ptc-conversion-model.json"
SUMMARY_JSON="$OUT_DIR/scalar-simple.smoke-summary.json"

if [[ "$FRESH" -eq 1 ]]; then
  rm -rf "$SCRATCH_ROOT"
fi
mkdir -p "$OUT_DIR"

require_tool python3
require_tool bash

if [[ "$SKIP_WALKER" -eq 0 ]]; then
  log "Running real QEMU 10.2.3 TCG walker probe under $WALKER_ROOT"
  walker_args=(
    "--scratch-root" "$WALKER_ROOT"
    "--jobs" "$JOBS"
  )
  if [[ -d "$QEMU_SRC" ]]; then
    walker_args+=("--qemu-src" "$QEMU_SRC" "--skip-download")
  fi
  bash "$SCRIPT_DIR/qemu_v2_ptc_tcg_op_walker_probe.sh" "${walker_args[@]}"
else
  log "Reusing existing walker dump under $WALKER_ROOT"
fi

[[ -s "$WALKER_JSONL" ]] || die "walker dump is missing or empty: $WALKER_JSONL"
if ! grep -q '"record":"op"' "$WALKER_JSONL"; then
  die "walker dump has no TCG op records, likely an empty stub path: $WALKER_JSONL"
fi

log "Filtering walker JSONL to scalar/simple op records"
python3 - "$WALKER_JSONL" "$SCALAR_JSONL" <<'PY'
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
vector_or_v2_names = {
    "mov_vec",
    "ld_vec",
    "st_vec",
    "extract",
    "qemu_ld2",
    "qemu_st2",
}
blocked_prefixes = ("v",)
stats = {
    "input_lines": 0,
    "output_lines": 0,
    "input_ops": 0,
    "scalar_ops": 0,
    "vector_or_v2_ops_dropped": 0,
    "temp_records": 0,
    "metadata_records": 0,
}

with src.open() as in_stream, dst.open("w") as out_stream:
    for line in in_stream:
        if not line.strip():
            continue
        stats["input_lines"] += 1
        record = json.loads(line)
        kind = record.get("record") or record.get("event")
        if kind == "op":
            stats["input_ops"] += 1
            name = record.get("name")
            param1 = record.get("param1")
            if (
                name in vector_or_v2_names
                or (isinstance(name, str) and name.startswith(blocked_prefixes) and name.endswith("_vec"))
                or param1 in {2, 3, 4, 5}
            ):
                stats["vector_or_v2_ops_dropped"] += 1
                continue
            stats["scalar_ops"] += 1
        elif kind == "temp":
            stats["temp_records"] += 1
        else:
            stats["metadata_records"] += 1
        out_stream.write(json.dumps(record, sort_keys=True, separators=(",", ":")))
        out_stream.write("\n")
        stats["output_lines"] += 1

if stats["input_ops"] <= 0:
    raise SystemExit(f"no TCG op records in walker dump: {src}")
if stats["scalar_ops"] <= 0:
    raise SystemExit(f"no scalar/simple op records after filtering: {src}")
if stats["output_lines"] <= 0:
    raise SystemExit(f"filtered scalar JSONL is empty: {dst}")

print(json.dumps(stats, sort_keys=True))
PY

[[ -s "$SCALAR_JSONL" ]] || die "scalar/simple JSONL is empty: $SCALAR_JSONL"
if ! grep -q '"record":"op"' "$SCALAR_JSONL"; then
  die "scalar/simple JSONL has no op records after filtering: $SCALAR_JSONL"
fi

log "Generating scalar manifest from walker JSONL"
python3 "$SCRIPT_DIR/qemu_v2_ptc_v2_manifest.py" \
  --inventory "$OUT_DIR/scalar-simple.derived.ptc-inventory.json" \
  --walker-jsonl "$SCALAR_JSONL" \
  --source-filter walker-jsonl \
  --tmp-dir "$OUT_DIR/manifest-tmp" \
  --json-out "$MANIFEST_JSON" \
  --header-out "$MANIFEST_HEADER"

[[ -s "$MANIFEST_JSON" ]] || die "manifest generation produced no JSON: $MANIFEST_JSON"

log "Converting scalar walker JSONL to PTCInstructionList-like model"
python3 "$SCRIPT_DIR/qemu_v2_ptc_convert_walker_jsonl.py" \
  --walker-jsonl "$SCALAR_JSONL" \
  --manifest "$MANIFEST_JSON" \
  --json-out "$MODEL_JSON"

[[ -s "$MODEL_JSON" ]] || die "converter produced no model JSON: $MODEL_JSON"

log "Asserting non-empty scalar PTC-like model and no rejected instructions"
python3 - "$WALKER_JSONL" "$SCALAR_JSONL" "$MANIFEST_JSON" "$MODEL_JSON" "$SUMMARY_JSON" "$SCRATCH_ROOT" <<'PY'
import json
import sys
from pathlib import Path

walker_path, scalar_path, manifest_path, model_path, summary_path, scratch_root = map(Path, sys.argv[1:])
with model_path.open() as stream:
    model = json.load(stream)
summary = model.get("summary", {})
instruction_count = int(summary.get("instruction_count", model.get("instruction_count", 0)))
argument_count = int(summary.get("argument_count", model.get("argument_count", 0)))
rejected = int(summary.get("rejected", 0))
emitted = int(summary.get("emitted", 0))
vector_schema = int(summary.get("by_emit_kind", {}).get("vector-schema-required", 0))
ptc_v2_ops = int(summary.get("by_emit_kind", {}).get("ptc-v2-op", 0))

if instruction_count <= 0:
    raise SystemExit(f"instruction_count must be > 0, got {instruction_count}: {model_path}")
if argument_count <= 0:
    raise SystemExit(f"argument_count must be > 0, got {argument_count}: {model_path}")
if emitted <= 0:
    raise SystemExit(f"emitted must be > 0, got {emitted}: {model_path}")
if rejected != 0:
    raise SystemExit(f"rejected must be 0 for scalar smoke, got {rejected}: {model_path}")
if vector_schema != 0:
    raise SystemExit(f"scalar smoke unexpectedly emitted vector schemas: {vector_schema}: {model_path}")
if ptc_v2_ops != 0:
    raise SystemExit(f"scalar smoke unexpectedly needed PTC v2 opcodes: {ptc_v2_ops}: {model_path}")
if model.get("model_policy", {}).get("not_runnable_lift_abi") is not True:
    raise SystemExit("model is missing explicit not_runnable_lift_abi policy")

result = {
    "status": "passed",
    "scratch_root": str(scratch_root),
    "walker_jsonl": str(walker_path),
    "scalar_jsonl": str(scalar_path),
    "manifest_json": str(manifest_path),
    "model_json": str(model_path),
    "instruction_count": instruction_count,
    "argument_count": argument_count,
    "temp_count": int(summary.get("temp_count", model.get("temp_count", 0))),
    "emitted": emitted,
    "rejected": rejected,
    "by_emit_kind": summary.get("by_emit_kind", {}),
    "by_manifest_category": summary.get("by_manifest_category", {}),
    "by_emit_opcode": summary.get("by_emit_opcode", {}),
    "real_pieces": [
        "QEMU 10.2.3 linux-user translation executed by patched throwaway C walker",
        "TCG op/temp records read from walker JSONL",
        "manifest generated from walker JSONL evidence",
    ],
    "prototype_pieces": [
        "PTCInstructionList-like JSON model",
        "raw walker TCGArg preservation instead of C ABI argument allocation",
        "PTCTemp-like JSON projection instead of runnable-lift PTCTemp memory",
    ],
}
summary_path.parent.mkdir(parents=True, exist_ok=True)
with summary_path.open("w") as stream:
    json.dump(result, stream, indent=2, sort_keys=True)
    stream.write("\n")
print(json.dumps(result, sort_keys=True))
PY

cat <<EOF

Scalar PTC real-translate smoke passed.
  Scratch root: $SCRATCH_ROOT
  Walker JSONL: $WALKER_JSONL
  Scalar JSONL: $SCALAR_JSONL
  Manifest:     $MANIFEST_JSON
  Model:        $MODEL_JSON
  Summary:      $SUMMARY_JSON
EOF
