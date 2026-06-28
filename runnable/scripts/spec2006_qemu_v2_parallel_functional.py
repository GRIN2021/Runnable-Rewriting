#!/usr/bin/env python3
"""Run QEMU V2 dynamic-parallel SPEC2006 lift smoke tests.

The harness is intentionally conservative: it refuses empty-stub QEMU V2
libraries and records lift diagnostics before attempting functional comparison.
"""

import argparse
import ctypes
import datetime as _datetime
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


DEFAULT_BENCHMARKS = ["libquantum", "bzip2", "gcc", "gobmk", "perlbench", "sjeng"]

QEMU_V2_FORBIDDEN_STDERR_NEEDLES: Tuple[Tuple[str, str], ...] = (
    ("native_fallback", "native fallback"),
    ("native_executable_fallback", "native executable fallback"),
    ("empty_payload", "empty payload"),
    ("empty_qemu_v2_ptc_payload", "empty qemu v2 ptc payload"),
    ("mismatched_block_pc", "mismatched block pc"),
    ("mismatched_block", "mismatched block"),
    ("ptc_returned_mismatched_block", "ptc returned mismatched block"),
    ("returned_pc_divergence", "returned-pc divergence"),
    ("returned_block_pc_divergence", "returned block pc divergence"),
    ("block_pc_divergence", "block pc divergence"),
    ("accepted_mismatched_qemu_v2_ptc_payload", "accepted mismatched qemu v2 ptc payload"),
    ("start_trampoline", "_start trampoline"),
    ("mismatched_returned_ptc_tb", "translating mismatched returned ptc tb"),
    ("ptc_payload_parse_rejected_counts", "ptc payload parse rejected counts"),
    ("unsupported_ptc_opcode", "unsupported ptc opcode"),
    ("unsupported_opcode_schema_boundary", "unsupported opcode/schema boundary"),
    ("unsupported_opcode", "unsupported opcode"),
    ("unresolved_qemu_v2_helper", "skipping unresolved qemu v2 ptc helper"),
    ("empty_jump_target", "materializing empty jump target"),
    ("temp_out_of_range", "temp out-of-range"),
    ("out_of_range_temp", "out-of-range temp"),
    ("invalid_ptc_temp_reference", "invalid ptc temp reference"),
)

MIN_STRICT_SOURCE_INSTRUCTIONS = 16
MIN_STRICT_PAYLOAD_INSTRUCTIONS = 12
MIN_STRICT_PAYLOAD_SOURCE_RATIO = 0.50
MAX_TRUNCATED_ENTRY_REAL_IR = 6


class SmokeSpec:
    def __init__(
        self,
        argv: Sequence[str],
        *,
        stdin: Optional[str] = None,
        expected_rc: int = 0,
        files: Optional[Dict[str, str]] = None,
    ) -> None:
        self.argv = list(argv)
        self.stdin = stdin
        self.expected_rc = expected_rc
        self.files = dict(files or {})


SMOKE_SPECS: Dict[str, SmokeSpec] = {
    "libquantum": SmokeSpec(["15"]),
    "bzip2": SmokeSpec(
        ["bzip-small.txt", "1"],
        files={
            "bzip-small.txt": (
                "Runnable QEMU V2 SPEC2006 smoke input.\n"
                "This file is deliberately tiny and deterministic.\n"
            )
        },
    ),
    "gcc": SmokeSpec(
        ["-quiet", "-lang-c", "-fsyntax-only", "-"],
        stdin="int main(void) { return 0; }\n",
    ),
    "gobmk": SmokeSpec(
        ["--mode", "gtp", "--quiet"],
        stdin="protocol_version\nquit\n",
    ),
    "perlbench": SmokeSpec(["-e", 'print 2+3,"\\n"']),
    "sjeng": SmokeSpec([], stdin="quit\n"),
    "hmmer": SmokeSpec(["-h"]),
}


def log(message: str) -> None:
    print(f"[spec2006-qemu-v2] {message}", file=sys.stderr, flush=True)


def now_tag() -> str:
    return _datetime.datetime.now().strftime("%Y%m%d-%H%M%S")


def parse_csv_list(values: Sequence[str]) -> List[str]:
    result: List[str] = []
    for value in values:
        for item in value.split(","):
            item = item.strip()
            if item:
                result.append(item)
    return result


def run_command(
    argv: Sequence[str],
    *,
    cwd: Optional[Path] = None,
    env: Optional[Dict[str, str]] = None,
    stdin_text: Optional[str] = None,
    timeout_sec: int = 30,
    stdout_path: Optional[Path] = None,
    stderr_path: Optional[Path] = None,
) -> Dict[str, object]:
    started = _datetime.datetime.now(_datetime.timezone.utc)
    stdout_bytes = b""
    stderr_bytes = b""
    timed_out = False
    returncode: Optional[int] = None
    try:
        completed = subprocess.run(
            list(argv),
            cwd=str(cwd) if cwd else None,
            env=env,
            input=stdin_text.encode("utf-8") if stdin_text is not None else None,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout_sec,
            check=False,
        )
        returncode = completed.returncode
        stdout_bytes = completed.stdout
        stderr_bytes = completed.stderr
    except subprocess.TimeoutExpired as exc:
        timed_out = True
        returncode = 124
        stdout_bytes = exc.stdout or b""
        stderr_bytes = exc.stderr or b""
    finished = _datetime.datetime.now(_datetime.timezone.utc)

    if stdout_path is not None:
        stdout_path.parent.mkdir(parents=True, exist_ok=True)
        stdout_path.write_bytes(stdout_bytes)
    if stderr_path is not None:
        stderr_path.parent.mkdir(parents=True, exist_ok=True)
        stderr_path.write_bytes(stderr_bytes)

    return {
        "argv": list(argv),
        "cwd": str(cwd) if cwd else None,
        "returncode": returncode,
        "timed_out": timed_out,
        "started_utc": started.isoformat(),
        "finished_utc": finished.isoformat(),
        "duration_sec": (finished - started).total_seconds(),
        "stdout_path": str(stdout_path) if stdout_path else None,
        "stderr_path": str(stderr_path) if stderr_path else None,
        "stdout_sha256": sha256_bytes(stdout_bytes),
        "stderr_sha256": sha256_bytes(stderr_bytes),
        "stdout_size": len(stdout_bytes),
        "stderr_size": len(stderr_bytes),
    }


def sha256_bytes(data: bytes) -> str:
    import hashlib

    return hashlib.sha256(data).hexdigest()


def parse_metadata(raw: str) -> Dict[str, str]:
    fields: Dict[str, str] = {}
    for line in raw.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        fields[key.strip()] = value.strip()
    return fields


def load_libtinycode_metadata(path: Path) -> Dict[str, object]:
    result: Dict[str, object] = {
        "path": str(path),
        "exists": path.exists(),
        "raw": "",
        "fields": {},
        "load_error": None,
        "metadata_error": None,
    }
    if not path.exists():
        result["load_error"] = "missing"
        return result
    try:
        handle = ctypes.CDLL(str(path.resolve()))
    except OSError as exc:
        result["load_error"] = str(exc)
        return result
    try:
        getter = handle.ptc_get_abi_metadata
        getter.restype = ctypes.c_char_p
        raw = getter()
        decoded = (raw or b"").decode("utf-8", "replace")
        result["raw"] = decoded
        result["fields"] = parse_metadata(decoded)
    except AttributeError as exc:
        result["metadata_error"] = str(exc)
    return result


def discover_live_sidecar_replay(libtinycode: Path) -> Optional[Dict[str, Path]]:
    marker = b"ptc_live_sidecar_regen.sh"
    try:
        data = libtinycode.read_bytes()
    except OSError:
        return None

    for field in data.split(b"\0"):
        if marker not in field or not field.startswith(b"/"):
            continue
        try:
            helper = Path(field.decode("utf-8"))
        except UnicodeDecodeError:
            continue
        sidecar_root = helper.parent / "sidecar"
        payload = sidecar_root / "sidecar.payload.txt"
        model = sidecar_root / "sidecar.model.json"
        summary = sidecar_root / "sidecar.summary.json"
        if payload.is_file() and model.is_file() and summary.is_file():
            return {
                "helper": helper,
                "payload": payload,
                "model": model,
                "summary": summary,
            }
    return None


def prepare_live_sidecar_bash_env(
    *,
    runtime_dir: Path,
    metadata: Dict[str, object],
    libtinycode: Path,
) -> Optional[Dict[str, str]]:
    fields = metadata.get("fields") or {}
    if not isinstance(fields, dict):
        return None
    if fields.get("abi_version") != "2" or fields.get("bridge_kind") != "live_sidecar":
        return None
    if fields.get("request_aware") == "true":
        return None

    replay = discover_live_sidecar_replay(libtinycode)
    if replay is None:
        return None

    replay_dir = runtime_dir / "ptc-live-sidecar-replay"
    replay_dir.mkdir(parents=True, exist_ok=True)
    local_payload = replay_dir / "sidecar.payload.txt"
    local_model = replay_dir / "sidecar.model.json"
    local_summary = replay_dir / "sidecar.summary.json"
    shutil.copy2(replay["payload"], local_payload)
    shutil.copy2(replay["model"], local_model)
    shutil.copy2(replay["summary"], local_summary)

    helper_shim = Path(f"/tmp/rr_ptc_cat_{os.getpid()}.sh")
    helper_shim.write_text(
        "#!/bin/sh\n"
        f"cat {shlex.quote(str(local_payload))}\n",
        encoding="utf-8",
    )
    helper_shim.chmod(0o755)

    old_helper = str(replay["helper"]).encode("utf-8")
    new_helper = str(helper_shim).encode("utf-8")
    if len(new_helper) > len(old_helper):
        return None
    lib_data = libtinycode.read_bytes()
    helper_offset = lib_data.find(old_helper)
    if helper_offset < 0:
        return None
    patched_data = (
        lib_data[:helper_offset]
        + new_helper
        + (b"\0" * (len(old_helper) - len(new_helper)))
        + lib_data[helper_offset + len(old_helper):]
    )
    libtinycode.write_bytes(patched_data)

    bash_env = runtime_dir / "ptc-live-sidecar-replay-env.sh"
    bash_env.write_text(
        "\n".join(
            [
                "# Auto-generated by spec2006_qemu_v2_parallel_functional.py.",
                "if [[ -z \"${PTC_SIDECAR_PAYLOAD_SOURCE:-}\" ]]; then",
                f"  export PTC_SIDECAR_PAYLOAD_SOURCE={shlex.quote(str(local_payload))}",
                "fi",
                "if [[ -z \"${PTC_SIDECAR_MODEL_SOURCE:-}\" ]]; then",
                f"  export PTC_SIDECAR_MODEL_SOURCE={shlex.quote(str(local_model))}",
                "fi",
                "if [[ -z \"${PTC_SIDECAR_SUMMARY_SOURCE:-}\" ]]; then",
                f"  export PTC_SIDECAR_SUMMARY_SOURCE={shlex.quote(str(local_summary))}",
                "fi",
                "",
            ]
        ),
        encoding="utf-8",
    )
    real_bash = shutil.which("bash") or "/usr/bin/bash"
    shim_dir = runtime_dir / "ptc-live-sidecar-shims"
    shim_dir.mkdir(parents=True, exist_ok=True)
    bash_shim = shim_dir / "bash"
    bash_shim.write_text(
        "\n".join(
            [
                "#!/bin/sh",
                "case \"${1:-}\" in",
                "  *ptc_live_sidecar_regen.sh)",
                f"    cat {shlex.quote(str(local_payload))}",
                "    exit $?",
                "    ;;",
                "esac",
                f"exec {shlex.quote(real_bash)} \"$@\"",
                "",
            ]
        ),
        encoding="utf-8",
    )
    bash_shim.chmod(0o755)
    return {
        "bash_env": str(bash_env),
        "path_prepend": str(shim_dir),
        "bash_shim": str(bash_shim),
        "real_bash": real_bash,
        "helper": str(replay["helper"]),
        "helper_shim": str(helper_shim),
        "patched_libtinycode": str(libtinycode),
        "payload": str(local_payload),
        "model": str(local_model),
        "summary": str(local_summary),
        "source_payload": str(replay["payload"]),
        "source_model": str(replay["model"]),
        "source_summary": str(replay["summary"]),
    }


def require_real_qemu_v2(metadata: Dict[str, object]) -> None:
    fields = metadata.get("fields") or {}
    if not isinstance(fields, dict):
        raise RuntimeError("libtinycode metadata fields are malformed")
    if fields.get("abi_version") != "2":
        raise RuntimeError(
            f"libtinycode is not ABI v2: abi_version={fields.get('abi_version')!r}"
        )
    if fields.get("real_translation") != "true":
        raise RuntimeError(
            "libtinycode is not a real QEMU V2 translation backend: "
            f"real_translation={fields.get('real_translation')!r}"
        )


def verify_dynamic_parallel_flags(runnable_lift: Path) -> Dict[str, object]:
    help_text = ""
    stdout = b""
    stderr = b""
    result: Dict[str, object] = {
        "argv": [str(runnable_lift), "--help"],
        "returncode": None,
        "timed_out": False,
    }
    try:
        completed = subprocess.run(
            [str(runnable_lift), "--help"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
            check=False,
        )
        help_text = (completed.stdout + completed.stderr).decode("utf-8", "replace")
        result["returncode"] = completed.returncode
        stdout = completed.stdout
        stderr = completed.stderr
    except subprocess.TimeoutExpired:
        result["returncode"] = 124
        result["timed_out"] = True
    result["stdout_sha256"] = sha256_bytes(stdout)
    result["stderr_sha256"] = sha256_bytes(stderr)
    result["has_dynamic_parallel"] = "-dynamic-parallel" in help_text
    result["has_parallel_workers"] = "-parallel-workers" in help_text
    result["has_parallel_fragment_dir"] = "-parallel-fragment-dir" in help_text
    if not (
        result["has_dynamic_parallel"]
        and result["has_parallel_workers"]
        and result["has_parallel_fragment_dir"]
    ):
        raise RuntimeError("runnable-lift does not expose dynamic-parallel flags")
    return result


def copy_runtime(
    *,
    runnable_lift: Path,
    libtinycode: Path,
    helpers: Path,
    early_linked: Path,
    runtime_dir: Path,
) -> Path:
    runtime_dir.mkdir(parents=True, exist_ok=True)
    staged_lift = runtime_dir / "runnable-lift"
    shutil.copy2(runnable_lift, staged_lift)
    shutil.copy2(libtinycode, runtime_dir / "libtinycode-x86_64.so")
    shutil.copy2(helpers, runtime_dir / "libtinycode-helpers-x86_64.ll")
    shutil.copy2(early_linked, runtime_dir / "early-linked-x86_64.ll")
    staged_lift.chmod(staged_lift.stat().st_mode | 0o111)
    return staged_lift


def maybe_strip(binary: Path) -> Dict[str, object]:
    strip_tool = shutil.which("strip")
    result = {"ran": False, "tool": strip_tool, "returncode": None, "stderr": ""}
    if strip_tool is None:
        return result
    completed = subprocess.run(
        [strip_tool, str(binary)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    result["ran"] = True
    result["returncode"] = completed.returncode
    result["stderr"] = completed.stderr.decode("utf-8", "replace")
    return result


def prepare_smoke_files(spec: SmokeSpec, work_dir: Path) -> None:
    for relative, content in spec.files.items():
        path = work_dir / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")


def exe_args_string(argv: Sequence[str]) -> str:
    return " ".join(shlex.quote(item) for item in argv)


def ll_stats(path: Path) -> Dict[str, object]:
    stats: Dict[str, object] = {
        "exists": path.exists(),
        "bytes": 0,
        "lines": 0,
        "define_count": 0,
        "instructionish_count": 0,
    }
    if not path.exists():
        return stats
    data = path.read_text(encoding="utf-8", errors="replace")
    stats["bytes"] = path.stat().st_size
    stats["lines"] = data.count("\n")
    stats["define_count"] = sum(1 for line in data.splitlines() if line.startswith("define "))
    stats["instructionish_count"] = sum(
        1
        for line in data.splitlines()
        if line.startswith("  ")
        and not line.lstrip().startswith(";")
        and any(token in line for token in ("=", "call ", "br ", "ret "))
    )
    return stats


def read_text_tail(path: Path, max_bytes: int = 65536) -> str:
    if not path.exists():
        return ""
    data = path.read_bytes()
    if len(data) > max_bytes:
        data = data[-max_bytes:]
    return data.decode("utf-8", "replace")


def _parse_int(value: object) -> Optional[int]:
    if value is None:
        return None
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        try:
            return int(text, 0)
        except ValueError:
            return None
    return None


def _normal_pc(value: object) -> Optional[str]:
    parsed = _parse_int(value)
    if parsed is not None:
        return f"0x{parsed:x}"
    if isinstance(value, str) and value.strip():
        return value.strip().lower()
    return None


def _read_json_object(path: Path) -> Tuple[Optional[Dict[str, object]], Optional[str]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        return None, str(exc)
    except json.JSONDecodeError as exc:
        return None, str(exc)
    if not isinstance(data, dict):
        return None, "json root is not an object"
    return data, None


def parse_sidecar_payload_header(path: Path) -> Dict[str, object]:
    result: Dict[str, object] = {
        "path": str(path),
        "exists": path.exists(),
        "fields": {},
        "error": None,
    }
    if not path.exists():
        result["error"] = "missing"
        return result

    fields: Dict[str, str] = {}
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                if line.startswith("instruction|") or line.startswith("temp|"):
                    break
                if "=" not in line:
                    continue
                key, value = line.split("=", 1)
                fields[key.strip()] = value.strip()
    except OSError as exc:
        result["error"] = str(exc)
    result["fields"] = fields
    return result


def find_forbidden_qemu_v2_stderr(stderr_path: Path) -> List[Dict[str, str]]:
    stderr = read_text_tail(stderr_path).lower()
    matches: List[Dict[str, str]] = []
    for code, needle in QEMU_V2_FORBIDDEN_STDERR_NEEDLES:
        if needle in stderr:
            matches.append({"code": code, "needle": needle})
    return matches


def inspect_sidecar_payload(
    *,
    summary_path: Optional[Path],
    payload_path: Optional[Path],
) -> Dict[str, object]:
    result: Dict[str, object] = {
        "status": "not_available",
        "summary_path": str(summary_path) if summary_path else None,
        "payload_path": str(payload_path) if payload_path else None,
        "reasons": [],
        "metrics": {},
        "entry_pc": None,
        "summary": None,
        "payload_header": None,
    }
    reasons: List[str] = []

    summary: Optional[Dict[str, object]] = None
    if summary_path is not None:
        if not summary_path.exists():
            reasons.append("sidecar_summary_missing")
        else:
            summary, error = _read_json_object(summary_path)
            if error is not None:
                reasons.append("sidecar_summary_unreadable")
                result["summary_error"] = error

    payload_header: Optional[Dict[str, object]] = None
    if payload_path is not None:
        payload_header = parse_sidecar_payload_header(payload_path)
        if payload_header.get("error"):
            reasons.append("sidecar_payload_unreadable")

    if summary is None and payload_header is None and not reasons:
        return result

    result["summary"] = summary
    result["payload_header"] = payload_header
    requested_pc = _normal_pc((summary or {}).get("canonical_requested_pc"))
    captured_pc = _normal_pc((summary or {}).get("captured_actual_pc"))
    first_debug_pc = _normal_pc((summary or {}).get("first_debug_insn_start_pc"))
    entry_pc = requested_pc or captured_pc or first_debug_pc
    result["entry_pc"] = entry_pc

    if requested_pc and captured_pc and requested_pc != captured_pc:
        reasons.append("sidecar_mismatched_requested_actual_pc")
    if requested_pc and first_debug_pc and requested_pc != first_debug_pc:
        reasons.append("sidecar_mismatched_requested_debug_pc")

    summary_payload_count = _parse_int((summary or {}).get("payload_instruction_count"))
    selected_count = _parse_int((summary or {}).get("selected_instruction_count"))
    source_count = _parse_int((summary or {}).get("source_instruction_count"))
    rejected_count = _parse_int((summary or {}).get("rejected_instruction_count"))
    rejected_instruction = (summary or {}).get("rejected_instruction")

    payload_fields = {}
    if isinstance(payload_header, dict) and isinstance(payload_header.get("fields"), dict):
        payload_fields = payload_header["fields"]  # type: ignore[assignment]
    payload_header_count = _parse_int(payload_fields.get("instruction_count"))
    payload_count = summary_payload_count
    if payload_count is None:
        payload_count = selected_count
    if payload_count is None:
        payload_count = payload_header_count

    result["metrics"] = {
        "requested_pc": requested_pc,
        "captured_pc": captured_pc,
        "first_debug_pc": first_debug_pc,
        "payload_instruction_count": payload_count,
        "summary_payload_instruction_count": summary_payload_count,
        "selected_instruction_count": selected_count,
        "source_instruction_count": source_count,
        "payload_header_instruction_count": payload_header_count,
        "rejected_instruction_count": rejected_count,
        "rejected_instruction": rejected_instruction,
    }

    if rejected_count and rejected_count > 0:
        reasons.append("sidecar_rejected_instruction")
    if rejected_instruction not in (None, "", "null"):
        reasons.append("sidecar_rejected_instruction")
    if (
        payload_count is not None
        and payload_header_count is not None
        and payload_count != payload_header_count
    ):
        reasons.append("sidecar_payload_header_count_mismatch")
    if (
        payload_count is not None
        and source_count is not None
        and source_count >= MIN_STRICT_SOURCE_INSTRUCTIONS
        and payload_count <= MIN_STRICT_PAYLOAD_INSTRUCTIONS
        and (payload_count / max(source_count, 1)) < MIN_STRICT_PAYLOAD_SOURCE_RATIO
    ):
        reasons.append("sidecar_short_payload_vs_source")

    result["reasons"] = sorted(set(reasons))
    result["status"] = "failed" if result["reasons"] else "passed"
    return result


def inspect_ll_entry_block(path: Path, entry_pc: Optional[str]) -> Dict[str, object]:
    result: Dict[str, object] = {
        "status": "not_available",
        "path": str(path),
        "exists": path.exists(),
        "entry_pc": entry_pc,
        "block_label": None,
        "found": False,
        "line_number": None,
        "instruction_count_before_terminator": 0,
        "real_ir_count_before_terminator": 0,
        "terminator": None,
        "newpc_payload_length": None,
        "reasons": [],
        "sample": [],
    }
    if entry_pc is None:
        return result
    if not path.exists():
        result["status"] = "failed"
        result["reasons"] = ["ll_missing"]
        return result

    label = f"bb.{entry_pc}"
    result["block_label"] = label
    label_re = re.compile(rf"^{re.escape(label)}:\s*(?:;.*)?$", re.IGNORECASE)
    next_label_re = re.compile(r"^(?:[A-Za-z$._-][A-Za-z$._0-9-]*|\d+):\s*(?:;.*)?$")
    newpc_re = re.compile(r"@newpc\(\s*i64\s+[^,]+,\s*i64\s+([0-9]+)")

    in_block = False
    instructions = 0
    real_ir = 0
    terminator: Optional[str] = None
    sample: List[str] = []
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line_number, raw_line in enumerate(handle, start=1):
                line = raw_line.rstrip("\n")
                stripped = line.strip()
                if not in_block:
                    if label_re.match(line):
                        in_block = True
                        result["found"] = True
                        result["line_number"] = line_number
                    continue
                if next_label_re.match(line):
                    break
                if len(sample) < 16:
                    sample.append(line)
                if not stripped or stripped.startswith(";"):
                    continue

                match = newpc_re.search(stripped)
                if match is not None:
                    result["newpc_payload_length"] = int(match.group(1))

                if stripped.startswith("unreachable"):
                    terminator = "unreachable"
                    break
                if stripped.startswith("br "):
                    terminator = "br"
                    break
                if stripped.startswith("ret "):
                    terminator = "ret"
                    break
                if stripped.startswith("switch "):
                    terminator = "switch"
                    break
                if stripped.startswith("indirectbr "):
                    terminator = "indirectbr"
                    break

                instructions += 1
                if "@newpc(" in stripped or "@llvm.dbg." in stripped:
                    continue
                real_ir += 1
    except OSError as exc:
        result["status"] = "failed"
        result["reasons"] = ["ll_unreadable"]
        result["error"] = str(exc)
        return result

    result["instruction_count_before_terminator"] = instructions
    result["real_ir_count_before_terminator"] = real_ir
    result["terminator"] = terminator
    result["sample"] = sample

    reasons: List[str] = []
    if not result["found"]:
        reasons.append("ll_entry_block_missing")
    elif terminator == "unreachable" and real_ir <= MAX_TRUNCATED_ENTRY_REAL_IR:
        reasons.append("ll_entry_block_truncated_unreachable")
    elif terminator is None:
        reasons.append("ll_entry_block_missing_terminator")

    result["reasons"] = reasons
    result["status"] = "failed" if reasons else "passed"
    return result


def qemu_v2_artifact_checks(
    *,
    stderr_path: Path,
    ll_path: Path,
    sidecar_summary_path: Optional[Path] = None,
    sidecar_payload_path: Optional[Path] = None,
) -> Dict[str, object]:
    stderr_matches = find_forbidden_qemu_v2_stderr(stderr_path)
    sidecar = inspect_sidecar_payload(
        summary_path=sidecar_summary_path,
        payload_path=sidecar_payload_path,
    )
    entry_pc = sidecar.get("entry_pc") if isinstance(sidecar, dict) else None
    ll_entry = inspect_ll_entry_block(
        ll_path,
        entry_pc if isinstance(entry_pc, str) else None,
    )

    reasons: List[str] = [f"stderr:{item['code']}" for item in stderr_matches]
    sidecar_reasons = sidecar.get("reasons") if isinstance(sidecar, dict) else []
    if isinstance(sidecar_reasons, list):
        reasons.extend(f"sidecar:{reason}" for reason in sidecar_reasons)
    ll_reasons = ll_entry.get("reasons") if isinstance(ll_entry, dict) else []
    if isinstance(ll_reasons, list):
        reasons.extend(f"ll:{reason}" for reason in ll_reasons)

    return {
        "status": "failed" if reasons else "passed",
        "reasons": sorted(set(reasons)),
        "stderr_forbidden_matches": stderr_matches,
        "sidecar": sidecar,
        "ll_entry_block": ll_entry,
    }


def classify_lift(
    returncode: int,
    timed_out: bool,
    stderr_path: Path,
    stats: Dict[str, object],
    qemu_checks: Optional[Dict[str, object]] = None,
) -> str:
    stderr = read_text_tail(stderr_path).lower()
    if timed_out:
        return "timeout"
    if returncode != 0:
        if "real_translation=false" in stderr or "empty-stub" in stderr:
            return "rejected_empty_stub"
        if (qemu_checks or {}).get("status") == "failed":
            return "failed_qemu_v2_ptc_payload"
        return "failed"
    if (qemu_checks or {}).get("status") == "failed":
        return "failed_qemu_v2_artifact_checks"
    if not stats.get("exists") or int(stats.get("instructionish_count") or 0) == 0:
        return "empty_or_nonmeaningful_ll"
    return "passed"


def build_tool_path(args: argparse.Namespace) -> str:
    parts: List[str] = []
    if args.llvm_bin_dir:
        parts.append(str(args.llvm_bin_dir))
    if args.repo_root:
        parts.append(str(args.repo_root / "build-codex-dynamic-current"))
    parts.append(os.environ.get("PATH", ""))
    return os.pathsep.join(parts)


def find_dynamic_merge_script(args: argparse.Namespace) -> Optional[Path]:
    candidates: List[Path] = []
    candidates.append(args.repo_root / "runnable" / "scripts" / "merge_dynamic_runnable_fragments.py")
    for parent in args.runnable_lift.parents:
        candidates.append(parent / "merge_dynamic_runnable_fragments.py")
    candidates.extend(
        [
            args.repo_root / "build-codex-dynamic-current" / "merge_dynamic_runnable_fragments.py",
        ]
    )
    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()
    return None


def compile_translated(
    *,
    args: argparse.Namespace,
    bench_dir: Path,
    binary: Path,
) -> Dict[str, object]:
    env = os.environ.copy()
    env["PATH"] = build_tool_path(args)
    missing = [tool for tool in ("llvm-link", "llc", "opt") if shutil.which(tool, path=env["PATH"]) is None]
    driver = args.runnable_driver
    result: Dict[str, object] = {
        "status": "not_run",
        "missing_tools": missing,
        "driver": str(driver),
        "command": None,
        "translated_path": str(binary) + ".translated",
    }
    if missing:
        result["status"] = "blocked_missing_llvm_tools"
        return result
    if not driver.exists():
        result["status"] = "blocked_missing_runnable_driver"
        return result
    stdout = bench_dir / "translate.stdout.log"
    stderr = bench_dir / "translate.stderr.log"
    command = [str(driver), "translate", "-s", str(binary)]
    result["command"] = command
    run = run_command(
        command,
        cwd=args.repo_root,
        env=env,
        timeout_sec=args.compile_timeout_sec,
        stdout_path=stdout,
        stderr_path=stderr,
    )
    result["run"] = run
    translated = Path(str(binary) + ".translated")
    if run["timed_out"]:
        result["status"] = "timeout"
    elif run["returncode"] != 0:
        result["status"] = "failed"
    elif not translated.exists():
        result["status"] = "missing_translated_executable"
    else:
        result["status"] = "passed"
    return result


def run_functional_pair(
    *,
    bench: str,
    spec: SmokeSpec,
    bench_dir: Path,
    original: Path,
    translated: Path,
    timeout_sec: int,
) -> Dict[str, object]:
    prepare_smoke_files(spec, bench_dir)
    original_run = run_command(
        [str(original), *spec.argv],
        cwd=bench_dir,
        stdin_text=spec.stdin,
        timeout_sec=timeout_sec,
        stdout_path=bench_dir / "original.stdout",
        stderr_path=bench_dir / "original.stderr",
    )
    translated_run = run_command(
        [str(translated), *spec.argv],
        cwd=bench_dir,
        stdin_text=spec.stdin,
        timeout_sec=timeout_sec,
        stdout_path=bench_dir / "translated.stdout",
        stderr_path=bench_dir / "translated.stderr",
    )
    stdout_equal = (
        (bench_dir / "original.stdout").read_bytes()
        == (bench_dir / "translated.stdout").read_bytes()
    )
    stderr_equal = (
        (bench_dir / "original.stderr").read_bytes()
        == (bench_dir / "translated.stderr").read_bytes()
    )
    rc_equal = original_run["returncode"] == translated_run["returncode"]
    status = "passed" if rc_equal and stdout_equal and stderr_equal else "mismatch"
    return {
        "benchmark": bench,
        "status": status,
        "expected_original_rc": spec.expected_rc,
        "original": original_run,
        "translated": translated_run,
        "returncode_equal": rc_equal,
        "stdout_equal": stdout_equal,
        "stderr_equal": stderr_equal,
    }


def run_one_benchmark(
    *,
    args: argparse.Namespace,
    staged_lift: Path,
    lift_env: Optional[Dict[str, str]],
    ptc_replay: Optional[Dict[str, str]],
    benchmark: str,
    run_dir: Path,
) -> Dict[str, object]:
    binary_src = args.spec_root / f"{benchmark}_base.x86.{args.opt}"
    bench_dir = run_dir / benchmark
    bench_dir.mkdir(parents=True, exist_ok=True)
    result: Dict[str, object] = {
        "benchmark": benchmark,
        "source_binary": str(binary_src),
        "status": "not_run",
    }
    if benchmark not in SMOKE_SPECS:
        result["status"] = "skipped_missing_smoke_spec"
        return result
    if not binary_src.exists():
        result["status"] = "skipped_missing_binary"
        return result

    staged_binary = bench_dir / binary_src.name
    shutil.copy2(binary_src, staged_binary)
    result["staged_binary"] = str(staged_binary)
    if args.strip:
        result["strip"] = maybe_strip(staged_binary)

    smoke_spec = SMOKE_SPECS[benchmark]
    prepare_smoke_files(smoke_spec, bench_dir)
    original_smoke = run_command(
        [str(staged_binary), *smoke_spec.argv],
        cwd=bench_dir,
        stdin_text=smoke_spec.stdin,
        timeout_sec=args.functional_timeout_sec,
        stdout_path=bench_dir / "original.pre_lift.stdout",
        stderr_path=bench_dir / "original.pre_lift.stderr",
    )
    result["original_pre_lift"] = original_smoke

    ll_path = bench_dir / f"{staged_binary.name}.ll"
    fragment_dir = bench_dir / "fragments"
    fragment_dir.mkdir(parents=True, exist_ok=True)
    lift_stdout = bench_dir / "lift.stdout.log"
    lift_stderr = bench_dir / "lift.stderr.log"
    command = [
        str(staged_lift),
        "-dynamic-parallel",
        f"-parallel-workers={args.workers}",
        f"-parallel-fragment-dir={fragment_dir}",
    ]
    if smoke_spec.argv:
        command.append(f"-exe-args={exe_args_string(smoke_spec.argv)}")
    command.extend([str(staged_binary), str(ll_path)])
    log(f"lifting {benchmark}: {' '.join(shlex.quote(x) for x in command)}")
    lift_run = run_command(
        command,
        cwd=bench_dir,
        env=lift_env,
        timeout_sec=args.lift_timeout_sec,
        stdout_path=lift_stdout,
        stderr_path=lift_stderr,
    )
    stats = ll_stats(ll_path)
    sidecar_summary_path: Optional[Path] = None
    sidecar_payload_path: Optional[Path] = None
    if ptc_replay is not None:
        summary_value = ptc_replay.get("summary")
        payload_value = ptc_replay.get("payload")
        sidecar_summary_path = Path(summary_value) if summary_value else None
        sidecar_payload_path = Path(payload_value) if payload_value else None
    qemu_checks = qemu_v2_artifact_checks(
        stderr_path=lift_stderr,
        ll_path=ll_path,
        sidecar_summary_path=sidecar_summary_path,
        sidecar_payload_path=sidecar_payload_path,
    )
    lift_status = classify_lift(
        int(lift_run["returncode"] or 0),
        bool(lift_run["timed_out"]),
        lift_stderr,
        stats,
        qemu_checks,
    )
    result["lift"] = {
        "status": lift_status,
        "run": lift_run,
        "ll_path": str(ll_path),
        "ll_stats": stats,
        "qemu_v2_checks": qemu_checks,
        "stderr_tail": read_text_tail(lift_stderr, max_bytes=8192),
    }

    if lift_status != "passed" and not args.compile_degraded:
        result["functional"] = {"status": f"blocked_by_lift:{lift_status}"}
        result["status"] = result["functional"]["status"]
        return result

    compile_result = compile_translated(args=args, bench_dir=bench_dir, binary=staged_binary)
    result["compile"] = compile_result
    if compile_result["status"] != "passed":
        result["functional"] = {"status": f"blocked_by_compile:{compile_result['status']}"}
        result["status"] = result["functional"]["status"]
        return result

    translated = Path(str(staged_binary) + ".translated")
    functional = run_functional_pair(
        bench=benchmark,
        spec=smoke_spec,
        bench_dir=bench_dir,
        original=staged_binary,
        translated=translated,
        timeout_sec=args.functional_timeout_sec,
    )
    result["functional"] = functional
    result["status"] = f"functional:{functional['status']}"
    return result


def write_summary(run_dir: Path, manifest: Dict[str, object]) -> None:
    rows = ["benchmark\tlift_status\tll_instructionish\tfunctional_status"]
    for item in manifest.get("benchmarks", []):
        if not isinstance(item, dict):
            continue
        lift = item.get("lift") or {}
        functional = item.get("functional") or {}
        stats = (lift.get("ll_stats") if isinstance(lift, dict) else {}) or {}
        rows.append(
            "\t".join(
                [
                    str(item.get("benchmark", "")),
                    str(lift.get("status", "")) if isinstance(lift, dict) else "",
                    str(stats.get("instructionish_count", "")) if isinstance(stats, dict) else "",
                    str(functional.get("status", "")) if isinstance(functional, dict) else "",
                ]
            )
        )
    (run_dir / "summary.tsv").write_text("\n".join(rows) + "\n", encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    repo_root = Path(__file__).resolve().parents[2]
    build_dir = repo_root / "build-codex-dynamic-current"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=repo_root)
    parser.add_argument(
        "--runnable-lift",
        type=Path,
        default=build_dir / "tools" / "runnable-lift" / "runnable-lift",
    )
    parser.add_argument(
        "--runnable-driver",
        type=Path,
        default=build_dir / "runnable",
    )
    parser.add_argument(
        "--libtinycode",
        type=Path,
        required=True,
        help="QEMU V2 libtinycode-x86_64.so; must report abi_version=2 and real_translation=true.",
    )
    parser.add_argument("--helpers", type=Path, required=True)
    parser.add_argument("--early-linked", type=Path, required=True)
    parser.add_argument("--spec-root", type=Path, default=repo_root / "test" / "spec")
    parser.add_argument("--output-root", type=Path, default=Path("/hdd/runnable-spec2006-qemu-v2-functional"))
    parser.add_argument("--benchmarks", nargs="+", default=DEFAULT_BENCHMARKS)
    parser.add_argument("--opt", default="O2")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--lift-timeout-sec", type=int, default=180)
    parser.add_argument("--compile-timeout-sec", type=int, default=180)
    parser.add_argument("--functional-timeout-sec", type=int, default=15)
    parser.add_argument("--llvm-bin-dir", type=Path)
    parser.add_argument("--no-strip", dest="strip", action="store_false")
    parser.add_argument("--compile-degraded", action="store_true")
    parser.set_defaults(strip=True)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.repo_root = args.repo_root.resolve()
    args.runnable_lift = args.runnable_lift.resolve()
    args.runnable_driver = args.runnable_driver.resolve()
    args.libtinycode = args.libtinycode.resolve()
    args.helpers = args.helpers.resolve()
    args.early_linked = args.early_linked.resolve()
    args.spec_root = args.spec_root.resolve()
    benchmarks = parse_csv_list(args.benchmarks)

    for path, label in (
        (args.runnable_lift, "runnable-lift"),
        (args.libtinycode, "libtinycode"),
        (args.helpers, "helpers"),
        (args.early_linked, "early-linked"),
        (args.spec_root, "spec root"),
    ):
        if not path.exists():
            parser.error(f"missing {label}: {path}")

    help_check = verify_dynamic_parallel_flags(args.runnable_lift)
    metadata = load_libtinycode_metadata(args.libtinycode)
    require_real_qemu_v2(metadata)

    run_dir = args.output_root / now_tag()
    runtime_dir = run_dir / "runtime"
    run_dir.mkdir(parents=True, exist_ok=True)

    manifest: Dict[str, object] = {
        "run_dir": str(run_dir),
        "created_utc": _datetime.datetime.now(_datetime.timezone.utc).isoformat(),
        "repo_root": str(args.repo_root),
        "runnable_lift": str(args.runnable_lift),
        "runnable_driver": str(args.runnable_driver),
        "spec_root": str(args.spec_root),
        "opt": args.opt,
        "workers": args.workers,
        "requested_benchmarks": benchmarks,
        "runnable_lift_help_check": help_check,
        "libtinycode_metadata": metadata,
    }
    staged_lift = copy_runtime(
        runnable_lift=args.runnable_lift,
        libtinycode=args.libtinycode,
        helpers=args.helpers,
        early_linked=args.early_linked,
        runtime_dir=runtime_dir,
    )
    manifest["staged_runnable_lift"] = str(staged_lift)
    lift_env = os.environ.copy()
    lift_env["RUNNABLE_REPO_ROOT"] = str(args.repo_root)
    dynamic_merge_script = find_dynamic_merge_script(args)
    if dynamic_merge_script is not None:
        lift_env["RUNNABLE_DYNAMIC_MERGE_SCRIPT"] = str(dynamic_merge_script)
        lift_env["RUNNABLE_BUILD_DIR"] = str(dynamic_merge_script.parent)
        manifest["dynamic_merge_script"] = str(dynamic_merge_script)
    lift_env["PATH"] = build_tool_path(args)
    replay_env = prepare_live_sidecar_bash_env(
        runtime_dir=runtime_dir,
        metadata=metadata,
        libtinycode=runtime_dir / "libtinycode-x86_64.so",
    )
    if replay_env is not None:
        lift_env["BASH_ENV"] = replay_env["bash_env"]
        lift_env["PATH"] = replay_env["path_prepend"] + os.pathsep + lift_env.get("PATH", "")
        manifest["ptc_live_sidecar_replay"] = replay_env

    benchmark_results: List[Dict[str, object]] = []
    for benchmark in benchmarks:
        benchmark_results.append(
            run_one_benchmark(
                args=args,
                staged_lift=staged_lift,
                lift_env=lift_env,
                ptc_replay=replay_env,
                benchmark=benchmark,
                run_dir=run_dir,
            )
        )
        manifest["benchmarks"] = benchmark_results
        (run_dir / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8"
        )
        write_summary(run_dir, manifest)

    log(f"wrote {run_dir / 'manifest.json'}")
    log(f"wrote {run_dir / 'summary.tsv'}")
    print(run_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
