#!/usr/bin/env bash
#
# Throwaway QEMU 10.2.3 EVEX vpclmulhqhqdq smoke patch experiment.
#
# All QEMU source/build/probe outputs stay under /tmp. This script reuses the
# existing HQLQ smoke patch as the carried-forward aggregate prefix, then applies
# a small exact-byte overlay for:
#   62 73 55 48 44 cc 11          vpclmulhqhqdq zmm9,zmm5,zmm4
set -euo pipefail

QEMU_VERSION="10.2.3"
QEMU_TARBALL="qemu-${QEMU_VERSION}.tar.xz"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HQLQ_SCRIPT="$SCRIPT_DIR/qemu_v2_evex_vpclmul_hqlq_smoke_patch.sh"
AGGREGATE_SRC="$REPO_ROOT/test/qemu-v2-probes/avx512-evex.S"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_EVEX_VPCLMUL_HH_SMOKE_ROOT:-/tmp/rr-qemu-v2-evex-vpclmul-hh-smoke}"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-3}"
FRESH=0
SKIP_DOWNLOAD=0
SKIP_AGGREGATE=0
QEMU_TARBALL_PATH=""

HQLQ_ROOT=""
HQLQ_PATCHED_SRC=""
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
  qemu_v2_evex_vpclmul_hh_smoke_patch.sh [options]

Options:
  --scratch-root DIR     Scratch root under /tmp.
                         Default: /tmp/rr-qemu-v2-evex-vpclmul-hh-smoke
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
  HQLQ_ROOT="$SCRATCH_ROOT/hqlq-base"
  HQLQ_PATCHED_SRC="$HQLQ_ROOT/qemu-${QEMU_VERSION}-evex-vpclmul-hqlq-smoke-src"
  PATCHED_SRC="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vpclmul-hh-smoke-src"
  BUILD_DIR="$SCRATCH_ROOT/build-${QEMU_VERSION}-evex-vpclmul-hh-smoke"
  INSTALL_DIR="$SCRATCH_ROOT/install-${QEMU_VERSION}-evex-vpclmul-hh-smoke"
  PATCH_FILE="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vpclmul-hh-overlay.patch"
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
@@ -2742,6 +2742,26 @@ static void rr_evex_pclmul_zmm8_zmm5_zmm4_hqlq_512(void)
         offsetof(CPUX86State, xmm_regs[4].ZMM_X(3)), 0x01);
 }

+static void rr_evex_pclmul_zmm9_zmm5_zmm4_hqhq_512(void)
+{
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[9].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(0)), 0x11);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[9].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(1)), 0x11);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[9].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(2)), 0x11);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[9].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(3)), 0x11);
+}
+
 static bool rr_try_evex_vpclmul_hqlq_smoke(DisasContext *s, CPUX86State *env)
 {
 #ifdef TARGET_X86_64
@@ -2784,6 +2804,9 @@ static bool rr_try_evex_vpclmul_hqlq_smoke(DisasContext *s, CPUX86State *env)
     static const uint8_t vpclmulhqlqdq_zmm8_zmm5_zmm4[] = {
         0x62, 0x73, 0x55, 0x48, 0x44, 0xc4, 0x01
     };
+    static const uint8_t vpclmulhqhqdq_zmm9_zmm5_zmm4[] = {
+        0x62, 0x73, 0x55, 0x48, 0x44, 0xcc, 0x11
+    };
     target_ulong pc = s->pc;
     target_ulong guest_addr;

@@ -2861,6 +2884,13 @@ static bool rr_try_evex_vpclmul_hqlq_smoke(DisasContext *s, CPUX86State *env)
         s->pc = pc + sizeof(vpclmulhqlqdq_zmm8_zmm5_zmm4);
         return true;
     }
+
+    if (rr_evex_exact_bytes(s, env, pc, vpclmulhqhqdq_zmm9_zmm5_zmm4,
+                            sizeof(vpclmulhqhqdq_zmm9_zmm5_zmm4))) {
+        rr_evex_pclmul_zmm9_zmm5_zmm4_hqhq_512();
+        s->pc = pc + sizeof(vpclmulhqhqdq_zmm9_zmm5_zmm4);
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

prepare_hqlq_base() {
  [[ -f "$HQLQ_SCRIPT" ]] || die "missing HQLQ base smoke script: $HQLQ_SCRIPT"

  local args=(
    --scratch-root "$HQLQ_ROOT"
    --jobs "$JOBS"
    --skip-aggregate
  )

  if [[ -n "$QEMU_TARBALL_PATH" ]]; then
    args+=(--qemu-tarball "$QEMU_TARBALL_PATH")
  fi
  if [[ "$SKIP_DOWNLOAD" -eq 1 ]]; then
    args+=(--skip-download)
  fi

  log "Preparing carried-forward HQLQ smoke source under $HQLQ_ROOT"
  bash "$HQLQ_SCRIPT" "${args[@]}"
  [[ -d "$HQLQ_PATCHED_SRC" ]] || die "missing HQLQ patched source: $HQLQ_PATCHED_SRC"
}

prepare_patched_tree() {
  if [[ -d "$PATCHED_SRC" ]]; then
    if [[ -f "$PATCHED_SRC/.rr-evex-vpclmul-hh-smoke-patched" ]]; then
      log "Using existing patched source tree $PATCHED_SRC"
      return
    fi
    die "patched tree exists without stamp: $PATCHED_SRC"
  fi

  log "Copying HQLQ source tree for HH overlay"
  cp -a "$HQLQ_PATCHED_SRC" "$PATCHED_SRC"

  require_tool patch
  log "Applying EVEX vpclmul hh exact-byte overlay"
  (cd "$PATCHED_SRC" && patch -p1 <"$PATCH_FILE")
  touch "$PATCHED_SRC/.rr-evex-vpclmul-hh-smoke-patched"
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

  cat >"$PROBE_DIR/vpclmul-hh-single.S" <<'EOF'
.intel_syntax noprefix
.section .text
.global _start
.type _start, @function
_start:
    vpclmulhqhqdq zmm9, zmm5, zmm4
    mov eax, 60
    xor edi, edi
    syscall
EOF

  cat >"$PROBE_DIR/vpclmul-hh-chain.S" <<'EOF'
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
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
EOF

  cat >"$PROBE_DIR/vpclmul-hh-semantic.S" <<'EOF'
.intel_syntax noprefix
.section .text
.global _start
.type _start, @function
_start:
    movdqu xmm5, xmmword ptr [rip + src_a]
    movdqu xmm4, xmmword ptr [rip + src_b]
    .byte 0x62, 0x73, 0x55, 0x48, 0x44, 0xcc, 0x11
    movdqu xmmword ptr [rip + out], xmm9

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
src_a:
    .quad 0x123456789abcdef0, 0xfeedfacecafebeef
src_b:
    .quad 0x0fedcba987654321, 0x0123456789abcdef
expected:
    .quad 0x5d145a8b347cb555, 0x00e00fef5abbd302
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

  grep -F "62 73 55 48 44 cc 11" "$objdump_file" >/dev/null \
    || die "$name objdump is missing exact vpclmulhqhqdq bytes"
  grep -F "vpclmulhqhqdq zmm9,zmm5,zmm4" "$objdump_file" >/dev/null \
    || die "$name objdump is missing expected vpclmulhqhqdq mnemonic"

  if [[ "$name" == "vpclmul-hh-chain" ]]; then
    grep -F "62 f3 55 48 44 f4 00" "$objdump_file" >/dev/null \
      || die "$name objdump is missing prior vpclmullqlqdq bytes"
    grep -F "62 f3 55 48 44 fc 10" "$objdump_file" >/dev/null \
      || die "$name objdump is missing prior vpclmullqhqdq bytes"
    grep -F "62 73 55 48 44 c4 01" "$objdump_file" >/dev/null \
      || die "$name objdump is missing prior vpclmulhqlqdq bytes"
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
  local vpclmul_hqhq_hits=0
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
    vpclmul_hqhq_hits="$({ grep -Ehi 'vpclmulhqhqdq zmm9,zmm5,zmm4' "$qemu_log" || true; } | wc -l)"
    pclmul_helper_hits="$({ grep -Ehi 'pclmulqdq_xmm' "$qemu_log" || true; } | wc -l)"
  fi

  if [[ "$run_rc" -eq 0 && "$exception_hits" -eq 0 && "$pclmul_helper_hits" -ge 4 ]]; then
    result="PASS"
  fi

  cat <<EOF
probe:                 $name
result:                $result
run_rc:                $run_rc
exception_hits:        $exception_hits
vpclmul_hqhq_hits:     $vpclmul_hqhq_hits
pclmul_helper_hits:    $pclmul_helper_hits
probe_bin:             $bin
qemu_log:              $qemu_log
EOF

  if [[ "$result" != "PASS" ]]; then
    echo "---- $name stderr ----"
    sed -n '1,120p' "$stderr_file" || true
    echo "---- $name qemu log head ----"
    sed -n '1,220p' "$qemu_log" || true
    return 1
  fi

  echo "---- $name qemu EVEX/helper ops ----"
  grep -En 'vpclmul|pclmul|raise_exception|check_exception|rip,\$0x[0-9a-f]+' "$qemu_log" | head -140 || true
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

  grep -F "62 73 55 48 44 c4 01" "$OUT_DIR/aggregate.objdump.txt" >/dev/null \
    || die "aggregate objdump is missing expected vpclmulhqlqdq bytes"
  grep -F "62 73 55 48 44 cc 11" "$OUT_DIR/aggregate.objdump.txt" >/dev/null \
    || die "aggregate objdump is missing expected vpclmulhqhqdq bytes"
  grep -F "vaesenc zmm10,zmm9,zmm8" "$OUT_DIR/aggregate.objdump.txt" >/dev/null \
    || die "aggregate objdump is missing expected post-HH vaesenc instruction"
}

run_aggregate_probe() {
  local stdout_file="$OUT_DIR/aggregate.qemu.stdout"
  local stderr_file="$OUT_DIR/aggregate.qemu.stderr"
  local qemu_log="$OUT_DIR/aggregate.qemu.log"
  local run_rc=0
  local exception_hits=0
  local vpclmul_hqhq_hits=0
  local pclmul_helper_hits=0
  local failure_pc_hex=""
  local result="FAIL_BEFORE_OR_AT_VPCLMUL_HH"
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
    vpclmul_hqhq_hits="$({ grep -Ehi 'vpclmulhqhqdq zmm9,zmm5,zmm4' "$qemu_log" || true; } | wc -l)"
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
       (( 16#$failure_pc_hex > 16#401048 )) &&
       [[ "$pclmul_helper_hits" -ge 16 ]]; then
    result="EXPECTED_FAIL_AFTER_VPCLMUL_HH"
  fi

  cat <<EOF
aggregate_result:             $result
aggregate_run_rc:             $run_rc
aggregate_exception_hits:     $exception_hits
aggregate_vpclmul_hqhq_hits:  $vpclmul_hqhq_hits
aggregate_pclmul_helper_hits: $pclmul_helper_hits
aggregate_fail_pc:            ${failure_pc_hex:-unknown}
aggregate_next:               ${next_line:-unknown}
aggregate_bin:                $AGGREGATE_BIN
aggregate_qemu_log:           $qemu_log
EOF

  echo "---- aggregate boundary ops ----"
  grep -En 'vpclmul|pclmul|vaes|raise_exception|check_exception|rip,\$0x[0-9a-f]+' "$qemu_log" | head -180 || true

  case "$result" in
    PASS_ALL|EXPECTED_FAIL_AFTER_VPCLMUL_HH)
      return 0
      ;;
    *)
      echo "---- aggregate stderr ----"
      sed -n '1,120p' "$stderr_file" || true
      echo "---- aggregate qemu log head ----"
      sed -n '1,280p' "$qemu_log" || true
      return 1
      ;;
  esac
}

run_probes() {
  local failures=0
  local name

  write_probe_sources

  for name in vpclmul-hh-single vpclmul-hh-chain vpclmul-hh-semantic; do
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
prepare_hqlq_base
ensure_build_tools
prepare_patched_tree
configure_qemu
build_qemu
run_probes
