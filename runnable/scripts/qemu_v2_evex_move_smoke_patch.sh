#!/usr/bin/env bash
#
# Throwaway QEMU 10.2.3 EVEX register-move smoke patch experiment.
#
# All QEMU source/build/probe outputs stay under /tmp.  The patch is an
# exact-byte experiment for:
#   62 f1 fd 48 ef c0    vpxorq zmm0,zmm0,zmm0
#   62 f1 fd 48 6f c8    vmovdqa64 zmm1,zmm0
#
# It builds qemu-x86_64 and runs the existing single-instruction probes in
# test/qemu-v2-probes through runnable/scripts/qemu_v2_probe_suite.py.
set -euo pipefail

QEMU_VERSION="10.2.3"
QEMU_TARBALL="qemu-${QEMU_VERSION}.tar.xz"
QEMU_URL="https://download.qemu.org/${QEMU_TARBALL}"
QEMU_SHA256="2aa0e420e4ea89ea34a833f4c4eced96a35b51a9ee8568b232692729b60b064d"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE_SUITE="$REPO_ROOT/runnable/scripts/qemu_v2_probe_suite.py"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_EVEX_MOVE_SMOKE_ROOT:-/tmp/rr-qemu-v2-evex-move-smoke}"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-3}"
FRESH=0
SKIP_DOWNLOAD=0
QEMU_TARBALL_PATH=""

DOWNLOAD_DIR=""
BASE_SRC=""
PATCHED_SRC=""
BUILD_DIR=""
INSTALL_DIR=""
PATCH_FILE=""
OUT_DIR=""
PROBE_BUILD_DIR=""
VENV_DIR=""

PROBES=(avx512-vpxorq avx512-vmovdqa64)

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_evex_move_smoke_patch.sh [options]

Options:
  --scratch-root DIR     Scratch root under /tmp.
                         Default: /tmp/rr-qemu-v2-evex-move-smoke
  --qemu-tarball FILE    Reuse an existing qemu-10.2.3.tar.xz.
  --jobs N, -j N         Parallel ninja jobs. Default: 3
  --fresh                Remove the scratch root before starting.
  --skip-download        Reuse an existing tarball/source tree; do not curl.
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
  DOWNLOAD_DIR="$SCRATCH_ROOT/download"
  BASE_SRC="$SCRATCH_ROOT/qemu-${QEMU_VERSION}"
  PATCHED_SRC="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-move-smoke-src"
  BUILD_DIR="$SCRATCH_ROOT/build-${QEMU_VERSION}-evex-move-smoke"
  INSTALL_DIR="$SCRATCH_ROOT/install-${QEMU_VERSION}-evex-move-smoke"
  PATCH_FILE="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-move-smoke.patch"
  OUT_DIR="$SCRATCH_ROOT/out"
  PROBE_BUILD_DIR="$SCRATCH_ROOT/probes-build"
  VENV_DIR="$SCRATCH_ROOT/venv"
}

write_patch_file() {
  mkdir -p "$SCRATCH_ROOT"
  cat >"$PATCH_FILE" <<'PATCH'
diff --git a/target/i386/tcg/decode-new.c.inc b/target/i386/tcg/decode-new.c.inc
--- a/target/i386/tcg/decode-new.c.inc
+++ b/target/i386/tcg/decode-new.c.inc
@@ -2533,6 +2533,66 @@
  * Convert one instruction. s->base.is_jmp is set if the translation must
  * be stopped.
  */
+static bool rr_evex_exact_bytes(DisasContext *s, CPUX86State *env,
+                                target_ulong pc, const uint8_t *insn,
+                                int len)
+{
+#ifdef TARGET_X86_64
+    int i;
+
+    if (!CODE64(s)) {
+        return false;
+    }
+    for (i = 0; i < len; i++) {
+        if (translator_ldub(env, &s->base, pc + i) != insn[i]) {
+            return false;
+        }
+    }
+    return true;
+#else
+    return false;
+#endif
+}
+
+static bool rr_try_evex_move_smoke(DisasContext *s, CPUX86State *env)
+{
+#ifdef TARGET_X86_64
+    static const uint8_t vpxorq_zmm0_zmm0_zmm0[] = {
+        0x62, 0xf1, 0xfd, 0x48, 0xef, 0xc0
+    };
+    static const uint8_t vmovdqa64_zmm1_zmm0[] = {
+        0x62, 0xf1, 0xfd, 0x48, 0x6f, 0xc8
+    };
+    target_ulong pc = s->pc;
+
+    /*
+     * Throwaway smoke semantics for vpxorq zmm0,zmm0,zmm0 only.  This is not
+     * a general EVEX decoder and intentionally ignores masking and CPUID.
+     */
+    if (rr_evex_exact_bytes(s, env, pc, vpxorq_zmm0_zmm0_zmm0,
+                            sizeof(vpxorq_zmm0_zmm0_zmm0))) {
+        tcg_gen_gvec_dup_imm(MO_64, offsetof(CPUX86State, xmm_regs[0]),
+                             64, 64, 0);
+        s->pc = pc + sizeof(vpxorq_zmm0_zmm0_zmm0);
+        return true;
+    }
+
+    /*
+     * Throwaway smoke semantics for vmovdqa64 zmm1,zmm0 only.  This proves a
+     * ZMM register-register move can emit non-raising TCG before full EVEX
+     * decode is available.
+     */
+    if (rr_evex_exact_bytes(s, env, pc, vmovdqa64_zmm1_zmm0,
+                            sizeof(vmovdqa64_zmm1_zmm0))) {
+        tcg_gen_gvec_mov(MO_64, offsetof(CPUX86State, xmm_regs[1]),
+                         offsetof(CPUX86State, xmm_regs[0]), 64, 64);
+        s->pc = pc + sizeof(vmovdqa64_zmm1_zmm0);
+        return true;
+    }
+#endif
+    return false;
+}
+
 static void disas_insn(DisasContext *s, CPUState *cpu)
 {
     CPUX86State *env = cpu_env(cpu);
@@ -2556,6 +2616,10 @@
     s->has_modrm = false;
     s->prefix = 0;

+    if (rr_try_evex_move_smoke(s, env)) {
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

download_or_extract_qemu() {
  mkdir -p "$DOWNLOAD_DIR"
  if [[ -d "$BASE_SRC" ]]; then
    log "Using existing source tree $BASE_SRC"
    return
  fi

  local tarball="$DOWNLOAD_DIR/$QEMU_TARBALL"
  if [[ -n "$QEMU_TARBALL_PATH" ]]; then
    [[ -f "$QEMU_TARBALL_PATH" ]] || die "missing --qemu-tarball file: $QEMU_TARBALL_PATH"
    log "Copying $QEMU_TARBALL_PATH"
    cp "$QEMU_TARBALL_PATH" "$tarball"
  elif [[ ! -f "$tarball" ]]; then
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
    if [[ -f "$PATCHED_SRC/.rr-evex-move-smoke-patched" ]]; then
      log "Using existing patched source tree $PATCHED_SRC"
      return
    fi
    die "patched tree exists without stamp: $PATCHED_SRC"
  fi

  log "Copying throwaway source tree"
  cp -a "$BASE_SRC" "$PATCHED_SRC"

  require_tool patch
  log "Applying EVEX move smoke patch"
  (cd "$PATCHED_SRC" && patch -p1 <"$PATCH_FILE")
  touch "$PATCHED_SRC/.rr-evex-move-smoke-patched"
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

run_one_probe() {
  local probe="$1"
  local suite_stdout="$OUT_DIR/${probe}.probe-suite.stdout"
  local suite_stderr="$OUT_DIR/${probe}.probe-suite.stderr"
  local qemu_stdout="$OUT_DIR/${probe}.qemu-debug.stdout"
  local qemu_stderr="$OUT_DIR/${probe}.qemu-debug.stderr"
  local qemu_log="$OUT_DIR/${probe}.qemu-debug.log"
  local suite_rc=0
  local debug_rc=0
  local exception_hits=0
  local vector_hits=0
  local result="FAIL"

  log "Running probe-suite for $probe"
  set +e
  python3 "$PROBE_SUITE" \
    --build-dir "$PROBE_BUILD_DIR" \
    --probe "$probe" \
    --compile \
    --objdump \
    --qemu-x86_64 "$BUILD_DIR/qemu-x86_64" \
    >"$suite_stdout" 2>"$suite_stderr"
  suite_rc=$?
  set -e

  if [[ "$suite_rc" -eq 0 ]]; then
    log "Collecting TCG op log for $probe"
    set +e
    QEMU_LOG_FILENAME="$qemu_log" \
      "$BUILD_DIR/qemu-x86_64" \
      -d in_asm,op,int \
      "$PROBE_BUILD_DIR/$probe" \
      >"$qemu_stdout" 2>"$qemu_stderr"
    debug_rc=$?
    set -e
  fi

  if [[ -f "$qemu_log" ]]; then
    exception_hits="$({ grep -Ehi 'raise_exception|Illegal instruction|EXCP06|check_exception' "$qemu_log" "$qemu_stderr" || true; } | wc -l)"
    vector_hits="$({ grep -Ehi '\b(ld_vec|st_vec|mov_vec)\b' "$qemu_log" || true; } | wc -l)"
  fi

  if [[ "$suite_rc" -eq 0 && "$debug_rc" -eq 0 && "$exception_hits" -eq 0 && "$vector_hits" -gt 0 ]]; then
    result="PASS"
  fi

  cat <<EOF
probe:        $probe
result:       $result
suite_rc:     $suite_rc
debug_rc:     $debug_rc
vector_hits:  $vector_hits
exception_hits: $exception_hits
suite_stdout: $suite_stdout
suite_stderr: $suite_stderr
qemu_log:     $qemu_log
EOF

  if [[ "$result" != "PASS" ]]; then
    echo "---- $probe probe-suite stdout ----"
    sed -n '1,120p' "$suite_stdout" || true
    echo "---- $probe probe-suite stderr ----"
    sed -n '1,120p' "$suite_stderr" || true
    echo "---- $probe qemu debug stderr ----"
    sed -n '1,120p' "$qemu_stderr" || true
    echo "---- $probe qemu log head ----"
    sed -n '1,120p' "$qemu_log" || true
    return 1
  fi

  echo "---- $probe qemu log vector ops ----"
  grep -En '\b(ld_vec|st_vec|mov_vec)\b' "$qemu_log" | head -20 || true
  return 0
}

run_probes() {
  mkdir -p "$OUT_DIR" "$PROBE_BUILD_DIR"

  local failures=0
  for probe in "${PROBES[@]}"; do
    if ! run_one_probe "$probe"; then
      failures=$((failures + 1))
    fi
  done

  cat <<EOF
scratch_root: $SCRATCH_ROOT
patch_file:   $PATCH_FILE
source_touch: target/i386/tcg/decode-new.c.inc
build_bin:    $BUILD_DIR/qemu-x86_64
probe_build:  $PROBE_BUILD_DIR
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

[[ -x "$PROBE_SUITE" ]] || die "missing probe suite: $PROBE_SUITE"

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
run_probes
