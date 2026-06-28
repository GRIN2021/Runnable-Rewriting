#!/usr/bin/env bash
#
# Build a throwaway libtinycode-x86_64.so under /tmp that exports ptc_load and
# ptc_translate, then dlopen it and verify that ptc_translate produces a
# non-empty scalar PTCInstructionList derived from the prior scalar conversion
# model or from a regenerated model when needed.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
LEGACY_QEMU_DIR="${RUNNABLE_QEMU_LEGACY_SRC:-$RR_DIR/archive/qemu-legacy-2.4.50}"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_PTC_DYNAMIC_SCALAR_ROOT:-/tmp/rr-qemu-v2-upstream-probes/ptc-dynamic-scalar-translate-smoke}"
SCALAR_SMOKE_ROOT="${RUNNABLE_QEMU_V2_PTC_REAL_SCALAR_ROOT:-/tmp/rr-qemu-v2-upstream-probes/ptc-real-translate-scalar-smoke}"
MODEL_JSON="${RUNNABLE_QEMU_V2_PTC_DYNAMIC_SCALAR_MODEL_JSON:-$SCALAR_SMOKE_ROOT/dumps/scalar-simple.ptc-conversion-model.json}"
QEMU_SRC="${RUNNABLE_QEMU_V2_UPSTREAM_SRC:-/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3}"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-3}"
FRESH=0

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_ptc_dynamic_scalar_translate_smoke.sh [options]

Options:
  --scratch-root DIR     Output scratch root under /tmp.
                         Default: /tmp/rr-qemu-v2-upstream-probes/ptc-dynamic-scalar-translate-smoke
  --scalar-smoke-root DIR
                         Scratch root to use if the scalar model must be generated.
                         Default: /tmp/rr-qemu-v2-upstream-probes/ptc-real-translate-scalar-smoke
  --model-json FILE      Existing scalar conversion-model JSON.
                         Default: $RUNNABLE_QEMU_V2_PTC_DYNAMIC_SCALAR_MODEL_JSON or the scalar-smoke root default
  --qemu-src DIR         QEMU 10.2.3 source tree to pass to the scalar-model smoke if regeneration is needed.
                         Default: /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3
  --jobs N, -j N         Parallelism for the scalar-model smoke. Default: 3 or RUNNABLE_QEMU_V2_JOBS.
  --fresh                Remove this smoke's scratch root before running.
  -h, --help             Show this help.
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

LIB_C="$SCRATCH_ROOT/qemu_v2_ptc_dynamic_scalar_translate_lib.c"
HARNESS_C="$SCRATCH_ROOT/qemu_v2_ptc_dynamic_scalar_translate_smoke.c"
HARNESS_BIN="$SCRATCH_ROOT/qemu_v2_ptc_dynamic_scalar_translate_smoke"
HARNESS_LOG="$SCRATCH_ROOT/qemu_v2_ptc_dynamic_scalar_translate_smoke.log"
SUMMARY_JSON="$SCRATCH_ROOT/qemu_v2_ptc_dynamic_scalar_translate_smoke.summary.json"
LIB_SO="$SCRATCH_ROOT/libtinycode-x86_64.so"

log "Generating throwaway libtinycode and dlopen harness"
python3 - "$MODEL_JSON" "$LIB_C" "$HARNESS_C" "$SUMMARY_JSON" "$LIB_SO" "$SCRATCH_ROOT" <<'PY'
import json
import sys
from pathlib import Path

model_path = Path(sys.argv[1])
lib_c_path = Path(sys.argv[2])
harness_c_path = Path(sys.argv[3])
summary_path = Path(sys.argv[4])
lib_so_path = Path(sys.argv[5])
scratch_root = Path(sys.argv[6])

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
total_temps = int(summary.get("total_temps", model.get("total_temps", 0)))

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
    raise SystemExit(f"vector-schema-required unexpectedly present: {vector_schema}")

def c_string(value):
    if value is None:
        return "NULL"
    s = str(value)
    s = s.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{s}"'

def as_int(value):
    if isinstance(value, bool):
      return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return int(value, 0)
    raise SystemExit(f"unsupported integer value: {value!r}")

def as_u64(value):
    return f"UINT64_C(0x{as_int(value):x})"

def opt_int(value, default=0):
    if value is None:
        return default
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return int(value, 0)
    return default

instructions = model.get("instructions", [])
temps = model.get("temps", [])
if len(instructions) != instruction_count:
    raise SystemExit("instruction_count does not match instructions array length")
if len(temps) != temp_count:
    raise SystemExit("temp_count does not match temps array length")

def get_ptc_opc(inst, idx):
    model = inst.get("ptc_list_model", {})
    opc = model.get("opc")
    if not isinstance(opc, str) or not opc:
        raise SystemExit(f"instruction {idx} missing ptc opcode name")
    return opc

instruction_entries = []
flat_args = []
arg_offsets = []
for idx, inst in enumerate(instructions):
    args = inst.get("args", [])
    if not isinstance(args, list) or not args:
        raise SystemExit(f"instruction {idx} has no args")
    model = inst.get("ptc_list_model", {})
    arg_start = int(model.get("argument_start", len(flat_args)))
    if arg_start != len(flat_args):
        raise SystemExit(f"instruction {idx} argument_start mismatch: {arg_start} != {len(flat_args)}")
    callo = model.get("callo")
    calli = model.get("calli")
    instruction_entries.append(
        {
            "opc": get_ptc_opc(inst, idx),
            "callo": int(callo) if isinstance(callo, int) else 0,
            "calli": int(calli) if isinstance(calli, int) else 0,
            "arg_count": len(args),
        }
    )
    arg_offsets.append(len(flat_args))
    flat_args.extend(as_u64(arg) for arg in args)

temp_entries = []
for idx, temp in enumerate(temps):
    model = temp.get("ptc_temp_model", {})
    temp_entries.append(
        {
            "name": temp.get("name") or f"temp_{idx}",
            "val_type": opt_int(model.get("val_type"), 0),
            "base_type": opt_int(model.get("base_type"), 0),
            "type": opt_int(model.get("type"), 0),
            "reg": model.get("reg"),
            "mem_reg": model.get("mem_reg"),
            "mem_offset": opt_int(model.get("mem_offset"), 0),
            "val": model.get("val"),
            "fixed_reg": 1 if model.get("fixed_reg") else 0,
            "mem_coherent": 1 if model.get("mem_coherent") else 0,
            "mem_allocated": 1 if model.get("mem_allocated") else 0,
            "temp_local": 1 if temp.get("derived_candidates", {}).get("temp_local", {}).get("candidate") else 0,
            "temp_allocated": 1 if model.get("temp_allocated") else 0,
        }
    )

def c_enum(name):
    return f"PTC_INSTRUCTION_op_{name}"

def c_temp_initializer(entry):
    reg = "0" if entry["reg"] is None else str(int(entry["reg"]))
    mem_reg = "0" if entry["mem_reg"] is None else str(int(entry["mem_reg"]))
    val = "0" if entry["val"] is None else as_u64(entry["val"])
    return (
        "{ .reg = %s, .mem_reg = %s, .mem_offset = %s, .val = %s, "
        ".name = %s, .val_type = %u, .base_type = %u, .type = %u, "
        ".fixed_reg = %u, .mem_coherent = %u, .mem_allocated = %u, "
        ".temp_local = %u, .temp_allocated = %u }"
        % (
            reg,
            mem_reg,
            str(int(entry["mem_offset"])),
            val,
            c_string(entry["name"]),
            int(entry["val_type"]),
            int(entry["base_type"]),
            int(entry["type"]),
            int(entry["fixed_reg"]),
            int(entry["mem_coherent"]),
            int(entry["mem_allocated"]),
            int(entry["temp_local"]),
            int(entry["temp_allocated"]),
        )
    )

def c_instruction_initializer(entry):
    return "{ .opc = %s, .callo = %u, .calli = %u, .arg_count = %u }" % (
        c_enum(entry["opc"]),
        int(entry["callo"]),
        int(entry["calli"]),
        int(entry["arg_count"]),
    )

lib_source = f'''#include <errno.h>
#include <inttypes.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
  PTCOpcode opc;
  unsigned callo;
  unsigned calli;
  unsigned arg_count;
}} PTCInstructionTemplate;

static const char ptc_abi_metadata[] =
  "abi_version=2\\n"
  "stub_kind=scalar_model_backed\\n"
  "real_translation=false\\n"
  "vector_schema=false\\n"
  "model_source=scalar-simple.ptc-conversion-model.json\\n";

static const PTCInstructionArg ptc_template_args[{len(flat_args)}] = {{
  {', '.join(flat_args)}
}};

static const size_t ptc_template_arg_offsets[{len(arg_offsets)}] = {{
  {', '.join(str(x) for x in arg_offsets)}
}};

static const PTCInstructionTemplate ptc_template_instructions[{len(instruction_entries)}] = {{
  {', '.join(c_instruction_initializer(entry) for entry in instruction_entries)}
}};

static const PTCTemp ptc_template_temps[{len(temp_entries)}] = {{
  {', '.join(c_temp_initializer(entry) for entry in temp_entries)}
}};

PTCOpcodeDef *ptc_opcode_defs;
PTCHelperDef *ptc_helper_defs;
unsigned ptc_helper_defs_size;

static PTCOpcodeDef ptc_opcode_defs_storage[PTC_INSTRUCTION_NB_OPS] = {{
#define DEF(op_name, oargs, iargs, cargs, flags) \
  [PTC_INSTRUCTION_op_##op_name] = {{ .name = #op_name, .nb_oargs = (uint8_t) (oargs), .nb_iargs = (uint8_t) (iargs), .nb_cargs = (uint8_t) (cargs), .nb_args = (uint8_t) ((oargs) + (iargs) + (cargs)) }},
#include "tcg-opc.h"
#undef DEF
}};

static PTCHelperDef ptc_helper_defs_storage[1] = {{
  {{ NULL, "ptc_scalar_model_backed_helper_table", 0u }},
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
  (void) virtual_address;
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

const char *ptc_get_abi_metadata(void)
{{
  return ptc_abi_metadata;
}}

static int ptc_copy_template_list(PTCInstructionList *instructions)
{{
  size_t i;
  size_t instruction_count = {instruction_count};
  size_t argument_count = {argument_count};
  size_t temp_count = {temp_count};

  instructions->instructions = calloc(instruction_count, sizeof(PTCInstruction));
  instructions->arguments = calloc(argument_count, sizeof(PTCInstructionArg));
  instructions->temps = calloc(temp_count, sizeof(PTCTemp));
  if (instructions->instructions == NULL || instructions->arguments == NULL || instructions->temps == NULL) {{
    ptc_instruction_list_free(instructions);
    memset(instructions, 0, sizeof(*instructions));
    return -ENOMEM;
  }}

  memcpy(instructions->arguments, ptc_template_args, sizeof(ptc_template_args));
  memcpy(instructions->temps, ptc_template_temps, sizeof(ptc_template_temps));

  for (i = 0; i < instruction_count; ++i) {{
    instructions->instructions[i].opc = ptc_template_instructions[i].opc;
    instructions->instructions[i].callo = ptc_template_instructions[i].callo;
    instructions->instructions[i].calli = ptc_template_instructions[i].calli;
    instructions->instructions[i].args = instructions->arguments + ptc_template_arg_offsets[i];
  }}

  instructions->instruction_count = (unsigned) instruction_count;
  instructions->global_temps = (unsigned) {global_temps};
  instructions->total_temps = (unsigned) {total_temps};
  return 0;
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
  (void) force;

  if (instructions == NULL) {{
    return 0;
  }}

  memset(instructions, 0, sizeof(*instructions));
  if (ptc_copy_template_list(instructions) != 0) {{
    return 0;
  }}

  ptc_reset_status(virtual_address);
  ptc_icount = instructions->instruction_count;
  ptc_block_size = instructions->instruction_count;

  if (dymvirtual_address != NULL) {{
    *dymvirtual_address = virtual_address;
  }}

  return instructions->instruction_count;
}}

void ptc_instruction_list_destroy_for_smoke(PTCInstructionList *instructions)
{{
  ptc_instruction_list_free(instructions);
}}
'''

harness_source = f'''#include <dlfcn.h>
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

static int verify_translation(ptc_translate_ptr_t translate, uint64_t pc, const char *source, PTCInterface *ptc, size_t *out_size)
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

  ptc_instruction_list_free(&list);
  return 0;
}}

int main(int argc, char **argv)
{{
  const char *library_path = argc > 1 ? argv[1] : "{lib_so_path}";
  void *handle = NULL;
  ptc_load_ptr_t ptc_load = NULL;
  ptc_translate_ptr_t ptc_translate = NULL;
  ptc_get_abi_metadata_ptr_t get_metadata = NULL;
  PTCInterface ptc = {{ 0 }};
  const char *metadata = NULL;
  size_t translated_size = 0;
  size_t translated_iface_size = 0;

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

  if (ptc_load(handle, &ptc, "/tmp/qemu-v2-ptc-dynamic-scalar-translate-smoke-input", "") != 0) {{
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
      require_metadata_field(metadata, "stub_kind=scalar_model_backed") != 0 ||
      require_metadata_field(metadata, "real_translation=false") != 0 ||
      require_metadata_field(metadata, "vector_schema=false") != 0) {{
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

  if (verify_translation(ptc_translate, 0x401000u, "dlsym(ptc_translate)", &ptc, &translated_size) != 0) {{
    dlclose(handle);
    return 1;
  }}

  if (verify_translation(ptc.translate, 0x402000u, "PTCInterface.translate", &ptc, &translated_iface_size) != 0) {{
    dlclose(handle);
    return 1;
  }}

  printf("dynamic scalar smoke ok: library=%s instruction_count=%u argument_count=%u temp_count=%u emitted=%u rejected=%u vector_schema=%u ptc_translate_non_empty=1 translated_size=%zu iface_translated_size=%zu metadata=%s\\n",
         library_path,
         (unsigned) {instruction_count},
         (unsigned) {argument_count},
         (unsigned) {temp_count},
         (unsigned) {emitted},
         (unsigned) {rejected},
         (unsigned) {vector_schema},
         translated_size,
         translated_iface_size,
         metadata);

  dlclose(handle);
  return 0;
}}
'''

lib_c_path.write_text(lib_source)
harness_c_path.write_text(harness_source)
summary_path.write_text(json.dumps({
    "scratch_root": str(scratch_root),
    "model_json": str(model_path),
    "instruction_count": instruction_count,
    "argument_count": argument_count,
    "temp_count": temp_count,
    "emitted": emitted,
    "rejected": rejected,
    "vector_schema": vector_schema,
    "global_temps": global_temps,
    "total_temps": total_temps,
    "library_path": str(lib_so_path),
}, indent=2, sort_keys=True) + "\n")
PY

cc -std=c11 -O2 -g -fPIC -shared \
  -I"$LEGACY_QEMU_DIR/linux-user" \
  -I"$LEGACY_QEMU_DIR/tcg" \
  -Wno-unused-parameter \
  -o "$LIB_SO" \
  "$LIB_C"

cc -std=c11 -O2 -g \
  -I"$LEGACY_QEMU_DIR/linux-user" \
  -I"$LEGACY_QEMU_DIR/tcg" \
  -Wno-unused-parameter \
  -o "$HARNESS_BIN" \
  "$HARNESS_C" \
  -ldl

"$HARNESS_BIN" "$LIB_SO" | tee "$HARNESS_LOG"

python3 - "$HARNESS_LOG" "$SUMMARY_JSON" <<'PY'
import json
import sys
from pathlib import Path

log_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
summary = json.loads(summary_path.read_text())
text = log_path.read_text().strip()

if "dynamic scalar smoke ok:" not in text:
    raise SystemExit(f"missing success line in log: {log_path}")
if "ptc_translate_non_empty=1" not in text:
    raise SystemExit(f"missing non-empty translation marker in log: {log_path}")

print(json.dumps({
    "command": "bash runnable/scripts/qemu_v2_ptc_dynamic_scalar_translate_smoke.sh --fresh",
    "scratch_root": summary.get("scratch_root", str(log_path.parent)),
    "library_path": summary.get("library_path"),
    "instruction_count": summary.get("instruction_count"),
    "argument_count": summary.get("argument_count"),
    "temp_count": summary.get("temp_count"),
    "emitted": summary.get("emitted"),
    "rejected": summary.get("rejected"),
    "vector_schema": summary.get("vector_schema"),
    "ptc_translate_non_empty": True,
}, indent=2, sort_keys=True))
PY

log "Smoke complete"
printf 'scratch_root=%s\n' "$SCRATCH_ROOT"
printf 'library_path=%s\n' "$LIB_SO"
printf 'summary_json=%s\n' "$SUMMARY_JSON"
printf 'log=%s\n' "$HARNESS_LOG"
