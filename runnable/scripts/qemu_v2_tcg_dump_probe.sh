#!/usr/bin/env bash
#
# Throwaway QEMU 10.2.3 TCG op dump probe for the Runnable QEMU V2 port.
#
# All QEMU source/build outputs live under /tmp by default. The only repo input
# is the existing test/qemu-v2-probes corpus and qemu_v2_probe_suite.py.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

QEMU_VERSION="10.2.3"
QEMU_TARBALL="qemu-${QEMU_VERSION}.tar.xz"
QEMU_URL="https://download.qemu.org/${QEMU_TARBALL}"
QEMU_SHA256="2aa0e420e4ea89ea34a833f4c4eced96a35b51a9ee8568b232692729b60b064d"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_TCG_DUMP_ROOT:-/tmp/rr-qemu-v2-tcg-op-dump}"
DOWNLOAD_DIR=""
BASE_SRC=""
PATCHED_SRC=""
BUILD_DIR=""
PROBE_BUILD_DIR=""
OUT_DIR=""
VENV_DIR=""
JOBS="${RUNNABLE_QEMU_V2_JOBS:-3}"
QEMU_CPU_MODEL="${RUNNABLE_QEMU_V2_TCG_DUMP_CPU:-max}"
FRESH=0
SKIP_DOWNLOAD=0
APPLY_PATCH_ONLY=0
BUILD_ONLY=0
RUN_ONLY=0
SHOW_INSTRUCTIONS=0

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_tcg_dump_probe.sh [options]

Options:
  --scratch-root DIR      Scratch root for QEMU source/build/output.
                          Default: /tmp/rr-qemu-v2-tcg-op-dump
  --qemu-src DIR          Existing unpatched QEMU 10.2.3 source tree to copy.
                          Default: download/extract under scratch root.
  --jobs N, -j N          Parallel ninja jobs. Default: 3 or RUNNABLE_QEMU_V2_JOBS.
  --cpu MODEL             QEMU linux-user CPU model. Default: max.
  --fresh                 Remove the patched source, build dir, probe build dir,
                          and output dir before running.
  --skip-download         Require an existing tarball/source tree; do not curl.
  --apply-patch-only      Prepare patched source and patch file, then stop.
  --build-only            Prepare patch and build qemu-x86_64, then stop.
  --run-only              Reuse an existing patched build and only run probes.
  --show-instructions     Print exact manual commands and create the patch file,
                          but do not patch/build/run.
  -h, --help              Show this help.

Outputs:
  $SCRATCH_ROOT/qemu-10.2.3-tcg-dump.patch
  $SCRATCH_ROOT/qemu-10.2.3-tcg-dump-src/
  $SCRATCH_ROOT/build-10.2.3-tcg-dump/qemu-x86_64
  $SCRATCH_ROOT/probes-build/{avx2-vex,avx512-evex}
  $SCRATCH_ROOT/dumps/{avx2-vex,avx512-evex}.tcg-ops.txt
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

abs_path() {
  local input="$1"
  if [[ "$input" = /* ]]; then
    printf '%s\n' "$input"
  else
    printf '%s/%s\n' "$PWD" "$input"
  fi
}

refresh_paths() {
  DOWNLOAD_DIR="$SCRATCH_ROOT/download"
  BASE_SRC="$SCRATCH_ROOT/qemu-${QEMU_VERSION}"
  PATCHED_SRC="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-tcg-dump-src"
  BUILD_DIR="$SCRATCH_ROOT/build-${QEMU_VERSION}-tcg-dump"
  PROBE_BUILD_DIR="$SCRATCH_ROOT/probes-build"
  OUT_DIR="$SCRATCH_ROOT/dumps"
  VENV_DIR="$SCRATCH_ROOT/venv"
}

write_patch() {
  mkdir -p "$SCRATCH_ROOT"
  local patch_file="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-tcg-dump.patch"
  cat >"$patch_file" <<'PATCH'
diff --git a/accel/tcg/translate-all.c b/accel/tcg/translate-all.c
--- a/accel/tcg/translate-all.c
+++ b/accel/tcg/translate-all.c
@@ -238,21 +238,61 @@ static int setjmp_gen_code(CPUArchState *env, TranslationBlock *tb,
                            vaddr pc, void *host_pc,
                            int *max_insns, int64_t *ti)
 {
+    const char *rr_tcg_dump_file;
+    const char *rr_tcg_dump_filter;
+    static FILE *rr_tcg_dump_stream;
+    static bool rr_tcg_dump_checked;
+    bool rr_tcg_dump_this_tb = false;
+
     int ret = sigsetjmp(tcg_ctx->jmp_trans, 0);
     if (unlikely(ret != 0)) {
         return ret;
     }

     tcg_func_start(tcg_ctx);

     CPUState *cs = env_cpu(env);
     tcg_ctx->cpu = cs;
     cs->cc->tcg_ops->translate_code(cs, tb, max_insns, pc, host_pc);

+    if (unlikely(!rr_tcg_dump_checked)) {
+        rr_tcg_dump_checked = true;
+        rr_tcg_dump_file = getenv("RR_TCG_OP_DUMP");
+        if (rr_tcg_dump_file && rr_tcg_dump_file[0]) {
+            rr_tcg_dump_stream = fopen(rr_tcg_dump_file, "w");
+            if (!rr_tcg_dump_stream) {
+                fprintf(stderr, "RR_TCG_OP_DUMP: could not open %s\n",
+                        rr_tcg_dump_file);
+            }
+        }
+    }
+    if (unlikely(rr_tcg_dump_stream)) {
+        rr_tcg_dump_filter = getenv("RR_TCG_OP_DUMP_PC");
+        rr_tcg_dump_this_tb = !rr_tcg_dump_filter || !rr_tcg_dump_filter[0];
+        if (!rr_tcg_dump_this_tb) {
+            unsigned long long rr_tcg_dump_pc = 0;
+
+            if (sscanf(rr_tcg_dump_filter, "%llx", &rr_tcg_dump_pc) == 1) {
+                rr_tcg_dump_this_tb = (pc == (vaddr)rr_tcg_dump_pc);
+            }
+        }
+        if (rr_tcg_dump_this_tb) {
+            fprintf(rr_tcg_dump_stream,
+                    "\n==== rr tcg dump: pc=0x%" VADDR_PRIx
+                    " tb_pc=0x%" VADDR_PRIx
+                    " size=%u icount=%u nb_ops=%d nb_temps=%d nb_globals=%d ====\n",
+                    pc, tb->pc, tb->size, tb->icount, tcg_ctx->nb_ops,
+                    tcg_ctx->nb_temps, tcg_ctx->nb_globals);
+            tcg_dump_ops(tcg_ctx, rr_tcg_dump_stream, false);
+            fputc('\n', rr_tcg_dump_stream);
+            fflush(rr_tcg_dump_stream);
+        }
+    }
+
     assert(tb->size != 0);
     tcg_ctx->cpu = NULL;
     *max_insns = tb->icount;

     return tcg_gen_code(tcg_ctx, tb, pc);
 }
PATCH
  echo "$patch_file"
}

print_manual_instructions() {
  local patch_file="$1"
  cat <<EOF
Patch file created:
  $patch_file

Manual run:
  mkdir -p "$SCRATCH_ROOT"
  cd "$SCRATCH_ROOT"
  curl -L --fail --retry 3 -o "$QEMU_TARBALL" "$QEMU_URL"
  printf '%s  %s\n' "$QEMU_SHA256" "$QEMU_TARBALL" | sha256sum -c -
  tar -xf "$QEMU_TARBALL"
  rm -rf "$PATCHED_SRC"
  cp -a "$BASE_SRC" "$PATCHED_SRC"
  cd "$PATCHED_SRC"
  patch -p1 < "$patch_file"
  mkdir -p "$BUILD_DIR"
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip meson ninja
  cd "$BUILD_DIR"
  PATH="$VENV_DIR/bin:\$PATH" "$PATCHED_SRC/configure" --target-list=x86_64-linux-user --disable-system --disable-tools --disable-docs --disable-gtk --disable-sdl --disable-vnc --disable-curses --disable-slirp --disable-capstone --disable-werror --prefix="$SCRATCH_ROOT/install-$QEMU_VERSION-tcg-dump"
  PATH="$VENV_DIR/bin:\$PATH" ninja -C "$BUILD_DIR" -j "$JOBS" qemu-x86_64
  python3 "$RR_DIR/runnable/scripts/qemu_v2_probe_suite.py" --compile --objdump --build-dir "$PROBE_BUILD_DIR"
  mkdir -p "$OUT_DIR"
  (cd "$OUT_DIR" && ulimit -c 0 && RR_TCG_OP_DUMP="$OUT_DIR/avx2-vex.tcg-ops.txt" RR_TCG_OP_DUMP_PC=\$(nm -n "$PROBE_BUILD_DIR/avx2-vex" | awk '/ _start$/ {print \$1; exit}') "$BUILD_DIR/qemu-x86_64" -cpu "$QEMU_CPU_MODEL" "$PROBE_BUILD_DIR/avx2-vex")
  (cd "$OUT_DIR" && ulimit -c 0 && RR_TCG_OP_DUMP="$OUT_DIR/avx512-evex.tcg-ops.txt" RR_TCG_OP_DUMP_PC=\$(nm -n "$PROBE_BUILD_DIR/avx512-evex" | awk '/ _start$/ {print \$1; exit}') "$BUILD_DIR/qemu-x86_64" -cpu "$QEMU_CPU_MODEL" "$PROBE_BUILD_DIR/avx512-evex")
EOF
}

download_or_extract_qemu() {
  mkdir -p "$DOWNLOAD_DIR"
  if [[ -d "$BASE_SRC" ]]; then
    log "Using existing QEMU source: $BASE_SRC"
    return
  fi

  local tarball="$DOWNLOAD_DIR/$QEMU_TARBALL"
  if [[ ! -f "$tarball" ]]; then
    [[ "$SKIP_DOWNLOAD" -eq 0 ]] || die "missing $tarball and --skip-download was requested"
    require_tool curl
    log "Downloading QEMU $QEMU_VERSION"
    curl -L --fail --retry 3 -o "$tarball" "$QEMU_URL"
  fi

  require_tool sha256sum
  (cd "$DOWNLOAD_DIR" && printf '%s  %s\n' "$QEMU_SHA256" "$QEMU_TARBALL" | sha256sum -c -)

  log "Extracting QEMU source"
  tar -C "$SCRATCH_ROOT" -xf "$tarball"
  [[ -x "$BASE_SRC/configure" ]] || die "QEMU configure not found after extraction: $BASE_SRC/configure"
}

copy_source() {
  local source="$1"
  [[ -d "$source" ]] || die "QEMU source tree not found: $source"
  [[ -x "$source/configure" ]] || die "QEMU configure not found or not executable: $source/configure"
  [[ -f "$source/meson.build" ]] || die "QEMU source does not look like a modern QEMU tree: $source"

  if [[ -d "$PATCHED_SRC" ]]; then
    if [[ -f "$PATCHED_SRC/.rr-tcg-dump-patched" ]]; then
      log "Using existing patched source: $PATCHED_SRC"
      return
    fi
    die "patched source exists but was not created by this script: $PATCHED_SRC"
  fi

  log "Copying QEMU source to throwaway patched tree"
  cp -a "$source" "$PATCHED_SRC"
}

apply_qemu_patch() {
  local patch_file="$1"
  if [[ -f "$PATCHED_SRC/.rr-tcg-dump-patched" ]]; then
    return
  fi
  require_tool patch
  log "Applying TCG dump patch"
  (cd "$PATCHED_SRC" && patch -p1 <"$patch_file")
  touch "$PATCHED_SRC/.rr-tcg-dump-patched"
}

setup_build_tools() {
  require_tool python3
  if command -v meson >/dev/null 2>&1 && command -v ninja >/dev/null 2>&1; then
    return
  fi

  log "Preparing Meson/Ninja venv under $VENV_DIR"
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip meson ninja
  export PATH="$VENV_DIR/bin:$PATH"
}

build_qemu() {
  setup_build_tools
  require_tool ninja
  mkdir -p "$BUILD_DIR"

  local configure_args=(
    "--target-list=x86_64-linux-user"
    "--disable-system"
    "--disable-tools"
    "--disable-docs"
    "--disable-gtk"
    "--disable-sdl"
    "--disable-vnc"
    "--disable-curses"
    "--disable-slirp"
    "--disable-capstone"
    "--disable-werror"
    "--prefix=$SCRATCH_ROOT/install-$QEMU_VERSION-tcg-dump"
  )

  if [[ -f "$BUILD_DIR/build.ninja" ]]; then
    log "Existing build.ninja found; skipping configure"
  else
    log "Configuring patched QEMU"
    (cd "$BUILD_DIR" && "$PATCHED_SRC/configure" "${configure_args[@]}")
  fi

  log "Building qemu-x86_64"
  ninja -C "$BUILD_DIR" -j "$JOBS" qemu-x86_64
  [[ -x "$BUILD_DIR/qemu-x86_64" ]] || die "expected QEMU binary missing: $BUILD_DIR/qemu-x86_64"
  "$BUILD_DIR/qemu-x86_64" --version
}

probe_entry_pc() {
  local binary="$1"
  require_tool nm
  local pc
  pc="$(nm -n "$binary" | awk '/ _start$/ {print $1; exit}')"
  [[ -n "$pc" ]] || die "could not find _start symbol in $binary"
  printf '%s\n' "$pc"
}

run_one_probe() {
  local probe="$1"
  local binary="$PROBE_BUILD_DIR/$probe"
  local dump_file="$OUT_DIR/$probe.tcg-ops.txt"
  local run_log="$OUT_DIR/$probe.run.log"
  local pc

  [[ -x "$binary" ]] || die "probe binary missing: $binary"
  pc="$(probe_entry_pc "$binary")"

  log "Running $probe with RR_TCG_OP_DUMP_PC=0x$pc"
  set +e
  (
    cd "$OUT_DIR"
    ulimit -c 0
    RR_TCG_OP_DUMP="$dump_file" \
    RR_TCG_OP_DUMP_PC="$pc" \
      "$BUILD_DIR/qemu-x86_64" -cpu "$QEMU_CPU_MODEL" "$binary"
  ) >"$run_log" 2>&1
  local rc=$?
  set -e

  printf '%s\n' "$rc" >"$OUT_DIR/$probe.exit-code"
  if [[ -s "$run_log" ]]; then
    sed -n '1,80p' "$run_log"
  fi

  if [[ -s "$dump_file" ]]; then
    local op_lines
    op_lines="$(grep -Ec '^[[:space:]]+[A-Za-z0-9_]+|^[[:space:]]*----' "$dump_file" || true)"
    log "$probe dump: $dump_file ($op_lines op/marker-looking lines, qemu rc=$rc)"
    sed -n '1,80p' "$dump_file"
  else
    log "$probe produced no dump at $dump_file (qemu rc=$rc)"
  fi
}

run_probes() {
  require_tool python3
  mkdir -p "$PROBE_BUILD_DIR" "$OUT_DIR"

  log "Compiling and objdump-checking existing Runnable probes"
  python3 "$RR_DIR/runnable/scripts/qemu_v2_probe_suite.py" \
    --compile \
    --objdump \
    --build-dir "$PROBE_BUILD_DIR"

  run_one_probe avx2-vex
  run_one_probe avx512-evex

  cat <<EOF

Results:
  QEMU binary: $BUILD_DIR/qemu-x86_64
  AVX2 dump:  $OUT_DIR/avx2-vex.tcg-ops.txt
  AVX512 dump:$OUT_DIR/avx512-evex.tcg-ops.txt
  Exit codes: $OUT_DIR/*.exit-code
  Run logs:   $OUT_DIR/*.run.log
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scratch-root)
      SCRATCH_ROOT="$(abs_path "${2:?missing value for --scratch-root}")"
      shift 2
      ;;
    --qemu-src)
      BASE_SRC="$(abs_path "${2:?missing value for --qemu-src}")"
      shift 2
      ;;
    --jobs|-j)
      JOBS="${2:?missing value for --jobs}"
      shift 2
      ;;
    --cpu)
      QEMU_CPU_MODEL="${2:?missing value for --cpu}"
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
    --apply-patch-only)
      APPLY_PATCH_ONLY=1
      shift
      ;;
    --build-only)
      BUILD_ONLY=1
      shift
      ;;
    --run-only)
      RUN_ONLY=1
      shift
      ;;
    --show-instructions)
      SHOW_INSTRUCTIONS=1
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
USER_BASE_SRC="$BASE_SRC"
refresh_paths
if [[ -n "$USER_BASE_SRC" ]]; then
  BASE_SRC="$USER_BASE_SRC"
fi

PATCH_FILE="$(write_patch)"

if [[ "$SHOW_INSTRUCTIONS" -eq 1 ]]; then
  print_manual_instructions "$PATCH_FILE"
  exit 0
fi

if [[ "$FRESH" -eq 1 ]]; then
  log "Removing throwaway generated directories under $SCRATCH_ROOT"
  rm -rf "$PATCHED_SRC" "$BUILD_DIR" "$PROBE_BUILD_DIR" "$OUT_DIR"
fi

if [[ "$RUN_ONLY" -eq 0 ]]; then
  if [[ -z "$USER_BASE_SRC" ]]; then
    download_or_extract_qemu
  fi
  copy_source "$BASE_SRC"
  apply_qemu_patch "$PATCH_FILE"

  if [[ "$APPLY_PATCH_ONLY" -eq 1 ]]; then
    log "Patched source is ready: $PATCHED_SRC"
    exit 0
  fi

  build_qemu

  if [[ "$BUILD_ONLY" -eq 1 ]]; then
    log "Patched QEMU binary is ready: $BUILD_DIR/qemu-x86_64"
    exit 0
  fi
else
  [[ -x "$BUILD_DIR/qemu-x86_64" ]] || die "--run-only requires existing binary: $BUILD_DIR/qemu-x86_64"
fi

run_probes
