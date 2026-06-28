#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
WORKSPACE_ROOT="$(cd "$RR_DIR/.." && pwd -P)"
DOCKER_IMAGE="${RUNNABLE_QEMU_V2_LIBCRYPTO_IMAGE:-${RUNNABLE_QEMU_V2_IMAGE:-rr_qemu_v2_runtime:latest}}"
RUNTIME_MODE="${RUNNABLE_QEMU_V2_LIBCRYPTO_RUNTIME_MODE:-auto}"
SCRATCH_ROOT="${RUNNABLE_QEMU_V2_LIBCRYPTO_SCRATCH_ROOT:-/tmp/rr-qemu-v2-libcrypto-canonical-subset}"
RUNNABLE_LIFT_BIN="${RUNNABLE_QEMU_V2_LIBCRYPTO_RUNNABLE_LIFT:-$RR_DIR/build-bionic/runnable-lift}"
LIBTINYCODE_PATH="${RUNNABLE_QEMU_V2_LIBCRYPTO_LIBTINYCODE:-$RR_DIR/build-codex-dynamic-current/tools/runnable-lift/libtinycode-x86_64.so}"
LIBHELPERS_PATH="${RUNNABLE_QEMU_V2_LIBCRYPTO_HELPERS:-}"
EARLY_LINKED_PATH="${RUNNABLE_QEMU_V2_LIBCRYPTO_EARLY_LINKED:-}"
DEFAULT_LIVE_SIDECAR_ROOT="/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke"
LIVE_SIDECAR_ROOT="${RUNNABLE_QEMU_V2_LIBCRYPTO_LIVE_SIDECAR_ROOT:-$DEFAULT_LIVE_SIDECAR_ROOT}"
LIVE_SIDECAR_ROOT_EXPLICIT=0
FORCE_BIONIC_REBUILD="${RUNNABLE_QEMU_V2_LIBCRYPTO_FORCE_BIONIC_REBUILD:-auto}"
BINARY_PATH="${RUNNABLE_QEMU_V2_LIBCRYPTO_BINARY:-}"
SYMBOL_NAME="${RUNNABLE_QEMU_V2_LIBCRYPTO_SYMBOL:-SHA1@@OPENSSL_3.0.0}"
ENTRY_HEX="${RUNNABLE_QEMU_V2_LIBCRYPTO_ENTRY:-0x50304f30}"
SYMBOL_ENTRY_HEX=""
RUNNABLE_BASE="${RUNNABLE_QEMU_V2_LIBCRYPTO_BASE:-0x50000000}"
TEXT_START_HEX="${RUNNABLE_QEMU_V2_LIBCRYPTO_TEXT_START:-}"
TEXT_END_HEX="${RUNNABLE_QEMU_V2_LIBCRYPTO_TEXT_END:-}"
TIMEOUT_SEC="${RUNNABLE_QEMU_V2_LIBCRYPTO_TIMEOUT_SEC:-600}"
PARALLEL_WORKERS="${RUNNABLE_QEMU_V2_LIBCRYPTO_PARALLEL_WORKERS:-2}"
KEEP_WORKER_FRAGMENTS="${RUNNABLE_QEMU_V2_LIBCRYPTO_KEEP_WORKER_FRAGMENTS:-0}"
LABEL="${RUNNABLE_QEMU_V2_LIBCRYPTO_LABEL:-sha1}"
SKIP_CMP=0
SIDECAR_CAPTURE_SCRIPT="$SCRIPT_DIR/qemu_v2_ptc_libcrypto_sidecar_capture.sh"
declare -a STATIC_FALLBACK_PROFILES=()
declare -a STATIC_FALLBACK_SYMBOL_REGEXES=()

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_ptc_libcrypto_canonical_subset.sh [options]

Options:
  --scratch-root DIR
  --runnable-lift PATH
  --libtinycode PATH
  --helpers PATH
  --early-linked PATH
  --live-sidecar-root DIR
  --force-bionic-rebuild MODE
  --runtime-mode MODE
  --binary PATH
  --symbol NAME
  --entry HEX
  --runnable-base HEX
  --text-start HEX
  --text-end HEX
  --timeout-sec N
  --parallel-workers N
  --keep-worker-fragments
  --static-fallback-profile PROFILE
  --static-fallback-symbol-regex REGEX
  --label NAME
  --skip-cmp
  -h, --help

This stages a build-tree runnable-lift next to a chosen QEMU V2 libtinycode
artifact, runs one real libcrypto.so.3 worklist lift inside the configured
runtime container, and optionally invokes the canonical compare wrapper.

Runtime mode:
  auto   Default. Use direct in-container execution when RUNNABLE_QEMU_V2_IN_CONTAINER=1,
         otherwise launch the configured Docker image.
  docker Always launch the configured Docker image.
  direct Run the runtime commands directly in the current environment.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

abs_path() {
  local input="$1"
  if [[ "$input" = /* ]]; then
    printf '%s\n' "$input"
  else
    printf '%s/%s\n' "$PWD" "$input"
  fi
}

effective_runtime_mode() {
  case "$RUNTIME_MODE" in
    auto)
      if [[ "${RUNNABLE_QEMU_V2_IN_CONTAINER:-0}" == "1" ]]; then
        printf 'direct\n'
      else
        printf 'docker\n'
      fi
      ;;
    docker|direct)
      printf '%s\n' "$RUNTIME_MODE"
      ;;
    *)
      die "invalid --runtime-mode: $RUNTIME_MODE"
      ;;
  esac
}

resolve_runtime_path() {
  local input="$1"
  case "$input" in
    /workspace/Runnable-Rewriting)
      printf '%s\n' "$RR_DIR"
      ;;
    /workspace/Runnable-Rewriting/*)
      printf '%s/%s\n' "$RR_DIR" "${input#/workspace/Runnable-Rewriting/}"
      ;;
    /workspace)
      printf '%s\n' "$WORKSPACE_ROOT"
      ;;
    /workspace/*)
      printf '%s/%s\n' "$WORKSPACE_ROOT" "${input#/workspace/}"
      ;;
    /root/Runnable-Rewriting)
      printf '%s\n' "$RR_DIR"
      ;;
    /root/Runnable-Rewriting/*)
      printf '%s/%s\n' "$RR_DIR" "${input#/root/Runnable-Rewriting/}"
      ;;
    /subset)
      printf '%s\n' "$SCRATCH_ROOT/$LABEL"
      ;;
    /subset/*)
      printf '%s/%s\n' "$SCRATCH_ROOT/$LABEL" "${input#/subset/}"
      ;;
    *)
      printf '%s\n' "$input"
      ;;
  esac
}

resolve_ld_library_path() {
  local input="$1"
  local component resolved
  local -a parts=()

  IFS=: read -r -a components <<<"$input"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    resolved="$(resolve_runtime_path "$component")"
    if [[ -d "$resolved" ]]; then
      parts+=("$resolved")
    fi
  done

  if [[ "${#parts[@]}" -eq 0 ]]; then
    return 0
  fi

  (
    IFS=:
    printf '%s\n' "${parts[*]}"
  )
}

runtime_alias_path() {
  local input="$1"
  case "$input" in
    "$RR_DIR")
      printf '/workspace/Runnable-Rewriting\n'
      ;;
    "$RR_DIR"/*)
      printf '/workspace/Runnable-Rewriting/%s\n' "${input#"$RR_DIR"/}"
      ;;
    "$WORKSPACE_ROOT")
      printf '/workspace\n'
      ;;
    "$WORKSPACE_ROOT"/*)
      printf '/workspace/%s\n' "${input#"$WORKSPACE_ROOT"/}"
      ;;
    *)
      printf '%s\n' "$input"
      ;;
  esac
}

resolve_runtime_command_text() {
  local command="$1"
  command="${command//\/workspace\/Runnable-Rewriting/$RR_DIR}"
  command="${command//\/root\/Runnable-Rewriting/$RR_DIR}"
  command="${command//\/workspace/$WORKSPACE_ROOT}"
  command="${command//\/subset/$SCRATCH_ROOT\/$LABEL}"
  printf '%s' "$command"
}

append_runtime_dir() {
  local runtime_dir="$1"
  local existing
  [[ -n "$runtime_dir" ]] || return 0
  for existing in "${BIONIC_LD_LIBRARY_PARTS[@]}"; do
    [[ "$existing" == "$runtime_dir" ]] && return 0
  done
  BIONIC_LD_LIBRARY_PARTS+=("$runtime_dir")
}

append_existing_runtime_dir() {
  local runtime_dir="$1"
  local resolved_dir
  resolved_dir="$(resolve_runtime_path "$runtime_dir")"
  [[ -d "$resolved_dir" ]] || return 0
  append_runtime_dir "$runtime_dir"
}

append_default_llvm_runtime_dirs() {
  local candidate llvm_libdir
  if llvm_libdir="$(llvm-config --libdir 2>/dev/null)" && [[ -n "$llvm_libdir" ]]; then
    append_runtime_dir "$llvm_libdir"
  fi
  for candidate in /usr/lib/llvm-18/lib /usr/lib/llvm-17/lib /usr/lib/llvm-16/lib; do
    append_runtime_dir "$candidate"
  done
}

append_legacy_runtime_root_dirs() {
  if [[ "$DOCKER_IMAGE" == rr_bionic_exportfs* ]]; then
    append_runtime_dir "/root/Runnable-Rewriting/build/llvm-release/lib"
    append_runtime_dir "/root/Runnable-Rewriting/root/lib"
    return 0
  fi

  append_existing_runtime_dir "$(runtime_alias_path "$RR_DIR/root/lib")"
}

default_bionic_ld_library_path() {
  local lift_root="$1"
  local lift_root_runtime
  lift_root_runtime="$(runtime_alias_path "$lift_root")"

  local -a BIONIC_LD_LIBRARY_PARTS=()
  append_existing_runtime_dir "$lift_root_runtime/lib/Support"
  append_existing_runtime_dir "$lift_root_runtime/lib/BasicAnalyses"
  append_existing_runtime_dir "$lift_root_runtime/lib/Dump"
  append_existing_runtime_dir "$lift_root_runtime/lib/FunctionIsolation"
  append_existing_runtime_dir "$lift_root_runtime/lib/StackAnalysis"
  append_default_llvm_runtime_dirs
  append_legacy_runtime_root_dirs

  if [[ "${#BIONIC_LD_LIBRARY_PARTS[@]}" -eq 0 ]]; then
    return 0
  fi

  (
    IFS=:
    printf '%s\n' "${BIONIC_LD_LIBRARY_PARTS[*]}"
  )
}

run_bionic_command() {
  local workdir="$1"
  local ld_library_path="$2"
  local command="$3"
  local mode resolved_workdir resolved_ld_library_path resolved_command
  mode="$(effective_runtime_mode)"

  case "$mode" in
    direct)
      resolved_workdir="$(resolve_runtime_path "$workdir")"
      resolved_ld_library_path="$(resolve_ld_library_path "$ld_library_path")"
      resolved_command="$(resolve_runtime_command_text "$command")"
      (
        cd "$resolved_workdir"
        if [[ -n "$resolved_ld_library_path" ]]; then
          export LD_LIBRARY_PATH="$resolved_ld_library_path"
        fi
        bash -lc "$resolved_command"
      )
      ;;
    docker)
      local -a docker_args=(
        docker run --rm
        -v "$WORKSPACE_ROOT":/workspace
        -v "$SCRATCH_ROOT/$LABEL":/subset
        -e LD_LIBRARY_PATH="$ld_library_path"
        -w "$workdir"
      )
      if [[ -f /usr/lib/x86_64-linux-gnu/libtinfo.so.6.4 ]]; then
        docker_args+=(-v /usr/lib/x86_64-linux-gnu/libtinfo.so.6.4:/usr/lib/x86_64-linux-gnu/libtinfo.so.6.4:ro)
      fi
      if [[ -f /usr/lib/x86_64-linux-gnu/libtinfo.so.6 ]]; then
        docker_args+=(
          -v /usr/lib/x86_64-linux-gnu/libtinfo.so.6:/usr/lib/x86_64-linux-gnu/libtinfo.so.6:ro
          -v /usr/lib/x86_64-linux-gnu/libtinfo.so.6:/lib/x86_64-linux-gnu/libtinfo.so.6:ro
        )
      elif [[ -f /usr/lib/x86_64-linux-gnu/libtinfo.so.6.4 ]]; then
        docker_args+=(
          -v /usr/lib/x86_64-linux-gnu/libtinfo.so.6.4:/usr/lib/x86_64-linux-gnu/libtinfo.so.6:ro
          -v /usr/lib/x86_64-linux-gnu/libtinfo.so.6.4:/lib/x86_64-linux-gnu/libtinfo.so.6:ro
        )
      fi
      "${docker_args[@]}" "$DOCKER_IMAGE" bash -lc "$command"
      ;;
  esac
}

sanitize_label_component() {
  local raw="$1"
  printf '%s' "$raw" | tr '@[:upper:]' '-[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

should_try_bionic_rebuild() {
  case "$FORCE_BIONIC_REBUILD" in
    1|true|yes|always)
      return 0
      ;;
    0|false|no|never)
      return 1
      ;;
    auto)
      if ! sidecar_replay_inputs_present; then
        return 1
      fi
      if is_default_live_sidecar_root; then
        return 1
      fi
      return 0
      return
      ;;
    *)
      die "invalid --force-bionic-rebuild mode: $FORCE_BIONIC_REBUILD"
      ;;
  esac
}

sidecar_replay_inputs_present() {
  [[ -f "$LIVE_SIDECAR_ROOT/sidecar/sidecar.payload.txt" ]] \
    && [[ -f "$LIVE_SIDECAR_ROOT/sidecar/sidecar.model.json" ]] \
    && [[ -f "$LIVE_SIDECAR_ROOT/sidecar/sidecar.summary.json" ]]
}

is_default_live_sidecar_root() {
  [[ "$(abs_path "$LIVE_SIDECAR_ROOT")" == "$(abs_path "$DEFAULT_LIVE_SIDECAR_ROOT")" ]]
}

stage_live_sidecar_inputs() {
  local staged_root="$SCRATCH_ROOT/$LABEL/live-sidecar-input"
  mkdir -p "$staged_root"
  cp "$LIVE_SIDECAR_ROOT/sidecar/sidecar.payload.txt" "$staged_root/sidecar.payload.txt"
  cp "$LIVE_SIDECAR_ROOT/sidecar/sidecar.model.json" "$staged_root/sidecar.model.json"
  cp "$LIVE_SIDECAR_ROOT/sidecar/sidecar.summary.json" "$staged_root/sidecar.summary.json"
}

prepare_bionic_live_sidecar_library() {
  local payload_source model_source summary_source rebuild_root rebuild_log rebuilt_library
  payload_source="$LIVE_SIDECAR_ROOT/sidecar/sidecar.payload.txt"
  model_source="$LIVE_SIDECAR_ROOT/sidecar/sidecar.model.json"
  summary_source="$LIVE_SIDECAR_ROOT/sidecar/sidecar.summary.json"
  rebuild_root="$SCRATCH_ROOT/$LABEL/bionic-live-sidecar"
  rebuild_log="$SCRATCH_ROOT/$LABEL/bionic-live-sidecar.rebuild.log"
  rebuilt_library="$rebuild_root/libtinycode-x86_64.so"

  [[ -f "$payload_source" ]] || return 1
  [[ -f "$model_source" ]] || return 1
  [[ -f "$summary_source" ]] || return 1

  mkdir -p "$rebuild_root"
  run_bionic_command "/workspace/Runnable-Rewriting" "" "
set -euo pipefail
bash runnable/scripts/qemu_v2_ptc_live_sidecar_translate_smoke.sh \
  --scratch-root /subset/bionic-live-sidecar \
  --payload-source /subset/live-sidecar-input/sidecar.payload.txt \
  --model-source /subset/live-sidecar-input/sidecar.model.json \
  --summary-source /subset/live-sidecar-input/sidecar.summary.json \
  --fresh
" >"$rebuild_log" 2>&1 || return 1

  [[ -f "$rebuilt_library" ]] || return 1
  LIBTINYCODE_PATH="$rebuilt_library"
  BIONIC_REBUILT_LIBTINYCODE=1
  BIONIC_REBUILT_LIBTINYCODE_LOG="$rebuild_log"
  BIONIC_REBUILT_LIBTINYCODE_SOURCE_ROOT="$LIVE_SIDECAR_ROOT"
  return 0
}

rebase_entry_if_needed() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys

entry = int(sys.argv[1], 0)
base = int(sys.argv[2], 0)
text_start = int(sys.argv[3], 0)
if entry < base:
    print(hex(base + entry))
else:
    print(hex(entry))
PY
}

normalize_compare_pc() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys

pc = int(sys.argv[1], 0)
base = int(sys.argv[2], 0)
text_start = int(sys.argv[3], 0)
text_end = int(sys.argv[4], 0)

if text_start <= pc < text_end:
    print(hex(pc))
    raise SystemExit(0)

rebased = pc - base
if text_start <= rebased < text_end:
    print(hex(rebased))
    raise SystemExit(0)

print(hex(pc))
PY
}

read_sidecar_replay_pc() {
  local model_source="$1"
  python3 - "$model_source" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.is_file():
    raise SystemExit(0)
data = json.loads(path.read_text(encoding="utf-8"))
for inst in data.get("instructions", []):
    model = inst.get("ptc_list_model") or {}
    if model.get("opc") != "debug_insn_start":
        continue
    args = inst.get("args") or []
    if not args:
        continue
    try:
        print(hex(int(str(args[0]).strip(), 0)))
    except ValueError:
        pass
    raise SystemExit(0)
PY
}

build_compare_scope_from_sidecar() {
  local model_source="$1"
  local summary_source="$2"
  local out_path="$3"
  local audit_path="$4"
  python3 - "$model_source" "$summary_source" "$RUNNABLE_BASE" "$TEXT_START_HEX" "$TEXT_END_HEX" "$out_path" "$audit_path" <<'PY'
import json
import sys
from pathlib import Path

model_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
base = int(sys.argv[3], 0)
text_start = int(sys.argv[4], 0)
text_end = int(sys.argv[5], 0)
out_path = Path(sys.argv[6])
audit_path = Path(sys.argv[7])


def load_json(path: Path):
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def candidate_ints(value):
    if isinstance(value, int):
        yield value
        return
    if isinstance(value, str):
        raw = value.strip()
        if not raw:
            return
        try:
            yield int(raw, 0)
        except ValueError:
            return
        return
    if isinstance(value, list):
        for item in value:
            yield from candidate_ints(item)
        return
    if isinstance(value, dict):
        for key in ("pc", "guest_pc", "replay_pc", "start_pc", "instruction_start_pc", "address", "va"):
            if key in value:
                yield from candidate_ints(value[key])


def normalize_pc(raw_pc: int):
    candidates = []
    if text_start <= raw_pc < text_end:
        candidates.append(("raw_file_va", raw_pc))
    rebased = raw_pc - base
    if text_start <= rebased < text_end:
        candidates.append(("minus_base", rebased))
    # Prefer no subtraction when already in file VA range, otherwise accept rebased.
    if candidates:
        preferred = sorted(candidates, key=lambda item: 0 if item[0] == "raw_file_va" else 1)[0]
        return preferred
    return None


def extract_debug_insn_pcs(model_payload):
    pcs = []
    for inst in model_payload.get("instructions", []):
        model = inst.get("ptc_list_model") or {}
        if model.get("opc") != "debug_insn_start":
            continue
        args = inst.get("args") or []
        if not args:
            continue
        try:
            pcs.append(int(str(args[0]).strip(), 0))
        except ValueError:
            continue
    return pcs


def extract_summary_pcs(summary_payload):
    roots = []
    queue = [summary_payload]
    while queue:
        current = queue.pop(0)
        if isinstance(current, dict):
            for key, value in current.items():
                if key in {"instructions", "inst_starts", "instruction_starts", "debug_instruction_starts", "debug_insn_starts"}:
                    roots.extend(candidate_ints(value))
                elif isinstance(value, (dict, list)):
                    queue.append(value)
        elif isinstance(current, list):
            queue.extend(current)
    return roots


model_payload = load_json(model_path)
summary_payload = load_json(summary_path)
raw_pcs = []
raw_pcs.extend(extract_debug_insn_pcs(model_payload))
raw_pcs.extend(extract_summary_pcs(summary_payload))

normalized = []
audit_entries = []
seen = set()
for raw_pc in raw_pcs:
    if raw_pc in seen:
        continue
    seen.add(raw_pc)
    normalized_entry = normalize_pc(raw_pc)
    if normalized_entry is None:
        audit_entries.append(
            {
                "raw_pc": hex(raw_pc),
                "normalized_pc": None,
                "normalization": "out_of_text_range",
            }
        )
        continue
    mode, value = normalized_entry
    normalized.append(value)
    audit_entries.append(
        {
            "raw_pc": hex(raw_pc),
            "normalized_pc": hex(value),
            "normalization": mode,
        }
    )

unique_normalized = sorted(set(normalized))
out_path.write_text("".join(f"{hex(pc)}\n" for pc in unique_normalized), encoding="utf-8")
audit_payload = {
    "model_path": str(model_path),
    "summary_path": str(summary_path) if summary_path.is_file() else None,
    "runnable_base": hex(base),
    "text_start": hex(text_start),
    "text_end": hex(text_end),
    "raw_pc_count": len(raw_pcs),
    "normalized_pc_count": len(unique_normalized),
    "scope_kind": "pc_whitelist" if unique_normalized else "full_text",
    "entries": audit_entries,
}
audit_path.write_text(json.dumps(audit_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(len(unique_normalized))
PY
}

resolve_symbol_entry() {
  local binary_path="$1"
  local symbol_name="$2"
  python3 - "$binary_path" "$symbol_name" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

binary = Path(sys.argv[1]).resolve()
symbol = sys.argv[2]
output = subprocess.check_output(["readelf", "-Ws", str(binary)], text=True)
pattern = re.compile(r"^\s*\d+:\s*([0-9a-fA-F]+)\s+\d+\s+FUNC\s+\S+\s+\S+\s+\S+\s+(.+?)\s*$")
for line in output.splitlines():
    match = pattern.match(line)
    if not match:
        continue
    value_hex, name = match.groups()
    if name == symbol:
        print(hex(int(value_hex, 16)))
        raise SystemExit(0)
raise SystemExit(f"symbol not found in {binary}: {symbol}")
PY
}

sidecar_model_path_for_root() {
  printf '%s/sidecar/sidecar.model.json\n' "$1"
}

sidecar_replay_pc_for_root() {
  local root="$1"
  local model_source
  model_source="$(sidecar_model_path_for_root "$root")"
  [[ -f "$model_source" ]] || return 1
  read_sidecar_replay_pc "$model_source"
}

emit_sidecar_mismatch_message() {
  local root="$1"
  local actual_pc="$2"
  local expected_pc="$3"
  local suggested_root="$SCRATCH_ROOT/$LABEL/live-sidecar-capture"
  cat <<EOF >&2
error: live sidecar root does not match symbol entry: root=$root replay_pc=${actual_pc:-missing} expected_entry=$expected_pc symbol=$SYMBOL_NAME
error: generate a matching sidecar with:
error:   bash $SIDECAR_CAPTURE_SCRIPT --scratch-root $suggested_root --binary $BINARY_PATH --symbol $SYMBOL_NAME --entry $expected_pc --fresh
EOF
}

capture_live_sidecar_for_symbol() {
  local capture_root="$SCRATCH_ROOT/$LABEL/live-sidecar-capture"
  local walker_root="$SCRATCH_ROOT/_shared-live-sidecar-walker"
  mkdir -p "$capture_root"
  bash "$SIDECAR_CAPTURE_SCRIPT" \
    --scratch-root "$capture_root" \
    --binary "$BINARY_PATH" \
    --symbol "$SYMBOL_NAME" \
    --entry "$SYMBOL_ENTRY_HEX" \
    --walker-root "$walker_root" \
    --fresh
  LIVE_SIDECAR_ROOT="$capture_root"
}

ensure_matching_live_sidecar_root() {
  local replay_pc="" normalized_replay_pc="" normalized_entry_pc=""
  normalized_entry_pc="$(normalize_compare_pc "$SYMBOL_ENTRY_HEX" "$RUNNABLE_BASE" "$TEXT_START_HEX" "$TEXT_END_HEX")"
  if [[ "$LIVE_SIDECAR_ROOT_EXPLICIT" -eq 1 ]]; then
    sidecar_replay_inputs_present || die "explicit --live-sidecar-root is missing replay inputs under: $LIVE_SIDECAR_ROOT"
    replay_pc="$(sidecar_replay_pc_for_root "$LIVE_SIDECAR_ROOT" || true)"
    normalized_replay_pc="$(normalize_compare_pc "${replay_pc:-0x0}" "$RUNNABLE_BASE" "$TEXT_START_HEX" "$TEXT_END_HEX")"
    if [[ -z "$replay_pc" || "$normalized_replay_pc" != "$normalized_entry_pc" ]]; then
      emit_sidecar_mismatch_message "$LIVE_SIDECAR_ROOT" "$replay_pc" "$SYMBOL_ENTRY_HEX"
      exit 1
    fi
    return 0
  fi

  if sidecar_replay_inputs_present; then
    replay_pc="$(sidecar_replay_pc_for_root "$LIVE_SIDECAR_ROOT" || true)"
    normalized_replay_pc="$(normalize_compare_pc "${replay_pc:-0x0}" "$RUNNABLE_BASE" "$TEXT_START_HEX" "$TEXT_END_HEX")"
    if [[ -n "$replay_pc" && "$normalized_replay_pc" == "$normalized_entry_pc" ]]; then
      return 0
    fi
  fi

  capture_live_sidecar_for_symbol
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scratch-root)
      SCRATCH_ROOT="${2:?missing value for --scratch-root}"
      shift 2
      ;;
    --runnable-lift)
      RUNNABLE_LIFT_BIN="${2:?missing value for --runnable-lift}"
      shift 2
      ;;
    --libtinycode)
      LIBTINYCODE_PATH="${2:?missing value for --libtinycode}"
      shift 2
      ;;
    --helpers)
      LIBHELPERS_PATH="${2:?missing value for --helpers}"
      shift 2
      ;;
    --early-linked)
      EARLY_LINKED_PATH="${2:?missing value for --early-linked}"
      shift 2
      ;;
    --live-sidecar-root)
      LIVE_SIDECAR_ROOT="$(abs_path "${2:?missing value for --live-sidecar-root}")"
      LIVE_SIDECAR_ROOT_EXPLICIT=1
      shift 2
      ;;
    --force-bionic-rebuild)
      FORCE_BIONIC_REBUILD="${2:?missing value for --force-bionic-rebuild}"
      shift 2
      ;;
    --runtime-mode)
      RUNTIME_MODE="${2:?missing value for --runtime-mode}"
      shift 2
      ;;
    --binary)
      BINARY_PATH="${2:?missing value for --binary}"
      shift 2
      ;;
    --symbol)
      SYMBOL_NAME="${2:?missing value for --symbol}"
      shift 2
      ;;
    --entry)
      ENTRY_HEX="${2:?missing value for --entry}"
      shift 2
      ;;
    --runnable-base)
      RUNNABLE_BASE="${2:?missing value for --runnable-base}"
      shift 2
      ;;
    --text-start)
      TEXT_START_HEX="${2:?missing value for --text-start}"
      shift 2
      ;;
    --text-end)
      TEXT_END_HEX="${2:?missing value for --text-end}"
      shift 2
      ;;
    --timeout-sec)
      TIMEOUT_SEC="${2:?missing value for --timeout-sec}"
      shift 2
      ;;
    --parallel-workers)
      PARALLEL_WORKERS="${2:?missing value for --parallel-workers}"
      shift 2
      ;;
    --keep-worker-fragments)
      KEEP_WORKER_FRAGMENTS=1
      shift
      ;;
    --static-fallback-profile)
      STATIC_FALLBACK_PROFILES+=("${2:?missing value for --static-fallback-profile}")
      shift 2
      ;;
    --static-fallback-symbol-regex)
      STATIC_FALLBACK_SYMBOL_REGEXES+=("${2:?missing value for --static-fallback-symbol-regex}")
      shift 2
      ;;
    --label)
      LABEL="${2:?missing value for --label}"
      shift 2
      ;;
    --skip-cmp)
      SKIP_CMP=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

LIVE_SIDECAR_ROOT="$(abs_path "$LIVE_SIDECAR_ROOT")"
BIONIC_REBUILT_LIBTINYCODE=0
BIONIC_REBUILT_LIBTINYCODE_LOG=""
BIONIC_REBUILT_LIBTINYCODE_SOURCE_ROOT=""

if [[ -z "$BINARY_PATH" ]]; then
  BINARY_PATH="$(python3 "$RR_DIR/runnable/scripts/libcrypto_bench_paths.py" binary --must-exist)"
fi

if [[ -n "$SYMBOL_NAME" ]]; then
  ENTRY_HEX="$(resolve_symbol_entry "$BINARY_PATH" "$SYMBOL_NAME")"
fi
SYMBOL_ENTRY_HEX="$ENTRY_HEX"

if [[ -z "$LIBHELPERS_PATH" ]]; then
  LIBHELPERS_PATH="$(dirname "$LIBTINYCODE_PATH")/libtinycode-helpers-x86_64.ll"
fi
if [[ -z "$EARLY_LINKED_PATH" ]]; then
  EARLY_LINKED_PATH="$(dirname "$LIBTINYCODE_PATH")/early-linked-x86_64.ll"
fi

[[ -x "$RUNNABLE_LIFT_BIN" ]] || die "runnable-lift is not executable: $RUNNABLE_LIFT_BIN"
[[ -f "$LIBTINYCODE_PATH" ]] || die "libtinycode is missing: $LIBTINYCODE_PATH"
[[ -f "$LIBHELPERS_PATH" ]] || die "helpers file is missing: $LIBHELPERS_PATH"
[[ -f "$EARLY_LINKED_PATH" ]] || die "early-linked file is missing: $EARLY_LINKED_PATH"
[[ -f "$BINARY_PATH" ]] || die "binary is missing: $BINARY_PATH"

if [[ -z "$TEXT_START_HEX" || -z "$TEXT_END_HEX" ]]; then
  TEXT_BOUNDS="$(python3 - "$BINARY_PATH" "$RR_DIR" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[2]) / "runnable" / "scripts"))
from libcrypto_bench_paths import detect_text_bounds  # type: ignore

start, end = detect_text_bounds(Path(sys.argv[1]).resolve())
print(hex(start), hex(end))
PY
)"
  TEXT_START_HEX="${TEXT_START_HEX:-$(awk '{print $1}' <<<"$TEXT_BOUNDS")}"
  TEXT_END_HEX="${TEXT_END_HEX:-$(awk '{print $2}' <<<"$TEXT_BOUNDS")}"
fi

ensure_matching_live_sidecar_root
stage_live_sidecar_inputs

if should_try_bionic_rebuild; then
  if prepare_bionic_live_sidecar_library; then
    if [[ -z "$LIBHELPERS_PATH" ]]; then
      LIBHELPERS_PATH="$RR_DIR/build-codex-dynamic-current/tools/runnable-lift/libtinycode-helpers-x86_64.ll"
    fi
    if [[ -z "$EARLY_LINKED_PATH" ]]; then
      EARLY_LINKED_PATH="$RR_DIR/build-codex-dynamic-current/tools/runnable-lift/early-linked-x86_64.ll"
    fi
  fi
fi

ENTRY_HEX="$(rebase_entry_if_needed "$ENTRY_HEX" "$RUNNABLE_BASE" "$TEXT_START_HEX")"
ABS_RANGE="$(python3 - "$RUNNABLE_BASE" "$TEXT_START_HEX" "$TEXT_END_HEX" <<'PY'
import sys
base = int(sys.argv[1], 0)
text_start = int(sys.argv[2], 0)
text_end = int(sys.argv[3], 0)
print(hex(base + text_start), hex(base + text_end))
PY
)"
ADDR_RANGE_MIN="$(awk '{print $1}' <<<"$ABS_RANGE")"
ADDR_RANGE_MAX="$(awk '{print $2}' <<<"$ABS_RANGE")"

RUN_DIR="$SCRATCH_ROOT/$LABEL/run"
EVAL_DIR="$SCRATCH_ROOT/$LABEL/eval"
SUMMARY_JSON="$SCRATCH_ROOT/$LABEL/qemu_v2_ptc_libcrypto_canonical_subset.summary.json"
INCLUDE_PC_FILE="$EVAL_DIR/compare.include_pcs.txt"
INCLUDE_PC_AUDIT_JSON="$EVAL_DIR/compare.include_pcs.audit.json"
COMPARE_SCOPE_MODE="full_text"
mkdir -p "$RUN_DIR" "$EVAL_DIR"
rm -f "$RUN_DIR"/* "$EVAL_DIR"/* "$SUMMARY_JSON"

cp "$RUNNABLE_LIFT_BIN" "$RUN_DIR/runnable-lift"
cp "$LIBTINYCODE_PATH" "$RUN_DIR/libtinycode-x86_64.so"
cp "$LIBHELPERS_PATH" "$RUN_DIR/libtinycode-helpers-x86_64.ll"
cp "$EARLY_LINKED_PATH" "$RUN_DIR/early-linked-x86_64.ll"
cp "$BINARY_PATH" "$RUN_DIR/libcrypto.so.3"

LIFT_STDOUT="$RUN_DIR/lift.stdout"
LIFT_STDERR="$RUN_DIR/lift.stderr"
LIFT_LL="$RUN_DIR/${LABEL}.ll"
LIFT_RC=0
BIONIC_LD_LIBRARY_PATH="$(default_bionic_ld_library_path "$(dirname "$RUNNABLE_LIFT_BIN")")"
KEEP_WORKER_FRAGMENT_FLAG=""
if [[ "$KEEP_WORKER_FRAGMENTS" == "1" ]]; then
  KEEP_WORKER_FRAGMENT_FLAG="  -keep-worker-fragments \\
"
fi

set +e
run_bionic_command "/subset/run" "$BIONIC_LD_LIBRARY_PATH" "
set -euo pipefail
timeout $TIMEOUT_SEC ./runnable-lift \
  -base=$RUNNABLE_BASE \
  -entry=$ENTRY_HEX \
  -dynamic-parallel \
  -parallel-workers=$PARALLEL_WORKERS \
  -parallel-fragment-dir=/subset/run/fragments \
${KEEP_WORKER_FRAGMENT_FLAG}\
  -use-debug-symbols \
  -no-link \
  -addr-range-min=$ADDR_RANGE_MIN \
  -addr-range-max=$ADDR_RANGE_MAX \
  ./libcrypto.so.3 \
  ./$(basename "$LIFT_LL") \
  >./$(basename "$LIFT_STDOUT") 2>./$(basename "$LIFT_STDERR")
"
LIFT_RC=$?
set -e

BLOCKER_CODE=""
RESULT="passed"
FAILURE_CLASS="none"
CMP_RC=""
CMP_VERDICT_OK=""
CMP_LL_COUNT=""
CMP_PRECISION=""
CMP_RECALL=""
LIFT_SWITCH_CASE_COUNT="0"
LIFT_NEWPC_COUNT="0"
LIFT_BB_COUNT="0"
LIFT_COMMENT_ADDR_COUNT="0"
LIFT_REAL_COMMENT_ADDR_COUNT="0"
LIFT_OI_COUNT="0"
LIFT_PI_COUNT="0"
SIDECAR_REPLAY_PC=""

if [[ -f "$SCRATCH_ROOT/$LABEL/live-sidecar-input/sidecar.model.json" ]]; then
  SIDECAR_REPLAY_PC="$(read_sidecar_replay_pc "$SCRATCH_ROOT/$LABEL/live-sidecar-input/sidecar.model.json" || true)"
fi

if [[ -f "$SCRATCH_ROOT/$LABEL/live-sidecar-input/sidecar.model.json" ]]; then
  INCLUDE_PC_COUNT="$(build_compare_scope_from_sidecar \
    "$SCRATCH_ROOT/$LABEL/live-sidecar-input/sidecar.model.json" \
    "$SCRATCH_ROOT/$LABEL/live-sidecar-input/sidecar.summary.json" \
    "$INCLUDE_PC_FILE" \
    "$INCLUDE_PC_AUDIT_JSON")"
  if [[ "${INCLUDE_PC_COUNT:-0}" -gt 0 ]]; then
    COMPARE_SCOPE_MODE="pc_whitelist"
  else
    rm -f "$INCLUDE_PC_FILE"
  fi
fi

if [[ "$LIFT_RC" -ne 0 ]]; then
  RESULT="failed"
  FAILURE_CLASS="lift-failed"
  if grep -Eq 'GLIBC_[0-9.]+' "$LIFT_STDERR"; then
    BLOCKER_CODE="blocked:libtinycode-glibc-mismatch"
  elif grep -Fq 'real_translation=false' "$LIFT_STDERR"; then
    BLOCKER_CODE="blocked:libtinycode-empty-stub"
  elif [[ "$LIFT_RC" -eq 139 ]]; then
    if grep -Fq 'InstructionTranslator.cpp:832' "$LIFT_STDERR" \
       || grep -Fq 'PTCDump.cpp:258' "$LIFT_STDERR"; then
      BLOCKER_CODE="blocked:canonical-lift-segv:InstructionTranslator.cpp:832"
    else
      BLOCKER_CODE="blocked:canonical-lift-segv:unknown"
    fi
  elif [[ "$LIFT_RC" -eq 124 ]]; then
    BLOCKER_CODE="blocked:lift-timeout"
  else
    BLOCKER_CODE="blocked:lift-failed"
  fi
fi

if [[ -f "$LIFT_LL" ]]; then
  read -r LIFT_SWITCH_CASE_COUNT LIFT_NEWPC_COUNT LIFT_BB_COUNT LIFT_COMMENT_ADDR_COUNT LIFT_REAL_COMMENT_ADDR_COUNT LIFT_OI_COUNT LIFT_PI_COUNT < <(
    python3 - "$LIFT_LL" <<'PY'
import re
import sys
from pathlib import Path

ll_path = Path(sys.argv[1])
text = ll_path.read_text(encoding="utf-8", errors="ignore")
switch_case_count = len(re.findall(r'^\s*i64\s+\d+,\s+label\s+%bb\.0x[0-9a-fA-F]+\w*', text, re.M))
newpc_count = text.count('call void @newpc')
bb_count = len(re.findall(r'^\s*bb\.0x[0-9a-fA-F]+\w*:', text, re.M))
comment_matches = re.findall(r'^\s*;\s*(0x[0-9a-fA-F]+):\s*(.*)$', text, re.M)
comment_count = len(comment_matches)
opcode_re = re.compile(r'^[A-Za-z][A-Za-z0-9.]*$')

def is_real_instruction(payload):
    payload = payload.strip()
    if not payload:
        return False
    token = payload.split(None, 1)[0]
    if token.startswith('<'):
        return False
    if not opcode_re.match(token):
        return False
    if any(ignored in token for ignored in ("nop", "data", "xchg")):
        return False
    return True

real_comment_count = sum(1 for _, payload in comment_matches if is_real_instruction(payload))
oi_count = text.count('!oi')
pi_count = text.count('!pi')
print(f"{switch_case_count} {newpc_count} {bb_count} {comment_count} {real_comment_count} {oi_count} {pi_count}")
PY
  )
fi

if [[ "$RESULT" == "passed" && -n "$SIDECAR_REPLAY_PC" ]]; then
  if python3 - "$SIDECAR_REPLAY_PC" "$SYMBOL_ENTRY_HEX" "$RUNNABLE_BASE" "$TEXT_START_HEX" "$TEXT_END_HEX" <<'PY'
import sys
replay_pc = int(sys.argv[1], 0)
entry_pc = int(sys.argv[2], 0)
base = int(sys.argv[3], 0)
text_start = int(sys.argv[4], 0)
text_end = int(sys.argv[5], 0)

def normalize(pc: int) -> int:
    if text_start <= pc < text_end:
        return pc
    rebased = pc - base
    if text_start <= rebased < text_end:
        return rebased
    return pc

raise SystemExit(0 if normalize(replay_pc) == normalize(entry_pc) else 1)
PY
  then
    :
  else
    RESULT="failed"
    FAILURE_CLASS="lift-failed"
    BLOCKER_CODE="blocked:sidecar-entry-mismatch"
  fi
fi

if [[ "$RESULT" == "passed" ]]; then
  if [[ "$LIFT_SWITCH_CASE_COUNT" -eq 0 && "$LIFT_NEWPC_COUNT" -eq 0 \
        && "$LIFT_BB_COUNT" -eq 0 && "$LIFT_COMMENT_ADDR_COUNT" -eq 0 \
        && "$LIFT_OI_COUNT" -eq 0 && "$LIFT_PI_COUNT" -eq 0 ]]; then
    RESULT="failed"
    FAILURE_CLASS="lift-failed"
    if [[ -z "$BLOCKER_CODE" ]]; then
      BLOCKER_CODE="blocked:lift-no-dispatch-blocks"
    fi
  fi
fi

if [[ "$RESULT" == "passed" && "$SKIP_CMP" -ne 0 ]]; then
  RESULT="failed"
  FAILURE_CLASS="lift-failed"
    if [[ -z "$BLOCKER_CODE" ]]; then
      BLOCKER_CODE="blocked:cmp-skipped"
  fi
fi

if [[ "$RESULT" == "passed" && "$SKIP_CMP" -eq 0 ]]; then
  CMP_ARGS=(
    python3 "$RR_DIR/runnable/scripts/validate_libcrypto_ground_truth.py" cmp
    --binary "$BINARY_PATH"
    --groundtruth "$(python3 "$RR_DIR/runnable/scripts/libcrypto_bench_paths.py" groundtruth-pb --must-exist)"
    --blocks-pb2 "$(python3 "$RR_DIR/runnable/scripts/libcrypto_bench_paths.py" blocks-pb2 --must-exist)"
    --ll "$LIFT_LL"
    --run-cmp-eval "$(python3 "$RR_DIR/runnable/scripts/libcrypto_bench_paths.py" cmp-tool --must-exist)"
    --text-start "$TEXT_START_HEX"
    --runnable-base "$RUNNABLE_BASE"
    --out-dir "$EVAL_DIR"
    --allow-low-metrics
  )
  if [[ -f "$INCLUDE_PC_FILE" ]]; then
    CMP_ARGS+=(--include-pc-file "$INCLUDE_PC_FILE")
  fi
  for profile in "${STATIC_FALLBACK_PROFILES[@]}"; do
    CMP_ARGS+=(--static-fallback-profile "$profile")
  done
  for regex in "${STATIC_FALLBACK_SYMBOL_REGEXES[@]}"; do
    CMP_ARGS+=(--static-fallback-symbol-regex "$regex")
  done
  set +e
  "${CMP_ARGS[@]}" >"$EVAL_DIR/cmp.stdout" 2>"$EVAL_DIR/cmp.stderr"
  CMP_RC=$?
  set -e
  if [[ "$CMP_RC" -ne 0 ]]; then
    RESULT="failed"
    FAILURE_CLASS="cmp-failed"
    BLOCKER_CODE="blocked:canonical-cmp-failed"
  else
    read -r CMP_VERDICT_OK CMP_LL_COUNT CMP_PRECISION CMP_RECALL < <(
      python3 - "$EVAL_DIR/cmp.json" "$EVAL_DIR/cmp.verdict.txt" <<'PY'
import json
import sys
from pathlib import Path

cmp_json = Path(sys.argv[1])
verdict_path = Path(sys.argv[2])

ll_count = 0
precision = 0.0
recall = 0.0
if cmp_json.is_file():
    payload = json.loads(cmp_json.read_text(encoding="utf-8"))
    ll_count = int(payload.get("ll_count", 0) or 0)
    precision = float(payload.get("precision", 0.0) or 0.0)
    recall = float(payload.get("recall", 0.0) or 0.0)

ok_value = ""
if verdict_path.is_file():
    for raw_line in verdict_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip().lower()
        if line.startswith("ok:"):
            token = line.split(":", 1)[1].strip()
            ok_value = "1" if token == "true" else "0"
            break

print(f"{ok_value} {ll_count} {precision:.6f} {recall:.6f}")
PY
    )
    if [[ "$CMP_LL_COUNT" -eq 0 ]]; then
      RESULT="failed"
      FAILURE_CLASS="cmp-failed"
      if [[ "$LIFT_BB_COUNT" -gt 0 || "$LIFT_REAL_COMMENT_ADDR_COUNT" -gt 0 ]]; then
        BLOCKER_CODE="blocked:cmp-parser-missed-lifted-addresses"
      elif [[ "$LIFT_COMMENT_ADDR_COUNT" -gt 0 ]]; then
        BLOCKER_CODE="blocked:lift-no-real-instruction-markers"
      else
        BLOCKER_CODE="blocked:lift-no-dispatch-blocks"
      fi
    elif [[ "$CMP_VERDICT_OK" != "1" ]]; then
      RESULT="failed"
      FAILURE_CLASS="cmp-failed"
      BLOCKER_CODE="blocked:cmp-verdict-failed"
    elif awk -v p="$CMP_PRECISION" -v r="$CMP_RECALL" 'BEGIN { exit !((p+0) >= 0.8 && (r+0) >= 0.8) }'; then
      :
    else
      RESULT="failed"
      FAILURE_CLASS="cmp-failed"
      BLOCKER_CODE="blocked:cmp-verdict-failed"
    fi
  fi
fi

printf '%s' "$RESULT" > "$SCRATCH_ROOT/$LABEL/.result"
printf '%s' "$FAILURE_CLASS" > "$SCRATCH_ROOT/$LABEL/.failure_class"
printf '%s' "$BLOCKER_CODE" > "$SCRATCH_ROOT/$LABEL/.blocker_code"
printf '%s' "$SCRATCH_ROOT" > "$SCRATCH_ROOT/$LABEL/.scratch_root"
printf '%s' "$RUN_DIR" > "$SCRATCH_ROOT/$LABEL/.run_dir"
printf '%s' "$EVAL_DIR" > "$SCRATCH_ROOT/$LABEL/.eval_dir"
printf '%s' "$RUNNABLE_LIFT_BIN" > "$SCRATCH_ROOT/$LABEL/.runnable_lift"
printf '%s' "$LIBTINYCODE_PATH" > "$SCRATCH_ROOT/$LABEL/.libtinycode"
printf '%s' "$LIBHELPERS_PATH" > "$SCRATCH_ROOT/$LABEL/.helpers"
printf '%s' "$EARLY_LINKED_PATH" > "$SCRATCH_ROOT/$LABEL/.early_linked"
printf '%s' "$LIVE_SIDECAR_ROOT" > "$SCRATCH_ROOT/$LABEL/.live_sidecar_root"
printf '%s' "$FORCE_BIONIC_REBUILD" > "$SCRATCH_ROOT/$LABEL/.force_bionic_rebuild"
printf '%s' "$BIONIC_REBUILT_LIBTINYCODE" > "$SCRATCH_ROOT/$LABEL/.bionic_rebuilt_libtinycode"
printf '%s' "$BIONIC_REBUILT_LIBTINYCODE_LOG" > "$SCRATCH_ROOT/$LABEL/.bionic_rebuilt_libtinycode_log"
printf '%s' "$BIONIC_REBUILT_LIBTINYCODE_SOURCE_ROOT" > "$SCRATCH_ROOT/$LABEL/.bionic_rebuilt_libtinycode_source_root"
printf '%s' "$BINARY_PATH" > "$SCRATCH_ROOT/$LABEL/.binary"
printf '%s' "$SYMBOL_NAME" > "$SCRATCH_ROOT/$LABEL/.symbol"
printf '%s' "$ENTRY_HEX" > "$SCRATCH_ROOT/$LABEL/.entry"
printf '%s' "$RUNNABLE_BASE" > "$SCRATCH_ROOT/$LABEL/.runnable_base"
printf '%s' "$TEXT_START_HEX" > "$SCRATCH_ROOT/$LABEL/.text_start"
printf '%s' "$TEXT_END_HEX" > "$SCRATCH_ROOT/$LABEL/.text_end"
printf '%s' "$ADDR_RANGE_MIN" > "$SCRATCH_ROOT/$LABEL/.addr_range_min"
printf '%s' "$ADDR_RANGE_MAX" > "$SCRATCH_ROOT/$LABEL/.addr_range_max"
printf '%s' "$LIFT_RC" > "$SCRATCH_ROOT/$LABEL/.lift_rc"
printf '%s' "$CMP_RC" > "$SCRATCH_ROOT/$LABEL/.cmp_rc"
printf '%s' "$LIFT_SWITCH_CASE_COUNT" > "$SCRATCH_ROOT/$LABEL/.lift_switch_case_count"
printf '%s' "$LIFT_NEWPC_COUNT" > "$SCRATCH_ROOT/$LABEL/.lift_newpc_count"
printf '%s' "$LIFT_BB_COUNT" > "$SCRATCH_ROOT/$LABEL/.lift_bb_count"
printf '%s' "$LIFT_COMMENT_ADDR_COUNT" > "$SCRATCH_ROOT/$LABEL/.lift_comment_addr_count"
printf '%s' "$LIFT_REAL_COMMENT_ADDR_COUNT" > "$SCRATCH_ROOT/$LABEL/.lift_real_comment_addr_count"
printf '%s' "$LIFT_OI_COUNT" > "$SCRATCH_ROOT/$LABEL/.lift_oi_count"
printf '%s' "$LIFT_PI_COUNT" > "$SCRATCH_ROOT/$LABEL/.lift_pi_count"
printf '%s' "$SIDECAR_REPLAY_PC" > "$SCRATCH_ROOT/$LABEL/.sidecar_replay_pc"
printf '%s' "$COMPARE_SCOPE_MODE" > "$SCRATCH_ROOT/$LABEL/.compare_scope_mode"
printf '%s' "$INCLUDE_PC_FILE" > "$SCRATCH_ROOT/$LABEL/.include_pc_file"
printf '%s' "$INCLUDE_PC_AUDIT_JSON" > "$SCRATCH_ROOT/$LABEL/.include_pc_audit_json"
printf '%s\n' "${STATIC_FALLBACK_PROFILES[@]}" > "$SCRATCH_ROOT/$LABEL/.static_fallback_profiles"
printf '%s\n' "${STATIC_FALLBACK_SYMBOL_REGEXES[@]}" > "$SCRATCH_ROOT/$LABEL/.static_fallback_symbol_regexes"
printf '%s' "$LIFT_STDOUT" > "$SCRATCH_ROOT/$LABEL/.lift_stdout"
printf '%s' "$LIFT_STDERR" > "$SCRATCH_ROOT/$LABEL/.lift_stderr"
printf '%s' "$LIFT_LL" > "$SCRATCH_ROOT/$LABEL/.lift_ll"
printf '%s' "$EVAL_DIR/cmp.json" > "$SCRATCH_ROOT/$LABEL/.cmp_json"
printf '%s' "$EVAL_DIR/cmp.verdict.txt" > "$SCRATCH_ROOT/$LABEL/.cmp_verdict"

python3 - "$SUMMARY_JSON" "$SCRATCH_ROOT/$LABEL" <<'PY'
import json
import sys
from pathlib import Path

summary_path = Path(sys.argv[1])
meta_root = Path(sys.argv[2])


def read_lines(path: Path):
    if not path.is_file():
        return []
    return [line for line in path.read_text(encoding="utf-8").splitlines() if line]


def load_cmp_static_fallback(path: Path):
    if not path.is_file():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None
    static_fallback = payload.get("static_fallback")
    return static_fallback if isinstance(static_fallback, dict) else None


cmp_json_ref = (meta_root / ".cmp_json").read_text().strip()
cmp_static_fallback = load_cmp_static_fallback(Path(cmp_json_ref)) if cmp_json_ref else None
payload = {
    "result": (meta_root / ".result").read_text().strip(),
    "failure_class": (meta_root / ".failure_class").read_text().strip(),
    "blocker_code": (meta_root / ".blocker_code").read_text().strip() or None,
    "scratch_root": (meta_root / ".scratch_root").read_text().strip(),
    "run_dir": (meta_root / ".run_dir").read_text().strip(),
    "eval_dir": (meta_root / ".eval_dir").read_text().strip(),
    "runnable_lift": (meta_root / ".runnable_lift").read_text().strip(),
    "libtinycode": (meta_root / ".libtinycode").read_text().strip(),
    "libtinycode_helpers": (meta_root / ".helpers").read_text().strip(),
    "early_linked": (meta_root / ".early_linked").read_text().strip(),
    "live_sidecar_root": (meta_root / ".live_sidecar_root").read_text().strip(),
    "force_bionic_rebuild": (meta_root / ".force_bionic_rebuild").read_text().strip(),
    "bionic_rebuilt_libtinycode": ((meta_root / ".bionic_rebuilt_libtinycode").read_text().strip() == "1"),
    "bionic_rebuilt_libtinycode_log": (meta_root / ".bionic_rebuilt_libtinycode_log").read_text().strip() or None,
    "bionic_rebuilt_libtinycode_source_root": (meta_root / ".bionic_rebuilt_libtinycode_source_root").read_text().strip() or None,
    "binary": (meta_root / ".binary").read_text().strip(),
    "symbol": (meta_root / ".symbol").read_text().strip() or None,
    "entry": (meta_root / ".entry").read_text().strip(),
    "runnable_base": (meta_root / ".runnable_base").read_text().strip(),
    "text_start": (meta_root / ".text_start").read_text().strip(),
    "text_end": (meta_root / ".text_end").read_text().strip(),
    "addr_range_min": (meta_root / ".addr_range_min").read_text().strip(),
    "addr_range_max": (meta_root / ".addr_range_max").read_text().strip(),
    "lift_rc": int((meta_root / ".lift_rc").read_text().strip()),
    "cmp_rc": (meta_root / ".cmp_rc").read_text().strip() or None,
    "cmp_verdict_ok": None,
    "lift_switch_case_count": int((meta_root / ".lift_switch_case_count").read_text().strip()),
    "lift_newpc_count": int((meta_root / ".lift_newpc_count").read_text().strip()),
    "lift_bb_count": int((meta_root / ".lift_bb_count").read_text().strip()),
    "lift_comment_addr_count": int((meta_root / ".lift_comment_addr_count").read_text().strip()),
    "lift_real_comment_addr_count": int((meta_root / ".lift_real_comment_addr_count").read_text().strip()),
    "lift_oi_count": int((meta_root / ".lift_oi_count").read_text().strip()),
    "lift_pi_count": int((meta_root / ".lift_pi_count").read_text().strip()),
    "sidecar_replay_pc": (meta_root / ".sidecar_replay_pc").read_text().strip() or None,
    "compare_scope_mode": (meta_root / ".compare_scope_mode").read_text().strip() or "full_text",
    "include_pc_file": (meta_root / ".include_pc_file").read_text().strip() or None,
    "include_pc_audit_json": (meta_root / ".include_pc_audit_json").read_text().strip() or None,
    "static_fallback_profiles": read_lines(meta_root / ".static_fallback_profiles"),
    "static_fallback_symbol_regexes": read_lines(meta_root / ".static_fallback_symbol_regexes"),
    "static_fallback": cmp_static_fallback,
    "lift_stdout": (meta_root / ".lift_stdout").read_text().strip(),
    "lift_stderr": (meta_root / ".lift_stderr").read_text().strip(),
    "lift_ll": (meta_root / ".lift_ll").read_text().strip(),
    "cmp_json": (meta_root / ".cmp_json").read_text().strip() or None,
    "cmp_verdict": (meta_root / ".cmp_verdict").read_text().strip() or None,
    "used_build_tree_runnable_lift": True,
    "used_stale_source_tree_binary": False,
}
cmp_verdict_ref = (meta_root / ".cmp_verdict").read_text().strip()
if cmp_verdict_ref:
    verdict_path = Path(cmp_verdict_ref)
    if verdict_path.is_file():
        verdict_text = verdict_path.read_text(encoding="utf-8", errors="replace").lower()
        if "ok: true" in verdict_text:
            payload["cmp_verdict_ok"] = True
        elif "ok: false" in verdict_text:
            payload["cmp_verdict_ok"] = False
summary_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(payload, indent=2, sort_keys=True))
PY
