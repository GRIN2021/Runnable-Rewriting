#!/usr/bin/env bash
#
# Build (if needed) and run the QEMU V2 runtime container smoke from the host.
# This is the smallest entry point for reproducing the containerized AVX-512
# probe check without touching the AVX-512 patch series or PTC worker sources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
RUNTIME_DIR="$REPO_ROOT/docker/qemu-v2-runtime"
IMAGE="${RUNNABLE_QEMU_V2_IMAGE:-rr_qemu_v2_runtime:latest}"
SCRATCH_ROOT="${RUNNABLE_QEMU_V2_SMOKE_ROOT:-/tmp/rr-qemu-v2-runtime-smoke}"
QEMU_SRC="${QEMU_V2_SRC:-}"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-$(nproc)}"
DOWNLOAD_QEMU=0
WITH_RUNNABLE_LIFT=0
BUILD_IMAGE=1
PROBES=()

usage() {
  cat <<'EOF'
Usage:
  docker/qemu-v2-runtime/run-smoke.sh [options]

Options:
  --image NAME           Docker image tag. Default: rr_qemu_v2_runtime:latest
  --repo DIR             Runnable-Rewriting checkout. Default: repository root.
  --qemu-src DIR         QEMU 10.2.3 source tree. If omitted, auto-detects a
                         cached /tmp tree or uses --download-qemu.
  --scratch-root DIR     Host scratch root mounted into the container.
                         Default: /tmp/rr-qemu-v2-runtime-smoke
  --probe NAME           Probe to compile and objdump. Repeatable.
                         Default: avx512-evex
  --download-qemu        Let the container smoke download qemu-10.2.3.
  --with-runnable-lift   Enable the optional runnable-lift outer smoke.
  --jobs N               Parallel jobs forwarded to the container smoke.
  --skip-image-build      Reuse an existing image tag.
  -h, --help             Show this help.
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
    --probe)
      if [[ "${PROBES[*]:-}" == "" ]]; then
        PROBES=()
      fi
      PROBES+=("${2:?missing value for --probe}")
      shift 2
      ;;
    --download-qemu)
      DOWNLOAD_QEMU=1
      shift
      ;;
    --with-runnable-lift)
      WITH_RUNNABLE_LIFT=1
      shift
      ;;
    --jobs|-j)
      JOBS="${2:?missing value for --jobs}"
      shift 2
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
      die "unknown argument: $1"
      ;;
  esac
done

if [[ ${#PROBES[@]} -eq 0 ]]; then
  PROBES=(avx512-evex)
fi

if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [[ "$JOBS" -lt 1 ]]; then
  die "--jobs must be a positive integer: $JOBS"
fi

SCRATCH_ROOT="$(resolve_dir "$(mkdir -p "$SCRATCH_ROOT" && printf '%s\n' "$SCRATCH_ROOT")" "scratch root")"
case "$SCRATCH_ROOT" in
  /tmp/*) ;;
  *) die "--scratch-root must resolve under /tmp: $SCRATCH_ROOT" ;;
esac

if [[ -z "$QEMU_SRC" && "$DOWNLOAD_QEMU" -eq 0 ]]; then
  QEMU_SRC="$(auto_detect_qemu_src)" || die "could not auto-detect QEMU 10.2.3; pass --qemu-src or --download-qemu"
fi

if [[ -n "$QEMU_SRC" ]]; then
  case "$QEMU_SRC" in
    "$REPO_ROOT"|"$REPO_ROOT"/*)
      QEMU_SRC_MOUNTED=0
      ;;
    *)
      QEMU_SRC_MOUNTED=1
      ;;
  esac
else
  QEMU_SRC_MOUNTED=0
fi

note "Build image"
echo "IMAGE=$IMAGE"
if [[ "$BUILD_IMAGE" -eq 1 ]]; then
  docker build -t "$IMAGE" "$RUNTIME_DIR"
fi

note "Run container smoke"
docker_run_args=(docker run --rm)
if [[ "$(id -u)" != "0" ]]; then
  docker_run_args+=(--user "$(id -u):$(id -g)" -e HOME=/tmp)
fi
docker_run_args+=(
  -v "$REPO_ROOT:/workspace/Runnable-Rewriting"
  -v "$SCRATCH_ROOT:$SCRATCH_ROOT"
)
if [[ -n "$QEMU_SRC" && "$QEMU_SRC_MOUNTED" -eq 1 ]]; then
  docker_run_args+=(-v "$QEMU_SRC:$QEMU_SRC:ro")
fi

smoke_args=(
  qemu-v2-runtime-smoke
  --repo /workspace/Runnable-Rewriting
  --scratch-root "$SCRATCH_ROOT"
  --jobs "$JOBS"
)
if [[ -n "$QEMU_SRC" ]]; then
  smoke_args+=(--qemu-src "$QEMU_SRC")
else
  smoke_args+=(--download-qemu)
fi
if [[ "$WITH_RUNNABLE_LIFT" -eq 1 ]]; then
  smoke_args+=(--with-runnable-lift)
fi
for probe in "${PROBES[@]}"; do
  smoke_args+=(--probe "$probe")
done

exec "${docker_run_args[@]}" -e RUNNABLE_QEMU_V2_IN_CONTAINER=1 \
  -w /workspace/Runnable-Rewriting \
  "$IMAGE" \
  "${smoke_args[@]}"
