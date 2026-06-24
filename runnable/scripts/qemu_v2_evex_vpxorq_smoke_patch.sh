#!/usr/bin/env bash
#
# Throwaway QEMU 10.2.3 EVEX smoke patch experiment.
#
# This script keeps all QEMU source/build/probe outputs under /tmp, applies a
# tiny exact-byte patch for `62 f1 fd 48 ef c0` (`vpxorq zmm0,zmm0,zmm0`),
# rebuilds qemu-x86_64, runs a single-instruction probe, and reports pass/fail.
set -euo pipefail

QEMU_VERSION="10.2.3"
QEMU_TARBALL="qemu-${QEMU_VERSION}.tar.xz"
QEMU_URL="https://download.qemu.org/${QEMU_TARBALL}"
QEMU_SHA256="2aa0e420e4ea89ea34a833f4c4eced96a35b51a9ee8568b232692729b60b064d"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_EVEX_SMOKE_ROOT:-/tmp/rr-qemu-v2-evex-vpxorq-smoke}"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-3}"
FRESH=0
SKIP_DOWNLOAD=0

DOWNLOAD_DIR=""
BASE_SRC=""
PATCHED_SRC=""
BUILD_DIR=""
INSTALL_DIR=""
PATCH_FILE=""
OUT_DIR=""
PROBE_DIR=""
VENV_DIR=""
PROBE_SRC=""
PROBE_BIN=""

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_evex_vpxorq_smoke_patch.sh [options]

Options:
  --scratch-root DIR   Scratch root under /tmp.
                       Default: /tmp/rr-qemu-v2-evex-vpxorq-smoke
  --jobs N, -j N       Parallel ninja jobs. Default: 3
  --fresh              Remove the scratch root before starting.
  --skip-download      Reuse an existing tarball/source tree; do not curl.
  -h, --help           Show this help.
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
  DOWNLOAD_DIR="$SCRATCH_ROOT/download"
  BASE_SRC="$SCRATCH_ROOT/qemu-${QEMU_VERSION}"
  PATCHED_SRC="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vpxorq-smoke-src"
  BUILD_DIR="$SCRATCH_ROOT/build-${QEMU_VERSION}-evex-vpxorq-smoke"
  INSTALL_DIR="$SCRATCH_ROOT/install-${QEMU_VERSION}-evex-vpxorq-smoke"
  PATCH_FILE="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vpxorq-smoke.patch"
  OUT_DIR="$SCRATCH_ROOT/out"
  PROBE_DIR="$SCRATCH_ROOT/probe"
  VENV_DIR="$SCRATCH_ROOT/venv"
  PROBE_SRC="$PROBE_DIR/vpxorq.S"
  PROBE_BIN="$PROBE_DIR/vpxorq"
}

write_patch_file() {
  mkdir -p "$SCRATCH_ROOT"
  cat >"$PATCH_FILE" <<'PATCH'
diff --git a/target/i386/tcg/decode-new.c.inc b/target/i386/tcg/decode-new.c.inc
--- a/target/i386/tcg/decode-new.c.inc
+++ b/target/i386/tcg/decode-new.c.inc
@@ -2533,6 +2533,34 @@
  * Convert one instruction. s->base.is_jmp is set if the translation must
  * be stopped.
  */
+static bool rr_try_evex_vpxorq_zmm0_smoke(DisasContext *s, CPUX86State *env)
+{
+#ifdef TARGET_X86_64
+    static const uint8_t insn[] = { 0x62, 0xf1, 0xfd, 0x48, 0xef, 0xc0 };
+    target_ulong pc = s->pc;
+    int i;
+
+    if (!CODE64(s)) {
+        return false;
+    }
+    for (i = 0; i < sizeof(insn); i++) {
+        if (translator_ldub(env, &s->base, pc + i) != insn[i]) {
+            return false;
+        }
+    }
+
+    /*
+     * Throwaway smoke semantics for vpxorq zmm0,zmm0,zmm0 only.  This is not
+     * a general EVEX decoder and intentionally ignores masking and CPUID.
+     */
+    tcg_gen_gvec_dup_imm(MO_64, offsetof(CPUX86State, xmm_regs[0]), 64, 64, 0);
+    s->pc = pc + sizeof(insn);
+    return true;
+#else
+    return false;
+#endif
+}
+
 static void disas_insn(DisasContext *s, CPUState *cpu)
 {
     CPUX86State *env = cpu_env(cpu);
@@ -2556,6 +2584,10 @@
     s->has_modrm = false;
     s->prefix = 0;

+    if (rr_try_evex_vpxorq_zmm0_smoke(s, env)) {
+        return;
+    }
+
  next_byte:;
 #ifdef TARGET_X86_64
     /* clear any REX prefix followed by other prefixes.  */
PATCH
}

ensure_build_tools() {
  require_tool python3
  if [[ ! -x "$VENV_DIR/bin/meson" || ! -x "$VENV_DIR/bin/ninja" ]]; then
    log "Preparing Meson/Ninja venv under $VENV_DIR"
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --upgrade pip meson ninja
  fi
  export PATH="$VENV_DIR/bin:$PATH"
}

download_or_extract_qemu() {
  mkdir -p "$DOWNLOAD_DIR"
  if [[ -d "$BASE_SRC" ]]; then
    log "Using existing source tree $BASE_SRC"
    return
  fi

  local tarball="$DOWNLOAD_DIR/$QEMU_TARBALL"
  if [[ ! -f "$tarball" ]]; then
    [[ "$SKIP_DOWNLOAD" -eq 0 ]] || die "missing tarball $tarball and --skip-download was requested"
    require_tool curl
    log "Downloading $QEMU_TARBALL"
    curl -L --fail --retry 3 -o "$tarball" "$QEMU_URL"
  fi

  require_tool sha256sum
  (cd "$DOWNLOAD_DIR" && printf '%s  %s\n' "$QEMU_SHA256" "$QEMU_TARBALL" | sha256sum -c -)

  log "Extracting $QEMU_TARBALL"
  tar -C "$SCRATCH_ROOT" -xf "$tarball"
  [[ -x "$BASE_SRC/configure" ]] || die "expected configure script at $BASE_SRC/configure"
}

prepare_patched_tree() {
  if [[ -d "$PATCHED_SRC" ]]; then
    if [[ -f "$PATCHED_SRC/.rr-evex-vpxorq-smoke-patched" ]]; then
      log "Using existing patched source tree $PATCHED_SRC"
      return
    fi
    die "patched tree exists without stamp: $PATCHED_SRC"
  fi

  log "Copying throwaway source tree"
  cp -a "$BASE_SRC" "$PATCHED_SRC"

  require_tool patch
  log "Applying EVEX smoke patch"
  (cd "$PATCHED_SRC" && patch -p1 <"$PATCH_FILE")
  touch "$PATCHED_SRC/.rr-evex-vpxorq-smoke-patched"
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

write_probe_source() {
  mkdir -p "$PROBE_DIR" "$OUT_DIR"
  cat >"$PROBE_SRC" <<'EOF'
.intel_syntax noprefix
.text
.global _start
_start:
  vpxorq zmm0, zmm0, zmm0
  mov eax, 60
  xor edi, edi
  syscall
EOF
}

build_probe() {
  require_tool gcc
  require_tool objdump

  log "Building single-instruction vpxorq probe"
  gcc -nostdlib -no-pie -Wl,--build-id=none -o "$PROBE_BIN" "$PROBE_SRC"

  objdump -d -Mintel "$PROBE_BIN" >"$OUT_DIR/probe.objdump.txt"
  grep -F "vpxorq zmm0,zmm0,zmm0" "$OUT_DIR/probe.objdump.txt" >/dev/null \
    || die "probe objdump is missing vpxorq zmm0,zmm0,zmm0"
}

run_probe() {
  local log_file="$OUT_DIR/qemu-vpxorq.log"
  local stdout_file="$OUT_DIR/qemu-vpxorq.stdout"
  local stderr_file="$OUT_DIR/qemu-vpxorq.stderr"
  local rc=0
  local exception_hits=0
  local vector_hits=0
  local result="FAIL"

  log "Running patched qemu-x86_64 on the smoke probe"
  set +e
  QEMU_LOG_FILENAME="$log_file" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    "$PROBE_BIN" \
    >"$stdout_file" 2>"$stderr_file"
  rc=$?
  set -e

  if [[ -f "$log_file" ]]; then
    exception_hits="$({ grep -Ehi 'raise_exception|Illegal instruction|EXCP06|check_exception' "$log_file" "$stderr_file" || true; } | wc -l)"
    vector_hits="$({ grep -Ehi '\b(st_vec|mov_vec)\b' "$log_file" || true; } | wc -l)"
  fi

  if [[ "$rc" -eq 0 && "$exception_hits" -eq 0 && "$vector_hits" -gt 0 ]]; then
    result="PASS"
  fi

  cat <<EOF
scratch_root: $SCRATCH_ROOT
patch_file:   $PATCH_FILE
source_touch: target/i386/tcg/decode-new.c.inc
build_bin:    $BUILD_DIR/qemu-x86_64
probe_bin:    $PROBE_BIN
result:       $result
rc:           $rc
vector_hits:  $vector_hits
exception_hits: $exception_hits
log_file:     $log_file
stderr_file:  $stderr_file
stdout_file:  $stdout_file
EOF

  if [[ "$result" != "PASS" ]]; then
    echo "---- probe stderr ----"
    cat "$stderr_file" || true
    echo "---- qemu log head ----"
    sed -n '1,120p' "$log_file" || true
    return 1
  fi

  echo "---- qemu log head ----"
  sed -n '1,80p' "$log_file"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scratch-root)
      SCRATCH_ROOT="${2:?missing value for --scratch-root}"
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

refresh_paths

if [[ "$FRESH" -eq 1 ]]; then
  log "Removing scratch root $SCRATCH_ROOT"
  rm -rf "$SCRATCH_ROOT"
fi

mkdir -p "$SCRATCH_ROOT"
write_patch_file
ensure_build_tools
download_or_extract_qemu
prepare_patched_tree
configure_qemu
build_qemu
write_probe_source
build_probe
run_probe
