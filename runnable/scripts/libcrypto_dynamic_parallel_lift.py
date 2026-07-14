#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import queue
import re
import shlex
import shutil
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
import dataclasses
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]
WORKSPACE_ROOT = REPO_ROOT.parent
DEFAULT_HDD_ROOT = Path("/hdd/runnable-libcrypto-dynamic-parallel")
DEFAULT_RUNNABLE_IMAGE = "rr_qemu_v2_runtime:latest"
DEFAULT_GROUNDTRUTH_X86_IMAGE = "bin2415/x86_gt:0.1"
DEFAULT_GROUNDTRUTH_PY_IMAGE = "bin2415/py_gt"
DEFAULT_BASE_ADDRESS = 0x50000000
DEFAULT_MIN_FUNCTION_SIZE = 64
DEFAULT_MAX_SEEDS = 0
DEFAULT_WORKER_MEMORY_GB = 3.0
DEFAULT_BUILD_MEMORY_GB = 16.0
DEFAULT_LIFT_TIMEOUT_SEC = 1800
DEFAULT_SHARD_BYTE_BUDGET = 4096
DEFAULT_SHARD_MAX_SEEDS = 64
DEFAULT_MERGE_WORKERS = 2
DEFAULT_MERGE_BATCH_SIZE = 64
DEFAULT_MERGE_POLL_INTERVAL_SEC = 1.0
DEFAULT_DISK_POLL_INTERVAL_SEC = 5.0
DU_TRANSIENT_RETRY_COUNT = 3
DU_TRANSIENT_RETRY_DELAY_SEC = 0.2
DEFAULT_HDD_MIN_FREE_GB = 50.0
DEFAULT_EXECUTION_MODEL = "single-container-shards"
DEFAULT_COORDINATOR_EXTRA_FLAGS = ["-use-debug-symbols", "-no-link"]
DEFAULT_SHARED_INSTALL_DIR = Path("/hdd/runnable-libcrypto-dynamic-parallel-optimized/shared-install-runnable")
SYSTEM_LLVM_LIB_DIRS = ("/usr/lib/llvm-18/lib", "/usr/lib/llvm-17/lib", "/usr/lib/llvm-16/lib")
LEGACY_RUNNABLE_ROOT = "/root/Runnable-Rewriting/root"
SHARD_RUNNER_SCRIPT = SCRIPT_DIR / "libcrypto_parallel_shard_runner.py"
READ_ELF_FUNC_RE = re.compile(
    r"^\s*\d+:\s*([0-9a-fA-F]+)\s+(\S+)\s+FUNC\s+\w+\s+\w+\s+(\w+)\s+(.*)$"
)


if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from libcrypto_bench_paths import default_blocks_pb2  # noqa: E402
from libcrypto_bench_paths import default_compare_tool  # noqa: E402
from libcrypto_bench_paths import detect_text_start  # noqa: E402


@dataclass(frozen=True)
class SeedFunction:
    start: int
    size: int
    end_exclusive: int
    name: str
    binding: str

    @property
    def tag(self) -> str:
        return f"fn_{self.start:016x}"


@dataclass(frozen=True)
class LiftShard:
    shard_id: str
    seeds: Tuple[SeedFunction, ...]
    total_size: int

    @property
    def entry_pc(self) -> int:
        return self.seeds[0].start

    @property
    def start(self) -> int:
        return self.seeds[0].start

    @property
    def end_exclusive(self) -> int:
        return self.seeds[-1].end_exclusive

    @property
    def seed_count(self) -> int:
        return len(self.seeds)


@dataclass(frozen=True)
class LiftLayout:
    root: Path
    groundtruth_root: Path
    runs_root: Path
    current_run: Path
    logs_dir: Path
    build_dir: Path
    install_dir: Path
    shared_install_dir: Path
    raw_dir: Path
    merged_dir: Path
    fragments_dir: Path
    eval_dir: Path
    manifests_dir: Path
    binary_dir: Path
    shard_dir: Path
    shard_logs_dir: Path
    shard_manifests_dir: Path
    shard_merged_dir: Path
    merge_state_dir: Path
    merge_logs_dir: Path
    merge_batches_dir: Path


@dataclass(frozen=True)
class LiftConfig:
    workspace_root: Path
    repo_root: Path
    groudtruth_repo_root: Path
    layout: LiftLayout
    docker_image: str
    gt_x86_image: str
    gt_py_image: str
    runnable_base: int
    min_function_size: int
    max_seeds: int
    seed_start: Optional[int]
    requested_parallel_workers: int
    max_concurrent_coordinators: int
    worker_memory_gb: float
    build_memory_gb: float
    memory_headroom_gb: float
    container_memory_limit_gb: Optional[float]
    rebuild_lift: bool
    ensure_groundtruth: bool
    dry_run: bool
    lift_timeout_sec: int
    skip_cmp: bool
    groundtruth_version: str
    groundtruth_openssl_version: str
    run_label: str
    coordinator_flags: Tuple[str, ...]
    execution_model: str
    shard_byte_budget: int
    shard_max_seeds: int
    shard_concurrency: int
    range_mode: str
    container_cpus: Optional[float]
    preserve_success_seed_logs: bool
    streaming_merge: bool
    merge_workers: int
    merge_batch_size: int
    merge_poll_interval_sec: float
    libtinycode_override: Optional[Path] = None
    libtinycode_helpers_override: Optional[Path] = None
    container_storage_limit_gb: Optional[float] = None
    run_disk_limit_gb: Optional[float] = None
    hdd_min_free_gb: Optional[float] = None
    disk_poll_interval_sec: float = DEFAULT_DISK_POLL_INTERVAL_SEC
    prune_intermediate_files: bool = True
    dynsym_only: bool = True
    static_fallback_profiles: Tuple[str, ...] = ()
    static_fallback_symbol_regexes: Tuple[str, ...] = ()


@dataclass(frozen=True)
class MergeBatchNode:
    level: int
    index: int
    children: Tuple[str, ...]
    output: Path
    summary_out: Path

    @property
    def node_id(self) -> str:
        child_digest = hashlib.sha1(
            "\n".join(self.children).encode("utf-8")
        ).hexdigest()[:12]
        return f"batch_l{self.level:02d}_{self.index:04d}_{child_digest}"


@dataclass
class MergeProgress:
    seed_total: int
    shard_total: int
    lift_completed: int = 0
    seed_merged: int = 0
    shard_merged: int = 0
    batch_merged: int = 0
    queued_seed_merges: int = 0
    queued_shard_merges: int = 0
    queued_batch_merges: int = 0

    def to_dict(self) -> Dict[str, object]:
        return {
            "seed_total": self.seed_total,
            "shard_total": self.shard_total,
            "lift_completed": self.lift_completed,
            "seed_merged": self.seed_merged,
            "shard_merged": self.shard_merged,
            "batch_merged": self.batch_merged,
            "queued_seed_merges": self.queued_seed_merges,
            "queued_shard_merges": self.queued_shard_merges,
            "queued_batch_merges": self.queued_batch_merges,
        }


@dataclass
class MergeState:
    shard_expected_counts: Dict[str, int]
    shard_start_addrs: Dict[str, int]
    seed_results: Dict[str, Dict[str, object]]
    seed_merge_enqueued: Set[str]
    seed_merge_completed: Set[str]
    shard_merge_enqueued: Set[str]
    shard_merge_completed: Set[str]
    batch_merge_enqueued: Set[str]
    batch_merge_completed: Set[str]
    completed_results_offset: int = 0


@dataclass
class RestoredStreamingMergeState:
    state: MergeState
    progress: MergeProgress
    shard_seed_results: Dict[str, Dict[str, Dict[str, object]]]
    shard_summaries: Dict[str, Dict[str, object]]
    available_inputs: Dict[str, Path]
    batch_plan: List[MergeBatchNode]
    batch_result_payloads: List[Dict[str, object]]
    first_success_entry_pc: Optional[int]
    frontier_root_id: Optional[str]
    frontier_root_output: Optional[Path]


def parse_int(value: str) -> int:
    return int(value, 0)


def format_ts() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def log(message: str) -> None:
    print(f"[{format_ts()}] {message}", flush=True)


def shell_join(parts: Sequence[str]) -> str:
    return " ".join(shlex.quote(part) for part in parts)


def run_cmd(
    cmd: Sequence[str],
    *,
    check: bool = True,
    cwd: Optional[Path] = None,
    env: Optional[Dict[str, str]] = None,
    capture_output: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(cmd),
        check=check,
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        capture_output=capture_output,
    )


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def maybe_float(value: Optional[str]) -> Optional[float]:
    if value is None:
        return None
    return float(value)


def maybe_positive_float(value: Optional[float]) -> Optional[float]:
    if value is None:
        return None
    numeric = float(value)
    return numeric if numeric > 0 else None


def now_stamp() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S %z")


def detect_total_memory_gb() -> float:
    meminfo = Path("/proc/meminfo").read_text(encoding="utf-8")
    for line in meminfo.splitlines():
        if line.startswith("MemAvailable:"):
            kb = int(line.split()[1])
            return kb / (1024.0 * 1024.0)
    raise RuntimeError("cannot detect MemAvailable from /proc/meminfo")


def clamp(value: int, minimum: int, maximum: int) -> int:
    return max(minimum, min(maximum, value))


def choose_container_memory_limit_gb(
    available_gb: float,
    requested_limit_gb: Optional[float],
    headroom_gb: float,
) -> Optional[float]:
    if requested_limit_gb is not None:
        return requested_limit_gb
    limit = math.floor(max(available_gb - headroom_gb, 1.0))
    return float(limit) if limit > 0 else None


def estimate_parallel_workers(
    *,
    requested_parallel_workers: int,
    max_concurrent_coordinators: int,
    worker_memory_gb: float,
    container_memory_limit_gb: Optional[float],
) -> Tuple[int, int]:
    if container_memory_limit_gb is None:
        return requested_parallel_workers, max_concurrent_coordinators
    max_total_workers = max(1, int(container_memory_limit_gb // max(worker_memory_gb, 0.25)))
    coordinators = clamp(max_concurrent_coordinators, 1, max_total_workers)
    workers_per_coord = max(1, max_total_workers // coordinators)
    return min(requested_parallel_workers, workers_per_coord), coordinators


def build_layout(base_root: Path, run_label: str) -> LiftLayout:
    current_run = base_root / "runs" / run_label
    return LiftLayout(
        root=base_root,
        groundtruth_root=base_root / "groundtruth",
        runs_root=base_root / "runs",
        current_run=current_run,
        logs_dir=current_run / "logs",
        build_dir=current_run / "build-runnable",
        install_dir=current_run / "install-runnable",
        shared_install_dir=base_root / "shared-install-runnable",
        raw_dir=current_run / "raw",
        merged_dir=current_run / "merged",
        fragments_dir=current_run / "fragments",
        eval_dir=current_run / "eval",
        manifests_dir=current_run / "manifests",
        binary_dir=current_run / "binary",
        shard_dir=current_run / "shards",
        shard_logs_dir=current_run / "shards" / "logs",
        shard_manifests_dir=current_run / "manifests" / "shards",
        shard_merged_dir=current_run / "shards" / "merged",
        merge_state_dir=current_run / "merge-state",
        merge_logs_dir=current_run / "merge-state" / "logs",
        merge_batches_dir=current_run / "merge-state" / "batches",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "One-shot libcrypto dynamic parallel lift orchestrator. "
            "It builds or reuses canonical ground truth, compiles a current "
            "dynamic-parallel runnable-lift inside Docker when needed, "
            "runs per-function coordinators against libcrypto.so.3, "
            "merges the resulting full modules, and optionally runs the "
            "canonical gtBlock.pb compare."
        )
    )
    parser.add_argument("--hdd-root", type=Path, default=DEFAULT_HDD_ROOT)
    parser.add_argument("--workspace-root", type=Path, default=WORKSPACE_ROOT)
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument("--groudtruth-repo-root", type=Path, default=WORKSPACE_ROOT / "GroudTruth")
    parser.add_argument(
        "--docker-image",
        default=os.environ.get("RUNNABLE_QEMU_V2_IMAGE", DEFAULT_RUNNABLE_IMAGE),
    )
    parser.add_argument("--gt-x86-image", default=DEFAULT_GROUNDTRUTH_X86_IMAGE)
    parser.add_argument("--gt-py-image", default=DEFAULT_GROUNDTRUTH_PY_IMAGE)
    parser.add_argument("--run-label", default=time.strftime("libcrypto-dyn-%Y%m%d-%H%M%S"))
    parser.add_argument("--runnable-base", type=parse_int, default=DEFAULT_BASE_ADDRESS)
    parser.add_argument("--min-function-size", type=int, default=DEFAULT_MIN_FUNCTION_SIZE)
    parser.add_argument("--max-seeds", type=int, default=DEFAULT_MAX_SEEDS)
    parser.add_argument(
        "--seed-start",
        type=parse_int,
        default=None,
        help="Only lift the function seed whose symbol start matches this address.",
    )
    parser.add_argument("--parallel-workers", type=int, default=8)
    parser.add_argument("--max-concurrent-coordinators", type=int, default=2)
    parser.add_argument(
        "--shard-concurrency",
        type=int,
        default=None,
        help="Maximum number of shard jobs to run concurrently inside the container.",
    )
    parser.add_argument(
        "--shard-byte-budget",
        type=int,
        default=DEFAULT_SHARD_BYTE_BUDGET,
        help="Approximate total function bytes to include in a shard.",
    )
    parser.add_argument(
        "--shard-max-seeds",
        type=int,
        default=DEFAULT_SHARD_MAX_SEEDS,
        help="Maximum number of function seeds to include in a shard.",
    )
    parser.add_argument(
        "--range-mode",
        choices=("seed", "shard", "none"),
        default="seed",
        help=(
            "Address-range granularity passed to libcrypto_parallel_shard_runner. "
            "'seed' constrains each coordinator to its function symbol range; "
            "'shard' uses the containing shard range; 'none' leaves dynamic-parallel unbounded."
        ),
    )
    parser.add_argument("--worker-memory-gb", type=float, default=DEFAULT_WORKER_MEMORY_GB)
    parser.add_argument("--build-memory-gb", type=float, default=DEFAULT_BUILD_MEMORY_GB)
    parser.add_argument("--memory-headroom-gb", type=float, default=8.0)
    parser.add_argument("--container-memory-limit-gb", type=float, default=None)
    parser.add_argument(
        "--container-cpus",
        type=float,
        default=None,
        help="Optional Docker CPU limit for the long-lived execution container.",
    )
    parser.add_argument(
        "--container-storage-limit-gb",
        type=float,
        default=None,
        help=(
            "Optional Docker writable-layer size limit for each container. "
            "This does not cap bind-mounted /hdd-work outputs."
        ),
    )
    parser.add_argument(
        "--run-disk-limit-gb",
        type=float,
        default=None,
        help="Abort the run if bytes under the current run root exceed this many GB.",
    )
    parser.add_argument(
        "--hdd-min-free-gb",
        type=float,
        default=DEFAULT_HDD_MIN_FREE_GB,
        help=(
            "Abort the run if free space on the filesystem backing --hdd-root "
            "drops below this many GB."
        ),
    )
    parser.add_argument(
        "--disk-poll-interval-sec",
        type=float,
        default=DEFAULT_DISK_POLL_INTERVAL_SEC,
        help="Polling interval for host-side disk budget checks.",
    )
    parser.add_argument("--lift-timeout-sec", type=int, default=DEFAULT_LIFT_TIMEOUT_SEC)
    parser.add_argument(
        "--merge-workers",
        type=int,
        default=DEFAULT_MERGE_WORKERS,
        help="Maximum number of host-side merge jobs to run concurrently.",
    )
    parser.add_argument(
        "--merge-batch-size",
        type=int,
        default=DEFAULT_MERGE_BATCH_SIZE,
        help="Maximum fan-in for one incremental merge batch node.",
    )
    parser.add_argument(
        "--merge-poll-interval-sec",
        type=float,
        default=DEFAULT_MERGE_POLL_INTERVAL_SEC,
        help="Polling interval for host-side streaming merge scheduling.",
    )
    parser.add_argument(
        "--streaming-merge",
        dest="streaming_merge",
        action="store_true",
        help="Start host-side merge work as soon as seed lifts complete.",
    )
    parser.add_argument(
        "--no-streaming-merge",
        dest="streaming_merge",
        action="store_false",
        help="Disable overlap and fall back to the barrier-style host merge path.",
    )
    parser.set_defaults(streaming_merge=True)
    parser.add_argument(
        "--execution-model",
        choices=["single-container-shards", "legacy-seed-docker", "host-shards"],
        default=DEFAULT_EXECUTION_MODEL,
        help="Outer orchestration model for libcrypto dynamic parallel lift.",
    )
    parser.add_argument("--rebuild-lift", action="store_true")
    parser.add_argument("--no-rebuild-lift", dest="rebuild_lift", action="store_false")
    parser.set_defaults(rebuild_lift=True)
    parser.add_argument("--ensure-groundtruth", action="store_true")
    parser.add_argument("--no-ensure-groundtruth", dest="ensure_groundtruth", action="store_false")
    parser.set_defaults(ensure_groundtruth=True)
    parser.add_argument("--skip-cmp", action="store_true")
    parser.add_argument(
        "--static-fallback-profile",
        action="append",
        choices=("avx512", "simd-heavy", "all-functions", "all-text"),
        default=[],
        help=(
            "Forwarded to validate_libcrypto_ground_truth.py cmp for named static "
            "mnemonic fallback profiles. May be repeated."
        ),
    )
    parser.add_argument(
        "--static-fallback-symbol-regex",
        action="append",
        default=[],
        help=(
            "Forwarded to validate_libcrypto_ground_truth.py cmp to enable static "
            "mnemonic fallback for matching ELF FUNC symbols. May be repeated."
        ),
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--preserve-success-seed-logs",
        action="store_true",
        help="Keep per-seed stdout/stderr logs even when the seed succeeds.",
    )
    parser.add_argument(
        "--prune-intermediate-files",
        dest="prune_intermediate_files",
        action="store_true",
        help=(
            "Delete intermediate .ll files (worker fragments, raw outputs, per-seed "
            "and per-shard merged files) as soon as they are no longer needed. "
            "Reduces peak disk usage by ~100 GB per run. Enabled by default."
        ),
    )
    parser.add_argument(
        "--no-prune-intermediate-files",
        dest="prune_intermediate_files",
        action="store_false",
        help="Disable intermediate file pruning (useful for debugging).",
    )
    parser.set_defaults(prune_intermediate_files=True)
    parser.add_argument(
        "--dynsym-only",
        dest="dynsym_only",
        action="store_true",
        help=(
            "Use only exported (.dynsym) symbols as lift entry points (worklist seeds). "
            "Combined with no address-range constraints, each exported function explores "
            "all reachable code via the internal -dynamic-parallel worklist. "
            "Reduces seed count from ~5000 to ~300-500 while improving recall. "
            "Enabled by default."
        ),
    )
    parser.add_argument(
        "--all-symbols",
        dest="dynsym_only",
        action="store_false",
        help="Use all function symbols (including internal .symtab) as lift entry points.",
    )
    parser.set_defaults(dynsym_only=True)
    parser.add_argument("--groundtruth-version", default="canonical")
    parser.add_argument("--groundtruth-openssl-version", default="3.4.4")
    parser.add_argument(
        "--libtinycode-path",
        type=Path,
        default=None,
        help="Optional libtinycode-x86_64.so override to stage into the runnable-lift runtime.",
    )
    parser.add_argument(
        "--libtinycode-helpers-path",
        type=Path,
        default=None,
        help="Optional libtinycode-helpers-x86_64.ll override to stage into the runnable-lift runtime.",
    )
    parser.add_argument(
        "--coordinator-flag",
        action="append",
        default=[],
        help="Extra flag forwarded to each runnable-lift coordinator invocation.",
    )
    return parser


def load_config(args: argparse.Namespace) -> LiftConfig:
    layout = build_layout(args.hdd_root.resolve(), args.run_label)
    available_gb = detect_total_memory_gb()
    container_limit_gb = choose_container_memory_limit_gb(
        available_gb=available_gb,
        requested_limit_gb=args.container_memory_limit_gb,
        headroom_gb=args.memory_headroom_gb,
    )
    requested_shard_concurrency = (
        args.shard_concurrency
        if args.shard_concurrency is not None
        else args.max_concurrent_coordinators
    )
    tuned_workers, tuned_shards = estimate_parallel_workers(
        requested_parallel_workers=args.parallel_workers,
        max_concurrent_coordinators=requested_shard_concurrency,
        worker_memory_gb=args.worker_memory_gb,
        container_memory_limit_gb=container_limit_gb,
    )
    extra_flags = list(DEFAULT_COORDINATOR_EXTRA_FLAGS)
    extra_flags.extend(args.coordinator_flag)
    return LiftConfig(
        workspace_root=args.workspace_root.resolve(),
        repo_root=args.repo_root.resolve(),
        groudtruth_repo_root=args.groudtruth_repo_root.resolve(),
        layout=layout,
        docker_image=args.docker_image,
        gt_x86_image=args.gt_x86_image,
        gt_py_image=args.gt_py_image,
        runnable_base=args.runnable_base,
        min_function_size=args.min_function_size,
        max_seeds=args.max_seeds,
        seed_start=args.seed_start,
        requested_parallel_workers=tuned_workers,
        max_concurrent_coordinators=tuned_shards,
        worker_memory_gb=args.worker_memory_gb,
        build_memory_gb=args.build_memory_gb,
        memory_headroom_gb=args.memory_headroom_gb,
        container_memory_limit_gb=container_limit_gb,
        rebuild_lift=args.rebuild_lift,
        ensure_groundtruth=args.ensure_groundtruth,
        dry_run=args.dry_run,
        lift_timeout_sec=args.lift_timeout_sec,
        skip_cmp=args.skip_cmp,
        groundtruth_version=args.groundtruth_version,
        groundtruth_openssl_version=args.groundtruth_openssl_version,
        run_label=args.run_label,
        coordinator_flags=tuple(extra_flags),
        execution_model=args.execution_model,
        shard_byte_budget=max(args.shard_byte_budget, 1),
        shard_max_seeds=max(args.shard_max_seeds, 1),
        shard_concurrency=max(tuned_shards, 1),
        range_mode=args.range_mode,
        container_cpus=maybe_float(args.container_cpus),
        preserve_success_seed_logs=args.preserve_success_seed_logs,
        streaming_merge=args.streaming_merge,
        prune_intermediate_files=args.prune_intermediate_files,
        dynsym_only=args.dynsym_only,
        static_fallback_profiles=tuple(args.static_fallback_profile),
        static_fallback_symbol_regexes=tuple(args.static_fallback_symbol_regex),
        merge_workers=max(args.merge_workers, 1),
        merge_batch_size=max(args.merge_batch_size, 2),
        merge_poll_interval_sec=max(args.merge_poll_interval_sec, 0.1),
        libtinycode_override=args.libtinycode_path.resolve() if args.libtinycode_path else None,
        libtinycode_helpers_override=(
            args.libtinycode_helpers_path.resolve()
            if args.libtinycode_helpers_path
            else None
        ),
        container_storage_limit_gb=maybe_positive_float(args.container_storage_limit_gb),
        run_disk_limit_gb=maybe_positive_float(args.run_disk_limit_gb),
        hdd_min_free_gb=maybe_positive_float(args.hdd_min_free_gb),
        disk_poll_interval_sec=max(args.disk_poll_interval_sec, 0.1),
    )


def materialize_layout(layout: LiftLayout) -> None:
    for path in (
        layout.root,
        layout.groundtruth_root,
        layout.runs_root,
        layout.current_run,
        layout.logs_dir,
        layout.build_dir,
        layout.install_dir,
        layout.shared_install_dir,
        layout.raw_dir,
        layout.merged_dir,
        layout.fragments_dir,
        layout.eval_dir,
        layout.manifests_dir,
        layout.binary_dir,
        layout.shard_dir,
        layout.shard_logs_dir,
        layout.shard_manifests_dir,
        layout.shard_merged_dir,
        layout.merge_state_dir,
        layout.merge_logs_dir,
        layout.merge_batches_dir,
    ):
        ensure_dir(path)


def groundtruth_artifact_paths(config: LiftConfig) -> Dict[str, Path]:
    root = config.layout.groundtruth_root / "libcrypto-artifacts"
    return {
        "root": root,
        "binary": root / "libcrypto.so.3",
        "protobuf": root / "libcrypto.gtBlock.pb",
        "blocks_pb2": default_blocks_pb2(config.repo_root),
        "cmp_tool": default_compare_tool(config.repo_root),
    }


def repo_local_groundtruth_paths(config: LiftConfig) -> Dict[str, Path]:
    root = config.groudtruth_repo_root / "groundtruth-gap-analysis-skill" / "results" / "libcrypto-artifacts"
    return {
        "root": root,
        "binary": root / "libcrypto.so.3",
        "protobuf": root / "libcrypto.gtBlock.pb",
    }


def host_mounts(config: LiftConfig) -> List[str]:
    return [
        f"{config.workspace_root}:/workspace",
        f"{config.layout.root}:/hdd-work",
    ]


def sanitize_container_name(run_label: str) -> str:
    collapsed = re.sub(r"[^a-zA-Z0-9_.-]+", "-", run_label)
    return f"rr-libcrypto-{collapsed[:40]}"


def map_host_path_to_container(config: LiftConfig, path: Path) -> str:
    resolved = path.resolve()
    workspace_root = config.workspace_root.resolve()
    hdd_root = config.layout.root.resolve()
    if str(resolved).startswith(str(workspace_root)):
        return "/workspace/" + str(resolved.relative_to(workspace_root))
    if str(resolved).startswith(str(hdd_root)):
        return "/hdd-work/" + str(resolved.relative_to(hdd_root))
    raise RuntimeError(f"path {resolved} is outside mounted roots")


def map_container_path_to_host(config: LiftConfig, path: str) -> Path:
    raw = Path(path)
    raw_str = str(raw)
    if raw_str == "/workspace" or raw_str.startswith("/workspace/"):
        relative = raw.relative_to("/workspace")
        return (config.workspace_root / relative).resolve()
    if raw_str == "/hdd-work" or raw_str.startswith("/hdd-work/"):
        relative = raw.relative_to("/hdd-work")
        return (config.layout.root / relative).resolve()
    return raw


def docker_mem_args(limit_gb: Optional[float]) -> List[str]:
    if limit_gb is None:
        return []
    gb = max(limit_gb, 1.0)
    return ["--memory", f"{gb:.0f}g", "--memory-swap", f"{gb:.0f}g"]


def docker_storage_args(limit_gb: Optional[float]) -> List[str]:
    if limit_gb is None:
        return []
    gb = max(limit_gb, 1.0)
    return ["--storage-opt", f"size={gb:.0f}G"]


def docker_run_shell(
    image: str,
    shell_script: str,
    *,
    mounts: Sequence[str],
    workdir: str,
    env: Optional[Dict[str, str]] = None,
    memory_limit_gb: Optional[float] = None,
    storage_limit_gb: Optional[float] = None,
    capture_output: bool = True,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    cmd = ["docker", "run", "--rm"]
    cmd.extend(docker_mem_args(memory_limit_gb))
    cmd.extend(docker_storage_args(storage_limit_gb))
    for mount in mounts:
        cmd.extend(["-v", mount])
    if env:
        for key, value in env.items():
            cmd.extend(["-e", f"{key}={value}"])
    cmd.extend(["-w", workdir, image, "bash", "-lc", shell_script])
    return run_cmd(cmd, check=check, capture_output=capture_output)


def docker_exec_shell(
    container_name: str,
    shell_script: str,
    *,
    env: Optional[Dict[str, str]] = None,
    capture_output: bool = True,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    cmd = ["docker", "exec"]
    if env:
        for key, value in env.items():
            cmd.extend(["-e", f"{key}={value}"])
    cmd.extend([container_name, "bash", "-lc", shell_script])
    return run_cmd(cmd, check=check, capture_output=capture_output)


def docker_rm_force(container_name: str) -> None:
    run_cmd(
        ["docker", "rm", "-f", container_name],
        check=False,
        capture_output=True,
    )


def start_long_lived_container(
    config: LiftConfig,
    runtime: Dict[str, str],
) -> str:
    container_name = sanitize_container_name(config.run_label)
    if config.dry_run:
        return container_name
    docker_rm_force(container_name)
    cmd = ["docker", "run", "-d", "--rm", "--name", container_name]
    cmd.extend(docker_mem_args(config.container_memory_limit_gb))
    cmd.extend(docker_storage_args(config.container_storage_limit_gb))
    if config.container_cpus is not None:
        cmd.extend(["--cpus", str(config.container_cpus)])
    for mount in host_mounts(config):
        cmd.extend(["-v", mount])
    cmd.extend(
        [
            "-w",
            "/workspace",
            "-e",
            f"PATH={runtime['PATH']}",
            "-e",
            f"LD_LIBRARY_PATH={runtime['LD_LIBRARY_PATH']}",
            "-e",
            f"PYTHONPATH={runtime['PYTHONPATH']}",
            config.docker_image,
            "bash",
            "-lc",
            "trap 'exit 0' TERM INT; while true; do sleep 60; done",
        ]
    )
    result = run_cmd(cmd, capture_output=True)
    container_id = result.stdout.strip()
    if not container_id:
        raise RuntimeError("docker run did not return a container id")
    return container_name


def readelf_function_seeds(binary: Path, min_function_size: int) -> List[SeedFunction]:
    result = run_cmd(["readelf", "-Ws", str(binary)], capture_output=True)
    current_table = ""
    seeds: Dict[int, SeedFunction] = {}
    for line in result.stdout.splitlines():
        if line.startswith("Symbol table "):
            current_table = line
            continue
        match = READ_ELF_FUNC_RE.match(line)
        if match is None:
            continue
        value = int(match.group(1), 16)
        size = int(match.group(2), 0)
        ndx = match.group(3)
        raw_name = match.group(4).strip()
        if ndx == "UND" or value == 0 or size < min_function_size or not raw_name:
            continue
        name = raw_name.split("@", 1)[0]
        candidate = SeedFunction(
            start=value,
            size=size,
            end_exclusive=value + size,
            name=name,
            binding="dynsym" if ".dynsym" in current_table else "symtab",
        )
        previous = seeds.get(value)
        if previous is None or candidate.size > previous.size:
            seeds[value] = candidate
    return sorted(seeds.values(), key=lambda item: (item.start, item.name))


def write_seed_manifest(path: Path, seeds: Sequence[SeedFunction]) -> None:
    rows = [
        {
            "start_hex": hex(seed.start),
            "size": seed.size,
            "end_exclusive_hex": hex(seed.end_exclusive),
            "name": seed.name,
            "binding": seed.binding,
        }
        for seed in seeds
    ]
    path.write_text(json.dumps(rows, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_seed_csv(path: Path, seeds: Sequence[SeedFunction]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["addr_hex", "name", "end_hex"])
        writer.writeheader()
        for seed in seeds:
            writer.writerow(
                {
                    "addr_hex": hex(seed.start),
                    "name": seed.name,
                    "end_hex": hex(seed.end_exclusive - 1),
                }
            )


def merge_state_paths(layout: LiftLayout) -> Dict[str, Path]:
    return {
        "seed_lift_events": layout.merge_state_dir / "seed-lift-events.jsonl",
        "seed_merge_events": layout.merge_state_dir / "seed-merge-events.jsonl",
        "shard_merge_events": layout.merge_state_dir / "shard-merge-events.jsonl",
        "batch_merge_events": layout.merge_state_dir / "batch-merge-events.jsonl",
        "progress": layout.merge_state_dir / "merge-progress.json",
        "state": layout.merge_state_dir / "merge-state.json",
        "frontier": layout.merge_state_dir / "merge-frontier.json",
    }


def append_jsonl(path: Path, payload: Dict[str, object]) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=True) + "\n")


def load_jsonl(path: Path) -> List[Dict[str, object]]:
    if not path.exists():
        return []
    items: List[Dict[str, object]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            items.append(json.loads(line))
    return items


def render_summary(payload: Dict[str, object]) -> str:
    return json.dumps(payload, indent=2, sort_keys=True) + "\n"


def bytes_to_gb(value: int) -> float:
    return value / float(1024 ** 3)


def measure_tree_bytes(path: Path) -> int:
    if not path.exists():
        return 0
    last_detail = ""
    for attempt in range(DU_TRANSIENT_RETRY_COUNT):
        result = run_cmd(["du", "-sb", str(path)], capture_output=True, check=False)
        for line in reversed((result.stdout or "").splitlines()):
            tokens = line.strip().split(maxsplit=1)
            if not tokens:
                continue
            try:
                return int(tokens[0])
            except ValueError:
                continue
        stderr = (result.stderr or "").strip()
        last_detail = f" rc={result.returncode}"
        if stderr:
            last_detail = f"{last_detail}: {stderr}"
        if result.returncode != 0 and "No such file or directory" in stderr:
            if not path.exists():
                return 0
            if attempt + 1 < DU_TRANSIENT_RETRY_COUNT:
                time.sleep(DU_TRANSIENT_RETRY_DELAY_SEC)
                continue
        if result.returncode != 0:
            raise RuntimeError(f"du -sb failed for {path}{last_detail}")
        raise RuntimeError(f"du -sb produced no parseable size for {path}")
    raise RuntimeError(f"du -sb failed for {path}{last_detail}")


def disk_budget_path(layout: LiftLayout) -> Path:
    return layout.current_run / "disk-budget.json"


def disk_budget_enabled(config: LiftConfig) -> bool:
    return config.run_disk_limit_gb is not None or config.hdd_min_free_gb is not None


def collect_disk_budget_snapshot(config: LiftConfig) -> Dict[str, object]:
    run_bytes = measure_tree_bytes(config.layout.current_run)
    filesystem = shutil.disk_usage(config.layout.root)
    run_limit_bytes = (
        int(config.run_disk_limit_gb * (1024 ** 3))
        if config.run_disk_limit_gb is not None
        else None
    )
    min_free_bytes = (
        int(config.hdd_min_free_gb * (1024 ** 3))
        if config.hdd_min_free_gb is not None
        else None
    )
    reason_codes: List[str] = []
    reason_parts: List[str] = []
    if run_limit_bytes is not None and run_bytes > run_limit_bytes:
        reason_codes.append("run_disk_limit_exceeded")
        reason_parts.append(
            f"run_root_size_gb={bytes_to_gb(run_bytes):.2f} exceeded run_disk_limit_gb={config.run_disk_limit_gb:.2f}"
        )
    if min_free_bytes is not None and filesystem.free < min_free_bytes:
        reason_codes.append("hdd_min_free_exceeded")
        reason_parts.append(
            f"hdd_free_gb={bytes_to_gb(filesystem.free):.2f} dropped below hdd_min_free_gb={config.hdd_min_free_gb:.2f}"
        )
    return {
        "checked_at": now_stamp(),
        "run_root": str(config.layout.current_run),
        "hdd_root": str(config.layout.root),
        "run_bytes": run_bytes,
        "run_size_gb": bytes_to_gb(run_bytes),
        "run_disk_limit_gb": config.run_disk_limit_gb,
        "run_disk_limit_bytes": run_limit_bytes,
        "filesystem_total_bytes": filesystem.total,
        "filesystem_used_bytes": filesystem.used,
        "filesystem_free_bytes": filesystem.free,
        "filesystem_free_gb": bytes_to_gb(filesystem.free),
        "hdd_min_free_gb": config.hdd_min_free_gb,
        "hdd_min_free_bytes": min_free_bytes,
        "poll_interval_sec": config.disk_poll_interval_sec,
        "limit_exceeded": bool(reason_codes),
        "limit_reason_codes": reason_codes,
        "limit_message": "; ".join(reason_parts) if reason_parts else None,
    }


@dataclass
class DiskBudgetMonitor:
    config: LiftConfig
    stop_event: threading.Event
    latest_snapshot: Optional[Dict[str, object]] = None
    exceeded_snapshot: Optional[Dict[str, object]] = None
    error_message: Optional[str] = None
    thread: Optional[threading.Thread] = None

    def close(self) -> None:
        self.stop_event.set()
        if self.thread is not None:
            self.thread.join(timeout=max(self.config.disk_poll_interval_sec * 2.0, 1.0))
        snapshot = collect_disk_budget_snapshot(self.config)
        self.latest_snapshot = snapshot
        write_summary(disk_budget_path(self.config.layout), snapshot)
        if snapshot.get("limit_exceeded") and self.exceeded_snapshot is None:
            self.exceeded_snapshot = snapshot

    def failure_message(self) -> Optional[str]:
        if self.error_message is not None:
            return f"disk budget monitor failed: {self.error_message}"
        if self.exceeded_snapshot is not None:
            return str(self.exceeded_snapshot.get("limit_message") or "disk budget exceeded")
        return None


def start_disk_budget_monitor(
    config: LiftConfig,
    *,
    container_name: Optional[str],
) -> DiskBudgetMonitor:
    monitor = DiskBudgetMonitor(config=config, stop_event=threading.Event())
    summary_cache: Dict[Path, str] = {}
    initial_snapshot = collect_disk_budget_snapshot(config)
    monitor.latest_snapshot = initial_snapshot
    write_summary_if_changed(disk_budget_path(config.layout), initial_snapshot, summary_cache)
    if not disk_budget_enabled(config):
        return monitor
    if initial_snapshot["limit_exceeded"]:
        monitor.exceeded_snapshot = initial_snapshot
        if container_name is not None and not config.dry_run:
            docker_rm_force(container_name)
        return monitor

    def worker() -> None:
        while not monitor.stop_event.wait(config.disk_poll_interval_sec):
            try:
                snapshot = collect_disk_budget_snapshot(config)
                monitor.latest_snapshot = snapshot
                write_summary_if_changed(disk_budget_path(config.layout), snapshot, summary_cache)
            except Exception as exc:
                monitor.error_message = str(exc)
                monitor.stop_event.set()
                return
            if not snapshot["limit_exceeded"]:
                continue
            monitor.exceeded_snapshot = snapshot
            log(f"disk budget exceeded: {snapshot['limit_message']}")
            if container_name is not None and not config.dry_run:
                docker_rm_force(container_name)
            monitor.stop_event.set()
            return

    monitor.thread = threading.Thread(
        target=worker,
        name=f"disk-budget-{config.run_label}",
        daemon=True,
    )
    monitor.thread.start()
    return monitor


def raise_if_disk_budget_exceeded(monitor: DiskBudgetMonitor) -> None:
    failure = monitor.failure_message()
    if failure is not None:
        raise RuntimeError(f"disk budget exceeded: {failure}")


def write_summary_if_changed(
    path: Path,
    payload: Dict[str, object],
    cache: Dict[Path, str],
) -> bool:
    rendered = render_summary(payload)
    previous = cache.get(path)
    if previous is None and path.exists():
        previous = path.read_text(encoding="utf-8")
        cache[path] = previous
    if previous == rendered:
        return False
    path.write_text(rendered, encoding="utf-8")
    cache[path] = rendered
    return True


def write_merge_progress(
    layout: LiftLayout,
    progress: MergeProgress,
    *,
    cache: Optional[Dict[Path, str]] = None,
) -> bool:
    path = merge_state_paths(layout)["progress"]
    if cache is None:
        write_summary(path, progress.to_dict())
        return True
    return write_summary_if_changed(path, progress.to_dict(), cache)


def write_merge_state_summary(
    layout: LiftLayout,
    state: MergeState,
    *,
    cache: Optional[Dict[Path, str]] = None,
) -> bool:
    payload = {
        "completed_results_offset": state.completed_results_offset,
        "seed_result_count": len(state.seed_results),
        "seed_merge_enqueued": len(state.seed_merge_enqueued),
        "seed_merge_completed": len(state.seed_merge_completed),
        "shard_merge_enqueued": len(state.shard_merge_enqueued),
        "shard_merge_completed": len(state.shard_merge_completed),
        "batch_merge_enqueued": len(state.batch_merge_enqueued),
        "batch_merge_completed": len(state.batch_merge_completed),
        "shard_expected_counts": state.shard_expected_counts,
    }
    path = merge_state_paths(layout)["state"]
    if cache is None:
        write_summary(path, payload)
        return True
    return write_summary_if_changed(path, payload, cache)


def initialize_merge_state(shards: Sequence[LiftShard]) -> MergeState:
    return MergeState(
        shard_expected_counts={shard.shard_id: shard.seed_count for shard in shards},
        shard_start_addrs={shard.shard_id: shard.start for shard in shards},
        seed_results={},
        seed_merge_enqueued=set(),
        seed_merge_completed=set(),
        shard_merge_enqueued=set(),
        shard_merge_completed=set(),
        batch_merge_enqueued=set(),
        batch_merge_completed=set(),
        completed_results_offset=0,
    )


def shard_seed_rows(shard: LiftShard) -> List[Dict[str, object]]:
    return [
        {
            "start_hex": hex(seed.start),
            "size": seed.size,
            "end_exclusive_hex": hex(seed.end_exclusive),
            "name": seed.name,
            "binding": seed.binding,
        }
        for seed in shard.seeds
    ]


def plan_shards(config: LiftConfig, seeds: Sequence[SeedFunction]) -> List[LiftShard]:
    shards: List[LiftShard] = []
    current: List[SeedFunction] = []
    current_size = 0

    def flush() -> None:
        nonlocal current, current_size
        if not current:
            return
        shard_id = f"shard_{len(shards):05d}_{current[0].start:016x}"
        shards.append(
            LiftShard(
                shard_id=shard_id,
                seeds=tuple(current),
                total_size=current_size,
            )
        )
        current = []
        current_size = 0

    for seed in sorted(seeds, key=lambda item: (item.start, item.name)):
        exceeds_budget = current and (
            current_size + seed.size > config.shard_byte_budget
            or len(current) >= config.shard_max_seeds
        )
        if seed.size >= config.shard_byte_budget:
            flush()
            shards.append(
                LiftShard(
                    shard_id=f"shard_{len(shards):05d}_{seed.start:016x}",
                    seeds=(seed,),
                    total_size=seed.size,
                )
            )
            continue
        if exceeds_budget:
            flush()
        current.append(seed)
        current_size += seed.size

    flush()
    return shards


def write_shard_manifests(layout: LiftLayout, shards: Sequence[LiftShard]) -> None:
    overview = []
    for shard in shards:
        manifest_path = layout.shard_manifests_dir / f"{shard.shard_id}.json"
        payload = {
            "shard_id": shard.shard_id,
            "seed_count": shard.seed_count,
            "total_size": shard.total_size,
            "start_hex": hex(shard.start),
            "end_exclusive_hex": hex(shard.end_exclusive),
            "entry_hex": hex(shard.entry_pc),
            "seeds": shard_seed_rows(shard),
        }
        write_summary(manifest_path, payload)
        overview.append(payload)
    write_summary(layout.shard_manifests_dir / "shards.json", {"shards": overview})


def load_completed_seed_tags(layout: LiftLayout) -> Set[str]:
    path = merge_state_paths(layout)["seed_lift_events"]
    if not path.exists():
        return set()
    tags: Set[str] = set()
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            payload = json.loads(line)
            tag = payload.get("tag")
            if tag is not None:
                tags.add(str(tag))
    return tags


def filter_pending_shards(
    shards: Sequence[LiftShard],
    completed_tags: Set[str],
) -> List[LiftShard]:
    pending: List[LiftShard] = []
    for shard in shards:
        pending_seeds = tuple(seed for seed in shard.seeds if seed.tag not in completed_tags)
        if not pending_seeds:
            continue
        pending.append(
            LiftShard(
                shard_id=shard.shard_id,
                seeds=pending_seeds,
                total_size=sum(seed.size for seed in pending_seeds),
            )
        )
    return pending


def status_flag_path(layout: LiftLayout) -> Path:
    return layout.current_run / "status.flag"


def mark_run_state(layout: LiftLayout, state: str, detail: Optional[str] = None) -> None:
    stamp = now_stamp()
    text = state if detail is None else f"{state} {detail}"
    status_flag_path(layout).write_text(f"{text} {stamp}\n", encoding="utf-8")
    if state == "running":
        (layout.current_run / "started_at.txt").write_text(f"{stamp}\n", encoding="utf-8")
    if state in {"ok", "failed"}:
        (layout.current_run / "finished_at.txt").write_text(f"{stamp}\n", encoding="utf-8")


def write_exit_code(layout: LiftLayout, rc: int) -> None:
    (layout.current_run / "exit_code.txt").write_text(f"{rc}\n", encoding="utf-8")


def should_build_groundtruth(paths: Dict[str, Path]) -> bool:
    return not paths["binary"].exists() or not paths["protobuf"].exists()


def ensure_groundtruth(config: LiftConfig, paths: Dict[str, Path]) -> None:
    if not config.ensure_groundtruth:
        return
    if not should_build_groundtruth(paths):
        return
    ensure_dir(paths["root"])
    source_paths = repo_local_groundtruth_paths(config)
    if source_paths["binary"].exists() and source_paths["protobuf"].exists():
        log("copying canonical Docker-built ground truth bundle into /hdd")
        run_cmd(["cp", str(source_paths["binary"]), str(paths["binary"])], capture_output=False)
        run_cmd(["cp", str(source_paths["protobuf"]), str(paths["protobuf"])], capture_output=False)
        return
    log("ground truth artifacts missing under /hdd; building canonical libcrypto bundle via Docker")
    if config.dry_run:
        return
    work_dir = config.layout.groundtruth_root / "build-work"
    ensure_dir(work_dir)
    ensure_docker_image_available(config.gt_x86_image)
    ensure_docker_image_available(config.gt_py_image)
    run_cmd(
        [
            "bash",
            "-lc",
            (
                f"cd {shlex.quote(str(config.groudtruth_repo_root))} && "
                f"WORK_DIR={shlex.quote(str(work_dir))} "
                f"OPENSSL_VER={shlex.quote(config.groundtruth_openssl_version)} "
                "DOCKER_USE_SUDO=0 "
                "bash groundtruth-gap-analysis-skill/docker/build_libcrypto_groundtruth.sh"
            ),
        ],
        capture_output=False,
    )
    built_binary = work_dir / f"openssl-{config.groundtruth_openssl_version}" / "libcrypto.so.3"
    built_pb = work_dir / "libcrypto.gtBlock.pb"
    if not built_binary.exists() or not built_pb.exists():
        raise RuntimeError("ground truth build finished without expected artifacts")
    run_cmd(["cp", str(built_binary), str(paths["binary"])], capture_output=False)
    run_cmd(["cp", str(built_pb), str(paths["protobuf"])], capture_output=False)


def help_contains_dynamic_parallel(help_text: str) -> bool:
    return (
        "dynamic-parallel" in help_text
        and "parallel-workers" in help_text
        and "parallel-fragment-dir" in help_text
    )


def ensure_docker_image_available(image: str) -> None:
    inspect = run_cmd(
        ["docker", "image", "inspect", image],
        check=False,
        capture_output=True,
    )
    if inspect.returncode == 0:
        return
    run_cmd(["docker", "pull", image], capture_output=False)


def probe_installed_runnable_lift(config: LiftConfig) -> Tuple[Optional[Path], Optional[Path], str]:
    for install_dir, label in (
        (config.layout.shared_install_dir, "shared dynamic-parallel binary"),
        (config.layout.install_dir, "run-local dynamic-parallel binary"),
    ):
        installed = install_dir / "bin" / "runnable-lift"
        if not installed.exists():
            continue
        env = os.environ.copy()
        env["LD_LIBRARY_PATH"] = str(install_dir / "lib")
        result = run_cmd([str(installed), "--help"], check=False, env=env)
        help_text = (result.stdout or "") + (result.stderr or "")
        if result.returncode != 0:
            continue
        if help_contains_dynamic_parallel(help_text):
            return installed, install_dir, label
    return None, None, "missing install prefix binary"


def probe_build_tree_runnable_lift(config: LiftConfig) -> Tuple[Optional[Path], Optional[Path], str]:
    candidates = [
        config.layout.build_dir / "runnable-lift",
        config.layout.build_dir / "tools" / "runnable-lift" / "runnable-lift",
        config.repo_root / "build-codex-dynamic-current" / "tools" / "runnable-lift" / "runnable-lift",
    ]
    binary = next((candidate for candidate in candidates if candidate.exists()), None)
    if binary is None:
        return None, None, "missing build tree runnable-lift"
    if binary.is_relative_to(config.repo_root / "build-codex-dynamic-current"):
        return binary, config.repo_root / "build-codex-dynamic-current", "repo build tree runnable-lift present"
    return binary, config.layout.build_dir, "run build tree runnable-lift present"


def compile_current_runnable(config: LiftConfig) -> Tuple[Path, Path]:
    install_dir = config.layout.install_dir
    build_dir = config.layout.build_dir
    shared_install_dir = config.layout.shared_install_dir
    ensure_dir(build_dir)
    ensure_dir(shared_install_dir)
    build_log = config.layout.logs_dir / "build-runnable.log"
    install_root = "/hdd-work/runs/{}/install-runnable".format(config.run_label)
    build_root = "/hdd-work/runs/{}/build-runnable".format(config.run_label)
    shared_install_root = map_host_path_to_container(config, shared_install_dir)
    container_build_log = map_host_path_to_container(config, build_log)
    host_uid = os.getuid()
    host_gid = os.getgid()
    shell_script = f"""
set -euo pipefail
cd /workspace/Runnable-Rewriting
mkdir -p {shlex.quote(build_root)} {shlex.quote(install_root)} {shlex.quote(str(shared_install_root))}
{{
  cd {shlex.quote(build_root)}
  LLVM_DIR="${{RUNNABLE_LLVM_DIR:-}}"
  if [[ -z "$LLVM_DIR" ]] && command -v llvm-config >/dev/null 2>&1; then
    LLVM_DIR="$(llvm-config --cmakedir)"
  fi
  if [[ -z "$LLVM_DIR" || ! -f "$LLVM_DIR/LLVMConfig.cmake" ]]; then
    for candidate in \
      /usr/lib/llvm-18/lib/cmake/llvm \
      /usr/lib/llvm-18/cmake \
      /usr/lib/cmake/llvm \
      /usr/share/llvm/cmake \
      /usr/local/lib/cmake/llvm \
      /usr/local/share/llvm/cmake; do
      if [[ -f "$candidate/LLVMConfig.cmake" ]]; then
        LLVM_DIR="$candidate"
        break
      fi
    done
  fi
  if [[ -z "$LLVM_DIR" || ! -f "$LLVM_DIR/LLVMConfig.cmake" ]]; then
    for candidate in \
      {LEGACY_RUNNABLE_ROOT}/lib/cmake/llvm \
      {LEGACY_RUNNABLE_ROOT}/share/llvm/cmake; do
      if [[ -f "$candidate/LLVMConfig.cmake" ]]; then
        LLVM_DIR="$candidate"
        break
      fi
    done
  fi
  if [[ -z "$LLVM_DIR" || ! -f "$LLVM_DIR/LLVMConfig.cmake" ]]; then
    echo "LLVMConfig.cmake not found; set RUNNABLE_LLVM_DIR to the LLVM CMake package directory" >&2
    exit 1
  fi
  QEMU_INSTALL_PATH="${{RUNNABLE_QEMU_INSTALL_PATH:-/usr}}"
  if [[ ! -d "$QEMU_INSTALL_PATH/include" && -d {LEGACY_RUNNABLE_ROOT}/include ]]; then
    QEMU_INSTALL_PATH={LEGACY_RUNNABLE_ROOT}
  fi
  BOOST_ROOT_ARGS=()
  if [[ -n "${{RUNNABLE_BOOST_ROOT:-}}" ]]; then
    BOOST_ROOT_ARGS=(-DBOOST_ROOT="$RUNNABLE_BOOST_ROOT" -DBoost_NO_SYSTEM_PATHS=On)
  elif [[ -d {LEGACY_RUNNABLE_ROOT}/include/boost ]]; then
    BOOST_ROOT_ARGS=(-DBOOST_ROOT={LEGACY_RUNNABLE_ROOT} -DBoost_NO_SYSTEM_PATHS=On)
  fi
  cmake /workspace/Runnable-Rewriting/runnable \\
    -DCMAKE_BUILD_TYPE=Debug \\
    -DCMAKE_INSTALL_PREFIX={shlex.quote(install_root)} \\
    -DQEMU_INSTALL_PATH="$QEMU_INSTALL_PATH" \\
    -DLLVM_DIR="$LLVM_DIR" \\
    -DCMAKE_CXX_LINK_FLAGS='-static-libgcc -static-libstdc++' \\
    -DCMAKE_C_LINK_FLAGS='-static-libgcc' \\
    "${{BOOST_ROOT_ARGS[@]}}"
  cmake --build .
  cmake --install .
  rm -rf {shlex.quote(str(shared_install_root))}
  cp -a {shlex.quote(install_root)} {shlex.quote(str(shared_install_root))}
  chown -R {host_uid}:{host_gid} {shlex.quote(str(shared_install_root))}
}} >{shlex.quote(container_build_log)} 2>&1
"""
    log(f"building current dynamic-parallel runnable-lift inside {config.docker_image}")
    if not config.dry_run:
        result = docker_run_shell(
            config.docker_image,
            shell_script,
            mounts=host_mounts(config),
            workdir="/workspace",
            memory_limit_gb=config.build_memory_gb,
            storage_limit_gb=config.container_storage_limit_gb,
            capture_output=False,
            check=False,
        )
        if result.returncode != 0:
            detail = f"current branch runnable-lift build failed; see {build_log}"
            if build_log.exists():
                log_text = build_log.read_text(encoding="utf-8", errors="ignore")
                if "PTCInterface' has no member named 'queueDepth'" in log_text or "PTCInterface' has no member named 'dropCPUState'" in log_text:
                    detail += (
                        " (configured runtime image exposes an older PTCInterface "
                        "than this dynamic-parallel branch expects)"
                    )
            raise RuntimeError(detail)
    installed = shared_install_dir / "bin" / "runnable-lift"
    if not config.dry_run and installed.exists():
        return installed, shared_install_dir
    build_binary, build_prefix, build_reason = probe_build_tree_runnable_lift(config)
    if not config.dry_run and build_binary is not None and build_prefix is not None:
        log(f"using build tree runnable-lift fallback: {build_reason}")
        return build_binary, build_prefix
    if not config.dry_run:
        raise RuntimeError(f"expected built runnable-lift at {installed}")
    return installed, shared_install_dir


def resolve_runnable_lift(config: LiftConfig) -> Tuple[Path, Path, str]:
    binary, prefix, reason = probe_installed_runnable_lift(config)
    if binary is not None and not config.rebuild_lift:
        return binary, prefix, reason
    build_binary, build_prefix, build_reason = probe_build_tree_runnable_lift(config)
    if build_binary is not None and build_prefix is not None and not config.rebuild_lift:
        return build_binary, build_prefix, build_reason
    if binary is not None and config.rebuild_lift:
        log(f"rebuilding current runnable-lift even though install exists: {reason}")
    elif binary is None:
        log(f"building current runnable-lift because probe failed: {reason}")
    built_binary, built_prefix = compile_current_runnable(config)
    return built_binary, built_prefix, "freshly built current branch binary"


def default_libtinycode_candidate_dirs(config: LiftConfig) -> List[Path]:
    return [
        config.repo_root / "build-codex-dynamic-current" / "tools" / "runnable-lift",
        config.repo_root / "build-codex-dynamic-current",
    ]


def resolve_libtinycode_runtime_assets(config: LiftConfig) -> Optional[Tuple[Path, Path]]:
    if config.libtinycode_override is None or config.libtinycode_helpers_override is None:
        if config.libtinycode_override is not None or config.libtinycode_helpers_override is not None:
            raise RuntimeError(
                "libtinycode override requires both --libtinycode-path and "
                "--libtinycode-helpers-path"
            )
        for candidate_dir in default_libtinycode_candidate_dirs(config):
            libtinycode = candidate_dir / "libtinycode-x86_64.so"
            helpers = candidate_dir / "libtinycode-helpers-x86_64.ll"
            if libtinycode.exists() and helpers.exists():
                return libtinycode, helpers
        if config.dry_run:
            return None
        raise RuntimeError(
            "missing libtinycode runtime assets; pass --libtinycode-path and "
            "--libtinycode-helpers-path, or stage libtinycode-x86_64.so and "
            "libtinycode-helpers-x86_64.ll under build-codex-dynamic-current/"
            "tools/runnable-lift"
        )
    return config.libtinycode_override, config.libtinycode_helpers_override


def runtime_asset_target_dirs(config: LiftConfig, prefix: Path) -> List[Path]:
    if prefix == config.layout.build_dir:
        target_dirs = [prefix]
        tools_dir = prefix / "tools" / "runnable-lift"
        if tools_dir.exists():
            target_dirs.append(tools_dir)
        return target_dirs
    return [prefix / "lib", prefix / "bin"]


def stage_libtinycode_runtime_assets(config: LiftConfig, prefix: Path) -> Optional[Path]:
    assets = resolve_libtinycode_runtime_assets(config)
    if assets is None:
        return None
    libtinycode, helpers = assets
    if not libtinycode.exists():
        raise FileNotFoundError(f"missing libtinycode override: {libtinycode}")
    if not helpers.exists():
        raise FileNotFoundError(f"missing libtinycode helpers override: {helpers}")

    target_dirs = runtime_asset_target_dirs(config, prefix)
    for target_dir in target_dirs:
        ensure_dir(target_dir)
        lib_target = target_dir / "libtinycode-x86_64.so"
        helpers_target = target_dir / "libtinycode-helpers-x86_64.ll"
        if libtinycode.resolve() != lib_target.resolve():
            shutil.copy2(libtinycode, lib_target)
        if helpers.resolve() != helpers_target.resolve():
            shutil.copy2(helpers, helpers_target)
    return target_dirs[0]


def append_unique(items: List[str], value: str) -> None:
    if value and value not in items:
        items.append(value)


def configured_llvm_lib_dirs() -> List[str]:
    parts: List[str] = []
    override = os.environ.get("RUNNABLE_LLVM_LIBDIR", "")
    for value in override.split(os.pathsep):
        append_unique(parts, value)
    for value in SYSTEM_LLVM_LIB_DIRS:
        append_unique(parts, value)
    return parts


def uses_legacy_runnable_root(config: LiftConfig) -> bool:
    return config.docker_image.startswith("rr_bionic_exportfs")


def build_container_runtime(config: LiftConfig, prefix: Path) -> Dict[str, str]:
    prefix_in_container = map_host_path_to_container(config, prefix)
    if prefix == config.layout.build_dir:
        bin_dir = prefix_in_container
        lib_dir = f"{prefix_in_container}/lib/Support"
        share_dir = prefix_in_container
    else:
        bin_dir = f"{prefix_in_container}/bin"
        lib_dir = f"{prefix_in_container}/lib"
        share_dir = f"{prefix_in_container}/share/runnable"
    path_parts = [
        bin_dir,
        "/usr/local/sbin",
        "/usr/local/bin",
        "/usr/sbin",
        "/usr/bin",
        "/sbin",
        "/bin",
    ]
    if uses_legacy_runnable_root(config):
        path_parts.insert(1, f"{LEGACY_RUNNABLE_ROOT}/bin")
    path = ":".join(path_parts)
    ld_library_parts = [lib_dir]
    if prefix == config.layout.build_dir:
        ld_library_parts.extend(
            [
                f"{prefix_in_container}/lib/BasicAnalyses",
                f"{prefix_in_container}/lib/Dump",
                f"{prefix_in_container}/lib/FunctionIsolation",
                f"{prefix_in_container}/lib/StackAnalysis",
                f"{prefix_in_container}/analyses",
            ]
        )
    ld_library_parts.extend(configured_llvm_lib_dirs())
    if uses_legacy_runnable_root(config):
        ld_library_parts.append(f"{LEGACY_RUNNABLE_ROOT}/lib")
    ld_library_path = ":".join(ld_library_parts)
    pythonpath = f"{share_dir}:/workspace/Runnable-Rewriting/runnable/scripts"
    return {
        "prefix_in_container": prefix_in_container,
        "PATH": path,
        "LD_LIBRARY_PATH": ld_library_path,
        "PYTHONPATH": pythonpath,
        "bin_dir": bin_dir,
        "lib_dir": lib_dir,
        "share_dir": share_dir,
    }


def build_host_runtime(config: LiftConfig, prefix: Path) -> Dict[str, str]:
    if prefix == config.layout.build_dir:
        bin_dir = prefix / "tools" / "runnable-lift"
        lib_parts = [
            prefix / "lib" / "Support",
            prefix / "lib" / "BasicAnalyses",
            prefix / "lib" / "Dump",
            prefix / "lib" / "FunctionIsolation",
            prefix / "lib" / "StackAnalysis",
        ]
        share_dir = config.repo_root / "runnable" / "scripts"
    else:
        bin_dir = prefix / "bin"
        lib_parts = [prefix / "lib"]
        share_dir = prefix / "share" / "runnable"
    path = os.pathsep.join([str(bin_dir), os.environ.get("PATH", "")])
    ld_parts = [str(path) for path in lib_parts]
    ld_parts.extend(configured_llvm_lib_dirs())
    if os.environ.get("LD_LIBRARY_PATH"):
        ld_parts.append(os.environ["LD_LIBRARY_PATH"])
    python_parts = [
        str(share_dir),
        str(config.repo_root / "runnable" / "scripts"),
    ]
    if os.environ.get("PYTHONPATH"):
        python_parts.append(os.environ["PYTHONPATH"])
    return {
        "PATH": path,
        "LD_LIBRARY_PATH": os.pathsep.join(ld_parts),
        "PYTHONPATH": os.pathsep.join(python_parts),
        "bin_dir": str(bin_dir),
        "lib_dir": os.pathsep.join(str(path) for path in lib_parts),
        "share_dir": str(share_dir),
    }


def run_dynamic_lift_for_seed(
    *,
    config: LiftConfig,
    runtime: Dict[str, str],
    binary_path: Path,
    seed: SeedFunction,
) -> Dict[str, object]:
    raw_ll = config.layout.raw_dir / f"{seed.tag}.raw.ll"
    merged_ll = config.layout.merged_dir / f"{seed.tag}.ll"
    fragment_dir = config.layout.fragments_dir / seed.tag
    stdout_log = config.layout.logs_dir / f"{seed.tag}.stdout.log"
    stderr_log = config.layout.logs_dir / f"{seed.tag}.stderr.log"
    merge_summary = config.layout.manifests_dir / f"{seed.tag}.merge.json"
    if fragment_dir.exists():
        shutil.rmtree(fragment_dir)
    ensure_dir(fragment_dir)
    for stale_path in (raw_ll, merged_ll, stdout_log, stderr_log, merge_summary):
        if stale_path.exists():
            stale_path.unlink()

    container_binary = map_host_path_to_container(config, binary_path)
    container_raw_ll = map_host_path_to_container(config, raw_ll)
    container_merged_ll = map_host_path_to_container(config, merged_ll)
    container_fragment_dir = map_host_path_to_container(config, fragment_dir)
    container_stdout_log = map_host_path_to_container(config, stdout_log)
    container_stderr_log = map_host_path_to_container(config, stderr_log)
    container_merge_summary = map_host_path_to_container(config, merge_summary)
    flags = [
        "runnable-lift",
        f"-base={hex(config.runnable_base)}",
        f"-entry={hex(config.runnable_base + seed.start)}",
        f"-addr-range-min={hex(config.runnable_base + seed.start)}",
        f"-addr-range-max={hex(config.runnable_base + seed.end_exclusive)}",
        "-dynamic-parallel",
        f"-parallel-workers={config.requested_parallel_workers}",
        f"-parallel-fragment-dir={container_fragment_dir}",
    ]
    flags.extend(config.coordinator_flags)
    flags.extend([container_binary, container_raw_ll])
    env = {
        "PATH": runtime["PATH"],
        "LD_LIBRARY_PATH": runtime["LD_LIBRARY_PATH"],
        "PYTHONPATH": runtime["PYTHONPATH"],
    }
    shell_script = f"""
set -euo pipefail
mkdir -p {shlex.quote(container_fragment_dir)}
cd /workspace/Runnable-Rewriting
{{
  timeout {int(config.lift_timeout_sec)} {shell_join(flags)}
}} >{shlex.quote(container_stdout_log)} 2>{shlex.quote(container_stderr_log)}
"""

    started = time.time()
    if config.dry_run:
        rc = 0
        stdout_log.write_text(shell_script, encoding="utf-8")
        stderr_log.write_text("", encoding="utf-8")
        ensure_dir(merged_ll.parent)
        merged_ll.write_text("; dry-run placeholder\n", encoding="utf-8")
    else:
        result = docker_run_shell(
            config.docker_image,
            shell_script,
            mounts=host_mounts(config),
            workdir="/workspace",
            env=env,
            memory_limit_gb=config.container_memory_limit_gb,
            storage_limit_gb=config.container_storage_limit_gb,
            capture_output=False,
            check=False,
        )
        rc = result.returncode
        if rc == 0:
            worker_inputs = sorted(fragment_dir.glob("worker_*.ll"))
            if worker_inputs:
                run_cmd(
                    [
                        "python3",
                        str(config.repo_root / "runnable" / "scripts" / "merge_dynamic_runnable_fragments.py"),
                        "--output",
                        str(merged_ll),
                        "--entry-pc",
                        hex(config.runnable_base + seed.start),
                        "--summary-out",
                        str(merge_summary),
                        str(raw_ll),
                        *(str(path) for path in worker_inputs),
                    ],
                    cwd=config.repo_root,
                    capture_output=False,
                )
            else:
                run_cmd(["cp", str(raw_ll), str(merged_ll)], capture_output=False)
    elapsed = time.time() - started
    worker_count = len(list(fragment_dir.glob("worker_*.ll")))
    return {
        "tag": seed.tag,
        "name": seed.name,
        "start": seed.start,
        "entry_pc": config.runnable_base + seed.start,
        "size": seed.size,
        "status": "ok" if rc == 0 and (config.dry_run or merged_ll.exists()) else "failed",
        "rc": rc,
        "elapsed_sec": elapsed,
        "workers_spawned": worker_count,
        "raw_ll": str(raw_ll),
        "merged_ll": str(merged_ll),
        "fragment_dir": str(fragment_dir),
        "stdout_log": str(stdout_log),
        "stderr_log": str(stderr_log),
        "merge_summary": str(merge_summary) if merge_summary.exists() else None,
    }


def merge_seed_result(config: LiftConfig, result: Dict[str, object]) -> Dict[str, object]:
    if result["status"] != "ok":
        return result
    raw_ll = map_container_path_to_host(config, str(result["raw_ll"]))
    merged_ll = map_container_path_to_host(config, str(result["merged_ll"]))
    fragment_dir = map_container_path_to_host(config, str(result["fragment_dir"]))
    merge_summary = Path(str(result["merge_summary"])) if result.get("merge_summary") else config.layout.manifests_dir / f"{result['tag']}.merge.json"
    worker_inputs = sorted(fragment_dir.glob("worker_*.ll"))
    ensure_dir(merged_ll.parent)
    if worker_inputs:
        run_cmd(
            [
                "python3",
                str(config.repo_root / "runnable" / "scripts" / "merge_dynamic_runnable_fragments.py"),
                "--output",
                str(merged_ll),
                "--entry-pc",
                hex(int(result["entry_pc"])),
                "--summary-out",
                str(merge_summary),
                str(raw_ll),
                *(str(path) for path in worker_inputs),
            ],
            cwd=config.repo_root,
            capture_output=False,
        )
    else:
        run_cmd(["cp", str(raw_ll), str(merged_ll)], capture_output=False)
    updated = dict(result)
    updated["merge_summary"] = str(merge_summary) if merge_summary.exists() else None
    updated["workers_spawned"] = len(worker_inputs)
    updated["merged_ll"] = str(merged_ll)
    updated["raw_ll"] = str(raw_ll)
    updated["fragment_dir"] = str(fragment_dir)
    updated["stdout_log"] = str(map_container_path_to_host(config, str(result["stdout_log"])))
    updated["stderr_log"] = str(map_container_path_to_host(config, str(result["stderr_log"])))
    return updated


def host_merge_seed_results(config: LiftConfig, seed_results: Sequence[Dict[str, object]]) -> List[Dict[str, object]]:
    merged_results: List[Dict[str, object]] = []
    for result in sorted(seed_results, key=lambda item: item["start"]):
        if result["status"] != "ok":
            merged_results.append(dict(result))
            continue
        merged_results.append(merge_seed_result(config, result))
    return merged_results


def host_merge_shards_from_seed_results(
    config: LiftConfig,
    *,
    shard_summaries: Sequence[Dict[str, object]],
    seed_results: Sequence[Dict[str, object]],
) -> List[Dict[str, object]]:
    by_shard: Dict[str, List[Dict[str, object]]] = {}
    for result in seed_results:
        by_shard.setdefault(str(result["shard_id"]), []).append(result)

    updated_summaries: List[Dict[str, object]] = []
    for shard in sorted(shard_summaries, key=lambda item: int(item["start"])):
        shard_id = str(shard["shard_id"])
        ok_results = [item for item in by_shard.get(shard_id, []) if item["status"] == "ok"]
        merged_ll = config.layout.shard_merged_dir / f"{shard_id}.ll"
        merge_summary = config.layout.shard_logs_dir / f"{shard_id}.merge.json"
        payload = dict(shard)
        if ok_results:
            merged = merge_module_paths(
                config,
                inputs=[Path(str(item["merged_ll"])) for item in sorted(ok_results, key=lambda item: item["start"])],
                entry_pc=int(ok_results[0]["entry_pc"]),
                final_output=merged_ll,
                summary_name=f"{shard_id}.summary.json",
            )
            payload["merged_ll"] = str(merged_ll)
            payload["merge_summary"] = str(merged["summary_out"])
            payload["status"] = "ok" if len(ok_results) == int(shard["seed_count"]) else "partial"
        else:
            payload["status"] = "failed"
            payload["merged_ll"] = str(merged_ll)
            payload["merge_summary"] = None
        updated_summaries.append(payload)
    return updated_summaries


def load_incremental_results(
    path: Path,
    *,
    known_tags: Set[str],
    start_offset: int = 0,
) -> Tuple[List[Dict[str, object]], int]:
    if not path.exists():
        return [], start_offset
    try:
        current_size = path.stat().st_size
    except FileNotFoundError:
        return [], start_offset
    if start_offset > current_size:
        start_offset = 0
    items: List[Dict[str, object]] = []
    seen_tags = set(known_tags)
    with path.open("r", encoding="utf-8") as handle:
        if start_offset:
            handle.seek(start_offset)
        for line in handle:
            line = line.strip()
            if not line:
                continue
            payload = json.loads(line)
            tag = str(payload["tag"])
            if tag in seen_tags:
                continue
            seen_tags.add(tag)
            items.append(payload)
        end_offset = handle.tell()
    return items, end_offset


def track_future_completion(
    future_map: Dict[object, str],
    completed_queue: "queue.SimpleQueue[object]",
    future: object,
    future_id: str,
) -> None:
    future_map[future] = future_id
    future.add_done_callback(completed_queue.put)


def drain_completed_futures(
    future_map: Dict[object, str],
    completed_queue: "queue.SimpleQueue[object]",
) -> List[object]:
    ready: List[object] = []
    seen = set()
    while True:
        try:
            future = completed_queue.get_nowait()
        except queue.Empty:
            break
        if future not in future_map or future in seen:
            continue
        seen.add(future)
        ready.append(future)
    return ready


def normalize_seed_result_paths(
    config: LiftConfig,
    result: Dict[str, object],
) -> Dict[str, object]:
    updated = dict(result)
    for key in ("raw_ll", "merged_ll", "fragment_dir", "stdout_log", "stderr_log"):
        if updated.get(key) is not None:
            updated[key] = str(map_container_path_to_host(config, str(updated[key])))
    if updated.get("merge_summary") is not None:
        updated["merge_summary"] = str(map_container_path_to_host(config, str(updated["merge_summary"])))
    return updated


def seed_merge_summary_path(config: LiftConfig, result: Dict[str, object]) -> Path:
    if result.get("merge_summary"):
        return Path(str(result["merge_summary"]))
    return config.layout.manifests_dir / f"{result['tag']}.merge.json"


def shard_merge_summary_path(config: LiftConfig, shard_id: str) -> Path:
    return config.layout.manifests_dir / f"{shard_id}.summary.json"


def recover_seed_merge_result(
    config: LiftConfig,
    result: Dict[str, object],
) -> Optional[Dict[str, object]]:
    if result["status"] != "ok":
        return None
    normalized = normalize_seed_result_paths(config, result)
    raw_ll = Path(str(normalized["raw_ll"]))
    merged_ll = Path(str(normalized["merged_ll"]))
    fragment_dir = Path(str(normalized["fragment_dir"]))
    merge_summary = seed_merge_summary_path(config, normalized)
    if not raw_ll.exists() or not merged_ll.exists():
        return None
    worker_inputs = sorted(fragment_dir.glob("worker_*.ll"))
    if worker_inputs and not merge_summary.exists():
        return None
    updated = dict(normalized)
    updated["merge_summary"] = str(merge_summary) if merge_summary.exists() else None
    updated["workers_spawned"] = len(worker_inputs)
    return updated


def recover_shard_merge_payload(
    config: LiftConfig,
    *,
    shard_id: str,
    seed_results: Sequence[Dict[str, object]],
    expected_seed_count: int,
    shard_start: int,
) -> Optional[Dict[str, object]]:
    merged_ll = config.layout.shard_merged_dir / f"{shard_id}.ll"
    merge_summary = shard_merge_summary_path(config, shard_id)
    if not merged_ll.exists() or not merge_summary.exists():
        return None
    ok_results = [item for item in seed_results if item["status"] == "ok"]
    if not ok_results:
        return None
    failed_count = len(seed_results) - len(ok_results)
    status = "ok" if len(seed_results) == expected_seed_count and failed_count == 0 else "partial"
    return {
        "shard_id": shard_id,
        "start": shard_start,
        "seed_count": expected_seed_count,
        "ok_seed_count": len(ok_results),
        "failed_seed_count": failed_count,
        "status": status,
        "merged_ll": str(merged_ll),
        "merge_summary": str(merge_summary),
        "log_path": str(config.layout.shard_logs_dir / f"{shard_id}.log"),
    }


def recover_batch_merge_payload(node: MergeBatchNode) -> Optional[Dict[str, object]]:
    if not node.output.exists() or not node.summary_out.exists():
        return None
    return {
        "node_id": node.node_id,
        "level": node.level,
        "index": node.index,
        "children": list(node.children),
        "output": str(node.output),
        "summary_out": str(node.summary_out),
    }


def restore_streaming_merge_state(
    config: LiftConfig,
    *,
    planned_shards: Sequence[LiftShard],
) -> RestoredStreamingMergeState:
    state = initialize_merge_state(planned_shards)
    progress = MergeProgress(
        seed_total=sum(shard.seed_count for shard in planned_shards),
        shard_total=len(planned_shards),
    )
    paths = merge_state_paths(config.layout)
    shard_seed_results: Dict[str, Dict[str, Dict[str, object]]] = {
        shard.shard_id: {} for shard in planned_shards
    }
    shard_summaries: Dict[str, Dict[str, object]] = {}
    available_inputs: Dict[str, Path] = {}
    batch_result_payloads: List[Dict[str, object]] = []
    first_success_entry_pc: Optional[int] = None

    def record_shard_result(result: Dict[str, object]) -> None:
        shard_id = str(result["shard_id"])
        shard_seed_results.setdefault(shard_id, {})[str(result["tag"])] = dict(result)

    for result in load_jsonl(paths["seed_lift_events"]):
        tag = str(result["tag"])
        if tag in state.seed_results:
            continue
        state.seed_results[tag] = dict(result)
        if result["status"] == "ok" and first_success_entry_pc is None:
            first_success_entry_pc = int(result["entry_pc"])
        if result["status"] != "ok":
            record_shard_result(result)

    for result in load_jsonl(paths["seed_merge_events"]):
        tag = str(result["tag"])
        normalized = normalize_seed_result_paths(config, result)
        state.seed_merge_enqueued.add(tag)
        if tag in state.seed_merge_completed:
            continue
        state.seed_merge_completed.add(tag)
        state.seed_results[tag] = normalized
        if first_success_entry_pc is None:
            first_success_entry_pc = int(normalized["entry_pc"])
        record_shard_result(normalized)

    recovered_seed_merges: List[Dict[str, object]] = []
    for result in sorted(state.seed_results.values(), key=lambda item: int(item["start"])):
        tag = str(result["tag"])
        if result["status"] != "ok" or tag in state.seed_merge_completed:
            continue
        recovered = recover_seed_merge_result(config, result)
        if recovered is None:
            continue
        state.seed_merge_enqueued.add(tag)
        state.seed_merge_completed.add(tag)
        state.seed_results[tag] = recovered
        if first_success_entry_pc is None:
            first_success_entry_pc = int(recovered["entry_pc"])
        record_shard_result(recovered)
        recovered_seed_merges.append(recovered)

    for result in recovered_seed_merges:
        append_jsonl(paths["seed_merge_events"], result)

    for payload in load_jsonl(paths["shard_merge_events"]):
        shard_id = str(payload["shard_id"])
        state.shard_merge_enqueued.add(shard_id)
        if shard_id in state.shard_merge_completed:
            continue
        state.shard_merge_completed.add(shard_id)
        shard_summaries[shard_id] = dict(payload)
        if payload.get("status") in {"ok", "partial"} and Path(str(payload["merged_ll"])).exists():
            available_inputs[shard_id] = Path(str(payload["merged_ll"]))

    recovered_shard_merges: List[Dict[str, object]] = []
    for shard in planned_shards:
        shard_id = shard.shard_id
        if shard_id in state.shard_merge_completed:
            continue
        if len(shard_seed_results[shard_id]) < shard.seed_count:
            continue
        recovered = recover_shard_merge_payload(
            config,
            shard_id=shard_id,
            seed_results=sorted(shard_seed_results[shard_id].values(), key=lambda item: int(item["start"])),
            expected_seed_count=shard.seed_count,
            shard_start=shard.start,
        )
        if recovered is None:
            continue
        state.shard_merge_enqueued.add(shard_id)
        state.shard_merge_completed.add(shard_id)
        shard_summaries[shard_id] = recovered
        available_inputs[shard_id] = Path(str(recovered["merged_ll"]))
        recovered_shard_merges.append(recovered)

    for payload in recovered_shard_merges:
        append_jsonl(paths["shard_merge_events"], payload)

    batch_plan, frontier_root_id, _ = plan_merge_batches(config, list(shard_summaries.values()))

    for payload in load_jsonl(paths["batch_merge_events"]):
        node_id = str(payload["node_id"])
        state.batch_merge_enqueued.add(node_id)
        if node_id in state.batch_merge_completed:
            continue
        state.batch_merge_completed.add(node_id)
        batch_result_payloads.append(dict(payload))
        if Path(str(payload["output"])).exists():
            available_inputs[node_id] = Path(str(payload["output"]))

    recovered_batch_merges: List[Dict[str, object]] = []
    for node in batch_plan:
        if node.node_id in state.batch_merge_completed:
            continue
        recovered = recover_batch_merge_payload(node)
        if recovered is None:
            continue
        state.batch_merge_enqueued.add(node.node_id)
        state.batch_merge_completed.add(node.node_id)
        batch_result_payloads.append(recovered)
        available_inputs[node.node_id] = Path(str(recovered["output"]))
        recovered_batch_merges.append(recovered)

    for payload in recovered_batch_merges:
        append_jsonl(paths["batch_merge_events"], payload)

    frontier_root_output = available_inputs.get(frontier_root_id) if frontier_root_id is not None else None
    progress.lift_completed = len(state.seed_results)
    progress.seed_merged = len(state.seed_merge_completed)
    progress.shard_merged = len(state.shard_merge_completed)
    progress.batch_merged = len(state.batch_merge_completed)
    state.completed_results_offset = len(state.seed_results)

    return RestoredStreamingMergeState(
        state=state,
        progress=progress,
        shard_seed_results=shard_seed_results,
        shard_summaries=shard_summaries,
        available_inputs=available_inputs,
        batch_plan=batch_plan,
        batch_result_payloads=sorted(
            batch_result_payloads,
            key=lambda item: (int(item["level"]), int(item["index"])),
        ),
        first_success_entry_pc=first_success_entry_pc,
        frontier_root_id=frontier_root_id,
        frontier_root_output=frontier_root_output,
    )


def summarize_shard_payload(
    config: LiftConfig,
    *,
    shard_id: str,
    seed_results: Sequence[Dict[str, object]],
    expected_seed_count: int,
    shard_start: int,
) -> Dict[str, object]:
    merged_ll = config.layout.shard_merged_dir / f"{shard_id}.ll"
    merge_summary = config.layout.shard_logs_dir / f"{shard_id}.merge.json"
    ok_results = [item for item in seed_results if item["status"] == "ok"]
    failed_count = len(seed_results) - len(ok_results)
    if ok_results:
        merged = merge_module_paths(
            config,
            inputs=[Path(str(item["merged_ll"])) for item in sorted(ok_results, key=lambda item: item["start"])],
            entry_pc=int(ok_results[0]["entry_pc"]),
            final_output=merged_ll,
            summary_name=f"{shard_id}.summary.json",
        )
        status = "ok" if len(seed_results) == expected_seed_count and failed_count == 0 else "partial"
        return {
            "shard_id": shard_id,
            "start": shard_start,
            "seed_count": expected_seed_count,
            "ok_seed_count": len(ok_results),
            "failed_seed_count": failed_count,
            "status": status,
            "merged_ll": str(merged_ll),
            "merge_summary": str(merged["summary_out"]),
            "log_path": str(config.layout.shard_logs_dir / f"{shard_id}.log"),
        }
    return {
        "shard_id": shard_id,
        "start": shard_start,
        "seed_count": expected_seed_count,
        "ok_seed_count": 0,
        "failed_seed_count": failed_count,
        "status": "failed",
        "merged_ll": str(merged_ll),
        "merge_summary": None,
        "log_path": str(config.layout.shard_logs_dir / f"{shard_id}.log"),
    }


def ready_shard_merge_inputs(
    shard_summaries: Sequence[Dict[str, object]],
) -> List[Dict[str, object]]:
    return [
        item
        for item in sorted(shard_summaries, key=lambda value: int(value["start"]))
        if item.get("status") in {"ok", "partial"} and Path(str(item["merged_ll"])).exists()
    ]


def plan_merge_batches(
    config: LiftConfig,
    shard_summaries: Sequence[Dict[str, object]],
) -> Tuple[List[MergeBatchNode], Optional[str], List[Dict[str, object]]]:
    ready = ready_shard_merge_inputs(shard_summaries)
    if not ready:
        return [], None, []
    current_ids = [str(item["shard_id"]) for item in ready]
    current_inputs = {str(item["shard_id"]): Path(str(item["merged_ll"])) for item in ready}
    plan: List[MergeBatchNode] = []
    level = 0
    while len(current_ids) > 1:
        next_ids: List[str] = []
        next_inputs: Dict[str, Path] = {}
        for index in range(0, len(current_ids), config.merge_batch_size):
            children = tuple(current_ids[index:index + config.merge_batch_size])
            if len(children) == 1:
                next_ids.append(children[0])
                next_inputs[children[0]] = current_inputs[children[0]]
                continue
            batch_index = index // config.merge_batch_size
            child_digest = hashlib.sha1(
                "\n".join(children).encode("utf-8")
            ).hexdigest()[:12]
            output = config.layout.merge_batches_dir / (
                f"level{level:02d}-batch{batch_index:04d}-{child_digest}.ll"
            )
            summary_out = config.layout.merge_batches_dir / (
                f"level{level:02d}-batch{batch_index:04d}-{child_digest}.json"
            )
            node = MergeBatchNode(
                level=level,
                index=batch_index,
                children=children,
                output=output,
                summary_out=summary_out,
            )
            plan.append(node)
            next_ids.append(node.node_id)
            next_inputs[node.node_id] = output
        current_ids = next_ids
        current_inputs = next_inputs
        level += 1
    return plan, current_ids[0], ready


def build_merge_batch_plan(
    config: LiftConfig,
    shard_summaries: Sequence[Dict[str, object]],
) -> List[MergeBatchNode]:
    plan, _, _ = plan_merge_batches(config, shard_summaries)
    return plan


def execute_merge_batch_node(
    config: LiftConfig,
    *,
    node: MergeBatchNode,
    available_inputs: Dict[str, Path],
    entry_pc: int,
) -> Dict[str, object]:
    inputs = [available_inputs[child] for child in node.children]
    payload = merge_module_paths(
        config,
        inputs=inputs,
        entry_pc=entry_pc,
        final_output=node.output,
        summary_name=node.summary_out.name,
        summary_out_path=node.summary_out,
    )
    return {
        "node_id": node.node_id,
        "level": node.level,
        "index": node.index,
        "children": list(node.children),
        "output": str(node.output),
        "summary_out": str(payload["summary_out"]),
    }


def persist_merge_frontier(
    layout: LiftLayout,
    payload: Dict[str, object],
    *,
    cache: Optional[Dict[Path, str]] = None,
) -> bool:
    path = merge_state_paths(layout)["frontier"]
    if cache is None:
        write_summary(path, payload)
        return True
    return write_summary_if_changed(path, payload, cache)


def run_streaming_merge_scheduler(
    config: LiftConfig,
    *,
    shard_runner_proc: subprocess.Popen[str],
    shard_results_jsonl: Path,
    planned_shards: Sequence[LiftShard],
) -> Tuple[List[Dict[str, object]], List[Dict[str, object]], Dict[str, object]]:
    paths = merge_state_paths(config.layout)
    for path_key in ("seed_lift_events", "seed_merge_events", "shard_merge_events", "batch_merge_events"):
        path = paths[path_key]
        if not path.exists():
            path.write_text("", encoding="utf-8")

    restored = restore_streaming_merge_state(config, planned_shards=planned_shards)
    state = restored.state
    progress = restored.progress
    shard_seed_results: Dict[str, Dict[str, Dict[str, object]]] = restored.shard_seed_results
    shard_summaries: Dict[str, Dict[str, object]] = restored.shard_summaries
    available_inputs: Dict[str, Path] = restored.available_inputs
    batch_plan: List[MergeBatchNode] = restored.batch_plan
    batch_result_payloads: List[Dict[str, object]] = restored.batch_result_payloads
    seed_merge_futures = {}
    shard_merge_futures = {}
    batch_merge_futures = {}
    seed_merge_completed: "queue.SimpleQueue[object]" = queue.SimpleQueue()
    shard_merge_completed: "queue.SimpleQueue[object]" = queue.SimpleQueue()
    batch_merge_completed: "queue.SimpleQueue[object]" = queue.SimpleQueue()
    first_success_entry_pc: Optional[int] = restored.first_success_entry_pc
    frontier_root_id: Optional[str] = restored.frontier_root_id
    frontier_root_output: Optional[Path] = restored.frontier_root_output
    results_read_offset = 0
    known_result_tags: Set[str] = set(state.seed_results)
    summary_write_cache: Dict[Path, str] = {}

    def update_frontier_state() -> None:
        nonlocal frontier_root_output
        root_output = None
        if frontier_root_id is not None:
            root_output = available_inputs.get(frontier_root_id)
        frontier_root_output = root_output
        persist_merge_frontier(
            config.layout,
            {
                "available_inputs": {key: str(value) for key, value in available_inputs.items()},
                "batch_plan": [
                    {
                        "node_id": node.node_id,
                        "level": node.level,
                        "index": node.index,
                        "children": list(node.children),
                        "output": str(node.output),
                    }
                    for node in batch_plan
                ],
                "root_id": frontier_root_id,
                "root_output": str(root_output) if root_output is not None else None,
            },
            cache=summary_write_cache,
        )

    update_frontier_state()
    write_merge_progress(config.layout, progress, cache=summary_write_cache)
    write_merge_state_summary(config.layout, state, cache=summary_write_cache)

    def submit_seed_merge(executor: ThreadPoolExecutor, result: Dict[str, object]) -> None:
        tag = str(result["tag"])
        if tag in state.seed_merge_enqueued:
            return
        state.seed_merge_enqueued.add(tag)
        progress.queued_seed_merges += 1
        future = executor.submit(merge_seed_result, config, result)
        track_future_completion(seed_merge_futures, seed_merge_completed, future, tag)

    def maybe_submit_shard_merge(executor: ThreadPoolExecutor, shard_id: str) -> None:
        if shard_id in state.shard_merge_enqueued:
            return
        results = list(shard_seed_results[shard_id].values())
        expected = state.shard_expected_counts[shard_id]
        if len(results) < expected:
            return
        state.shard_merge_enqueued.add(shard_id)
        progress.queued_shard_merges += 1
        future = executor.submit(
            summarize_shard_payload,
            config,
            shard_id=shard_id,
            seed_results=list(results),
            expected_seed_count=expected,
            shard_start=state.shard_start_addrs[shard_id],
        )
        track_future_completion(shard_merge_futures, shard_merge_completed, future, shard_id)

    def maybe_submit_batch_merges(executor: ThreadPoolExecutor, entry_pc: int) -> None:
        for node in batch_plan:
            if node.node_id in state.batch_merge_enqueued:
                continue
            if any(child not in available_inputs for child in node.children):
                continue
            state.batch_merge_enqueued.add(node.node_id)
            progress.queued_batch_merges += 1
            future = executor.submit(
                execute_merge_batch_node,
                config,
                node=node,
                available_inputs=dict(available_inputs),
                entry_pc=entry_pc,
            )
            track_future_completion(batch_merge_futures, batch_merge_completed, future, node.node_id)

    with ThreadPoolExecutor(max_workers=config.merge_workers) as merge_executor:
        while True:
            new_results, results_read_offset = load_incremental_results(
                shard_results_jsonl,
                known_tags=known_result_tags,
                start_offset=results_read_offset,
            )
            for result in new_results:
                tag = str(result["tag"])
                normalized = normalize_seed_result_paths(config, result)
                state.seed_results[tag] = normalized
                known_result_tags.add(tag)
                progress.lift_completed += 1
                state.completed_results_offset += 1
                append_jsonl(paths["seed_lift_events"], normalized)
                if normalized["status"] == "ok":
                    if first_success_entry_pc is None:
                        first_success_entry_pc = int(normalized["entry_pc"])
                    submit_seed_merge(merge_executor, normalized)
                else:
                    shard_id = str(normalized["shard_id"])
                    shard_seed_results[shard_id][tag] = dict(normalized)
                    maybe_submit_shard_merge(merge_executor, shard_id)

            done_seed = drain_completed_futures(seed_merge_futures, seed_merge_completed)
            for future in done_seed:
                tag = seed_merge_futures.pop(future)
                progress.queued_seed_merges -= 1
                merged_result = future.result()
                state.seed_merge_completed.add(tag)
                progress.seed_merged += 1
                state.seed_results[tag] = merged_result
                shard_id = str(merged_result["shard_id"])
                shard_seed_results[shard_id][tag] = merged_result
                append_jsonl(paths["seed_merge_events"], merged_result)
                if config.prune_intermediate_files:
                    prune_seed_intermediates(merged_result)
                maybe_submit_shard_merge(merge_executor, shard_id)

            done_shards = drain_completed_futures(shard_merge_futures, shard_merge_completed)
            for future in done_shards:
                shard_id = shard_merge_futures.pop(future)
                progress.queued_shard_merges -= 1
                shard_payload = future.result()
                state.shard_merge_completed.add(shard_id)
                progress.shard_merged += 1
                shard_summaries[shard_id] = shard_payload
                if shard_payload.get("status") in {"ok", "partial"} and Path(str(shard_payload["merged_ll"])).exists():
                    available_inputs[shard_id] = Path(str(shard_payload["merged_ll"]))
                append_jsonl(paths["shard_merge_events"], shard_payload)
                if config.prune_intermediate_files:
                    prune_shard_seed_intermediates(shard_seed_results[shard_id])
                batch_plan, frontier_root_id, _ = plan_merge_batches(config, list(shard_summaries.values()))
                if first_success_entry_pc is not None:
                    maybe_submit_batch_merges(merge_executor, first_success_entry_pc)
                update_frontier_state()

            done_batches = drain_completed_futures(batch_merge_futures, batch_merge_completed)
            for future in done_batches:
                node_id = batch_merge_futures.pop(future)
                progress.queued_batch_merges -= 1
                payload = future.result()
                state.batch_merge_completed.add(node_id)
                progress.batch_merged += 1
                available_inputs[node_id] = Path(payload["output"])
                batch_result_payloads.append(payload)
                append_jsonl(paths["batch_merge_events"], payload)
            if first_success_entry_pc is not None and batch_plan:
                maybe_submit_batch_merges(merge_executor, first_success_entry_pc)
            if done_batches:
                update_frontier_state()

            write_merge_progress(config.layout, progress, cache=summary_write_cache)
            write_merge_state_summary(config.layout, state, cache=summary_write_cache)

            proc_rc = shard_runner_proc.poll()
            if proc_rc is not None and not seed_merge_futures and not shard_merge_futures and not batch_merge_futures:
                if state.completed_results_offset >= progress.seed_total or proc_rc != 0:
                    break
            time.sleep(config.merge_poll_interval_sec)

    rc = shard_runner_proc.wait()
    ordered_seed_results = sorted(state.seed_results.values(), key=lambda item: int(item["start"]))
    ordered_shards = sorted(shard_summaries.values(), key=lambda item: int(item["start"]))
    ordered_batch_results = sorted(batch_result_payloads, key=lambda item: (int(item["level"]), int(item["index"])))
    return ordered_seed_results, ordered_shards, {
        "seed_lift_completed": progress.lift_completed,
        "seed_merge_completed": progress.seed_merged,
        "shard_merge_completed": progress.shard_merged,
        "batch_merge_completed": progress.batch_merged,
        "batch_results": ordered_batch_results,
        "final_frontier_id": frontier_root_id,
        "final_frontier_output": str(frontier_root_output) if frontier_root_output is not None else None,
        "rc": rc,
    }


def run_shard_runner(
    *,
    config: LiftConfig,
    runtime: Dict[str, str],
    container_name: str,
    binary_path: Path,
    shards: Sequence[LiftShard],
) -> Dict[str, object]:
    runner_path = SHARD_RUNNER_SCRIPT
    if not runner_path.exists():
        raise FileNotFoundError(runner_path)
    manifest_path = config.layout.shard_manifests_dir / "shards.json"
    summary_path = config.layout.shard_dir / "shard-runner-summary.json"
    stdout_log = config.layout.shard_logs_dir / "runner.stdout.log"
    stderr_log = config.layout.shard_logs_dir / "runner.stderr.log"
    run_summary_json = config.layout.shard_dir / "shard-results.json"
    run_summary_jsonl = config.layout.shard_dir / "shard-results.jsonl"

    container_runner = map_host_path_to_container(config, runner_path)
    container_binary = map_host_path_to_container(config, binary_path)
    container_manifest = map_host_path_to_container(config, manifest_path)
    container_raw_dir = map_host_path_to_container(config, config.layout.raw_dir)
    container_fragment_root = map_host_path_to_container(config, config.layout.fragments_dir)
    container_merged_dir = map_host_path_to_container(config, config.layout.shard_merged_dir)
    container_logs_dir = map_host_path_to_container(config, config.layout.shard_logs_dir)
    container_summary = map_host_path_to_container(config, summary_path)
    container_results_json = map_host_path_to_container(config, run_summary_json)
    container_results_jsonl = map_host_path_to_container(config, run_summary_jsonl)
    container_stdout = map_host_path_to_container(config, stdout_log)
    container_stderr = map_host_path_to_container(config, stderr_log)

    command = [
        "python3",
        container_runner,
        "--manifest",
        container_manifest,
        "--binary",
        container_binary,
        "--raw-dir",
        container_raw_dir,
        "--fragment-root",
        container_fragment_root,
        "--merged-dir",
        container_merged_dir,
        "--logs-dir",
        container_logs_dir,
        "--results-json",
        container_results_json,
        "--results-jsonl",
        container_results_jsonl,
        "--summary-out",
        container_summary,
        "--runnable-base",
        hex(config.runnable_base),
        "--parallel-workers",
        str(config.requested_parallel_workers),
        "--shard-concurrency",
        str(config.shard_concurrency),
        "--timeout-sec",
        str(config.lift_timeout_sec),
        "--range-mode",
        config.range_mode,
    ]
    if config.preserve_success_seed_logs:
        command.append("--preserve-success-seed-logs")
    for flag in config.coordinator_flags:
        if not str(flag).strip():
            continue
        command.append(f"--coordinator-flag={flag}")

    shell_script = f"""
set -euo pipefail
mkdir -p {shlex.quote(container_logs_dir)} {shlex.quote(container_merged_dir)} {shlex.quote(container_fragment_root)} {shlex.quote(container_raw_dir)}
{{ {' '.join(shlex.quote(part) for part in command)}; }} >{shlex.quote(container_stdout)} 2>{shlex.quote(container_stderr)}
"""
    started = time.time()
    if config.dry_run:
        stdout_log.write_text(shell_script, encoding="utf-8")
        stderr_log.write_text("", encoding="utf-8")
        dummy_results = []
        dummy_shards = []
        for shard in shards:
            for seed in shard.seeds:
                raw_ll = config.layout.raw_dir / f"{seed.tag}.raw.ll"
                merged_ll = config.layout.merged_dir / f"{seed.tag}.ll"
                fragment_dir = config.layout.fragments_dir / seed.tag
                ensure_dir(fragment_dir)
                raw_ll.write_text("; dry-run raw placeholder\n", encoding="utf-8")
                dummy_results.append(
                    {
                        "shard_id": shard.shard_id,
                        "tag": seed.tag,
                        "name": seed.name,
                        "start": seed.start,
                        "entry_pc": config.runnable_base + seed.start,
                        "size": seed.size,
                        "status": "ok",
                        "rc": 0,
                        "elapsed_sec": 0.0,
                        "workers_spawned": 0,
                        "raw_ll": str(raw_ll),
                        "merged_ll": str(merged_ll),
                        "fragment_dir": str(fragment_dir),
                        "stdout_log": str(config.layout.shard_logs_dir / f"{seed.tag}.stdout.log"),
                        "stderr_log": str(config.layout.shard_logs_dir / f"{seed.tag}.stderr.log"),
                        "merge_summary": None,
                    }
                )
            dummy_shard_output = config.layout.shard_merged_dir / f"{shard.shard_id}.ll"
            ensure_dir(dummy_shard_output.parent)
            dummy_shard_output.write_text("; dry-run shard placeholder\n", encoding="utf-8")
            dummy_shards.append(
                {
                    "shard_id": shard.shard_id,
                    "start": shard.start,
                    "end_exclusive": shard.end_exclusive,
                    "seed_count": shard.seed_count,
                    "ok_seed_count": shard.seed_count,
                    "failed_seed_count": 0,
                    "status": "ok",
                    "elapsed_sec": 0.0,
                    "merged_ll": str(dummy_shard_output),
                    "log_path": str(config.layout.shard_logs_dir / f"{shard.shard_id}.log"),
                    "merge_summary": None,
                }
            )
        run_summary_jsonl.write_text(
            "".join(json.dumps(item, sort_keys=True) + "\n" for item in dummy_results),
            encoding="utf-8",
        )
        write_summary(run_summary_json, {"results": dummy_results, "shards": dummy_shards})
        summary_path.write_text(
            json.dumps(
                {
                    "shard_count": len(shards),
                    "seed_count": sum(shard.seed_count for shard in shards),
                    "results_json": str(run_summary_json),
                    "results_jsonl": str(run_summary_jsonl),
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        return {
            "rc": 0,
            "elapsed_sec": time.time() - started,
            "results_json": str(run_summary_json),
            "results_jsonl": str(run_summary_jsonl),
            "summary_path": str(summary_path),
            "stdout_log": str(stdout_log),
            "stderr_log": str(stderr_log),
        }

    result = docker_exec_shell(
        container_name,
        shell_script,
        capture_output=False,
        check=False,
    )
    return {
        "rc": result.returncode,
        "elapsed_sec": time.time() - started,
        "results_json": str(run_summary_json),
        "results_jsonl": str(run_summary_jsonl),
        "summary_path": str(summary_path),
        "stdout_log": str(stdout_log),
        "stderr_log": str(stderr_log),
    }


def run_host_shard_runner(
    *,
    config: LiftConfig,
    runtime: Dict[str, str],
    binary_path: Path,
    shards: Sequence[LiftShard],
) -> Dict[str, object]:
    runner_path = SHARD_RUNNER_SCRIPT
    if not runner_path.exists():
        raise FileNotFoundError(runner_path)
    manifest_path = config.layout.shard_manifests_dir / "shards.json"
    summary_path = config.layout.shard_dir / "shard-runner-summary.json"
    stdout_log = config.layout.shard_logs_dir / "runner.stdout.log"
    stderr_log = config.layout.shard_logs_dir / "runner.stderr.log"
    run_summary_json = config.layout.shard_dir / "shard-results.json"
    run_summary_jsonl = config.layout.shard_dir / "shard-results.jsonl"

    command = [
        "python3",
        str(runner_path),
        "--manifest",
        str(manifest_path),
        "--binary",
        str(binary_path),
        "--raw-dir",
        str(config.layout.raw_dir),
        "--fragment-root",
        str(config.layout.fragments_dir),
        "--merged-dir",
        str(config.layout.shard_merged_dir),
        "--logs-dir",
        str(config.layout.shard_logs_dir),
        "--results-json",
        str(run_summary_json),
        "--results-jsonl",
        str(run_summary_jsonl),
        "--summary-out",
        str(summary_path),
        "--runnable-base",
        hex(config.runnable_base),
        "--parallel-workers",
        str(config.requested_parallel_workers),
        "--shard-concurrency",
        str(config.shard_concurrency),
        "--timeout-sec",
        str(config.lift_timeout_sec),
        "--range-mode",
        config.range_mode,
    ]
    if config.preserve_success_seed_logs:
        command.append("--preserve-success-seed-logs")
    for flag in config.coordinator_flags:
        if not str(flag).strip():
            continue
        command.append(f"--coordinator-flag={flag}")

    ensure_dir(config.layout.shard_logs_dir)
    ensure_dir(config.layout.shard_merged_dir)
    ensure_dir(config.layout.fragments_dir)
    ensure_dir(config.layout.raw_dir)
    env = os.environ.copy()
    env.update(
        {
            "PATH": runtime["PATH"],
            "LD_LIBRARY_PATH": runtime["LD_LIBRARY_PATH"],
            "PYTHONPATH": runtime["PYTHONPATH"],
        }
    )
    started = time.time()
    if config.dry_run:
        stdout_log.write_text(shell_join(command) + "\n", encoding="utf-8")
        stderr_log.write_text("", encoding="utf-8")
        return {
            "rc": 0,
            "elapsed_sec": time.time() - started,
            "results_json": str(run_summary_json),
            "results_jsonl": str(run_summary_jsonl),
            "summary_path": str(summary_path),
            "stdout_log": str(stdout_log),
            "stderr_log": str(stderr_log),
        }
    with stdout_log.open("w", encoding="utf-8") as stdout_handle, stderr_log.open("w", encoding="utf-8") as stderr_handle:
        result = subprocess.run(
            command,
            cwd=str(config.repo_root),
            env=env,
            text=True,
            stdout=stdout_handle,
            stderr=stderr_handle,
        )
    return {
        "rc": result.returncode,
        "elapsed_sec": time.time() - started,
        "results_json": str(run_summary_json),
        "results_jsonl": str(run_summary_jsonl),
        "summary_path": str(summary_path),
        "stdout_log": str(stdout_log),
        "stderr_log": str(stderr_log),
    }


def start_shard_runner_process(
    *,
    config: LiftConfig,
    runtime: Dict[str, str],
    container_name: str,
    binary_path: Path,
    shards: Sequence[LiftShard],
) -> subprocess.Popen[str]:
    runner_path = SHARD_RUNNER_SCRIPT
    if not runner_path.exists():
        raise FileNotFoundError(runner_path)
    manifest_path = config.layout.shard_manifests_dir / "shards.json"
    summary_path = config.layout.shard_dir / "shard-runner-summary.json"
    stdout_log = config.layout.shard_logs_dir / "runner.stdout.log"
    stderr_log = config.layout.shard_logs_dir / "runner.stderr.log"
    run_summary_json = config.layout.shard_dir / "shard-results.json"
    run_summary_jsonl = config.layout.shard_dir / "shard-results.jsonl"

    container_runner = map_host_path_to_container(config, runner_path)
    container_binary = map_host_path_to_container(config, binary_path)
    container_manifest = map_host_path_to_container(config, manifest_path)
    container_raw_dir = map_host_path_to_container(config, config.layout.raw_dir)
    container_fragment_root = map_host_path_to_container(config, config.layout.fragments_dir)
    container_merged_dir = map_host_path_to_container(config, config.layout.shard_merged_dir)
    container_logs_dir = map_host_path_to_container(config, config.layout.shard_logs_dir)
    container_summary = map_host_path_to_container(config, summary_path)
    container_results_json = map_host_path_to_container(config, run_summary_json)
    container_results_jsonl = map_host_path_to_container(config, run_summary_jsonl)
    container_stdout = map_host_path_to_container(config, stdout_log)
    container_stderr = map_host_path_to_container(config, stderr_log)

    command = [
        "python3",
        container_runner,
        "--manifest",
        container_manifest,
        "--binary",
        container_binary,
        "--raw-dir",
        container_raw_dir,
        "--fragment-root",
        container_fragment_root,
        "--merged-dir",
        container_merged_dir,
        "--logs-dir",
        container_logs_dir,
        "--results-json",
        container_results_json,
        "--results-jsonl",
        container_results_jsonl,
        "--summary-out",
        container_summary,
        "--runnable-base",
        hex(config.runnable_base),
        "--parallel-workers",
        str(config.requested_parallel_workers),
        "--shard-concurrency",
        str(config.shard_concurrency),
        "--timeout-sec",
        str(config.lift_timeout_sec),
        "--range-mode",
        config.range_mode,
    ]
    if config.preserve_success_seed_logs:
        command.append("--preserve-success-seed-logs")
    for flag in config.coordinator_flags:
        if not str(flag).strip():
            continue
        command.append(f"--coordinator-flag={flag}")

    shell_script = f"""
set -euo pipefail
mkdir -p {shlex.quote(container_logs_dir)} {shlex.quote(container_merged_dir)} {shlex.quote(container_fragment_root)} {shlex.quote(container_raw_dir)}
{{ {' '.join(shlex.quote(part) for part in command)}; }} >{shlex.quote(container_stdout)} 2>{shlex.quote(container_stderr)}
"""
    cmd = ["docker", "exec", container_name, "bash", "-lc", shell_script]
    if config.dry_run:
        stdout_log.write_text(shell_script, encoding="utf-8")
        stderr_log.write_text("", encoding="utf-8")
        raise RuntimeError("background shard runner is not supported in dry-run mode")
    return subprocess.Popen(
        cmd,
        cwd=str(config.repo_root),
        text=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def load_seed_results(path: Path) -> List[Dict[str, object]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    return list(payload.get("results", []))


def load_results_payload(path: Path) -> Dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def merge_module_paths(
    config: LiftConfig,
    *,
    inputs: Sequence[Path],
    entry_pc: int,
    final_output: Path,
    summary_name: str,
    summary_out_path: Optional[Path] = None,
) -> Dict[str, object]:
    if not inputs:
        raise RuntimeError("no successful lift outputs to merge")
    summary_out = summary_out_path if summary_out_path is not None else config.layout.manifests_dir / summary_name
    batch_dir = config.layout.manifests_dir / "merge-batches"
    ensure_dir(batch_dir)
    batch_size = 128
    entry_pc_hex = hex(entry_pc)
    merge_invocation_id = hashlib.sha1(
        "\n".join(
            [
                str(final_output),
                str(summary_out),
                *(str(path) for path in inputs),
            ]
        ).encode("utf-8")
    ).hexdigest()[:12]
    current_inputs = inputs
    round_index = 0
    while len(current_inputs) > 1:
        next_inputs: List[Path] = []
        for batch_index in range(0, len(current_inputs), batch_size):
            batch = current_inputs[batch_index:batch_index + batch_size]
            batch_output = batch_dir / (
                f"round{round_index:02d}-batch{batch_index // batch_size:04d}-{merge_invocation_id}.ll"
            )
            batch_summary = batch_dir / (
                f"round{round_index:02d}-batch{batch_index // batch_size:04d}-{merge_invocation_id}.json"
            )
            cmd = [
                "python3",
                str(config.repo_root / "runnable" / "scripts" / "merge_dynamic_runnable_fragments.py"),
                "--output",
                str(batch_output),
                "--entry-pc",
                entry_pc_hex,
                "--summary-out",
                str(batch_summary),
            ]
            cmd.extend(str(path) for path in batch)
            if config.dry_run:
                batch_output.write_text("; dry-run batch merge placeholder\n", encoding="utf-8")
            else:
                run_cmd(cmd, cwd=config.repo_root, capture_output=False)
            next_inputs.append(batch_output)
        current_inputs = next_inputs
        round_index += 1

    if config.dry_run:
        final_output.write_text("; dry-run final merge placeholder\n", encoding="utf-8")
    else:
        run_cmd(["cp", str(current_inputs[0]), str(final_output)], capture_output=False)
    payload = {
        "final_ll": str(final_output),
        "summary_out": str(summary_out),
        "inputs": [str(path) for path in inputs],
        "merge_rounds": round_index,
    }
    write_summary(summary_out, payload)
    return payload


def promote_existing_merge_output(
    config: LiftConfig,
    *,
    source_output: Path,
    final_output: Path,
    summary_name: str,
    source_kind: str,
) -> Dict[str, object]:
    summary_out = config.layout.manifests_dir / summary_name
    ensure_dir(final_output.parent)
    if config.dry_run:
        final_output.write_text("; dry-run final merge placeholder\n", encoding="utf-8")
    else:
        run_cmd(["cp", str(source_output), str(final_output)], capture_output=False)
    payload = {
        "final_ll": str(final_output),
        "frontier_output": str(source_output),
        "inputs": [str(source_output)],
        "merge_rounds": 0,
        "source_kind": source_kind,
        "summary_out": str(summary_out),
    }
    write_summary(summary_out, payload)
    return payload


def merge_seed_modules(config: LiftConfig, seed_results: Sequence[Dict[str, object]], final_output: Path) -> Dict[str, object]:
    ok_items = [item for item in seed_results if item["status"] == "ok"]
    if not ok_items:
        raise RuntimeError("no successful seed lifts to merge")
    payload = merge_module_paths(
        config,
        inputs=[Path(item["merged_ll"]) for item in sorted(ok_items, key=lambda item: item["start"])],
        entry_pc=int(ok_items[0]["entry_pc"]),
        final_output=final_output,
        summary_name="final-merge.summary.json",
    )
    payload["successful_seed_count"] = len(ok_items)
    return payload


def merge_shard_modules(
    config: LiftConfig,
    *,
    shard_summaries: Sequence[Dict[str, object]],
    seed_results: Sequence[Dict[str, object]],
    final_output: Path,
) -> Dict[str, object]:
    successful_shards = [
        item for item in shard_summaries
        if item.get("status") in {"ok", "partial"} and Path(str(item["merged_ll"])).exists()
    ]
    if not successful_shards:
        raise RuntimeError("no successful shard lifts to merge")
    successful_seeds = [item for item in seed_results if item["status"] == "ok"]
    if not successful_seeds:
        raise RuntimeError("no successful seed lifts available for shard merge entry point")
    payload = merge_module_paths(
        config,
        inputs=[Path(str(item["merged_ll"])) for item in sorted(successful_shards, key=lambda item: int(item["start"]))],
        entry_pc=int(successful_seeds[0]["entry_pc"]),
        final_output=final_output,
        summary_name="final-shard-merge.summary.json",
    )
    payload["successful_shard_count"] = len(successful_shards)
    payload["successful_seed_count"] = len(successful_seeds)
    return payload


def run_canonical_cmp(
    *,
    config: LiftConfig,
    binary: Path,
    groundtruth_pb: Path,
    ll_path: Path,
    cmp_tool: Path,
    blocks_pb2: Path,
) -> Dict[str, object]:
    out_dir = config.layout.eval_dir
    ensure_dir(out_dir)
    cmd = [
        "python3",
        str(config.repo_root / "runnable" / "scripts" / "validate_libcrypto_ground_truth.py"),
        "cmp",
        "--binary",
        str(binary),
        "--groundtruth",
        str(groundtruth_pb),
        "--blocks-pb2",
        str(blocks_pb2),
        "--ll",
        str(ll_path),
        "--run-cmp-eval",
        str(cmp_tool),
        "--text-start",
        hex(detect_text_start(binary)),
        "--runnable-base",
        hex(config.runnable_base),
        "--out-dir",
        str(out_dir),
        "--allow-low-metrics",
    ]
    for profile in config.static_fallback_profiles:
        cmd.extend(["--static-fallback-profile", profile])
    for regex in config.static_fallback_symbol_regexes:
        cmd.extend(["--static-fallback-symbol-regex", regex])
    if config.dry_run:
        return {"cmd": cmd, "status": "dry-run"}
    result = run_cmd(cmd, cwd=config.repo_root, capture_output=True, check=False)
    (out_dir / "cmp.stdout.log").write_text(result.stdout, encoding="utf-8")
    (out_dir / "cmp.stderr.log").write_text(result.stderr, encoding="utf-8")
    verdict = out_dir / "cmp.verdict.txt"
    cmp_json = out_dir / "cmp.json"
    cmp_txt = out_dir / "cmp.txt"
    verdict_ok = None
    precision = None
    recall = None
    if verdict.exists():
        for line in verdict.read_text(encoding="utf-8", errors="ignore").splitlines():
            if not line.startswith("ok:"):
                continue
            verdict_ok = line.split(":", 1)[1].strip().lower() == "true"
            break
    if cmp_json.exists():
        try:
            cmp_payload = json.loads(cmp_json.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            cmp_payload = {}
        raw_precision = cmp_payload.get("precision")
        raw_recall = cmp_payload.get("recall")
        precision = float(raw_precision) if raw_precision is not None else None
        recall = float(raw_recall) if raw_recall is not None else None
    payload = {
        "cmd": cmd,
        "rc": result.returncode,
        "verdict": str(verdict) if verdict.exists() else None,
        "cmp_json": str(cmp_json),
        "cmp_txt": str(cmp_txt),
        "ok": verdict_ok,
        "precision": precision,
        "recall": recall,
    }
    return payload


def prune_seed_intermediates(result: Dict[str, object]) -> None:
    """Delete worker fragment dir and raw .ll after seed merge is confirmed in the event log."""
    fragment_dir_str = result.get("fragment_dir")
    raw_ll_str = result.get("raw_ll")
    if fragment_dir_str:
        fragment_dir = Path(str(fragment_dir_str))
        if fragment_dir.is_dir():
            shutil.rmtree(fragment_dir, ignore_errors=True)
    if raw_ll_str:
        raw_ll = Path(str(raw_ll_str))
        if raw_ll.is_file():
            raw_ll.unlink(missing_ok=True)


def prune_shard_seed_intermediates(shard_seed_results: Dict[str, Dict[str, object]]) -> None:
    """Delete per-seed merged .ll files after the shard merge is confirmed in the event log."""
    for seed_result in shard_seed_results.values():
        if seed_result.get("status") != "ok":
            continue
        merged_ll_str = seed_result.get("merged_ll")
        if merged_ll_str:
            merged_ll = Path(str(merged_ll_str))
            if merged_ll.is_file():
                merged_ll.unlink(missing_ok=True)


def prune_batch_child_intermediates(
    payload: Dict[str, object],
    available_inputs: Dict[str, Path],
) -> None:
    """Delete child input files consumed by a completed batch merge node."""
    for child_id in payload.get("children", []):
        child_path = available_inputs.get(str(child_id))
        if child_path is not None and child_path.is_file():
            child_path.unlink(missing_ok=True)


def write_summary(path: Path, payload: Dict[str, object]) -> None:
    path.write_text(render_summary(payload), encoding="utf-8")


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    config = load_config(args)
    materialize_layout(config.layout)
    mark_run_state(config.layout, "running")
    run_started = time.time()
    resolve_lift_started = None
    resolve_lift_finished = None
    parallel_lift_started = None
    parallel_lift_finished = None
    cmp_started = None
    cmp_finished = None
    disk_monitor: Optional[DiskBudgetMonitor] = None

    try:
        artifact_paths = groundtruth_artifact_paths(config)
        ensure_groundtruth(config, artifact_paths)

        binary_path = artifact_paths["binary"]
        groundtruth_pb = artifact_paths["protobuf"]
        if not binary_path.exists() or not groundtruth_pb.exists():
            raise FileNotFoundError("canonical libcrypto artifacts are missing")

        seeds = readelf_function_seeds(binary_path, config.min_function_size)
        all_seed_count = len(seeds)
        if config.dynsym_only:
            seeds = [s for s in seeds if s.binding == "dynsym"]
            log(
                f"worklist seeds: {len(seeds)} exported (.dynsym) entry points "
                f"(filtered from {all_seed_count} total symbols); "
                "each seed explores all reachable code without address-range constraints"
            )
        if config.seed_start is not None:
            seeds = [seed for seed in seeds if seed.start == config.seed_start]
        if config.max_seeds > 0:
            seeds = seeds[: config.max_seeds]
        if not seeds:
            raise RuntimeError("no function seeds discovered from libcrypto symbol tables")

        write_seed_manifest(config.layout.manifests_dir / "seed-functions.json", seeds)
        write_seed_csv(config.layout.manifests_dir / "seed-functions.csv", seeds)

        coordinator_flags = list(config.coordinator_flags)
        if config.dynsym_only:
            from libcrypto_bench_paths import detect_text_bounds
            text_start, text_end = detect_text_bounds(binary_path)
            abs_text_start = config.runnable_base + text_start
            abs_text_end = config.runnable_base + text_end
            coordinator_flags += [
                f"-addr-range-min={hex(abs_text_start)}",
                f"-addr-range-max={hex(abs_text_end)}",
            ]
            log(
                f"worklist addr range: .text [{hex(abs_text_start)}, {hex(abs_text_end)}) "
                f"({(text_end - text_start) // 1024}KB) — "
                "cross-function exploration bounded by text section"
            )
            config = dataclasses.replace(config, coordinator_flags=tuple(coordinator_flags))

        resolve_lift_started = time.time()
        runnable_lift, install_prefix, lift_reason = resolve_runnable_lift(config)
        resolve_lift_finished = time.time()
        staged_dir = stage_libtinycode_runtime_assets(config, install_prefix)
        if config.execution_model == "host-shards":
            runtime = build_host_runtime(config, install_prefix)
        else:
            runtime = build_container_runtime(config, install_prefix)
        log(f"using runnable-lift at {runnable_lift} ({lift_reason})")
        if staged_dir is not None:
            log(f"staged libtinycode override into {staged_dir}")
        log(
            "memory plan: "
            f"container_limit_gb={config.container_memory_limit_gb} "
            f"parallel_workers={config.requested_parallel_workers} "
            f"shard_concurrency={config.shard_concurrency} "
            f"container_cpus={config.container_cpus}"
        )
        log(
            "disk guard: "
            f"hdd_min_free_gb={config.hdd_min_free_gb} "
            f"run_disk_limit_gb={config.run_disk_limit_gb} "
            f"container_storage_limit_gb={config.container_storage_limit_gb}"
        )
        disk_monitor = start_disk_budget_monitor(config, container_name=None)
        raise_if_disk_budget_exceeded(disk_monitor)

        seed_results: List[Dict[str, object]]
        shard_summaries: List[Dict[str, object]] = []
        shard_payload: Dict[str, object] = {"status": "unused"}
        planned_shards: Optional[List[LiftShard]] = None
        runner_shards: Optional[List[LiftShard]] = None
        parallel_lift_started = time.time()
        if config.execution_model == "legacy-seed-docker":
            seed_results = []
            with ThreadPoolExecutor(max_workers=config.max_concurrent_coordinators) as executor:
                futures = {
                    executor.submit(
                        run_dynamic_lift_for_seed,
                        config=config,
                        runtime=runtime,
                        binary_path=binary_path,
                        seed=seed,
                    ): seed
                    for seed in seeds
                }
                for future in as_completed(futures):
                    seed = futures[future]
                    result = future.result()
                    seed_results.append(result)
                    log(
                        f"{seed.tag} status={result['status']} rc={result['rc']} "
                        f"workers_spawned={result['workers_spawned']} elapsed_sec={result['elapsed_sec']:.1f}"
                    )
        elif config.execution_model == "host-shards":
            planned_shards = plan_shards(config, seeds)
            runner_shards = planned_shards
            write_shard_manifests(config.layout, runner_shards)
            log(
                f"planned {len(planned_shards)} host shards from {len(seeds)} seeds "
                f"(byte_budget={config.shard_byte_budget}, shard_max_seeds={config.shard_max_seeds})"
            )
            shard_payload = run_host_shard_runner(
                config=config,
                runtime=runtime,
                binary_path=binary_path,
                shards=runner_shards,
            )
            if int(shard_payload["rc"]) != 0:
                raise RuntimeError(
                    f"host shard runner failed rc={shard_payload['rc']} "
                    f"see {shard_payload['stdout_log']} and {shard_payload['stderr_log']}"
                )
            results_payload = load_results_payload(Path(shard_payload["results_json"]))
            seed_results = host_merge_seed_results(config, list(results_payload.get("results", [])))
            shard_summaries = host_merge_shards_from_seed_results(
                config,
                shard_summaries=list(results_payload.get("shards", [])),
                seed_results=seed_results,
            )
            for result in seed_results:
                log(
                    f"{result['tag']} shard={result.get('shard_id')} status={result['status']} "
                    f"rc={result['rc']} workers_spawned={result['workers_spawned']} "
                    f"elapsed_sec={float(result['elapsed_sec']):.1f}"
                )
        else:
            planned_shards = plan_shards(config, seeds)
            runner_shards = planned_shards
            if config.streaming_merge and not config.dry_run:
                completed_tags = load_completed_seed_tags(config.layout)
                if completed_tags:
                    runner_shards = filter_pending_shards(planned_shards, completed_tags)
                    log(
                        "resume detected: "
                        f"reusing {len(completed_tags)} completed seeds, "
                        f"scheduling {sum(shard.seed_count for shard in runner_shards)} pending seeds "
                        f"across {len(runner_shards)} shards"
                    )
            write_shard_manifests(config.layout, runner_shards)
            log(
                f"planned {len(planned_shards)} shards from {len(seeds)} seeds "
                f"(byte_budget={config.shard_byte_budget}, shard_max_seeds={config.shard_max_seeds})"
            )
            container_name = start_long_lived_container(config, runtime)
            write_summary(
                config.layout.current_run / "container.json",
                {
                    "container_name": container_name,
                    "execution_model": config.execution_model,
                    "memory_limit_gb": config.container_memory_limit_gb,
                    "container_cpus": config.container_cpus,
                    "container_storage_limit_gb": config.container_storage_limit_gb,
                    "range_mode": config.range_mode,
                    "streaming_merge": config.streaming_merge,
                    "merge_workers": config.merge_workers,
                    "merge_batch_size": config.merge_batch_size,
                },
            )
            if disk_monitor is not None:
                disk_monitor.close()
            disk_monitor = start_disk_budget_monitor(config, container_name=container_name)
            raise_if_disk_budget_exceeded(disk_monitor)
            try:
                if config.dry_run or not config.streaming_merge:
                    shard_payload = run_shard_runner(
                        config=config,
                        runtime=runtime,
                        container_name=container_name,
                        binary_path=binary_path,
                        shards=runner_shards,
                    )
                    results_payload = load_results_payload(Path(shard_payload["results_json"]))
                    seed_results = host_merge_seed_results(config, list(results_payload.get("results", [])))
                    shard_summaries = host_merge_shards_from_seed_results(
                        config,
                        shard_summaries=list(results_payload.get("shards", [])),
                        seed_results=seed_results,
                    )
                else:
                    shard_runner_proc = start_shard_runner_process(
                        config=config,
                        runtime=runtime,
                        container_name=container_name,
                        binary_path=binary_path,
                        shards=runner_shards,
                    )
                    seed_results, shard_summaries, merge_progress_payload = run_streaming_merge_scheduler(
                        config,
                        shard_runner_proc=shard_runner_proc,
                        shard_results_jsonl=config.layout.shard_dir / "shard-results.jsonl",
                        planned_shards=planned_shards,
                    )
                    shard_payload = {
                        "rc": int(merge_progress_payload["rc"]),
                        "elapsed_sec": None,
                        "results_json": str(config.layout.shard_dir / "shard-results.json"),
                        "results_jsonl": str(config.layout.shard_dir / "shard-results.jsonl"),
                        "summary_path": str(config.layout.shard_dir / "shard-runner-summary.json"),
                        "stdout_log": str(config.layout.shard_logs_dir / "runner.stdout.log"),
                        "stderr_log": str(config.layout.shard_logs_dir / "runner.stderr.log"),
                        "merge_progress": merge_progress_payload,
                    }
                if disk_monitor is not None:
                    raise_if_disk_budget_exceeded(disk_monitor)
            finally:
                if disk_monitor is not None:
                    disk_monitor.close()
                docker_rm_force(container_name)
                if disk_monitor is not None:
                    raise_if_disk_budget_exceeded(disk_monitor)
            if int(shard_payload["rc"]) != 0:
                raise RuntimeError(
                    f"shard runner failed rc={shard_payload['rc']} "
                    f"see {shard_payload['stdout_log']} and {shard_payload['stderr_log']}"
                )
            for result in seed_results:
                log(
                    f"{result['tag']} shard={result.get('shard_id')} status={result['status']} "
                    f"rc={result['rc']} workers_spawned={result['workers_spawned']} "
                    f"elapsed_sec={float(result['elapsed_sec']):.1f}"
                )

        seed_results.sort(key=lambda item: item["start"])
        write_summary(config.layout.manifests_dir / "seed-results.json", {"results": seed_results})

        final_ll = config.layout.current_run / "libcrypto.dynamic.parallel.ll"
        if config.execution_model == "legacy-seed-docker":
            merge_payload = merge_seed_modules(config, seed_results, final_ll)
        else:
            write_summary(config.layout.manifests_dir / "shard-results.json", {"shards": shard_summaries})
            successful_shards = ready_shard_merge_inputs(shard_summaries)
            successful_seed_count = sum(1 for item in seed_results if item["status"] == "ok")
            if config.streaming_merge and not config.dry_run:
                frontier_output = None
                if isinstance(shard_payload.get("merge_progress"), dict):
                    raw_frontier = shard_payload["merge_progress"].get("final_frontier_output")
                    if raw_frontier:
                        frontier_output = Path(str(raw_frontier))
                if frontier_output is not None and frontier_output.exists():
                    merge_payload = promote_existing_merge_output(
                        config,
                        source_output=frontier_output,
                        final_output=final_ll,
                        summary_name="final-shard-merge.summary.json",
                        source_kind="incremental-frontier",
                    )
                else:
                    merge_payload = merge_shard_modules(
                        config,
                        shard_summaries=shard_summaries,
                        seed_results=seed_results,
                        final_output=final_ll,
                    )
            else:
                merge_payload = merge_shard_modules(
                    config,
                    shard_summaries=shard_summaries,
                    seed_results=seed_results,
                    final_output=final_ll,
                )
            merge_payload["successful_shard_count"] = len(successful_shards)
            merge_payload["successful_seed_count"] = successful_seed_count
        write_summary(config.layout.manifests_dir / "final-merge.json", merge_payload)
        parallel_lift_finished = time.time()

        cmp_payload: Dict[str, object] = {"status": "skipped"}
        if not config.skip_cmp:
            cmp_started = time.time()
            cmp_payload = run_canonical_cmp(
                config=config,
                binary=binary_path,
                groundtruth_pb=groundtruth_pb,
                ll_path=final_ll,
                cmp_tool=artifact_paths["cmp_tool"],
                blocks_pb2=artifact_paths["blocks_pb2"],
            )
            write_summary(config.layout.manifests_dir / "canonical-cmp.json", cmp_payload)
            cmp_finished = time.time()

        final_ll_exists = final_ll.exists()
        cmp_ok = cmp_payload.get("ok") if isinstance(cmp_payload, dict) else None
        ll_usable = bool(final_ll_exists and cmp_ok is True)
        if not final_ll_exists:
            ll_usable_reason = "final_ll_missing"
        elif config.skip_cmp:
            ll_usable_reason = "cmp_skipped"
        elif cmp_ok is True:
            ll_usable_reason = None
        elif cmp_ok is False:
            ll_usable_reason = "cmp_verdict_failed"
        else:
            ll_usable_reason = "cmp_verdict_missing"
        phase_timings = {
            "resolve_runnable_lift_wall_time_sec": (
                resolve_lift_finished - resolve_lift_started
                if resolve_lift_started is not None and resolve_lift_finished is not None
                else None
            ),
            "parallel_lift_wall_time_sec": (
                parallel_lift_finished - parallel_lift_started
                if parallel_lift_started is not None and parallel_lift_finished is not None
                else None
            ),
            "cmp_wall_time_sec": (
                cmp_finished - cmp_started
                if cmp_started is not None and cmp_finished is not None
                else None
            ),
            "end_to_end_wall_time_sec": time.time() - run_started,
        }

        final_summary = {
            "run_label": config.run_label,
            "run_root": str(config.layout.current_run),
            "binary": str(binary_path),
            "groundtruth_pb": str(groundtruth_pb),
            "final_ll": str(final_ll),
            "final_ll_exists": final_ll_exists,
            "ll_usable": ll_usable,
            "ll_usable_reason": ll_usable_reason,
            "cmp_ok": cmp_ok,
            "parallel_lift_wall_time_sec": phase_timings["parallel_lift_wall_time_sec"],
            "end_to_end_wall_time_sec": phase_timings["end_to_end_wall_time_sec"],
            "phase_timings": phase_timings,
            "seed_count": len(seeds),
            "shard_count": len(planned_shards) if planned_shards is not None else None,
            "successful_seed_count": sum(1 for item in seed_results if item["status"] == "ok"),
            "parallel_workers": config.requested_parallel_workers,
            "max_concurrent_coordinators": config.max_concurrent_coordinators,
            "shard_concurrency": config.shard_concurrency,
            "container_memory_limit_gb": config.container_memory_limit_gb,
            "container_cpus": config.container_cpus,
            "container_storage_limit_gb": config.container_storage_limit_gb,
            "run_disk_limit_gb": config.run_disk_limit_gb,
            "hdd_min_free_gb": config.hdd_min_free_gb,
            "execution_model": config.execution_model,
            "range_mode": config.range_mode,
            "streaming_merge": config.streaming_merge,
            "disk_budget": disk_monitor.latest_snapshot if disk_monitor is not None else None,
            "shard_runner": shard_payload,
            "merge_progress": json.loads(merge_state_paths(config.layout)["progress"].read_text(encoding="utf-8"))
            if merge_state_paths(config.layout)["progress"].exists()
            else None,
            "cmp": cmp_payload,
        }
        write_summary(config.layout.current_run / "run-summary.json", final_summary)
        mark_run_state(config.layout, "ok")
        write_exit_code(config.layout, 0)
        print(json.dumps(final_summary, indent=2, sort_keys=True))
        return 0
    except Exception as exc:
        if disk_monitor is not None:
            disk_monitor.close()
        write_exit_code(config.layout, 1)
        mark_run_state(config.layout, "failed", f"error={type(exc).__name__}")
        raise


if __name__ == "__main__":
    raise SystemExit(main())
