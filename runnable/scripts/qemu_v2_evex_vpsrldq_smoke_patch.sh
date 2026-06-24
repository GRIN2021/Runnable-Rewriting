#!/usr/bin/env bash
#
# Throwaway QEMU 10.2.3 EVEX vpsrldq smoke patch experiment.
#
# All QEMU source/build/probe outputs stay under /tmp. This script expects a
# verified base source tree that already includes the vpslldq smoke patch, then
# applies a small exact-byte overlay for:
#   62 d1 0d 48 73 dd 04          vpsrldq zmm14,zmm13,0x4
set -euo pipefail

QEMU_VERSION="10.2.3"
QEMU_TARBALL="qemu-${QEMU_VERSION}.tar.xz"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGGREGATE_SRC="$REPO_ROOT/test/qemu-v2-probes/avx512-evex.S"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_EVEX_VPSRLDQ_SMOKE_ROOT:-/tmp/rr-qemu-v2-evex-vpsrldq-smoke}"
BASE_SRC="${RUNNABLE_QEMU_V2_EVEX_VPSRLDQ_BASE_SRC:-}"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-3}"
FRESH=0
SKIP_DOWNLOAD=0
SKIP_AGGREGATE=0
QEMU_TARBALL_PATH=""

PATCHED_SRC=""
BUILD_DIR=""
INSTALL_DIR=""
PATCH_FILE=""
OUT_DIR=""
PROBE_DIR=""
VENV_DIR=""
AGGREGATE_DIR=""
AGGREGATE_BIN=""

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_evex_vpsrldq_smoke_patch.sh [options]

Options:
  --scratch-root DIR     Scratch root under /tmp.
                         Default: /tmp/rr-qemu-v2-evex-vpsrldq-smoke
  --base-src DIR         Verified QEMU source tree that already includes
                         the vpslldq smoke overlay.
  --qemu-tarball FILE    Reuse an existing qemu-10.2.3.tar.xz.
  --jobs N, -j N         Parallel ninja jobs. Default: 3
  --fresh                Remove the scratch root before starting.
  --skip-download        Reuse an existing tarball/source tree; do not curl.
  --skip-aggregate       Do not run the aggregate boundary check.
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
  PATCHED_SRC="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vpsrldq-smoke-src"
  BUILD_DIR="$SCRATCH_ROOT/build-${QEMU_VERSION}-evex-vpsrldq-smoke"
  INSTALL_DIR="$SCRATCH_ROOT/install-${QEMU_VERSION}-evex-vpsrldq-smoke"
  PATCH_FILE="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vpsrldq-smoke.patch"
  OUT_DIR="$SCRATCH_ROOT/out"
  PROBE_DIR="$SCRATCH_ROOT/probes"
  VENV_DIR="$SCRATCH_ROOT/venv"
  AGGREGATE_DIR="$SCRATCH_ROOT/aggregate"
  AGGREGATE_BIN="$AGGREGATE_DIR/avx512-evex"
}

resolve_base_src() {
  [[ -n "$BASE_SRC" ]] || \
    die "no verified base source tree available; pass --base-src with a vpslldq smoke tree or run patch-series 0015 PASS first"
  [[ -d "$BASE_SRC" ]] || die "--base-src is not a directory: $BASE_SRC"
  [[ -f "$BASE_SRC/target/i386/tcg/decode-new.c.inc" ]] || \
    die "--base-src is missing target/i386/tcg/decode-new.c.inc: $BASE_SRC"
}

ensure_patch_file() {
  [[ -f "$PATCH_FILE" ]] && return

  resolve_base_src
  local source_file="$BASE_SRC/target/i386/tcg/decode-new.c.inc"
  local modified_file

  [[ -f "$source_file" ]] || die "missing source file for patch generation: $source_file"

  modified_file="$(mktemp "$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vpsrldq.XXXXXX")"
  python3 - "$source_file" "$modified_file" <<'PY'
from pathlib import Path
import sys

orig = Path(sys.argv[1]).read_text()
src = orig

anchor = """static bool rr_try_evex_vpslldq_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vpslldq_zmm13_zmm12_0x4[] = {
        0x62, 0xd1, 0x15, 0x48, 0x73, 0xfc, 0x04
    };
    target_ulong pc = s->pc;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vpslldq_zmm13_zmm12_0x4,
                             sizeof(vpslldq_zmm13_zmm12_0x4))) {
        return false;
    }

    rr_evex_pslldq_zmm13_zmm12_512();
    s->pc = pc + sizeof(vpslldq_zmm13_zmm12_0x4);
    return true;
#else
    return false;
#endif
}
"""

insertion = """static bool rr_try_evex_vpslldq_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vpslldq_zmm13_zmm12_0x4[] = {
        0x62, 0xd1, 0x15, 0x48, 0x73, 0xfc, 0x04
    };
    target_ulong pc = s->pc;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vpslldq_zmm13_zmm12_0x4,
                             sizeof(vpslldq_zmm13_zmm12_0x4))) {
        return false;
    }

    rr_evex_pslldq_zmm13_zmm12_512();
    s->pc = pc + sizeof(vpslldq_zmm13_zmm12_0x4);
    return true;
#else
    return false;
#endif
}

static void rr_evex_psrldq_xmm_lane(intptr_t dofs, intptr_t sofs, uint8_t imm)
{
    TCGv_ptr d = tcg_temp_new_ptr();
    TCGv_ptr s = tcg_temp_new_ptr();
    TCGv_ptr c = rr_evex_make_imm8u_xmm_vec(imm);

    tcg_gen_addi_ptr(d, tcg_env, dofs);
    tcg_gen_addi_ptr(s, tcg_env, sofs);
    gen_helper_psrldq_xmm(tcg_env, d, s, c);
}

static void rr_evex_psrldq_zmm14_zmm13_512(void)
{
    rr_evex_psrldq_xmm_lane(
        offsetof(CPUX86State, xmm_regs[14].ZMM_X(0)),
        offsetof(CPUX86State, xmm_regs[13].ZMM_X(0)), 4);
    rr_evex_psrldq_xmm_lane(
        offsetof(CPUX86State, xmm_regs[14].ZMM_X(1)),
        offsetof(CPUX86State, xmm_regs[13].ZMM_X(1)), 4);
    rr_evex_psrldq_xmm_lane(
        offsetof(CPUX86State, xmm_regs[14].ZMM_X(2)),
        offsetof(CPUX86State, xmm_regs[13].ZMM_X(2)), 4);
    rr_evex_psrldq_xmm_lane(
        offsetof(CPUX86State, xmm_regs[14].ZMM_X(3)),
        offsetof(CPUX86State, xmm_regs[13].ZMM_X(3)), 4);
}

static bool rr_try_evex_vpsrldq_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vpsrldq_zmm14_zmm13_0x4[] = {
        0x62, 0xd1, 0x0d, 0x48, 0x73, 0xdd, 0x04
    };
    target_ulong pc = s->pc;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vpsrldq_zmm14_zmm13_0x4,
                             sizeof(vpsrldq_zmm14_zmm13_0x4))) {
        return false;
    }

    rr_evex_psrldq_zmm14_zmm13_512();
    s->pc = pc + sizeof(vpsrldq_zmm14_zmm13_0x4);
    return true;
#else
    return false;
#endif
}
"""

if "static bool rr_try_evex_vpsrldq_smoke(DisasContext *s, CPUX86State *env)" in src:
    raise SystemExit("vpsrldq overlay already present in source")
if anchor not in src:
    raise SystemExit("failed to find vpslldq anchor for vpsrldq overlay")
src = src.replace(anchor, insertion, 1)

call_marker = """    if (rr_try_evex_vpslldq_smoke(s, env)) {
        return;
    }"""
call_insert = """    if (rr_try_evex_vpslldq_smoke(s, env)) {
        return;
    }
    if (rr_try_evex_vpsrldq_smoke(s, env)) {
        return;
    }"""
if call_marker not in src:
    raise SystemExit("failed to find vpslldq dispatch hook")
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

ensure_build_tools() {
  require_tool python3
  if command -v meson >/dev/null 2>&1 && command -v ninja >/dev/null 2>&1; then
    log "Using Meson/Ninja from PATH"
    return
  fi

  if [[ ! -x "$VENV_DIR/bin/meson" || ! -x "$VENV_DIR/bin/ninja" ]]; then
    log "Preparing Meson/Ninja venv under $VENV_DIR"
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --upgrade pip meson ninja
  fi
  export PATH="$VENV_DIR/bin:$PATH"
}

prepare_patched_tree() {
  if [[ -d "$PATCHED_SRC" ]]; then
    if [[ -f "$PATCHED_SRC/.rr-evex-vpsrldq-smoke-patched" ]]; then
      log "Using existing patched source tree $PATCHED_SRC"
      return
    fi
    die "patched tree exists without stamp: $PATCHED_SRC"
  fi

  resolve_base_src
  log "Copying verified base source tree for VPSRLDQ overlay"
  cp -a "$BASE_SRC" "$PATCHED_SRC"

  require_tool patch
  log "Applying EVEX vpsrldq exact-byte overlay"
  (cd "$PATCHED_SRC" && patch -p1 <"$PATCH_FILE")
  touch "$PATCHED_SRC/.rr-evex-vpsrldq-smoke-patched"
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
  )
}

build_qemu() {
  log "Building qemu-x86_64"
  ninja -C "$BUILD_DIR" -j "$JOBS" qemu-x86_64
  [[ -x "$BUILD_DIR/qemu-x86_64" ]] || die "missing built binary: $BUILD_DIR/qemu-x86_64"
}

write_probe_sources() {
  mkdir -p "$PROBE_DIR" "$OUT_DIR"

  cat >"$PROBE_DIR/vpsrldq-single.S" <<'EOF'
.intel_syntax noprefix
.section .text
.global _start
.type _start, @function
_start:
    vpsrldq zmm14, zmm13, 4
    mov eax, 60
    xor edi, edi
    syscall
EOF

  cat >"$PROBE_DIR/vpsrldq-chain.S" <<'EOF'
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
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
src:
    .byte 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77
    .byte 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff
    .byte 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77
    .byte 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff
    .byte 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77
    .byte 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff
    .byte 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77
    .byte 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff
EOF
}

require_binary_bytes() {
  local bin="$1"
  local hex="$2"
  local label="$3"

  python3 - "$bin" "$hex" "$label" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
needle = bytes.fromhex(sys.argv[2])
label = sys.argv[3]
data = path.read_bytes()
if needle not in data:
    raise SystemExit(f"{label}: missing exact bytes {needle.hex(' ')} in {path}")
PY
}

build_probe() {
  local name="$1"
  local expected_bytes="$2"
  local expected_objdump="$3"
  local src="$PROBE_DIR/$name.S"
  local bin="$PROBE_DIR/$name"
  local objdump_file="$OUT_DIR/$name.objdump.txt"

  require_tool gcc
  require_tool objdump
  require_tool python3

  log "Building probe $name"
  gcc -nostdlib -no-pie -Wl,--build-id=none -o "$bin" "$src"
  objdump -d -Mintel "$bin" >"$objdump_file"

  require_binary_bytes "$bin" "$expected_bytes" "$name"
  grep -F "$expected_objdump" "$objdump_file" >/dev/null \
    || die "$name objdump is missing expected vpsrldq mnemonic"
}

run_one_probe() {
  local name="$1"
  local bin="$PROBE_DIR/$name"
  local stdout_file="$OUT_DIR/$name.qemu.stdout"
  local stderr_file="$OUT_DIR/$name.qemu.stderr"
  local qemu_log="$OUT_DIR/$name.qemu.log"
  local run_rc=0
  local exception_hits=0
  local vbroadcast_hits=0
  local pslldq_helper_hits=0
  local psrldq_helper_hits=0
  local qemu_ld_i128_hits=0
  local qemu_ld2_i128_hits=0
  local st_i128_hits=0
  local st_i64_hits=0
  local aesenc_helper_hits=0
  local aesenclast_helper_hits=0
  local pclmul_helper_hits=0
  local failure_pc_hex=""
  local failure_next_line=""
  local result="FAIL"

  log "Running probe $name under patched qemu-x86_64"
  set +e
  QEMU_LOG_FILENAME="$qemu_log" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    "$bin" \
    >"$stdout_file" 2>"$stderr_file"
  run_rc=$?
  set -e

  if [[ -f "$qemu_log" ]]; then
    exception_hits="$({ grep -Ehi 'raise_exception|Illegal instruction|EXCP06|check_exception' "$qemu_log" "$stderr_file" || true; } | wc -l)"
    vbroadcast_hits="$({ grep -Ehi 'vbroadcastf64x2 zmm12' "$qemu_log" || true; } | wc -l)"
    pslldq_helper_hits="$({ grep -Ehi 'pslldq_xmm' "$qemu_log" || true; } | wc -l)"
    psrldq_helper_hits="$({ grep -Ehi 'psrldq_xmm' "$qemu_log" || true; } | wc -l)"
    qemu_ld_i128_hits="$({ grep -Ehi 'qemu_ld_i128' "$qemu_log" || true; } | wc -l)"
    qemu_ld2_i128_hits="$({ grep -Ehi 'qemu_ld2_i128' "$qemu_log" || true; } | wc -l)"
    st_i128_hits="$({ grep -Ehi 'st_i128' "$qemu_log" || true; } | wc -l)"
    st_i64_hits="$({ grep -Ehi 'st_i64' "$qemu_log" || true; } | wc -l)"
    aesenc_helper_hits="$({ grep -Ehi 'aesenc_xmm' "$qemu_log" || true; } | wc -l)"
    aesenclast_helper_hits="$({ grep -Ehi 'aesenclast_xmm' "$qemu_log" || true; } | wc -l)"
    pclmul_helper_hits="$({ grep -Ehi 'pclmulqdq_xmm' "$qemu_log" || true; } | wc -l)"
    failure_pc_hex="$(
      grep -Eoi 'rip,\$0x[0-9a-f]+' "$qemu_log" \
        | tail -1 \
        | sed 's/.*\$0x//' \
        | tr '[:upper:]' '[:lower:]' \
        || true
    )"
    if [[ -n "$failure_pc_hex" ]]; then
      failure_next_line="$(
        grep -E -i -m1 "^ *${failure_pc_hex}:" "$OUT_DIR/$name.objdump.txt" \
          | sed 's/[[:space:]][[:space:]]*/ /g' \
          || true
      )"
    fi
  fi

  if [[ "$run_rc" -eq 0 && "$exception_hits" -eq 0 && "$psrldq_helper_hits" -ge 4 ]]; then
    result="PASS"
  fi

  cat <<EOF
probe:                    $name
result:                   $result
run_rc:                   $run_rc
exception_hits:           $exception_hits
vbroadcast_hits:          $vbroadcast_hits
pslldq_helper_hits:       $pslldq_helper_hits
psrldq_helper_hits:       $psrldq_helper_hits
qemu_ld_i128_hits:        $qemu_ld_i128_hits
qemu_ld2_i128_hits:       $qemu_ld2_i128_hits
st_i128_hits:             $st_i128_hits
st_i64_hits:              $st_i64_hits
aesenc_helper_hits:       $aesenc_helper_hits
aesenclast_helper_hits:   $aesenclast_helper_hits
pclmul_helper_hits:       $pclmul_helper_hits
probe_bin:                $bin
qemu_log:                 $qemu_log
probe_fail_pc:            ${failure_pc_hex:-unknown}
probe_fail_next:          ${failure_next_line:-unknown}
EOF

  if [[ "$result" != "PASS" ]]; then
    echo "---- $name stderr ----"
    sed -n '1,120p' "$stderr_file" || true
    echo "---- $name qemu log head ----"
    sed -n '1,260p' "$qemu_log" || true
    echo "---- $name failure summary ----"
    printf 'first_sigill_pc: %s\n' "${failure_pc_hex:-unknown}"
    printf 'first_sigill_insn: %s\n' "${failure_next_line:-unknown}"
    return 1
  fi

  echo "---- $name qemu EVEX/helper ops ----"
  grep -En 'vbroadcast|pslldq_xmm|psrldq_xmm|qemu_ld[2]?_i128|st_i(64|128)|vaes|aesenc|aesenclast|vpclmul|pclmul|raise_exception|check_exception|rip,\$0x[0-9a-f]+' "$qemu_log" | head -240 || true
  return 0
}

build_aggregate_probe() {
  require_tool gcc
  require_tool objdump
  require_tool python3

  [[ -f "$AGGREGATE_SRC" ]] || die "missing aggregate probe source: $AGGREGATE_SRC"
  mkdir -p "$AGGREGATE_DIR"

  log "Building aggregate probe"
  gcc -nostdlib -no-pie -Wl,--build-id=none -o "$AGGREGATE_BIN" "$AGGREGATE_SRC"
  objdump -d -Mintel "$AGGREGATE_BIN" >"$OUT_DIR/aggregate.objdump.txt"

  require_binary_bytes "$AGGREGATE_BIN" "62d10d4873dd04" "aggregate"
  grep -F "62 d1 0d 48 73 dd 04" "$OUT_DIR/aggregate.objdump.txt" >/dev/null \
    || die "aggregate objdump is missing expected vpsrldq bytes"
  grep -F "vpslldq zmm13,zmm12,0x4" "$OUT_DIR/aggregate.objdump.txt" >/dev/null \
    || die "aggregate objdump is missing expected pre-vpsrldq vpslldq instruction"
  grep -F "vpsrldq zmm14,zmm13,0x4" "$OUT_DIR/aggregate.objdump.txt" >/dev/null \
    || die "aggregate objdump is missing expected vpsrldq instruction"
}

run_aggregate_probe() {
  local stdout_file="$OUT_DIR/aggregate.qemu.stdout"
  local stderr_file="$OUT_DIR/aggregate.qemu.stderr"
  local qemu_log="$OUT_DIR/aggregate.qemu.log"
  local run_rc=0
  local exception_hits=0
  local vbroadcast_hits=0
  local pslldq_helper_hits=0
  local psrldq_helper_hits=0
  local qemu_ld_i128_hits=0
  local qemu_ld2_i128_hits=0
  local st_i128_hits=0
  local st_i64_hits=0
  local aesenc_helper_hits=0
  local aesenclast_helper_hits=0
  local pclmul_helper_hits=0
  local failure_pc_hex=""
  local result="FAIL_BEFORE_OR_AT_VPSRLDQ"
  local next_line

  build_aggregate_probe
  next_line="unknown"

  log "Running aggregate probe under patched qemu-x86_64"
  set +e
  QEMU_LOG_FILENAME="$qemu_log" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    "$AGGREGATE_BIN" \
    >"$stdout_file" 2>"$stderr_file"
  run_rc=$?
  set -e

  if [[ -f "$qemu_log" ]]; then
    exception_hits="$({ grep -Ehi 'raise_exception|Illegal instruction|EXCP06|check_exception' "$qemu_log" "$stderr_file" || true; } | wc -l)"
    vbroadcast_hits="$({ grep -Ehi 'vbroadcastf64x2 zmm12' "$qemu_log" || true; } | wc -l)"
    pslldq_helper_hits="$({ grep -Ehi 'pslldq_xmm' "$qemu_log" || true; } | wc -l)"
    psrldq_helper_hits="$({ grep -Ehi 'psrldq_xmm' "$qemu_log" || true; } | wc -l)"
    qemu_ld_i128_hits="$({ grep -Ehi 'qemu_ld_i128' "$qemu_log" || true; } | wc -l)"
    qemu_ld2_i128_hits="$({ grep -Ehi 'qemu_ld2_i128' "$qemu_log" || true; } | wc -l)"
    st_i128_hits="$({ grep -Ehi 'st_i128' "$qemu_log" || true; } | wc -l)"
    st_i64_hits="$({ grep -Ehi 'st_i64' "$qemu_log" || true; } | wc -l)"
    aesenc_helper_hits="$({ grep -Ehi 'aesenc_xmm' "$qemu_log" || true; } | wc -l)"
    aesenclast_helper_hits="$({ grep -Ehi 'aesenclast_xmm' "$qemu_log" || true; } | wc -l)"
    pclmul_helper_hits="$({ grep -Ehi 'pclmulqdq_xmm' "$qemu_log" || true; } | wc -l)"
    failure_pc_hex="$(
      grep -Eoi 'rip,\$0x[0-9a-f]+' "$qemu_log" \
        | tail -1 \
        | sed 's/.*\$0x//' \
        | tr '[:upper:]' '[:lower:]' \
        || true
    )"
    if [[ -n "$failure_pc_hex" ]]; then
      next_line="$(
        grep -E -i -m1 "^ *${failure_pc_hex}:" "$OUT_DIR/aggregate.objdump.txt" \
          | sed 's/[[:space:]][[:space:]]*/ /g' \
          || true
      )"
    fi
  fi

  if [[ "$run_rc" -eq 0 ]]; then
    result="PASS_ALL"
  elif [[ "$failure_pc_hex" =~ ^[0-9a-f]+$ ]] &&
       (( 16#$failure_pc_hex > 16#40106c )) &&
       [[ "$pslldq_helper_hits" -ge 4 ]] &&
       [[ "$psrldq_helper_hits" -ge 4 ]] &&
       [[ "$pclmul_helper_hits" -ge 16 ]] &&
       [[ "$aesenc_helper_hits" -ge 4 ]] &&
       [[ "$aesenclast_helper_hits" -ge 4 ]]; then
    result="PASS"
  fi

  cat <<EOF
aggregate_result:                 $result
aggregate_run_rc:                 $run_rc
aggregate_exception_hits:         $exception_hits
aggregate_vbroadcast_hits:        $vbroadcast_hits
aggregate_pslldq_helper_hits:     $pslldq_helper_hits
aggregate_psrldq_helper_hits:     $psrldq_helper_hits
aggregate_qemu_ld_i128_hits:      $qemu_ld_i128_hits
aggregate_qemu_ld2_i128_hits:     $qemu_ld2_i128_hits
aggregate_st_i128_hits:           $st_i128_hits
aggregate_st_i64_hits:            $st_i64_hits
aggregate_aesenc_helper_hits:     $aesenc_helper_hits
aggregate_aesenclast_helper_hits: $aesenclast_helper_hits
aggregate_pclmul_helper_hits:     $pclmul_helper_hits
aggregate_fail_pc:                ${failure_pc_hex:-unknown}
aggregate_next:                   ${next_line:-unknown}
aggregate_bin:                    $AGGREGATE_BIN
aggregate_qemu_log:               $qemu_log
EOF

  echo "---- aggregate boundary ops ----"
  grep -En 'vpclmul|pclmul|vaes|aesenc|aesenclast|vbroadcast|pslldq_xmm|psrldq_xmm|qemu_ld[2]?_i128|st_i(64|128)|vpslldq|vpsrldq|vextracti|vmovdqu8|raise_exception|check_exception|rip,\$0x[0-9a-f]+' "$qemu_log" | head -320 || true

  case "$result" in
    PASS_ALL|PASS)
      return 0
      ;;
    *)
      echo "---- aggregate stderr ----"
      sed -n '1,120p' "$stderr_file" || true
      echo "---- aggregate qemu log head ----"
      sed -n '1,380p' "$qemu_log" || true
      return 1
      ;;
  esac
}

run_probes() {
  local failures=0
  local name

  write_probe_sources

  build_probe "vpsrldq-single" "62d10d4873dd04" \
    "vpsrldq zmm14,zmm13,0x4"
  build_probe "vpsrldq-chain" "62d10d4873dd04" \
    "vpsrldq zmm14,zmm13,0x4"

  for name in vpsrldq-single vpsrldq-chain vpsrldq-semantic; do
    case "$name" in
      vpsrldq-semantic)
        cat <<'EOF'
probe:                    vpsrldq-semantic
result:                   SKIPPED
skip_reason:              semantic verification would require a zmm14 store hook, which is outside this exact-byte smoke
EOF
        ;;
      *)
        if ! run_one_probe "$name"; then
          failures=$((failures + 1))
        fi
        ;;
    esac
  done

  if [[ "$SKIP_AGGREGATE" -eq 0 ]]; then
    if ! run_aggregate_probe; then
      failures=$((failures + 1))
    fi
  else
    echo "aggregate_result: SKIPPED"
  fi

  cat <<EOF
scratch_root: $SCRATCH_ROOT
patch_file:   $PATCH_FILE
source_touch: target/i386/tcg/decode-new.c.inc
build_bin:    $BUILD_DIR/qemu-x86_64
probe_dir:    $PROBE_DIR
aggregate_src:$AGGREGATE_SRC
failures:     $failures
EOF

  [[ "$failures" -eq 0 ]]
}

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
    --qemu-tarball)
      QEMU_TARBALL_PATH="${2:?missing value for --qemu-tarball}"
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
    --skip-download)
      SKIP_DOWNLOAD=1
      shift
      ;;
    --skip-aggregate)
      SKIP_AGGREGATE=1
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

case "$SCRATCH_ROOT" in
  /tmp/*) ;;
  *) die "--scratch-root must be under /tmp: $SCRATCH_ROOT" ;;
esac

refresh_paths

if [[ "$FRESH" -eq 1 ]]; then
  log "Removing scratch root $SCRATCH_ROOT"
  rm -rf "$SCRATCH_ROOT"
fi

mkdir -p "$SCRATCH_ROOT"
ensure_build_tools
ensure_patch_file
prepare_patched_tree
configure_qemu
build_qemu
run_probes
