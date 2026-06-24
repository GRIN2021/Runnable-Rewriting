#!/usr/bin/env bash
#
# Throwaway QEMU 10.2.3 EVEX vaesenclast smoke patch experiment.
#
# All QEMU source/build/probe outputs stay under /tmp. This script reuses the
# existing VAESENC smoke patch as the carried-forward aggregate prefix, then
# applies a small exact-byte overlay for:
#   62 72 2d 48 dd df             vaesenclast zmm11,zmm10,zmm7
set -euo pipefail

QEMU_VERSION="10.2.3"
QEMU_TARBALL="qemu-${QEMU_VERSION}.tar.xz"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VAESENC_SCRIPT="$SCRIPT_DIR/qemu_v2_evex_vaesenc_smoke_patch.sh"
AGGREGATE_SRC="$REPO_ROOT/test/qemu-v2-probes/avx512-evex.S"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_EVEX_VAESENCLAST_SMOKE_ROOT:-/tmp/rr-qemu-v2-evex-vaesenclast-smoke}"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-3}"
FRESH=0
SKIP_DOWNLOAD=0
SKIP_AGGREGATE=0
QEMU_TARBALL_PATH=""

VAESENC_ROOT=""
VAESENC_PATCHED_SRC=""
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
  qemu_v2_evex_vaesenclast_smoke_patch.sh [options]

Options:
  --scratch-root DIR     Scratch root under /tmp.
                         Default: /tmp/rr-qemu-v2-evex-vaesenclast-smoke
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
  VAESENC_ROOT="$SCRATCH_ROOT/vaesenc-base"
  VAESENC_PATCHED_SRC="$VAESENC_ROOT/qemu-${QEMU_VERSION}-evex-vaesenc-smoke-src"
  PATCHED_SRC="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vaesenclast-smoke-src"
  BUILD_DIR="$SCRATCH_ROOT/build-${QEMU_VERSION}-evex-vaesenclast-smoke"
  INSTALL_DIR="$SCRATCH_ROOT/install-${QEMU_VERSION}-evex-vaesenclast-smoke"
  PATCH_FILE="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vaesenclast-overlay.patch"
  OUT_DIR="$SCRATCH_ROOT/out"
  PROBE_DIR="$SCRATCH_ROOT/probes"
  VENV_DIR="$SCRATCH_ROOT/venv"
  AGGREGATE_DIR="$SCRATCH_ROOT/aggregate"
  AGGREGATE_BIN="$AGGREGATE_DIR/avx512-evex"
}

write_patch_file() {
  mkdir -p "$SCRATCH_ROOT"
  cat >"$PATCH_FILE" <<'PATCH'
diff --git a/target/i386/tcg/decode-new.c.inc b/target/i386/tcg/decode-new.c.inc
--- a/target/i386/tcg/decode-new.c.inc
+++ b/target/i386/tcg/decode-new.c.inc
@@ -2657,6 +2657,19 @@ static void rr_evex_aesenc_xmm_lane(intptr_t dofs, intptr_t vofs,
     gen_helper_aesenc_xmm(tcg_env, d, v, src);
 }

+static void rr_evex_aesenclast_xmm_lane(intptr_t dofs, intptr_t vofs,
+                                        intptr_t sofs)
+{
+    TCGv_ptr d = tcg_temp_new_ptr();
+    TCGv_ptr v = tcg_temp_new_ptr();
+    TCGv_ptr src = tcg_temp_new_ptr();
+
+    tcg_gen_addi_ptr(d, tcg_env, dofs);
+    tcg_gen_addi_ptr(v, tcg_env, vofs);
+    tcg_gen_addi_ptr(src, tcg_env, sofs);
+    gen_helper_aesenclast_xmm(tcg_env, d, v, src);
+}
+
 static void rr_evex_add_zmm4_zmm3_zmm2_512(void)
 {
     tcg_gen_gvec_add(MO_32,
@@ -2800,6 +2813,26 @@ static void rr_evex_aesenc_zmm10_zmm9_zmm8_512(void)
         offsetof(CPUX86State, xmm_regs[8].ZMM_X(3)));
 }

+static void rr_evex_aesenclast_zmm11_zmm10_zmm7_512(void)
+{
+    rr_evex_aesenclast_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[11].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[10].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[7].ZMM_X(0)));
+    rr_evex_aesenclast_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[11].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[10].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[7].ZMM_X(1)));
+    rr_evex_aesenclast_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[11].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[10].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[7].ZMM_X(2)));
+    rr_evex_aesenclast_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[11].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[10].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[7].ZMM_X(3)));
+}
+
 static bool rr_try_evex_vpclmul_hqlq_smoke(DisasContext *s, CPUX86State *env)
 {
 #ifdef TARGET_X86_64
@@ -2851,6 +2884,9 @@ static bool rr_try_evex_vpclmul_hqlq_smoke(DisasContext *s, CPUX86State *env)
     static const uint8_t vaesenc_zmm10_zmm9_zmm8[] = {
         0x62, 0x52, 0x35, 0x48, 0xdc, 0xd0
     };
+    static const uint8_t vaesenclast_zmm11_zmm10_zmm7[] = {
+        0x62, 0x72, 0x2d, 0x48, 0xdd, 0xdf
+    };
     target_ulong pc = s->pc;
     target_ulong guest_addr;

@@ -2939,6 +2975,13 @@ static bool rr_try_evex_vpclmul_hqlq_smoke(DisasContext *s, CPUX86State *env)
         s->pc = pc + sizeof(vaesenc_zmm10_zmm9_zmm8);
         return true;
     }
+
+    if (rr_evex_exact_bytes(s, env, pc, vaesenclast_zmm11_zmm10_zmm7,
+                            sizeof(vaesenclast_zmm11_zmm10_zmm7))) {
+        rr_evex_aesenclast_zmm11_zmm10_zmm7_512();
+        s->pc = pc + sizeof(vaesenclast_zmm11_zmm10_zmm7);
+        return true;
+    }
 #endif
     return false;
 }
PATCH
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

prepare_vaesenc_base() {
  [[ -f "$VAESENC_SCRIPT" ]] || die "missing VAESENC base smoke script: $VAESENC_SCRIPT"

  local args=(
    --scratch-root "$VAESENC_ROOT"
    --jobs "$JOBS"
    --skip-aggregate
  )

  if [[ -n "$QEMU_TARBALL_PATH" ]]; then
    args+=(--qemu-tarball "$QEMU_TARBALL_PATH")
  fi
  if [[ "$SKIP_DOWNLOAD" -eq 1 ]]; then
    args+=(--skip-download)
  fi

  log "Preparing carried-forward VAESENC smoke source under $VAESENC_ROOT"
  bash "$VAESENC_SCRIPT" "${args[@]}"
  [[ -d "$VAESENC_PATCHED_SRC" ]] || die "missing VAESENC patched source: $VAESENC_PATCHED_SRC"
}

prepare_patched_tree() {
  if [[ -d "$PATCHED_SRC" ]]; then
    if [[ -f "$PATCHED_SRC/.rr-evex-vaesenclast-smoke-patched" ]]; then
      log "Using existing patched source tree $PATCHED_SRC"
      return
    fi
    die "patched tree exists without stamp: $PATCHED_SRC"
  fi

  log "Copying VAESENC source tree for VAESENCLAST overlay"
  cp -a "$VAESENC_PATCHED_SRC" "$PATCHED_SRC"

  require_tool patch
  log "Applying EVEX vaesenclast exact-byte overlay"
  (cd "$PATCHED_SRC" && patch -p1 <"$PATCH_FILE")
  touch "$PATCHED_SRC/.rr-evex-vaesenclast-smoke-patched"
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

  cat >"$PROBE_DIR/vaesenclast-single.S" <<'EOF'
.intel_syntax noprefix
.section .text
.global _start
.type _start, @function
_start:
    vaesenclast zmm11, zmm10, zmm7
    mov eax, 60
    xor edi, edi
    syscall
EOF

  cat >"$PROBE_DIR/vaesenclast-chain.S" <<'EOF'
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
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
EOF

  cat >"$PROBE_DIR/vaesenclast-semantic.S" <<'EOF'
.intel_syntax noprefix
.section .text
.global _start
.type _start, @function
_start:
    movdqu xmm10, xmmword ptr [rip + state]
    movdqu xmm7, xmmword ptr [rip + round_key]
    .byte 0x62, 0x72, 0x2d, 0x48, 0xdd, 0xdf
    movdqu xmmword ptr [rip + out], xmm11

    mov rax, qword ptr [rip + out]
    xor rax, qword ptr [rip + expected]
    mov rdx, qword ptr [rip + out + 8]
    xor rdx, qword ptr [rip + expected + 8]
    or rax, rdx
    setne dil
    movzx edi, dil
    mov eax, 60
    syscall

.section .data
.align 16
state:
    .byte 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77
    .byte 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff
round_key:
    .byte 0x0f, 0x0e, 0x0d, 0x0c, 0x0b, 0x0a, 0x09, 0x08
    .byte 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x00
expected:
    .byte 0x6c, 0xf2, 0xa1, 0x1a, 0x10, 0xe4, 0x21, 0xcb
    .byte 0xc3, 0xc7, 0x96, 0xf1, 0x48, 0x80, 0x32, 0xea
out:
    .zero 16
EOF
}

build_probe() {
  local name="$1"
  local src="$PROBE_DIR/$name.S"
  local bin="$PROBE_DIR/$name"
  local objdump_file="$OUT_DIR/$name.objdump.txt"

  require_tool gcc
  require_tool objdump

  log "Building probe $name"
  gcc -nostdlib -no-pie -Wl,--build-id=none -o "$bin" "$src"
  objdump -d -Mintel "$bin" >"$objdump_file"

  grep -F "62 72 2d 48 dd df" "$objdump_file" >/dev/null \
    || die "$name objdump is missing exact vaesenclast bytes"
  grep -F "vaesenclast zmm11,zmm10,zmm7" "$objdump_file" >/dev/null \
    || die "$name objdump is missing expected vaesenclast mnemonic"

  if [[ "$name" == "vaesenclast-chain" ]]; then
    grep -F "62 52 35 48 dc d0" "$objdump_file" >/dev/null \
      || die "$name objdump is missing prior vaesenc bytes"
    grep -F "62 73 55 48 44 cc 11" "$objdump_file" >/dev/null \
      || die "$name objdump is missing prior vpclmulhqhqdq bytes"
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
  local vaesenc_hits=0
  local vaesenclast_hits=0
  local aesenc_helper_hits=0
  local aesenclast_helper_hits=0
  local pclmul_helper_hits=0
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
    vaesenc_hits="$({ grep -Ehi 'vaesenc zmm10,zmm9,zmm8' "$qemu_log" || true; } | wc -l)"
    vaesenclast_hits="$({ grep -Ehi 'vaesenclast zmm11,zmm10,zmm7' "$qemu_log" || true; } | wc -l)"
    aesenc_helper_hits="$({ grep -Ehi 'aesenc_xmm' "$qemu_log" || true; } | wc -l)"
    aesenclast_helper_hits="$({ grep -Ehi 'aesenclast_xmm' "$qemu_log" || true; } | wc -l)"
    pclmul_helper_hits="$({ grep -Ehi 'pclmulqdq_xmm' "$qemu_log" || true; } | wc -l)"
  fi

  if [[ "$run_rc" -eq 0 && "$exception_hits" -eq 0 && "$aesenclast_helper_hits" -ge 4 ]]; then
    result="PASS"
  fi

  cat <<EOF
probe:                    $name
result:                   $result
run_rc:                   $run_rc
exception_hits:           $exception_hits
vaesenc_hits:             $vaesenc_hits
vaesenclast_hits:         $vaesenclast_hits
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
  grep -En 'vaes|aesenc|aesenclast|vpclmul|pclmul|raise_exception|check_exception|rip,\$0x[0-9a-f]+' "$qemu_log" | head -220 || true
  return 0
}

build_aggregate_probe() {
  require_tool gcc
  require_tool objdump

  [[ -f "$AGGREGATE_SRC" ]] || die "missing aggregate probe source: $AGGREGATE_SRC"
  mkdir -p "$AGGREGATE_DIR"

  log "Building aggregate probe"
  gcc -nostdlib -no-pie -Wl,--build-id=none -o "$AGGREGATE_BIN" "$AGGREGATE_SRC"
  objdump -d -Mintel "$AGGREGATE_BIN" >"$OUT_DIR/aggregate.objdump.txt"

  grep -F "62 52 35 48 dc d0" "$OUT_DIR/aggregate.objdump.txt" >/dev/null \
    || die "aggregate objdump is missing expected vaesenc bytes"
  grep -F "62 72 2d 48 dd df" "$OUT_DIR/aggregate.objdump.txt" >/dev/null \
    || die "aggregate objdump is missing expected vaesenclast bytes"
  grep -F "vbroadcastf64x2 zmm12" "$OUT_DIR/aggregate.objdump.txt" >/dev/null \
    || die "aggregate objdump is missing expected post-VAESENCLAST vbroadcastf64x2 instruction"
}

run_aggregate_probe() {
  local stdout_file="$OUT_DIR/aggregate.qemu.stdout"
  local stderr_file="$OUT_DIR/aggregate.qemu.stderr"
  local qemu_log="$OUT_DIR/aggregate.qemu.log"
  local run_rc=0
  local exception_hits=0
  local vaesenc_hits=0
  local vaesenclast_hits=0
  local aesenc_helper_hits=0
  local aesenclast_helper_hits=0
  local pclmul_helper_hits=0
  local failure_pc_hex=""
  local result="FAIL_BEFORE_OR_AT_VAESENCLAST"
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
    vaesenc_hits="$({ grep -Ehi 'vaesenc zmm10,zmm9,zmm8' "$qemu_log" || true; } | wc -l)"
    vaesenclast_hits="$({ grep -Ehi 'vaesenclast zmm11,zmm10,zmm7' "$qemu_log" || true; } | wc -l)"
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
       (( 16#$failure_pc_hex > 16#401055 )) &&
       [[ "$pclmul_helper_hits" -ge 16 ]] &&
       [[ "$aesenc_helper_hits" -ge 4 ]] &&
       [[ "$aesenclast_helper_hits" -ge 4 ]]; then
    result="EXPECTED_FAIL_AFTER_VAESENCLAST"
  fi

  cat <<EOF
aggregate_result:                $result
aggregate_run_rc:                $run_rc
aggregate_exception_hits:        $exception_hits
aggregate_vaesenc_hits:          $vaesenc_hits
aggregate_vaesenclast_hits:      $vaesenclast_hits
aggregate_aesenc_helper_hits:    $aesenc_helper_hits
aggregate_aesenclast_helper_hits: $aesenclast_helper_hits
aggregate_pclmul_helper_hits:    $pclmul_helper_hits
aggregate_fail_pc:               ${failure_pc_hex:-unknown}
aggregate_next:                  ${next_line:-unknown}
aggregate_bin:                   $AGGREGATE_BIN
aggregate_qemu_log:              $qemu_log
EOF

  echo "---- aggregate boundary ops ----"
  grep -En 'vpclmul|pclmul|vaes|aesenc|aesenclast|vbroadcast|raise_exception|check_exception|rip,\$0x[0-9a-f]+' "$qemu_log" | head -260 || true

  case "$result" in
    PASS_ALL|EXPECTED_FAIL_AFTER_VAESENCLAST)
      return 0
      ;;
    *)
      echo "---- aggregate stderr ----"
      sed -n '1,120p' "$stderr_file" || true
      echo "---- aggregate qemu log head ----"
      sed -n '1,360p' "$qemu_log" || true
      return 1
      ;;
  esac
}

run_probes() {
  local failures=0
  local name

  write_probe_sources

  for name in vaesenclast-single vaesenclast-chain vaesenclast-semantic; do
    build_probe "$name"
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
write_patch_file
prepare_vaesenc_base
ensure_build_tools
prepare_patched_tree
configure_qemu
build_qemu
run_probes
