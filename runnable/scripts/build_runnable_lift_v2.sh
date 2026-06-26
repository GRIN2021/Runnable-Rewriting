#!/usr/bin/env bash
#
# Build runnable-lift for the QEMU V2 migration line.
#
# Host mode builds/runs the qemu-v2 runtime Docker image and re-enters this
# script inside the container. Container mode performs the real CMake configure
# and builds the build-tree runnable-lift target used by the libcrypto tests.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
RUNTIME_DIR="$RR_DIR/docker/qemu-v2-runtime"
IMAGE="${RUNNABLE_QEMU_V2_IMAGE:-rr_qemu_v2_runtime:latest}"
BUILD_DIR="build-codex-dynamic-current"
LLVM_ROOT=""
LLVM_ROOT_EXPLICIT=0
LLVM_DIR_OVERRIDE="${RUNNABLE_LLVM_DIR:-}"
QEMU_INSTALL_PATH="/usr"
BUILD_TYPE="Debug"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-$(nproc)}"
USE_DOCKER="auto"
BUILD_IMAGE=1
RUN_VERIFY=0

usage() {
  cat <<'EOF'
Usage:
  runnable/scripts/build_runnable_lift_v2.sh [options]

Options:
  --build-dir DIR         Build directory. Default: build-codex-dynamic-current
  --llvm-root DIR         LLVM/Clang prefix with lib/cmake/llvm.
                          No default. Explicit values are used instead of
                          llvm-config/system paths; root remains supported.
  --llvm-dir DIR          Exact LLVM CMake directory. Overrides RUNNABLE_LLVM_DIR
                          and --llvm-root.
  --qemu-install-path DIR Include prefix for QEMU headers. Default: /usr
  --build-type TYPE       CMake build type. Default: Debug
  --image NAME            Docker image tag for host mode.
                          Default: rr_qemu_v2_runtime:latest
  --jobs N, -j N          Parallel build jobs. Default: nproc
  --no-docker             Build in the current environment.
  --skip-image-build      Reuse an existing Docker image in host mode.
  --verify                After build, run ldd and --help smoke checks.
  -h, --help              Show this help.

Default host command:
  runnable/scripts/build_runnable_lift_v2.sh

Equivalent in-container command:
  runnable/scripts/build_runnable_lift_v2.sh --no-docker

The canonical artifact is the build-tree binary:
  <build-dir>/tools/runnable-lift/runnable-lift

Direct execution from outside the build tree usually needs LD_LIBRARY_PATH:
  <build-dir>/lib/StackAnalysis:<build-dir>/lib/BasicAnalyses:<build-dir>/lib/Support:<llvm-lib-dir>
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

note() {
  printf '\n== %s ==\n' "$*"
}

is_container() {
  [[ "${RUNNABLE_QEMU_V2_IN_CONTAINER:-}" == "1" ]]
}

abs_path() {
  local input="$1"
  if [[ "$input" = /* ]]; then
    printf '%s\n' "$input"
  else
    printf '%s/%s\n' "$RR_DIR" "$input"
  fi
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
      die "Docker handoff only supports paths under the repository root: $abs"
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

container_path_or_passthrough() {
  local abs="$1"
  case "$abs" in
    "$RR_DIR"|"$RR_DIR"/*)
      container_repo_path "$abs"
      ;;
    *)
      printf '%s\n' "$abs"
      ;;
  esac
}

find_llvm_config_tool() {
  local tool
  for tool in llvm-config llvm-config-18 llvm-config-17 llvm-config-16; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf '%s\n' "$tool"
      return 0
    fi
  done
  return 1
}

find_llvm_cmake_dir() {
  local candidate
  for candidate in "$@"; do
    [[ -n "$candidate" ]] || continue
    if [[ -f "$candidate/LLVMConfig.cmake" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

resolve_llvm_dir() {
  local llvm_root_abs="$1"
  local llvm_root_explicit="$2"
  local llvm_dir_override_abs="$3"
  local candidate llvm_config_tool llvm_config_dir
  local -a candidates=()

  if [[ -n "$llvm_dir_override_abs" ]]; then
    candidates+=("$llvm_dir_override_abs")
    if find_llvm_cmake_dir "${candidates[@]}"; then
      return 0
    fi
  elif [[ "$llvm_root_explicit" -eq 1 ]]; then
    candidates+=(
      "$llvm_root_abs/lib/cmake/llvm"
      "$llvm_root_abs/share/llvm/cmake"
    )
    if find_llvm_cmake_dir "${candidates[@]}"; then
      return 0
    fi
  else
    if llvm_config_tool="$(find_llvm_config_tool)"; then
      llvm_config_dir="$("$llvm_config_tool" --cmakedir 2>/dev/null || true)"
      if [[ -n "$llvm_config_dir" ]]; then
        candidates+=("$llvm_config_dir")
      fi
    fi

    candidates+=(
      /usr/lib/llvm-18/lib/cmake/llvm
      /usr/lib/llvm-18/cmake
      /usr/lib/cmake/llvm
      /usr/share/llvm/cmake
      /usr/local/lib/cmake/llvm
      /usr/local/share/llvm/cmake
      "$RR_DIR/root/lib/cmake/llvm"
      "$RR_DIR/root/share/llvm/cmake"
    )

    if find_llvm_cmake_dir "${candidates[@]}"; then
      return 0
    fi
  fi

  {
    echo "LLVM CMake directory not found."
    echo "Checked:"
    for candidate in "${candidates[@]}"; do
      echo "  $candidate"
    done
    echo "Set RUNNABLE_LLVM_DIR or pass --llvm-dir <dir-containing-LLVMConfig.cmake> if your LLVM install uses a different layout."
  } >&2
  exit 1
}

resolve_llvm_lib_dir() {
  local llvm_dir="$1"
  local candidate llvm_config_tool llvm_config_dir llvm_config_lib_dir
  local -a candidates=()

  case "$llvm_dir" in
    */lib/cmake/llvm)
      candidates+=("${llvm_dir%/cmake/llvm}")
      ;;
    */share/llvm/cmake)
      candidates+=("${llvm_dir%/share/llvm/cmake}/lib")
      ;;
    */cmake)
      candidates+=("${llvm_dir%/cmake}/lib")
      ;;
  esac

  if llvm_config_tool="$(find_llvm_config_tool)"; then
    llvm_config_dir="$("$llvm_config_tool" --cmakedir 2>/dev/null || true)"
    llvm_config_lib_dir="$("$llvm_config_tool" --libdir 2>/dev/null || true)"
    if [[ -n "$llvm_config_lib_dir" && ( -z "$llvm_config_dir" || "$llvm_config_dir" == "$llvm_dir" ) ]]; then
      candidates+=("$llvm_config_lib_dir")
    fi
  fi

  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if [[ "${#candidates[@]}" -gt 0 ]]; then
    printf '%s\n' "${candidates[0]}"
    return 0
  fi

  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir)
      BUILD_DIR="${2:?missing value for --build-dir}"
      shift 2
      ;;
    --llvm-root)
      LLVM_ROOT="${2:?missing value for --llvm-root}"
      LLVM_ROOT_EXPLICIT=1
      shift 2
      ;;
    --llvm-dir)
      LLVM_DIR_OVERRIDE="${2:?missing value for --llvm-dir}"
      shift 2
      ;;
    --qemu-install-path)
      QEMU_INSTALL_PATH="${2:?missing value for --qemu-install-path}"
      shift 2
      ;;
    --build-type)
      BUILD_TYPE="${2:?missing value for --build-type}"
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
    --no-docker)
      USE_DOCKER="never"
      shift
      ;;
    --skip-image-build)
      BUILD_IMAGE=0
      shift
      ;;
    --verify)
      RUN_VERIFY=1
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

if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [[ "$JOBS" -lt 1 ]]; then
  die "--jobs must be a positive integer: $JOBS"
fi

BUILD_DIR_ABS="$(abs_path "$BUILD_DIR")"
LLVM_ROOT_ABS=""
if [[ "$LLVM_ROOT_EXPLICIT" -eq 1 ]]; then
  LLVM_ROOT_ABS="$(abs_path "$LLVM_ROOT")"
fi
LLVM_DIR_OVERRIDE_ABS=""
if [[ -n "$LLVM_DIR_OVERRIDE" ]]; then
  LLVM_DIR_OVERRIDE_ABS="$(abs_path "$LLVM_DIR_OVERRIDE")"
fi

[[ -f "$RR_DIR/runnable/CMakeLists.txt" ]] || die "missing runnable/CMakeLists.txt under $RR_DIR"

if [[ "$USE_DOCKER" != "never" && ! is_container ]]; then
  BUILD_DIR_CONTAINER="$(container_repo_path "$BUILD_DIR_ABS")"
  LLVM_ROOT_CONTAINER=""
  if [[ "$LLVM_ROOT_EXPLICIT" -eq 1 ]]; then
    LLVM_ROOT_CONTAINER="$(container_path_or_passthrough "$LLVM_ROOT_ABS")"
  fi
  LLVM_DIR_CONTAINER=""
  if [[ -n "$LLVM_DIR_OVERRIDE_ABS" ]]; then
    LLVM_DIR_CONTAINER="$(container_path_or_passthrough "$LLVM_DIR_OVERRIDE_ABS")"
  fi

  note "Build image"
  echo "IMAGE=$IMAGE"
  if [[ "$BUILD_IMAGE" -eq 1 ]]; then
    docker build -t "$IMAGE" "$RUNTIME_DIR"
  fi

  USER_ARGS=()
  if [[ "$(id -u)" != "0" ]]; then
    USER_ARGS=(--user "$(id -u):$(id -g)" -e HOME=/tmp)
  fi

  DOCKER_CMD=(
    docker run --rm
    "${USER_ARGS[@]}"
    -e RUNNABLE_QEMU_V2_IN_CONTAINER=1
    -e RUNNABLE_QEMU_V2_JOBS="$JOBS"
    -v "$RR_DIR":/workspace/Runnable-Rewriting
    -w /workspace/Runnable-Rewriting
    "$IMAGE"
    bash runnable/scripts/build_runnable_lift_v2.sh
      --build-dir "$BUILD_DIR_CONTAINER"
      --qemu-install-path "$QEMU_INSTALL_PATH"
      --build-type "$BUILD_TYPE"
      --jobs "$JOBS"
      --no-docker
  )
  if [[ -n "$LLVM_ROOT_CONTAINER" ]]; then
    DOCKER_CMD+=(--llvm-root "$LLVM_ROOT_CONTAINER")
  fi
  if [[ -n "$LLVM_DIR_CONTAINER" ]]; then
    DOCKER_CMD+=(--llvm-dir "$LLVM_DIR_CONTAINER")
  fi
  if [[ "$RUN_VERIFY" -eq 1 ]]; then
    DOCKER_CMD+=(--verify)
  fi
  exec "${DOCKER_CMD[@]}"
fi

LLVM_DIR="$(resolve_llvm_dir "$LLVM_ROOT_ABS" "$LLVM_ROOT_EXPLICIT" "$LLVM_DIR_OVERRIDE_ABS")"
LLVM_LIB_DIR="$(resolve_llvm_lib_dir "$LLVM_DIR" || true)"

mkdir -p "$BUILD_DIR_ABS"

note "Configure runnable-lift"
echo "repo root         : $RR_DIR"
echo "build dir         : $BUILD_DIR_ABS"
echo "llvm dir          : $LLVM_DIR"
echo "llvm lib dir      : ${LLVM_LIB_DIR:-<not resolved>}"
echo "qemu install path : $QEMU_INSTALL_PATH"
echo "build type        : $BUILD_TYPE"
echo "parallel jobs     : $JOBS"

cmake -S "$RR_DIR/runnable" -B "$BUILD_DIR_ABS" \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DCMAKE_INSTALL_PREFIX="$BUILD_DIR_ABS/install" \
  -DQEMU_INSTALL_PATH="$QEMU_INSTALL_PATH" \
  -DLLVM_DIR="$LLVM_DIR"

note "Build runnable-lift"
cmake --build "$BUILD_DIR_ABS" --target runnable-lift -- -j"$JOBS"

ARTIFACT="$BUILD_DIR_ABS/tools/runnable-lift/runnable-lift"
[[ -x "$ARTIFACT" ]] || die "expected runnable-lift artifact was not produced: $ARTIFACT"

LD_PATH="$BUILD_DIR_ABS/lib/StackAnalysis:$BUILD_DIR_ABS/lib/BasicAnalyses:$BUILD_DIR_ABS/lib/Support"
if [[ -n "$LLVM_LIB_DIR" ]]; then
  LD_PATH="$LD_PATH:$LLVM_LIB_DIR"
fi

if [[ "$RUN_VERIFY" -eq 1 ]]; then
  note "Verify runnable-lift"
  LD_LIBRARY_PATH="$LD_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$ARTIFACT"
  LD_LIBRARY_PATH="$LD_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$ARTIFACT" --help >/dev/null
fi

note "Summary"
echo "BUILD_OK=1"
echo "RUNNABLE_LIFT=$ARTIFACT"
echo "LD_LIBRARY_PATH=$LD_PATH"
