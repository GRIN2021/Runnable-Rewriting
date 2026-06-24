#!/usr/bin/env bash
#
# Generic host-side launcher for the QEMU V2 runtime image.
# It mounts the repo, optional QEMU 10.2.3 source, scratch space under /tmp,
# and then runs an arbitrary command inside the reproducible container.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
RUNTIME_DIR="$REPO_ROOT/docker/qemu-v2-runtime"
IMAGE="${RUNNABLE_QEMU_V2_IMAGE:-rr_qemu_v2_runtime:latest}"
SCRATCH_ROOT="${RUNNABLE_QEMU_V2_SCRATCH_ROOT:-/tmp/rr-qemu-v2-runtime}"
QEMU_SRC="${QEMU_V2_SRC:-}"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-$(nproc)}"
DOWNLOAD_QEMU=0
BUILD_IMAGE=1

declare -a EXTRA_MOUNTS=()
declare -a CONTAINER_CMD=()

usage() {
  cat <<'EOF'
Usage:
  docker/qemu-v2-runtime/run-validation.sh [options] [-- command args...]

Options:
  --image NAME           Docker image tag. Default: rr_qemu_v2_runtime:latest
  --repo DIR             Runnable-Rewriting checkout. Default: repository root.
  --qemu-src DIR         Host QEMU 10.2.3 source tree to mount read-only.
                         If omitted, auto-detects a cached tree unless
                         --download-qemu is given.
  --scratch-root DIR     Host scratch root mounted to the same /tmp path in the
                         container. Default: /tmp/rr-qemu-v2-runtime
  --jobs N               Export RUNNABLE_QEMU_V2_JOBS=N in the container.
  --mount SPEC           Extra bind mount, repeatable. Format:
                         /host/path:/container/path[:ro|rw]
  --download-qemu        Do not mount a host QEMU tree; let the in-container
                         command fetch qemu-10.2.3 when it supports that mode.
  --skip-image-build     Reuse an existing image tag.
  -h, --help             Show this help.

Examples:
  docker/qemu-v2-runtime/run-validation.sh \
    --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
    -- qemu-v2-runtime-smoke --repo /workspace/Runnable-Rewriting \
       --qemu-src /workspace/qemu-10.2.3

  docker/qemu-v2-runtime/run-validation.sh \
    --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
    -- bash runnable/scripts/qemu_v2_avx512_patch_series.sh \
       --qemu-src /workspace/qemu-10.2.3 \
       --scratch-root /tmp/rr-qemu-v2-avx512-patch-series
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

note() {
  printf '\n== %s ==\n' "$*"
}

abs_path() {
  local input="$1"
  if [[ "$input" = /* ]]; then
    printf '%s\n' "$input"
  else
    printf '%s/%s\n' "$PWD" "$input"
  fi
}

resolve_dir() {
  local input="$1"
  local purpose="$2"
  local path

  [[ -n "$input" ]] || die "missing $purpose"
  path="$(abs_path "$input")"
  [[ -d "$path" ]] || die "$purpose not found: $path"
  (cd "$path" && pwd -P)
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
  local candidate
  local -a candidates=(
    "/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3"
    "/tmp/qemu-10.2.3"
    "$REPO_ROOT/../qemu-10.2.3"
    "$REPO_ROOT/qemu-10.2.3"
  )

  for candidate in "${candidates[@]}"; do
    if is_qemu_10_2_3_tree "$candidate"; then
      (cd "$candidate" && pwd -P)
      return 0
    fi
  done

  return 1
}

container_repo_path() {
  local abs="$1"
  case "$abs" in
    "$REPO_ROOT")
      printf '/workspace/Runnable-Rewriting\n'
      ;;
    "$REPO_ROOT"/*)
      printf '/workspace/Runnable-Rewriting/%s\n' "${abs#"$REPO_ROOT"/}"
      ;;
    *)
      die "path is outside repository root and needs --mount instead: $abs"
      ;;
  esac
}

resolve_mount_spec() {
  local spec="$1"
  local host_path container_path mode resolved_host remainder

  host_path="${spec%%:*}"
  remainder="${spec#*:}"
  [[ "$remainder" != "$spec" ]] || die "--mount requires /host:/container[:ro|rw]: $spec"

  container_path="${remainder%%:*}"
  mode="${remainder#"$container_path"}"
  if [[ "$mode" == "$remainder" ]]; then
    mode=""
  fi

  [[ -n "$host_path" ]] || die "--mount missing host path: $spec"
  [[ -n "$container_path" ]] || die "--mount missing container path: $spec"
  resolved_host="$(abs_path "$host_path")"
  [[ -e "$resolved_host" ]] || die "--mount host path not found: $resolved_host"

  case "$mode" in
    ""|:ro|:rw)
      printf '%s:%s%s\n' "$resolved_host" "$container_path" "$mode"
      ;;
    *)
      die "--mount mode must be :ro or :rw: $spec"
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      IMAGE="${2:?missing value for --image}"
      shift 2
      ;;
    --repo)
      REPO_ROOT="$(resolve_dir "${2:?missing value for --repo}" "repository")"
      RUNTIME_DIR="$REPO_ROOT/docker/qemu-v2-runtime"
      shift 2
      ;;
    --qemu-src)
      QEMU_SRC="$(resolve_dir "${2:?missing value for --qemu-src}" "QEMU source tree")"
      shift 2
      ;;
    --scratch-root)
      SCRATCH_ROOT="${2:?missing value for --scratch-root}"
      shift 2
      ;;
    --jobs|-j)
      JOBS="${2:?missing value for --jobs}"
      shift 2
      ;;
    --mount)
      EXTRA_MOUNTS+=("$(resolve_mount_spec "${2:?missing value for --mount}")")
      shift 2
      ;;
    --download-qemu)
      DOWNLOAD_QEMU=1
      shift
      ;;
    --skip-image-build)
      BUILD_IMAGE=0
      shift
      ;;
    --)
      shift
      CONTAINER_CMD=("$@")
      break
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

mkdir -p "$SCRATCH_ROOT"
SCRATCH_ROOT="$(resolve_dir "$SCRATCH_ROOT" "scratch root")"
case "$SCRATCH_ROOT" in
  /tmp/*) ;;
  *) die "--scratch-root must resolve under /tmp: $SCRATCH_ROOT" ;;
esac

if [[ -z "$QEMU_SRC" && "$DOWNLOAD_QEMU" -eq 0 ]]; then
  QEMU_SRC="$(auto_detect_qemu_src)" || die "could not auto-detect QEMU 10.2.3; pass --qemu-src or --download-qemu"
fi

QEMU_SRC_IN_CONTAINER=""
if [[ -n "$QEMU_SRC" ]]; then
  if ! is_qemu_10_2_3_tree "$QEMU_SRC"; then
    die "expected QEMU 10.2.3 source tree: $QEMU_SRC"
  fi
  case "$QEMU_SRC" in
    "$REPO_ROOT"|"$REPO_ROOT"/*)
      QEMU_SRC_IN_CONTAINER="$(container_repo_path "$QEMU_SRC")"
      ;;
    *)
      QEMU_SRC_IN_CONTAINER="/workspace/qemu-10.2.3"
      EXTRA_MOUNTS+=("$QEMU_SRC:$QEMU_SRC_IN_CONTAINER:ro")
      ;;
  esac
fi

if [[ ${#CONTAINER_CMD[@]} -eq 0 ]]; then
  CONTAINER_CMD=(bash)
fi

note "Build image"
echo "IMAGE=$IMAGE"
if [[ "$BUILD_IMAGE" -eq 1 ]]; then
  docker build -t "$IMAGE" "$RUNTIME_DIR"
fi

note "Run validation container"
docker_run_args=(docker run --rm)
if [[ "$(id -u)" != "0" ]]; then
  docker_run_args+=(--user "$(id -u):$(id -g)" -e HOME=/tmp)
fi
docker_run_args+=(
  -e RUNNABLE_QEMU_V2_IN_CONTAINER=1
  -e RUNNABLE_QEMU_V2_JOBS="$JOBS"
  -e RUNNABLE_QEMU_V2_SCRATCH_ROOT="$SCRATCH_ROOT"
  -v "$REPO_ROOT:/workspace/Runnable-Rewriting"
  -v "$SCRATCH_ROOT:$SCRATCH_ROOT"
  -w /workspace/Runnable-Rewriting
)
if [[ -n "$QEMU_SRC_IN_CONTAINER" ]]; then
  docker_run_args+=(-e QEMU_V2_SRC="$QEMU_SRC_IN_CONTAINER")
fi
for mount_spec in "${EXTRA_MOUNTS[@]}"; do
  docker_run_args+=(-v "$mount_spec")
done

exec "${docker_run_args[@]}" "$IMAGE" "${CONTAINER_CMD[@]}"
