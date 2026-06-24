#!/usr/bin/env bash
#
# Throwaway QEMU 10.2.3 EVEX vbroadcastf64x2 smoke patch experiment.
#
# All QEMU source/build/probe outputs stay under /tmp. This script reuses the
# existing VAESENCLAST smoke patch as the carried-forward aggregate prefix, then
# applies a small exact-byte overlay for:
#   62 72 fd 48 1a 25 9b 0f 00 00  vbroadcastf64x2 zmm12,[rip+disp32]
set -euo pipefail

QEMU_VERSION="10.2.3"
QEMU_TARBALL="qemu-${QEMU_VERSION}.tar.xz"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VAESENCLAST_SCRIPT="$SCRIPT_DIR/qemu_v2_evex_vaesenclast_smoke_patch.sh"
AGGREGATE_SRC="$REPO_ROOT/test/qemu-v2-probes/avx512-evex.S"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_EVEX_VBROADCASTF64X2_SMOKE_ROOT:-/tmp/rr-qemu-v2-evex-vbroadcastf64x2-smoke}"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-3}"
FRESH=0
SKIP_DOWNLOAD=0
SKIP_AGGREGATE=0
QEMU_TARBALL_PATH=""

VAESENCLAST_ROOT=""
VAESENCLAST_PATCHED_SRC=""
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
  qemu_v2_evex_vbroadcastf64x2_smoke_patch.sh [options]

Options:
  --scratch-root DIR     Scratch root under /tmp.
                         Default: /tmp/rr-qemu-v2-evex-vbroadcastf64x2-smoke
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
  VAESENCLAST_ROOT="$SCRATCH_ROOT/vaesenclast-base"
  VAESENCLAST_PATCHED_SRC="$VAESENCLAST_ROOT/qemu-${QEMU_VERSION}-evex-vaesenclast-smoke-src"
  PATCHED_SRC="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vbroadcastf64x2-smoke-src"
  BUILD_DIR="$SCRATCH_ROOT/build-${QEMU_VERSION}-evex-vbroadcastf64x2-smoke"
  INSTALL_DIR="$SCRATCH_ROOT/install-${QEMU_VERSION}-evex-vbroadcastf64x2-smoke"
  PATCH_FILE="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vbroadcastf64x2-overlay.patch"
  OUT_DIR="$SCRATCH_ROOT/out"
  PROBE_DIR="$SCRATCH_ROOT/probes"
  VENV_DIR="$SCRATCH_ROOT/venv"
  AGGREGATE_DIR="$SCRATCH_ROOT/aggregate"
  AGGREGATE_BIN="$AGGREGATE_DIR/avx512-evex"
}

write_patch_file() {
  local source_file="$VAESENCLAST_PATCHED_SRC/target/i386/tcg/decode-new.c.inc"
  local modified_file

  [[ -f "$source_file" ]] || die "missing source file for patch generation: $source_file"

  modified_file="$(mktemp "$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vbroadcastf64x2.XXXXXX")"
  python3 - "$source_file" "$modified_file" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text()
dst = src.replace(
    """static void rr_evex_aesenclast_zmm11_zmm10_zmm7_512(void)
{
    rr_evex_aesenclast_xmm_lane(
        offsetof(CPUX86State, xmm_regs[11].ZMM_X(0)),
        offsetof(CPUX86State, xmm_regs[10].ZMM_X(0)),
        offsetof(CPUX86State, xmm_regs[7].ZMM_X(0)));
    rr_evex_aesenclast_xmm_lane(
        offsetof(CPUX86State, xmm_regs[11].ZMM_X(1)),
        offsetof(CPUX86State, xmm_regs[10].ZMM_X(1)),
        offsetof(CPUX86State, xmm_regs[7].ZMM_X(1)));
    rr_evex_aesenclast_xmm_lane(
        offsetof(CPUX86State, xmm_regs[11].ZMM_X(2)),
        offsetof(CPUX86State, xmm_regs[10].ZMM_X(2)),
        offsetof(CPUX86State, xmm_regs[7].ZMM_X(2)));
    rr_evex_aesenclast_xmm_lane(
        offsetof(CPUX86State, xmm_regs[11].ZMM_X(3)),
        offsetof(CPUX86State, xmm_regs[10].ZMM_X(3)),
        offsetof(CPUX86State, xmm_regs[7].ZMM_X(3)));
}
""",
    """static void rr_evex_aesenclast_zmm11_zmm10_zmm7_512(void)
{
    rr_evex_aesenclast_xmm_lane(
        offsetof(CPUX86State, xmm_regs[11].ZMM_X(0)),
        offsetof(CPUX86State, xmm_regs[10].ZMM_X(0)),
        offsetof(CPUX86State, xmm_regs[7].ZMM_X(0)));
    rr_evex_aesenclast_xmm_lane(
        offsetof(CPUX86State, xmm_regs[11].ZMM_X(1)),
        offsetof(CPUX86State, xmm_regs[10].ZMM_X(1)),
        offsetof(CPUX86State, xmm_regs[7].ZMM_X(1)));
    rr_evex_aesenclast_xmm_lane(
        offsetof(CPUX86State, xmm_regs[11].ZMM_X(2)),
        offsetof(CPUX86State, xmm_regs[10].ZMM_X(2)),
        offsetof(CPUX86State, xmm_regs[7].ZMM_X(2)));
    rr_evex_aesenclast_xmm_lane(
        offsetof(CPUX86State, xmm_regs[11].ZMM_X(3)),
        offsetof(CPUX86State, xmm_regs[10].ZMM_X(3)),
        offsetof(CPUX86State, xmm_regs[7].ZMM_X(3)));
}

static void rr_evex_broadcastf64x2_zmm12_m128_512(DisasContext *s,
                                                  target_ulong guest_addr)
{
    MemOp mop = MO_128 | MO_LE | MO_ATOM_IFALIGN_PAIR;
    TCGv_i128 t = tcg_temp_new_i128();

    tcg_gen_movi_tl(s->A0, guest_addr);
    tcg_gen_qemu_ld_i128(t, s->A0, s->mem_index, mop);
    tcg_gen_st_i128(t, tcg_env,
                    offsetof(CPUX86State, xmm_regs[12].ZMM_X(0)));
    tcg_gen_st_i128(t, tcg_env,
                    offsetof(CPUX86State, xmm_regs[12].ZMM_X(1)));
    tcg_gen_st_i128(t, tcg_env,
                    offsetof(CPUX86State, xmm_regs[12].ZMM_X(2)));
    tcg_gen_st_i128(t, tcg_env,
                    offsetof(CPUX86State, xmm_regs[12].ZMM_X(3)));
}
""",
    1,
)
dst = dst.replace(
    """    static const uint8_t vaesenclast_zmm11_zmm10_zmm7[] = {
        0x62, 0x72, 0x2d, 0x48, 0xdd, 0xdf
    };
    target_ulong pc = s->pc;
    target_ulong guest_addr;
""",
    """    static const uint8_t vaesenclast_zmm11_zmm10_zmm7[] = {
        0x62, 0x72, 0x2d, 0x48, 0xdd, 0xdf
    };
    static const uint8_t vbroadcastf64x2_zmm12_m128[] = {
        0x62, 0x72, 0xfd, 0x48, 0x1a, 0x25, 0x9b, 0x0f, 0x00, 0x00
    };
    static const uint8_t vbroadcastf64x2_zmm12_m128_semantic[] = {
        0x62, 0x72, 0xfd, 0x48, 0x1a, 0x25, 0xdb, 0x1f, 0x00, 0x00
    };
    target_ulong pc = s->pc;
    target_ulong guest_addr;
""",
    1,
)
dst = dst.replace(
    """    if (rr_evex_exact_bytes(s, env, pc, vaesenclast_zmm11_zmm10_zmm7,
                            sizeof(vaesenclast_zmm11_zmm10_zmm7))) {
        rr_evex_aesenclast_zmm11_zmm10_zmm7_512();
        s->pc = pc + sizeof(vaesenclast_zmm11_zmm10_zmm7);
        return true;
    }
#endif
""",
    """    if (rr_evex_exact_bytes(s, env, pc, vaesenclast_zmm11_zmm10_zmm7,
                            sizeof(vaesenclast_zmm11_zmm10_zmm7))) {
        rr_evex_aesenclast_zmm11_zmm10_zmm7_512();
        s->pc = pc + sizeof(vaesenclast_zmm11_zmm10_zmm7);
        return true;
    }

    if (rr_evex_exact_bytes(s, env, pc, vbroadcastf64x2_zmm12_m128,
                            sizeof(vbroadcastf64x2_zmm12_m128))) {
        guest_addr = rr_evex_rip_rel_addr(s, env, pc, 10);
        rr_evex_broadcastf64x2_zmm12_m128_512(s, guest_addr);
        s->pc = pc + sizeof(vbroadcastf64x2_zmm12_m128);
        return true;
    }

    if (rr_evex_exact_bytes(s, env, pc, vbroadcastf64x2_zmm12_m128_semantic,
                            sizeof(vbroadcastf64x2_zmm12_m128_semantic))) {
        guest_addr = rr_evex_rip_rel_addr(s, env, pc, 10);
        rr_evex_broadcastf64x2_zmm12_m128_512(s, guest_addr);
        s->pc = pc + sizeof(vbroadcastf64x2_zmm12_m128_semantic);
        return true;
    }
#endif
""",
    1,
)
if dst == src:
    raise SystemExit("patch generation made no changes")
Path(sys.argv[2]).write_text(dst)
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

prepare_vaesenclast_base() {
  [[ -f "$VAESENCLAST_SCRIPT" ]] || die "missing VAESENCLAST base smoke script: $VAESENCLAST_SCRIPT"

  local args=(
    --scratch-root "$VAESENCLAST_ROOT"
    --jobs "$JOBS"
    --skip-aggregate
  )

  if [[ -n "$QEMU_TARBALL_PATH" ]]; then
    args+=(--qemu-tarball "$QEMU_TARBALL_PATH")
  fi
  if [[ "$SKIP_DOWNLOAD" -eq 1 ]]; then
    args+=(--skip-download)
  fi

  log "Preparing carried-forward VAESENCLAST smoke source under $VAESENCLAST_ROOT"
  bash "$VAESENCLAST_SCRIPT" "${args[@]}"
  [[ -d "$VAESENCLAST_PATCHED_SRC" ]] || die "missing VAESENCLAST patched source: $VAESENCLAST_PATCHED_SRC"
}

prepare_patched_tree() {
  if [[ -d "$PATCHED_SRC" ]]; then
    if [[ -f "$PATCHED_SRC/.rr-evex-vbroadcastf64x2-smoke-patched" ]]; then
      log "Using existing patched source tree $PATCHED_SRC"
      return
    fi
    die "patched tree exists without stamp: $PATCHED_SRC"
  fi

  log "Copying VAESENCLAST source tree for VBROADCASTF64X2 overlay"
  cp -a "$VAESENCLAST_PATCHED_SRC" "$PATCHED_SRC"

  require_tool patch
  log "Applying EVEX vbroadcastf64x2 exact-byte overlay"
  (cd "$PATCHED_SRC" && patch -p1 <"$PATCH_FILE")
  touch "$PATCHED_SRC/.rr-evex-vbroadcastf64x2-smoke-patched"
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

  cat >"$PROBE_DIR/vbroadcastf64x2-single.S" <<'EOF'
.intel_syntax noprefix
.section .text
.global _start
.type _start, @function
_start:
    jmp vbroadcast_insn
    .org 0x5b, 0x90
vbroadcast_insn:
    vbroadcastf64x2 zmm12, xmmword ptr [rip + src]
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
src:
    .quad 0x1122334455667788
    .quad 0x99aabbccddeeff00
EOF

  cat >"$PROBE_DIR/vbroadcastf64x2-chain.S" <<'EOF'
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

  cat >"$PROBE_DIR/vbroadcastf64x2-semantic.S" <<'EOF'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    jmp vbroadcast_insn
    .org 0x5b, 0x90
vbroadcast_insn:
    vbroadcastf64x2 zmm12, xmmword ptr [rip + src]
    vmovdqu64 zmmword ptr [rip + observed], zmm12

    lea rbx, [rip + observed]
    lea rcx, [rip + expected]
    xor rsi, rsi

    mov rax, qword ptr [rbx]
    xor rax, qword ptr [rcx]
    or rsi, rax
    mov rax, qword ptr [rbx + 8]
    xor rax, qword ptr [rcx + 8]
    or rsi, rax

    mov rax, qword ptr [rbx + 16]
    xor rax, qword ptr [rcx + 16]
    or rsi, rax
    mov rax, qword ptr [rbx + 24]
    xor rax, qword ptr [rcx + 24]
    or rsi, rax

    mov rax, qword ptr [rbx + 32]
    xor rax, qword ptr [rcx + 32]
    or rsi, rax
    mov rax, qword ptr [rbx + 40]
    xor rax, qword ptr [rcx + 40]
    or rsi, rax

    mov rax, qword ptr [rbx + 48]
    xor rax, qword ptr [rcx + 48]
    or rsi, rax
    mov rax, qword ptr [rbx + 56]
    xor rax, qword ptr [rcx + 56]
    or rsi, rax

    test rsi, rsi
    setne dil
    movzx edi, dil
    mov eax, 60
    syscall

.section .data
.align 64
src:
    .quad 0x1122334455667788
    .quad 0x99aabbccddeeff00

.section .bss
.align 64
observed:
    .zero 64

.section .rodata
.align 64
expected:
    .quad 0x1122334455667788
    .quad 0x99aabbccddeeff00
    .quad 0x1122334455667788
    .quad 0x99aabbccddeeff00
    .quad 0x1122334455667788
    .quad 0x99aabbccddeeff00
    .quad 0x1122334455667788
    .quad 0x99aabbccddeeff00
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
    || die "$name objdump is missing expected vbroadcastf64x2 mnemonic/displacement"

  if [[ "$name" == "vbroadcastf64x2-chain" ]]; then
    grep -F "62 72 2d 48 dd df" "$objdump_file" >/dev/null \
      || die "$name objdump is missing prior vaesenclast bytes"
    grep -F "62 52 35 48 dc d0" "$objdump_file" >/dev/null \
      || die "$name objdump is missing prior vaesenc bytes"
  fi
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
  local qemu_ld_i128_hits=0
  local qemu_ld2_i128_hits=0
  local st_i128_hits=0
  local st_i64_hits=0
  local aesenc_helper_hits=0
  local aesenclast_helper_hits=0
  local pclmul_helper_hits=0
  local vbroadcast_evidence=0
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
    qemu_ld_i128_hits="$({ grep -Ehi 'qemu_ld_i128' "$qemu_log" || true; } | wc -l)"
    qemu_ld2_i128_hits="$({ grep -Ehi 'qemu_ld2_i128' "$qemu_log" || true; } | wc -l)"
    st_i128_hits="$({ grep -Ehi 'st_i128' "$qemu_log" || true; } | wc -l)"
    st_i64_hits="$({ grep -Ehi 'st_i64' "$qemu_log" || true; } | wc -l)"
    aesenc_helper_hits="$({ grep -Ehi 'aesenc_xmm' "$qemu_log" || true; } | wc -l)"
    aesenclast_helper_hits="$({ grep -Ehi 'aesenclast_xmm' "$qemu_log" || true; } | wc -l)"
    pclmul_helper_hits="$({ grep -Ehi 'pclmulqdq_xmm' "$qemu_log" || true; } | wc -l)"
  fi

  if [[ "$vbroadcast_hits" -ge 1 ]] ||
     [[ "$qemu_ld_i128_hits" -ge 1 && "$st_i128_hits" -ge 4 ]] ||
     [[ "$qemu_ld2_i128_hits" -ge 1 && "$st_i64_hits" -ge 8 ]]; then
    vbroadcast_evidence=1
  fi

  if [[ "$run_rc" -eq 0 && "$exception_hits" -eq 0 && "$vbroadcast_evidence" -eq 1 ]] &&
     { [[ "$qemu_ld_i128_hits" -ge 1 && "$st_i128_hits" -ge 4 ]] ||
       [[ "$qemu_ld2_i128_hits" -ge 1 && "$st_i64_hits" -ge 8 ]]; }; then
    result="PASS"
  fi

  cat <<EOF
probe:                    $name
result:                   $result
run_rc:                   $run_rc
exception_hits:           $exception_hits
vbroadcast_hits:          $vbroadcast_hits
qemu_ld_i128_hits:        $qemu_ld_i128_hits
qemu_ld2_i128_hits:       $qemu_ld2_i128_hits
st_i128_hits:             $st_i128_hits
st_i64_hits:              $st_i64_hits
aesenc_helper_hits:       $aesenc_helper_hits
aesenclast_helper_hits:   $aesenclast_helper_hits
pclmul_helper_hits:       $pclmul_helper_hits
probe_bin:                $bin
qemu_log:                 $qemu_log
EOF

  if [[ "$result" != "PASS" ]]; then
    echo "---- $name stderr ----"
    sed -n '1,120p' "$stderr_file" || true
    echo "---- $name qemu log head ----"
    sed -n '1,260p' "$qemu_log" || true
    return 1
  fi

  echo "---- $name qemu EVEX/helper ops ----"
  grep -En 'vbroadcast|qemu_ld[2]?_i128|st_i(64|128)|vaes|aesenc|aesenclast|vpclmul|pclmul|raise_exception|check_exception|rip,\$0x[0-9a-f]+' "$qemu_log" | head -240 || true
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

  require_binary_bytes "$AGGREGATE_BIN" "6272fd481a259b0f0000" "aggregate"
  grep -F "62 72 2d 48 dd df" "$OUT_DIR/aggregate.objdump.txt" >/dev/null \
    || die "aggregate objdump is missing expected vaesenclast bytes"
  grep -F "vbroadcastf64x2 zmm12,XMMWORD PTR [rip+0xf9b]" "$OUT_DIR/aggregate.objdump.txt" >/dev/null \
    || die "aggregate objdump is missing expected vbroadcastf64x2 instruction"
  grep -F "vpslldq zmm13,zmm12,0x4" "$OUT_DIR/aggregate.objdump.txt" >/dev/null \
    || die "aggregate objdump is missing expected post-vbroadcast vpslldq instruction"
}

run_aggregate_probe() {
  local stdout_file="$OUT_DIR/aggregate.qemu.stdout"
  local stderr_file="$OUT_DIR/aggregate.qemu.stderr"
  local qemu_log="$OUT_DIR/aggregate.qemu.log"
  local run_rc=0
  local exception_hits=0
  local vbroadcast_hits=0
  local qemu_ld_i128_hits=0
  local qemu_ld2_i128_hits=0
  local st_i128_hits=0
  local st_i64_hits=0
  local aesenc_helper_hits=0
  local aesenclast_helper_hits=0
  local pclmul_helper_hits=0
  local vbroadcast_evidence=0
  local failure_pc_hex=""
  local result="FAIL_BEFORE_OR_AT_VBROADCASTF64X2"
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
    qemu_ld_i128_hits="$({ grep -Ehi 'qemu_ld_i128' "$qemu_log" || true; } | wc -l)"
    qemu_ld2_i128_hits="$({ grep -Ehi 'qemu_ld2_i128' "$qemu_log" || true; } | wc -l)"
    st_i128_hits="$({ grep -Ehi 'st_i128' "$qemu_log" || true; } | wc -l)"
    st_i64_hits="$({ grep -Ehi 'st_i64' "$qemu_log" || true; } | wc -l)"
    aesenc_helper_hits="$({ grep -Ehi 'aesenc_xmm' "$qemu_log" || true; } | wc -l)"
    aesenclast_helper_hits="$({ grep -Ehi 'aesenclast_xmm' "$qemu_log" || true; } | wc -l)"
    pclmul_helper_hits="$({ grep -Ehi 'pclmulqdq_xmm' "$qemu_log" || true; } | wc -l)"
    if [[ "$vbroadcast_hits" -ge 1 ]] ||
       [[ "$qemu_ld_i128_hits" -ge 1 && "$st_i128_hits" -ge 4 ]] ||
       [[ "$qemu_ld2_i128_hits" -ge 1 && "$st_i64_hits" -ge 8 ]]; then
      vbroadcast_evidence=1
    fi
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
       (( 16#$failure_pc_hex > 16#40105b )) &&
       [[ "$vbroadcast_evidence" -eq 1 ]] &&
       [[ "$pclmul_helper_hits" -ge 16 ]] &&
       [[ "$aesenc_helper_hits" -ge 4 ]] &&
       [[ "$aesenclast_helper_hits" -ge 4 ]]; then
    result="EXPECTED_FAIL_AFTER_VBROADCASTF64X2"
  fi

  cat <<EOF
aggregate_result:                 $result
aggregate_run_rc:                 $run_rc
aggregate_exception_hits:         $exception_hits
aggregate_vbroadcast_hits:        $vbroadcast_hits
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
  grep -En 'vpclmul|pclmul|vaes|aesenc|aesenclast|vbroadcast|qemu_ld[2]?_i128|st_i(64|128)|vpslldq|raise_exception|check_exception|rip,\$0x[0-9a-f]+' "$qemu_log" | head -300 || true

  case "$result" in
    PASS_ALL|EXPECTED_FAIL_AFTER_VBROADCASTF64X2)
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

  build_probe "vbroadcastf64x2-single" "6272fd481a259b0f0000" \
    "vbroadcastf64x2 zmm12,XMMWORD PTR [rip+0xf9b]"
  build_probe "vbroadcastf64x2-chain" "6272fd481a259b0f0000" \
    "vbroadcastf64x2 zmm12,XMMWORD PTR [rip+0xf9b]"
  build_probe "vbroadcastf64x2-semantic" "6272fd481a25db1f0000" \
    "vbroadcastf64x2 zmm12,XMMWORD PTR [rip+0x1fdb]"

  for name in vbroadcastf64x2-single vbroadcastf64x2-chain vbroadcastf64x2-semantic; do
    if ! run_one_probe "$name"; then
      failures=$((failures + 1))
    fi
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
prepare_vaesenclast_base
write_patch_file
ensure_build_tools
prepare_patched_tree
configure_qemu
build_qemu
run_probes
