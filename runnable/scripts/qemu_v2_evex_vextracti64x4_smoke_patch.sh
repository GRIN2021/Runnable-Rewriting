#!/usr/bin/env bash
#
# Throwaway QEMU 10.2.3 EVEX vextracti64x4 smoke patch experiment.
#
# All QEMU source/build/probe outputs stay under /tmp. This script expects a
# verified base source tree that already includes the vextracti32x4 smoke patch,
# then applies a small exact-byte overlay for:
#   62 33 fd 48 3b f0 01          vextracti64x4 ymm16,zmm14,0x1
set -euo pipefail

QEMU_VERSION="10.2.3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGGREGATE_SRC="$REPO_ROOT/test/qemu-v2-probes/avx512-evex.S"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_EVEX_VEXTRACTI64X4_SMOKE_ROOT:-/tmp/rr-qemu-v2-evex-vextracti64x4-smoke}"
BASE_SRC="${RUNNABLE_QEMU_V2_EVEX_VEXTRACTI64X4_BASE_SRC:-}"
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

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_evex_vextracti64x4_smoke_patch.sh [options]

Options:
  --scratch-root DIR     Scratch root under /tmp.
                         Default: /tmp/rr-qemu-v2-evex-vextracti64x4-smoke
  --base-src DIR         Verified QEMU source tree that already includes
                         the vextracti32x4 smoke overlay.
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
  PATCHED_SRC="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vextracti64x4-smoke-src"
  BUILD_DIR="$SCRATCH_ROOT/build-${QEMU_VERSION}-evex-vextracti64x4-smoke"
  INSTALL_DIR="$SCRATCH_ROOT/install-${QEMU_VERSION}-evex-vextracti64x4-smoke"
  PATCH_FILE="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vextracti64x4-smoke.patch"
  OUT_DIR="$SCRATCH_ROOT/out"
  PROBE_DIR="$SCRATCH_ROOT/probes"
  VENV_DIR="$SCRATCH_ROOT/venv"
  AGGREGATE_BIN="$SCRATCH_ROOT/aggregate/avx512-evex"
}

resolve_base_src() {
  [[ -n "$BASE_SRC" ]] || \
    die "no verified base source tree available; pass --base-src with a vextracti32x4 smoke tree or use full-harness-17 patched source"
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

ensure_patch_file() {
  [[ -f "$PATCH_FILE" ]] && return

  resolve_base_src
  local source_file="$BASE_SRC/target/i386/tcg/decode-new.c.inc"
  local modified_file

  modified_file="$(mktemp "$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vextracti64x4.XXXXXX")"
  python3 - "$source_file" "$modified_file" <<'PY'
from pathlib import Path
import sys

orig = Path(sys.argv[1]).read_text()
src = orig

anchor = """static void rr_evex_vextracti32x4_xmm15_zmm14_imm1(void)
{
    TCGv_i128 t = tcg_temp_new_i128();

    tcg_gen_gvec_dup_imm(MO_64, offsetof(CPUX86State, xmm_regs[15]), 64, 64, 0);
    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[14].ZMM_X(1)));
    tcg_gen_st_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[15].ZMM_X(0)));
}

static bool rr_try_evex_vextracti32x4_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vextracti32x4_xmm15_zmm14_0x1[] = {
        0x62, 0x53, 0x7d, 0x48, 0x39, 0xf7, 0x01
    };
    target_ulong pc = s->pc;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vextracti32x4_xmm15_zmm14_0x1,
                             sizeof(vextracti32x4_xmm15_zmm14_0x1))) {
        return false;
    }

    rr_evex_vextracti32x4_xmm15_zmm14_imm1();
    s->pc = pc + sizeof(vextracti32x4_xmm15_zmm14_0x1);
    return true;
#else
    return false;
#endif
}
"""

insertion = """static void rr_evex_vextracti32x4_xmm15_zmm14_imm1(void)
{
    TCGv_i128 t = tcg_temp_new_i128();

    tcg_gen_gvec_dup_imm(MO_64, offsetof(CPUX86State, xmm_regs[15]), 64, 64, 0);
    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[14].ZMM_X(1)));
    tcg_gen_st_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[15].ZMM_X(0)));
}

static bool rr_try_evex_vextracti32x4_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vextracti32x4_xmm15_zmm14_0x1[] = {
        0x62, 0x53, 0x7d, 0x48, 0x39, 0xf7, 0x01
    };
    target_ulong pc = s->pc;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vextracti32x4_xmm15_zmm14_0x1,
                             sizeof(vextracti32x4_xmm15_zmm14_0x1))) {
        return false;
    }

    rr_evex_vextracti32x4_xmm15_zmm14_imm1();
    s->pc = pc + sizeof(vextracti32x4_xmm15_zmm14_0x1);
    return true;
#else
    return false;
#endif
}

static void rr_evex_vextracti64x4_ymm16_zmm14_imm1(void)
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

if "static bool rr_try_evex_vextracti64x4_smoke(DisasContext *s, CPUX86State *env)" in src:
    raise SystemExit("vextracti64x4 overlay already present in source")
if anchor not in src:
    raise SystemExit("failed to find vextracti32x4 anchor for vextracti64x4 overlay")
src = src.replace(anchor, insertion, 1)

call_marker = """    if (rr_try_evex_vextracti32x4_smoke(s, env)) {
        return;
    }"""
call_insert = """    if (rr_try_evex_vextracti32x4_smoke(s, env)) {
        return;
    }
    if (rr_try_evex_vextracti64x4_smoke(s, env)) {
        return;
    }"""
if call_marker not in src:
    raise SystemExit("failed to find vextracti32x4 dispatch hook")
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
    if [[ -f "$PATCHED_SRC/.rr-evex-vextracti64x4-smoke-patched" ]]; then
      log "Using existing patched source tree $PATCHED_SRC"
      return
    fi
    die "patched tree exists without stamp: $PATCHED_SRC"
  fi

  resolve_base_src
  log "Copying verified base source tree for vextracti64x4 overlay"
  cp -a "$BASE_SRC" "$PATCHED_SRC"

  require_tool patch
  log "Applying EVEX vextracti64x4 exact-byte overlay"
  (cd "$PATCHED_SRC" && patch -p1 <"$PATCH_FILE")
  touch "$PATCHED_SRC/.rr-evex-vextracti64x4-smoke-patched"
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

write_probe_sources() {
  mkdir -p "$PROBE_DIR" "$OUT_DIR" "$(dirname "$AGGREGATE_BIN")"

  cat >"$PROBE_DIR/vextracti64x4-single.S" <<'EOF'
.intel_syntax noprefix
.section .text
.global _start
.type _start, @function
_start:
    vextracti64x4 ymm16, zmm14, 1
    mov eax, 60
    xor edi, edi
    syscall
EOF

  cat >"$PROBE_DIR/vextracti64x4-chain.S" <<'EOF'
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
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .quad 0x1122334455667788
    .quad 0x99aabbccddeeff00
    .zero 48
EOF
}

build_probe() {
  local name="$1"
  local expected_hex="$2"
  local expected_text="$3"
  local bin="$PROBE_DIR/$name"
  local src="$PROBE_DIR/$name.S"
  local objdump_file="$OUT_DIR/$name.objdump.txt"

  gcc -nostdlib -no-pie -Wl,--build-id=none -o "$bin" "$src"
  objdump -d -Mintel "$bin" >"$objdump_file"
  grep -F "$expected_text" "$objdump_file" >/dev/null \
    || die "$name objdump is missing expected mnemonic"
  python3 - "$bin" "$expected_hex" "$name" <<'PY'
from pathlib import Path
import sys
data = Path(sys.argv[1]).read_bytes()
needle = bytes.fromhex(sys.argv[2])
if needle not in data:
    raise SystemExit(f"{sys.argv[3]} missing bytes {needle.hex(' ')}")
PY
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
  local out="$OUT_DIR/$name.max.out"
  local log_file="$OUT_DIR/$name.max.qemu.log"
  local rc exception_hits insn_hits copy_hits

  log "Running probe $name"
  run_capture_qemu_log "$log_file" "$out" \
    "$BUILD_DIR/qemu-x86_64" -d in_asm,op,int -cpu max "$PROBE_DIR/$name"
  rc="$(cat "${out}.rc")"
  exception_hits="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$log_file" "$out")"
  insn_hits="$(count_hits '6233fd483bf001|62 33 fd 48 3b f0 01|vextracti64x4 ymm16,zmm14,0x1|vextracti64x4|000000000040107a|0x000000000040107a' "$log_file" "$out")"
  copy_hits="$(count_hits 'st_vec .*env,\$0x760|st_vec .*env,\$0x780|st_i64 .*env,\$0x760|st_i64 .*env,\$0x768|st_i64 .*env,\$0x770|st_i64 .*env,\$0x778' "$log_file")"

  printf '%s: %s rc=%s vextracti64x4_hits=%s copy_hits=%s exception_hits=%s\n' \
    "$name" \
    "$(if [[ "$rc" = "0" && "$exception_hits" = "0" && "$insn_hits" -gt 0 && "$copy_hits" -gt 0 ]]; then echo PASS; else echo FAIL; fi)" \
    "$rc" "$insn_hits" "$copy_hits" "$exception_hits"

  [[ "$rc" = "0" && "$exception_hits" = "0" && "$insn_hits" -gt 0 && "$copy_hits" -gt 0 ]]
}

build_aggregate_probe() {
  [[ -f "$AGGREGATE_SRC" ]] || die "missing aggregate probe source: $AGGREGATE_SRC"
  gcc -nostdlib -no-pie -Wl,--build-id=none -o "$AGGREGATE_BIN" "$AGGREGATE_SRC"
  objdump -d -Mintel "$AGGREGATE_BIN" >"$OUT_DIR/aggregate.objdump.txt"
  grep -F '62 33 fd 48 3b f0 01' "$OUT_DIR/aggregate.objdump.txt" >/dev/null \
    || die "aggregate objdump is missing expected vextracti64x4 bytes"
  grep -F 'vextracti64x4 ymm16,zmm14,0x1' "$OUT_DIR/aggregate.objdump.txt" >/dev/null \
    || die "aggregate objdump is missing expected vextracti64x4 mnemonic"
}

run_aggregate_probe() {
  local out="$OUT_DIR/aggregate.max.out"
  local log_file="$OUT_DIR/aggregate.max.qemu.log"
  local rc exception_hits observed_pc next_line vextracti64x4_hits prefix_hits

  build_aggregate_probe
  log "Running aggregate probe"
  run_capture_qemu_log "$log_file" "$out" \
    "$BUILD_DIR/qemu-x86_64" -d in_asm,op,int -cpu max "$AGGREGATE_BIN"

  rc="$(cat "${out}.rc")"
  exception_hits="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$log_file" "$out")"
  observed_pc="$(last_exception_pc "$log_file")"
  vextracti64x4_hits="$(count_hits '6233fd483bf001|62 33 fd 48 3b f0 01|vextracti64x4 ymm16,zmm14,0x1|vextracti64x4|000000000040107a|0x000000000040107a' "$log_file" "$out")"
  prefix_hits="$(count_hits '62537d4839f701|vextracti32x4 xmm15,zmm14,0x1|rip,\$0x40107a|0x000000000040107a' "$log_file" "$out")"
  next_line="$(grep -E -i -m1 '^ *401081:' "$OUT_DIR/aggregate.objdump.txt" | sed 's/[[:space:]][[:space:]]*/ /g' || true)"

  printf 'aggregate: %s expected_next=vmovdqu8 expected_pc=0x401081 observed_pc=%s rc=%s vextracti64x4_hits=%s exception_hits=%s\n' \
    "$(if [[ "$rc" != "0" && "$exception_hits" -gt 0 && "$observed_pc" = "0x401081" && ( "$vextracti64x4_hits" -gt 0 || "$prefix_hits" -gt 0 ) ]]; then echo PASS; else echo FAIL; fi)" \
    "${observed_pc:-unknown}" "$rc" "$vextracti64x4_hits" "$exception_hits"
  printf 'aggregate_next: %s\n' "${next_line:-unknown}"

  [[ "$rc" != "0" && "$exception_hits" -gt 0 && "$observed_pc" = "0x401081" && ( "$vextracti64x4_hits" -gt 0 || "$prefix_hits" -gt 0 ) ]]
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
  ensure_patch_file
  prepare_patched_tree
  write_probe_sources
  configure_qemu
  build_qemu

  build_probe "vextracti64x4-single" "6233fd483bf001" "vextracti64x4 ymm16,zmm14,0x1"
  build_probe "vextracti64x4-chain" "6233fd483bf001" "vextracti64x4 ymm16,zmm14,0x1"

  run_probe "vextracti64x4-single"
  run_probe "vextracti64x4-chain"
  run_aggregate_probe
}

main "$@"
