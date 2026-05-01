#!/usr/bin/env python3

import argparse
import json
import re
import sys
from pathlib import Path
from types import SimpleNamespace

from _merge_dynamic_fragments_lib import merge_full_module


HEX_RE = re.compile(r"0x([0-9a-fA-F]+)")
WORKER_RE = re.compile(r"worker_([0-9a-fA-F]+)\.ll$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Merge coordinator and worker runnable-lift full modules."
    )
    parser.add_argument("inputs", nargs="+", type=Path, help="Full-module .ll inputs.")
    parser.add_argument("--output", required=True, type=Path, help="Merged output path.")
    parser.add_argument(
        "--entry-pc",
        required=True,
        type=lambda value: int(value, 0),
        help="Coordinator entry PC used as the merged root entry.",
    )
    parser.add_argument(
        "--summary-out",
        type=Path,
        help="Optional JSON file for merge metadata.",
    )
    return parser.parse_args()


def infer_start(path: Path, default_entry_pc: int) -> int:
    worker_match = WORKER_RE.search(path.name)
    if worker_match is not None:
        return int(worker_match.group(1), 16)

    hex_match = HEX_RE.search(path.name)
    if hex_match is not None:
        return int(hex_match.group(1), 16)

    with path.open("r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            line = line.strip()
            if line.startswith("; 0x"):
                try:
                    return int(line.split(":")[0].split()[-1], 16)
                except ValueError:
                    continue

    return default_entry_pc


def main() -> int:
    args = parse_args()

    output = args.output.resolve()
    results = {}
    for index, path in enumerate(args.inputs):
        ll_path = path.resolve()
        if not ll_path.exists():
            raise FileNotFoundError(ll_path)
        start = infer_start(ll_path, args.entry_pc if index == 0 else 0)
        tag = "main" if index == 0 else f"worker_{start:016x}_{index}"
        results[tag] = {
            "tag": tag,
            "status": "ok",
            "start": start,
            "raw_ll": str(ll_path),
        }

    config = SimpleNamespace(
        raw_dir=output.parent,
        merged_full_ll=output,
        ground_truth_binary=None,
        entry_pc=args.entry_pc,
    )
    info = merge_full_module(config, results)
    payload = {
        "inputs": [str(path.resolve()) for path in args.inputs],
        "output": str(output),
        "entry_pc": f"0x{args.entry_pc:x}",
        "merge_info": info,
    }
    if args.summary_out is not None:
        args.summary_out.resolve().write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
