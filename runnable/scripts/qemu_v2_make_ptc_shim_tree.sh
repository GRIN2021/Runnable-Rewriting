#!/usr/bin/env bash
#
# Create a throwaway QEMU V2 PTC/libtinycode shim source tree.
#
# The generated tree copies the legacy PTC ABI header plus enough companion
# headers and stub sources to build a load-smoke libtinycode-x86_64.so outside
# the repository.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

QEMU_SRC=""
OUT_DIR=""
FORCE=0

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_make_ptc_shim_tree.sh --qemu-src /path/to/qemu-10.2.3 --out-dir /tmp/qemu-v2-ptc-shim
  qemu_v2_make_ptc_shim_tree.sh /path/to/qemu-10.2.3 /tmp/qemu-v2-ptc-shim

Options:
  --qemu-src DIR    QEMU 10.2.3 source tree.
  --out-dir DIR     Output directory. Must be under /tmp.
  --force           Replace an existing output directory under /tmp.
  -h, --help        Show this help.

The generated tree is a standalone stub project that builds a load-smoke
libtinycode-x86_64.so under /tmp. It does not build QEMU itself and it does
not translate guest code yet.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

resolve_existing_dir() {
  local input="$1"
  local purpose="$2"
  [[ -n "$input" ]] || die "missing $purpose"
  [[ -d "$input" ]] || die "$purpose not found: $input"
  (cd "$input" && pwd -P)
}

resolve_output_path() {
  local input="$1"
  local raw parent base parent_abs
  [[ -n "$input" ]] || die "missing output directory"
  if [[ "$input" = /* ]]; then
    raw="$input"
  else
    raw="$PWD/$input"
  fi
  parent="$(dirname "$raw")"
  base="$(basename "$raw")"
  mkdir -p "$parent"
  parent_abs="$(cd "$parent" && pwd -P)"
  printf '%s/%s\n' "$parent_abs" "$base"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --qemu-src)
      QEMU_SRC="${2:?missing value for --qemu-src}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:?missing value for --out-dir}"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown argument: $1"
      ;;
    *)
      if [[ -z "$QEMU_SRC" ]]; then
        QEMU_SRC="$1"
      elif [[ -z "$OUT_DIR" ]]; then
        OUT_DIR="$1"
      else
        die "unexpected positional argument: $1"
      fi
      shift
      ;;
  esac
done

QEMU_SRC_ABS="$(resolve_existing_dir "$QEMU_SRC" "QEMU source tree")"
OUT_DIR_ABS="$(resolve_output_path "$OUT_DIR")"

[[ -f "$QEMU_SRC_ABS/meson.build" ]] || die "source tree does not look like modern QEMU; missing meson.build"
[[ -x "$QEMU_SRC_ABS/configure" ]] || die "QEMU configure script not found or not executable"
[[ -f "$QEMU_SRC_ABS/VERSION" ]] || die "QEMU VERSION file not found"

QEMU_VERSION="$(tr -d '[:space:]' < "$QEMU_SRC_ABS/VERSION")"
[[ "$QEMU_VERSION" == "10.2.3" ]] || die "expected QEMU VERSION 10.2.3, found: $QEMU_VERSION"

case "$OUT_DIR_ABS" in
  /tmp/*)
    ;;
  *)
    die "--out-dir must be under /tmp, got: $OUT_DIR_ABS"
    ;;
esac

if [[ -e "$OUT_DIR_ABS" ]]; then
  if [[ "$FORCE" -ne 1 ]]; then
    die "output directory already exists; pass --force to replace it: $OUT_DIR_ABS"
  fi
  rm -rf "$OUT_DIR_ABS"
fi

PTC_HEADER_SRC="$RR_DIR/qemu/linux-user/ptc.h"
TCG_OPC_SRC="$RR_DIR/qemu/tcg/tcg-opc.h"
[[ -f "$PTC_HEADER_SRC" ]] || die "legacy PTC header not found: $PTC_HEADER_SRC"
[[ -f "$TCG_OPC_SRC" ]] || die "legacy tcg-opc.h not found: $TCG_OPC_SRC"

mkdir -p \
  "$OUT_DIR_ABS/include" \
  "$OUT_DIR_ABS/src" \
  "$OUT_DIR_ABS/tests"

cp "$PTC_HEADER_SRC" "$OUT_DIR_ABS/include/ptc.h"
cp "$TCG_OPC_SRC" "$OUT_DIR_ABS/include/tcg-opc.h"

cat > "$OUT_DIR_ABS/README.md" <<EOF
# QEMU V2 Minimal PTC Shim Stub

Generated from:

- QEMU source: \`$QEMU_SRC_ABS\`
- QEMU version: \`$QEMU_VERSION\`
- Runnable-Rewriting source: \`$RR_DIR\`
- Copied legacy ABI header: \`qemu/linux-user/ptc.h\`
- Copied legacy opcode list: \`qemu/tcg/tcg-opc.h\`

This tree is a standalone load-smoke stub project. It does not build QEMU
itself and it does not translate guest code yet. Its purpose is narrower:

- build a \`libtinycode-x86_64.so\` shared object,
- export \`ptc_load\` and \`ptc_translate\`,
- export optional ABI metadata through \`ptc_abi_metadata\` and
  \`ptc_get_abi_metadata()\`,
- fill a \`PTCInterface\` with stable non-null pointers for smoke testing,
- keep translation as an explicit empty stub.

Project layout:

- \`include/ptc.h\`: copied legacy V1 PTC ABI header.
- \`include/tcg-opc.h\`: copied legacy opcode list used to fill \`opcode_defs\`.
- \`include/ptc_standalone_prefix.h\`: standalone compile-time TCG feature macros.
- \`include/ptc_standalone.h\`: wrapper that includes the copied ABI header safely.
- \`src/ptc_load_stub.c\`: \`ptc_load\`, optional ABI metadata symbols, safe
  stub state, and helper functions.
- \`src/ptc_translate_stub.c\`: \`ptc_translate\` returning an empty instruction list.
- \`src/dump_tinycode_stub.c\`: placeholder for the future modern TCG op walker.
- \`tests/ptc_load_smoke.c\`: \`dlopen\`/\`dlsym\`/\`ptc_load\` smoke harness.
- \`Makefile\`: builds the shared object and smoke harness under \`build/\`.
- \`meson.build.fragment.todo\`: notes for later QEMU-integrated wiring.

Build commands:

\`\`\`bash
cd $OUT_DIR_ABS
make
make smoke
\`\`\`

Outputs:

- \`build/libtinycode-x86_64.so\`
- \`build/ptc_load_smoke\`

Current stub contract:

- \`ptc_load\` succeeds and fills every \`PTCInterface\` function pointer.
- \`opcode_defs\` is a fully populated legacy-shaped table derived from the
  copied \`tcg-opc.h\`.
- \`helper_defs\` is non-null but \`helper_defs_size\` stays \`0\`.
- \`initialized_env\`, \`regs\`, \`pc\`, \`sp\`, and \`exception_index\` point
  into a small fake x86-64-like environment owned by the stub.
- \`ptc_translate\` returns size \`0\`, keeps \`dymvirtual_address\` equal to the
  requested virtual address, and returns an empty \`PTCInstructionList\`.
- \`ptc_abi_metadata\` and \`ptc_get_abi_metadata()\` are forward-compatible,
  optional loader-discovery hooks. They currently report
  \`abi_version=2\`, \`stub_kind=empty_stub\`,
  \`real_translation=false\`, and \`vector_schema=false\`.

Next implementation steps:

1. Replace the fake env layout with real modern \`CPUX86State\`/\`CPUState\`
   offsets from QEMU 10.2.3.
2. Replace the placeholder init path in \`ptc_load\` with real modern
   linux-user initialization and image mapping state.
3. Replace \`ptc_translate\` with a translate-only path around modern
   \`tb_gen_code\` or an in-tree wrapper and emit a non-empty
   \`PTCInstructionList\`.
4. Replace \`dump_tinycode_stub.c\` with a \`TCGContext->ops\` walker plus a V1
   opcode compatibility map.
EOF

cat > "$OUT_DIR_ABS/source-manifest.txt" <<EOF
qemu_src=$QEMU_SRC_ABS
qemu_version=$QEMU_VERSION
runnable_rewriting=$RR_DIR
copied_ptc_header=$PTC_HEADER_SRC
copied_tcg_opc=$TCG_OPC_SRC
build_claim=stub-shared-object
optional_abi_metadata=ptc_abi_metadata,ptc_get_abi_metadata
EOF

cat > "$OUT_DIR_ABS/Makefile" <<'EOF'
CC ?= cc
CPPFLAGS += -Iinclude -Isrc
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -Wall -Wextra -Wno-unused-parameter -fPIC
LDFLAGS ?=
LDLIBS ?=

BUILD_DIR := build
LIB_NAME := libtinycode-x86_64.so
SHARED_LIB := $(BUILD_DIR)/$(LIB_NAME)
SMOKE_BIN := $(BUILD_DIR)/ptc_load_smoke
SRCS := \
	src/ptc_load_stub.c \
	src/ptc_translate_stub.c \
	src/dump_tinycode_stub.c
OBJS := $(patsubst src/%.c,$(BUILD_DIR)/%.o,$(SRCS))

.PHONY: all smoke clean

all: $(SHARED_LIB)

smoke: $(SHARED_LIB) $(SMOKE_BIN)
	$(SMOKE_BIN) $(SHARED_LIB)

clean:
	rm -rf $(BUILD_DIR)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/%.o: src/%.c | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(SHARED_LIB): $(OBJS) | $(BUILD_DIR)
	$(CC) -shared -Wl,-soname,$(LIB_NAME) $(LDFLAGS) -o $@ $(OBJS) $(LDLIBS)

$(SMOKE_BIN): tests/ptc_load_smoke.c | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ $< -ldl
EOF

cat > "$OUT_DIR_ABS/include/ptc_standalone_prefix.h" <<'EOF'
#ifndef RUNNABLE_QEMU_V2_PTC_STANDALONE_PREFIX_H
#define RUNNABLE_QEMU_V2_PTC_STANDALONE_PREFIX_H

#include <stdio.h>

#define TCG_TARGET_REG_BITS 64
#define TARGET_LONG_BITS 64

#define TCG_OPF_NOT_PRESENT  (1u << 0)
#define TCG_OPF_CALL_CLOBBER (1u << 1)
#define TCG_OPF_64BIT        (1u << 2)
#define TCG_OPF_BB_END       (1u << 3)
#define TCG_OPF_SIDE_EFFECTS (1u << 4)

#define TCG_TARGET_HAS_add2_i32 0
#define TCG_TARGET_HAS_add2_i64 0
#define TCG_TARGET_HAS_andc_i32 0
#define TCG_TARGET_HAS_andc_i64 0
#define TCG_TARGET_HAS_bswap16_i32 0
#define TCG_TARGET_HAS_bswap16_i64 0
#define TCG_TARGET_HAS_bswap32_i32 0
#define TCG_TARGET_HAS_bswap32_i64 0
#define TCG_TARGET_HAS_bswap64_i64 0
#define TCG_TARGET_HAS_deposit_i32 0
#define TCG_TARGET_HAS_deposit_i64 0
#define TCG_TARGET_HAS_div2_i32 0
#define TCG_TARGET_HAS_div2_i64 0
#define TCG_TARGET_HAS_div_i32 0
#define TCG_TARGET_HAS_div_i64 0
#define TCG_TARGET_HAS_eqv_i32 0
#define TCG_TARGET_HAS_eqv_i64 0
#define TCG_TARGET_HAS_ext16s_i32 0
#define TCG_TARGET_HAS_ext16s_i64 0
#define TCG_TARGET_HAS_ext16u_i32 0
#define TCG_TARGET_HAS_ext16u_i64 0
#define TCG_TARGET_HAS_ext32s_i64 0
#define TCG_TARGET_HAS_ext32u_i64 0
#define TCG_TARGET_HAS_ext8s_i32 0
#define TCG_TARGET_HAS_ext8s_i64 0
#define TCG_TARGET_HAS_ext8u_i32 0
#define TCG_TARGET_HAS_ext8u_i64 0
#define TCG_TARGET_HAS_movcond_i32 0
#define TCG_TARGET_HAS_movcond_i64 0
#define TCG_TARGET_HAS_muls2_i32 0
#define TCG_TARGET_HAS_muls2_i64 0
#define TCG_TARGET_HAS_mulsh_i32 0
#define TCG_TARGET_HAS_mulsh_i64 0
#define TCG_TARGET_HAS_mulu2_i32 0
#define TCG_TARGET_HAS_mulu2_i64 0
#define TCG_TARGET_HAS_muluh_i32 0
#define TCG_TARGET_HAS_muluh_i64 0
#define TCG_TARGET_HAS_nand_i32 0
#define TCG_TARGET_HAS_nand_i64 0
#define TCG_TARGET_HAS_neg_i32 0
#define TCG_TARGET_HAS_neg_i64 0
#define TCG_TARGET_HAS_nor_i32 0
#define TCG_TARGET_HAS_nor_i64 0
#define TCG_TARGET_HAS_not_i32 0
#define TCG_TARGET_HAS_not_i64 0
#define TCG_TARGET_HAS_orc_i32 0
#define TCG_TARGET_HAS_orc_i64 0
#define TCG_TARGET_HAS_rem_i32 0
#define TCG_TARGET_HAS_rem_i64 0
#define TCG_TARGET_HAS_rot_i32 0
#define TCG_TARGET_HAS_rot_i64 0
#define TCG_TARGET_HAS_sub2_i32 0
#define TCG_TARGET_HAS_sub2_i64 0
#define TCG_TARGET_HAS_trunc_shr_i32 0

#endif /* RUNNABLE_QEMU_V2_PTC_STANDALONE_PREFIX_H */
EOF

cat > "$OUT_DIR_ABS/include/ptc_standalone.h" <<'EOF'
#ifndef RUNNABLE_QEMU_V2_PTC_STANDALONE_H
#define RUNNABLE_QEMU_V2_PTC_STANDALONE_H

#include "ptc_standalone_prefix.h"
#include "ptc.h"

#endif /* RUNNABLE_QEMU_V2_PTC_STANDALONE_H */
EOF

cat > "$OUT_DIR_ABS/src/ptc_shim_internal.h" <<'EOF'
#ifndef RUNNABLE_QEMU_V2_PTC_SHIM_INTERNAL_H
#define RUNNABLE_QEMU_V2_PTC_SHIM_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

#include "ptc_standalone.h"

enum {
  PTC_V2_GPR_COUNT = 16,
  PTC_V2_R_ESP = 4,
  PTC_V2_R_EBP = 5,
  PTC_V2_STACK_SIZE = 4096,
};

typedef struct {
  uint64_t regs[PTC_V2_GPR_COUNT];
  uint64_t pc;
  int32_t exception_index;
  uint32_t reserved0;
  uint64_t reserved[32];
} PTCShimEnv;

PTCInstructionList ptc_v2_dump_tinycode(void *tcg_context);
void ptc_v2_warn_unimplemented_once(const char *api_name);
void ptc_v2_reset_status(uint64_t virtual_address);

extern PTCShimEnv ptc_v2_env;
extern uint8_t ptc_v2_stack[PTC_V2_STACK_SIZE];

extern int32_t ptc_v2_exception_syscall;
extern uint64_t ptc_v2_syscall_next_eip;
extern uint64_t ptc_v2_is_indirect;
extern uint64_t ptc_v2_is_call;
extern uint64_t ptc_v2_is_directcall;
extern uint64_t ptc_v2_call_next;
extern uint64_t ptc_v2_is_indirect_jmp;
extern uint64_t ptc_v2_is_direct_jmp;
extern uint64_t ptc_v2_is_ret;
extern uint64_t ptc_v2_elf_start_stack;
extern uint64_t ptc_v2_illegal_access_addr;
extern uint64_t ptc_v2_cfi_addr;
extern uint64_t ptc_v2_is_syscall;
extern uint64_t ptc_v2_block_size;
extern uint64_t ptc_v2_icount;
extern uint64_t ptc_v2_is_illegal;
extern uint64_t ptc_v2_is_add;

#endif /* RUNNABLE_QEMU_V2_PTC_SHIM_INTERNAL_H */
EOF

cat > "$OUT_DIR_ABS/src/ptc_load_stub.c" <<'EOF'
#include "ptc_shim_internal.h"

#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

PTCOpcodeDef *ptc_opcode_defs;
PTCHelperDef *ptc_helper_defs;
unsigned ptc_helper_defs_size;

const char ptc_abi_metadata[] =
  "abi_version=2\n"
  "stub_kind=empty_stub\n"
  "real_translation=false\n"
  "vector_schema=false\n";

const char *ptc_get_abi_metadata(void)
{
  return ptc_abi_metadata;
}

PTCShimEnv ptc_v2_env;
uint8_t ptc_v2_stack[PTC_V2_STACK_SIZE];

int32_t ptc_v2_exception_syscall = -1;
uint64_t ptc_v2_syscall_next_eip;
uint64_t ptc_v2_is_indirect;
uint64_t ptc_v2_is_call;
uint64_t ptc_v2_is_directcall;
uint64_t ptc_v2_call_next;
uint64_t ptc_v2_is_indirect_jmp;
uint64_t ptc_v2_is_direct_jmp;
uint64_t ptc_v2_is_ret;
uint64_t ptc_v2_elf_start_stack;
uint64_t ptc_v2_illegal_access_addr;
uint64_t ptc_v2_cfi_addr;
uint64_t ptc_v2_is_syscall;
uint64_t ptc_v2_block_size;
uint64_t ptc_v2_icount;
uint64_t ptc_v2_is_illegal;
uint64_t ptc_v2_is_add;

static uint64_t ptc_v2_image_base;
static size_t ptc_v2_image_size;
static unsigned ptc_v2_warned_apis;

static PTCOpcodeDef ptc_v2_opcode_defs_storage[PTC_INSTRUCTION_NB_OPS] = {
#define DEF(op_name, oargs, iargs, cargs, flags)                           \
  [PTC_INSTRUCTION_op_ ## op_name] = {                                     \
    .name = #op_name,                                                      \
    .nb_oargs = (uint8_t) (oargs),                                         \
    .nb_iargs = (uint8_t) (iargs),                                         \
    .nb_cargs = (uint8_t) (cargs),                                         \
    .nb_args = (uint8_t) ((oargs) + (iargs) + (cargs)),                    \
  },
#include "tcg-opc.h"
#undef DEF
};

static PTCHelperDef ptc_v2_helper_defs_storage[1] = {
  { NULL, "ptc_v2_helper_table_empty", 0u },
};

static unsigned ptc_v2_warning_bit(const char *api_name)
{
  if (strcmp(api_name, "ptc_init") == 0) {
    return 1u << 0;
  }
  if (strcmp(api_name, "ptc_translate") == 0) {
    return 1u << 1;
  }
  if (strcmp(api_name, "ptc_exec") == 0) {
    return 1u << 2;
  }
  if (strcmp(api_name, "ptc_exec1") == 0) {
    return 1u << 3;
  }
  if (strcmp(api_name, "ptc_exec2") == 0) {
    return 1u << 4;
  }
  if (strcmp(api_name, "ptc_run_library") == 0) {
    return 1u << 5;
  }
  if (strcmp(api_name, "ptc_do_syscall2") == 0) {
    return 1u << 6;
  }
  return 0;
}

static void ptc_v2_init_env_once(void)
{
  static int initialized;
  uint64_t stack_top;

  if (initialized) {
    return;
  }

  memset(&ptc_v2_env, 0, sizeof(ptc_v2_env));
  memset(ptc_v2_stack, 0, sizeof(ptc_v2_stack));

  stack_top = (uint64_t) (uintptr_t) (ptc_v2_stack + sizeof(ptc_v2_stack));
  ptc_v2_elf_start_stack = stack_top;
  ptc_v2_env.regs[PTC_V2_R_ESP] = stack_top - 16u;
  ptc_v2_env.regs[PTC_V2_R_EBP] = ptc_v2_env.regs[PTC_V2_R_ESP];

  initialized = 1;
}

static void ptc_v2_init_metadata(void)
{
  if (ptc_opcode_defs == NULL) {
    ptc_opcode_defs = ptc_v2_opcode_defs_storage;
  }

  if (ptc_helper_defs == NULL) {
    ptc_helper_defs = ptc_v2_helper_defs_storage;
    ptc_helper_defs_size = 0;
  }
}

static uint32_t ptc_v2_addr_in_range(uint64_t va, const void *base, size_t size)
{
  uintptr_t addr = (uintptr_t) va;
  uintptr_t start = (uintptr_t) base;
  uintptr_t end = start + size;
  return size != 0 && addr >= start && addr < end;
}

void ptc_v2_warn_unimplemented_once(const char *api_name)
{
  unsigned bit = ptc_v2_warning_bit(api_name);

  if (bit != 0 && (ptc_v2_warned_apis & bit) != 0) {
    return;
  }
  if (bit != 0) {
    ptc_v2_warned_apis |= bit;
  }

  fprintf(stderr,
          "qemu-v2 PTC shim stub: %s is not wired to modern QEMU APIs yet\n",
          api_name);
}

void ptc_v2_reset_status(uint64_t virtual_address)
{
  ptc_v2_env.pc = virtual_address;
  ptc_v2_env.exception_index = 0;

  ptc_v2_exception_syscall = -1;
  ptc_v2_syscall_next_eip = virtual_address;
  ptc_v2_is_indirect = 0;
  ptc_v2_is_call = 0;
  ptc_v2_is_directcall = 0;
  ptc_v2_call_next = 0;
  ptc_v2_is_indirect_jmp = 0;
  ptc_v2_is_direct_jmp = 0;
  ptc_v2_is_ret = 0;
  ptc_v2_illegal_access_addr = 0;
  ptc_v2_cfi_addr = 0;
  ptc_v2_is_syscall = 0;
  ptc_v2_block_size = 0;
  ptc_v2_icount = 0;
  ptc_v2_is_illegal = 0;
  ptc_v2_is_add = 0;
}

void ptc_init(const char *filename, const char *exe_args)
{
  (void) filename;
  (void) exe_args;

  ptc_v2_init_env_once();
  ptc_v2_reset_status(0);
  ptc_v2_warn_unimplemented_once("ptc_init");
}

void ptc_disassemble(FILE *output, uint32_t buffer, size_t buffer_size, int max)
{
  (void) buffer;
  (void) buffer_size;
  (void) max;
  if (output != NULL) {
    fputs("qemu-v2 PTC disassemble stub\n", output);
  }
}

int ptc_disassemble_bytes(FILE *output, const uint8_t *buffer,
                          size_t buffer_size, int flags)
{
  (void) output;
  (void) buffer;
  (void) buffer_size;
  (void) flags;
  return -ENOSYS;
}

const char *ptc_get_condition_name(PTCCondition condition)
{
  switch (condition) {
  case PTC_COND_NEVER: return "never";
  case PTC_COND_ALWAYS: return "always";
  case PTC_COND_EQ: return "eq";
  case PTC_COND_NE: return "ne";
  case PTC_COND_LT: return "lt";
  case PTC_COND_GE: return "ge";
  case PTC_COND_LE: return "le";
  case PTC_COND_GT: return "gt";
  case PTC_COND_LTU: return "ltu";
  case PTC_COND_GEU: return "geu";
  case PTC_COND_LEU: return "leu";
  case PTC_COND_GTU: return "gtu";
  }
  return "unknown";
}

const char *ptc_get_load_store_name(PTCLoadStoreType type)
{
  switch (type) {
  case PTC_MO_8: return "8";
  case PTC_MO_16: return "16";
  case PTC_MO_32: return "32";
  case PTC_MO_64: return "64";
  default: return "unknown";
  }
}

PTCLoadStoreArg ptc_parse_load_store_arg(PTCInstructionArg arg)
{
  PTCLoadStoreArg result = { 0 };

  /*
   * TODO(qemu-v2): Decode modern MemOpIdx/TCGMemOpIdx. This placeholder keeps
   * the ABI symbol present and preserves the legacy size bits.
   */
  result.access_type = PTC_MEMORY_ACCESS_UNKNOWN;
  result.type = (PTCLoadStoreType) (arg & PTC_MO_SSIZE);
  result.raw_op = (unsigned) arg;
  result.mmu_index = 0;
  return result;
}

unsigned ptc_get_arg_label_id(PTCInstructionArg arg)
{
  return (unsigned) arg;
}

void ptc_mmap(uint64_t virtual_address, size_t code_size)
{
  ptc_v2_image_base = virtual_address;
  ptc_v2_image_size = code_size;
}

void ptc_unmmap(uint64_t virtual_address, size_t code_size)
{
  if (ptc_v2_image_base == virtual_address && ptc_v2_image_size == code_size) {
    ptc_v2_image_base = 0;
    ptc_v2_image_size = 0;
  }
}

void ptc_cleanLowAddr(uint64_t virtual_address, size_t code_size)
{
  (void) virtual_address;
  (void) code_size;
}

int64_t ptc_exec(uint64_t va)
{
  (void) va;
  ptc_v2_warn_unimplemented_once("ptc_exec");
  return -ENOSYS;
}

int64_t ptc_exec1(uint64_t begin, uint64_t end)
{
  (void) begin;
  (void) end;
  ptc_v2_warn_unimplemented_once("ptc_exec1");
  return -ENOSYS;
}

size_t ptc_exec2(uint64_t begin, uint64_t end)
{
  (void) begin;
  (void) end;
  ptc_v2_warn_unimplemented_once("ptc_exec2");
  return 0;
}

int64_t ptc_isdecodeblock(uint64_t va)
{
  (void) va;
  return 0;
}

size_t ptc_getBadBlockSize(uint64_t va, int *stop)
{
  (void) va;
  if (stop != NULL) {
    *stop = 1;
  }
  return 0;
}

uint64_t ptc_run_library(size_t flag)
{
  (void) flag;
  ptc_v2_warn_unimplemented_once("ptc_run_library");
  return 0;
}

void ptc_data_start(uint64_t start, uint64_t entry)
{
  ptc_v2_image_base = start;
  ptc_v2_image_size = entry > start ? (size_t) (entry - start) : ptc_v2_image_size;
}

unsigned long ptc_do_syscall2(void)
{
  ptc_v2_warn_unimplemented_once("ptc_do_syscall2");
  return 0;
}

uint32_t ptc_storeCPUState(void) { return 0; }
uint32_t ptc_dropCPUState(void) { return 0; }
uint32_t ptc_queueDepth(void) { return 0; }
void ptc_getBranchCPUeip(void) {}
uint32_t ptc_deletCPULINEState(void) { return 0; }
void ptc_recoverStack(void) {}

void ptc_recoverOnlyStack(void *storedStack, bool needFree)
{
  (void) storedStack;
  (void) needFree;
}

void *ptc_storeOnlyStack(void) { return NULL; }
void ptc_storeStack(void) {}

uint32_t ptc_is_stack_addr(uint64_t va)
{
  return ptc_v2_addr_in_range(va, ptc_v2_stack, sizeof(ptc_v2_stack));
}

uint32_t ptc_is_image_addr(uint64_t va)
{
  if (ptc_v2_image_size == 0) {
    return 0;
  }
  return va >= ptc_v2_image_base && va < ptc_v2_image_base + ptc_v2_image_size;
}

uint32_t ptc_isValidExecuteAddr(uint64_t va)
{
  return ptc_is_image_addr(va);
}

void ptc_lockexec(void) {}
void ptc_unlockexec(void) {}

int ptc_load(void *handle, PTCInterface *output, const char *ptc_filename,
             const char *exe_args)
{
  PTCInterface result = { 0 };

  (void) handle;
  if (output == NULL) {
    return -EINVAL;
  }

  ptc_v2_init_env_once();
  ptc_v2_init_metadata();
  ptc_v2_reset_status(0);
  ptc_init(ptc_filename, exe_args);

  result.get_condition_name = &ptc_get_condition_name;
  result.get_load_store_name = &ptc_get_load_store_name;
  result.parse_load_store_arg = &ptc_parse_load_store_arg;
  result.get_arg_label_id = &ptc_get_arg_label_id;
  result.mmap = &ptc_mmap;
  result.unmmap = &ptc_unmmap;
  result.cleanLowAddr = &ptc_cleanLowAddr;
  result.translate = &ptc_translate;
  result.exec = &ptc_exec;
  result.exec1 = &ptc_exec1;
  result.exec2 = &ptc_exec2;
  result.isdecodeblock = &ptc_isdecodeblock;
  result.getBadBlockSize = &ptc_getBadBlockSize;
  result.run_library = &ptc_run_library;
  result.data_start = &ptc_data_start;
  result.disassemble = &ptc_disassemble;
  result.do_syscall2 = &ptc_do_syscall2;
  result.storeCPUState = &ptc_storeCPUState;
  result.dropCPUState = &ptc_dropCPUState;
  result.queueDepth = &ptc_queueDepth;
  result.getBranchCPUeip = &ptc_getBranchCPUeip;
  result.deletCPULINEState = &ptc_deletCPULINEState;
  result.recoverStack = &ptc_recoverStack;
  result.recoverOnlyStack = &ptc_recoverOnlyStack;
  result.storeStack = &ptc_storeStack;
  result.storeOnlyStack = &ptc_storeOnlyStack;
  result.is_stack_addr = &ptc_is_stack_addr;
  result.is_image_addr = &ptc_is_image_addr;
  result.isValidExecuteAddr = &ptc_isValidExecuteAddr;

  result.opcode_defs = ptc_opcode_defs;
  result.helper_defs = ptc_helper_defs;
  result.helper_defs_size = ptc_helper_defs_size;

  result.pc = (intptr_t) offsetof(PTCShimEnv, pc);
  result.sp = (intptr_t) offsetof(PTCShimEnv, regs[PTC_V2_R_ESP]);
  result.exception_index = (intptr_t) offsetof(PTCShimEnv, exception_index);
  result.initialized_env = (uint8_t *) &ptc_v2_env;
  result.regs = ptc_v2_env.regs;

  result.exception_syscall = &ptc_v2_exception_syscall;
  result.syscall_next_eip = &ptc_v2_syscall_next_eip;
  result.isIndirect = &ptc_v2_is_indirect;
  result.isCall = &ptc_v2_is_call;
  result.isDirectcall = &ptc_v2_is_directcall;
  result.CallNext = &ptc_v2_call_next;
  result.isIndirectJmp = &ptc_v2_is_indirect_jmp;
  result.isDirectJmp = &ptc_v2_is_direct_jmp;
  result.isRet = &ptc_v2_is_ret;
  result.ElfStartStack = &ptc_v2_elf_start_stack;
  result.illegalAccessAddr = &ptc_v2_illegal_access_addr;
  result.CFIAddr = &ptc_v2_cfi_addr;
  result.isSyscall = &ptc_v2_is_syscall;
  result.BlockSize = &ptc_v2_block_size;
  result.iCount = &ptc_v2_icount;
  result.isIllegal = &ptc_v2_is_illegal;
  result.isAdd = &ptc_v2_is_add;

  *output = result;
  return 0;
}
EOF

cat > "$OUT_DIR_ABS/src/ptc_translate_stub.c" <<'EOF'
#include "ptc_shim_internal.h"

#include <string.h>

size_t ptc_translate(uint64_t virtual_address, uint32_t force,
                     PTCInstructionList *instructions,
                     uint64_t *dymvirtual_address)
{
  (void) force;

  /*
   * TODO(qemu-v2): Translate-only implementation should:
   *   1. Set modern CPUX86State.eip/rip to virtual_address.
   *   2. Obtain TCGTBCPUState through CPUClass tcg_ops.
   *   3. Call modern tb_gen_code or an in-tree wrapper.
   *   4. Dump TCG ops before execution.
   *   5. Return TranslationBlock size and next-PC metadata.
   */
  ptc_v2_warn_unimplemented_once("ptc_translate");
  ptc_v2_reset_status(virtual_address);

  if (instructions != NULL) {
    memset(instructions, 0, sizeof(*instructions));
  }

  if (dymvirtual_address != NULL) {
    *dymvirtual_address = virtual_address;
  }

  return 0;
}
EOF

cat > "$OUT_DIR_ABS/src/dump_tinycode_stub.c" <<'EOF'
#include "ptc_shim_internal.h"

PTCInstructionList ptc_v2_dump_tinycode(void *tcg_context)
{
  PTCInstructionList result = { 0 };

  (void) tcg_context;

  /*
   * TODO(qemu-v2): Replace with a modern TCGContext op walker:
   *
   *   QTAILQ_FOREACH(op, &tcg_ctx->ops, link) { ... }
   *
   * Required compatibility decisions:
   *   - Map modern insn_start to V1 debug_insn_start.
   *   - Rebuild call metadata from modern tcg_call_info/tcg_call_func.
   *   - Copy modern TCGTemp fields into PTCTemp without assuming V1 layout.
   *   - Build a V1 opcode map for scalar ops and explicit diagnostics for
   *     modern vector ops.
   */

  return result;
}
EOF

cat > "$OUT_DIR_ABS/tests/ptc_load_smoke.c" <<'EOF'
#include <dlfcn.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define USE_DYNAMIC_PTC 1
#include "ptc_standalone.h"

typedef const char *(*ptc_get_abi_metadata_ptr_t)(void);

static int require_non_null(const void *pointer, const char *label)
{
  if (pointer != NULL) {
    return 0;
  }

  fprintf(stderr, "missing required pointer: %s\n", label);
  return 1;
}

static int require_metadata_field(const char *metadata, const char *field)
{
  if (metadata != NULL && strstr(metadata, field) != NULL) {
    return 0;
  }

  fprintf(stderr, "metadata missing required field: %s\n", field);
  return 1;
}

static int verify_optional_metadata(void *library_handle)
{
  const char *metadata_symbol = NULL;
  const char *metadata_from_getter = NULL;
  const char *error = NULL;
  ptc_get_abi_metadata_ptr_t get_metadata = NULL;

  dlerror();
  metadata_symbol = (const char *) dlsym(library_handle, "ptc_abi_metadata");
  error = dlerror();
  if (error != NULL || metadata_symbol == NULL) {
    fprintf(stderr, "dlsym(ptc_abi_metadata) failed: %s\n",
            error != NULL ? error : "symbol resolved to NULL");
    return 1;
  }

  if (require_metadata_field(metadata_symbol, "abi_version=2") != 0 ||
      require_metadata_field(metadata_symbol, "stub_kind=empty_stub") != 0 ||
      require_metadata_field(metadata_symbol, "real_translation=false") != 0 ||
      require_metadata_field(metadata_symbol, "vector_schema=false") != 0) {
    return 1;
  }

  dlerror();
  get_metadata = (ptc_get_abi_metadata_ptr_t)
      dlsym(library_handle, "ptc_get_abi_metadata");
  error = dlerror();
  if (error != NULL || get_metadata == NULL) {
    fprintf(stderr, "dlsym(ptc_get_abi_metadata) failed: %s\n",
            error != NULL ? error : "symbol resolved to NULL");
    return 1;
  }

  metadata_from_getter = get_metadata();
  if (metadata_from_getter == NULL) {
    fputs("ptc_get_abi_metadata returned NULL\n", stderr);
    return 1;
  }

  if (strcmp(metadata_symbol, metadata_from_getter) != 0) {
    fputs("metadata symbol and getter returned different content\n", stderr);
    return 1;
  }

  return 0;
}

static int verify_interface(PTCInterface *ptc)
{
  PTCInstructionList instructions = { 0 };
  uint64_t next_pc = 0;
  size_t translated_size = 0;

  if (require_non_null(ptc->translate, "translate") != 0 ||
      require_non_null(ptc->get_condition_name, "get_condition_name") != 0 ||
      require_non_null(ptc->get_load_store_name, "get_load_store_name") != 0 ||
      require_non_null(ptc->opcode_defs, "opcode_defs") != 0 ||
      require_non_null(ptc->helper_defs, "helper_defs") != 0 ||
      require_non_null(ptc->initialized_env, "initialized_env") != 0 ||
      require_non_null(ptc->regs, "regs") != 0 ||
      require_non_null(ptc->isIndirect, "isIndirect") != 0 ||
      require_non_null(ptc->BlockSize, "BlockSize") != 0 ||
      require_non_null(ptc->iCount, "iCount") != 0 ||
      require_non_null(ptc->ElfStartStack, "ElfStartStack") != 0) {
    return 1;
  }

  if (strcmp(ptc->get_condition_name(PTC_COND_EQ), "eq") != 0) {
    fprintf(stderr, "unexpected condition name for PTC_COND_EQ\n");
    return 1;
  }

  if (strcmp(ptc->get_load_store_name(PTC_MO_32), "32") != 0) {
    fprintf(stderr, "unexpected load/store name for PTC_MO_32\n");
    return 1;
  }

  if (ptc->opcode_defs[PTC_INSTRUCTION_op_call].name == NULL) {
    fprintf(stderr, "opcode_defs[call].name is null\n");
    return 1;
  }

  translated_size = ptc->translate(0x401000u, 1u, &instructions, &next_pc);
  if (translated_size != 0) {
    fprintf(stderr, "expected ptc_translate stub to return 0, got %zu\n",
            translated_size);
    return 1;
  }

  if (next_pc != 0x401000u) {
    fprintf(stderr, "expected next pc to stay at input, got 0x%" PRIx64 "\n",
            next_pc);
    return 1;
  }

  if (instructions.instruction_count != 0 ||
      instructions.instructions != NULL ||
      instructions.arguments != NULL ||
      instructions.temps != NULL) {
    fprintf(stderr, "expected empty instruction list from ptc_translate stub\n");
    return 1;
  }

  ptc_instruction_list_free(&instructions);
  return 0;
}

int main(int argc, char **argv)
{
  const char *library_path = argc > 1 ? argv[1] : "build/libtinycode-x86_64.so";
  void *library_handle = NULL;
  ptc_load_ptr_t ptc_load = NULL;
  PTCInterface ptc = { 0 };

  library_handle = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
  if (library_handle == NULL) {
    fprintf(stderr, "dlopen failed for %s: %s\n", library_path, dlerror());
    return 1;
  }

  ptc_load = (ptc_load_ptr_t) dlsym(library_handle, "ptc_load");
  if (ptc_load == NULL) {
    fprintf(stderr, "dlsym(ptc_load) failed: %s\n", dlerror());
    dlclose(library_handle);
    return 1;
  }

  if (ptc_load(library_handle, &ptc, "/tmp/ptc-load-smoke-input", "") != 0) {
    fprintf(stderr, "ptc_load returned failure\n");
    dlclose(library_handle);
    return 1;
  }

  if (verify_interface(&ptc) != 0) {
    dlclose(library_handle);
    return 1;
  }

  if (verify_optional_metadata(library_handle) != 0) {
    dlclose(library_handle);
    return 1;
  }

  printf("smoke ok: pc=%" PRIdPTR " sp=%" PRIdPTR
         " exception_index=%" PRIdPTR
         " helper_defs_size=%u stack_top=0x%" PRIx64 "\n",
         ptc.pc,
         ptc.sp,
         ptc.exception_index,
         ptc.helper_defs_size,
         *ptc.ElfStartStack);

  dlclose(library_handle);
  return 0;
}
EOF

cat > "$OUT_DIR_ABS/meson.build.fragment.todo" <<'EOF'
# TODO(qemu-v2): This is a note, not Meson syntax ready for inclusion.
#
# Once the stub is replaced with real QEMU-integrated code, add the PTC shim
# sources to the x86_64 linux-user build that produces libtinycode-x86_64.so.
# Keep this separate from the vanilla qemu-x86_64 target.
#
# Candidate replacement source set:
#   linux-user/ptc-v2.c
#   linux-user/ptc.h
#   any target/i386/tcg hook needed to preserve branch metadata
EOF

cat <<EOF
Created QEMU V2 PTC shim stub project:
  $OUT_DIR_ABS

Build it with:
  cd $OUT_DIR_ABS
  make
  make smoke

Start at:
  $OUT_DIR_ABS/README.md
EOF
