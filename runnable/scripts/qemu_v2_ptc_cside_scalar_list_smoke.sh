#!/usr/bin/env bash
#
# Consume the scalar PTC conversion-model JSON, allocate a non-empty
# PTCInstructionList-shaped payload on the C side, validate its invariants, and
# free it. This is ABI-compatible with the legacy repo ptc.h layout, but the
# harness remains outside QEMU and uses a generated /tmp test program.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_PTC_CSIDE_SCALAR_ROOT:-/tmp/rr-qemu-v2-upstream-probes/ptc-cside-scalar-list-smoke}"
SCALAR_SMOKE_ROOT="${RUNNABLE_QEMU_V2_PTC_REAL_SCALAR_ROOT:-/tmp/rr-qemu-v2-upstream-probes/ptc-real-translate-scalar-smoke}"
MODEL_JSON="${RUNNABLE_QEMU_V2_PTC_CSIDE_SCALAR_MODEL_JSON:-$SCALAR_SMOKE_ROOT/dumps/scalar-simple.ptc-conversion-model.json}"
QEMU_SRC="${RUNNABLE_QEMU_V2_UPSTREAM_SRC:-/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3}"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-3}"
FRESH=0

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_ptc_cside_scalar_list_smoke.sh [options]

Options:
  --scratch-root DIR     Output scratch root under /tmp.
                         Default: /tmp/rr-qemu-v2-upstream-probes/ptc-cside-scalar-list-smoke
  --scalar-smoke-root DIR
                         Scratch root to use if the scalar model must be generated.
                         Default: /tmp/rr-qemu-v2-upstream-probes/ptc-real-translate-scalar-smoke
  --model-json FILE      Existing scalar conversion-model JSON.
                         Default: $RUNNABLE_QEMU_V2_PTC_CSIDE_SCALAR_MODEL_JSON or the scalar-smoke root default
  --qemu-src DIR        QEMU 10.2.3 source tree to pass through when the scalar smoke must be generated.
                         Default: /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3
  --jobs N, -j N        Parallelism for the upstream scalar smoke. Default: 3 or RUNNABLE_QEMU_V2_JOBS.
  --fresh               Remove the c-side scratch root before running.
  -h, --help            Show this help.
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
    --scalar-smoke-root)
      SCALAR_SMOKE_ROOT="$(abs_path "${2:?missing value for --scalar-smoke-root}")"
      shift 2
      ;;
    --model-json)
      MODEL_JSON="$(abs_path "${2:?missing value for --model-json}")"
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
SCALAR_SMOKE_ROOT="$(abs_path "$SCALAR_SMOKE_ROOT")"
MODEL_JSON="$(abs_path "$MODEL_JSON")"
QEMU_SRC="$(abs_path "$QEMU_SRC")"

if [[ "$FRESH" -eq 1 ]]; then
  rm -rf "$SCRATCH_ROOT"
fi
mkdir -p "$SCRATCH_ROOT"

require_tool python3
require_tool cc
require_tool bash

if [[ ! -s "$MODEL_JSON" ]]; then
  log "Scalar model missing; generating it with qemu_v2_ptc_real_translate_scalar_smoke.sh"
  scalar_args=(
    "--scratch-root" "$SCALAR_SMOKE_ROOT"
    "--jobs" "$JOBS"
  )
  if [[ -d "$QEMU_SRC" ]]; then
    scalar_args+=("--qemu-src" "$QEMU_SRC")
  fi
  bash "$SCRIPT_DIR/qemu_v2_ptc_real_translate_scalar_smoke.sh" "${scalar_args[@]}"
fi

[[ -s "$MODEL_JSON" ]] || die "scalar conversion-model JSON is missing or empty: $MODEL_JSON"

HARNESS_C="$SCRATCH_ROOT/qemu_v2_ptc_cside_scalar_list_smoke.c"
HARNESS_BIN="$SCRATCH_ROOT/qemu_v2_ptc_cside_scalar_list_smoke"
HARNESS_LOG="$SCRATCH_ROOT/qemu_v2_ptc_cside_scalar_list_smoke.log"
HARNESS_SUMMARY_JSON="$SCRATCH_ROOT/qemu_v2_ptc_cside_scalar_list_smoke.summary.json"

log "Validating scalar model and generating the C harness"
python3 - "$MODEL_JSON" "$HARNESS_C" "$HARNESS_SUMMARY_JSON" <<'PY'
import json
import sys
from pathlib import Path

model_path = Path(sys.argv[1])
c_path = Path(sys.argv[2])
summary_path = Path(sys.argv[3])

with model_path.open() as stream:
    model = json.load(stream)

summary = model.get("summary", {})
instruction_count = int(summary.get("instruction_count", model.get("instruction_count", 0)))
argument_count = int(summary.get("argument_count", model.get("argument_count", 0)))
temp_count = int(summary.get("temp_count", model.get("temp_count", 0)))
emitted = int(summary.get("emitted", 0))
rejected = int(summary.get("rejected", 0))
vector_schema = int(summary.get("by_emit_kind", {}).get("vector-schema-required", 0))
global_temps = int(summary.get("global_temps", model.get("global_temps", 0)))

if instruction_count <= 0:
    raise SystemExit(f"instruction_count must be > 0, got {instruction_count}")
if argument_count <= 0:
    raise SystemExit(f"argument_count must be > 0, got {argument_count}")
if temp_count <= 0:
    raise SystemExit(f"temp_count must be > 0, got {temp_count}")
if emitted <= 0:
    raise SystemExit(f"emitted must be > 0, got {emitted}")
if rejected != 0:
    raise SystemExit(f"rejected must be 0, got {rejected}")
if vector_schema != 0:
    raise SystemExit(f"scalar subset unexpectedly contains vector-schema-required records: {vector_schema}")
if not model.get("model_policy", {}).get("not_runnable_lift_abi"):
    raise SystemExit("model is missing not_runnable_lift_abi=true")

instructions = model.get("instructions", [])
temps = model.get("temps", [])
flat_arguments = model.get("arguments", [])

if len(instructions) != instruction_count:
    raise SystemExit("instruction_count does not match instructions array length")
if len(temps) != temp_count:
    raise SystemExit("temp_count does not match temps array length")
if len(flat_arguments) != argument_count:
    raise SystemExit("argument_count does not match arguments array length")

def as_int(value):
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return int(value, 0)
    raise SystemExit(f"unsupported integer value: {value!r}")

def as_uint64_literal(value):
    return f"UINT64_C(0x{as_int(value):x})"

def as_c_string(value):
    if value is None:
        return "NULL"
    s = str(value)
    s = s.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{s}"'

def as_bool(value):
    return "1" if bool(value) else "0"

opcode_names = []
flat_args = []
instruction_rows = []
for index, inst in enumerate(instructions):
    decision = inst["decision"]
    if decision.get("emit_kind") == "vector-schema-required":
        raise SystemExit(f"unexpected vector-schema-required instruction at index {index}")
    opcode_name = decision.get("emit_opcode") or inst.get("ptc_list_model", {}).get("opc")
    if not isinstance(opcode_name, str) or not opcode_name:
        raise SystemExit(f"instruction {index} is missing a usable opcode name")
    arg_values = inst.get("args", [])
    if not isinstance(arg_values, list) or len(arg_values) <= 0:
        raise SystemExit(f"instruction {index} is expected to have non-empty args")
    ptc_list_model = inst.get("ptc_list_model", {})
    argument_start = int(ptc_list_model.get("argument_start", 0))
    argument_count_for_inst = int(ptc_list_model.get("argument_count", len(arg_values)))
    if argument_count_for_inst != len(arg_values):
        raise SystemExit(f"instruction {index} arg count mismatch")
    opcode_names.append(opcode_name)
    flat_args.extend(as_uint64_literal(arg) for arg in arg_values)
    instruction_rows.append({
        "opcode_name": opcode_name,
        "walker_name": inst.get("walker", {}).get("name"),
        "manifest_category": decision.get("manifest_category"),
        "compatibility": decision.get("compatibility"),
        "argument_start": argument_start,
        "argument_count": argument_count_for_inst,
        "callo": ptc_list_model.get("callo"),
        "calli": ptc_list_model.get("calli"),
    })

temp_rows = []
for index, temp in enumerate(temps):
    seed = temp.get("ptc_temp_model", {})
    name = temp.get("name") or f"temp_{index}"
    temp_rows.append({
        "name": name,
        "val_type": seed.get("val_type", 0),
        "base_type": seed.get("base_type", 0),
        "type": seed.get("type", 0),
        "reg": seed.get("reg"),
        "mem_reg": seed.get("mem_reg"),
        "mem_offset": seed.get("mem_offset"),
        "val": seed.get("val"),
        "fixed_reg": seed.get("fixed_reg"),
        "mem_coherent": seed.get("mem_coherent"),
        "mem_allocated": seed.get("mem_allocated"),
        "temp_local": temp.get("derived_candidates", {}).get("temp_local", {}).get("candidate"),
        "temp_allocated": seed.get("temp_allocated"),
        "is_global": temp.get("flags", {}).get("is_global"),
    })

global_mem_offset = None
global_mem_offset_index = None
for index, temp in enumerate(temps):
    offset = temp.get("ptc_temp_model", {}).get("mem_offset")
    if isinstance(offset, int):
        global_mem_offset = offset
        global_mem_offset_index = index
        break

def render_array(name, values):
    return "static const " + name + "[] = {\n" + ",\n".join(f"  {v}" for v in values) + "\n};\n"

instruction_entries = []
for row in instruction_rows:
    instruction_entries.append(
        "{ "
        f".opcode_name = {as_c_string(row['opcode_name'])}, "
        f".walker_name = {as_c_string(row['walker_name'])}, "
        f".manifest_category = {as_c_string(row['manifest_category'])}, "
        f".compatibility = {as_c_string(row['compatibility'])}, "
        f".argument_start = {row['argument_start']}, "
        f".argument_count = {row['argument_count']}, "
        f".callo = {0 if row['callo'] is None else int(row['callo'])}, "
        f".calli = {0 if row['calli'] is None else int(row['calli'])} "
        "}"
    )

temp_entries = []
for row in temp_rows:
    temp_entries.append(
        "{ "
        f".name = {as_c_string(row['name'])}, "
        f".val_type = {0 if row['val_type'] is None else int(row['val_type'])}, "
        f".base_type = {0 if row['base_type'] is None else int(row['base_type'])}, "
        f".type = {0 if row['type'] is None else int(row['type'])}, "
        f".reg = {0 if row['reg'] is None else int(row['reg'])}, "
        f".mem_reg = {0 if row['mem_reg'] is None else int(row['mem_reg'])}, "
        f".mem_offset = {0 if row['mem_offset'] is None else int(row['mem_offset'])}, "
        f".val = {0 if row['val'] is None else as_int(row['val'])}, "
        f".fixed_reg = {as_bool(row['fixed_reg'])}, "
        f".mem_coherent = {as_bool(row['mem_coherent'])}, "
        f".mem_allocated = {as_bool(row['mem_allocated'])}, "
        f".temp_local = {as_bool(row['temp_local'])}, "
        f".temp_allocated = {as_bool(row['temp_allocated'])}, "
        f".is_global = {as_bool(row['is_global'])} "
        "}"
    )

header_mode = "exact_repo_ptc.h"

c_source = f'''#include <inttypes.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ptc.h"

#define INSTRUCTION_COUNT {instruction_count}
#define ARGUMENT_COUNT {argument_count}
#define TEMP_COUNT {temp_count}
#define GLOBAL_TEMPS {global_temps}

struct InstructionSeed {{
  const char *opcode_name;
  const char *walker_name;
  const char *manifest_category;
  const char *compatibility;
  size_t argument_start;
  size_t argument_count;
  unsigned callo;
  unsigned calli;
}};

struct TempSeed {{
  const char *name;
  unsigned val_type;
  unsigned base_type;
  unsigned type;
  unsigned reg;
  unsigned mem_reg;
  intptr_t mem_offset;
  uint64_t val;
  unsigned fixed_reg;
  unsigned mem_coherent;
  unsigned mem_allocated;
  unsigned temp_local;
  unsigned temp_allocated;
  unsigned is_global;
}};

static const uint64_t kArguments[ARGUMENT_COUNT] = {{
{",\n".join("  " + value for value in flat_args)}
}};

static const struct InstructionSeed kInstructions[INSTRUCTION_COUNT] = {{
{",\n".join("  " + entry for entry in instruction_entries)}
}};

static const struct TempSeed kTemps[TEMP_COUNT] = {{
{",\n".join("  " + entry for entry in temp_entries)}
}};

static PTCOpcode resolve_opcode(const char *name)
{{
  if (strcmp(name, "ld_i32") == 0) return PTC_INSTRUCTION_op_ld_i32;
  if (strcmp(name, "ld_i64") == 0) return PTC_INSTRUCTION_op_ld_i64;
  if (strcmp(name, "st_i32") == 0) return PTC_INSTRUCTION_op_st_i32;
  if (strcmp(name, "st_i64") == 0) return PTC_INSTRUCTION_op_st_i64;
  if (strcmp(name, "mov_i32") == 0) return PTC_INSTRUCTION_op_mov_i32;
  if (strcmp(name, "mov_i64") == 0) return PTC_INSTRUCTION_op_mov_i64;
  if (strcmp(name, "add_i32") == 0) return PTC_INSTRUCTION_op_add_i32;
  if (strcmp(name, "add_i64") == 0) return PTC_INSTRUCTION_op_add_i64;
  if (strcmp(name, "discard") == 0) return PTC_INSTRUCTION_op_discard;
  if (strcmp(name, "exit_tb") == 0) return PTC_INSTRUCTION_op_exit_tb;
  if (strcmp(name, "brcond_i32") == 0) return PTC_INSTRUCTION_op_brcond_i32;
  if (strcmp(name, "debug_insn_start") == 0) return PTC_INSTRUCTION_op_debug_insn_start;
  if (strcmp(name, "set_label") == 0) return PTC_INSTRUCTION_op_set_label;
  if (strcmp(name, "call") == 0) return PTC_INSTRUCTION_op_call;
  if (strcmp(name, "st8_i32") == 0) return PTC_INSTRUCTION_op_st8_i32;
  fprintf(stderr, "unsupported opcode in scalar harness: %s\\n", name);
  exit(1);
}}

static void require(int condition, const char *message)
{{
  if (condition) {{
    return;
  }}
  fputs(message, stderr);
  fputc('\\n', stderr);
  exit(1);
}}

static void populate_list(PTCInstructionList *list)
{{
  memset(list, 0, sizeof(*list));
  list->instructions = calloc(INSTRUCTION_COUNT, sizeof(*list->instructions));
  list->arguments = calloc(ARGUMENT_COUNT, sizeof(*list->arguments));
  list->temps = calloc(TEMP_COUNT, sizeof(*list->temps));
  require(list->instructions != NULL, "instruction allocation failed");
  require(list->arguments != NULL, "argument allocation failed");
  require(list->temps != NULL, "temp allocation failed");

  for (size_t i = 0; i < ARGUMENT_COUNT; ++i) {{
    list->arguments[i] = kArguments[i];
  }}

  for (size_t i = 0; i < INSTRUCTION_COUNT; ++i) {{
    const struct InstructionSeed *seed = &kInstructions[i];
    PTCInstruction *inst = &list->instructions[i];
    const size_t end = seed->argument_start + seed->argument_count;

    inst->opc = resolve_opcode(seed->opcode_name);
    inst->callo = seed->callo;
    inst->calli = seed->calli;
    require(seed->argument_start < ARGUMENT_COUNT || seed->argument_count == 0,
            "instruction argument_start is out of range");
    require(end <= ARGUMENT_COUNT, "instruction argument span is out of range");
    inst->args = seed->argument_count > 0 ? &list->arguments[seed->argument_start] : NULL;
  }}

  for (size_t i = 0; i < TEMP_COUNT; ++i) {{
    const struct TempSeed *seed = &kTemps[i];
    PTCTemp *temp = &list->temps[i];
    temp->reg = (uint8_t) seed->reg;
    temp->mem_reg = (uint8_t) seed->mem_reg;
    temp->mem_offset = seed->mem_offset;
    temp->val = seed->val;
    temp->name = seed->name;
    temp->val_type = (PTCTempType) seed->val_type;
    temp->base_type = (PTCType) seed->base_type;
    temp->type = (PTCType) seed->type;
    temp->fixed_reg = seed->fixed_reg;
    temp->mem_coherent = seed->mem_coherent;
    temp->mem_allocated = seed->mem_allocated;
    temp->temp_local = seed->temp_local;
    temp->temp_allocated = seed->temp_allocated;
  }}

  list->instruction_count = INSTRUCTION_COUNT;
  list->global_temps = GLOBAL_TEMPS;
  list->total_temps = TEMP_COUNT;
}}

static void validate_list(const PTCInstructionList *list)
{{
  require(list->instructions != NULL, "instructions pointer must be non-null");
  require(list->arguments != NULL, "arguments pointer must be non-null");
  require(list->temps != NULL, "temps pointer must be non-null");
  require(list->instruction_count == INSTRUCTION_COUNT, "instruction count mismatch");
  require(list->global_temps > 0, "global_temps must be non-zero for this smoke");
  require(list->total_temps == TEMP_COUNT, "temp count mismatch");
  require(list->global_temps <= list->total_temps, "global_temps must not exceed total_temps");

  size_t counted_args = 0;
  for (size_t i = 0; i < INSTRUCTION_COUNT; ++i) {{
    const struct InstructionSeed *seed = &kInstructions[i];
    const PTCInstruction *inst = &list->instructions[i];
    const PTCOpcode expected = resolve_opcode(seed->opcode_name);

    require(inst->opc == expected, "instruction opcode mismatch");
    require(inst->callo == seed->callo, "instruction callo mismatch");
    require(inst->calli == seed->calli, "instruction calli mismatch");
    require(inst->args == (seed->argument_count > 0 ? &list->arguments[seed->argument_start] : NULL),
            "instruction args pointer mismatch");
    counted_args += seed->argument_count;
  }}

  require(counted_args == ARGUMENT_COUNT, "flat argument count mismatch");

  for (size_t i = 0; i < TEMP_COUNT; ++i) {{
    const struct TempSeed *seed = &kTemps[i];
    const PTCTemp *temp = &list->temps[i];
    require(temp->name != NULL, "temp name must be non-null");
    require(strcmp(temp->name, seed->name) == 0, "temp name mismatch");
    require(temp->mem_offset == seed->mem_offset, "temp mem_offset mismatch");
    require(temp->val == seed->val, "temp value mismatch");
  }}

  require(ptc_temp_is_global((PTCInstructionList *) list, 0), "temp[0] must be global");
  if (list->global_temps < list->total_temps) {{
    require(!ptc_temp_is_global((PTCInstructionList *) list, list->global_temps),
            "first non-global temp reported as global");
  }}

  {{
    const intptr_t probe_offset = {global_mem_offset if global_mem_offset is not None else 0};
    const int probe_index = ptc_temp_get_by_mem_offset((PTCInstructionList *) list, probe_offset);
    require(probe_index >= 0, "ptc_temp_get_by_mem_offset failed for a known offset");
    require((size_t) probe_index < list->total_temps, "probe temp index out of range");
    require(list->temps[probe_index].mem_offset == probe_offset,
            "ptc_temp_get_by_mem_offset returned the wrong temp");
  }}
}}

int main(void)
{{
  PTCInstructionList list;

  populate_list(&list);
  validate_list(&list);

  printf("cside scalar list smoke ok: header_mode={header_mode} instruction_count=%d argument_count=%d temp_count=%d global_temps=%u\\n",
         INSTRUCTION_COUNT,
         ARGUMENT_COUNT,
         TEMP_COUNT,
         GLOBAL_TEMPS);

  ptc_instruction_list_free(&list);
  return 0;
}}
'''

c_path.write_text(c_source)
summary = {
    "model_json": str(model_path),
    "instruction_count": instruction_count,
    "argument_count": argument_count,
    "temp_count": temp_count,
    "global_temps": global_temps,
    "header_mode": header_mode,
    "scalar_model": {
        "emitted": emitted,
        "rejected": rejected,
        "vector_schema_required": vector_schema,
    },
}
with summary_path.open("w") as stream:
    json.dump(summary, stream, indent=2, sort_keys=True)
    stream.write("\n")
print(json.dumps(summary, sort_keys=True))
PY

log "Compiling the generated C harness against the repo ptc.h ABI"
cc -std=c11 -O2 -g -Wall -Wextra -Werror \
  -Wno-unused-parameter \
  -I"$RR_DIR/qemu/linux-user" \
  -I"$RR_DIR/qemu/tcg" \
  -o "$HARNESS_BIN" \
  "$HARNESS_C"

log "Running the C-side allocation/free smoke"
"$HARNESS_BIN" | tee "$HARNESS_LOG"

cat <<EOF

C-side scalar PTC list smoke passed.
  Scratch root: $SCRATCH_ROOT
  Model JSON:   $MODEL_JSON
  Harness:      $HARNESS_C
  Binary:       $HARNESS_BIN
  Log:          $HARNESS_LOG
  ABI mode:     exact repo ptc.h + repo tcg-opc.h
EOF
