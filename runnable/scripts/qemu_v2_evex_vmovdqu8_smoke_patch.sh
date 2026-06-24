#!/usr/bin/env bash
#
# Throwaway QEMU 10.2.3 EVEX vmovdqu8 smoke patch experiment.
#
# All QEMU source/build/probe outputs stay under /tmp. This script expects a
# verified base source tree that already includes the vextracti64x4 smoke patch,
# then applies a small exact-byte overlay for selected RIP-relative stores:
#   vmovdqu8 zmmword ptr [rip + scratch], zmm14
set -euo pipefail

QEMU_VERSION="10.2.3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGGREGATE_SRC="$REPO_ROOT/test/qemu-v2-probes/avx512-evex.S"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_EVEX_VMOVDQU8_SMOKE_ROOT:-/tmp/rr-qemu-v2-evex-vmovdqu8-smoke}"
BASE_SRC="${RUNNABLE_QEMU_V2_EVEX_VMOVDQU8_BASE_SRC:-}"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-3}"
FRESH=0

PATCHED_SRC=""
BUILD_DIR=""
INSTALL_DIR=""
PATCH_FILE=""
OUT_DIR=""
PROBE_DIR=""
VENV_DIR=""
AGGREGATE_BIN=""
SINGLE_HEX=""
CHAIN_HEX=""
AGGREGATE_HEX=""

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_evex_vmovdqu8_smoke_patch.sh [options]

Options:
  --scratch-root DIR     Scratch root under /tmp.
                         Default: /tmp/rr-qemu-v2-evex-vmovdqu8-smoke
  --base-src DIR         Verified QEMU source tree that already includes
                         the vextracti64x4 smoke overlay.
  --jobs N, -j N         Parallel ninja jobs. Default: 3
  --fresh                Remove the scratch root before starting.
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

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

refresh_paths() {
  PATCHED_SRC="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vmovdqu8-smoke-src"
  BUILD_DIR="$SCRATCH_ROOT/build-${QEMU_VERSION}-evex-vmovdqu8-smoke"
  INSTALL_DIR="$SCRATCH_ROOT/install-${QEMU_VERSION}-evex-vmovdqu8-smoke"
  PATCH_FILE="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vmovdqu8-smoke.patch"
  OUT_DIR="$SCRATCH_ROOT/out"
  PROBE_DIR="$SCRATCH_ROOT/probes"
  VENV_DIR="$SCRATCH_ROOT/venv"
  AGGREGATE_BIN="$SCRATCH_ROOT/aggregate/avx512-evex"
}

resolve_base_src() {
  [[ -n "$BASE_SRC" ]] || \
    die "no verified base source tree available; pass --base-src with a vextracti64x4 smoke tree or use full-harness-18 patched source"
  [[ -d "$BASE_SRC" ]] || die "--base-src is not a directory: $BASE_SRC"
  [[ -f "$BASE_SRC/target/i386/tcg/decode-new.c.inc" ]] || \
    die "--base-src is missing target/i386/tcg/decode-new.c.inc: $BASE_SRC"
}

ensure_build_tools() {
  require_tool python3
  if command -v meson >/dev/null 2>&1 && command -v ninja >/dev/null 2>&1; then
    return
  fi
  if [[ ! -x "$VENV_DIR/bin/meson" || ! -x "$VENV_DIR/bin/ninja" ]]; then
    log "Preparing Meson/Ninja venv under $VENV_DIR"
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --upgrade pip meson ninja
  fi
  export PATH="$VENV_DIR/bin:$PATH"
}

write_probe_sources() {
  mkdir -p "$PROBE_DIR" "$OUT_DIR" "$(dirname "$AGGREGATE_BIN")"

  cat >"$PROBE_DIR/vmovdqu8-single.S" <<'EOF'
.intel_syntax noprefix
.section .text
.global _start
.type _start, @function
_start:
    vmovdqu8 zmmword ptr [rip + scratch], zmm14
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
EOF

  cat >"$PROBE_DIR/vmovdqu8-chain.S" <<'EOF'
.intel_syntax noprefix
.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    vpaddd zmm4, zmm3, zmm2
    vpternlogq zmm5, zmm4, zmm3, 0x96
    vpclmullqlqdq zmm6, zmm5, zmm4
    vpclmullqhqdq zmm7, zmm5, zmm4
    vpclmulhqlqdq zmm8, zmm5, zmm4
    vpclmulhqhqdq zmm9, zmm5, zmm4
    vaesenc zmm10, zmm9, zmm8
    vaesenclast zmm11, zmm10, zmm7
    vbroadcastf64x2 zmm12, xmmword ptr [rip + scratch]
    vpslldq zmm13, zmm12, 4
    vpsrldq zmm14, zmm13, 4
    vextracti32x4 xmm15, zmm14, 1
    vextracti64x4 ymm16, zmm14, 1
    vmovdqu8 zmmword ptr [rip + scratch], zmm14
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
EOF
}

extract_vmovdqu8_hex() {
  local objdump_file="$1"
  python3 - "$objdump_file" <<'PY'
from pathlib import Path
import re
import sys

for line in Path(sys.argv[1]).read_text().splitlines():
    if "vmovdqu8" not in line:
        continue
    m = re.search(r':\s*((?:[0-9a-f]{2} )+[0-9a-f]{2})\s+vmovdqu8', line, re.I)
    if not m:
        continue
    print(m.group(1).replace(" ", ""))
    raise SystemExit(0)
raise SystemExit("failed to extract vmovdqu8 bytes from objdump")
PY
}

build_probe() {
  local name="$1"
  local expected_text="$2"
  local bin="$PROBE_DIR/$name"
  local src="$PROBE_DIR/$name.S"
  local objdump_file="$OUT_DIR/$name.objdump.txt"

  require_tool gcc
  require_tool objdump
  gcc -nostdlib -no-pie -Wl,--build-id=none -o "$bin" "$src"
  objdump -d -Mintel "$bin" >"$objdump_file"
  grep -F "$expected_text" "$objdump_file" >/dev/null \
    || die "$name objdump is missing expected vmovdqu8 mnemonic"
}

prepare_probe_binaries() {
  write_probe_sources
  build_probe "vmovdqu8-single" "vmovdqu8 ZMMWORD PTR"
  build_probe "vmovdqu8-chain" "vmovdqu8 ZMMWORD PTR"

  SINGLE_HEX="$(extract_vmovdqu8_hex "$OUT_DIR/vmovdqu8-single.objdump.txt")"
  CHAIN_HEX="$(extract_vmovdqu8_hex "$OUT_DIR/vmovdqu8-chain.objdump.txt")"
}

build_aggregate_probe() {
  [[ -f "$AGGREGATE_SRC" ]] || die "missing aggregate probe source: $AGGREGATE_SRC"
  gcc -nostdlib -no-pie -Wl,--build-id=none -o "$AGGREGATE_BIN" "$AGGREGATE_SRC"
  objdump -d -Mintel "$AGGREGATE_BIN" >"$OUT_DIR/aggregate.objdump.txt"
  grep -F 'vmovdqu8 ZMMWORD PTR' "$OUT_DIR/aggregate.objdump.txt" >/dev/null \
    || die "aggregate objdump is missing expected vmovdqu8 mnemonic"
  AGGREGATE_HEX="$(extract_vmovdqu8_hex "$OUT_DIR/aggregate.objdump.txt")"
}

ensure_patch_file() {
  [[ -f "$PATCH_FILE" ]] && return

  resolve_base_src
  local source_file="$BASE_SRC/target/i386/tcg/decode-new.c.inc"
  local modified_file

  modified_file="$(mktemp "$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vmovdqu8.XXXXXX")"
  python3 - "$source_file" "$modified_file" "$SINGLE_HEX" "$CHAIN_HEX" "$AGGREGATE_HEX" <<'PY'
from pathlib import Path
import sys

orig = Path(sys.argv[1]).read_text()
src = orig
single_hex, chain_hex, aggregate_hex = sys.argv[3:6]

def bytes_block(name: str, hexstr: str) -> str:
    items = [f"0x{hexstr[i:i+2]}" for i in range(0, len(hexstr), 2)]
    return (
        f"    static const uint8_t {name}[] = {{\n"
        f"        {', '.join(items)}\n"
        f"    }};\n"
    )

anchor = """static void rr_evex_vextracti64x4_ymm16_zmm14_imm1(void)
{
    tcg_gen_gvec_dup_imm(MO_64, offsetof(CPUX86State, xmm_regs[16]), 64, 64, 0);
    tcg_gen_gvec_mov(MO_64,
                     offsetof(CPUX86State, xmm_regs[16].ZMM_Y(0)),
                     offsetof(CPUX86State, xmm_regs[14].ZMM_Y(1)),
                     32, 32);
}

static bool rr_try_evex_vextracti64x4_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vextracti64x4_ymm16_zmm14_0x1[] = {
        0x62, 0x33, 0xfd, 0x48, 0x3b, 0xf0, 0x01
    };
    target_ulong pc = s->pc;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vextracti64x4_ymm16_zmm14_0x1,
                             sizeof(vextracti64x4_ymm16_zmm14_0x1))) {
        return false;
    }

    rr_evex_vextracti64x4_ymm16_zmm14_imm1();
    s->pc = pc + sizeof(vextracti64x4_ymm16_zmm14_0x1);
    return true;
#else
    return false;
#endif
}
"""

insertion = anchor + """
static void rr_evex_store_zmm14_512(DisasContext *s, target_ulong guest_addr)
{
    MemOp mop = MO_128 | MO_LE | MO_ATOM_IFALIGN_PAIR;
    TCGv_i128 t = tcg_temp_new_i128();

    tcg_gen_movi_tl(s->A0, guest_addr + 0);
    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[14].ZMM_X(0)));
    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);

    tcg_gen_movi_tl(s->A0, guest_addr + 16);
    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[14].ZMM_X(1)));
    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);

    tcg_gen_movi_tl(s->A0, guest_addr + 32);
    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[14].ZMM_X(2)));
    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);

    tcg_gen_movi_tl(s->A0, guest_addr + 48);
    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[14].ZMM_X(3)));
    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);
}

static bool rr_try_evex_vmovdqu8_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
""" + bytes_block("vmovdqu8_store_single", single_hex) + bytes_block("vmovdqu8_store_chain", chain_hex) + bytes_block("vmovdqu8_store_aggregate", aggregate_hex) + """    target_ulong pc = s->pc;
    target_ulong guest_addr;

    if (!CODE64(s)) {
        return false;
    }
    if (!(rr_evex_exact_bytes(s, env, pc, vmovdqu8_store_single,
                              sizeof(vmovdqu8_store_single)) ||
          rr_evex_exact_bytes(s, env, pc, vmovdqu8_store_chain,
                              sizeof(vmovdqu8_store_chain)) ||
          rr_evex_exact_bytes(s, env, pc, vmovdqu8_store_aggregate,
                              sizeof(vmovdqu8_store_aggregate)))) {
        return false;
    }

    guest_addr = rr_evex_rip_rel_addr(s, env, pc, 10);
    rr_evex_store_zmm14_512(s, guest_addr);
    s->pc = pc + 10;
    return true;
#else
    return false;
#endif
}
"""

if "static bool rr_try_evex_vmovdqu8_smoke(DisasContext *s, CPUX86State *env)" in src:
    raise SystemExit("vmovdqu8 overlay already present in source")
if anchor not in src:
    raise SystemExit("failed to find vextracti64x4 anchor for vmovdqu8 overlay")
src = src.replace(anchor, insertion, 1)

call_marker = """    if (rr_try_evex_vextracti64x4_smoke(s, env)) {
        return;
    }"""
call_insert = """    if (rr_try_evex_vextracti64x4_smoke(s, env)) {
        return;
    }
    if (rr_try_evex_vmovdqu8_smoke(s, env)) {
        return;
    }"""
if call_marker not in src:
    raise SystemExit("failed to find vextracti64x4 dispatch hook")
src = src.replace(call_marker, call_insert, 1)

if src == orig:
    raise SystemExit("patch generation made no changes")
Path(sys.argv[2]).write_text(src)
PY

  set +e
  diff -u \
    --label a/target/i386/tcg/decode-new.c.inc \
    --label b/target/i386/tcg/decode-new.c.inc \
    "$source_file" \
    "$modified_file" >"$PATCH_FILE"
  local diff_rc=$?
  set -e
  [[ "$diff_rc" -eq 1 ]] || die "diff failed while generating overlay patch: rc=$diff_rc"
  rm -f "$modified_file"
}

prepare_patched_tree() {
  if [[ -d "$PATCHED_SRC" ]]; then
    if [[ -f "$PATCHED_SRC/.rr-evex-vmovdqu8-smoke-patched" ]]; then
      log "Using existing patched source tree $PATCHED_SRC"
      return
    fi
    die "patched tree exists without stamp: $PATCHED_SRC"
  fi

  resolve_base_src
  log "Copying verified base source tree for vmovdqu8 overlay"
  cp -a "$BASE_SRC" "$PATCHED_SRC"

  require_tool patch
  log "Applying EVEX vmovdqu8 exact-byte overlay"
  (cd "$PATCHED_SRC" && patch -p1 <"$PATCH_FILE")
  touch "$PATCHED_SRC/.rr-evex-vmovdqu8-smoke-patched"
}

configure_qemu() {
  if [[ -f "$BUILD_DIR/build.ninja" && -x "$BUILD_DIR/qemu-x86_64" ]]; then
    log "Reusing existing build directory $BUILD_DIR"
    return
  fi

  mkdir -p "$BUILD_DIR" "$INSTALL_DIR"
  log "Configuring QEMU $QEMU_VERSION"
  (
    cd "$BUILD_DIR"
    "$PATCHED_SRC/configure" \
      --target-list=x86_64-linux-user \
      --disable-system \
      --disable-tools \
      --disable-docs \
      --disable-gtk \
      --disable-sdl \
      --disable-vnc \
      --disable-curses \
      --disable-slirp \
      --disable-capstone \
      --disable-werror \
      --prefix="$INSTALL_DIR"
  ) >"$OUT_DIR/configure.out" 2>&1 || {
    tail -80 "$OUT_DIR/configure.out" >&2 || true
    die "QEMU configure failed; see $OUT_DIR/configure.out"
  }
}

build_qemu() {
  log "Building qemu-x86_64"
  ninja -C "$BUILD_DIR" -j "$JOBS" qemu-x86_64 >"$OUT_DIR/ninja.out" 2>&1 || {
    tail -120 "$OUT_DIR/ninja.out" >&2 || true
    die "QEMU build failed; see $OUT_DIR/ninja.out"
  }
  [[ -x "$BUILD_DIR/qemu-x86_64" ]] || die "missing built binary: $BUILD_DIR/qemu-x86_64"
}

run_capture_qemu_log() {
  local log_file="$1"
  local outfile="$2"
  shift 2
  local rc

  set +e
  QEMU_LOG_FILENAME="$log_file" "$@" >"$outfile" 2>&1
  rc=$?
  set -e
  printf '%s\n' "$rc" >"${outfile}.rc"
}

count_hits() {
  local pattern="$1"
  shift
  { grep -Ehi "$pattern" "$@" || true; } | wc -l | tr -d '[:space:]'
}

last_exception_pc() {
  local log_file="$1"
  grep -B4 -E 'raise_exception|EXCP06|check_exception' "$log_file" 2>/dev/null |
    sed -n 's/.*mov_i64 rip,\$\(0x[0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' |
    tail -1
}

run_probe() {
  local name="$1"
  local expected_pc="$2"
  local expected_hex="$3"
  local out="$OUT_DIR/$name.max.out"
  local log_file="$OUT_DIR/$name.max.qemu.log"
  local rc exception_hits insn_hits memory_hits store_hits pc_hits

  log "Running probe $name"
  run_capture_qemu_log "$log_file" "$out" \
    "$BUILD_DIR/qemu-x86_64" -d in_asm,op,int -cpu max "$PROBE_DIR/$name"
  rc="$(cat "${out}.rc")"
  exception_hits="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$log_file" "$out")"
  insn_hits="$(count_hits "${expected_hex}|vmovdqu8 ZMMWORD PTR|vmovdqu8" "$log_file" "$out")"
  pc_hits="$(count_hits "${expected_pc}|0x${expected_pc#0x}" "$log_file" "$out")"
  memory_hits="$(count_hits 'qemu_st2_i128|qemu_st_i128|st_i128' "$log_file")"
  store_hits="$(count_hits 'env,\$0x6e0|env,\$0x6e8|env,\$0x6f0|env,\$0x6f8|env,\$0x700|env,\$0x708|env,\$0x710|env,\$0x718' "$log_file")"

  printf '%s: %s rc=%s vmovdqu8_hits=%s memory_hits=%s store_hits=%s exception_hits=%s\n' \
    "$name" \
    "$(if [[ "$rc" = "0" && "$exception_hits" = "0" && "$insn_hits" -gt 0 && "$memory_hits" -ge 4 && "$store_hits" -gt 0 ]]; then echo PASS; else echo FAIL; fi)" \
    "$rc" "$insn_hits" "$memory_hits" "$store_hits" "$exception_hits"

  if [[ "$rc" != "0" || "$exception_hits" != "0" || "$insn_hits" -le 0 ||
        "$memory_hits" -lt 4 || "$store_hits" -le 0 ]]; then
    echo "expected_pc=$expected_pc pc_hits=$pc_hits log=$log_file"
    return 1
  fi
}

run_aggregate_probe() {
  local out="$OUT_DIR/aggregate.max.out"
  local log_file="$OUT_DIR/aggregate.max.qemu.log"
  local rc exception_hits observed_pc vmovdqu8_hits next_line

  log "Running aggregate probe"
  run_capture_qemu_log "$log_file" "$out" \
    "$BUILD_DIR/qemu-x86_64" -d in_asm,op,int -cpu max "$AGGREGATE_BIN"

  rc="$(cat "${out}.rc")"
  exception_hits="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$log_file" "$out")"
  observed_pc="$(last_exception_pc "$log_file" || true)"
  vmovdqu8_hits="$(count_hits "${AGGREGATE_HEX}|vmovdqu8 ZMMWORD PTR|vmovdqu8|rip,\$0x401081|0x0000000000401081|env,\$0x6e0|env,\$0x6e8|env,\$0x6f0|env,\$0x6f8|env,\$0x700|env,\$0x708|env,\$0x710|env,\$0x718|qemu_st2_i128" "$log_file" "$out")"
  next_line="$(grep -E -i -m1 '^ *40108b:' "$OUT_DIR/aggregate.objdump.txt" | sed 's/[[:space:]][[:space:]]*/ /g' || true)"

  if [[ "$rc" = "0" && "$exception_hits" = "0" && "$vmovdqu8_hits" -gt 0 ]]; then
    printf 'aggregate: PASS expected_next=none expected_pc=none observed_pc=completed rc=%s vmovdqu8_hits=%s exception_hits=%s\n' \
      "$rc" "$vmovdqu8_hits" "$exception_hits"
    printf 'aggregate_next: completed\n'
    return 0
  fi

  printf 'aggregate: %s expected_next=vzeroupper expected_pc=0x40108b observed_pc=%s rc=%s vmovdqu8_hits=%s exception_hits=%s\n' \
    "$(if [[ "$rc" != "0" && "$exception_hits" -gt 0 && "$observed_pc" = "0x40108b" && "$vmovdqu8_hits" -gt 0 ]]; then echo PASS; else echo FAIL; fi)" \
    "${observed_pc:-unknown}" "$rc" "$vmovdqu8_hits" "$exception_hits"
  printf 'aggregate_next: %s\n' "${next_line:-unknown}"

  if [[ "$rc" != "0" && "$exception_hits" -gt 0 && "$observed_pc" = "0x40108b" && "$vmovdqu8_hits" -gt 0 ]]; then
    return 0
  fi
  return 1
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scratch-root)
        SCRATCH_ROOT="${2:?missing value for --scratch-root}"
        shift 2
        ;;
      --base-src)
        BASE_SRC="${2:?missing value for --base-src}"
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
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ "$SCRATCH_ROOT" == /tmp/* ]] || die "--scratch-root must be under /tmp: $SCRATCH_ROOT"
  refresh_paths

  if [[ "$FRESH" -eq 1 ]]; then
    log "Removing scratch root $SCRATCH_ROOT"
    rm -rf "$SCRATCH_ROOT"
  fi

  mkdir -p "$SCRATCH_ROOT" "$OUT_DIR"
  ensure_build_tools
  prepare_probe_binaries
  build_aggregate_probe
  ensure_patch_file
  prepare_patched_tree
  configure_qemu
  build_qemu

  run_probe "vmovdqu8-single" "0x401000" "$SINGLE_HEX"
  run_probe "vmovdqu8-chain" "0x40107a" "$CHAIN_HEX"
  run_aggregate_probe
}

main "$@"
