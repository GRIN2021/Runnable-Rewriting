#!/usr/bin/env bash
#
# Stage the live-sidecar libtinycode-x86_64.so next to runnable-lift and run a
# minimal probe through the consumer path.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_PTC_LIVE_SIDECAR_RUNNABLE_LIFT_ROOT:-/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-smoke}"
LIBRARY_PATH="${RUNNABLE_QEMU_V2_PTC_LIVE_SIDECAR_LIBRARY:-/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/libtinycode-x86_64.so}"
RUNNABLE_LIFT_BIN="${RUNNABLE_LIFT_BIN:-}"
REPLAY_TRANSLATE_LIB="${RUNNABLE_QEMU_V2_PTC_LIVE_SIDECAR_REPLAY_TRANSLATE_LIB:-1}"
FRESH=0

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_ptc_live_sidecar_runnable_lift_smoke.sh [options]

Options:
  --scratch-root DIR  Output scratch root.
                      Default: /tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-smoke
  --library PATH      Live-sidecar libtinycode-x86_64.so to stage.
                      Default: /tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/libtinycode-x86_64.so
  --runnable-lift BIN runnable-lift binary to probe.
                      Defaults to a local build-tree binary. Passing the
                      source-tree runnable/tools/runnable-lift/runnable-lift
                      is allowed but treated as a stale-binary risk.
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

  log "Rebuilding replay-backed live-sidecar library for runnable-lift smoke"
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
  "result": "blocked:replay-library-rebuild",
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

SCRATCH_ROOT="$(abs_path "$SCRATCH_ROOT")"
LIBRARY_PATH="$(abs_path "$LIBRARY_PATH")"
RUN_DIR="$SCRATCH_ROOT/run"
SUMMARY_JSON="$SCRATCH_ROOT/qemu_v2_ptc_live_sidecar_runnable_lift_smoke.summary.json"
DIAG_ROOT="$SCRATCH_ROOT/diag"
PROBE_C="$RUN_DIR/probe.c"
PROBE_BIN="$RUN_DIR/probe"
PROBE_BC="$RUN_DIR/probe.bc"
RUN_STDOUT="$RUN_DIR/runnable-lift.stdout"
RUN_STDERR="$RUN_DIR/runnable-lift.stderr"
STAGED_LIFT_BIN="$RUN_DIR/runnable-lift"
STAGED_LIBRARY="$RUN_DIR/libtinycode-x86_64.so"
DIAG_STDOUT="$DIAG_ROOT/runnable-lift.retry.stdout"
DIAG_STDERR="$DIAG_ROOT/runnable-lift.retry.stderr"
DIAG_STRACE_PREFIX="$DIAG_ROOT/runnable-lift.strace"
DIAG_GDB_TXT="$DIAG_ROOT/runnable-lift.gdb.txt"

if [[ "$FRESH" -eq 1 ]]; then
  rm -rf "$SCRATCH_ROOT"
fi

mkdir -p "$RUN_DIR"

require_tool bash
require_tool cc
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
FALLBACK_HELPERS_LL="$RR_DIR/runnable/tools/runnable-lift/libtinycode-helpers-x86_64.ll"
FALLBACK_EARLY_LL="$RR_DIR/runnable/tools/runnable-lift/early-linked-x86_64.ll"

if [[ ! -f "$HELPERS_LL" ]]; then
  HELPERS_LL="$FALLBACK_HELPERS_LL"
fi
if [[ ! -f "$EARLY_LL" ]]; then
  EARLY_LL="$FALLBACK_EARLY_LL"
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

log "Running runnable-lift against staged live-sidecar library"
set +e
timeout 20s "$STAGED_LIFT_BIN" -entry "$ENTRY" "$PROBE_BIN" "$PROBE_BC" \
  >"$RUN_STDOUT" 2>"$RUN_STDERR"
RUN_RC="$?"
set -e

RESULT="blocked:unknown"
FAILURE_CLASS="unknown"
if [[ "$RUN_RC" -eq 0 ]] && [[ -s "$PROBE_BC" ]]; then
  RESULT="consumed:rewrite-success"
  FAILURE_CLASS="consumed:rewrite-success"
elif [[ "$RUN_RC" -eq 124 ]]; then
  RESULT="blocked:timeout"
  FAILURE_CLASS="timeout"
elif grep -Eq "unsupported PTC opcode|unsupported PTC temp schema|invalid PTC temp reference|only legacy scalar PTC temp types" "$RUN_STDERR"; then
  RESULT="blocked:ptc-schema"
  FAILURE_CLASS="ptc-schema"
elif grep -Eq "Couldn't (load the PTC library|find libtinycode|find PTC functions|find ptc_load)" "$RUN_STDERR"; then
  RESULT="blocked:load-path"
  FAILURE_CLASS="load-path"
fi

if [[ "$RUN_RC" -eq 139 || "$RUN_RC" -eq 11 ]]; then
  mkdir -p "$DIAG_ROOT"
  DIAG_RC=127
  DIAG_GDB_RC=127

  if command -v strace >/dev/null 2>&1; then
    log "Capturing runnable-lift retry strace stack"
    set +e
    timeout -k 2s 30s \
      strace -ff -k -tt -T -s 256 -o "$DIAG_STRACE_PREFIX" \
      "$STAGED_LIFT_BIN" -entry "$ENTRY" "$PROBE_BIN" "$PROBE_BC" \
      >"$DIAG_STDOUT" 2>"$DIAG_STDERR"
    DIAG_RC="$?"
    set -e
  else
    printf 'strace not found in PATH; skipped strace retry\n' >"$DIAG_STDERR"
  fi

  if command -v gdb >/dev/null 2>&1; then
    log "Capturing runnable-lift retry gdb backtrace"
    set +e
    timeout -k 2s 30s \
      gdb -q -batch \
        -ex "set pagination off" \
        -ex "set confirm off" \
        -ex "set debuginfod enabled off" \
        -ex "set print thread-events off" \
        -ex "handle SIGSEGV stop print nopass" \
        -ex "run" \
        -ex "bt full" \
        -ex "frame 0" \
        -ex "info args" \
        --args "$STAGED_LIFT_BIN" -entry "$ENTRY" "$PROBE_BIN" "$PROBE_BC" \
      >"$DIAG_GDB_TXT" 2>&1
    DIAG_GDB_RC="$?"
    set -e
  else
    printf 'gdb not found in PATH; skipped gdb retry\n' >"$DIAG_GDB_TXT"
  fi

  python3 - "$SUMMARY_JSON" "$RUN_STDOUT" "$RUN_STDERR" "$DIAG_STDOUT" "$DIAG_STDERR" "$DIAG_STRACE_PREFIX" "$DIAG_GDB_TXT" "$RUN_RC" "$DIAG_RC" "$DIAG_GDB_RC" "$ENTRY" "$PROBE_BIN" "$PROBE_BC" "$LIBRARY_PATH" "$STAGED_LIFT_BIN" "$USED_STALE_SOURCE_TREE_BINARY" "$RUNNABLE_LIFT_WARNING" <<'PY'
import json
import re
import sys
from pathlib import Path

summary_path = Path(sys.argv[1])
run_stdout = Path(sys.argv[2])
run_stderr = Path(sys.argv[3])
diag_stdout = Path(sys.argv[4])
diag_stderr = Path(sys.argv[5])
diag_strace_prefix = sys.argv[6]
diag_gdb = Path(sys.argv[7])
run_rc = int(sys.argv[8])
diag_rc = int(sys.argv[9])
diag_gdb_rc = int(sys.argv[10])
entry = sys.argv[11]
probe_bin = sys.argv[12]
probe_bc = sys.argv[13]
library_path = sys.argv[14]
runnable_lift_bin = sys.argv[15]
used_stale_source_tree_binary = sys.argv[16] == "1"
runnable_lift_warning = sys.argv[17]

run_stderr_text = run_stderr.read_text(errors="replace") if run_stderr.exists() else ""
run_stdout_text = run_stdout.read_text(errors="replace") if run_stdout.exists() else ""
diag_stderr_text = diag_stderr.read_text(errors="replace") if diag_stderr.exists() else ""
diag_stdout_text = diag_stdout.read_text(errors="replace") if diag_stdout.exists() else ""
gdb_text = diag_gdb.read_text(errors="replace") if diag_gdb.exists() else ""

summary = {
    "scratch_root": str(summary_path.parent),
    "library_path": library_path,
    "runnable_lift_bin": runnable_lift_bin,
    "used_stale_source_tree_binary": used_stale_source_tree_binary,
    "runnable_lift_warning": runnable_lift_warning,
    "probe_binary": probe_bin,
    "probe_bc": probe_bc,
    "entry": entry,
    "run_rc": run_rc,
    "stdout": str(run_stdout),
    "stderr": str(run_stderr),
    "diag_run_rc": diag_rc,
    "diag_gdb_rc": diag_gdb_rc,
    "diag_stdout": str(diag_stdout),
    "diag_stderr": str(diag_stderr),
    "diag_gdb": str(diag_gdb),
    "diag_repro_command": f"cd {Path(probe_bin).parent} && ./runnable-lift -entry {entry} ./probe ./probe.bc",
}

repo_needles = (
    "InstructionTranslator::preprocess",
    "InstructionTranslator::newInstruction",
    "CodeGenerator::translate",
    "PTCDump.cpp",
    "disassemble (",
    "main",
)
gdb_repo_frames = []
for line in gdb_text.splitlines():
    if not line.startswith("#"):
        continue
    if not any(needle in line for needle in repo_needles):
        continue
    stripped = line.strip()
    if stripped not in gdb_repo_frames:
        gdb_repo_frames.append(stripped)

crash_function = ""
if gdb_repo_frames:
    top = gdb_repo_frames[0]
    for candidate in (
        "InstructionTranslator::preprocess",
        "InstructionTranslator::newInstruction",
        "CodeGenerator::translate",
        "disassemble",
        "main",
    ):
        if candidate in top:
            crash_function = candidate
            break

strace_match_files = []
segv_null = False
stack_source = ""
stack_top = ""
sigsegv_re = re.compile(r"SIGSEGV")
trace_frame_re = re.compile(r"\((.+?)\+0x[0-9a-f]+\)")
for path in sorted(Path(diag_strace_prefix).parent.glob(Path(diag_strace_prefix).name + "*")):
    text = path.read_text(errors="replace")
    if "SIGSEGV" not in text:
        continue
    strace_match_files.append(str(path))
    if "si_addr=NULL" in text or "si_addr=0x0" in text:
        segv_null = True
    if not stack_source and ("PTCDump" in text or "CodeGenerator::translate" in text or "InstructionTranslator::newInstruction" in text):
        stack_source = str(path)
        for line in reversed(text.splitlines()):
            if "PTCDump" in line or "CodeGenerator::translate" in line or "InstructionTranslator::newInstruction" in line:
                stack_top = line.strip()
                m = trace_frame_re.search(line)
                if m and not crash_function:
                    crash_function = m.group(1).split("+", 1)[0]
                break

if not crash_function and "Program received signal SIGSEGV" in gdb_text:
    crash_function = "unknown"

if crash_function == "disassemble":
    result = "blocked:runnable-lift-segv:disassemble"
    failure_class = "runnable-lift-segv:disassemble"
elif crash_function:
    result = f"blocked:runnable-lift-segv:{crash_function}"
    failure_class = f"runnable-lift-segv:{crash_function}"
elif segv_null or run_rc == 139:
    result = "blocked:runnable-lift-segv"
    failure_class = "runnable-lift-segv"
else:
    result = "blocked:unknown"
    failure_class = "unknown"

summary.update({
    "result": result,
    "failure_class": failure_class,
    "diag_crash_function": crash_function,
    "diag_stack_top": stack_top,
    "diag_stack_source": stack_source,
    "diag_gdb_repo_frames": gdb_repo_frames[:12],
    "diag_gdb_excerpt": gdb_text.splitlines()[:80],
    "diag_run_stdout_excerpt": run_stdout_text.splitlines()[:20],
    "diag_run_stderr_excerpt": run_stderr_text.splitlines()[:40],
    "diag_stdout_excerpt": diag_stdout_text.splitlines()[:20],
    "diag_stderr_excerpt": diag_stderr_text.splitlines()[:40],
    "diag_strace_match_files": strace_match_files,
    "diag_sigsegv_null": segv_null,
})
summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(summary, indent=2, sort_keys=True))
PY
  RESULT="$(python3 - "$SUMMARY_JSON" <<'PY'
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text())
print(summary.get("result", "blocked:unknown"))
PY
)"
  FAILURE_CLASS="$(python3 - "$SUMMARY_JSON" <<'PY'
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text())
print(summary.get("failure_class", "unknown"))
PY
)"
else
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
  "run_rc": $RUN_RC,
  "result": "$RESULT",
  "failure_class": "$FAILURE_CLASS",
  "stdout": "$RUN_STDOUT",
  "stderr": "$RUN_STDERR",
  "diag_repro_command": "cd $RUN_DIR && ./runnable-lift -entry $ENTRY ./probe ./probe.bc"
}
EOF
fi

echo "SCRATCH_ROOT=$SCRATCH_ROOT"
echo "LIBRARY_PATH=$LIBRARY_PATH"
echo "RUNNABLE_LIFT_BIN=$STAGED_LIFT_BIN"
echo "RUNNABLE_LIFT_ENTRY=$ENTRY"
echo "RUNNABLE_LIFT_EXIT=$RUN_RC"
echo "RUNNABLE_LIFT_RESULT=$RESULT"
echo "RUNNABLE_LIFT_STDOUT=$RUN_STDOUT"
echo "RUNNABLE_LIFT_STDERR=$RUN_STDERR"
echo "SUMMARY_JSON=$SUMMARY_JSON"
sed -n '1,80p' "$RUN_STDOUT"
sed -n '1,80p' "$RUN_STDERR"
