#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Iterable, List


ROOT_DIR = Path(__file__).resolve().parents[2]
WORKSPACE_ROOT = ROOT_DIR.parent
BENCH_ROOT_ENV = "RUNNABLE_LIBCRYPTO_BENCH_ROOT"
GROUND_TRUTH_ENV = "RUNNABLE_LIBCRYPTO_GROUND_TRUTH"
GROUND_TRUTH_PB_ENV = "RUNNABLE_LIBCRYPTO_GROUND_TRUTH_PB"
CANONICAL_TEXT_START_ENV = "RUNNABLE_LIBCRYPTO_TEXT_START"
CANONICAL_GT_DIRNAME = "libcrypto_groudtruth_20260428"
LEGACY_GT_DIRNAME = "libcrypto_master_test_20260414"
READELF_TEXT_RE = re.compile(r"^\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+([0-9a-fA-F]+)\s")
READELF_TEXT_BOUNDS_RE = re.compile(
    r"^\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+([0-9a-fA-F]+)\s+[0-9a-fA-F]+\s+([0-9a-fA-F]+)\s"
)


def _unique_paths(paths: Iterable[Path]) -> List[Path]:
    unique: List[Path] = []
    seen: set[str] = set()
    for path in paths:
        key = os.path.normpath(str(path.expanduser()))
        if key in seen:
            continue
        seen.add(key)
        unique.append(Path(key))
    return unique


def configured_bench_roots(repo_root: Path = ROOT_DIR) -> List[Path]:
    candidates: List[Path] = []
    workspace_root = repo_root.parent

    env_root = os.environ.get(BENCH_ROOT_ENV)
    if env_root:
        candidates.append(Path(env_root).expanduser())

    # Repo-local canonical artifacts currently live under GroudTruth results.
    candidates.extend(
        [
            workspace_root / "GroudTruth" / "groundtruth-gap-analysis-skill" / "results" / "libcrypto-artifacts",
            workspace_root / "GroudTruth" / "groundtruth-gap-analysis-skill" / "results",
            workspace_root / "GroudTruth",
            repo_root / "GroudTruth" / "groundtruth-gap-analysis-skill" / "results" / "libcrypto-artifacts",
            repo_root / "GroudTruth" / "groundtruth-gap-analysis-skill" / "results",
            repo_root / "GroudTruth",
            repo_root,
        ]
    )

    return _unique_paths(candidates)


def _binary_candidates_from_root(root: Path) -> List[Path]:
    root = root.expanduser()
    if root.name == "libcrypto.so.3" or root.is_file():
        return [root]

    candidates = [
        root / "libcrypto.so.3",
        root / CANONICAL_GT_DIRNAME / "libcrypto.so.3",
        root / LEGACY_GT_DIRNAME / "libcrypto.so.3",
        root / "archives" / "groundtruth" / CANONICAL_GT_DIRNAME / "libcrypto.so.3",
        root / "archives" / "experiments" / LEGACY_GT_DIRNAME / "libcrypto.so.3",
        root / "groundtruth-gap-analysis-skill" / "results" / "libcrypto-artifacts" / "libcrypto.so.3",
    ]
    return _unique_paths(candidates)


def binary_candidates(repo_root: Path = ROOT_DIR) -> List[Path]:
    candidates: List[Path] = []
    exact = os.environ.get(GROUND_TRUTH_ENV)
    if exact:
        candidates.append(Path(exact).expanduser())
    for root in configured_bench_roots(repo_root):
        candidates.extend(_binary_candidates_from_root(root))
    return _unique_paths(candidates)


def default_ground_truth_binary(repo_root: Path = ROOT_DIR) -> Path:
    candidates = binary_candidates(repo_root)
    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()
    return candidates[0]


def _groundtruth_pb_candidates(binary: Path, repo_root: Path = ROOT_DIR) -> List[Path]:
    candidates: List[Path] = []

    env_path = os.environ.get(GROUND_TRUTH_PB_ENV)
    if env_path:
        candidates.append(Path(env_path).expanduser())

    if ".so" in binary.name:
        base = binary.name.split(".so", 1)[0]
        candidates.append(binary.with_name(f"{base}.gtBlock.pb"))
    candidates.append(Path(str(binary) + ".gtBlock.pb"))
    candidates.append(binary.with_name(f"{binary.name}.gtBlock.pb"))

    candidates.extend(
        [
            repo_root / "GroudTruth" / "groundtruth-gap-analysis-skill" / "results" / "libcrypto-artifacts" / "libcrypto.gtBlock.pb",
            repo_root / "archives" / "groundtruth" / CANONICAL_GT_DIRNAME / "libcrypto.gtBlock.pb",
        ]
    )
    return _unique_paths(candidates)


def default_groundtruth_pb(repo_root: Path = ROOT_DIR) -> Path:
    binary = default_ground_truth_binary(repo_root)
    candidates = _groundtruth_pb_candidates(binary, repo_root)
    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()
    return candidates[0]


def default_blocks_pb2(repo_root: Path = ROOT_DIR) -> Path:
    workspace_root = repo_root.parent
    candidates = [
        workspace_root / "GroudTruth" / "protobuf_def" / "blocks_pb2.py",
        workspace_root / "GroudTruth" / "extract_gt" / "pemap" / "blocks_pb2.py",
        repo_root / "GroudTruth" / "protobuf_def" / "blocks_pb2.py",
        repo_root / "GroudTruth" / "extract_gt" / "pemap" / "blocks_pb2.py",
        Path(__file__).resolve().parent / "_vendor" / "blocks_pb2.py",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()
    return candidates[0]


def default_compare_tool(repo_root: Path = ROOT_DIR) -> Path:
    candidates = [
        Path(__file__).resolve().parent / "run_cmp_eval.py",
        repo_root / ".codex" / "skills" / "runnable-cmp-eval" / "scripts" / "run_cmp_eval.py",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()
    return candidates[0]


def parse_text_start_from_readelf_output(output: str) -> int:
    for line in output.splitlines():
        match = READELF_TEXT_RE.match(line)
        if match and match.group(1) == ".text":
            return int(match.group(2), 16)
    raise RuntimeError("cannot detect .text start from readelf output")


def detect_text_start(binary: Path) -> int:
    result = subprocess.run(
        ["readelf", "-WS", str(binary)],
        check=True,
        capture_output=True,
        text=True,
    )
    return parse_text_start_from_readelf_output(result.stdout)


def detect_text_bounds(binary: Path) -> tuple:
    """Return (text_start, text_end_exclusive) as relative VMA offsets."""
    result = subprocess.run(
        ["readelf", "-WS", str(binary)],
        check=True,
        capture_output=True,
        text=True,
    )
    for line in result.stdout.splitlines():
        m = READELF_TEXT_BOUNDS_RE.match(line)
        if m and m.group(1) == ".text":
            start = int(m.group(2), 16)
            size = int(m.group(3), 16)
            return (start, start + size)
    raise RuntimeError("cannot detect .text bounds from readelf output")


def canonical_text_start(repo_root: Path = ROOT_DIR) -> int:
    env_value = os.environ.get(CANONICAL_TEXT_START_ENV)
    if env_value:
        return int(env_value, 0)
    return detect_text_start(default_ground_truth_binary(repo_root))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Resolve canonical libcrypto benchmark asset paths."
    )
    parser.add_argument(
        "kind",
        choices=["bench-root", "binary", "groundtruth-pb", "blocks-pb2", "cmp-tool", "text-start"],
    )
    parser.add_argument("--repo-root", type=Path, default=ROOT_DIR)
    parser.add_argument("--must-exist", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    repo_root = args.repo_root.resolve()

    if args.kind == "bench-root":
        value = configured_bench_roots(repo_root)[0]
    elif args.kind == "binary":
        value = default_ground_truth_binary(repo_root)
    elif args.kind == "groundtruth-pb":
        value = default_groundtruth_pb(repo_root)
    elif args.kind == "blocks-pb2":
        value = default_blocks_pb2(repo_root)
    elif args.kind == "cmp-tool":
        value = default_compare_tool(repo_root)
    else:
        value = hex(canonical_text_start(repo_root))

    if args.kind != "text-start" and args.must_exist and not value.exists():
        print(str(value), file=sys.stderr)
        return 2
    print(str(value))
    return 0


if __name__ == "__main__":
    sys.exit(main())
