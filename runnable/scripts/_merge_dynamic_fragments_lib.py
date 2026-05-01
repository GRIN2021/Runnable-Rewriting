#!/usr/bin/env python3

import argparse
import csv
import json
import os
import re
import shlex
import struct
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath
from typing import Dict, Iterable, List, Optional, Tuple

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONTAINER_NAME = "runnable-parallel-lift-legacy"
DEFAULT_RUN_DIR = REPO_ROOT
DEFAULT_OUT_DIR = DEFAULT_RUN_DIR / "out" / "runnable-parallel-lift-legacy"
DEFAULT_FUNCS_CSV = DEFAULT_RUN_DIR / "dataset" / "libcrypto.funcs.csv"
DEFAULT_REFERENCE_LL = DEFAULT_OUT_DIR / "reference.ll"
DEFAULT_GROUND_TRUTH = DEFAULT_RUN_DIR / "dataset" / "libcrypto.so"
DEFAULT_RUN_CMP_EVAL = DEFAULT_RUN_DIR / "test" / "cmp_instruction.py"
DEFAULT_CONTAINER_WORKDIR = "/workdir"
DEFAULT_CONTAINER_BINARY = "/workdir/libcrypto.so"
DEFAULT_RUNNABLE_LIFT = "runnable-lift"
DEFAULT_CSV_IMAGE_BASE = 0x400000

LL_COMMENT_RE = re.compile(r"^\s*;\s*(0x[0-9a-fA-F]+):(.*)$")
ROOT_LABEL_RE = re.compile(r"^([A-Za-z$._0-9-]+):")
ROOT_BLOCK_LABEL_RE = re.compile(r"^bb\.0x([0-9a-fA-F]+)")
ROOT_SYMBOLIC_BLOCK_RE = re.compile(r"^(bb\.[A-Za-z$._0-9-]+?)(?:\.0x([0-9a-fA-F]+))?(?:$|[._].*)")
ROOT_CASE_RE = re.compile(r"^\s*i64\s+(\d+),\s+label\s+%([A-Za-z$._0-9-]+)")
SWITCH_CASE_RE = re.compile(r"^\s*i\d+\s+(-?\d+),\s+label\s+%[A-Za-z$._0-9-]+")
ANON_BLOCK_LABEL_RE = re.compile(r"^\s*;\s*<label>:(\d+):")
SET_REGISTER_CASE_RE = re.compile(r"^\s*i32\s+(-?\d+),\s+label\s+%(\d+)")
DISAM_GLOBAL_RE = re.compile(r"^(@disam_0x[0-9A-Za-z_.]+)\s*=\s*(.*)$")
DISAM_REF_RE = re.compile(r"@disam_0x[0-9A-Za-z_.]+")
GLOBAL_DEF_RE = re.compile(r"^(@[A-Za-z$._0-9-]+)\s*=\s*(.*)$")
GLOBAL_REF_RE = re.compile(r"@[A-Za-z$._0-9-]+")
I8_ARRAY_GLOBAL_DEF_RE = re.compile(
    r"^(@[A-Za-z$._0-9-]+)\s*=.*\[(\d+) x i8\]\s+c(?:\"|')"
)
I8_ARRAY_GEP_REF_RE = re.compile(
    r"\[(\d+) x i8\], \[(\d+) x i8\]\* (@[A-Za-z$._0-9-]+)"
)
I8_ARRAY_PTR_CAST_RE = re.compile(
    r"\[(\d+) x i8\]\* (@[A-Za-z$._0-9-]+)(?= to i8\*)"
)
LIFTED_STATE_GLOBAL_RE = re.compile(
    r"@(state_0x[0-9A-Fa-f]+|pc|r(?:ax|bx|cx|dx|bp|sp|si|di|8|9|10|11|12|13|14|15)|"
    r"cc_(?:op|src|dst)|exception_index|cpu_loop_exiting)\b"
)
CPUX86STATE_GEP_RE = re.compile(r"getelementptr(?: inbounds)? %struct\.CPUX86State")
TYPE_DEF_RE = re.compile(r"^(%[A-Za-z$._0-9-]+)\s*=\s*type\s+(.*)$")
METADATA_DEF_RE = re.compile(r"^!(\d+)\s*=\s*(.*)$")
METADATA_REF_RE = re.compile(r"!(\d+)")
DEBUG_ATTACHMENT_RE = re.compile(r", !dbg !\d+")
DEBUG_INLINE_RE = re.compile(r"\s*!dbg !\d+")
ROOT_DROP_METADATA_RE = re.compile(
    r", !(?:alias\.scope|noalias|oi|pi) !\d+"
)
LOCAL_VALUE_RE = re.compile(r"%(\d+)\b")
DISAM_ADDR_RE = re.compile(r"0x([0-9a-fA-F]+):")
NEWPC_ADDR_RE = re.compile(r"@newpc\(i64\s+(\d+),")
PC_STORE_ADDR_RE = re.compile(r"store i64\s+(\d+), i64\* @pc")
REFERENCE_ENTRY_RE = re.compile(r"entry_0x([0-9a-fA-F]+)")
ROOT_COMMON_LABELS = {
    "entrypoint",
    "dispatcher.entry",
    "dispatcher.default",
    "anypc",
    "unexpectedpc",
    "serialize_and_jump_out",
    "return_from_external",
    "setjmp",
    "dispatcher.external",
}
ROOT_RICH_COMMON_LABELS = {
    "serialize_and_jump_out",
    "return_from_external",
}
ROOT_COMMON_FEATURE_REFS = (
    "@pc",
    "@rax",
    "@rbx",
    "@rcx",
    "@rdx",
    "@rbp",
    "@rsp",
    "@rsi",
    "@rdi",
    "@r8",
    "@r9",
    "@r10",
    "@r11",
    "@r12",
    "@r13",
    "@r14",
    "@r15",
    "@state_0x8558",
    "@state_0x8598",
    "@state_0x85d8",
    "@state_0x8618",
    "@state_0x8658",
    "@state_0x8698",
    "@state_0x86d8",
    "@state_0x8718",
)
SERIALIZE_GPRS = (
    ("rax", "@rax"),
    ("rbx", "@rbx"),
    ("rcx", "@rcx"),
    ("rdx", "@rdx"),
    ("rbp", "@rbp"),
    ("rsp", "@rsp"),
    ("rsi", "@rsi"),
    ("rdi", "@rdi"),
    ("r8", "@r8"),
    ("r9", "@r9"),
    ("r10", "@r10"),
    ("r11", "@r11"),
    ("r12", "@r12"),
    ("r13", "@r13"),
    ("r14", "@r14"),
    ("r15", "@r15"),
)
XMM_STATE_GLOBALS = (
    ("xmm0", "@state_0x8558"),
    ("xmm1", "@state_0x8598"),
    ("xmm2", "@state_0x85d8"),
    ("xmm3", "@state_0x8618"),
    ("xmm4", "@state_0x8658"),
    ("xmm5", "@state_0x8698"),
    ("xmm6", "@state_0x86d8"),
    ("xmm7", "@state_0x8718"),
)
RETURN_FROM_EXTERNAL_SLOTS = (
    ("pc", "@pc", 16),
    ("rax", "@rax", 13),
    ("rbx", "@rbx", 11),
    ("rcx", "@rcx", 14),
    ("rdx", "@rdx", 12),
    ("rbp", "@rbp", 10),
    ("rsp", "@rsp", 15),
    ("rsi", "@rsi", 9),
    ("rdi", "@rdi", 8),
    ("r8", "@r8", 0),
    ("r9", "@r9", 1),
    ("r10", "@r10", 2),
    ("r11", "@r11", 3),
    ("r12", "@r12", 4),
    ("r13", "@r13", 5),
    ("r14", "@r14", 6),
    ("r15", "@r15", 7),
)


@dataclass(frozen=True)
class ShardJob:
    index: int
    start: int
    end_inclusive: int
    name: str
    range_min: int
    range_max: int
    exact_end_exclusive: int

    @property
    def tag(self) -> str:
        return f"fn_{self.start:016x}"


@dataclass(frozen=True)
class RootBlockSegment:
    label: str
    base_addr: int
    order_index: int
    lines: List[str]


@dataclass(frozen=True)
class ParsedRoot:
    define_line: str
    entry_label: str
    entry_allocas: List[str]
    entry_rest: List[str]
    dispatcher_prefix: List[str]
    dispatcher_footer: List[str]
    dispatcher_cases: Dict[int, str]
    common_segments: Dict[str, List[str]]
    translated_segments: List[RootBlockSegment]
    globals: Dict[str, str]
    disam_globals: Dict[str, str]
    metadata_defs: Dict[int, str]


@dataclass(frozen=True)
class ParsedModule:
    type_defs_by_name: Dict[str, str]
    globals_by_name: Dict[str, List[str]]
    functions_by_name: Dict[str, List[str]]
    function_kinds: Dict[str, str]
    type_order: List[str]
    global_order: List[str]
    function_order: List[str]


class Config:
    def __init__(self, args: argparse.Namespace):
        self.container_name = args.container_name
        self.run_dir = args.run_dir.resolve()
        self.out_dir = args.out_dir.resolve()
        self.funcs_csv = args.funcs_csv.resolve()
        self.reference_ll = args.reference_ll.resolve()
        self.ground_truth_binary = args.ground_truth_binary.resolve()
        self.run_cmp_eval = args.run_cmp_eval.resolve()
        self.container_workdir = PurePosixPath(args.container_workdir)
        self.container_binary = args.container_binary
        self.runnable_lift = args.runnable_lift
        self.rebase_base = args.rebase_base
        self.csv_image_base = args.csv_image_base
        self.range_margin = args.range_margin
        self.func_timeout = args.func_timeout
        self.workers = args.workers
        self.max_repair_rounds = args.max_repair_rounds
        self.repair_timeout_multiplier = args.repair_timeout_multiplier
        self.repair_margin_step = args.repair_margin_step
        self.limit = args.limit
        self.super_fast = args.super_fast
        self.rerun_all_on_metric_gap = args.rerun_all_on_metric_gap
        self.force = args.force
        self.keep_raw_on_success = args.keep_raw_on_success
        self.shards_dir = self.out_dir / "shards"
        self.raw_dir = self.out_dir / "raw"
        self.eval_dir = self.out_dir / "eval"
        self.round_reports_dir = self.out_dir / "round_reports"
        self.logs_dir = self.out_dir / "logs"
        self.manifest_json = self.out_dir / "shard_results.json"
        self.manifest_jsonl = self.out_dir / "shard_results.jsonl"
        self.status_json = self.out_dir / "status.json"
        self.merged_ll = self.out_dir / "merged.ll"
        self.merged_full_ll = self.out_dir / "merged_full.ll"
        self.delta_json = self.eval_dir / "delta.json"
        self.parallel_eval_json = self.eval_dir / "parallel.eval.json"
        self.parallel_eval_txt = self.eval_dir / "parallel.eval.txt"
        self.reference_eval_json = self.eval_dir / "reference.eval.json"
        self.reference_eval_txt = self.eval_dir / "reference.eval.txt"
        self.final_report_json = self.out_dir / "final_report.json"
        self.final_report_md = self.out_dir / "final_report.md"

        if self.workers < 1 or self.workers > 100:
            raise ValueError("--workers must be within [1, 100]")
        if not self.out_dir.is_relative_to(self.run_dir):
            raise ValueError("--out-dir must live under the mounted run dir")

        rel = self.out_dir.relative_to(self.run_dir)
        self.container_out_dir = self.container_workdir.joinpath(*rel.parts)
        self.container_shards_dir = self.container_out_dir / "shards"
        self.container_raw_dir = self.container_out_dir / "raw"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run the legacy libcrypto address-ranged parallel lift workflow. "
            "This is the offline static sharding path, not runnable-lift's "
            "dynamic branch-driven mode."
        )
    )
    parser.add_argument("--container-name", default=DEFAULT_CONTAINER_NAME)
    parser.add_argument("--run-dir", type=Path, default=DEFAULT_RUN_DIR)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--funcs-csv", type=Path, default=DEFAULT_FUNCS_CSV)
    parser.add_argument("--reference-ll", type=Path, default=DEFAULT_REFERENCE_LL)
    parser.add_argument("--ground-truth-binary", type=Path, default=DEFAULT_GROUND_TRUTH)
    parser.add_argument("--run-cmp-eval", type=Path, default=DEFAULT_RUN_CMP_EVAL)
    parser.add_argument("--container-workdir", default=DEFAULT_CONTAINER_WORKDIR)
    parser.add_argument("--container-binary", default=DEFAULT_CONTAINER_BINARY)
    parser.add_argument("--runnable-lift", default=DEFAULT_RUNNABLE_LIFT)
    parser.add_argument("--rebase-base", type=lambda v: int(v, 0), default=0x50000000)
    parser.add_argument("--csv-image-base", type=lambda v: int(v, 0), default=DEFAULT_CSV_IMAGE_BASE)
    parser.add_argument("--range-margin", type=int, default=0)
    parser.add_argument("--func-timeout", type=int, default=30)
    parser.add_argument("--workers", type=int, default=100)
    parser.add_argument("--max-repair-rounds", type=int, default=5)
    parser.add_argument("--repair-timeout-multiplier", type=float, default=2.0)
    parser.add_argument("--repair-margin-step", type=int, default=32)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--super-fast", dest="super_fast", action="store_true", default=True)
    parser.add_argument("--no-super-fast", dest="super_fast", action="store_false")
    parser.add_argument(
        "--rerun-all-on-metric-gap",
        dest="rerun_all_on_metric_gap",
        action="store_true",
        default=True,
        help="When metrics are still below reference but no shards explicitly failed, rerun all shards.",
    )
    parser.add_argument(
        "--no-rerun-all-on-metric-gap",
        dest="rerun_all_on_metric_gap",
        action="store_false",
        help="Stop the repair loop when only a metric gap remains and no shards explicitly failed.",
    )
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--keep-raw-on-success", action="store_true")
    return parser.parse_args()


def log(msg: str) -> None:
    ts = time.strftime("%F %T")
    print(f"[{ts}] {msg}", flush=True)


def run_cmd(
    cmd: List[str],
    *,
    check: bool = True,
    capture_output: bool = True,
    cwd: Optional[Path] = None,
) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        check=check,
        cwd=str(cwd) if cwd else None,
        text=True,
        capture_output=capture_output,
    )


def docker_exec(
    config: Config,
    shell_command: str,
    *,
    check: bool = True,
    capture_output: bool = True,
) -> subprocess.CompletedProcess:
    return run_cmd(
        ["docker", "exec", config.container_name, "bash", "-lc", shell_command],
        check=check,
        capture_output=capture_output,
    )


def ensure_paths(config: Config) -> None:
    for path in (
        config.run_dir,
        config.funcs_csv,
        config.reference_ll,
        config.ground_truth_binary,
        config.run_cmp_eval,
    ):
        if not path.exists():
            raise FileNotFoundError(path)
    config.out_dir.mkdir(parents=True, exist_ok=True)
    config.shards_dir.mkdir(parents=True, exist_ok=True)
    config.raw_dir.mkdir(parents=True, exist_ok=True)
    config.eval_dir.mkdir(parents=True, exist_ok=True)
    config.round_reports_dir.mkdir(parents=True, exist_ok=True)
    config.logs_dir.mkdir(parents=True, exist_ok=True)


def require_addr_range_support(config: Config) -> Dict[str, object]:
    help_result = docker_exec(
        config,
        f"{shlex.quote(config.runnable_lift)} --help 2>&1",
        capture_output=True,
    )
    if "addr-range-min" not in help_result.stdout or "addr-range-max" not in help_result.stdout:
        raise RuntimeError(
            "runnable-lift does not expose --addr-range-min/max; rebuild the container binary first"
        )
    info_result = docker_exec(
        config,
        "python3 --version && nproc && "
        + shlex.quote(config.runnable_lift)
        + " --help 2>&1 | grep -n 'addr-range'",
        capture_output=True,
    )
    return {
        "help_lines": [line for line in info_result.stdout.splitlines() if "addr-range" in line],
        "runtime_info": info_result.stdout.splitlines()[:2],
    }


def load_jobs(config: Config) -> List[ShardJob]:
    jobs: List[ShardJob] = []
    with config.funcs_csv.open("r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for index, row in enumerate(reader):
            start = int(row["addr_hex"], 16)
            end_inclusive = int(row["end_hex"], 16)
            if end_inclusive < start:
                continue
            if start < config.csv_image_base or end_inclusive < config.csv_image_base:
                raise ValueError(
                    f"function address {hex(start)} is below csv image base {hex(config.csv_image_base)}"
                )
            exact_end_exclusive = end_inclusive + 1
            rebased_start = config.rebase_base + (start - config.csv_image_base)
            rebased_end_exclusive = config.rebase_base + (
                exact_end_exclusive - config.csv_image_base
            )
            jobs.append(
                ShardJob(
                    index=index,
                    start=start,
                    end_inclusive=end_inclusive,
                    name=row.get("name", f"sub_{start:x}"),
                    range_min=rebased_start,
                    range_max=rebased_end_exclusive + config.range_margin,
                    exact_end_exclusive=rebased_end_exclusive,
                )
            )
    if config.limit > 0:
        jobs = jobs[: config.limit]
    return jobs


def load_existing_results(config: Config) -> Dict[str, Dict[str, object]]:
    if not config.manifest_json.exists():
        return {}
    with config.manifest_json.open("r", encoding="utf-8") as handle:
        items = json.load(handle)
    return {item["tag"]: item for item in items}


def write_manifest(config: Config, items: Iterable[Dict[str, object]]) -> None:
    ordered = sorted(items, key=lambda item: item["start"])
    with config.manifest_json.open("w", encoding="utf-8") as handle:
        json.dump(ordered, handle, indent=2, sort_keys=True)


def compact_ll(raw_ll: Path, compact_ll_path: Path, start: int, end_exclusive: int) -> int:
    last_seen: Dict[int, str] = {}
    with raw_ll.open("r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            match = LL_COMMENT_RE.match(line)
            if match is None:
                continue
            addr = int(match.group(1), 16)
            if start <= addr < end_exclusive:
                last_seen[addr] = line.rstrip("\n")
    with compact_ll_path.open("w", encoding="utf-8") as handle:
        for addr in sorted(last_seen):
            handle.write(last_seen[addr] + "\n")
    return len(last_seen)


def filter_coverage_csv(raw_cov: Path, compact_cov: Path, start: int, end_exclusive: int) -> None:
    if not raw_cov.exists():
        return
    rows: List[str] = []
    with raw_cov.open("r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split(",")
            try:
                addr = int(parts[0], 16)
            except ValueError:
                continue
            if start <= addr < end_exclusive:
                rows.append(line)
    compact_cov.write_text("\n".join(rows) + ("\n" if rows else ""), encoding="utf-8")


def delete_if_exists(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        return


def container_path(path: PurePosixPath) -> str:
    return shlex.quote(str(path))


def shell_bool(enabled: bool, flag: str) -> str:
    return flag + " " if enabled else ""


def run_shard(
    config: Config,
    job: ShardJob,
    *,
    timeout_sec: int,
    range_margin: int,
    super_fast: bool,
) -> Dict[str, object]:
    shard_ll = config.shards_dir / f"{job.tag}.ll"
    shard_cov = config.shards_dir / f"{job.tag}.ll.coverage.csv"
    shard_li = config.shards_dir / f"{job.tag}.ll.li.csv"
    shard_need = config.shards_dir / f"{job.tag}.ll.need.csv"
    shard_illegal = config.shards_dir / f"{job.tag}.ll.illegalEntry.log"
    shard_stdout = config.shards_dir / f"{job.tag}.stdout.log"
    shard_stderr = config.shards_dir / f"{job.tag}.stderr.log"

    raw_ll = config.raw_dir / f"{job.tag}.raw.ll"
    raw_cov = config.raw_dir / f"{job.tag}.raw.coverage.csv"
    raw_stdout = config.raw_dir / f"{job.tag}.stdout.log"
    raw_stderr = config.raw_dir / f"{job.tag}.stderr.log"
    raw_exit = config.raw_dir / f"{job.tag}.exitcode"
    raw_li = config.raw_dir / f"{job.tag}.raw.ll.li.csv"
    raw_need = config.raw_dir / f"{job.tag}.raw.ll.need.csv"
    raw_illegal = config.raw_dir / f"{job.tag}.raw.ll.illegalEntry.log"

    c_raw_ll = config.container_raw_dir / raw_ll.name
    c_raw_cov = config.container_raw_dir / raw_cov.name
    c_raw_stdout = config.container_raw_dir / raw_stdout.name
    c_raw_stderr = config.container_raw_dir / raw_stderr.name
    c_raw_exit = config.container_raw_dir / raw_exit.name

    range_max = job.exact_end_exclusive + range_margin
    shell = (
        "set +e\n"
        f"mkdir -p {container_path(config.container_raw_dir)}\n"
        f"rm -f {container_path(c_raw_ll)} {container_path(c_raw_cov)} "
        f"{container_path(c_raw_stdout)} {container_path(c_raw_stderr)} {container_path(c_raw_exit)}\n"
        f"timeout {timeout_sec} {shlex.quote(config.runnable_lift)} "
        f"{shell_bool(super_fast, '-super-fast')}"
        f"-entry=0x{job.range_min:x} "
        f"-addr-range-min 0x{job.range_min:x} "
        f"-addr-range-max 0x{range_max:x} "
        f"-coverage-path {container_path(c_raw_cov)} "
        f"{shlex.quote(config.container_binary)} {container_path(c_raw_ll)} "
        f"> {container_path(c_raw_stdout)} 2> {container_path(c_raw_stderr)}\n"
        "rc=$?\n"
        f"printf '%s' \"$rc\" > {container_path(c_raw_exit)}\n"
        "exit 0\n"
    )
    infra_rc = docker_exec(config, shell, check=False, capture_output=True).returncode

    try:
        raw_rc = int(raw_exit.read_text(encoding="utf-8").strip())
    except FileNotFoundError:
        raw_rc = infra_rc

    if raw_ll.exists():
        compact_count = compact_ll(raw_ll, shard_ll, job.range_min, range_max)
    else:
        compact_count = 0
        delete_if_exists(shard_ll)

    filter_coverage_csv(raw_cov, shard_cov, job.range_min, range_max)

    if raw_li.exists():
        raw_li.replace(shard_li)
    else:
        delete_if_exists(shard_li)
    if raw_need.exists():
        raw_need.replace(shard_need)
    else:
        delete_if_exists(shard_need)
    if raw_illegal.exists():
        raw_illegal.replace(shard_illegal)
    else:
        delete_if_exists(shard_illegal)

    status = "ok"
    if raw_rc == 124:
        status = "timeout"
    elif raw_rc != 0:
        status = "error"
    elif compact_count == 0:
        status = "empty"

    keep_logs = status != "ok"
    if keep_logs:
        if raw_stdout.exists():
            raw_stdout.replace(shard_stdout)
        if raw_stderr.exists():
            raw_stderr.replace(shard_stderr)
    else:
        delete_if_exists(raw_stdout)
        delete_if_exists(raw_stderr)
        delete_if_exists(shard_stdout)
        delete_if_exists(shard_stderr)

    if status == "ok" and not config.keep_raw_on_success:
        delete_if_exists(raw_cov)
        delete_if_exists(raw_exit)

    return {
        "tag": job.tag,
        "index": job.index,
        "name": job.name,
        "start": job.start,
        "end_inclusive": job.end_inclusive,
        "entry_rebased": job.range_min,
        "range_max_used": range_max,
        "exact_end_exclusive": job.exact_end_exclusive,
        "timeout_sec": timeout_sec,
        "range_margin": range_margin,
        "super_fast": super_fast,
        "status": status,
        "raw_rc": raw_rc,
        "raw_ll": str(raw_ll) if raw_ll.exists() else None,
        "compact_instruction_count": compact_count,
        "shard_ll": str(shard_ll),
        "coverage_csv": str(shard_cov),
        "stderr_log": str(shard_stderr) if shard_stderr.exists() else None,
        "stdout_log": str(shard_stdout) if shard_stdout.exists() else None,
    }


def run_jobs(
    config: Config,
    jobs: List[ShardJob],
    existing: Dict[str, Dict[str, object]],
    *,
    timeout_sec: int,
    range_margin: int,
    super_fast: bool,
    force_tags: Optional[set] = None,
) -> Dict[str, Dict[str, object]]:
    results = dict(existing)
    force_tags = force_tags or set()
    pending: List[ShardJob] = []
    for job in jobs:
        if config.force or job.tag in force_tags:
            pending.append(job)
            continue
        cached = results.get(job.tag)
        if cached is None:
            pending.append(job)
            continue
        if cached.get("status") != "ok":
            pending.append(job)
            continue
        shard_ll = Path(cached["shard_ll"])
        if not shard_ll.exists():
            pending.append(job)
            continue

    total = len(jobs)
    completed = total - len(pending)
    count_lock = threading.Lock()
    if pending:
        log(f"Launching {len(pending)} shard jobs with {config.workers} workers")
    else:
        log("All shard jobs already present; reusing cached results")

    with ThreadPoolExecutor(max_workers=config.workers) as executor:
        futures = {
            executor.submit(
                run_shard,
                config,
                job,
                timeout_sec=timeout_sec,
                range_margin=range_margin,
                super_fast=super_fast,
            ): job
            for job in pending
        }
        for future in as_completed(futures):
            result = future.result()
            job = futures[future]
            results[job.tag] = result
            with count_lock:
                completed += 1
                if completed % 100 == 0 or completed == total:
                    ok_total = sum(1 for item in results.values() if item.get("status") == "ok")
                    compact_total = sum(
                        item.get("compact_instruction_count", 0)
                        for item in results.values()
                    )
                    log(
                        f"[{completed}/{total}] ok={ok_total} "
                        f"compact_instructions={compact_total}"
                    )
    return results


def merge_shards(config: Config, results: Dict[str, Dict[str, object]]) -> Dict[str, object]:
    merged: Dict[int, str] = {}
    shard_count = 0
    for item in sorted(results.values(), key=lambda value: value["start"]):
        if item["status"] != "ok":
            continue
        shard_path = Path(item["shard_ll"])
        if not shard_path.exists():
            continue
        shard_count += 1
        with shard_path.open("r", encoding="utf-8", errors="ignore") as handle:
            for line in handle:
                match = LL_COMMENT_RE.match(line)
                if match is None:
                    continue
                merged[int(match.group(1), 16)] = line.rstrip("\n")
    with config.merged_ll.open("w", encoding="utf-8") as handle:
        for addr in sorted(merged):
            handle.write(merged[addr] + "\n")
    merge_info = {
        "merged_ll": str(config.merged_ll),
        "unique_instruction_count": len(merged),
        "successful_shards": shard_count,
    }
    merge_info.update(merge_full_module(config, results))
    return merge_info


def strip_root_debug_line(line: str) -> Optional[str]:
    if "@llvm.dbg." in line:
        return None
    line = DEBUG_ATTACHMENT_RE.sub("", line)
    line = DEBUG_INLINE_RE.sub("", line)
    line = ROOT_DROP_METADATA_RE.sub("", line)
    return line


def root_block_addr(label: str) -> Optional[int]:
    match = ROOT_BLOCK_LABEL_RE.match(label)
    if match is None:
        return None
    return int(match.group(1), 16)


def disam_addr_from_definition(definition: Optional[str]) -> Optional[int]:
    if definition is None:
        return None
    match = DISAM_ADDR_RE.search(definition)
    if match is None:
        return None
    return int(match.group(1), 16)


def infer_symbolic_block_addr(
    label: str,
    lines: List[str],
    *,
    dispatcher_label_addrs: Dict[str, int],
    disam_globals: Dict[str, str],
) -> Optional[int]:
    direct_addr = dispatcher_label_addrs.get(label)
    if direct_addr is not None:
        return direct_addr

    if label.startswith("bb."):
        direct_disam = disam_addr_from_definition(disam_globals.get(f"@disam_{label[3:]}"))
        if direct_disam is not None:
            return direct_disam

    symbolic_match = ROOT_SYMBOLIC_BLOCK_RE.match(label)
    if symbolic_match is not None:
        root_label = symbolic_match.group(1)
        offset_hex = symbolic_match.group(2)
        if offset_hex is not None:
            root_addr = dispatcher_label_addrs.get(root_label)
            if root_addr is None and root_label.startswith("bb."):
                root_addr = disam_addr_from_definition(disam_globals.get(f"@disam_{root_label[3:]}"))
            if root_addr is not None:
                return root_addr + int(offset_hex, 16)

    for line in lines:
        match = NEWPC_ADDR_RE.search(line)
        if match is not None:
            return int(match.group(1))
        match = PC_STORE_ADDR_RE.search(line)
        if match is not None:
            return int(match.group(1))

    return None


def find_root_bounds(lines: List[str]) -> Tuple[int, int]:
    start = next(index for index, line in enumerate(lines) if line.startswith("define void @root("))
    depth = lines[start].count("{") - lines[start].count("}")
    end = start + 1
    while end < len(lines):
        depth += lines[end].count("{") - lines[end].count("}")
        if depth == 0:
            end += 1
            break
        end += 1
    return start, end


def extract_root(raw_ll: Path) -> ParsedRoot:
    lines = raw_ll.read_text(encoding="utf-8", errors="ignore").splitlines()
    globals_by_name: Dict[str, str] = {}
    disam_globals: Dict[str, str] = {}
    metadata_defs: Dict[int, str] = {}
    for line in lines:
        global_match = GLOBAL_DEF_RE.match(line)
        if global_match is not None:
            globals_by_name[global_match.group(1)] = line
        disam_match = DISAM_GLOBAL_RE.match(line)
        if disam_match is not None:
            disam_globals[disam_match.group(1)] = line
            continue
        metadata_match = METADATA_DEF_RE.match(line)
        if metadata_match is not None:
            metadata_defs[int(metadata_match.group(1))] = metadata_match.group(2)

    root_start, root_end = find_root_bounds(lines)
    root_lines = lines[root_start:root_end]

    segments: Dict[str, List[str]] = {}
    segment_order: List[str] = []
    current_label: Optional[str] = None
    current_lines: List[str] = []

    for line in root_lines[1:-1]:
        match = ROOT_LABEL_RE.match(line)
        if match is not None:
            if current_label is not None:
                segments[current_label] = current_lines
                segment_order.append(current_label)
            current_label = match.group(1)
            current_lines = [line]
            continue
        if current_label is not None:
            current_lines.append(line)
    if current_label is not None:
        segments[current_label] = current_lines
        segment_order.append(current_label)

    define_line = strip_root_debug_line(root_lines[0])
    if define_line is None:
        raise RuntimeError(f"unexpected dbg-only root definition in {raw_ll}")

    entry_segment = [line for line in (strip_root_debug_line(line) for line in segments["entrypoint"]) if line is not None]
    entry_label = entry_segment[0]
    entry_allocas: List[str] = []
    entry_rest: List[str] = []
    seen_non_alloca = False
    for line in entry_segment[1:]:
        if not seen_non_alloca and " alloca " in line:
            entry_allocas.append(line)
            continue
        seen_non_alloca = True
        entry_rest.append(line)

    dispatcher_segment = [
        line
        for line in (strip_root_debug_line(line) for line in segments["dispatcher.entry"])
        if line is not None
    ]
    switch_index = next(index for index, line in enumerate(dispatcher_segment) if "switch i64 " in line)
    switch_end = next(
        index for index in range(switch_index + 1, len(dispatcher_segment))
        if dispatcher_segment[index].lstrip().startswith("]")
    )
    dispatcher_cases: Dict[int, str] = {}
    for line in dispatcher_segment[switch_index + 1:switch_end]:
        match = ROOT_CASE_RE.match(line)
        if match is None:
            continue
        dispatcher_cases[int(match.group(1))] = line
    dispatcher_label_addrs = {
        ROOT_CASE_RE.match(line).group(2): int(ROOT_CASE_RE.match(line).group(1))
        for line in dispatcher_cases.values()
        if ROOT_CASE_RE.match(line) is not None
    }

    common_segments: Dict[str, List[str]] = {}
    translated_segments: List[RootBlockSegment] = []
    translated_order = 0
    for label in segment_order:
        if label in {"entrypoint", "dispatcher.entry"}:
            continue
        cleaned = [line for line in (strip_root_debug_line(line) for line in segments[label]) if line is not None]
        if label in ROOT_COMMON_LABELS:
            common_segments[label] = cleaned
            continue
        base_addr = root_block_addr(label)
        if base_addr is None:
            base_addr = infer_symbolic_block_addr(
                label,
                cleaned,
                dispatcher_label_addrs=dispatcher_label_addrs,
                disam_globals=disam_globals,
            )
        if base_addr is None:
            base_addr = (1 << 62) + translated_order
        translated_segments.append(
            RootBlockSegment(
                label=label,
                base_addr=base_addr,
                order_index=translated_order,
                lines=cleaned,
            )
        )
        translated_order += 1

    return ParsedRoot(
        define_line=define_line,
        entry_label=entry_label,
        entry_allocas=entry_allocas,
        entry_rest=entry_rest,
        dispatcher_prefix=dispatcher_segment[:switch_index + 1],
        dispatcher_footer=dispatcher_segment[switch_end:],
        dispatcher_cases=dispatcher_cases,
        common_segments=common_segments,
        translated_segments=translated_segments,
        globals=globals_by_name,
        disam_globals=disam_globals,
        metadata_defs=metadata_defs,
    )


def parse_reference_entry_pc(reference_ll: Path) -> Optional[int]:
    match = REFERENCE_ENTRY_RE.search(reference_ll.name)
    if match is None:
        return None
    return int(match.group(1), 16)


def read_elf_entry_pc(binary_path: Path) -> Optional[int]:
    try:
        header = binary_path.read_bytes()[:64]
    except OSError:
        return None
    if len(header) < 24 or header[:4] != b"\x7fELF":
        return None

    elf_class = header[4]
    data_encoding = header[5]
    if data_encoding == 1:
        endian = "<"
    elif data_encoding == 2:
        endian = ">"
    else:
        return None

    if elf_class == 1:
        if len(header) < 28:
            return None
        return struct.unpack_from(f"{endian}I", header, 24)[0]
    if elf_class == 2:
        if len(header) < 32:
            return None
        return struct.unpack_from(f"{endian}Q", header, 24)[0]
    return None


def determine_root_entry_pc(config: object) -> Tuple[Optional[int], str]:
    explicit_entry_pc = getattr(config, "entry_pc", None)
    if explicit_entry_pc is not None:
        return int(explicit_entry_pc), "config.entry_pc"

    reference_ll = getattr(config, "reference_ll", None)
    if reference_ll:
        parsed = parse_reference_entry_pc(Path(reference_ll))
        if parsed is not None:
            return parsed, "reference_ll"

    ground_truth_binary = getattr(config, "ground_truth_binary", None)
    if ground_truth_binary:
        parsed = read_elf_entry_pc(Path(ground_truth_binary))
        if parsed is not None:
            return parsed, "ground_truth_binary"

    return None, "base_root"


def rewrite_root_entry_rest(entry_rest: List[str], entry_pc: int) -> Tuple[List[str], Optional[int], bool]:
    rewritten: List[str] = []
    previous_pc: Optional[int] = None
    replaced = False
    for line in entry_rest:
        if not replaced:
            match = PC_STORE_ADDR_RE.search(line)
            if match is not None:
                previous_pc = int(match.group(1))
                rewritten.append(
                    line[:match.start(1)] + str(entry_pc) + line[match.end(1):]
                )
                replaced = True
                continue
        rewritten.append(line)
    return rewritten, previous_pc, replaced


def common_segment_score(lines: List[str]) -> Tuple[int, int]:
    text = "\n".join(lines)
    feature_count = sum(1 for ref in ROOT_COMMON_FEATURE_REFS if ref in text)
    return feature_count, len(lines)


def function_symbol_score(symbol_lines: List[str]) -> Tuple[int, int, int, int]:
    text = "\n".join(symbol_lines)
    lifted_state_refs = len(LIFTED_STATE_GLOBAL_RE.findall(text))
    cpux86state_geps = len(CPUX86STATE_GEP_RE.findall(text))
    lowered_state_score = 0
    if "%struct.CPUX86State" in text:
        lowered_state_score = (lifted_state_refs * 10) - cpux86state_geps
    return lowered_state_score, switch_case_count(symbol_lines), len(symbol_lines), -cpux86state_geps


def find_segment_line(variants: List[List[str]], pattern: str) -> Optional[str]:
    for lines in variants:
        for line in lines:
            if pattern in line:
                return line
    return None


def build_serialize_and_jump_out_union(
    variants: List[List[str]],
    *,
    available_globals: set,
) -> Optional[List[str]]:
    if not variants:
        return None

    jump_line = find_segment_line(variants, 'jmpq *%r11')
    unreachable_line = find_segment_line(variants, "unreachable")
    if jump_line is None or unreachable_line is None:
        return None

    lines = ["serialize_and_jump_out:"]
    for reg_name, global_name in SERIALIZE_GPRS:
        if global_name not in available_globals:
            continue
        lines.append(
            f'  call void asm sideeffect "movq $0, %{reg_name}", '
            f'"*m,~{{{reg_name}}},~{{dirflag}},~{{fpsr}},~{{flags}}"(i64* {global_name})'
        )
    for xmm_name, global_name in XMM_STATE_GLOBALS:
        if global_name not in available_globals:
            continue
        lines.append(
            f'  call void asm sideeffect "movq $0, %{xmm_name}", '
            f'"*m,~{{{xmm_name}}},~{{dirflag}},~{{fpsr}},~{{flags}}"(i64* {global_name})'
        )
    lines.append(jump_line)
    lines.append(unreachable_line)
    return lines


def build_return_from_external_union(
    variants: List[List[str]],
    *,
    available_globals: set,
) -> Optional[List[str]]:
    if not variants:
        return None

    br_line = find_segment_line(variants, "br label %dispatcher.entry")
    if br_line is None:
        return None

    lines = ["return_from_external:"]
    for reg_name, global_name, slot in RETURN_FROM_EXTERNAL_SLOTS:
        if global_name not in available_globals:
            continue
        base_name = f"%return_from_external_{reg_name}_base"
        ptr_name = f"%return_from_external_{reg_name}_ptr"
        value_name = f"%return_from_external_{reg_name}_value"
        lines.append(f"  {base_name} = load i64*, i64** @saved_registers")
        lines.append(f"  {ptr_name} = getelementptr i64, i64* {base_name}, i32 {slot}")
        lines.append(f"  {value_name} = load i64, i64* {ptr_name}")
        lines.append(f"  store i64 {value_name}, i64* {global_name}")
    for xmm_name, global_name in XMM_STATE_GLOBALS:
        if global_name not in available_globals:
            continue
        lines.append(
            f'  call void asm sideeffect "movq %{xmm_name}, $0", '
            f'"*m,~{{}},~{{dirflag}},~{{fpsr}},~{{flags}}"(i64* {global_name})'
        )
    lines.append(br_line)
    return lines


def import_root_segment_refs(
    lines: List[str],
    *,
    root: ParsedRoot,
    base_global_names: set,
    base_disam_names: set,
    imported_extra_globals: Dict[str, List[str]],
    imported_disam_globals: Dict[str, str],
) -> None:
    segment_text = "\n".join(lines)
    for disam_ref in DISAM_REF_RE.findall(segment_text):
        if disam_ref in base_disam_names:
            continue
        definition = root.disam_globals.get(disam_ref)
        if definition is not None:
            imported_disam_globals[disam_ref] = definition
    for global_ref in GLOBAL_REF_RE.findall(segment_text):
        if global_ref in base_global_names or global_ref in imported_disam_globals:
            continue
        definition = root.globals.get(global_ref)
        if definition is not None:
            imported_extra_globals[global_ref] = sanitize_imported_symbol([definition])


def rename_local_values(lines: List[str], prefix: str) -> List[str]:
    return [LOCAL_VALUE_RE.sub(lambda match: f"%{prefix}_{match.group(1)}", line) for line in lines]


def normalize_root_local_values(lines: List[str]) -> List[str]:
    if not lines:
        return []
    define_line = lines[0].replace("@root(i64)", "@root(i64 %root_0)", 1)
    return [define_line] + rename_local_values(lines[1:], "root")


def strip_imported_line(line: str) -> Optional[str]:
    if "@llvm.dbg." in line:
        return None
    line = DEBUG_ATTACHMENT_RE.sub("", line)
    line = DEBUG_INLINE_RE.sub("", line)
    line = re.sub(r", ![A-Za-z0-9_.-]+ !\d+", "", line)
    return line


def sanitize_imported_symbol(lines: List[str]) -> List[str]:
    cleaned = [line for line in (strip_imported_line(line) for line in lines) if line is not None]
    if cleaned and cleaned[0].startswith("define internal "):
        cleaned[0] = cleaned[0].replace("define internal ", "define ", 1)
    return cleaned


def collect_i8_array_global_sizes(lines: List[str]) -> Dict[str, int]:
    sizes: Dict[str, int] = {}
    for line in lines:
        match = I8_ARRAY_GLOBAL_DEF_RE.match(line)
        if match is None:
            continue
        sizes[match.group(1)] = int(match.group(2))
    return sizes


def normalize_i8_array_global_refs(lines: List[str]) -> Tuple[List[str], int]:
    canonical_sizes = collect_i8_array_global_sizes(lines)
    if not canonical_sizes:
        return list(lines), 0

    fix_count = 0
    normalized: List[str] = []
    for line in lines:
        def replace_gep(match: re.Match) -> str:
            nonlocal fix_count
            symbol = match.group(3)
            size = canonical_sizes.get(symbol)
            if size is None:
                return match.group(0)
            updated = f"[{size} x i8], [{size} x i8]* {symbol}"
            if updated != match.group(0):
                fix_count += 1
            return updated

        line = I8_ARRAY_GEP_REF_RE.sub(replace_gep, line)

        def replace_ptr_cast(match: re.Match) -> str:
            nonlocal fix_count
            symbol = match.group(2)
            size = canonical_sizes.get(symbol)
            if size is None:
                return match.group(0)
            updated = f"[{size} x i8]* {symbol}"
            if updated != match.group(0):
                fix_count += 1
            return updated

        line = I8_ARRAY_PTR_CAST_RE.sub(replace_ptr_cast, line)
        normalized.append(line)
    return normalized, fix_count


def parse_module_symbols(raw_ll: Path) -> ParsedModule:
    lines = raw_ll.read_text(encoding="utf-8", errors="ignore").splitlines()
    type_defs_by_name: Dict[str, str] = {}
    globals_by_name: Dict[str, List[str]] = {}
    functions_by_name: Dict[str, List[str]] = {}
    function_kinds: Dict[str, str] = {}
    type_order: List[str] = []
    global_order: List[str] = []
    function_order: List[str] = []
    index = 0
    top_level_re = re.compile(
        r"^(?:%[A-Za-z$._0-9-]+\s*=\s*type\b|@|define |declare |attributes #|![A-Za-z0-9_.-]+ =|![0-9]+ =)"
    )

    while index < len(lines):
        line = lines[index]
        type_match = TYPE_DEF_RE.match(line)
        if type_match is not None:
            name = type_match.group(1)
            type_defs_by_name[name] = line
            type_order.append(name)
            index += 1
            continue

        if line.startswith("define "):
            match = re.search(r"@([^\s(]+)\(", line)
            if match is None:
                index += 1
                continue
            name = f"@{match.group(1)}"
            start = index
            depth = line.count("{") - line.count("}")
            index += 1
            while index < len(lines):
                depth += lines[index].count("{") - lines[index].count("}")
                if depth == 0:
                    index += 1
                    break
                index += 1
            functions_by_name[name] = lines[start:index]
            function_kinds[name] = "define"
            function_order.append(name)
            continue

        if line.startswith("declare "):
            match = re.search(r"@([^\s(]+)\(", line)
            if match is None:
                index += 1
                continue
            name = f"@{match.group(1)}"
            functions_by_name[name] = [line]
            function_kinds[name] = "declare"
            function_order.append(name)
            index += 1
            continue

        global_match = GLOBAL_DEF_RE.match(line)
        if global_match is not None:
            name = global_match.group(1)
            start = index
            index += 1
            while index < len(lines) and not top_level_re.match(lines[index]):
                index += 1
            globals_by_name[name] = lines[start:index]
            global_order.append(name)
            continue

        index += 1

    return ParsedModule(
        type_defs_by_name=type_defs_by_name,
        globals_by_name=globals_by_name,
        functions_by_name=functions_by_name,
        function_kinds=function_kinds,
        type_order=type_order,
        global_order=global_order,
        function_order=function_order,
    )


def collect_metadata_ids(lines: Iterable[str]) -> List[int]:
    seen: Dict[int, None] = {}
    for line in lines:
        for match in METADATA_REF_RE.finditer(line):
            seen[int(match.group(1))] = None
    return list(seen.keys())


def collect_metadata_closure(metadata_defs: Dict[int, str], seed_ids: Iterable[int]) -> Dict[int, str]:
    closure: Dict[int, str] = {}
    stack = list(seed_ids)
    while stack:
        current = stack.pop()
        if current in closure:
            continue
        definition = metadata_defs.get(current)
        if definition is None:
            continue
        closure[current] = definition
        for match in METADATA_REF_RE.finditer(definition):
            stack.append(int(match.group(1)))
    return closure


def rewrite_metadata_ids(text: str, mapping: Dict[int, int]) -> str:
    return METADATA_REF_RE.sub(
        lambda match: f"!{mapping.get(int(match.group(1)), int(match.group(1)))}",
        text,
    )


def disam_sort_key(name: str) -> Tuple[int, str]:
    match = re.search(r"0x([0-9a-fA-F]+)", name)
    base = int(match.group(1), 16) if match is not None else 0
    return base, name


def switch_case_count(symbol_lines: List[str]) -> int:
    return len({match.group(1) for line in symbol_lines for match in [SWITCH_CASE_RE.match(line)] if match is not None})


def parse_switch_case_blocks(
    symbol_lines: List[str],
    *,
    case_re: re.Pattern[str],
) -> Tuple[Dict[int, str], Dict[str, List[str]]]:
    switch_index = next(
        index for index, line in enumerate(symbol_lines)
        if line.strip().startswith("switch ")
    )
    switch_end = next(
        index for index in range(switch_index + 1, len(symbol_lines))
        if symbol_lines[index].strip() == "]"
    )

    case_labels: Dict[int, str] = {}
    for line in symbol_lines[switch_index + 1:switch_end]:
        match = case_re.match(line)
        if match is None:
            continue
        case_labels[int(match.group(1))] = match.group(2)

    blocks: Dict[str, List[str]] = {}
    current_label: Optional[str] = None
    current_lines: List[str] = []
    for line in symbol_lines[switch_end + 1:-1]:
        match = ANON_BLOCK_LABEL_RE.match(line)
        if match is not None:
            if current_label is not None:
                blocks[current_label] = current_lines
            current_label = match.group(1)
            current_lines = []
            continue
        if current_label is not None:
            current_lines.append(line)
    if current_label is not None:
        blocks[current_label] = current_lines

    return case_labels, blocks


def rewrite_set_register_case_body(case_value: int, body_lines: List[str]) -> List[str]:
    prefix = f"set_register_case_{case_value}"
    rewritten: List[str] = []
    for line in body_lines:
        if line.strip().startswith(";"):
            continue
        updated = re.sub(r"%0\b", "%reg", line)
        updated = re.sub(r"%1\b", "%value", updated)
        updated = re.sub(r"label %4\b", "label %set_register.ret", updated)
        updated = re.sub(
            r"%(?!0\b|1\b)(\d+)\b",
            lambda match: f"%{prefix}_{match.group(1)}",
            updated,
        )
        rewritten.append(updated)
    return rewritten


def merge_set_register_definitions(symbol_variants: List[List[str]]) -> Optional[List[str]]:
    if not symbol_variants:
        return None

    case_bodies: Dict[int, List[str]] = {}
    for symbol_lines in sorted(symbol_variants, key=switch_case_count, reverse=True):
        try:
            case_labels, blocks = parse_switch_case_blocks(
                symbol_lines,
                case_re=SET_REGISTER_CASE_RE,
            )
        except StopIteration:
            continue
        for case_value, block_label in case_labels.items():
            if case_value in case_bodies:
                continue
            block_lines = blocks.get(block_label)
            if not block_lines:
                continue
            case_bodies[case_value] = rewrite_set_register_case_body(case_value, block_lines)

    if not case_bodies:
        return None

    merged_lines = [
        "define void @set_register(i32 %reg, i64 %value) {",
        "entry:",
        "  switch i32 %reg, label %set_register.abort [",
    ]
    for case_value in sorted(case_bodies):
        merged_lines.append(f"    i32 {case_value}, label %set_register.case_{case_value}")
    merged_lines.extend(
        [
            "  ]",
            "",
            "set_register.abort:",
            "  call void @abort()",
            "  unreachable",
            "",
            "set_register.ret:",
            "  ret void",
        ]
    )

    for case_value in sorted(case_bodies):
        merged_lines.append("")
        merged_lines.append(f"set_register.case_{case_value}:")
        merged_lines.extend(case_bodies[case_value])
    merged_lines.append("}")
    return merged_lines


def function_name_from_signature(line: str) -> Optional[str]:
    if not (line.startswith("define ") or line.startswith("declare ")):
        return None
    match = re.search(r"@([^\s(]+)\(", line)
    if match is None:
        return None
    return f"@{match.group(1)}"


def append_base_functions_with_replacements(
    output_lines: List[str],
    base_lines: List[str],
    start: int,
    end: int,
    replacement_functions: Dict[str, List[str]],
    emitted_replacements: Dict[str, None],
) -> None:
    index = start
    while index < end:
        line = base_lines[index]
        function_name = function_name_from_signature(line)
        replacement = replacement_functions.get(function_name or "")
        if function_name is None or replacement is None:
            output_lines.append(line)
            index += 1
            continue

        output_lines.extend(replacement)
        emitted_replacements[function_name] = None
        if line.startswith("declare "):
            index += 1
            continue
        depth = line.count("{") - line.count("}")
        index += 1
        while index < end:
            depth += base_lines[index].count("{") - base_lines[index].count("}")
            index += 1
            if depth == 0:
                break

def find_post_root_suffix_start(lines: List[str], start: int) -> int:
    named_metadata_re = re.compile(r"^![A-Za-z0-9_.-]+\s*=")
    for index in range(start, len(lines)):
        line = lines[index]
        if (
            line.startswith("attributes #")
            or line.startswith("uselistorder")
            or METADATA_DEF_RE.match(line) is not None
            or named_metadata_re.match(line) is not None
        ):
            return index
    return len(lines)


def merge_full_module(config: Config, results: Dict[str, Dict[str, object]]) -> Dict[str, object]:
    successful = [
        item for item in sorted(results.values(), key=lambda value: value["start"])
        if item["status"] == "ok"
    ]
    if not successful:
        delete_if_exists(config.merged_full_ll)
        return {
            "merged_full_ll": None,
            "merged_full_status": "no_successful_shards",
            "merged_full_block_count": 0,
            "merged_full_disam_count": 0,
        }

    missing_raw: List[str] = []
    resolved_raw: List[Tuple[Dict[str, object], Path]] = []
    for item in successful:
        raw_ll = resolve_raw_ll_path(config, item)
        if raw_ll is None:
            missing_raw.append(item["tag"])
            continue
        resolved_raw.append((item, raw_ll))

    if missing_raw:
        if config.merged_full_ll.exists():
            return {
                "merged_full_ll": str(config.merged_full_ll),
                "merged_full_status": "reused_existing_artifact_missing_raw",
                "merged_full_missing_raw_shards": len(missing_raw),
                "merged_full_block_count": None,
                "merged_full_disam_count": None,
            }
        return {
            "merged_full_ll": None,
            "merged_full_status": "skipped_missing_raw",
            "merged_full_missing_raw_shards": len(missing_raw),
            "merged_full_block_count": 0,
            "merged_full_disam_count": 0,
        }

    base_item, base_raw_ll = resolved_raw[0]
    base_root = extract_root(base_raw_ll)
    base_module = parse_module_symbols(base_raw_ll)
    base_lines = base_raw_ll.read_text(encoding="utf-8", errors="ignore").splitlines()
    first_definition_index = next(
        index for index, line in enumerate(base_lines)
        if line.startswith("@") or line.startswith("define ") or line.startswith("declare ")
    )
    root_start, root_end = find_root_bounds(base_lines)
    first_function_index = next(
        index for index, line in enumerate(base_lines)
        if line.startswith("define ") or line.startswith("declare ")
    )
    post_root_suffix_start = find_post_root_suffix_start(base_lines, root_end)
    existing_metadata_ids = [
        int(match.group(1))
        for line in base_lines
        for match in [METADATA_DEF_RE.match(line)]
        if match is not None
    ]
    next_metadata_id = (max(existing_metadata_ids) + 1) if existing_metadata_ids else 0

    merged_cases: Dict[int, str] = {}
    merged_segments: Dict[str, RootBlockSegment] = {}
    imported_allocas: List[str] = []
    imported_type_defs: Dict[str, str] = {}
    imported_disam_globals: Dict[str, str] = {}
    imported_extra_globals: Dict[str, List[str]] = {}
    imported_functions: Dict[str, List[str]] = {}
    imported_metadata_defs: List[str] = []
    replacement_functions: Dict[str, List[str]] = {}
    replacement_function_variants: Dict[str, List[List[str]]] = {}
    replacement_function_scores: Dict[str, Tuple[int, int]] = {}
    base_disam_names = set(base_root.disam_globals)
    base_global_names = set(base_root.globals)
    base_function_names = set(base_module.functions_by_name)
    base_type_names = set(base_module.type_defs_by_name)
    selected_common_segments = dict(base_root.common_segments)
    selected_common_segment_scores = {
        label: common_segment_score(lines)
        for label, lines in base_root.common_segments.items()
    }
    common_segment_variants: Dict[str, List[List[str]]] = {
        label: [lines]
        for label, lines in base_root.common_segments.items()
        if label in ROOT_RICH_COMMON_LABELS
    }
    merge_prefer_max_case_functions = {"@set_register"}
    for name in merge_prefer_max_case_functions:
        if name in base_module.functions_by_name:
            cleaned = sanitize_imported_symbol(base_module.functions_by_name[name])
            replacement_functions[name] = cleaned
            replacement_function_variants.setdefault(name, []).append(cleaned)
            replacement_function_scores[name] = function_symbol_score(cleaned)

    for item, raw_ll in resolved_raw:
        root = extract_root(raw_ll)
        module = parse_module_symbols(raw_ll)

        for name in merge_prefer_max_case_functions:
            symbol_lines = module.functions_by_name.get(name)
            if symbol_lines is None:
                continue
            cleaned = sanitize_imported_symbol(symbol_lines)
            replacement_function_variants.setdefault(name, []).append(cleaned)
            score = function_symbol_score(cleaned)
            if score > replacement_function_scores.get(name, (-1, -1)):
                replacement_functions[name] = cleaned
                replacement_function_scores[name] = score

        selected_cases = dict(root.dispatcher_cases)
        for addr, line in selected_cases.items():
            merged_cases[addr] = line

        if item["tag"] == base_item["tag"]:
            for segment in base_root.translated_segments:
                merged_segments[segment.label] = segment
            continue

        selected_segments = list(root.translated_segments)

        for name in module.type_order:
            if name in base_type_names or name in imported_type_defs:
                continue
            imported_type_defs[name] = module.type_defs_by_name[name]

        for name in module.global_order:
            if name in base_global_names or name in imported_extra_globals or name.startswith("@disam_"):
                continue
            imported_extra_globals[name] = sanitize_imported_symbol(module.globals_by_name[name])
        for name in module.function_order:
            if name == "@root":
                continue
            symbol_lines = module.functions_by_name[name]
            symbol_kind = module.function_kinds.get(name)
            cleaned = sanitize_imported_symbol(symbol_lines)
            if not cleaned:
                continue

            if name in base_function_names:
                if symbol_kind == "define":
                    score = function_symbol_score(cleaned)
                    if score > replacement_function_scores.get(name, (-1, -1)):
                        replacement_functions[name] = cleaned
                        replacement_function_scores[name] = score
                continue

            if name in imported_functions:
                if symbol_kind != "define":
                    continue
                score = function_symbol_score(cleaned)
                existing_score = replacement_function_scores.get(
                    name,
                    function_symbol_score(imported_functions[name]),
                )
                if score > existing_score:
                    imported_functions[name] = cleaned
                    replacement_function_scores[name] = score
                continue

            imported_functions[name] = cleaned
            if symbol_kind == "define":
                replacement_function_scores[name] = function_symbol_score(cleaned)

        prefix = item["tag"].replace("-", "_")
        renamed_allocas = rename_local_values(root.entry_allocas, prefix)
        renamed_segments = [
            RootBlockSegment(
                label=segment.label,
                base_addr=segment.base_addr,
                order_index=segment.order_index,
                lines=rename_local_values(segment.lines, prefix),
            )
            for segment in selected_segments
        ]
        if not renamed_segments:
            continue

        metadata_seed = collect_metadata_ids(renamed_allocas)
        for segment in renamed_segments:
            metadata_seed.extend(collect_metadata_ids(segment.lines))
        metadata_closure = collect_metadata_closure(root.metadata_defs, metadata_seed)
        metadata_map = {
            old_id: next_metadata_id + offset
            for offset, old_id in enumerate(sorted(metadata_closure))
        }
        next_metadata_id += len(metadata_map)

        renamed_allocas = [rewrite_metadata_ids(line, metadata_map) for line in renamed_allocas]
        imported_allocas.extend(renamed_allocas)

        for old_id in sorted(metadata_closure):
            rewritten_definition = rewrite_metadata_ids(metadata_closure[old_id], metadata_map)
            imported_metadata_defs.append(f"!{metadata_map[old_id]} = {rewritten_definition}")
            for disam_ref in DISAM_REF_RE.findall(rewritten_definition):
                if disam_ref in base_disam_names:
                    continue
                definition = root.disam_globals.get(disam_ref)
                if definition is not None:
                    imported_disam_globals[disam_ref] = definition
            for global_ref in GLOBAL_REF_RE.findall(rewritten_definition):
                if global_ref in base_global_names or global_ref in imported_disam_globals:
                    continue
                definition = root.globals.get(global_ref)
                if definition is not None:
                    imported_extra_globals[global_ref] = sanitize_imported_symbol([definition])

        for segment in renamed_segments:
            rewritten_lines = [rewrite_metadata_ids(line, metadata_map) for line in segment.lines]
            merged_segments[segment.label] = RootBlockSegment(
                label=segment.label,
                base_addr=segment.base_addr,
                order_index=segment.order_index,
                lines=rewritten_lines,
            )
            for disam_ref in DISAM_REF_RE.findall("\n".join(rewritten_lines)):
                if disam_ref in base_disam_names:
                    continue
                definition = root.disam_globals.get(disam_ref)
                if definition is not None:
                    imported_disam_globals[disam_ref] = definition
            for global_ref in GLOBAL_REF_RE.findall("\n".join(rewritten_lines)):
                if global_ref in base_global_names or global_ref in imported_disam_globals:
                    continue
                definition = root.globals.get(global_ref)
                if definition is not None:
                    imported_extra_globals[global_ref] = sanitize_imported_symbol([definition])

        for label in ROOT_RICH_COMMON_LABELS:
            segment_lines = root.common_segments.get(label)
            if segment_lines is None:
                continue
            candidate_lines = segment_lines
            if item["tag"] != base_item["tag"]:
                candidate_lines = rename_local_values(segment_lines, prefix)
            common_segment_variants.setdefault(label, []).append(candidate_lines)
            import_root_segment_refs(
                candidate_lines,
                root=root,
                base_global_names=base_global_names,
                base_disam_names=base_disam_names,
                imported_extra_globals=imported_extra_globals,
                imported_disam_globals=imported_disam_globals,
            )
            candidate_score = common_segment_score(candidate_lines)
            if candidate_score <= selected_common_segment_scores.get(label, (-1, -1)):
                continue
            selected_common_segments[label] = candidate_lines
            selected_common_segment_scores[label] = candidate_score

    available_globals = set(base_global_names) | set(imported_extra_globals)
    merged_serialize = build_serialize_and_jump_out_union(
        common_segment_variants.get("serialize_and_jump_out", []),
        available_globals=available_globals,
    )
    if merged_serialize is not None:
        selected_common_segments["serialize_and_jump_out"] = merged_serialize
    merged_return_from_external = build_return_from_external_union(
        common_segment_variants.get("return_from_external", []),
        available_globals=available_globals,
    )
    if merged_return_from_external is not None:
        selected_common_segments["return_from_external"] = merged_return_from_external

    merged_set_register = merge_set_register_definitions(
        replacement_function_variants.get("@set_register", [])
    )
    if merged_set_register is not None:
        replacement_functions["@set_register"] = merged_set_register

    requested_entry_pc, entry_pc_source = determine_root_entry_pc(config)
    effective_entry_pc = requested_entry_pc
    if effective_entry_pc is not None and effective_entry_pc not in merged_cases:
        effective_entry_pc = None
        entry_pc_source = f"{entry_pc_source}:missing_dispatcher_case"
    rewritten_entry_rest = list(base_root.entry_rest)
    entry_pc_rewritten = False
    entry_pc_previous: Optional[int] = None
    if effective_entry_pc is not None:
        rewritten_entry_rest, entry_pc_previous, entry_pc_rewritten = rewrite_root_entry_rest(
            rewritten_entry_rest,
            effective_entry_pc,
        )

    merged_root_lines: List[str] = [base_root.define_line, base_root.entry_label]
    merged_root_lines.extend(base_root.entry_allocas)
    merged_root_lines.extend(imported_allocas)
    merged_root_lines.extend(rewritten_entry_rest)
    merged_root_lines.extend(base_root.dispatcher_prefix)
    for addr in sorted(merged_cases):
        merged_root_lines.append(merged_cases[addr])
    merged_root_lines.extend(base_root.dispatcher_footer)
    for label in ("dispatcher.default", "anypc", "unexpectedpc"):
        merged_root_lines.extend(base_root.common_segments[label])
    for segment in sorted(
        merged_segments.values(),
        key=lambda value: (value.base_addr, value.order_index, value.label),
    ):
        merged_root_lines.extend(segment.lines)
    for label in ("serialize_and_jump_out", "return_from_external", "setjmp", "dispatcher.external"):
        merged_root_lines.extend(selected_common_segments[label])
    merged_root_lines.append("}")
    merged_root_lines = normalize_root_local_values(merged_root_lines)

    new_lines: List[str] = []
    new_lines.extend(base_lines[:first_definition_index])
    new_lines.extend(imported_type_defs[name] for name in imported_type_defs)
    new_lines.extend(base_lines[first_definition_index:first_function_index])
    new_lines.extend(
        line
        for name in sorted(imported_extra_globals)
        for line in imported_extra_globals[name]
    )
    new_lines.extend(imported_disam_globals[name] for name in sorted(imported_disam_globals, key=disam_sort_key))
    emitted_replacements: Dict[str, None] = {}
    append_base_functions_with_replacements(
        new_lines,
        base_lines,
        first_function_index,
        root_start,
        replacement_functions,
        emitted_replacements,
    )
    new_lines.extend(merged_root_lines)
    append_base_functions_with_replacements(
        new_lines,
        base_lines,
        root_end,
        post_root_suffix_start,
        replacement_functions,
        emitted_replacements,
    )
    for name in sorted(replacement_functions):
        if name not in emitted_replacements:
            new_lines.extend(replacement_functions[name])
    for name in sorted(imported_functions):
        new_lines.extend(imported_functions[name])
    new_lines.extend(base_lines[post_root_suffix_start:])
    new_lines.extend(imported_metadata_defs)
    new_lines, i8_array_ref_fix_count = normalize_i8_array_global_refs(new_lines)
    config.merged_full_ll.write_text("\n".join(new_lines) + "\n", encoding="utf-8")

    return {
        "merged_full_ll": str(config.merged_full_ll),
        "merged_full_status": "built",
        "merged_full_block_count": len(merged_segments),
        "merged_full_imported_type_count": len(imported_type_defs),
        "merged_full_extra_global_count": len(imported_extra_globals),
        "merged_full_imported_function_count": len(imported_functions),
        "merged_full_disam_count": len(imported_disam_globals) + len(base_root.disam_globals),
        "merged_full_entry_pc": effective_entry_pc,
        "merged_full_entry_pc_source": entry_pc_source,
        "merged_full_entry_pc_rewritten": entry_pc_rewritten,
        "merged_full_previous_entry_pc": entry_pc_previous,
        "merged_full_i8_array_ref_fix_count": i8_array_ref_fix_count,
    }


def cleanup_raw_modules(config: Config, results: Dict[str, Dict[str, object]]) -> None:
    if config.keep_raw_on_success:
        return
    for item in results.values():
        if item.get("status") != "ok":
            continue
        raw_ll_path = item.get("raw_ll")
        if not raw_ll_path:
            continue
        delete_if_exists(Path(raw_ll_path))


def resolve_raw_ll_path(config: Config, item: Dict[str, object]) -> Optional[Path]:
    raw_ll_path = item.get("raw_ll")
    if raw_ll_path:
        candidate = Path(raw_ll_path)
        if candidate.exists():
            return candidate
    fallback = config.raw_dir / f"{item['tag']}.raw.ll"
    if fallback.exists():
        return fallback
    return None


def main() -> int:
    parse_args()
    print(
        "This module documents the legacy offline static sharding CLI shape only. "
        "It is not the default dynamic branch-driven runnable-lift entrypoint.",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
