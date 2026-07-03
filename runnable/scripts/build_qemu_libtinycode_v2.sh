#!/usr/bin/env bash
#
# build_qemu_libtinycode_v2.sh - build helper for the QEMU V2 runtime image.
#
# The vanilla upstream linux-user path is implemented. The real
# libtinycode-specific QEMU V2 port remains explicit not-implemented work. A
# separate transition mode builds the current minimal PTC shim stub under /tmp.
#
# Usage:
#   runnable/scripts/build_qemu_libtinycode_v2.sh \
#     --linux-user-only \
#     --qemu-src qemu-v2 \
#     --build-dir build-qemu-v2-linux-user \
#     --install-dir root-qemu-v2-linux-user
#   runnable/scripts/build_qemu_libtinycode_v2.sh \
#     --ptc-shim-stub \
#     --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
RUNTIME_DIR="$RR_DIR/docker/qemu-v2-runtime"
IMAGE="${RUNNABLE_QEMU_V2_IMAGE:-rr_qemu_v2_runtime:latest}"
QEMU_SRC="qemu-v2"
QEMU_SRC_SET=0
BUILD_DIR="build-qemu-v2-linux-user"
INSTALL_DIR="root-qemu-v2-linux-user"
PTC_SHIM_OUT_DIR="${RUNNABLE_QEMU_V2_PTC_SHIM_OUT_DIR:-/tmp/qemu-v2-ptc-shim-build-wrapper}"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-$(nproc)}"
MODE="libtinycode"
USE_DOCKER="auto"
BUILD_IMAGE=1
REPLAY_PAYLOAD=""
REPLAY_MODEL=""
REPLAY_SUMMARY=""

usage() {
  cat <<'EOF'
Usage:
  build_qemu_libtinycode_v2.sh --linux-user-only [options]
  build_qemu_libtinycode_v2.sh --ptc-shim-stub [options]
  build_qemu_libtinycode_v2.sh --libtinycode [options]

Modes:
  --linux-user-only       Configure, build, and install upstream QEMU
                          x86_64-linux-user only.
  --ptc-shim-stub         Build the current minimal PTC shim stub
                          libtinycode-x86_64.so under /tmp and run smoke.
  --libtinycode           Request the libtinycode-specific QEMU V2 build.
                          Builds and installs the live-sidecar libtinycode.

Options:
  --qemu-src DIR          QEMU source tree. Default for --linux-user-only:
                          qemu-v2. For --ptc-shim-stub, an omitted value is
                          auto-detected and must be QEMU 10.2.3.
  --build-dir DIR         Out-of-tree build directory.
                          Default: build-qemu-v2-linux-user
  --install-dir DIR       Install prefix. Default: root-qemu-v2-linux-user
  --ptc-shim-out-dir DIR  Generated shim project directory. Must resolve under
                          /tmp; relative names are placed under /tmp.
                          Default: /tmp/qemu-v2-ptc-shim-build-wrapper
  --image NAME            Docker image for host-side container handoff.
                          Default: rr_qemu_v2_runtime:latest
  --jobs N                Parallel build jobs. Default: nproc
  --replay-payload PATH   Test/developer replay payload for --libtinycode.
  --replay-model PATH     Test/developer replay model JSON for --libtinycode.
  --replay-summary PATH   Test/developer replay summary JSON for --libtinycode.
  --no-docker             Build in the current environment instead of
                          building/running the runtime image.
  --skip-image-build      In host mode, reuse an existing Docker image.
  -h, --help              Show this help.

When run on the host, build modes use the runtime image and re-run the script
inside the container. When run inside the container, pass --no-docker or rely
on container auto-detection.

The --ptc-shim-stub mode is a transition artifact only. It does not migrate
real PTC translation and intentionally prints:
REAL_PTC_TRANSLATION=not-migrated-empty-stub
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

is_container() {
  [[ "${RUNNABLE_QEMU_V2_IN_CONTAINER:-}" == "1" ]]
}

input_to_path() {
  local input="$1"
  if [[ "$input" = /* ]]; then
    printf '%s\n' "$input"
  else
    printf '%s/%s\n' "$RR_DIR" "$input"
  fi
}

resolve_existing_dir() {
  local input="$1"
  local purpose="$2"
  local path
  path="$(input_to_path "$input")"
  [[ -d "$path" ]] || die "$purpose not found: $path"
  (cd "$path" && pwd -P)
}

resolve_output_dir() {
  local input="$1"
  local path
  path="$(input_to_path "$input")"
  mkdir -p "$path"
  (cd "$path" && pwd -P)
}

resolve_tmp_output_dir() {
  local input="$1"
  local raw parent base parent_abs path

  [[ -n "$input" ]] || die "missing temporary output directory"
  if [[ "$input" = /* ]]; then
    raw="$input"
  else
    raw="/tmp/$input"
  fi

  parent="$(dirname "$raw")"
  base="$(basename "$raw")"
  mkdir -p "$parent"
  parent_abs="$(cd "$parent" && pwd -P)"
  path="$(readlink -m "$parent_abs/$base")"

  case "$path" in
    /tmp/*)
      printf '%s\n' "$path"
      ;;
    *)
      die "PTC shim output directory must be below /tmp, got: $path"
      ;;
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

auto_detect_qemu_10_2_3_src() {
  local search_root version_file dir
  local -a candidates=()

  if [[ -n "${QEMU_V2_SRC:-}" ]]; then
    candidates+=("$QEMU_V2_SRC")
  fi

  candidates+=(
    "/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3"
    "/tmp/qemu-10.2.3"
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

repo_relative_path() {
  local abs="$1"
  case "$abs" in
    "$RR_DIR")
      printf '.\n'
      ;;
    "$RR_DIR"/*)
      printf '%s\n' "${abs#"$RR_DIR"/}"
      ;;
    *)
      die "host-side Docker handoff only supports paths under the repository root: $abs"
      ;;
  esac
}

container_repo_path() {
  local abs="$1"
  local rel
  rel="$(repo_relative_path "$abs")"
  if [[ "$rel" == "." ]]; then
    printf '/workspace/Runnable-Rewriting\n'
  else
    printf '/workspace/Runnable-Rewriting/%s\n' "$rel"
  fi
}

build_ptc_shim_stub() {
  local qemu_src_abs out_dir_abs artifact generator

  generator="$SCRIPT_DIR/qemu_v2_make_ptc_shim_tree.sh"
  [[ -f "$generator" ]] || die "PTC shim generator not found: $generator"

  if [[ "$QEMU_SRC_SET" -eq 1 ]]; then
    qemu_src_abs="$(resolve_existing_dir "$QEMU_SRC" "QEMU 10.2.3 source tree")"
  else
    qemu_src_abs="$(auto_detect_qemu_10_2_3_src)" || \
      die "could not auto-detect QEMU 10.2.3 source; pass --qemu-src"
  fi

  is_qemu_10_2_3_tree "$qemu_src_abs" || \
    die "expected QEMU 10.2.3 source with meson.build and executable configure: $qemu_src_abs"

  out_dir_abs="$(resolve_tmp_output_dir "$PTC_SHIM_OUT_DIR")"
  artifact="$out_dir_abs/build/libtinycode-x86_64.so"

  echo "repo root       : $RR_DIR"
  echo "mode            : $MODE"
  echo "qemu src        : $qemu_src_abs"
  echo "shim tree       : $out_dir_abs"
  echo "artifact        : $artifact"
  echo "parallel jobs   : $JOBS"
  echo "REAL_PTC_TRANSLATION=not-migrated-empty-stub"
  echo "translation note: transition stub only; real QEMU V2 PTC translation is not migrated"

  bash "$generator" \
    --qemu-src "$qemu_src_abs" \
    --out-dir "$out_dir_abs" \
    --force

  make -C "$out_dir_abs" clean
  make -C "$out_dir_abs" -j "$JOBS"
  make -C "$out_dir_abs" smoke

  [[ -f "$artifact" ]] || die "expected shim artifact was not produced: $artifact"

  echo "stub shim build ok"
  echo "artifact=$artifact"
  echo "REAL_PTC_TRANSLATION=not-migrated-empty-stub"
}

build_libtinycode_v2() {
  local qemu_src_abs build_dir_abs install_dir_abs scratch_root
  local live_script helper_generator legacy_qemu_dir legacy_header
  local lib_so helper_ir metadata_json sidecar_model sidecar_summary qemu_version
  local -a live_args

  live_script="$SCRIPT_DIR/qemu_v2_ptc_live_sidecar_translate_smoke.sh"
  helper_generator="$SCRIPT_DIR/qemu_v2_generate_libtinycode_helpers.py"
  legacy_qemu_dir="${RUNNABLE_QEMU_LEGACY_SRC:-$RR_DIR/archive/qemu-legacy-2.4.50}"

  [[ -f "$live_script" ]] || die "live-sidecar builder not found: $live_script"
  [[ -f "$helper_generator" ]] || die "helper IR generator not found: $helper_generator"

  qemu_src_abs="$(resolve_existing_dir "$QEMU_SRC" "QEMU 10.2.3 source tree")"
  [[ -f "$qemu_src_abs/meson.build" ]] || die "QEMU 10.2.3 source tree is missing meson.build: $qemu_src_abs"
  [[ -x "$qemu_src_abs/configure" ]] || die "QEMU 10.2.3 source tree is missing executable configure: $qemu_src_abs"
  [[ -f "$qemu_src_abs/VERSION" ]] || die "QEMU 10.2.3 source tree is missing VERSION: $qemu_src_abs"
  qemu_version="$(tr -d '[:space:]' < "$qemu_src_abs/VERSION")"
  [[ "$qemu_version" == "10.2.3" ]] || \
    die "QEMU 10.2.3 source tree expected VERSION=10.2.3, found $qemu_version at $qemu_src_abs"

  build_dir_abs="$(resolve_output_dir "$BUILD_DIR")"
  install_dir_abs="$(resolve_output_dir "$INSTALL_DIR")"
  scratch_root="$build_dir_abs/libtinycode-live-sidecar"
  lib_so="$scratch_root/libtinycode-x86_64.so"
  sidecar_model="$scratch_root/sidecar/sidecar.model.json"
  sidecar_summary="$scratch_root/sidecar/sidecar.summary.json"
  helper_ir="$install_dir_abs/lib/libtinycode-helpers-x86_64.ll"
  metadata_json="$install_dir_abs/share/runnable/qemu-v2-libtinycode.json"
  legacy_header="$legacy_qemu_dir/linux-user/ptc.h"
  [[ -f "$legacy_header" ]] || die "legacy ptc.h header not found: $legacy_header"

  live_args=(
    --scratch-root "$scratch_root"
    --qemu-src "$qemu_src_abs"
    --jobs "$JOBS"
    --fresh
  )
  if [[ -n "$REPLAY_PAYLOAD" ]]; then
    live_args+=(--payload-source "$(input_to_path "$REPLAY_PAYLOAD")")
  fi
  if [[ -n "$REPLAY_MODEL" ]]; then
    live_args+=(--model-source "$(input_to_path "$REPLAY_MODEL")")
  fi
  if [[ -n "$REPLAY_SUMMARY" ]]; then
    live_args+=(--summary-source "$(input_to_path "$REPLAY_SUMMARY")")
  fi

  echo "repo root       : $RR_DIR"
  echo "runtime image   : $IMAGE"
  echo "mode            : $MODE"
  echo "qemu src        : $qemu_src_abs"
  echo "build dir       : $build_dir_abs"
  echo "install dir     : $install_dir_abs"
  echo "scratch root    : $scratch_root"
  echo "parallel jobs   : $JOBS"

  bash "$live_script" "${live_args[@]}"

  [[ -f "$lib_so" ]] || die "live-sidecar libtinycode was not produced: $lib_so"
  [[ -f "$sidecar_model" ]] || die "live-sidecar model was not produced: $sidecar_model"
  [[ -f "$sidecar_summary" ]] || die "live-sidecar summary was not produced: $sidecar_summary"

  mkdir -p "$install_dir_abs/lib" "$install_dir_abs/include" "$install_dir_abs/share/runnable"
  cp "$lib_so" "$install_dir_abs/lib/libtinycode-x86_64.so"
  cp "$legacy_header" "$install_dir_abs/include/ptc.h"

  python3 "$helper_generator" \
    --model-json "$sidecar_model" \
    --output "$helper_ir" \
    --qemu-src "$qemu_src_abs" \
    --library-path "$install_dir_abs/lib/libtinycode-x86_64.so"

  python3 - "$metadata_json" "$qemu_src_abs" "$qemu_version" "$scratch_root" "$install_dir_abs/lib/libtinycode-x86_64.so" "$helper_ir" <<'PY'
import json
import sys
from pathlib import Path

metadata_path = Path(sys.argv[1])
data = {
    "schema": "qemu-v2-libtinycode-build-v1",
    "qemu_src": sys.argv[2],
    "qemu_version": sys.argv[3],
    "implementation_source": "qemu-v2-live-sidecar",
    "abi_version": "2",
    "real_translation": "true",
    "scratch_root": sys.argv[4],
    "library_path": sys.argv[5],
    "helpers_path": sys.argv[6],
}
metadata_path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

  if command -v nm >/dev/null 2>&1; then
    nm -D "$install_dir_abs/lib/libtinycode-x86_64.so" | grep -q ' ptc_load$' || \
      die "installed library does not export ptc_load"
    nm -D "$install_dir_abs/lib/libtinycode-x86_64.so" | grep -q ' ptc_get_abi_metadata$' || \
      die "installed library does not export ptc_get_abi_metadata"
  fi

  python3 - "$install_dir_abs/lib/libtinycode-x86_64.so" <<'PY'
import ctypes
import sys

lib = ctypes.CDLL(sys.argv[1])
lib.ptc_get_abi_metadata.restype = ctypes.c_char_p
metadata = lib.ptc_get_abi_metadata()
if metadata is None:
    raise SystemExit("ptc_get_abi_metadata returned NULL")
text = metadata.decode("utf-8", errors="replace")
for field in ("abi_version=2", "real_translation=true"):
    if field not in text:
        raise SystemExit(f"ptc_get_abi_metadata missing {field}: {text}")
print(text, end="" if text.endswith("\n") else "\n")
PY

  echo "LIBTINYCODE_V2_BUILD_OK=1"
  echo "LIBTINYCODE=$install_dir_abs/lib/libtinycode-x86_64.so"
  echo "LIBTINYCODE_HELPERS=$helper_ir"
  echo "LIBTINYCODE_METADATA=$metadata_json"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --linux-user-only)
      MODE="linux-user-only"
      shift
      ;;
    --ptc-shim-stub)
      MODE="ptc-shim-stub"
      shift
      ;;
    --libtinycode|--with-libtinycode)
      MODE="libtinycode"
      shift
      ;;
    --qemu-src)
      QEMU_SRC="${2:?missing value for --qemu-src}"
      QEMU_SRC_SET=1
      shift 2
      ;;
    --build-dir)
      BUILD_DIR="${2:?missing value for --build-dir}"
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR="${2:?missing value for --install-dir}"
      shift 2
      ;;
    --ptc-shim-out-dir)
      PTC_SHIM_OUT_DIR="${2:?missing value for --ptc-shim-out-dir}"
      shift 2
      ;;
    --image)
      IMAGE="${2:?missing value for --image}"
      shift 2
      ;;
    --jobs|-j)
      JOBS="${2:?missing value for --jobs}"
      shift 2
      ;;
    --replay-payload)
      REPLAY_PAYLOAD="${2:?missing value for --replay-payload}"
      shift 2
      ;;
    --replay-model)
      REPLAY_MODEL="${2:?missing value for --replay-model}"
      shift 2
      ;;
    --replay-summary)
      REPLAY_SUMMARY="${2:?missing value for --replay-summary}"
      shift 2
      ;;
    --no-docker)
      USE_DOCKER="never"
      shift
      ;;
    --skip-image-build)
      BUILD_IMAGE=0
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

if [[ "$MODE" == "libtinycode" ]]; then
  if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [[ "$JOBS" -lt 1 ]]; then
    die "--jobs must be a positive integer: $JOBS"
  fi
  if [[ "$USE_DOCKER" != "never" && ! is_container ]]; then
    QEMU_SRC_ABS="$(resolve_existing_dir "$QEMU_SRC" "QEMU 10.2.3 source tree")"
    BUILD_DIR_ABS="$(resolve_output_dir "$BUILD_DIR")"
    INSTALL_DIR_ABS="$(resolve_output_dir "$INSTALL_DIR")"
    QEMU_SRC_CONTAINER="$(container_repo_path "$QEMU_SRC_ABS")"
    BUILD_DIR_CONTAINER="$(container_repo_path "$BUILD_DIR_ABS")"
    INSTALL_DIR_CONTAINER="$(container_repo_path "$INSTALL_DIR_ABS")"

    if [[ "$BUILD_IMAGE" -eq 1 ]]; then
      docker build -t "$IMAGE" "$RUNTIME_DIR"
    fi

    USER_ARGS=()
    if [[ "$(id -u)" != "0" ]]; then
      USER_ARGS=(--user "$(id -u):$(id -g)" -e HOME=/tmp)
    fi

    DOCKER_ARGS=(
      bash runnable/scripts/build_qemu_libtinycode_v2.sh
      "--$MODE"
      --qemu-src "$QEMU_SRC_CONTAINER"
      --build-dir "$BUILD_DIR_CONTAINER"
      --install-dir "$INSTALL_DIR_CONTAINER"
      --jobs "$JOBS"
    )
    if [[ -n "$REPLAY_PAYLOAD" ]]; then
      DOCKER_ARGS+=(--replay-payload "$(container_repo_path "$(input_to_path "$REPLAY_PAYLOAD")")")
    fi
    if [[ -n "$REPLAY_MODEL" ]]; then
      DOCKER_ARGS+=(--replay-model "$(container_repo_path "$(input_to_path "$REPLAY_MODEL")")")
    fi
    if [[ -n "$REPLAY_SUMMARY" ]]; then
      DOCKER_ARGS+=(--replay-summary "$(container_repo_path "$(input_to_path "$REPLAY_SUMMARY")")")
    fi
    DOCKER_ARGS+=(--no-docker)

    exec docker run --rm \
      "${USER_ARGS[@]}" \
      -e RUNNABLE_QEMU_V2_IN_CONTAINER=1 \
      -v "$RR_DIR":/workspace/Runnable-Rewriting \
      -w /workspace/Runnable-Rewriting \
      "$IMAGE" \
      "${DOCKER_ARGS[@]}"
  fi
  build_libtinycode_v2
  exit 0
fi

if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [[ "$JOBS" -lt 1 ]]; then
  die "--jobs must be a positive integer: $JOBS"
fi

if [[ "$MODE" == "ptc-shim-stub" ]]; then
  build_ptc_shim_stub
  exit 0
fi

QEMU_SRC_ABS="$(resolve_existing_dir "$QEMU_SRC" "QEMU source tree")"
BUILD_DIR_ABS="$(resolve_output_dir "$BUILD_DIR")"
INSTALL_DIR_ABS="$(resolve_output_dir "$INSTALL_DIR")"

[[ -x "$QEMU_SRC_ABS/configure" ]] || die "QEMU configure script not found or not executable: $QEMU_SRC_ABS/configure"
[[ -f "$QEMU_SRC_ABS/meson.build" ]] || die "source tree does not look like modern upstream QEMU; missing: $QEMU_SRC_ABS/meson.build"

echo "repo root     : $RR_DIR"
echo "runtime image  : $IMAGE"
echo "mode           : $MODE"
echo "qemu src       : $QEMU_SRC_ABS"
echo "build dir      : $BUILD_DIR_ABS"
echo "install dir    : $INSTALL_DIR_ABS"
echo "parallel jobs   : $JOBS"

if [[ "$USE_DOCKER" != "never" && ! is_container ]]; then
  QEMU_SRC_CONTAINER="$(container_repo_path "$QEMU_SRC_ABS")"
  BUILD_DIR_CONTAINER="$(container_repo_path "$BUILD_DIR_ABS")"
  INSTALL_DIR_CONTAINER="$(container_repo_path "$INSTALL_DIR_ABS")"

  if [[ "$BUILD_IMAGE" -eq 1 ]]; then
    docker build -t "$IMAGE" "$RUNTIME_DIR"
  fi

  USER_ARGS=()
  if [[ "$(id -u)" != "0" ]]; then
    USER_ARGS=(--user "$(id -u):$(id -g)" -e HOME=/tmp)
  fi

  exec docker run --rm \
    "${USER_ARGS[@]}" \
    -e RUNNABLE_QEMU_V2_IN_CONTAINER=1 \
    -v "$RR_DIR":/workspace/Runnable-Rewriting \
    -w /workspace/Runnable-Rewriting \
    "$IMAGE" \
    bash runnable/scripts/build_qemu_libtinycode_v2.sh \
      --linux-user-only \
      --qemu-src "$QEMU_SRC_CONTAINER" \
      --build-dir "$BUILD_DIR_CONTAINER" \
      --install-dir "$INSTALL_DIR_CONTAINER" \
      --jobs "$JOBS" \
      --no-docker
fi

echo "Inside QEMU V2 build environment"

CONFIGURE_ARGS=(
  "--prefix=$INSTALL_DIR_ABS"
  "--target-list=x86_64-linux-user"
  "--disable-system"
  "--enable-linux-user"
  "--disable-docs"
  "--disable-werror"
)

if [[ -f "$BUILD_DIR_ABS/build.ninja" ]]; then
  echo "Existing build.ninja found; skipping configure. Use a fresh build dir to reconfigure."
else
  (
    cd "$BUILD_DIR_ABS"
    "$QEMU_SRC_ABS/configure" "${CONFIGURE_ARGS[@]}"
  )
fi

ninja -C "$BUILD_DIR_ABS" -j "$JOBS" qemu-x86_64
ninja -C "$BUILD_DIR_ABS" -j "$JOBS" install

QEMU_BIN="$INSTALL_DIR_ABS/bin/qemu-x86_64"
[[ -x "$QEMU_BIN" ]] || die "expected installed binary was not produced: $QEMU_BIN"

"$QEMU_BIN" --version
echo "Installed upstream x86_64 linux-user QEMU: $QEMU_BIN"
