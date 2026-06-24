#!/usr/bin/env bash
#
# Short QEMU V2 container smoke:
#   1. compile and objdump the source-only AVX/AVX-512 probe corpus,
#   2. exercise the build wrapper's transition PTC shim stub path,
#   3. build and dlopen the minimal PTC shim stub.
#
# The full AVX-512 patched QEMU build remains a long-running path documented in
# README.md; this script intentionally keeps the default loop short.
set -euo pipefail

QEMU_VERSION="10.2.3"
QEMU_TARBALL="qemu-${QEMU_VERSION}.tar.xz"
QEMU_URL="https://download.qemu.org/${QEMU_TARBALL}"
QEMU_SHA256="2aa0e420e4ea89ea34a833f4c4eced96a35b51a9ee8568b232692729b60b064d"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="${RUNNABLE_REPO:-}"
SCRATCH_ROOT="${RUNNABLE_QEMU_V2_SMOKE_ROOT:-/tmp/rr-qemu-v2-runtime-smoke}"
QEMU_SRC="${QEMU_V2_SRC:-}"
DOWNLOAD_QEMU=0
WITH_RUNNABLE_LIFT=0
JOBS="${RUNNABLE_QEMU_V2_JOBS:-$(nproc)}"
PROBE_SELECTION=(all)

usage() {
  cat <<'EOF'
Usage:
  qemu-v2-runtime-smoke [options]

Options:
  --repo DIR             Runnable-Rewriting checkout. Default: $RUNNABLE_REPO,
                         an adjacent checkout when run from the repo, or $PWD.
  --scratch-root DIR     Scratch root. Must resolve under /tmp because the PTC
                         shim scripts currently enforce /tmp outputs.
                         Default: /tmp/rr-qemu-v2-runtime-smoke
  --qemu-src DIR         Mounted or preexisting QEMU 10.2.3 source tree for the
                         PTC shim smoke. Also accepted through $QEMU_V2_SRC.
  --download-qemu        Download and verify qemu-10.2.3.tar.xz into the
                         scratch root when --qemu-src is not supplied.
  --probe NAME           Probe to compile/objdump. Repeatable. Default: all.
  --with-runnable-lift   Let the PTC smoke try the optional runnable-lift outer
                         load path. Default skips it for a container-only
                         dlopen/dlsym smoke.
  --jobs N, -j N         Parallel jobs for the PTC wrapper stub build and
                         long-running manual commands. Default: nproc.
  -h, --help             Show this help.

Required short smoke:
  - python3 runnable/scripts/qemu_v2_probe_suite.py --compile --objdump
  - runnable/scripts/build_qemu_libtinycode_v2.sh --ptc-shim-stub
  - runnable/scripts/qemu_v2_ptc_shim_dlopen_smoke.sh --no-runnable-lift

Examples:
  qemu-v2-runtime-smoke --repo /workspace/Runnable-Rewriting \
    --qemu-src /workspace/qemu-10.2.3

  qemu-v2-runtime-smoke --repo /workspace/Runnable-Rewriting --download-qemu
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
  [[ -n "$input" ]] || die "missing $purpose"
  [[ -d "$input" ]] || die "$purpose not found: $input"
  (cd "$input" && pwd -P)
}

resolve_output_dir() {
  local input="$1"
  local raw parent base parent_abs

  [[ -n "$input" ]] || die "missing output directory"
  if [[ "$input" = /* ]]; then
    raw="$input"
  else
    raw="$PWD/$input"
  fi

  parent="$(dirname "$raw")"
  base="$(basename "$raw")"
  mkdir -p "$parent"
  parent_abs="$(cd "$parent" && pwd -P)"
  printf '%s/%s\n' "$parent_abs" "$base"
}

is_qemu_10_2_3_tree() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  [[ -f "$dir/meson.build" ]] || return 1
  [[ -x "$dir/configure" ]] || return 1
  [[ -f "$dir/VERSION" ]] || return 1
  [[ "$(tr -d '[:space:]' < "$dir/VERSION")" == "$QEMU_VERSION" ]]
}

autodetect_repo() {
  local candidate
  local -a candidates=(
    "$SCRIPT_DIR/../.."
    "$PWD"
    "/workspace/Runnable-Rewriting"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate/runnable/scripts/qemu_v2_probe_suite.py" ]]; then
      (cd "$candidate" && pwd -P)
      return 0
    fi
  done

  return 1
}

download_qemu_source() {
  local download_dir="$SCRATCH_ROOT/download"
  local tarball="$download_dir/$QEMU_TARBALL"
  local source_dir="$SCRATCH_ROOT/qemu-${QEMU_VERSION}"

  if is_qemu_10_2_3_tree "$source_dir"; then
    printf '%s\n' "$source_dir"
    return 0
  fi

  command -v curl >/dev/null 2>&1 || die "curl is required for --download-qemu"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required for --download-qemu"
  command -v tar >/dev/null 2>&1 || die "tar is required for --download-qemu"

  mkdir -p "$download_dir"
  if [[ ! -f "$tarball" ]]; then
    note "Download QEMU ${QEMU_VERSION}" >&2
    curl -fL --retry 3 --retry-delay 2 -o "$tarball" "$QEMU_URL"
  fi

  printf '%s  %s\n' "$QEMU_SHA256" "$tarball" | sha256sum -c - >&2
  rm -rf "$source_dir"
  tar -C "$SCRATCH_ROOT" -xf "$tarball"

  is_qemu_10_2_3_tree "$source_dir" || die "downloaded archive did not produce a QEMU ${QEMU_VERSION} source tree"
  printf '%s\n' "$source_dir"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO_DIR="${2:?missing value for --repo}"
      shift 2
      ;;
    --scratch-root)
      SCRATCH_ROOT="${2:?missing value for --scratch-root}"
      shift 2
      ;;
    --qemu-src)
      QEMU_SRC="${2:?missing value for --qemu-src}"
      shift 2
      ;;
    --download-qemu)
      DOWNLOAD_QEMU=1
      shift
      ;;
    --probe)
      if [[ "${PROBE_SELECTION[*]}" == "all" ]]; then
        PROBE_SELECTION=()
      fi
      PROBE_SELECTION+=("${2:?missing value for --probe}")
      shift 2
      ;;
    --with-runnable-lift)
      WITH_RUNNABLE_LIFT=1
      shift
      ;;
    --jobs|-j)
      JOBS="${2:?missing value for --jobs}"
      shift 2
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

if [[ -n "$REPO_DIR" ]]; then
  REPO_DIR="$(resolve_dir "$REPO_DIR" "repository")"
else
  REPO_DIR="$(autodetect_repo)" || die "could not find Runnable-Rewriting checkout; pass --repo"
fi

SCRATCH_ROOT="$(resolve_output_dir "$SCRATCH_ROOT")"
case "$SCRATCH_ROOT" in
  /tmp/*)
    ;;
  *)
    die "--scratch-root must be under /tmp for the current PTC shim smoke: $SCRATCH_ROOT"
    ;;
esac

[[ -f "$REPO_DIR/runnable/scripts/qemu_v2_probe_suite.py" ]] || die "missing probe suite under repository: $REPO_DIR"
[[ -x "$REPO_DIR/runnable/scripts/build_qemu_libtinycode_v2.sh" ]] || die "missing QEMU build wrapper under repository: $REPO_DIR"
[[ -x "$REPO_DIR/runnable/scripts/qemu_v2_ptc_shim_dlopen_smoke.sh" ]] || die "missing PTC dlopen smoke under repository: $REPO_DIR"

mkdir -p "$SCRATCH_ROOT"

if [[ -n "$QEMU_SRC" ]]; then
  QEMU_SRC="$(resolve_dir "$(abs_path "$QEMU_SRC")" "QEMU source tree")"
  is_qemu_10_2_3_tree "$QEMU_SRC" || die "expected QEMU ${QEMU_VERSION} source tree: $QEMU_SRC"
elif [[ "$DOWNLOAD_QEMU" -eq 1 ]]; then
  QEMU_SRC="$(download_qemu_source)"
else
  die "PTC shim smoke requires QEMU ${QEMU_VERSION}; pass --qemu-src, set QEMU_V2_SRC, or use --download-qemu"
fi

note "Environment"
echo "REPO_DIR=$REPO_DIR"
echo "SCRATCH_ROOT=$SCRATCH_ROOT"
echo "QEMU_SRC=$QEMU_SRC"
echo "JOBS=$JOBS"

note "Probe compile/objdump"
PROBE_ARGS=()
for probe in "${PROBE_SELECTION[@]}"; do
  PROBE_ARGS+=(--probe "$probe")
done

python3 "$REPO_DIR/runnable/scripts/qemu_v2_probe_suite.py" \
  "${PROBE_ARGS[@]}" \
  --build-dir "$SCRATCH_ROOT/probes" \
  --compile \
  --objdump

note "PTC shim build-wrapper stub smoke"
PTC_WRAPPER_SHIM_DIR="$SCRATCH_ROOT/ptc-shim-wrapper"
PTC_WRAPPER_LOG="$SCRATCH_ROOT/ptc-shim-wrapper.log"

"$REPO_DIR/runnable/scripts/build_qemu_libtinycode_v2.sh" \
  --ptc-shim-stub \
  --qemu-src "$QEMU_SRC" \
  --ptc-shim-out-dir "$PTC_WRAPPER_SHIM_DIR" \
  --jobs "$JOBS" \
  --no-docker \
  2>&1 | tee "$PTC_WRAPPER_LOG"

grep -q '^REAL_PTC_TRANSLATION=not-migrated-empty-stub$' "$PTC_WRAPPER_LOG" || \
  die "PTC shim build wrapper did not report the expected empty-stub marker"
[[ -f "$PTC_WRAPPER_SHIM_DIR/build/libtinycode-x86_64.so" ]] || \
  die "PTC shim build wrapper did not produce libtinycode-x86_64.so"

note "PTC shim dlopen smoke"
PTC_ARGS=(
  --qemu-src "$QEMU_SRC"
  --out-dir "$SCRATCH_ROOT/ptc-shim"
  --run-dir "$SCRATCH_ROOT/ptc-shim-run"
)
if [[ "$WITH_RUNNABLE_LIFT" -eq 0 ]]; then
  PTC_ARGS+=(--no-runnable-lift)
fi

"$REPO_DIR/runnable/scripts/qemu_v2_ptc_shim_dlopen_smoke.sh" "${PTC_ARGS[@]}"

note "Summary"
echo "QEMU_V2_RUNTIME_SMOKE=pass"
echo "PROBE_BUILD_DIR=$SCRATCH_ROOT/probes"
echo "PTC_WRAPPER_SHIM_DIR=$PTC_WRAPPER_SHIM_DIR"
echo "PTC_WRAPPER_LOG=$PTC_WRAPPER_LOG"
echo "PTC_SHIM_DIR=$SCRATCH_ROOT/ptc-shim"
echo "PTC_RUN_DIR=$SCRATCH_ROOT/ptc-shim-run"
echo "REAL_PTC_TRANSLATION=not-migrated-empty-stub"
