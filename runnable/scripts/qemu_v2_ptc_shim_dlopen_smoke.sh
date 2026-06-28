#!/usr/bin/env bash
#
# Build the minimal QEMU V2 PTC shim stub under /tmp, verify its dynamic ABI,
# and optionally try the outer runnable-lift load path without modifying
# runnable-lift sources.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

QEMU_SRC="${QEMU_V2_SRC:-}"
OUT_DIR="/tmp/qemu-v2-ptc-shim-dlopen-smoke"
RUN_DIR="/tmp/qemu-v2-ptc-shim-dlopen-smoke-run"
RUNNABLE_LIFT_BIN=""
DO_RUNNABLE_LIFT=1

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_ptc_shim_dlopen_smoke.sh [options]

Options:
  --qemu-src DIR       QEMU 10.2.3 source tree. Defaults to $QEMU_V2_SRC or
                       an auto-detected /tmp QEMU 10.2.3 tree.
  --out-dir DIR        Generated shim project directory under /tmp.
                       Default: /tmp/qemu-v2-ptc-shim-dlopen-smoke
  --run-dir DIR        Temporary harness/run directory under /tmp.
                       Default: /tmp/qemu-v2-ptc-shim-dlopen-smoke-run
  --runnable-lift BIN  runnable-lift binary to probe. Defaults to the current
                       build-codex-dynamic-current build-tree binary.
  --no-runnable-lift   Skip the optional runnable-lift outer smoke.
  -h, --help           Show this help.

Required success:
  - generator builds build/libtinycode-x86_64.so,
  - dlopen succeeds,
  - dlsym("ptc_load") and dlsym("ptc_translate") succeed,
  - optional ABI metadata symbols resolve and match the empty-stub contract,
  - ptc_load and ptc_translate are callable,
  - the empty PTCInstructionList result is safely freeable.

Optional runnable-lift smoke:
  Attempts to run runnable-lift from a /tmp directory whose libtinycode-x86_64.so
  is the generated stub. A failure after ptc_translate is classified as the
  expected empty-translation boundary, not as a real translation success.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

note() {
  printf '\n== %s ==\n' "$*"
}

resolve_output_dir() {
  local path="$1"
  local parent base parent_abs

  [[ -n "$path" ]] || die "missing output path"
  if [[ "$path" != /* ]]; then
    path="$PWD/$path"
  fi
  parent="$(dirname "$path")"
  base="$(basename "$path")"
  mkdir -p "$parent"
  parent_abs="$(cd "$parent" && pwd -P)"
  path="$parent_abs/$base"

  case "$path" in
    /tmp/*) printf '%s\n' "$path" ;;
    *) die "temporary output path must be under /tmp: $path" ;;
  esac
}

is_qemu_10_2_3_tree() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  [[ -f "$dir/meson.build" ]] || return 1
  [[ -x "$dir/configure" ]] || return 1
  [[ -f "$dir/VERSION" ]] || return 1
  [[ "$(tr -d '[:space:]' < "$dir/VERSION")" == "10.2.3" ]]
}

auto_detect_qemu_src() {
  local search_root version_file dir
  local -a candidates=(
    "/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3"
    "/tmp/rr-qemu-v2-evex-vpxorq-smoke-script-test/qemu-10.2.3"
    "/tmp/rr-qemu-v2-evex-vpxorq-smoke-script-test2/qemu-10.2.3"
    "/tmp/rr-qemu-v2-evex-move-smoke-dev/qemu-10.2.3"
    "$RR_DIR/../qemu-10.2.3"
    "$RR_DIR/qemu-10.2.3"
  )

  for dir in "${candidates[@]}"; do
    if is_qemu_10_2_3_tree "$dir"; then
      (cd "$dir" && pwd -P)
      return 0
    fi
  done

  for search_root in /tmp "$RR_DIR/.."; do
    [[ -d "$search_root" ]] || continue
    while IFS= read -r version_file; do
      dir="$(dirname "$version_file")"
      if is_qemu_10_2_3_tree "$dir"; then
        (cd "$dir" && pwd -P)
        return 0
      fi
    done < <(find "$search_root" -maxdepth 5 -type f -name VERSION -path '*qemu*' -print 2>/dev/null)
  done

  return 1
}

find_runnable_lift() {
  local candidate
  local -a candidates=(
    "$RR_DIR/build-codex-dynamic-current/tools/runnable-lift/runnable-lift"
    "$RR_DIR/build-codex-dynamic-current/runnable-lift"
    "$RR_DIR/build-codex-dynamic/tools/runnable-lift/runnable-lift"
    "$RR_DIR/build-codex-dynamic/runnable-lift"
    "$RR_DIR/build-bionic/runnable-lift"
    "$RR_DIR/runnable/tools/runnable-lift/runnable-lift"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      (cd "$(dirname "$candidate")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$candidate")")
      return 0
    fi
  done

  return 1
}

append_ld_dir() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    if [[ -n "${RUNNABLE_LIFT_LD_LIBRARY_PATH:-}" ]]; then
      RUNNABLE_LIFT_LD_LIBRARY_PATH="$RUNNABLE_LIFT_LD_LIBRARY_PATH:$dir"
    else
      RUNNABLE_LIFT_LD_LIBRARY_PATH="$dir"
    fi
  fi
}

build_runnable_lift_ld_library_path() {
  local binary="$1"
  local binary_dir build_root

  binary_dir="$(cd "$(dirname "$binary")" && pwd -P)"
  RUNNABLE_LIFT_LD_LIBRARY_PATH=""

  case "$binary_dir" in
    "$RR_DIR"/*/tools/runnable-lift)
      build_root="$(cd "$binary_dir/../.." && pwd -P)"
      append_ld_dir "$build_root/lib/StackAnalysis"
      append_ld_dir "$build_root/lib/BasicAnalyses"
      append_ld_dir "$build_root/lib/Support"
      ;;
    "$RR_DIR"/build-*)
      build_root="$binary_dir"
      append_ld_dir "$build_root/lib/StackAnalysis"
      append_ld_dir "$build_root/lib/BasicAnalyses"
      append_ld_dir "$build_root/lib/Support"
      ;;
  esac

  if command -v llvm-config >/dev/null 2>&1; then
    append_ld_dir "$(llvm-config --libdir)"
  fi
  append_ld_dir "$RR_DIR/root/lib"
  printf '%s\n' "$RUNNABLE_LIFT_LD_LIBRARY_PATH"
}

find_companion_file() {
  local name="$1"
  local binary_dir="$2"
  local candidate
  local -a candidates=(
    "$binary_dir/$name"
    "$RR_DIR/runnable/tools/runnable-lift/$name"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      (cd "$(dirname "$candidate")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$candidate")")
      return 0
    fi
  done

  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --qemu-src)
      QEMU_SRC="${2:?missing value for --qemu-src}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:?missing value for --out-dir}"
      shift 2
      ;;
    --run-dir)
      RUN_DIR="${2:?missing value for --run-dir}"
      shift 2
      ;;
    --runnable-lift)
      RUNNABLE_LIFT_BIN="${2:?missing value for --runnable-lift}"
      shift 2
      ;;
    --no-runnable-lift)
      DO_RUNNABLE_LIFT=0
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

OUT_DIR="$(resolve_output_dir "$OUT_DIR")"
RUN_DIR="$(resolve_output_dir "$RUN_DIR")"

if [[ -n "$QEMU_SRC" ]]; then
  [[ -d "$QEMU_SRC" ]] || die "QEMU source tree not found: $QEMU_SRC"
  QEMU_SRC="$(cd "$QEMU_SRC" && pwd -P)"
  is_qemu_10_2_3_tree "$QEMU_SRC" || die "expected a QEMU 10.2.3 source tree with meson.build and executable configure: $QEMU_SRC"
else
  QEMU_SRC="$(auto_detect_qemu_src)" || die "could not auto-detect QEMU 10.2.3; pass --qemu-src or set QEMU_V2_SRC"
fi

rm -rf "$OUT_DIR" "$RUN_DIR"
mkdir -p "$RUN_DIR"

note "Generate and build stub"
"$SCRIPT_DIR/qemu_v2_make_ptc_shim_tree.sh" \
  --qemu-src "$QEMU_SRC" \
  --out-dir "$OUT_DIR" \
  --force

make -C "$OUT_DIR" clean all
make -C "$OUT_DIR" smoke

STUB_LIB="$OUT_DIR/build/libtinycode-x86_64.so"
[[ -f "$STUB_LIB" ]] || die "stub library was not built: $STUB_LIB"

note "Extra dlopen/dlsym smoke"
cat > "$RUN_DIR/ptc_shim_dlopen_smoke.c" <<'EOF'
#include <dlfcn.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define USE_DYNAMIC_PTC 1
#include "ptc_standalone.h"

typedef const char *(*ptc_get_abi_metadata_ptr_t)(void);

static int require_pointer(const void *pointer, const char *name)
{
  if (pointer != NULL) {
    return 0;
  }
  fprintf(stderr, "missing pointer: %s\n", name);
  return 1;
}

static int require_metadata_line(const char *metadata, const char *field)
{
  const char *cursor = metadata;
  const size_t field_len = strlen(field);

  while (cursor != NULL && *cursor != '\0') {
    const char *line_end = strchr(cursor, '\n');
    const size_t line_len = line_end != NULL
        ? (size_t) (line_end - cursor)
        : strlen(cursor);

    if (line_len == field_len && strncmp(cursor, field, field_len) == 0) {
      return 0;
    }

    cursor = line_end != NULL ? line_end + 1 : NULL;
  }

  fprintf(stderr, "metadata missing required line: %s\n", field);
  return 1;
}

static int verify_optional_metadata(void *handle)
{
  const char *metadata_symbol = NULL;
  const char *metadata_from_getter = NULL;
  const char *error = NULL;
  ptc_get_abi_metadata_ptr_t get_metadata = NULL;

  dlerror();
  metadata_symbol = (const char *) dlsym(handle, "ptc_abi_metadata");
  error = dlerror();
  if (error != NULL || metadata_symbol == NULL) {
    fprintf(stderr,
            "missing optional ABI metadata symbol ptc_abi_metadata: %s\n",
            error != NULL ? error : "symbol resolved to NULL");
    return 1;
  }

  dlerror();
  get_metadata = (ptc_get_abi_metadata_ptr_t)
      dlsym(handle, "ptc_get_abi_metadata");
  error = dlerror();
  if (error != NULL || get_metadata == NULL) {
    fprintf(stderr,
            "missing optional ABI metadata function ptc_get_abi_metadata: %s\n",
            error != NULL ? error : "symbol resolved to NULL");
    return 1;
  }

  metadata_from_getter = get_metadata();
  if (metadata_from_getter == NULL) {
    fputs("ptc_get_abi_metadata returned NULL\n", stderr);
    return 1;
  }

  if (strcmp(metadata_symbol, metadata_from_getter) != 0) {
    fputs("metadata symbol and getter returned different content\n", stderr);
    return 1;
  }

  if (require_metadata_line(metadata_symbol, "abi_version=2") != 0 ||
      require_metadata_line(metadata_symbol, "stub_kind=empty_stub") != 0 ||
      require_metadata_line(metadata_symbol, "real_translation=false") != 0 ||
      require_metadata_line(metadata_symbol, "vector_schema=false") != 0) {
    return 1;
  }

  return 0;
}

static int verify_empty_translation(ptc_translate_ptr_t translate,
                                    uint64_t pc,
                                    const char *source)
{
  PTCInstructionList list = { 0 };
  uint64_t dynamic_pc = 0;
  size_t consumed = translate(pc, 1, &list, &dynamic_pc);

  if (consumed != 0) {
    fprintf(stderr, "%s returned non-empty size: %zu\n", source, consumed);
    ptc_instruction_list_free(&list);
    return 1;
  }
  if (dynamic_pc != pc) {
    fprintf(stderr,
            "%s changed dynamic pc: expected 0x%" PRIx64 ", got 0x%" PRIx64 "\n",
            source,
            pc,
            dynamic_pc);
    ptc_instruction_list_free(&list);
    return 1;
  }
  if (list.instruction_count != 0 ||
      list.instructions != NULL ||
      list.arguments != NULL ||
      list.temps != NULL) {
    fprintf(stderr, "%s did not return an empty instruction list\n", source);
    ptc_instruction_list_free(&list);
    return 1;
  }

  ptc_instruction_list_free(&list);
  return 0;
}

int main(int argc, char **argv)
{
  const char *library_path = argc > 1 ? argv[1] : "build/libtinycode-x86_64.so";
  void *handle = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
  ptc_load_ptr_t ptc_load = NULL;
  ptc_translate_ptr_t ptc_translate = NULL;
  PTCInterface ptc = { 0 };

  if (handle == NULL) {
    fprintf(stderr, "dlopen failed for %s: %s\n", library_path, dlerror());
    return 1;
  }

  ptc_load = (ptc_load_ptr_t) dlsym(handle, "ptc_load");
  if (ptc_load == NULL) {
    fprintf(stderr, "dlsym(ptc_load) failed: %s\n", dlerror());
    dlclose(handle);
    return 1;
  }

  ptc_translate = (ptc_translate_ptr_t) dlsym(handle, "ptc_translate");
  if (ptc_translate == NULL) {
    fprintf(stderr, "dlsym(ptc_translate) failed: %s\n", dlerror());
    dlclose(handle);
    return 1;
  }

  if (verify_optional_metadata(handle) != 0) {
    dlclose(handle);
    return 1;
  }

  if (ptc_load(handle, &ptc, "/tmp/qemu-v2-ptc-shim-dlopen-smoke-input", "") != 0) {
    fprintf(stderr, "ptc_load returned failure\n");
    dlclose(handle);
    return 1;
  }

  if (require_pointer(ptc.translate, "PTCInterface.translate") != 0 ||
      require_pointer(ptc.opcode_defs, "PTCInterface.opcode_defs") != 0 ||
      require_pointer(ptc.helper_defs, "PTCInterface.helper_defs") != 0 ||
      require_pointer(ptc.initialized_env, "PTCInterface.initialized_env") != 0 ||
      require_pointer(ptc.regs, "PTCInterface.regs") != 0 ||
      require_pointer(ptc.ElfStartStack, "PTCInterface.ElfStartStack") != 0) {
    dlclose(handle);
    return 1;
  }

  if (verify_empty_translation(ptc_translate, 0x401000u, "dlsym(ptc_translate)") != 0 ||
      verify_empty_translation(ptc.translate, 0x402000u, "PTCInterface.translate") != 0) {
    dlclose(handle);
    return 1;
  }

  printf("dlopen smoke ok: ptc_load=%p ptc_translate=%p iface_translate=%p metadata=abi_version=2,empty_stub helper_defs_size=%u stack_top=0x%" PRIx64 "\n",
         (void *) ptc_load,
         (void *) ptc_translate,
         (void *) ptc.translate,
         ptc.helper_defs_size,
         *ptc.ElfStartStack);

  dlclose(handle);
  return 0;
}
EOF

cc -I"$OUT_DIR/include" -I"$OUT_DIR/src" \
  -O2 -g -std=c11 -Wall -Wextra -Wno-unused-parameter \
  -o "$RUN_DIR/ptc_shim_dlopen_smoke" \
  "$RUN_DIR/ptc_shim_dlopen_smoke.c" \
  -ldl
"$RUN_DIR/ptc_shim_dlopen_smoke" "$STUB_LIB" | tee "$RUN_DIR/ptc_shim_dlopen_smoke.log"

RUNNABLE_LIFT_RESULT="skipped"
RUNNABLE_LIFT_STATUS="n/a"

if [[ "$DO_RUNNABLE_LIFT" -eq 1 ]]; then
  note "Optional runnable-lift outer smoke"

  if [[ -n "$RUNNABLE_LIFT_BIN" ]]; then
    [[ -x "$RUNNABLE_LIFT_BIN" ]] || die "requested runnable-lift is not executable: $RUNNABLE_LIFT_BIN"
    RUNNABLE_LIFT_BIN="$(cd "$(dirname "$RUNNABLE_LIFT_BIN")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$RUNNABLE_LIFT_BIN")")"
  elif ! RUNNABLE_LIFT_BIN="$(find_runnable_lift)"; then
    RUNNABLE_LIFT_RESULT="blocked:no-runnable-lift"
    echo "RUNNABLE_LIFT_SMOKE=$RUNNABLE_LIFT_RESULT"
  fi

  if [[ "$RUNNABLE_LIFT_RESULT" == "skipped" ]]; then
    RUNNABLE_LIFT_SRC_DIR="$(dirname "$RUNNABLE_LIFT_BIN")"
    if ! HELPERS_LL="$(find_companion_file "libtinycode-helpers-x86_64.ll" "$RUNNABLE_LIFT_SRC_DIR")"; then
      RUNNABLE_LIFT_RESULT="blocked:missing-libtinycode-helpers-x86_64.ll"
      echo "RUNNABLE_LIFT_SMOKE=$RUNNABLE_LIFT_RESULT"
    elif ! EARLY_LL="$(find_companion_file "early-linked-x86_64.ll" "$RUNNABLE_LIFT_SRC_DIR")"; then
      RUNNABLE_LIFT_RESULT="blocked:missing-early-linked-x86_64.ll"
      echo "RUNNABLE_LIFT_SMOKE=$RUNNABLE_LIFT_RESULT"
    elif ! command -v cc >/dev/null 2>&1; then
      RUNNABLE_LIFT_RESULT="blocked:missing-cc"
      echo "RUNNABLE_LIFT_SMOKE=$RUNNABLE_LIFT_RESULT"
    elif ! command -v readelf >/dev/null 2>&1 && ! command -v llvm-readelf >/dev/null 2>&1; then
      RUNNABLE_LIFT_RESULT="blocked:missing-readelf"
      echo "RUNNABLE_LIFT_SMOKE=$RUNNABLE_LIFT_RESULT"
    else
      LIFT_RUN_DIR="$RUN_DIR/runnable-lift"
      LIFT_LD_LIBRARY_PATH="$(build_runnable_lift_ld_library_path "$RUNNABLE_LIFT_BIN")"
      mkdir -p "$LIFT_RUN_DIR"
      cp "$RUNNABLE_LIFT_BIN" "$LIFT_RUN_DIR/runnable-lift"
      cp "$HELPERS_LL" "$LIFT_RUN_DIR/libtinycode-helpers-x86_64.ll"
      cp "$EARLY_LL" "$LIFT_RUN_DIR/early-linked-x86_64.ll"
      cp "$STUB_LIB" "$LIFT_RUN_DIR/libtinycode-x86_64.so"

      cat > "$LIFT_RUN_DIR/probe.c" <<'EOF'
int main(void)
{
  return 0;
}
EOF
      cc -O0 -g -fno-pie -no-pie -o "$LIFT_RUN_DIR/probe" "$LIFT_RUN_DIR/probe.c"

      if command -v readelf >/dev/null 2>&1; then
        ENTRY="$(readelf -h "$LIFT_RUN_DIR/probe" | awk '/Entry point address:/ {print $4}')"
      else
        ENTRY="$(llvm-readelf -h "$LIFT_RUN_DIR/probe" | awk '/Entry point address:/ {print $4}')"
      fi

      [[ -n "$ENTRY" ]] || die "could not read ELF entry point from $LIFT_RUN_DIR/probe"

      set +e
      if command -v timeout >/dev/null 2>&1; then
        LD_LIBRARY_PATH="$LIFT_LD_LIBRARY_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        timeout 20s "$LIFT_RUN_DIR/runnable-lift" \
          -entry "$ENTRY" \
          "$LIFT_RUN_DIR/probe" \
          "$LIFT_RUN_DIR/probe.bc" \
          >"$LIFT_RUN_DIR/runnable-lift.stdout" \
          2>"$LIFT_RUN_DIR/runnable-lift.stderr"
      else
        LD_LIBRARY_PATH="$LIFT_LD_LIBRARY_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$LIFT_RUN_DIR/runnable-lift" \
          -entry "$ENTRY" \
          "$LIFT_RUN_DIR/probe" \
          "$LIFT_RUN_DIR/probe.bc" \
          >"$LIFT_RUN_DIR/runnable-lift.stdout" \
          2>"$LIFT_RUN_DIR/runnable-lift.stderr"
      fi
      RUNNABLE_LIFT_STATUS="$?"
      set -e

      if [[ "$RUNNABLE_LIFT_STATUS" -eq 0 ]]; then
        RUNNABLE_LIFT_RESULT="completed:unexpected-with-empty-translation"
      elif [[ "$RUNNABLE_LIFT_STATUS" -eq 124 ]]; then
        RUNNABLE_LIFT_RESULT="blocked:timeout"
      elif grep -q "qemu-v2 PTC shim stub: ptc_translate" "$LIFT_RUN_DIR/runnable-lift.stderr"; then
        RUNNABLE_LIFT_RESULT="boundary:empty-translation"
      elif grep -Eq "Couldn't (load the PTC library|find libtinycode|find PTC functions|find ptc_load)" "$LIFT_RUN_DIR/runnable-lift.stderr"; then
        RUNNABLE_LIFT_RESULT="blocked:load-path"
      else
        RUNNABLE_LIFT_RESULT="blocked:failed-before-stub-translate"
      fi

      echo "RUNNABLE_LIFT_ENTRY=$ENTRY"
      echo "RUNNABLE_LIFT_EXIT=$RUNNABLE_LIFT_STATUS"
      echo "RUNNABLE_LIFT_SMOKE=$RUNNABLE_LIFT_RESULT"
      echo "RUNNABLE_LIFT_LD_LIBRARY_PATH=$LIFT_LD_LIBRARY_PATH"
      echo "RUNNABLE_LIFT_STDERR=$LIFT_RUN_DIR/runnable-lift.stderr"
      sed -n '1,80p' "$LIFT_RUN_DIR/runnable-lift.stderr"
    fi
  fi
fi

note "Summary"
echo "QEMU_SRC=$QEMU_SRC"
echo "SHIM_DIR=$OUT_DIR"
echo "STUB_LIB=$STUB_LIB"
echo "DLOPEN_DLSYM_SMOKE=pass"
echo "PTC_ABI_METADATA_SMOKE=pass"
echo "RUNNABLE_LIFT_SMOKE=$RUNNABLE_LIFT_RESULT"
echo "RUNNABLE_LIFT_EXIT=$RUNNABLE_LIFT_STATUS"
echo "REAL_PTC_TRANSLATION=not-migrated-empty-stub"
