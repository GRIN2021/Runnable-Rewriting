#!/usr/bin/env bash
#
# Diagnose where runnable-lift hangs when consuming the live-sidecar
# libtinycode-x86_64.so. This reuses the staged smoke setup, then runs the
# consumer under a short watchdog with strace and lightweight process-tree
# sampling.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_PTC_LIVE_SIDECAR_RUNNABLE_LIFT_TRACE_ROOT:-/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-trace}"
LIBRARY_PATH="${RUNNABLE_QEMU_V2_PTC_LIVE_SIDECAR_LIBRARY:-/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/libtinycode-x86_64.so}"
RUNNABLE_LIFT_BIN="${RUNNABLE_LIFT_BIN:-}"
TIMEOUT_SEC="${RUNNABLE_QEMU_V2_PTC_LIVE_SIDECAR_RUNNABLE_LIFT_TRACE_TIMEOUT_SEC:-10}"
REPLAY_TRANSLATE_LIB="${RUNNABLE_QEMU_V2_PTC_LIVE_SIDECAR_REPLAY_TRANSLATE_LIB:-1}"
FRESH=0

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_ptc_live_sidecar_runnable_lift_trace.sh [options]

Options:
  --scratch-root DIR  Output scratch root.
                      Default: /tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-trace
  --library PATH      Live-sidecar libtinycode-x86_64.so to stage.
                      Default: /tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/libtinycode-x86_64.so
  --runnable-lift BIN runnable-lift binary to probe.
                      Defaults to a local build-tree binary. Passing the
                      source-tree runnable/tools/runnable-lift/runnable-lift
                      is allowed but treated as a stale-binary risk.
  --timeout-sec N     Short watchdog for the traced consumer run.
                      Default: 10
  --no-replay-library
                      Skip rebuilding a replay-backed live-sidecar library from
                      adjacent sidecar payload/model/summary artifacts.
  --fresh             Remove the scratch root before running.
  -h, --help          Show this help.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

abs_path() {
  local input="$1"
  if [[ "$input" = /* ]]; then
    printf '%s\n' "$input"
  else
    printf '%s/%s\n' "$PWD" "$input"
  fi
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

prepare_replay_library() {
  local library_dir payload_source model_source summary_source replay_root replay_summary replay_library replay_log
  library_dir="$(dirname "$LIBRARY_PATH")"
  payload_source="$library_dir/sidecar/sidecar.payload.txt"
  model_source="$library_dir/sidecar/sidecar.model.json"
  summary_source="$library_dir/sidecar/sidecar.summary.json"

  if [[ "$REPLAY_TRANSLATE_LIB" != "1" ]]; then
    return 0
  fi
  if [[ ! -f "$payload_source" || ! -f "$model_source" || ! -f "$summary_source" ]]; then
    return 0
  fi

  replay_root="$SCRATCH_ROOT/replay-translate"
  replay_summary="$replay_root/qemu_v2_ptc_live_sidecar_translate_smoke.summary.json"
  replay_library="$replay_root/libtinycode-x86_64.so"
  replay_log="$SCRATCH_ROOT/replay-translate.rebuild.log"
  mkdir -p "$replay_root"

  log "Rebuilding replay-backed live-sidecar library for runnable-lift trace"
  if ! bash "$RR_DIR/runnable/scripts/qemu_v2_ptc_live_sidecar_translate_smoke.sh" \
      --scratch-root "$replay_root" \
      --payload-source "$payload_source" \
      --model-source "$model_source" \
      --summary-source "$summary_source" \
      --fresh >"$replay_log" 2>&1; then
    cat >"$SUMMARY_JSON" <<EOF
{
  "scratch_root": "$SCRATCH_ROOT",
  "library_path": "$LIBRARY_PATH",
  "replay_translate_root": "$replay_root",
  "replay_rebuild_log_path": "$replay_log",
  "replay_translate_log": "$replay_log",
  "replay_payload_source": "$payload_source",
  "replay_model_source": "$model_source",
  "replay_summary_source": "$summary_source",
  "timeout_sec": $TIMEOUT_SEC,
  "result": "blocked:replay-library-rebuild",
  "trace_conclusion": "replay translate rebuild failed before runnable-lift launch",
  "stderr": "$replay_log"
}
EOF
    cat "$replay_log"
    exit 1
  fi

  [[ -f "$replay_summary" ]] || die "missing replay translate summary after rebuild: $replay_summary"
  [[ -f "$replay_library" ]] || die "missing replay translate library after rebuild: $replay_library"
  LIBRARY_PATH="$replay_library"
}

find_runnable_lift() {
  local candidate
  local -a candidates=(
    "$RR_DIR/build-codex-dynamic-current/runnable-lift"
    "$RR_DIR/build-codex-dynamic/runnable-lift"
    "$RR_DIR/build-bionic/runnable-lift"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      (cd "$(dirname "$candidate")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$candidate")")
      return 0
    fi
  done

  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scratch-root)
      SCRATCH_ROOT="$(abs_path "${2:?missing value for --scratch-root}")"
      shift 2
      ;;
    --library)
      LIBRARY_PATH="$(abs_path "${2:?missing value for --library}")"
      shift 2
      ;;
    --runnable-lift)
      RUNNABLE_LIFT_BIN="$(abs_path "${2:?missing value for --runnable-lift}")"
      shift 2
      ;;
    --timeout-sec)
      TIMEOUT_SEC="${2:?missing value for --timeout-sec}"
      shift 2
      ;;
    --no-replay-library)
      REPLAY_TRANSLATE_LIB=0
      shift
      ;;
    --fresh)
      FRESH=1
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

if ! [[ "$TIMEOUT_SEC" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_SEC" -lt 1 ]]; then
  die "--timeout-sec must be a positive integer: $TIMEOUT_SEC"
fi

SCRATCH_ROOT="$(abs_path "$SCRATCH_ROOT")"
LIBRARY_PATH="$(abs_path "$LIBRARY_PATH")"
RUN_DIR="$SCRATCH_ROOT/run"
TRACE_ROOT="$SCRATCH_ROOT/trace"
SUMMARY_JSON="$SCRATCH_ROOT/qemu_v2_ptc_live_sidecar_runnable_lift_trace.summary.json"
TRACE_SUMMARY="$TRACE_ROOT/trace.summary.txt"
PROCESS_TREE_LOG="$TRACE_ROOT/process-tree.log"
PROBE_C="$RUN_DIR/probe.c"
PROBE_BIN="$RUN_DIR/probe"
PROBE_BC="$RUN_DIR/probe.bc"
RUN_STDOUT="$RUN_DIR/runnable-lift.stdout"
RUN_STDERR="$RUN_DIR/runnable-lift.stderr"
STAGED_LIFT_BIN="$RUN_DIR/runnable-lift"
STAGED_LIBRARY="$RUN_DIR/libtinycode-x86_64.so"
STRACE_PREFIX="$TRACE_ROOT/runnable-lift.strace"

if [[ "$FRESH" -eq 1 ]]; then
  rm -rf "$SCRATCH_ROOT"
fi

mkdir -p "$RUN_DIR" "$TRACE_ROOT"

require_tool bash
require_tool cc
require_tool python3
require_tool strace
require_tool timeout
require_tool ps
if ! command -v readelf >/dev/null 2>&1 && ! command -v llvm-readelf >/dev/null 2>&1; then
  die "missing required tool: readelf or llvm-readelf"
fi

if [[ ! -f "$LIBRARY_PATH" ]]; then
  die "live-sidecar library not found: $LIBRARY_PATH"
fi

prepare_replay_library

if [[ -z "$RUNNABLE_LIFT_BIN" ]]; then
  if ! RUNNABLE_LIFT_BIN="$(find_runnable_lift)"; then
    log "runnable-lift not found; rebuilding via existing script"
    "$RR_DIR/runnable/scripts/build_runnable_lift.sh" build-bionic
    RUNNABLE_LIFT_BIN="$RR_DIR/build-bionic/runnable-lift"
  fi
fi

[[ -x "$RUNNABLE_LIFT_BIN" ]] || die "runnable-lift is not executable: $RUNNABLE_LIFT_BIN"
RUNNABLE_LIFT_BIN="$(cd "$(dirname "$RUNNABLE_LIFT_BIN")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$RUNNABLE_LIFT_BIN")")"
SOURCE_TREE_RUNNABLE_LIFT="$RR_DIR/runnable/tools/runnable-lift/runnable-lift"
USED_STALE_SOURCE_TREE_BINARY=0
RUNNABLE_LIFT_WARNING=""
if [[ "$RUNNABLE_LIFT_BIN" == "$SOURCE_TREE_RUNNABLE_LIFT" ]]; then
  USED_STALE_SOURCE_TREE_BINARY=1
  RUNNABLE_LIFT_WARNING="using stale source-tree runnable-lift binary; prefer build-codex-dynamic-current/runnable-lift"
  printf 'warning: %s\n' "$RUNNABLE_LIFT_WARNING" >&2
fi

RUNNABLE_LIFT_SRC_DIR="$(dirname "$RUNNABLE_LIFT_BIN")"
HELPERS_LL="$RUNNABLE_LIFT_SRC_DIR/libtinycode-helpers-x86_64.ll"
EARLY_LL="$RUNNABLE_LIFT_SRC_DIR/early-linked-x86_64.ll"
if [[ ! -f "$HELPERS_LL" || ! -f "$EARLY_LL" ]]; then
  if [[ -f "$RUNNABLE_LIFT_SRC_DIR/tools/runnable-lift/libtinycode-helpers-x86_64.ll" \
        && -f "$RUNNABLE_LIFT_SRC_DIR/tools/runnable-lift/early-linked-x86_64.ll" ]]; then
    HELPERS_LL="$RUNNABLE_LIFT_SRC_DIR/tools/runnable-lift/libtinycode-helpers-x86_64.ll"
    EARLY_LL="$RUNNABLE_LIFT_SRC_DIR/tools/runnable-lift/early-linked-x86_64.ll"
  fi
fi

[[ -f "$HELPERS_LL" ]] || die "missing companion helper file: $HELPERS_LL"
[[ -f "$EARLY_LL" ]] || die "missing companion early-linked file: $EARLY_LL"

cp "$RUNNABLE_LIFT_BIN" "$STAGED_LIFT_BIN"
cp "$HELPERS_LL" "$RUN_DIR/libtinycode-helpers-x86_64.ll"
cp "$EARLY_LL" "$RUN_DIR/early-linked-x86_64.ll"
cp "$LIBRARY_PATH" "$STAGED_LIBRARY"

cat >"$PROBE_C" <<'EOF'
int main(void) {
  return 0;
}
EOF

cc -O0 -g -fno-pie -no-pie -o "$PROBE_BIN" "$PROBE_C"

if command -v readelf >/dev/null 2>&1; then
  ENTRY="$(readelf -h "$PROBE_BIN" | awk '/Entry point address:/ {print $4}')"
else
  ENTRY="$(llvm-readelf -h "$PROBE_BIN" | awk '/Entry point address:/ {print $4}')"
fi

[[ -n "$ENTRY" ]] || die "could not read ELF entry point from $PROBE_BIN"

sample_process_tree() {
  local loops="$1"
  local i
  for ((i = 0; i < loops; i++)); do
    {
      printf '[%s] process-tree snapshot %d\n' "$(date -u +%FT%TZ)" "$((i + 1))"
      ps -eo pid,ppid,stat,etime,comm,args --forest | grep -E 'runnable-lift|strace|timeout|probe' || true
      printf '\n'
    } >>"$PROCESS_TREE_LOG"
    sleep 1
  done
}

log "Running runnable-lift under strace and a short watchdog"
sample_process_tree "$((TIMEOUT_SEC + 3))" &
SAMPLER_PID="$!"

set +e
timeout -k 2s "${TIMEOUT_SEC}s" \
  strace -ff -tt -T -s 256 -o "$STRACE_PREFIX" \
  "$STAGED_LIFT_BIN" -entry "$ENTRY" "$PROBE_BIN" "$PROBE_BC" \
  >"$RUN_STDOUT" 2>"$RUN_STDERR"
RUN_RC="$?"
set -e

kill "$SAMPLER_PID" >/dev/null 2>&1 || true
wait "$SAMPLER_PID" >/dev/null 2>&1 || true

RESULT="blocked:unknown"
if [[ "$RUN_RC" -eq 0 ]] && [[ -s "$PROBE_BC" ]]; then
  RESULT="consumed:rewrite-success"
elif [[ "$RUN_RC" -eq 124 ]]; then
  RESULT="blocked:timeout"
elif grep -Eq "unsupported PTC opcode|unsupported PTC temp schema|invalid PTC temp reference|only legacy scalar PTC temp types" "$RUN_STDERR"; then
  RESULT="blocked:ptc-schema"
elif grep -Eq "null PTCInstruction pointer|SIGSEGV.*si_addr=NULL|SIGSEGV.*si_addr=0x0" "$RUN_STDERR"; then
  RESULT="blocked:null-instruction"
elif grep -Eq "refusing QEMU V2 empty-stub library: real_translation=false|real_translation=false" "$RUN_STDERR"; then
  RESULT="blocked:empty-stub"
elif grep -Eq "Couldn't (load the PTC library|find libtinycode|find PTC functions|find ptc_load)" "$RUN_STDERR"; then
  RESULT="blocked:load-path"
fi

python3 - "$TRACE_ROOT" "$STRACE_PREFIX" "$TRACE_SUMMARY" <<'PY'
import glob
import os
import re
import sys
from pathlib import Path

trace_root = Path(sys.argv[1])
prefix = sys.argv[2]
summary_path = Path(sys.argv[3])

syscall_re = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)\(')
child_re = re.compile(r'wait(?:4|pid)\((\d+)')
pid_suffix_re = re.compile(r'\.(\d+)$')

def strip_prefix(line: str) -> str:
    line = line.strip()
    line = re.sub(r'^\d+\s+', '', line)
    line = re.sub(r'^\d{2}:\d{2}:\d{2}\.\d+\s+', '', line)
    return line

def last_syscall_line(path: Path):
    last = ""
    for raw in path.read_text(errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("+++ exited") or line.startswith("---"):
            continue
        if "(" in line:
          last = line
    if not last:
        return "", "unknown", None
    cleaned = strip_prefix(last)
    match = syscall_re.search(cleaned)
    syscall = match.group(1) if match else "unknown"
    child_pid = None
    m = child_re.search(cleaned)
    if m:
        child_pid = int(m.group(1))
    return cleaned, syscall, child_pid

records = []
for file_path in sorted(glob.glob(prefix + "*")):
    path = Path(file_path)
    if not path.is_file():
        continue
    match = pid_suffix_re.search(path.name)
    pid = int(match.group(1)) if match else None
    last_line, syscall, child_pid = last_syscall_line(path)
    records.append({
        "path": path,
        "pid": pid,
        "last_line": last_line,
        "syscall": syscall,
        "child_pid": child_pid,
    })

by_pid = {rec["pid"]: rec for rec in records if rec["pid"] is not None}
parent = next((rec for rec in records if rec["syscall"] in {"wait4", "waitpid"}), None)
child = by_pid.get(parent["child_pid"]) if parent and parent.get("child_pid") else None

loader_markers = ("libLLVM", "libstdc++", "libgcc_s", "ld-linux", "libtinycode", "libc.so", "ptc")
read_like = {"read", "pread64", "readv", "recvfrom", "recvmsg", "poll", "ppoll", "epoll_wait", "select", "pselect6"}
loader_like = {"openat", "open", "access", "faccessat", "faccessat2", "statx", "newfstatat", "lstat", "fstat"}
sync_like = {"futex", "clock_nanosleep", "nanosleep"}
cleanup_like = {"unlink", "unlinkat", "rmdir", "rename", "renameat", "renameat2"}

conclusion = "other"
evidence = []
null_instr = next((rec for rec in records if "null PTCInstruction pointer" in rec["last_line"]), None)
cleanup = next((rec for rec in records if rec["syscall"] in cleanup_like), None)
blocked_read = next((rec for rec in records if rec["syscall"] in read_like), None)
if cleanup:
    evidence.append(f"cleanup_pid={cleanup['pid']} cleanup_last={cleanup['last_line']}")
    conclusion = f"filesystem cleanup ({cleanup['syscall']})"
if null_instr:
    evidence.append(f"null_instr_pid={null_instr['pid']} null_instr_last={null_instr['last_line']}")
    conclusion = "null PTCInstruction pointer"
if blocked_read:
    evidence.append(f"read_pid={blocked_read['pid']} read_last={blocked_read['last_line']}")
    conclusion = "sidecar subprocess read/poll"
if parent:
    evidence.append(f"parent_pid={parent['pid']} parent_last={parent['last_line']}")
    if child:
        evidence.append(f"child_pid={child['pid']} child_last={child['last_line']}")
        if child["syscall"] in read_like:
            conclusion = "sidecar subprocess read/poll"
        elif child["syscall"] in loader_like and any(marker in child["last_line"] for marker in loader_markers):
            conclusion = "loader lookup"
        elif child["syscall"] in sync_like:
            conclusion = "LLVM emit/synchronization"
        elif child["syscall"] in loader_like:
            conclusion = "loader lookup or library probe"
        elif null_instr:
            conclusion = "null PTCInstruction pointer"
        elif not cleanup and not blocked_read:
            conclusion = f"waiting on child pid {child['pid']}"
    else:
        if null_instr:
            conclusion = "null PTCInstruction pointer"
        elif not cleanup and not blocked_read:
            conclusion = "sidecar subprocess wait"
elif not cleanup and not blocked_read:
    interesting = next((rec for rec in records if rec["syscall"] in read_like | loader_like | sync_like), None)
    if interesting:
        evidence.append(f"pid={interesting['pid']} last={interesting['last_line']}")
        if interesting["syscall"] in read_like:
            conclusion = "read/poll"
        elif interesting["syscall"] in loader_like and any(marker in interesting["last_line"] for marker in loader_markers):
            conclusion = "loader lookup"
        elif interesting["syscall"] in sync_like:
            conclusion = "LLVM emit/synchronization"
        else:
            conclusion = interesting["syscall"]
elif null_instr:
    conclusion = "null PTCInstruction pointer"

summary_lines = [
    f"trace_root={trace_root}",
    f"trace_files={len(records)}",
    f"trace_conclusion={conclusion}",
]
summary_lines.extend(evidence)
summary_lines.append("trace_last_syscalls:")
for rec in sorted(records, key=lambda item: (-1 if item["pid"] is None else item["pid"])):
    summary_lines.append(
        f"  pid={rec['pid']} syscall={rec['syscall']} line={rec['last_line']}"
    )
summary_path.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
PY

TRACE_CONCLUSION="$(awk -F= '/^trace_conclusion=/{print $2; exit}' "$TRACE_SUMMARY")"

cat >"$SUMMARY_JSON" <<EOF
{
  "scratch_root": "$SCRATCH_ROOT",
  "library_path": "$LIBRARY_PATH",
  "runnable_lift_bin": "$STAGED_LIFT_BIN",
  "used_stale_source_tree_binary": $( [[ "$USED_STALE_SOURCE_TREE_BINARY" -eq 1 ]] && printf 'true' || printf 'false' ),
  "runnable_lift_warning": "$(printf '%s' "$RUNNABLE_LIFT_WARNING")",
  "probe_binary": "$PROBE_BIN",
  "probe_bc": "$PROBE_BC",
  "entry": "$ENTRY",
  "timeout_sec": $TIMEOUT_SEC,
  "run_rc": $RUN_RC,
  "result": "$RESULT",
  "trace_conclusion": "$TRACE_CONCLUSION",
  "stdout": "$RUN_STDOUT",
  "stderr": "$RUN_STDERR",
  "trace_root": "$TRACE_ROOT",
  "trace_summary": "$TRACE_SUMMARY",
  "process_tree_log": "$PROCESS_TREE_LOG"
}
EOF

echo "SCRATCH_ROOT=$SCRATCH_ROOT"
echo "LIBRARY_PATH=$LIBRARY_PATH"
echo "RUNNABLE_LIFT_BIN=$STAGED_LIFT_BIN"
echo "RUNNABLE_LIFT_ENTRY=$ENTRY"
echo "RUNNABLE_LIFT_TIMEOUT_SEC=$TIMEOUT_SEC"
echo "RUNNABLE_LIFT_EXIT=$RUN_RC"
echo "RUNNABLE_LIFT_RESULT=$RESULT"
echo "RUNNABLE_LIFT_TRACE_CONCLUSION=$TRACE_CONCLUSION"
echo "RUNNABLE_LIFT_STDOUT=$RUN_STDOUT"
echo "RUNNABLE_LIFT_STDERR=$RUN_STDERR"
echo "RUNNABLE_LIFT_TRACE_ROOT=$TRACE_ROOT"
echo "RUNNABLE_LIFT_TRACE_SUMMARY=$TRACE_SUMMARY"
echo "RUNNABLE_LIFT_PROCESS_TREE=$PROCESS_TREE_LOG"
echo "SUMMARY_JSON=$SUMMARY_JSON"

sed -n '1,80p' "$TRACE_SUMMARY"
sed -n '1,80p' "$PROCESS_TREE_LOG"
sed -n '1,80p' "$RUN_STDOUT"
sed -n '1,80p' "$RUN_STDERR"
