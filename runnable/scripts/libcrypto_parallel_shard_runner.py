#!/usr/bin/env python3

import argparse
import json
import os
import shlex
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Dict, List, Optional, Sequence


def run_cmd(
    cmd: Sequence[str],
    *,
    check: bool = True,
    capture_output: bool = True,
):
    stdout = subprocess.PIPE if capture_output else None
    stderr = subprocess.PIPE if capture_output else None
    return subprocess.run(
        list(cmd),
        check=check,
        universal_newlines=True,
        stdout=stdout,
        stderr=stderr,
    )


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def shell_join(parts: Sequence[str]) -> str:
    return " ".join(shlex.quote(part) for part in parts)


def has_addr_range_flags(flags: Sequence[str]) -> bool:
    return any(flag.startswith("-addr-range-min") for flag in flags) or any(
        flag.startswith("-addr-range-max") for flag in flags
    )


def seed_addr_range_flags(args: argparse.Namespace, start: int, end_exclusive: int) -> List[str]:
    if has_addr_range_flags(args.coordinator_flag):
        return []
    return [
        f"-addr-range-min={hex(args.runnable_base + start)}",
        f"-addr-range-max={hex(args.runnable_base + end_exclusive)}",
    ]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run libcrypto dynamic lift shards inside one container.")
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--raw-dir", required=True, type=Path)
    parser.add_argument("--fragment-root", required=True, type=Path)
    parser.add_argument("--merged-dir", required=True, type=Path)
    parser.add_argument("--logs-dir", required=True, type=Path)
    parser.add_argument("--results-json", required=True, type=Path)
    parser.add_argument("--results-jsonl", required=True, type=Path)
    parser.add_argument("--summary-out", required=True, type=Path)
    parser.add_argument("--runnable-base", required=True, type=lambda value: int(value, 0))
    parser.add_argument("--parallel-workers", required=True, type=int)
    parser.add_argument("--shard-concurrency", required=True, type=int)
    parser.add_argument("--timeout-sec", required=True, type=int)
    parser.add_argument("--preserve-success-seed-logs", action="store_true")
    parser.add_argument("--coordinator-flag", action="append", default=[])
    return parser.parse_args()


def load_shards(path: Path) -> List[Dict[str, object]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    return list(payload.get("shards", []))


def write_json(path: Path, payload: Dict[str, object]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def append_jsonl(path: Path, payload: Dict[str, object], *, lock: threading.Lock) -> None:
    line = json.dumps(payload, sort_keys=True)
    with lock:
        with path.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")


def run_seed(
    *,
    args: argparse.Namespace,
    shard_id: str,
    seed: Dict[str, object],
) -> Dict[str, object]:
    start = int(str(seed["start_hex"]), 0)
    end_exclusive = int(str(seed["end_exclusive_hex"]), 0)
    tag = f"fn_{start:016x}"
    raw_ll = args.raw_dir / f"{tag}.raw.ll"
    merged_ll = args.merged_dir / f"{tag}.ll"
    fragment_dir = args.fragment_root / tag
    stdout_log = args.logs_dir / f"{tag}.stdout.log"
    stderr_log = args.logs_dir / f"{tag}.stderr.log"
    merge_summary = args.logs_dir / f"{tag}.merge.json"

    ensure_dir(args.raw_dir)
    ensure_dir(args.merged_dir)
    ensure_dir(args.logs_dir)
    if fragment_dir.exists():
        run_cmd(["rm", "-rf", str(fragment_dir)], capture_output=False)
    ensure_dir(fragment_dir)
    os.chmod(fragment_dir, 0o777)
    for stale_path in (raw_ll, merged_ll, stdout_log, stderr_log, merge_summary):
        try:
            stale_path.unlink()
        except FileNotFoundError:
            pass

    flags = [
        "runnable-lift",
        f"-base={hex(args.runnable_base)}",
        f"-entry={hex(args.runnable_base + start)}",
        "-dynamic-parallel",
        f"-parallel-workers={args.parallel_workers}",
        f"-parallel-fragment-dir={fragment_dir}",
        *seed_addr_range_flags(args, start, end_exclusive),
        *args.coordinator_flag,
        str(args.binary),
        str(raw_ll),
    ]
    shell_script = f"""
set -euo pipefail
mkdir -p {shlex.quote(str(fragment_dir))}
{{ timeout {int(args.timeout_sec)} {shell_join(flags)}; }} >{shlex.quote(str(stdout_log))} 2>{shlex.quote(str(stderr_log))}
"""
    started = time.time()
    result = run_cmd(["bash", "-lc", shell_script], check=False, capture_output=False)
    rc = result.returncode
    worker_inputs = sorted(fragment_dir.glob("worker_*.ll"))
    if rc == 0 and not args.preserve_success_seed_logs:
        try:
            stdout_log.unlink()
        except FileNotFoundError:
            pass
        try:
            stderr_log.unlink()
        except FileNotFoundError:
            pass
    return {
        "shard_id": shard_id,
        "tag": tag,
        "name": str(seed["name"]),
        "start": start,
        "entry_pc": args.runnable_base + start,
        "size": int(seed["size"]),
        "status": "ok" if rc == 0 and raw_ll.exists() else "failed",
        "rc": rc,
        "elapsed_sec": time.time() - started,
        "workers_spawned": len(worker_inputs),
        "raw_ll": str(raw_ll),
        "merged_ll": str(merged_ll),
        "fragment_dir": str(fragment_dir),
        "stdout_log": str(stdout_log),
        "stderr_log": str(stderr_log),
        "merge_summary": str(merge_summary) if merge_summary.exists() else None,
    }


def run_shard(args: argparse.Namespace, shard: Dict[str, object], *, jsonl_lock: threading.Lock) -> Dict[str, object]:
    shard_id = str(shard["shard_id"])
    shard_log = args.logs_dir / f"{shard_id}.log"
    merged_ll = args.merged_dir / f"{shard_id}.ll"
    seeds = list(shard.get("seeds", []))
    ensure_dir(args.logs_dir)
    started = time.time()
    seed_results: List[Dict[str, object]] = []
    with shard_log.open("w", encoding="utf-8") as handle:
        for seed in seeds:
            handle.write(f"start {seed['start_hex']} {seed['name']}\n")
            handle.flush()
            result = run_seed(args=args, shard_id=shard_id, seed=seed)
            seed_results.append(result)
            handle.write(
                f"done {result['tag']} status={result['status']} rc={result['rc']} workers={result['workers_spawned']} elapsed={result['elapsed_sec']:.1f}\n"
            )
            handle.flush()
            append_jsonl(args.results_jsonl, result, lock=jsonl_lock)

    ok_seed_results = [item for item in seed_results if item["status"] == "ok"]
    if ok_seed_results and len(ok_seed_results) == len(seed_results):
        status = "ok"
    elif ok_seed_results:
        status = "partial"
    else:
        status = "failed"
    payload = {
        "shard_id": shard_id,
        "start": int(str(shard["start_hex"]), 0),
        "end_exclusive": int(str(shard["end_exclusive_hex"]), 0),
        "seed_count": int(shard["seed_count"]),
        "ok_seed_count": len(ok_seed_results),
        "failed_seed_count": len(seed_results) - len(ok_seed_results),
        "status": status,
        "elapsed_sec": time.time() - started,
        "merged_ll": str(merged_ll),
        "log_path": str(shard_log),
        "merge_summary": None,
    }
    return payload


def main() -> int:
    args = parse_args()
    for path in (
        args.raw_dir,
        args.fragment_root,
        args.merged_dir,
        args.logs_dir,
        args.results_json.parent,
        args.summary_out.parent,
    ):
        ensure_dir(path)
    args.results_jsonl.write_text("", encoding="utf-8")
    shards = load_shards(args.manifest)
    results: List[Dict[str, object]] = []
    shard_summaries: List[Dict[str, object]] = []
    jsonl_lock = threading.Lock()

    with ThreadPoolExecutor(max_workers=max(args.shard_concurrency, 1)) as executor:
        futures = {
            executor.submit(run_shard, args, shard, jsonl_lock=jsonl_lock): shard
            for shard in shards
        }
        for future in as_completed(futures):
            shard_summary = future.result()
            shard_summaries.append(shard_summary)

    by_tag: Dict[str, Dict[str, object]] = {}
    with args.results_jsonl.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            item = json.loads(line)
            by_tag[str(item["tag"])] = item
    results = sorted(by_tag.values(), key=lambda item: int(item["start"]))
    shard_summaries.sort(key=lambda item: int(item["start"]))
    write_json(args.results_json, {"results": results, "shards": shard_summaries})
    write_json(
        args.summary_out,
        {
            "seed_count": len(results),
            "shard_count": len(shard_summaries),
            "ok_shard_count": sum(1 for item in shard_summaries if item["status"] == "ok"),
            "results_json": str(args.results_json),
            "results_jsonl": str(args.results_jsonl),
        },
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
