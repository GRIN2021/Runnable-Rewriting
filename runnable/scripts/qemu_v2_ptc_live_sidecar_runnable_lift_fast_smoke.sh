#!/usr/bin/env bash
#
# Fast-path verification for the live-sidecar runnable-lift consumer.
#
# This reuses the already validated live-sidecar library and temporarily
# replaces its embedded helper script with a replay helper that streams the
# prepared payload straight back to ptc_translate. The goal is to keep the
# runnable-lift consumer on the live-sidecar path without re-entering the nested
# QEMU tree copy workflow.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_PTC_LIVE_SIDECAR_RUNNABLE_LIFT_FAST_ROOT:-/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-fast-smoke}"
SOURCE_ROOT="${RUNNABLE_QEMU_V2_PTC_LIVE_SIDECAR_SOURCE_ROOT:-/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke}"
SOURCE_MODEL="$SOURCE_ROOT/sidecar/sidecar.model.json"
SOURCE_SUMMARY="$SOURCE_ROOT/sidecar/sidecar.summary.json"
SOURCE_PAYLOAD="$SOURCE_ROOT/sidecar/sidecar.payload.txt"
SOURCE_HELPER="$SOURCE_ROOT/ptc_live_sidecar_regen.sh"
SOURCE_LIBRARY="$SOURCE_ROOT/libtinycode-x86_64.so"
TRACE_ROOT="$SCRATCH_ROOT/trace"
FRESH=0
SOURCE_METADATA_JSON="$SCRATCH_ROOT/source-library.metadata.json"

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_ptc_live_sidecar_runnable_lift_fast_smoke.sh [options]

Options:
  --scratch-root DIR  Output scratch root.
                      Default: /tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-fast-smoke
  --source-root DIR   Existing live-sidecar translate-smoke scratch root to replay.
                      Default: /tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke
  --fresh             Remove the fast-smoke scratch root before running.
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scratch-root)
      SCRATCH_ROOT="$(abs_path "${2:?missing value for --scratch-root}")"
      shift 2
      ;;
    --source-root)
      SOURCE_ROOT="$(abs_path "${2:?missing value for --source-root}")"
      shift 2
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
SOURCE_ROOT="$(abs_path "$SOURCE_ROOT")"
TRACE_ROOT="$SCRATCH_ROOT/trace"
SUMMARY_JSON="$SCRATCH_ROOT/qemu_v2_ptc_live_sidecar_runnable_lift_fast_smoke.summary.json"
TRACE_SUMMARY_JSON="$TRACE_ROOT/qemu_v2_ptc_live_sidecar_runnable_lift_trace.summary.json"
DIAG_ROOT="$SCRATCH_ROOT/diag"
DIAG_STDOUT="$DIAG_ROOT/runnable-lift.retry.stdout"
DIAG_STDERR="$DIAG_ROOT/runnable-lift.retry.stderr"
DIAG_STRACE_PREFIX="$DIAG_ROOT/runnable-lift.strace"
DIAG_GDB_TXT="$DIAG_ROOT/runnable-lift.gdb.txt"
SOURCE_HELPER_BACKUP="$SCRATCH_ROOT/ptc_live_sidecar_regen.sh.backup"
REPLAY_HELPER="$SOURCE_HELPER"

if [[ "$FRESH" -eq 1 ]]; then
  rm -rf "$SCRATCH_ROOT"
fi

mkdir -p "$SCRATCH_ROOT" "$TRACE_ROOT"

require_tool bash
require_tool python3

for path in "$SOURCE_MODEL" "$SOURCE_SUMMARY" "$SOURCE_PAYLOAD" "$SOURCE_HELPER" "$SOURCE_LIBRARY"; do
  [[ -f "$path" ]] || die "missing replay source artifact: $path"
done

python3 - "$SOURCE_LIBRARY" "$SOURCE_METADATA_JSON" <<'PY'
import ctypes
import json
import sys
from pathlib import Path

library_path = Path(sys.argv[1])
metadata_path = Path(sys.argv[2])

lib = ctypes.CDLL(str(library_path))
try:
    lib.ptc_get_abi_metadata.restype = ctypes.c_char_p
    raw = lib.ptc_get_abi_metadata()
    metadata = raw.decode("utf-8") if raw is not None else ""
except AttributeError:
    metadata = ""

fields = {}
for line in metadata.splitlines():
    if "=" not in line:
        continue
    key, value = line.split("=", 1)
    fields[key.strip()] = value.strip()

result = {
    "library_path": str(library_path),
    "metadata": metadata,
    "fields": fields,
    "real_translation": fields.get("real_translation", ""),
    "stub_kind": fields.get("stub_kind", ""),
}
metadata_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(result, sort_keys=True))
PY

SOURCE_REAL_TRANSLATION="$(python3 - "$SOURCE_METADATA_JSON" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
print(data.get("real_translation", ""))
PY
)"
if [[ "$SOURCE_REAL_TRANSLATION" != "true" ]]; then
  SUMMARY_JSON="$SCRATCH_ROOT/qemu_v2_ptc_live_sidecar_runnable_lift_fast_smoke.summary.json"
  cat >"$SUMMARY_JSON" <<EOF
{
  "scratch_root": "$SCRATCH_ROOT",
  "source_root": "$SOURCE_ROOT",
  "source_library": "$SOURCE_LIBRARY",
  "source_metadata_json": "$SOURCE_METADATA_JSON",
  "source_real_translation": "$(printf '%s' "$SOURCE_REAL_TRANSLATION")",
  "result": "blocked:no-real-translation-artifact",
  "trace_result": "blocked:no-real-translation-artifact",
  "trace_conclusion": "source library metadata is not real_translation=true",
  "next_upstream_artifact": "a libtinycode-x86_64.so whose ptc_get_abi_metadata() reports real_translation=true",
  "next_upstream_generator": "runnable/scripts/qemu_v2_ptc_inlibrary_live_translate_spike.sh or a new real QEMU/libtinycode build wrapper that stages a real-translation libtinycode-x86_64.so",
  "next_upstream_output": "libtinycode-x86_64.so under a scratch root that fast-smoke can copy into the runnable-lift trace staging directory",
  "stderr": "refusing to replay live-sidecar runnable-lift against a non-real-translation source library"
}
EOF
  cat "$SUMMARY_JSON"
  printf 'SCRATCH_ROOT=%s\n' "$SCRATCH_ROOT"
  printf 'SOURCE_ROOT=%s\n' "$SOURCE_ROOT"
  printf 'SOURCE_LIBRARY=%s\n' "$SOURCE_LIBRARY"
  printf 'SOURCE_METADATA_JSON=%s\n' "$SOURCE_METADATA_JSON"
  exit 0
fi

cleanup() {
  if [[ -f "$SOURCE_HELPER_BACKUP" ]]; then
    cp "$SOURCE_HELPER_BACKUP" "$SOURCE_HELPER" 2>/dev/null || true
    chmod +x "$SOURCE_HELPER" 2>/dev/null || true
  fi
}
trap cleanup EXIT

cp "$SOURCE_HELPER" "$SOURCE_HELPER_BACKUP"
cat >"$REPLAY_HELPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SCRATCH_ROOT="\${1:?missing scratch root}"
QEMU_SRC="\${2:?missing qemu src}"
JOBS="\${3:?missing jobs}"
LOG_PATH="\$SCRATCH_ROOT/sidecar.log"
MODEL_SOURCE="$SOURCE_MODEL"
SUMMARY_SOURCE="$SOURCE_SUMMARY"
PAYLOAD_SOURCE="$SOURCE_PAYLOAD"
MODEL_JSON="\$SCRATCH_ROOT/sidecar.model.json"
SUMMARY_JSON="\$SCRATCH_ROOT/sidecar.summary.json"
PAYLOAD_OUT="\$SCRATCH_ROOT/sidecar.payload.txt"
PAYLOAD_SIZE="\$SCRATCH_ROOT/sidecar.payload.size"

mkdir -p "\$SCRATCH_ROOT"
{
  printf '[%s] sidecar-start scratch_root=%s qemu_src=%s jobs=%s replay=true\n' "\$(date -u +%FT%TZ)" "\$SCRATCH_ROOT" "\$QEMU_SRC" "\$JOBS"
  printf '[%s] sidecar-replay model_source=%s\n' "\$(date -u +%FT%TZ)" "\$MODEL_SOURCE"
  printf '[%s] sidecar-replay summary_source=%s\n' "\$(date -u +%FT%TZ)" "\$SUMMARY_SOURCE"
  printf '[%s] sidecar-replay payload_source=%s\n' "\$(date -u +%FT%TZ)" "\$PAYLOAD_SOURCE"
} >>"\$LOG_PATH"

python3 - "\$MODEL_SOURCE" "\$MODEL_JSON" "\$SUMMARY_JSON" "\$PAYLOAD_SOURCE" <<'PY' >"\$PAYLOAD_OUT"
import json
import sys
from pathlib import Path

source_model = Path(sys.argv[1])
model_json = Path(sys.argv[2])
summary_json = Path(sys.argv[3])
payload_source = Path(sys.argv[4])
model = json.loads(source_model.read_text())
summary = model["summary"]
instructions = model["instructions"]
temps = model["temps"]

def to_int(value):
    return 0 if value is None else int(value)

def instruction_opcode(inst):
    return inst["ptc_list_model"]["opc"]

debug_index = next((i for i, inst in enumerate(instructions)
                    if instruction_opcode(inst) == "debug_insn_start"), None)
if debug_index is None:
    raise SystemExit(f"replay source model has no debug_insn_start instruction: {source_model}")

next_debug_index = next((i for i in range(debug_index + 1, len(instructions))
                         if instruction_opcode(instructions[i]) == "debug_insn_start"), len(instructions))
selected_instructions = instructions[debug_index:next_debug_index]
if not selected_instructions:
    raise SystemExit(f"replay source model is missing instructions after debug_insn_start: {source_model}")

temp_by_walker_arg = {}
for temp in temps:
    walker_arg = temp.get("walker_arg")
    if walker_arg is not None:
        temp_by_walker_arg[str(walker_arg)] = temp

selected_temp_indices = []
selected_temp_set = set()
for inst in selected_instructions:
    for arg in inst.get("args", []):
        temp = temp_by_walker_arg.get(str(arg))
        if temp is None:
            continue
        temp_index = int(temp["index"])
        if temp_index not in selected_temp_set:
            selected_temp_set.add(temp_index)
            selected_temp_indices.append(temp_index)

def temp_sort_key(temp_index):
    temp = temps[temp_index]
    flags = temp.get("flags", {})
    return (
        0 if flags.get("is_global") else 1,
        int(temp["index"]),
    )

ordered_temp_indices = sorted(selected_temp_indices, key=temp_sort_key)
if 0 not in ordered_temp_indices and any(temp.get("index") == 0 for temp in temps):
    ordered_temp_indices = [0] + [i for i in ordered_temp_indices if i != 0]

temp_remap = {old_index: new_index for new_index, old_index in enumerate(ordered_temp_indices)}
selected_temps = []
for new_index, old_index in enumerate(ordered_temp_indices):
    temp = dict(temps[old_index])
    temp["index"] = new_index
    temp["temp_id"] = new_index
    temp["temp_index"] = new_index
    selected_temps.append(temp)

renumbered_instructions = []
argument_count = 0
for new_index, inst in enumerate(selected_instructions):
    inst_copy = dict(inst)
    inst_copy["index"] = new_index
    mapped_args = []
    for arg in inst.get("args", []):
        temp = temp_by_walker_arg.get(str(arg))
        if temp is None:
            mapped_args.append(arg)
            continue
        old_index = int(temp["index"])
        if old_index not in temp_remap:
            raise SystemExit(
                f"replay source model instruction {inst.get('index')} references temp {old_index} "
                f"not captured by the selected replay subset"
            )
        mapped_args.append(str(temp_remap[old_index]))
    inst_copy["args"] = mapped_args
    renumbered_instructions.append(inst_copy)
    argument_count += len(mapped_args)

model_json.write_text(source_model.read_text(), encoding="utf-8")
summary_json.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")

print("PTC_LIVE_SIDECAR v1")
print(f"instruction_count={len(renumbered_instructions)}")
print(f"argument_count={argument_count}")
print(f"temp_count={len(selected_temps)}")
global_temps = sum(1 for temp in selected_temps if temp.get("flags", {}).get("is_global"))
if global_temps == 0:
    raise SystemExit(f"replay source model selected no global temps: {source_model}")
print(f"global_temps={global_temps}")
print(f"total_temps={len(selected_temps)}")
print(f"model_json={model_json}")
print(f"summary_json={summary_json}")
print(f"payload_source={payload_source}")
for inst in renumbered_instructions:
    model_entry = inst["ptc_list_model"]
    args = ",".join(str(arg) for arg in inst["args"])
    print(
        "instruction|%d|%s|%s|%s|%d|%s"
        % (
        int(inst["index"]),
            model_entry["opc"],
            "0" if model_entry["callo"] is None else int(model_entry["callo"]),
            "0" if model_entry["calli"] is None else int(model_entry["calli"]),
            len(inst["args"]),
            args,
        )
    )
for temp in selected_temps:
    model_entry = temp["ptc_temp_model"]
    temp_name = temp.get("name") or f"temp_{int(temp['index'])}"
    temp_val = model_entry["val"]
    print(
        "temp|%d|%s|%d|%d|%d|%d|%d|%d|%s|%d|%d|%d|%d|%d"
        % (
            to_int(temp["index"]),
            str(temp_name).replace("|", "/"),
            to_int(model_entry["val_type"]),
            to_int(model_entry["base_type"]),
            to_int(model_entry["type"]),
            to_int(model_entry["reg"]),
            to_int(model_entry["mem_reg"]),
            to_int(model_entry["mem_offset"]),
            "0" if temp_val is None else temp_val,
            1 if model_entry["fixed_reg"] else 0,
            1 if model_entry["mem_coherent"] else 0,
            1 if model_entry["mem_allocated"] else 0,
            1 if model_entry["temp_local"] else 0,
            1 if model_entry["temp_allocated"] else 0,
        )
    )
PY

test -s "\$PAYLOAD_OUT"
wc -c <"\$PAYLOAD_OUT" >"\$PAYLOAD_SIZE"
cat "\$PAYLOAD_OUT"

{
  printf '[%s] sidecar-finished model_json=%s summary_json=%s payload=%s payload_size=%s replay=true\n' "\$(date -u +%FT%TZ)" "\$MODEL_JSON" "\$SUMMARY_JSON" "\$PAYLOAD_OUT" "\$(cat "\$PAYLOAD_SIZE")"
} >>"\$LOG_PATH"
EOF
chmod +x "$REPLAY_HELPER"

log "Tracing runnable-lift against replayed live-sidecar library"
bash "$SCRIPT_DIR/qemu_v2_ptc_live_sidecar_runnable_lift_trace.sh" \
  --scratch-root "$TRACE_ROOT" \
  --library "$SOURCE_LIBRARY" \
  --fresh

python3 - "$SCRATCH_ROOT" "$SOURCE_ROOT" "$SOURCE_MODEL" "$SOURCE_SUMMARY" "$SOURCE_LIBRARY" "$TRACE_ROOT" "$TRACE_SUMMARY_JSON" "$SUMMARY_JSON" <<'PY'
import json
import re
import sys
from pathlib import Path

scratch_root = Path(sys.argv[1])
source_root = Path(sys.argv[2])
source_model = Path(sys.argv[3])
source_summary = Path(sys.argv[4])
source_library = Path(sys.argv[5])
trace_root = Path(sys.argv[6])
trace_summary_json = Path(sys.argv[7])
summary_json = Path(sys.argv[8])

trace_result = json.loads(trace_summary_json.read_text())
trace_result_name = str(trace_result.get("result", ""))
try:
    diag_run_rc = int(trace_result.get("diag_run_rc", -1))
except (TypeError, ValueError):
    diag_run_rc = -1
diag_crash_function = str(trace_result.get("diag_crash_function", ""))
copy_hits = 0
cp_exec_hits = 0
strace_matches = []
segv_null = False

def temp_out_of_range_sources(paths):
    needles = (
        "temp_id < instructions->total_temps",
        "assert(temp_id < instructions->total_temps)",
        "ptc_temp_get",
        "temp out-of-range in preprocess",
        "qemu/linux-user/ptc.h:97",
        "qemu/linux-user/ptc.h:98",
        "qemu/linux-user/ptc.h:99",
    )
    hits = []
    for path in paths:
        if not path.exists():
            continue
        text = path.read_text(errors="replace")
        if any(needle in text for needle in needles):
            hits.append(str(path))
    return hits

trace_stderr = trace_root / "run" / "runnable-lift.stderr"
trace_stdout = trace_root / "run" / "runnable-lift.stdout"
temp_out_of_range_hits = temp_out_of_range_sources([trace_stderr, trace_stdout] + sorted(trace_root.glob("runnable-lift.strace*")))

for path in sorted(trace_root.glob("runnable-lift.strace*")):
    text = path.read_text(errors="replace")
    copy_hits += len(re.findall(r"copy_file_range\(", text))
    copy_hits += len(re.findall(r"utimensat\(", text))
    cp_exec_hits += len(re.findall(r'execve\("/usr/bin/cp"', text))
    if "SIGSEGV" in text and "si_addr=NULL" in text:
        segv_null = True
    if "copy_file_range(" in text or 'execve("/usr/bin/cp"' in text:
        strace_matches.append(str(path))

summary = {
    "scratch_root": str(scratch_root),
    "source_root": str(source_root),
    "source_model": str(source_model),
    "source_summary": str(source_summary),
    "source_library": str(source_library),
    "trace_root": str(trace_root),
    "trace_summary_json": str(trace_summary_json),
    "trace_conclusion": trace_result.get("trace_conclusion", ""),
    "trace_result": trace_result.get("result", ""),
    "trace_exit": trace_result.get("run_rc", None),
    "trace_sigsegv_null": segv_null,
    "temp_out_of_range_sources": temp_out_of_range_hits,
    "payload_path": str(source_root / "sidecar" / "sidecar.payload.txt"),
    "payload_size": (source_root / "sidecar" / "sidecar.payload.txt").stat().st_size if (source_root / "sidecar" / "sidecar.payload.txt").exists() else 0,
    "copy_syscall_hits": copy_hits,
    "cp_exec_hits": cp_exec_hits,
    "strace_match_files": strace_matches,
    "conclusion": (
        "replay fast-path avoids QEMU tree copy"
        if copy_hits == 0 and cp_exec_hits == 0
        else "replay fast-path still shows QEMU tree copy"
    ),
    "result": (
        "passed"
        if trace_result_name == "consumed:rewrite-success"
        else (
            "blocked:ptc-temp-out-of-range"
            if temp_out_of_range_hits
            else (
                f"blocked:runnable-lift-segv:{diag_crash_function}"
                if diag_run_rc == 139 and diag_crash_function
                else (
                    "blocked:runnable-lift-segv"
                    if diag_run_rc == 139
                    else (
                        "blocked:segv-null-after-ptc-translate"
                        if segv_null and trace_result_name != "consumed:rewrite-success"
                        else trace_result_name
                    )
                )
            )
        )
    ),
    "failure_class": (
        "ptc-temp-out-of-range"
        if temp_out_of_range_hits
        else (
            "segv-null-after-ptc-translate"
            if segv_null and trace_result_name != "consumed:rewrite-success"
            else (
                f"runnable-lift-segv:{diag_crash_function}"
                if diag_run_rc == 139 and diag_crash_function
                else (
                    "runnable-lift-segv"
                    if diag_run_rc == 139
                    else trace_result_name
                )
            )
        )
    ),
}
summary_json.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
print(json.dumps(summary, indent=2, sort_keys=True))
PY

if [[ "${RUN_RC:-1}" -ne 0 ]]; then
  mkdir -p "$DIAG_ROOT"
  log "Capturing runnable-lift retry strace stack"
  ENTRY="$(python3 - "$TRACE_SUMMARY_JSON" <<'PY'
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text())
print(summary.get("entry", ""))
PY
)"
  [[ -n "$ENTRY" ]] || die "missing entry in trace summary: $TRACE_SUMMARY_JSON"
  set +e
  timeout -k 2s 30s \
    strace -ff -k -tt -T -s 256 -o "$DIAG_STRACE_PREFIX" \
    "$TRACE_ROOT/run/runnable-lift" -entry "$ENTRY" "$TRACE_ROOT/run/probe" "$TRACE_ROOT/run/probe.bc" \
    >"$DIAG_STDOUT" 2>"$DIAG_STDERR"
  DIAG_RC="$?"
  set -e

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
        --args "$TRACE_ROOT/run/runnable-lift" -entry "$ENTRY" "$TRACE_ROOT/run/probe" "$TRACE_ROOT/run/probe.bc" \
      >"$DIAG_GDB_TXT" 2>&1
    DIAG_GDB_RC="$?"
    set -e
  else
    printf 'gdb not found in PATH; skipped gdb retry\n' >"$DIAG_GDB_TXT"
    DIAG_GDB_RC=127
  fi

  python3 - "$SUMMARY_JSON" "$DIAG_STDOUT" "$DIAG_STDERR" "$DIAG_STRACE_PREFIX" "$DIAG_GDB_TXT" "$DIAG_RC" "$DIAG_GDB_RC" "$ENTRY" "$TRACE_ROOT/run/probe" "$TRACE_ROOT/run/probe.bc" <<'PY'
import json
import re
import sys
from pathlib import Path

summary_path = Path(sys.argv[1])
diag_stdout = Path(sys.argv[2])
diag_stderr = Path(sys.argv[3])
diag_strace_prefix = sys.argv[4]
diag_gdb = Path(sys.argv[5])
diag_rc = int(sys.argv[6])
diag_gdb_rc = int(sys.argv[7])
entry = sys.argv[8]
probe_bin = sys.argv[9]
probe_bc = sys.argv[10]

summary = json.loads(summary_path.read_text())
stderr_text = diag_stderr.read_text(errors="replace") if diag_stderr.exists() else ""
stdout_text = diag_stdout.read_text(errors="replace") if diag_stdout.exists() else ""
gdb_text = diag_gdb.read_text(errors="replace") if diag_gdb.exists() else ""
segv_null = "SIGSEGV" in stderr_text and ("si_addr=NULL" in stderr_text or "si_addr=0x0" in stderr_text)
stack_text = ""
stack_source = ""
sigsegv_re = re.compile(r"SIGSEGV")
trace_frame_re = re.compile(r"^(?:\s*>\s*)?(.+\((.+?)\+0x?[0-9a-f]+\)\s+\[[0-9a-fx]+\])$")
preferred_frames = ("ptc_translate", "CodeGenerator::translate", "main")
repo_frame_needles = (
    "InstructionTranslator::preprocess",
    "InstructionTranslator::newInstruction",
    "CodeGenerator::translate",
    "ptc_temp_get",
    "main",
)

def temp_out_of_range_sources(paths):
    needles = (
        "temp_id < instructions->total_temps",
        "assert(temp_id < instructions->total_temps)",
        "ptc_temp_get",
        "temp out-of-range in preprocess",
        "qemu/linux-user/ptc.h:97",
        "qemu/linux-user/ptc.h:98",
        "qemu/linux-user/ptc.h:99",
    )
    hits = []
    for path in paths:
        if not path.exists():
            continue
        text = path.read_text(errors="replace")
        if any(needle in text for needle in needles):
            hits.append(str(path))
    return hits

def classify_failure(trace_result_name, diag_rc_value, segv_null_value, crash_function_value, temp_hits, preprocess_hit):
    if trace_result_name == "consumed:rewrite-success":
        return "passed", trace_result_name
    if temp_hits:
        return "blocked:ptc-temp-out-of-range", "ptc-temp-out-of-range"
    if crash_function_value == "InstructionTranslator::newInstruction":
        return (
            "blocked:runnable-lift-newInstruction-disassemble-null",
            "runnable-lift-newInstruction-disassemble-null",
        )
    if crash_function_value == "CodeGenerator::embeddedData":
        return (
            "blocked:runnable-lift-embeddedData-invalid-address",
            "runnable-lift-embeddedData-invalid-address",
        )
    if preprocess_hit:
        return (
            "blocked:runnable-lift-crash:InstructionTranslator::preprocess",
            "runnable-lift-crash:InstructionTranslator::preprocess",
        )
    if diag_rc_value == 139 and crash_function_value:
        return (
            f"blocked:runnable-lift-segv:{crash_function_value}",
            f"runnable-lift-segv:{crash_function_value}",
        )
    if diag_rc_value == 139:
        return "blocked:runnable-lift-segv", "runnable-lift-segv"
    if segv_null_value and trace_result_name != "consumed:rewrite-success":
        return "blocked:segv-null-after-ptc-translate", "segv-null-after-ptc-translate"
    return trace_result_name, trace_result_name

for path in sorted(Path(diag_strace_prefix).parent.glob(Path(diag_strace_prefix).name + "*")):
    lines = path.read_text(errors="replace").splitlines()
    segv_index = next((i for i, line in enumerate(lines) if sigsegv_re.search(line)), None)
    if segv_index is None:
        continue
    window_start = max(0, segv_index - 24)
    window = lines[window_start:segv_index + 1]
    window_text = "\n".join(window)
    if any(frame in window_text for frame in preferred_frames):
        stack_text = window_text
        stack_source = str(path)
        break

if not stack_text:
    for path in sorted(Path(diag_strace_prefix).parent.glob(Path(diag_strace_prefix).name + "*")):
        text = path.read_text(errors="replace")
        if "ptc_translate+" in text or "CodeGenerator::translate" in text:
            stack_text = text
            stack_source = str(path)
            break

if not stack_text and diag_stderr.exists():
    stack_text = stderr_text
    stack_source = str(diag_stderr)

trace_stderr = Path(summary.get("trace_root", "")) / "run" / "runnable-lift.stderr"
trace_stdout = Path(summary.get("trace_root", "")) / "run" / "runnable-lift.stdout"
temp_out_of_range_hits = temp_out_of_range_sources(
    [diag_stderr, trace_stderr, trace_stdout, diag_gdb]
    + sorted(Path(summary.get("trace_root", "")).glob("runnable-lift.strace*"))
    + sorted(Path(diag_strace_prefix).parent.glob(Path(diag_strace_prefix).name + "*"))
)

assertion_line = next((line.strip() for line in stderr_text.splitlines()
                       if line.startswith("Assertion failed at ")), "")
assertion_message = ""
if assertion_line:
    idx = stderr_text.splitlines().index(assertion_line)
    lines = stderr_text.splitlines()
    if idx + 1 < len(lines):
        assertion_message = lines[idx + 1].strip()
assertion_site = ""
if assertion_line:
    m = re.search(r'Assertion failed at (.+?):(\d+)', assertion_line)
    if m:
        assertion_site = f"{m.group(1)}:{m.group(2)}"

stack_lines = []
for line in stack_text.splitlines():
    if line.startswith("./runnable-lift(") or line.startswith("/"):
        stack_lines.append(line.strip())
    elif line.startswith(" > "):
        stack_lines.append(line[3:].strip())

gdb_repo_frames = []
for line in gdb_text.splitlines():
    if not line.startswith("#"):
        continue
    if not any(needle in line for needle in repo_frame_needles):
        continue
    frame_line = line.strip()
    if frame_line not in gdb_repo_frames:
        gdb_repo_frames.append(frame_line)

gdb_preprocess_hit = "InstructionTranslator::preprocess" in gdb_text
gdb_ptc_temp_hit = (
    "ptc_temp_get" in gdb_text
    or "temp_id < instructions->total_temps" in gdb_text
)

crash_function = ""
stack_top = ""
if gdb_preprocess_hit:
    crash_function = "InstructionTranslator::preprocess"
elif gdb_repo_frames:
    repo_frame_text = gdb_repo_frames[0]
    if "InstructionTranslator::newInstruction" in repo_frame_text:
        crash_function = "InstructionTranslator::newInstruction"
    elif "CodeGenerator::translate" in repo_frame_text:
        crash_function = "CodeGenerator::translate"
    elif "ptc_temp_get" in repo_frame_text:
        crash_function = "ptc_temp_get"
for line in stack_lines:
    match = trace_frame_re.match(line)
    if not match:
        continue
    frame_text = match.group(2)
    if "InstructionTranslator::newInstruction" in frame_text:
        crash_function = "InstructionTranslator::newInstruction"
        stack_top = frame_text
        break
    if not crash_function and "CodeGenerator::translate" in frame_text:
        crash_function = "CodeGenerator::translate"
        stack_top = frame_text

if not stack_top and gdb_repo_frames:
    stack_top = gdb_repo_frames[0]

if not stack_top and stack_lines:
    first_line = stack_lines[0]
    m = trace_frame_re.match(first_line)
    if m:
        stack_top = m.group(2)
        crash_function = stack_top.split("+", 1)[0]

result, failure_class = classify_failure(
    summary.get("trace_result", ""),
    diag_rc,
    segv_null,
    crash_function,
    temp_out_of_range_hits,
    gdb_preprocess_hit,
)

summary.update({
    "diag_run_rc": diag_rc,
    "diag_gdb_rc": diag_gdb_rc,
    "diag_stdout": str(diag_stdout),
    "diag_stderr": str(diag_stderr),
    "diag_gdb": str(diag_gdb),
    "diag_assertion": assertion_line,
    "diag_assertion_message": assertion_message,
    "diag_crash_site": assertion_site,
    "diag_stack_top": stack_top,
    "diag_crash_function": crash_function,
    "diag_stack_source": stack_source,
    "temp_out_of_range_sources": temp_out_of_range_hits,
    "diag_gdb_repo_frames": gdb_repo_frames[:12],
    "diag_gdb_preprocess_hit": gdb_preprocess_hit,
    "diag_gdb_ptc_temp_hit": gdb_ptc_temp_hit,
    "diag_gdb_excerpt": gdb_text.splitlines()[:80],
    "diag_repro_command": f"cd {summary.get('trace_root', '')}/run && ./runnable-lift -entry {entry} ./probe ./probe.bc",
    "diag_stdout_excerpt": stdout_text.splitlines()[:20],
    "diag_stderr_excerpt": stderr_text.splitlines()[:40],
    "result": result,
    "failure_class": failure_class,
})
summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
print(json.dumps(summary, indent=2, sort_keys=True))
PY
fi

cat "$SUMMARY_JSON"

printf 'SCRATCH_ROOT=%s\n' "$SCRATCH_ROOT"
printf 'SOURCE_ROOT=%s\n' "$SOURCE_ROOT"
printf 'SOURCE_MODEL=%s\n' "$SOURCE_MODEL"
printf 'SOURCE_SUMMARY=%s\n' "$SOURCE_SUMMARY"
printf 'SOURCE_LIBRARY=%s\n' "$SOURCE_LIBRARY"
printf 'TRACE_ROOT=%s\n' "$TRACE_ROOT"
printf 'TRACE_SUMMARY_JSON=%s\n' "$TRACE_SUMMARY_JSON"
printf 'SUMMARY_JSON=%s\n' "$SUMMARY_JSON"
