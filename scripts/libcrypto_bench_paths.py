#!/usr/bin/env python3
"""Resolve canonical libcrypto benchmark assets from repo-local or external roots."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Iterable, List


ROOT_DIR = Path(__file__).resolve().parents[1]
BENCH_ROOT_ENV = "RUNNABLE_LIBCRYPTO_BENCH_ROOT"
GROUND_TRUTH_ENV = "RUNNABLE_LIBCRYPTO_GROUND_TRUTH"
CANONICAL_GT_DIRNAME = "libcrypto_groudtruth_20260428"
LEGACY_GT_DIRNAME = "libcrypto_master_test_20260414"
CANONICAL_GT_BINARY_REL = (
    Path("archives") / "groundtruth" / CANONICAL_GT_DIRNAME / "libcrypto.so.3"
)
LEGACY_GT_BINARY_REL = (
    Path("archives") / "experiments" / LEGACY_GT_DIRNAME / "libcrypto.so.3"
)
READELF_TEXT_RE = re.compile(r"^\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+([0-9a-fA-F]+)\s")


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
    env_root = os.environ.get(BENCH_ROOT_ENV)
    if env_root:
        candidates.append(Path(env_root).expanduser())
    candidates.append(repo_root.expanduser())
    return _unique_paths(candidates)


def _binary_candidates_from_root(root: Path) -> List[Path]:
    root = root.expanduser()
    if root.name == "libcrypto.so.3" or root.is_file():
        return [root]

    candidates = [
        root / CANONICAL_GT_BINARY_REL,
        root / LEGACY_GT_BINARY_REL,
        root / CANONICAL_GT_DIRNAME / "libcrypto.so.3",
        root / LEGACY_GT_DIRNAME / "libcrypto.so.3",
        root / "libcrypto.so.3",
    ]
    if root.name == "groundtruth":
        candidates.insert(0, root / CANONICAL_GT_DIRNAME / "libcrypto.so.3")
    if root.name == "experiments":
        candidates.insert(0, root / LEGACY_GT_DIRNAME / "libcrypto.so.3")
    return _unique_paths(candidates)


def binary_candidates(repo_root: Path = ROOT_DIR) -> List[Path]:
    exact = os.environ.get(GROUND_TRUTH_ENV)
    candidates: List[Path] = []
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


def bench_root_for_binary(binary: Path, repo_root: Path = ROOT_DIR) -> Path:
    resolved_binary = binary.resolve()
    for root in configured_bench_roots(repo_root):
        expanded_root = root.expanduser()
        if expanded_root.is_file():
            if expanded_root.resolve() == resolved_binary:
                return expanded_root.parent.resolve()
            continue
        try:
            resolved_binary.relative_to(expanded_root.resolve())
            return expanded_root.resolve()
        except ValueError:
            continue
    return resolved_binary.parent.resolve()


def _groundtruth_pb_candidates(binary: Path) -> List[Path]:
    candidates: List[Path] = []
    if ".so" in binary.name:
        base = binary.name.split(".so", 1)[0]
        candidates.append(binary.with_name(f"{base}.gtBlock.pb"))
    candidates.append(Path(str(binary) + ".gtBlock.pb"))
    candidates.append(binary.with_name(f"{binary.name}.gtBlock.pb"))
    return _unique_paths(candidates)


def default_groundtruth_pb(repo_root: Path = ROOT_DIR) -> Path:
    binary = default_ground_truth_binary(repo_root)
    candidates = _groundtruth_pb_candidates(binary)
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


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Resolve canonical libcrypto benchmark asset paths."
    )
    parser.add_argument(
        "kind",
        choices=["bench-root", "binary", "groundtruth-pb", "text-start"],
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
    else:
        value = hex(detect_text_start(default_ground_truth_binary(repo_root)))

    if args.kind != "text-start" and args.must_exist and not value.exists():
        print(str(value), file=sys.stderr)
        return 2
    print(str(value))
    return 0


if __name__ == "__main__":
    sys.exit(main())
