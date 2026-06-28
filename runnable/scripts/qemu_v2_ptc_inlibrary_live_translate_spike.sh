#!/usr/bin/env bash
#
# Bounded spike for the stronger QEMU v2 PTC bridge: try to move live QEMU
# translation into the dynamic libtinycode ptc_translate path. All generated
# source, object, link, and smoke artifacts stay under /tmp by default.
#
# The expected bounded result today is a precise linker/initialization blocker:
# QEMU's linux-user translate path is not packaged as a reusable shared library,
# and the objects that contain translator_loop/target translate code pull in
# the full linux-user runtime, page/mmap state, TCG globals, and CPU init graph.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
LEGACY_QEMU_DIR="${RUNNABLE_QEMU_LEGACY_SRC:-$RR_DIR/archive/qemu-legacy-2.4.50}"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_PTC_INLIBRARY_ROOT:-/tmp/rr-qemu-v2-upstream-probes/ptc-inlibrary-live-translate-spike}"
QEMU_BUILD="${RUNNABLE_QEMU_V2_UPSTREAM_BUILD:-/tmp/rr-qemu-v2-upstream-probes/build-10.2.3}"
QEMU_SRC="${RUNNABLE_QEMU_V2_UPSTREAM_SRC:-/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3}"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-3}"
FRESH=0
SKIP_FALLBACK=0

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_ptc_inlibrary_live_translate_spike.sh [options]

Options:
  --scratch-root DIR  Output/build scratch root.
                      Default: /tmp/rr-qemu-v2-upstream-probes/ptc-inlibrary-live-translate-spike
  --qemu-build DIR    Existing QEMU 10.2.3 linux-user build directory.
                      Default: /tmp/rr-qemu-v2-upstream-probes/build-10.2.3
  --qemu-src DIR      Existing unpatched QEMU 10.2.3 source tree for fallback smoke.
                      Default: /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3
  --jobs N, -j N      Parallelism passed to fallback smoke. Default: 3 or RUNNABLE_QEMU_V2_JOBS.
  --fresh             Remove this spike's scratch root before running.
  --skip-fallback     Do not run the known live/model bridge fallback comparison.
  -h, --help          Show this help.

Outputs:
  $SCRATCH_ROOT/qemu_v2_ptc_inlibrary_live_translate_candidate.c
  $SCRATCH_ROOT/qemu_v2_ptc_inlibrary_live_translate_candidate.o
  $SCRATCH_ROOT/libtinycode-x86_64.so, if the strong link unexpectedly succeeds
  $SCRATCH_ROOT/link.log
  $SCRATCH_ROOT/bridge-fallback/, unless --skip-fallback is used
  $SCRATCH_ROOT/qemu_v2_ptc_inlibrary_live_translate_spike.summary.json
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
    --qemu-build)
      QEMU_BUILD="$(abs_path "${2:?missing value for --qemu-build}")"
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
    --skip-fallback)
      SKIP_FALLBACK=1
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
QEMU_BUILD="$(abs_path "$QEMU_BUILD")"
QEMU_SRC="$(abs_path "$QEMU_SRC")"

PTC_HEADER="$LEGACY_QEMU_DIR/linux-user/ptc.h"
CANDIDATE_C="$SCRATCH_ROOT/qemu_v2_ptc_inlibrary_live_translate_candidate.c"
CANDIDATE_O="$SCRATCH_ROOT/qemu_v2_ptc_inlibrary_live_translate_candidate.o"
COMPILE_LOG="$SCRATCH_ROOT/compile.log"
LINK_LOG="$SCRATCH_ROOT/link.log"
SUMMARY_JSON="$SCRATCH_ROOT/qemu_v2_ptc_inlibrary_live_translate_spike.summary.json"
LIB_SO="$SCRATCH_ROOT/libtinycode-x86_64.so"
FALLBACK_ROOT="$SCRATCH_ROOT/bridge-fallback"
FALLBACK_SUMMARY="$FALLBACK_ROOT/qemu_v2_ptc_live_translate_bridge_smoke.summary.json"

QEMU_OBJECTS=(
  "$QEMU_BUILD/libuser.a.p/accel_tcg_translator.c.o"
  "$QEMU_BUILD/libuser.a.p/accel_tcg_translate-all.c.o"
  "$QEMU_BUILD/libqemu-x86_64-linux-user.a.p/target_i386_tcg_translate.c.o"
  "$QEMU_BUILD/libuser.a.p/tcg_tcg.c.o"
  "$QEMU_BUILD/libuser.a.p/tcg_tcg-op.c.o"
  "$QEMU_BUILD/libuser.a.p/tcg_tcg-op-ldst.c.o"
  "$QEMU_BUILD/libuser.a.p/tcg_optimize.c.o"
)

if [[ "$FRESH" -eq 1 ]]; then
  rm -rf "$SCRATCH_ROOT"
fi
mkdir -p "$SCRATCH_ROOT"

require_tool cc
require_tool python3
require_tool bash
[[ -f "$PTC_HEADER" ]] || die "exact repo ptc.h is missing: $PTC_HEADER"
[[ -d "$QEMU_BUILD" ]] || die "QEMU build dir is missing: $QEMU_BUILD"

for object in "${QEMU_OBJECTS[@]}"; do
  [[ -f "$object" ]] || die "QEMU object needed for link attempt is missing: $object"
done

log "Generating in-library live translate candidate against exact repo ptc.h"
cat >"$CANDIDATE_C" <<'C'
#include <errno.h>
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

/*
 * This is deliberately a live-QEMU candidate, not a model-backed fallback.
 * The unresolved call below forces the link to prove whether the QEMU
 * translate path can be embedded from the existing linux-user build objects.
 */
extern void translator_loop(void);
extern int cpu_exec(void *cpu);

PTCOpcodeDef *ptc_opcode_defs;
PTCHelperDef *ptc_helper_defs;
unsigned ptc_helper_defs_size;

static uint64_t ptc_elf_start_stack = UINT64_C(0x700000000000);
static uint64_t ptc_regs[16];
static uint8_t ptc_initialized_env[64];
static int32_t ptc_exception_syscall = -1;
static uint64_t ptc_status_words[16];

const char *ptc_get_abi_metadata(void)
{
  return "abi_version=2\nstub_kind=inlibrary_live_qemu_link_candidate\nreal_translation=attempted\nmodel_backed=false\n";
}

int ptc_load(void *handle, PTCInterface *output, const char *ptc_filename, const char *exe_args)
{
  PTCInterface result = { 0 };

  (void) handle;
  (void) ptc_filename;
  (void) exe_args;
  if (output == NULL) {
    return -EINVAL;
  }

  result.translate = &ptc_translate;
  result.initialized_env = ptc_initialized_env;
  result.regs = ptc_regs;
  result.ElfStartStack = &ptc_elf_start_stack;
  result.exception_syscall = &ptc_exception_syscall;
  result.syscall_next_eip = &ptc_status_words[0];
  result.isIndirect = &ptc_status_words[1];
  result.isCall = &ptc_status_words[2];
  result.isDirectcall = &ptc_status_words[3];
  result.CallNext = &ptc_status_words[4];
  result.isIndirectJmp = &ptc_status_words[5];
  result.isDirectJmp = &ptc_status_words[6];
  result.isRet = &ptc_status_words[7];
  result.illegalAccessAddr = &ptc_status_words[8];
  result.CFIAddr = &ptc_status_words[9];
  result.isSyscall = &ptc_status_words[10];
  result.BlockSize = &ptc_status_words[11];
  result.iCount = &ptc_status_words[12];
  result.isIllegal = &ptc_status_words[13];
  result.isAdd = &ptc_status_words[14];

  *output = result;
  return 0;
}

size_t ptc_translate(uint64_t virtual_address, uint32_t force,
                     PTCInstructionList *instructions, uint64_t *dymvirtual_address)
{
  (void) virtual_address;
  (void) force;
  if (instructions == NULL) {
    return 0;
  }

  memset(instructions, 0, sizeof(*instructions));
  if (dymvirtual_address != NULL) {
    *dymvirtual_address = virtual_address;
  }

  /*
   * Strong target: this must become a call into an initialized QEMU
   * translate/walker helper that fills instructions. In this bounded pass the
   * symbol is intentionally linked from QEMU objects to expose the real
   * dependency closure instead of silently falling back to model payloads.
   */
  translator_loop();
  return instructions->instruction_count;
}

void ptc_instruction_list_destroy_for_smoke(PTCInstructionList *instructions)
{
  ptc_instruction_list_free(instructions);
}
C

log "Compiling candidate object"
set +e
cc -fPIC -Wall -Wextra -I"$LEGACY_QEMU_DIR/linux-user" -I"$LEGACY_QEMU_DIR/tcg" -c "$CANDIDATE_C" -o "$CANDIDATE_O" >"$COMPILE_LOG" 2>&1
compile_rc=$?
set -e
if [[ "$compile_rc" -ne 0 ]]; then
  sed -n '1,160p' "$COMPILE_LOG" >&2
  die "candidate did not compile against exact repo ptc.h; see $COMPILE_LOG"
fi

log "Attempting strong shared-library link with QEMU linux-user translation objects"
set +e
cc -shared -Wl,--no-undefined -o "$LIB_SO" "$CANDIDATE_O" "${QEMU_OBJECTS[@]}" "$QEMU_BUILD/libqemuutil.a" -lm -lz -pthread -ldl -lglib-2.0 >"$LINK_LOG" 2>&1
link_rc=$?
set -e

strong_status="blocked"
strong_reason="qemu-linux-user-translation-object-link-failed"
if [[ "$link_rc" -eq 0 && -s "$LIB_SO" ]]; then
  strong_status="linked_unvalidated"
  strong_reason="strong link unexpectedly succeeded, but no non-empty in-library live PTCInstructionList validation was implemented in this bounded pass"
else
  rm -f "$LIB_SO"
fi

fallback_status="skipped"
if [[ "$SKIP_FALLBACK" -eq 0 ]]; then
  log "Running known live/model bridge fallback once for comparison"
  bash "$SCRIPT_DIR/qemu_v2_ptc_live_translate_bridge_smoke.sh" \
    --scratch-root "$FALLBACK_ROOT" \
    --qemu-src "$QEMU_SRC" \
    --jobs "$JOBS" \
    --fresh
  fallback_status="ran"
fi

log "Writing spike summary"
python3 - "$SUMMARY_JSON" "$SCRATCH_ROOT" "$CANDIDATE_C" "$CANDIDATE_O" "$COMPILE_LOG" "$LINK_LOG" "$LIB_SO" "$QEMU_BUILD" "$PTC_HEADER" "$link_rc" "$strong_status" "$strong_reason" "$fallback_status" "$FALLBACK_SUMMARY" "${QEMU_OBJECTS[@]}" <<'PY'
import json
import sys
from pathlib import Path

summary_path = Path(sys.argv[1])
scratch_root = Path(sys.argv[2])
candidate_c = Path(sys.argv[3])
candidate_o = Path(sys.argv[4])
compile_log = Path(sys.argv[5])
link_log = Path(sys.argv[6])
lib_so = Path(sys.argv[7])
qemu_build = Path(sys.argv[8])
ptc_header = Path(sys.argv[9])
link_rc = int(sys.argv[10])
strong_status = sys.argv[11]
strong_reason = sys.argv[12]
fallback_status = sys.argv[13]
fallback_summary_path = Path(sys.argv[14])
qemu_objects = [str(Path(p)) for p in sys.argv[15:]]

link_excerpt = []
if link_log.exists():
    with link_log.open(errors="replace") as stream:
        for line in stream:
            line = line.rstrip("\n")
            if "undefined reference" in line or "relocation" in line or "multiple definition" in line:
                link_excerpt.append(line)
            if len(link_excerpt) >= 40:
                break

fallback = None
if fallback_summary_path.exists():
    with fallback_summary_path.open() as stream:
        fallback = json.load(stream)

summary = {
    "status": "passed" if fallback_status in {"ran", "skipped"} else "failed",
    "strong_outcome_achieved": False,
    "strong_status": strong_status,
    "strong_reason": strong_reason,
    "scratch_root": str(scratch_root),
    "candidate_c": str(candidate_c),
    "candidate_object": str(candidate_o),
    "compile_log": str(compile_log),
    "link_log": str(link_log),
    "dynamic_library_path": str(lib_so) if lib_so.exists() else None,
    "qemu_build": str(qemu_build),
    "ptc_header": str(ptc_header),
    "qemu_objects_attempted": qemu_objects,
    "link_return_code": link_rc,
    "link_evidence_excerpt": link_excerpt,
    "blocker": {
        "summary": "Existing QEMU linux-user build artifacts do not expose a small reusable in-process translate/walker library for ptc_translate.",
        "details": [
            "The candidate compiles against the archived legacy ptc.h ABI.",
            "Linking the candidate with translator_loop and target/i386 translate objects requires the full QEMU linux-user dependency closure.",
            "The current walker hook is inside QEMU's initialized translate-all path after CPUState, TranslationBlock, TCGContext, page/mmap, and target CPU setup exist.",
            "A correct strong bridge needs a QEMU-owned translate-only helper or shared library that performs linux-user CPU/page/TCG initialization before filling PTCInstructionList.",
        ],
    },
    "fallback_comparison": {
        "status": fallback_status,
        "summary_json": str(fallback_summary_path) if fallback_summary_path.exists() else None,
        "live_walker_regenerated_same_run": (fallback or {}).get("live_walker_regenerated_same_run"),
        "dynamic_library_path": ((fallback or {}).get("dynamic") or {}).get("library_path"),
        "instruction_count": ((fallback or {}).get("dynamic") or {}).get("instruction_count"),
        "argument_count": ((fallback or {}).get("dynamic") or {}).get("argument_count"),
        "temp_count": ((fallback or {}).get("dynamic") or {}).get("temp_count"),
        "model_backed": fallback is not None,
    },
    "next_plan": [
        "Patch/copy QEMU under /tmp to add an exported rr_ptc_translate_one_tb(CPUState*, vaddr, PTCInstructionList*) helper near setjmp_gen_code, reusing the existing walker while the TCGContext is live.",
        "Build that patched QEMU path as either a dedicated shared object or a linux-user binary/library variant with explicit initialization entrypoints, not by ad hoc linking meson private objects.",
        "Make libtinycode-x86_64.so own ptc_load initialization: create/configure an X86CPU, initialize TCG/page/mmap state, map caller bytes, call rr_ptc_translate_one_tb from ptc_translate, and allocate/free exact ptc.h lists.",
    ],
}

summary_path.parent.mkdir(parents=True, exist_ok=True)
with summary_path.open("w") as stream:
    json.dump(summary, stream, indent=2, sort_keys=True)
    stream.write("\n")

print(json.dumps({
    "scratch_root": str(scratch_root),
    "strong_outcome_achieved": False,
    "strong_status": strong_status,
    "link_return_code": link_rc,
    "link_log": str(link_log),
    "fallback_status": fallback_status,
    "fallback_instruction_count": summary["fallback_comparison"]["instruction_count"],
    "fallback_library_path": summary["fallback_comparison"]["dynamic_library_path"],
}, sort_keys=True))
PY

cat <<EOF
in-library live translate spike complete:
  scratch_root=$SCRATCH_ROOT
  candidate_object=$CANDIDATE_O
  dynamic_library=$([[ -s "$LIB_SO" ]] && printf '%s' "$LIB_SO" || printf 'not-created')
  link_rc=$link_rc
  link_log=$LINK_LOG
  summary=$SUMMARY_JSON
EOF
