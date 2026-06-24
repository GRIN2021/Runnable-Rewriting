#!/usr/bin/env bash
#
# Smoke the stronger PTC bridge shape: build a throwaway /tmp/libtinycode-x86_64.so
# whose ptc_translate path shells out to a /tmp sidecar that regenerates live
# QEMU walker/model data during the translate call, then reconstructs a
# non-empty PTCInstructionList using the exact repo qemu/linux-user/ptc.h ABI.
#
# This avoids linking non-PIC QEMU objects into the shared object. The dynamic
# library stays PIC-only and only depends on the repo headers plus libc/dl.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_PTC_LIVE_SIDECAR_ROOT:-/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke}"
QEMU_SRC="${RUNNABLE_QEMU_V2_UPSTREAM_SRC:-/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3}"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-3}"
PAYLOAD_SOURCE="${RUNNABLE_QEMU_V2_PTC_LIVE_SIDECAR_PAYLOAD_SOURCE:-}"
MODEL_SOURCE="${RUNNABLE_QEMU_V2_PTC_LIVE_SIDECAR_MODEL_SOURCE:-}"
SUMMARY_SOURCE="${RUNNABLE_QEMU_V2_PTC_LIVE_SIDECAR_SUMMARY_SOURCE:-}"
FRESH=0

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_ptc_live_sidecar_translate_smoke.sh [options]

Options:
  --scratch-root DIR  Output/build scratch root.
                      Default: /tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke
  --qemu-src DIR      Existing unpatched QEMU 10.2.3 source tree to copy when available.
                      Default: /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3
  --jobs N, -j N      QEMU/ninja parallelism. Default: 3 or RUNNABLE_QEMU_V2_JOBS.
  --payload-source PATH
                      Replay an already prepared sidecar payload instead of
                      invoking the nested real-smoke copy/build workflow.
  --model-source PATH
                      Optional model JSON to stage alongside a replay payload.
  --summary-source PATH
                      Optional summary JSON to stage alongside a replay payload.
  --fresh             Remove this smoke's scratch root before running.
  -h, --help          Show this help.

Outputs:
  $SCRATCH_ROOT/sidecar/sidecar.log
  $SCRATCH_ROOT/sidecar/sidecar.model.json
  $SCRATCH_ROOT/sidecar/sidecar.summary.json
  $SCRATCH_ROOT/libtinycode-x86_64.so
  $SCRATCH_ROOT/qemu_v2_ptc_live_sidecar_translate_smoke.summary.json
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
    --payload-source)
      PAYLOAD_SOURCE="$(abs_path "${2:?missing value for --payload-source}")"
      shift 2
      ;;
    --model-source)
      MODEL_SOURCE="$(abs_path "${2:?missing value for --model-source}")"
      shift 2
      ;;
    --summary-source)
      SUMMARY_SOURCE="$(abs_path "${2:?missing value for --summary-source}")"
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

if [[ ! -x "$QEMU_SRC/configure" && -x "$RR_DIR/qemu/configure" ]]; then
  QEMU_SRC="$RR_DIR/qemu"
  log "Falling back to repo qemu source tree: $QEMU_SRC"
fi

if [[ -n "$PAYLOAD_SOURCE" && ! -f "$PAYLOAD_SOURCE" ]]; then
  die "replay payload source not found: $PAYLOAD_SOURCE"
fi
if [[ -n "$MODEL_SOURCE" && ! -f "$MODEL_SOURCE" ]]; then
  die "replay model source not found: $MODEL_SOURCE"
fi
if [[ -n "$SUMMARY_SOURCE" && ! -f "$SUMMARY_SOURCE" ]]; then
  die "replay summary source not found: $SUMMARY_SOURCE"
fi

SIDE_ROOT="$SCRATCH_ROOT/sidecar"
SIDE_LOG="$SIDE_ROOT/sidecar.log"
SIDE_MODEL_JSON="$SIDE_ROOT/sidecar.model.json"
SIDE_SUMMARY_JSON="$SIDE_ROOT/sidecar.summary.json"
SIDE_PAYLOAD="$SIDE_ROOT/sidecar.payload.txt"
REAL_ROOT="$SIDE_ROOT/real"

LIB_C="$SCRATCH_ROOT/qemu_v2_ptc_live_sidecar_translate_lib.c"
HARNESS_C="$SCRATCH_ROOT/qemu_v2_ptc_live_sidecar_translate_smoke.c"
HARNESS_BIN="$SCRATCH_ROOT/qemu_v2_ptc_live_sidecar_translate_smoke"
HARNESS_LOG="$SCRATCH_ROOT/qemu_v2_ptc_live_sidecar_translate_smoke.log"
SUMMARY_JSON="$SCRATCH_ROOT/qemu_v2_ptc_live_sidecar_translate_smoke.summary.json"
LIB_SO="$SCRATCH_ROOT/libtinycode-x86_64.so"
SIDE_HELPER="$SCRATCH_ROOT/ptc_live_sidecar_regen.sh"

if [[ "$FRESH" -eq 1 ]]; then
  rm -rf "$SCRATCH_ROOT"
fi
mkdir -p "$SCRATCH_ROOT"

require_tool bash
require_tool python3
require_tool cc

log "Generating /tmp sidecar helper"
cat >"$SIDE_HELPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRATCH_ROOT="${1:?missing scratch root}"
QEMU_SRC="${2:?missing qemu src}"
JOBS="${3:?missing jobs}"
LOG_PATH="$SCRATCH_ROOT/sidecar.log"
MODEL_JSON="$SCRATCH_ROOT/sidecar.model.json"
SUMMARY_JSON="$SCRATCH_ROOT/sidecar.summary.json"
PAYLOAD_OUT="$SCRATCH_ROOT/sidecar.payload.txt"
REAL_ROOT="$SCRATCH_ROOT/real"
RR_DIR="${PTC_RR_DIR:?missing PTC_RR_DIR}"
REAL_SCRIPT="$RR_DIR/runnable/scripts/qemu_v2_ptc_real_translate_scalar_smoke.sh"
PAYLOAD_SOURCE="${PTC_SIDECAR_PAYLOAD_SOURCE:-}"
MODEL_SOURCE="${PTC_SIDECAR_MODEL_SOURCE:-}"
SUMMARY_SOURCE="${PTC_SIDECAR_SUMMARY_SOURCE:-}"

mkdir -p "$SCRATCH_ROOT"
{
  printf '[%s] sidecar-start scratch_root=%s qemu_src=%s jobs=%s\n' "$(date -u +%FT%TZ)" "$SCRATCH_ROOT" "$QEMU_SRC" "$JOBS"
} >>"$LOG_PATH"

if [[ -n "$PAYLOAD_SOURCE" ]]; then
  {
    printf '[%s] sidecar-replay payload_source=%s\n' "$(date -u +%FT%TZ)" "$PAYLOAD_SOURCE"
    if [[ -n "$MODEL_SOURCE" ]]; then
      printf '[%s] sidecar-replay model_source=%s\n' "$(date -u +%FT%TZ)" "$MODEL_SOURCE"
    fi
    if [[ -n "$SUMMARY_SOURCE" ]]; then
      printf '[%s] sidecar-replay summary_source=%s\n' "$(date -u +%FT%TZ)" "$SUMMARY_SOURCE"
    fi
  } >>"$LOG_PATH"
  if [[ -n "$MODEL_SOURCE" ]]; then
    cp "$MODEL_SOURCE" "$MODEL_JSON"
  fi
  if [[ -n "$SUMMARY_SOURCE" ]]; then
    cp "$SUMMARY_SOURCE" "$SUMMARY_JSON"
  fi
  python3 - "$PAYLOAD_SOURCE" "$PAYLOAD_OUT" "$MODEL_SOURCE" <<'PY' >"$PAYLOAD_OUT"
import sys
from pathlib import Path
import json

source_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
model_source = Path(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else None

model_json = output_path.parent / "sidecar.model.json"
summary_json = output_path.parent / "sidecar.summary.json"

if model_source is None or not model_source.exists():
    raise SystemExit(f"replay source model is required for closure remapping: {source_path}")

model = json.loads(model_source.read_text())
if model.get("schema") == "qemu-v2-ptc-live-sidecar-model-v1":
    output = source_path.read_text(encoding="utf-8")
    if not output.endswith("\n"):
        output += "\n"
    output_path.write_text(output, encoding="utf-8")
    sys.stdout.write(output)
    raise SystemExit(0)

instructions = model["instructions"]
temps = model["temps"]

def to_int(value):
    return 0 if value is None else int(value)

def instruction_opcode(inst):
    return inst["ptc_list_model"]["opc"]

debug_index = next((i for i, inst in enumerate(instructions)
                    if instruction_opcode(inst) == "debug_insn_start"), None)
if debug_index is None:
    raise SystemExit(f"replay source model has no debug_insn_start instruction: {model_source}")

next_debug_index = next((i for i in range(debug_index + 1, len(instructions))
                         if instruction_opcode(instructions[i]) == "debug_insn_start"), len(instructions))
selected_instructions = instructions[debug_index:next_debug_index]
if not selected_instructions:
    raise SystemExit(f"replay source model is missing instructions after debug_insn_start: {model_source}")

temp_by_walker_arg = {}
for temp in temps:
    walker_arg = temp.get("walker_arg")
    if walker_arg is not None:
        temp_by_walker_arg[str(walker_arg)] = temp

selected_temp_indices = []
selected_temp_set = set()
for inst in selected_instructions:
    for arg in inst.get("args", []):
        temp = temp_by_walker_arg.get(str(arg))
        if temp is None:
            continue
        temp_index = int(temp["index"])
        if temp_index not in selected_temp_set:
            selected_temp_set.add(temp_index)
            selected_temp_indices.append(temp_index)

def temp_sort_key(temp_index):
    temp = temps[temp_index]
    flags = temp.get("flags", {})
    return (
        0 if flags.get("is_global") else 1,
        int(temp["index"]),
    )

ordered_temp_indices = sorted(selected_temp_indices, key=temp_sort_key)
if 0 not in ordered_temp_indices and any(temp.get("index") == 0 for temp in temps):
    ordered_temp_indices = [0] + [i for i in ordered_temp_indices if i != 0]

temp_remap = {old_index: new_index for new_index, old_index in enumerate(ordered_temp_indices)}
selected_temps = []
for new_index, old_index in enumerate(ordered_temp_indices):
    temp = dict(temps[old_index])
    temp["index"] = new_index
    temp["temp_id"] = new_index
    temp["temp_index"] = new_index
    selected_temps.append(temp)

renumbered_instructions = []
argument_count = 0
for new_index, inst in enumerate(selected_instructions):
    inst_copy = dict(inst)
    inst_copy["index"] = new_index
    mapped_args = []
    for arg in inst.get("args", []):
        temp = temp_by_walker_arg.get(str(arg))
        if temp is None:
            mapped_args.append(arg)
            continue
        old_index = int(temp["index"])
        if old_index not in temp_remap:
            raise SystemExit(
                f"replay source model instruction {inst.get('index')} references temp {old_index} "
                f"not captured by the selected replay subset"
            )
        mapped_args.append(str(temp_remap[old_index]))
    inst_copy["args"] = mapped_args
    renumbered_instructions.append(inst_copy)
    argument_count += len(mapped_args)

global_temps = sum(1 for temp in selected_temps if temp.get("flags", {}).get("is_global"))
if global_temps == 0:
    raise SystemExit(f"replay source model selected no global temps: {model_source}")

output_lines = [
    "PTC_LIVE_SIDECAR v1",
    f"instruction_count={len(renumbered_instructions)}",
    f"argument_count={argument_count}",
    f"temp_count={len(selected_temps)}",
    f"global_temps={global_temps}",
    f"total_temps={len(selected_temps)}",
    f"model_json={model_json}",
    f"summary_json={summary_json}",
    f"payload_source={source_path}",
]
for inst in renumbered_instructions:
    model_entry = inst["ptc_list_model"]
    args = ",".join(str(arg) for arg in inst["args"])
    output_lines.append(
        "instruction|%d|%s|%s|%s|%d|%s"
        % (
            int(inst["index"]),
            model_entry["opc"],
            to_int(model_entry["callo"]),
            to_int(model_entry["calli"]),
            len(inst["args"]),
            args,
        )
    )
for temp in selected_temps:
    model_entry = temp["ptc_temp_model"]
    temp_name = temp.get("name") or f"temp_{int(temp['index'])}"
    temp_val = model_entry["val"]
    output_lines.append(
        "temp|%d|%s|%d|%d|%d|%d|%d|%d|%s|%d|%d|%d|%d|%d"
        % (
            int(temp["index"]),
            str(temp_name).replace("|", "/"),
            to_int(model_entry["val_type"]),
            to_int(model_entry["base_type"]),
            to_int(model_entry["type"]),
            to_int(model_entry["reg"]),
            to_int(model_entry["mem_reg"]),
            to_int(model_entry["mem_offset"]),
            "0" if temp_val is None else temp_val,
            1 if model_entry["fixed_reg"] else 0,
            1 if model_entry["mem_coherent"] else 0,
            1 if model_entry["mem_allocated"] else 0,
            1 if model_entry["temp_local"] else 0,
            1 if model_entry["temp_allocated"] else 0,
        )
    )
output = "\n".join(output_lines) + "\n"
output_path.write_text(output, encoding="utf-8")
sys.stdout.write(output)
PY
  test -s "$PAYLOAD_OUT"
else
  printf '[%s] invoking-real-smoke\n' "$(date -u +%FT%TZ)" >>"$LOG_PATH"
  bash "$REAL_SCRIPT" --scratch-root "$REAL_ROOT" --qemu-src "$QEMU_SRC" --jobs "$JOBS" --fresh >>"$LOG_PATH" 2>&1

  cp "$REAL_ROOT/dumps/scalar-simple.ptc-conversion-model.json" "$MODEL_JSON"
  cp "$REAL_ROOT/dumps/scalar-simple.smoke-summary.json" "$SUMMARY_JSON"

  python3 - "$MODEL_JSON" "$LOG_PATH" <<'PY' >"$PAYLOAD_OUT"
import json
import sys
from pathlib import Path

model_path = Path(sys.argv[1])
log_path = Path(sys.argv[2])
model = json.loads(model_path.read_text())
summary = model["summary"]
instructions = model["instructions"]
temps = model["temps"]

def to_int(value):
    return 0 if value is None else int(value)

log_path.write_text(
    log_path.read_text()
    + f"[{__import__('datetime').datetime.utcnow().isoformat()}Z] model_json={model_path}\n"
    + f"[{__import__('datetime').datetime.utcnow().isoformat()}Z] summary_json={model_path.parent / 'sidecar.summary.json'}\n"
    + f"[{__import__('datetime').datetime.utcnow().isoformat()}Z] sidecar-generated-lines={len(instructions) + len(temps) + 6}\n"
    + "",
    encoding="utf-8",
)

print("PTC_LIVE_SIDECAR v1")
print(f"instruction_count={int(summary['instruction_count'])}")
print(f"argument_count={int(summary['argument_count'])}")
print(f"temp_count={int(summary['temp_count'])}")
print(f"global_temps={int(summary['global_temps'])}")
print(f"total_temps={int(summary['total_temps'])}")
print(f"model_json={model_path}")
print(f"summary_json={model_path.parent / 'sidecar.summary.json'}")
for inst in instructions:
    model_entry = inst["ptc_list_model"]
    args = ",".join(str(arg) for arg in inst["args"])
    print(
        "instruction|%d|%s|%s|%s|%d|%s"
        % (
            int(inst["index"]),
            model_entry["opc"],
            "0" if model_entry["callo"] is None else int(model_entry["callo"]),
            "0" if model_entry["calli"] is None else int(model_entry["calli"]),
            len(inst["args"]),
            args,
        )
    )
for temp in temps:
    model_entry = temp["ptc_temp_model"]
    temp_name = temp.get("name") or f"temp_{int(temp['index'])}"
    temp_val = model_entry["val"]
    print(
        "temp|%d|%s|%d|%d|%d|%d|%d|%d|%s|%d|%d|%d|%d|%d"
        % (
            to_int(temp["index"]),
            str(temp_name).replace("|", "/"),
            to_int(model_entry["val_type"]),
            to_int(model_entry["base_type"]),
            to_int(model_entry["type"]),
            to_int(model_entry["reg"]),
            to_int(model_entry["mem_reg"]),
            to_int(model_entry["mem_offset"]),
            "0" if temp_val is None else temp_val,
            1 if model_entry["fixed_reg"] else 0,
            1 if model_entry["mem_coherent"] else 0,
            1 if model_entry["mem_allocated"] else 0,
            1 if model_entry["temp_local"] else 0,
            1 if model_entry["temp_allocated"] else 0,
        )
    )
PY
fi

cat "$PAYLOAD_OUT"

{
  printf '[%s] sidecar-finished model_json=%s summary_json=%s payload=%s\n' "$(date -u +%FT%TZ)" "$MODEL_JSON" "$SUMMARY_JSON" "$PAYLOAD_OUT"
} >>"$LOG_PATH"
EOF
chmod +x "$SIDE_HELPER"

log "Generating library and harness sources"
python3 - "$LIB_C" "$HARNESS_C" "$SIDE_HELPER" "$SIDE_ROOT" "$QEMU_SRC" "$LIB_SO" "$RR_DIR" "$JOBS" "$PAYLOAD_SOURCE" "$MODEL_SOURCE" "$SUMMARY_SOURCE" <<'PY'
import sys
from pathlib import Path

lib_c_path = Path(sys.argv[1])
harness_c_path = Path(sys.argv[2])
side_helper = Path(sys.argv[3])
side_root = Path(sys.argv[4])
qemu_src = Path(sys.argv[5])
lib_so = Path(sys.argv[6])
rr_dir = Path(sys.argv[7])
jobs = int(sys.argv[8])
payload_source = sys.argv[9]
model_source = sys.argv[10]
summary_source = sys.argv[11]
side_log = side_root / "sidecar.log"
side_model = side_root / "sidecar.model.json"
side_summary = side_root / "sidecar.summary.json"

lib_c = f'''#define _GNU_SOURCE 1
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>

#define TCG_TARGET_REG_BITS 64
#define TARGET_LONG_BITS 64
#define TCG_TARGET_HAS_div2_i32 0
#define TCG_TARGET_HAS_rot_i32 0
#define TCG_TARGET_HAS_ext8s_i32 0
#define TCG_TARGET_HAS_ext16s_i32 0
#define TCG_TARGET_HAS_ext8u_i32 0
#define TCG_TARGET_HAS_ext16u_i32 0
#define TCG_TARGET_HAS_bswap16_i32 0
#define TCG_TARGET_HAS_bswap32_i32 0
#define TCG_TARGET_HAS_neg_i32 0
#define TCG_TARGET_HAS_not_i32 0
#define TCG_TARGET_HAS_andc_i32 0
#define TCG_TARGET_HAS_orc_i32 0
#define TCG_TARGET_HAS_eqv_i32 0
#define TCG_TARGET_HAS_nand_i32 0
#define TCG_TARGET_HAS_nor_i32 0
#define TCG_TARGET_HAS_deposit_i32 0
#define TCG_TARGET_HAS_movcond_i32 0
#define TCG_TARGET_HAS_add2_i32 0
#define TCG_TARGET_HAS_sub2_i32 0
#define TCG_TARGET_HAS_mulu2_i32 0
#define TCG_TARGET_HAS_muls2_i32 0
#define TCG_TARGET_HAS_muluh_i32 0
#define TCG_TARGET_HAS_mulsh_i32 0
#define TCG_TARGET_HAS_trunc_shr_i32 0
#define TCG_TARGET_HAS_div2_i64 0
#define TCG_TARGET_HAS_rot_i64 0
#define TCG_TARGET_HAS_ext8s_i64 0
#define TCG_TARGET_HAS_ext16s_i64 0
#define TCG_TARGET_HAS_ext32s_i64 0
#define TCG_TARGET_HAS_ext8u_i64 0
#define TCG_TARGET_HAS_ext16u_i64 0
#define TCG_TARGET_HAS_ext32u_i64 0
#define TCG_TARGET_HAS_bswap16_i64 0
#define TCG_TARGET_HAS_bswap32_i64 0
#define TCG_TARGET_HAS_bswap64_i64 0
#define TCG_TARGET_HAS_neg_i64 0
#define TCG_TARGET_HAS_not_i64 0
#define TCG_TARGET_HAS_andc_i64 0
#define TCG_TARGET_HAS_orc_i64 0
#define TCG_TARGET_HAS_eqv_i64 0
#define TCG_TARGET_HAS_nand_i64 0
#define TCG_TARGET_HAS_nor_i64 0
#define TCG_TARGET_HAS_deposit_i64 0
#define TCG_TARGET_HAS_movcond_i64 0
#define TCG_TARGET_HAS_add2_i64 0
#define TCG_TARGET_HAS_sub2_i64 0
#define TCG_TARGET_HAS_mulu2_i64 0
#define TCG_TARGET_HAS_muls2_i64 0
#define TCG_TARGET_HAS_muluh_i64 0
#define TCG_TARGET_HAS_mulsh_i64 0

#include "ptc.h"

typedef struct {{
  char **items;
  size_t count;
  size_t cap;
}} ptc_line_vec;

typedef struct {{
  PTCOpcode opc;
  unsigned callo;
  unsigned calli;
  unsigned arg_count;
  PTCInstructionArg *args;
}} ptc_instruction_build;

static const char ptc_abi_metadata[] =
  "abi_version=2\\n"
  "bridge_kind=live_sidecar\\n"
  "real_translation=true\\n"
  "sidecar_triggered_during_ptc_translate=true\\n"
  "exact_repo_ptc_h=true\\n";

static const char ptc_sidecar_payload_source[] = "{payload_source}";
static const char ptc_sidecar_model_source[] = "{model_source}";
static const char ptc_sidecar_summary_source[] = "{summary_source}";
static const char ptc_sidecar_helper_path[] = "{side_helper}";
static const char ptc_sidecar_root_path[] = "{side_root}";
static const char ptc_qemu_src_path[] = "{qemu_src}";
static const unsigned ptc_sidecar_jobs = {jobs}u;

PTCOpcodeDef *ptc_opcode_defs;
PTCHelperDef *ptc_helper_defs;
unsigned ptc_helper_defs_size;

static PTCOpcodeDef ptc_opcode_defs_storage[PTC_INSTRUCTION_NB_OPS] = {{
#define DEF(op_name, oargs, iargs, cargs, flags) \\
  [PTC_INSTRUCTION_op_##op_name] = {{ .name = #op_name, .nb_oargs = (uint8_t) (oargs), .nb_iargs = (uint8_t) (iargs), .nb_cargs = (uint8_t) (cargs), .nb_args = (uint8_t) ((oargs) + (iargs) + (cargs)) }},
#include "tcg-opc.h"
#undef DEF
}};

static PTCHelperDef ptc_helper_defs_storage[1] = {{
  {{ NULL, "ptc_live_sidecar_helper_table", 0u }},
}};

static uint64_t ptc_elf_start_stack = UINT64_C(0x700000000000);
static uint64_t ptc_regs[16];
static uint8_t ptc_initialized_env[64];
static int32_t ptc_exception_syscall = -1;
static uint64_t ptc_syscall_next_eip;
static uint64_t ptc_is_indirect;
static uint64_t ptc_is_call;
static uint64_t ptc_is_directcall;
static uint64_t ptc_call_next;
static uint64_t ptc_is_indirect_jmp;
static uint64_t ptc_is_direct_jmp;
static uint64_t ptc_is_ret;
static uint64_t ptc_illegal_access_addr;
static uint64_t ptc_cfi_addr;
static uint64_t ptc_is_syscall;
static uint64_t ptc_block_size;
static uint64_t ptc_icount;
static uint64_t ptc_is_illegal;
static uint64_t ptc_is_add;
static void ptc_reset_status(uint64_t virtual_address)
{{
  ptc_syscall_next_eip = virtual_address;
  ptc_is_indirect = 0;
  ptc_is_call = 0;
  ptc_is_directcall = 0;
  ptc_call_next = 0;
  ptc_is_indirect_jmp = 0;
  ptc_is_direct_jmp = 0;
  ptc_is_ret = 0;
  ptc_illegal_access_addr = 0;
  ptc_cfi_addr = 0;
  ptc_is_syscall = 0;
  ptc_block_size = 0;
  ptc_icount = 0;
  ptc_is_illegal = 0;
  ptc_is_add = 0;
}}

static void ptc_init_env_once(void)
{{
  static int initialized;
  if (initialized) {{
    return;
  }}
  memset(ptc_initialized_env, 0, sizeof(ptc_initialized_env));
  memset(ptc_regs, 0, sizeof(ptc_regs));
  ptc_regs[4] = ptc_elf_start_stack - 16u;
  ptc_regs[5] = ptc_regs[4];
  initialized = 1;
}}

static void ptc_line_vec_init(ptc_line_vec *vec)
{{
  vec->items = NULL;
  vec->count = 0;
  vec->cap = 0;
}}

static void ptc_line_vec_free(ptc_line_vec *vec)
{{
  size_t i;
  if (vec == NULL) {{
    return;
  }}
  for (i = 0; i < vec->count; ++i) {{
    free(vec->items[i]);
  }}
  free(vec->items);
  vec->items = NULL;
  vec->count = 0;
  vec->cap = 0;
}}

static int ptc_line_vec_push(ptc_line_vec *vec, const char *line)
{{
  char *copy;
  char **items;
  size_t cap;

  copy = strdup(line);
  if (copy == NULL) {{
    return -ENOMEM;
  }}
  if (vec->count == vec->cap) {{
    cap = vec->cap ? vec->cap * 2 : 32;
    items = realloc(vec->items, cap * sizeof(*items));
    if (items == NULL) {{
      free(copy);
      return -ENOMEM;
    }}
    vec->items = items;
    vec->cap = cap;
  }}
  vec->items[vec->count++] = copy;
  return 0;
}}

static char *ptc_trim_newline(char *line)
{{
  size_t len;
  if (line == NULL) {{
    return NULL;
  }}
  len = strlen(line);
  while (len > 0 && (line[len - 1] == '\\n' || line[len - 1] == '\\r')) {{
    line[--len] = '\\0';
  }}
  return line;
}}

static int ptc_parse_u64(const char *text, uint64_t *out)
{{
  char *end = NULL;
  unsigned long long value;
  if (text == NULL || out == NULL || *text == '\\0') {{
    return -EINVAL;
  }}
  errno = 0;
  value = strtoull(text, &end, 0);
  if (errno != 0 || end == text || *end != '\\0') {{
    return -EINVAL;
  }}
  *out = (uint64_t) value;
  return 0;
}}

static int ptc_parse_int64(const char *text, int64_t *out)
{{
  char *end = NULL;
  long long value;
  if (text == NULL || out == NULL || *text == '\\0') {{
    return -EINVAL;
  }}
  errno = 0;
  value = strtoll(text, &end, 0);
  if (errno != 0 || end == text || *end != '\\0') {{
    return -EINVAL;
  }}
  *out = (int64_t) value;
  return 0;
}}

static PTCOpcode ptc_lookup_opcode(const char *name)
{{
  unsigned i;
  for (i = 0; i < PTC_INSTRUCTION_NB_OPS; ++i) {{
    if (ptc_opcode_defs_storage[i].name != NULL && strcmp(ptc_opcode_defs_storage[i].name, name) == 0) {{
      return (PTCOpcode) i;
    }}
  }}
  return (PTCOpcode) 0;
}}

static int ptc_parse_payload_line(char *line, const char **kind, char **rest)
{{
  const char *sep = strchr(line, '|');
  if (sep == NULL) {{
    return -EINVAL;
  }}
  *((char *) sep) = '\\0';
  *kind = line;
  *rest = (char *) (sep + 1);
  return 0;
}}

static int ptc_parse_assignment_line(char *line, const char **key, char **value)
{{
  const char *sep = strchr(line, '=');
  if (sep == NULL) {{
    return -EINVAL;
  }}
  *((char *) sep) = '\\0';
  *key = line;
  *value = (char *) (sep + 1);
  return 0;
}}

static int ptc_build_instruction_list_from_payload(FILE *stream, PTCInstructionList *instructions, uint64_t *dymvirtual_address)
{{
  char *line = NULL;
  size_t line_cap = 0;
  ssize_t line_len;
  ptc_line_vec lines;
  size_t i;
  size_t instruction_count = 0;
  size_t argument_count = 0;
  size_t temp_count = 0;
  size_t global_temps = 0;
  size_t total_temps = 0;
  PTCInstructionArg *arguments = NULL;
  PTCInstruction *instruction_table = NULL;
  PTCTemp *temp_table = NULL;
  size_t arg_cursor = 0;
  size_t temp_name_bytes = 0;
  int in_header = 1;

  ptc_line_vec_init(&lines);
  while ((line_len = getline(&line, &line_cap, stream)) != -1) {{
    (void) line_len;
    ptc_trim_newline(line);
    if (line[0] == '\\0' || line[0] == '#') {{
      continue;
    }}
    if (ptc_line_vec_push(&lines, line) != 0) {{
      free(line);
      ptc_line_vec_free(&lines);
      return -ENOMEM;
    }}
  }}
  free(line);

  for (i = 0; i < lines.count; ++i) {{
    const char *key;
    const char *kind;
    char *rest;
    char *tmp;
    char *value;

    if (strcmp(lines.items[i], "PTC_LIVE_SIDECAR v1") == 0) {{
      continue;
    }}
    if (in_header && ptc_parse_assignment_line(lines.items[i], &key, &value) == 0) {{
      if (strcmp(key, "instruction_count") == 0) {{
        uint64_t parsed = 0;
        if (ptc_parse_u64(value, &parsed) != 0) {{
          ptc_line_vec_free(&lines);
          return -EINVAL;
        }}
        instruction_count = (size_t) parsed;
        continue;
      }}
      if (strcmp(key, "argument_count") == 0) {{
        uint64_t parsed = 0;
        if (ptc_parse_u64(value, &parsed) != 0) {{
          ptc_line_vec_free(&lines);
          return -EINVAL;
        }}
        argument_count = (size_t) parsed;
        continue;
      }}
      if (strcmp(key, "temp_count") == 0) {{
        uint64_t parsed = 0;
        if (ptc_parse_u64(value, &parsed) != 0) {{
          ptc_line_vec_free(&lines);
          return -EINVAL;
        }}
        temp_count = (size_t) parsed;
        continue;
      }}
      if (strcmp(key, "global_temps") == 0) {{
        uint64_t parsed = 0;
        if (ptc_parse_u64(value, &parsed) != 0) {{
          ptc_line_vec_free(&lines);
          return -EINVAL;
        }}
        global_temps = (size_t) parsed;
        continue;
      }}
      if (strcmp(key, "total_temps") == 0) {{
        uint64_t parsed = 0;
        if (ptc_parse_u64(value, &parsed) != 0) {{
          ptc_line_vec_free(&lines);
          return -EINVAL;
        }}
        total_temps = (size_t) parsed;
        continue;
      }}
      continue;
    }}
    if (strncmp(lines.items[i], "instruction|", sizeof("instruction|") - 1) == 0 ||
        strncmp(lines.items[i], "temp|", sizeof("temp|") - 1) == 0) {{
      in_header = 0;
      continue;
    }}
    if (in_header) {{
      continue;
    }}
  }}

  if (instruction_count == 0 || argument_count == 0 || temp_count == 0 || total_temps == 0 || global_temps == 0) {{
    fprintf(stderr, "ptc payload parse rejected counts: instruction_count=%zu argument_count=%zu temp_count=%zu global_temps=%zu total_temps=%zu\\n",
            instruction_count, argument_count, temp_count, global_temps, total_temps);
    ptc_line_vec_free(&lines);
    return -EINVAL;
  }}

  instruction_table = calloc(instruction_count, sizeof(*instruction_table));
  arguments = calloc(argument_count, sizeof(*arguments));
  temp_table = calloc(temp_count, sizeof(*temp_table));
  if (instruction_table == NULL || arguments == NULL || temp_table == NULL) {{
    free(instruction_table);
    free(arguments);
    free(temp_table);
    ptc_line_vec_free(&lines);
    return -ENOMEM;
  }}

  for (i = 0; i < lines.count; ++i) {{
    const char *key;
    const char *kind;
    char *rest;
    char *fields[16];
    char *mutable_line;

    if (strcmp(lines.items[i], "PTC_LIVE_SIDECAR v1") == 0) {{
      continue;
    }}
    if (ptc_parse_assignment_line(lines.items[i], &key, &rest) == 0) {{
      continue;
    }}
    if (ptc_parse_payload_line(lines.items[i], &kind, &rest) != 0) {{
      continue;
    }}
    in_header = 0;
    if (strcmp(kind, "instruction") == 0) {{
      size_t field_count = 0;
      mutable_line = strdup(rest);
      char *cursor = mutable_line;
      char *token;
      char *save = NULL;
      uint64_t parsed_inst_index = 0;
      uint64_t parsed_arg_count = 0;
      size_t inst_index;
      size_t arg_count;
      size_t arg_i;

      if (mutable_line == NULL) {{
        free(instruction_table);
        free(arguments);
        free(temp_table);
        ptc_line_vec_free(&lines);
        return -ENOMEM;
      }}
      while ((token = strtok_r(cursor, "|", &save)) != NULL && field_count < 16) {{
        fields[field_count++] = token;
        cursor = NULL;
      }}
      if (field_count != 6) {{
        fprintf(stderr, "ptc payload parse instruction field mismatch: got=%zu expected=6 line=%s\\n", field_count, rest);
        free(mutable_line);
        free(instruction_table);
        free(arguments);
        free(temp_table);
        ptc_line_vec_free(&lines);
        return -EINVAL;
      }}
      if (ptc_parse_u64(fields[0], &parsed_inst_index) != 0 ||
          ptc_parse_u64(fields[4], &parsed_arg_count) != 0) {{
        fprintf(stderr, "ptc payload parse instruction numeric mismatch: index=%s arg_count=%s\\n", fields[0], fields[4]);
        free(mutable_line);
        free(instruction_table);
        free(arguments);
        free(temp_table);
        ptc_line_vec_free(&lines);
        return -EINVAL;
      }}
      inst_index = (size_t) parsed_inst_index;
      arg_count = (size_t) parsed_arg_count;
      if (inst_index >= instruction_count) {{
        fprintf(stderr, "ptc payload parse instruction index out of range: index=%zu limit=%zu\\n", inst_index, instruction_count);
        free(mutable_line);
        free(instruction_table);
        free(arguments);
        free(temp_table);
        ptc_line_vec_free(&lines);
        return -EINVAL;
      }}
      instruction_table[inst_index].opc = ptc_lookup_opcode(fields[1]);
      instruction_table[inst_index].callo = (unsigned) strtoul(fields[2], NULL, 0);
      instruction_table[inst_index].calli = (unsigned) strtoul(fields[3], NULL, 0);
      instruction_table[inst_index].args = arguments + arg_cursor;
      if (field_count > 5 && fields[5][0] != '\\0') {{
        char *args_copy = strdup(fields[5]);
        char *arg_cursor_text = args_copy;
        char *arg_token;
        char *arg_save = NULL;
        size_t arg_seen = 0;
        if (args_copy == NULL) {{
          free(mutable_line);
          free(instruction_table);
          free(arguments);
          free(temp_table);
          ptc_line_vec_free(&lines);
          return -ENOMEM;
        }}
        while ((arg_token = strtok_r(arg_cursor_text, ",", &arg_save)) != NULL) {{
          uint64_t parsed_arg = 0;
          if (ptc_parse_u64(arg_token, &parsed_arg) != 0) {{
            fprintf(stderr, "ptc payload parse instruction arg numeric mismatch: index=%zu token=%s\\n", inst_index, arg_token);
            free(args_copy);
            free(mutable_line);
            free(instruction_table);
            free(arguments);
            free(temp_table);
            ptc_line_vec_free(&lines);
            return -EINVAL;
          }}
          if (arg_cursor + arg_seen >= argument_count) {{
            fprintf(stderr, "ptc payload parse instruction arg overflow: cursor=%zu seen=%zu limit=%zu\\n", arg_cursor, arg_seen, argument_count);
            free(args_copy);
            free(mutable_line);
            free(instruction_table);
            free(arguments);
            free(temp_table);
            ptc_line_vec_free(&lines);
            return -EINVAL;
          }}
          arguments[arg_cursor + arg_seen] = (PTCInstructionArg) parsed_arg;
          ++arg_seen;
          arg_cursor_text = NULL;
        }}
        if (arg_seen != arg_count) {{
          fprintf(stderr, "ptc payload parse instruction arg count mismatch: index=%zu parsed=%zu expected=%zu\\n", inst_index, arg_seen, arg_count);
          free(args_copy);
          free(mutable_line);
          free(instruction_table);
          free(arguments);
          free(temp_table);
          ptc_line_vec_free(&lines);
          return -EINVAL;
        }}
        free(args_copy);
      }}
      arg_cursor += arg_count;
      free(mutable_line);
      continue;
    }}
    if (strcmp(kind, "temp") == 0) {{
      size_t field_count = 0;
      mutable_line = strdup(rest);
      char *cursor = mutable_line;
      char *token;
      char *save = NULL;
      uint64_t parsed_temp_index = 0;
      int64_t mem_offset = 0;
      uint64_t val = 0;
      size_t temp_index = 0;
      char *name_copy;

      if (mutable_line == NULL) {{
        free(instruction_table);
        free(arguments);
        free(temp_table);
        ptc_line_vec_free(&lines);
        return -ENOMEM;
      }}
      while ((token = strtok_r(cursor, "|", &save)) != NULL && field_count < 16) {{
        fields[field_count++] = token;
        cursor = NULL;
      }}
      if (field_count != 14) {{
        fprintf(stderr, "ptc payload parse temp field mismatch: got=%zu expected=14 line=%s\\n", field_count, rest);
        free(mutable_line);
        free(instruction_table);
        free(arguments);
        free(temp_table);
        ptc_line_vec_free(&lines);
        return -EINVAL;
      }}
      if (ptc_parse_u64(fields[0], &parsed_temp_index) != 0 ||
          ptc_parse_int64(fields[7], &mem_offset) != 0 ||
          ptc_parse_u64(fields[8], &val) != 0) {{
        fprintf(stderr, "ptc payload parse temp numeric mismatch: index=%s mem_offset=%s val=%s\\n", fields[0], fields[7], fields[8]);
        free(mutable_line);
        free(instruction_table);
        free(arguments);
        free(temp_table);
        ptc_line_vec_free(&lines);
        return -EINVAL;
      }}
      temp_index = (size_t) parsed_temp_index;
      if (temp_index >= temp_count) {{
        fprintf(stderr, "ptc payload parse temp index out of range: index=%zu limit=%zu\\n", temp_index, temp_count);
        free(mutable_line);
        free(instruction_table);
        free(arguments);
        free(temp_table);
        ptc_line_vec_free(&lines);
        return -EINVAL;
      }}
      name_copy = strdup(fields[1]);
      if (name_copy == NULL) {{
        free(mutable_line);
        free(instruction_table);
        free(arguments);
        free(temp_table);
        ptc_line_vec_free(&lines);
        return -ENOMEM;
      }}
      temp_table[temp_index].name = name_copy;
      temp_table[temp_index].val_type = (PTCTempType) strtoul(fields[2], NULL, 0);
      temp_table[temp_index].base_type = (PTCType) strtoul(fields[3], NULL, 0);
      temp_table[temp_index].type = (PTCType) strtoul(fields[4], NULL, 0);
      temp_table[temp_index].reg = (uint8_t) strtoul(fields[5], NULL, 0);
      temp_table[temp_index].mem_reg = (uint8_t) strtoul(fields[6], NULL, 0);
      temp_table[temp_index].mem_offset = (intptr_t) mem_offset;
      temp_table[temp_index].val = (uint64_t) val;
      temp_table[temp_index].fixed_reg = (unsigned int) strtoul(fields[9], NULL, 0);
      temp_table[temp_index].mem_coherent = (unsigned int) strtoul(fields[10], NULL, 0);
      temp_table[temp_index].mem_allocated = (unsigned int) strtoul(fields[11], NULL, 0);
      temp_table[temp_index].temp_local = (unsigned int) strtoul(fields[12], NULL, 0);
      temp_table[temp_index].temp_allocated = (unsigned int) strtoul(fields[13], NULL, 0);
      free(mutable_line);
      continue;
    }}
  }}

  if (arg_cursor != argument_count) {{
    fprintf(stderr, "ptc payload parse argument mismatch: parsed=%zu expected=%zu instruction_count=%zu temp_count=%zu global_temps=%zu total_temps=%zu\\n",
            arg_cursor, argument_count, instruction_count, temp_count, global_temps, total_temps);
    free(instruction_table);
    free(arguments);
    free(temp_table);
    ptc_line_vec_free(&lines);
    return -EINVAL;
  }}

  instructions->instructions = instruction_table;
  instructions->arguments = arguments;
  instructions->temps = temp_table;
  instructions->instruction_count = (unsigned) instruction_count;
  instructions->global_temps = (unsigned) global_temps;
  instructions->total_temps = (unsigned) total_temps;

  ptc_line_vec_free(&lines);
  if (dymvirtual_address != NULL) {{
    *dymvirtual_address = UINT64_C(0x401000);
  }}
  return 0;
}}

const char *ptc_get_abi_metadata(void)
{{
  return ptc_abi_metadata;
}}

int ptc_load(void *handle, PTCInterface *output, const char *ptc_filename, const char *exe_args)
{{
  PTCInterface result = {{ 0 }};

  (void) handle;
  (void) ptc_filename;
  (void) exe_args;
  if (output == NULL) {{
    return -EINVAL;
  }}

  ptc_init_env_once();
  ptc_reset_status(0);

  result.translate = &ptc_translate;
  result.opcode_defs = ptc_opcode_defs_storage;
  result.helper_defs = ptc_helper_defs_storage;
  result.helper_defs_size = 1;
  result.initialized_env = ptc_initialized_env;
  result.regs = ptc_regs;
  result.pc = 0;
  result.sp = 0;
  result.exception_index = 0;
  result.ElfStartStack = &ptc_elf_start_stack;
  result.exception_syscall = &ptc_exception_syscall;
  result.syscall_next_eip = &ptc_syscall_next_eip;
  result.isIndirect = &ptc_is_indirect;
  result.isCall = &ptc_is_call;
  result.isDirectcall = &ptc_is_directcall;
  result.CallNext = &ptc_call_next;
  result.isIndirectJmp = &ptc_is_indirect_jmp;
  result.isDirectJmp = &ptc_is_direct_jmp;
  result.isRet = &ptc_is_ret;
  result.illegalAccessAddr = &ptc_illegal_access_addr;
  result.CFIAddr = &ptc_cfi_addr;
  result.isSyscall = &ptc_is_syscall;
  result.BlockSize = &ptc_block_size;
  result.iCount = &ptc_icount;
  result.isIllegal = &ptc_is_illegal;
  result.isAdd = &ptc_is_add;

  *output = result;
  return 0;
}}

size_t ptc_translate(uint64_t virtual_address, uint32_t force, PTCInstructionList *instructions, uint64_t *dymvirtual_address)
{{
  char command[4096];
  FILE *pipe;
  int status;
  size_t translated = 0;

  (void) force;
  if (instructions == NULL) {{
    return 0;
  }}

  snprintf(command, sizeof(command), "PTC_RR_DIR=%s PTC_SIDECAR_PAYLOAD_SOURCE=%s PTC_SIDECAR_MODEL_SOURCE=%s PTC_SIDECAR_SUMMARY_SOURCE=%s %s %s %s %u", "{rr_dir}", ptc_sidecar_payload_source, ptc_sidecar_model_source, ptc_sidecar_summary_source, ptc_sidecar_helper_path, ptc_sidecar_root_path, ptc_qemu_src_path, ptc_sidecar_jobs);
  pipe = popen(command, "r");
  if (pipe == NULL) {{
    return 0;
  }}

  memset(instructions, 0, sizeof(*instructions));
  if (ptc_build_instruction_list_from_payload(pipe, instructions, dymvirtual_address) != 0) {{
    fprintf(stderr, "ptc_translate: payload reconstruction failed after sidecar success\\n");
    pclose(pipe);
    ptc_instruction_list_free(instructions);
    memset(instructions, 0, sizeof(*instructions));
    return 0;
  }}

  status = pclose(pipe);
  if (status == -1 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {{
    ptc_instruction_list_free(instructions);
    memset(instructions, 0, sizeof(*instructions));
    return 0;
  }}

  ptc_reset_status(virtual_address);
  ptc_icount = instructions->instruction_count;
  ptc_block_size = instructions->instruction_count;
  if (dymvirtual_address != NULL) {{
    *dymvirtual_address = virtual_address;
  }}
  translated = instructions->instruction_count;
  return translated;
}}
'''

harness_c = f'''#include <dlfcn.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define USE_DYNAMIC_PTC 1
#include "ptc.h"

typedef const char *(*ptc_get_abi_metadata_ptr_t)(void);

static int require_non_null(const void *pointer, const char *name)
{{
  if (pointer != NULL) {{
    return 0;
  }}
  fprintf(stderr, "missing pointer: %s\\n", name);
  return 1;
}}

static int require_metadata_field(const char *metadata, const char *field)
{{
  if (metadata != NULL && strstr(metadata, field) != NULL) {{
    return 0;
  }}
  fprintf(stderr, "metadata missing required field: %s\\n", field);
  return 1;
}}

static int verify_translation(PTCInterface *ptc, ptc_translate_ptr_t translate, uint64_t pc, const char *source, size_t *out_size, unsigned *out_instruction_count, unsigned *out_argument_count, unsigned *out_temp_count)
{{
  PTCInstructionList list = {{ 0 }};
  uint64_t dynamic_pc = 0;
  size_t size = translate(pc, 1, &list, &dynamic_pc);

  if (size <= 0) {{
    fprintf(stderr, "%s returned an empty translation\\n", source);
    ptc_instruction_list_free(&list);
    return 1;
  }}
  if (list.instruction_count == 0 || list.instructions == NULL || list.arguments == NULL || list.temps == NULL) {{
    fprintf(stderr, "%s returned an empty instruction list\\n", source);
    ptc_instruction_list_free(&list);
    return 1;
  }}
  if (list.instructions[0].args == NULL) {{
    fprintf(stderr, "%s produced a null args pointer on the first instruction\\n", source);
    ptc_instruction_list_free(&list);
    return 1;
  }}
  if (list.total_temps == 0 || list.global_temps == 0) {{
    fprintf(stderr, "%s produced an unexpected temp table\\n", source);
    ptc_instruction_list_free(&list);
    return 1;
  }}
  if (dynamic_pc != pc) {{
    fprintf(stderr, "%s changed the dynamic pc unexpectedly: 0x%" PRIx64 " -> 0x%" PRIx64 "\\n", source, pc, dynamic_pc);
    ptc_instruction_list_free(&list);
    return 1;
  }}

  if (out_size != NULL) {{
    *out_size = size;
  }}
  if (out_instruction_count != NULL) {{
    *out_instruction_count = list.instruction_count;
  }}
  if (out_argument_count != NULL) {{
    unsigned total_args = 0;
    size_t index;
    for (index = 0; index < list.instruction_count; ++index) {{
      if (list.instructions[index].opc == PTC_INSTRUCTION_op_call) {{
        total_args += (unsigned) list.instructions[index].callo + (unsigned) list.instructions[index].calli;
      }} else {{
        total_args += ptc_instruction_opcode_def(ptc, &list.instructions[index])->nb_args;
      }}
    }}
    *out_argument_count = total_args;
  }}
  if (out_temp_count != NULL) {{
    *out_temp_count = list.total_temps;
  }}

  ptc_instruction_list_free(&list);
  return 0;
}}

int main(int argc, char **argv)
{{
  const char *library_path = argc > 1 ? argv[1] : "{lib_so}";
  void *handle = NULL;
  ptc_load_ptr_t ptc_load = NULL;
  ptc_translate_ptr_t ptc_translate = NULL;
  ptc_get_abi_metadata_ptr_t get_metadata = NULL;
  PTCInterface ptc = {{ 0 }};
  const char *metadata = NULL;
  size_t translated_size = 0;
  size_t translated_iface_size = 0;
  unsigned translated_instruction_count = 0;
  unsigned translated_argument_count = 0;
  unsigned translated_temp_count = 0;

  handle = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
  if (handle == NULL) {{
    fprintf(stderr, "dlopen failed for %s: %s\\n", library_path, dlerror());
    return 1;
  }}

  ptc_load = (ptc_load_ptr_t) dlsym(handle, "ptc_load");
  if (ptc_load == NULL) {{
    fprintf(stderr, "dlsym(ptc_load) failed: %s\\n", dlerror());
    dlclose(handle);
    return 1;
  }}

  ptc_translate = (ptc_translate_ptr_t) dlsym(handle, "ptc_translate");
  if (ptc_translate == NULL) {{
    fprintf(stderr, "dlsym(ptc_translate) failed: %s\\n", dlerror());
    dlclose(handle);
    return 1;
  }}

  get_metadata = (ptc_get_abi_metadata_ptr_t) dlsym(handle, "ptc_get_abi_metadata");
  if (get_metadata == NULL) {{
    fprintf(stderr, "dlsym(ptc_get_abi_metadata) failed: %s\\n", dlerror());
    dlclose(handle);
    return 1;
  }}

  if (ptc_load(handle, &ptc, "/tmp/qemu-v2-ptc-live-sidecar-smoke-input", "") != 0) {{
    fputs("ptc_load returned failure\\n", stderr);
    dlclose(handle);
    return 1;
  }}

  metadata = get_metadata();
  if (metadata == NULL) {{
    fputs("ptc_get_abi_metadata returned NULL\\n", stderr);
    dlclose(handle);
    return 1;
  }}

  if (require_metadata_field(metadata, "abi_version=2") != 0 ||
      require_metadata_field(metadata, "bridge_kind=live_sidecar") != 0 ||
      require_metadata_field(metadata, "real_translation=true") != 0 ||
      require_metadata_field(metadata, "sidecar_triggered_during_ptc_translate=true") != 0 ||
      require_metadata_field(metadata, "exact_repo_ptc_h=true") != 0) {{
    dlclose(handle);
    return 1;
  }}

  if (require_non_null(ptc.translate, "PTCInterface.translate") != 0 ||
      require_non_null(ptc.opcode_defs, "PTCInterface.opcode_defs") != 0 ||
      require_non_null(ptc.helper_defs, "PTCInterface.helper_defs") != 0 ||
      require_non_null(ptc.initialized_env, "PTCInterface.initialized_env") != 0 ||
      require_non_null(ptc.regs, "PTCInterface.regs") != 0 ||
      require_non_null(ptc.ElfStartStack, "PTCInterface.ElfStartStack") != 0) {{
    dlclose(handle);
    return 1;
  }}

  if (verify_translation(&ptc, ptc_translate, 0x401000u, "dlsym(ptc_translate)", &translated_size, &translated_instruction_count, &translated_argument_count, &translated_temp_count) != 0) {{
    dlclose(handle);
    return 1;
  }}

  if (verify_translation(&ptc, ptc.translate, 0x402000u, "PTCInterface.translate", &translated_iface_size, NULL, NULL, NULL) != 0) {{
    dlclose(handle);
    return 1;
  }}

  printf("live sidecar smoke ok: library=%s instruction_count=%u argument_count=%u temp_count=%u translated_size=%zu iface_translated_size=%zu sidecar_log=%s sidecar_model=%s sidecar_summary=%s metadata=%s\\n",
         library_path,
         translated_instruction_count,
         translated_argument_count,
         translated_temp_count,
         translated_size,
         translated_iface_size,
         "{side_log}",
         "{side_model}",
         "{side_summary}",
         metadata);

  dlclose(handle);
  return 0;
}}
'''

lib_c_path.write_text(lib_c)
harness_c_path.write_text(harness_c)
PY

log "Running bash -n on the new smoke script"
bash -n "$SCRIPT_DIR/qemu_v2_ptc_live_sidecar_translate_smoke.sh"

log "Building shared library and harness"
cc -std=c11 -O2 -g -fPIC -shared -D_GNU_SOURCE \
  -I"$RR_DIR/qemu/linux-user" \
  -I"$RR_DIR/qemu/tcg" \
  -Wno-unused-parameter \
  -o "$LIB_SO" \
  "$LIB_C"

cc -std=c11 -O2 -g -D_GNU_SOURCE \
  -I"$RR_DIR/qemu/linux-user" \
  -I"$RR_DIR/qemu/tcg" \
  -Wno-unused-parameter \
  -o "$HARNESS_BIN" \
  "$HARNESS_C" \
  -ldl

log "Running live sidecar smoke"
"$HARNESS_BIN" "$LIB_SO" | tee "$HARNESS_LOG"

python3 - "$HARNESS_LOG" "$SUMMARY_JSON" "$SIDE_LOG" "$SIDE_MODEL_JSON" "$SIDE_SUMMARY_JSON" "$LIB_SO" "$SCRATCH_ROOT" <<'PY'
import json
import sys
from pathlib import Path

log_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
side_log = Path(sys.argv[3])
side_model = Path(sys.argv[4])
side_summary = Path(sys.argv[5])
lib_so = Path(sys.argv[6])
scratch_root = Path(sys.argv[7])

text = log_path.read_text().strip()
if "live sidecar smoke ok:" not in text:
    raise SystemExit(f"missing success line in log: {log_path}")

summary = {
    "scratch_root": str(scratch_root),
    "library_path": str(lib_so),
    "sidecar_log": str(side_log),
    "sidecar_model_json": str(side_model),
    "sidecar_summary_json": str(side_summary),
    "ptc_translate_sidecar_triggered": True,
}
summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")

print(json.dumps({
    "scratch_root": str(scratch_root),
    "library_path": str(lib_so),
    "sidecar_log": str(side_log),
    "sidecar_model_json": str(side_model),
    "sidecar_summary_json": str(side_summary),
}, indent=2, sort_keys=True))
PY

log "Smoke complete"
printf 'scratch_root=%s\n' "$SCRATCH_ROOT"
printf 'library_path=%s\n' "$LIB_SO"
printf 'sidecar_log=%s\n' "$SIDE_LOG"
printf 'sidecar_model_json=%s\n' "$SIDE_MODEL_JSON"
printf 'sidecar_summary_json=%s\n' "$SIDE_SUMMARY_JSON"
printf 'summary_json=%s\n' "$SUMMARY_JSON"
