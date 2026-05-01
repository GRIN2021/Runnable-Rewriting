#!/usr/bin/env python3

import argparse
import json
from pathlib import Path
from typing import Dict, List, Optional

from _fn_fp_root_cause_lib import (
    find_symbol_for_address,
    hex_list,
    is_continuation_byte,
    is_in_ranges,
    load_coverage_addresses,
    load_function_symbols_csv,
    load_ground_truth_csv,
    load_illegal_addresses,
    load_lifted_instruction_map,
    load_shard_results,
    neighbor_ground_truth,
    read_json,
    shard_path,
    tag_for_symbol,
    write_json,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Analyze false negatives and false positives from runnable ground-truth validation."
    )
    parser.add_argument("--validation-summary", required=True, type=Path)
    parser.add_argument("--ground-truth-csv", required=True, type=Path)
    parser.add_argument("--function-symbols-csv", required=True, type=Path)
    parser.add_argument("--merged-ll", required=True, type=Path)
    parser.add_argument("--shard-results-json", required=True, type=Path)
    parser.add_argument("--csv-image-base", required=True, type=lambda value: int(value, 0))
    parser.add_argument("--rebase-base", required=True, type=lambda value: int(value, 0))
    parser.add_argument("--summary-out", type=Path)
    return parser.parse_args()


def fn_reason_for_address(
    addr: int,
    symbol,
    shard: Optional[Dict[str, object]],
    fixture_root: Path,
) -> Dict[str, object]:
    evidence: List[str] = []
    reason = "unknown_fn"
    priority = "medium"

    if shard is None:
        return {"reason": "missing_shard_result", "priority": "high", "evidence": evidence}

    status = shard.get("status")
    coverage = load_coverage_addresses(shard_path(fixture_root, shard.get("coverage_csv")))
    illegal_path = None
    if shard.get("coverage_csv"):
        coverage_path = shard_path(fixture_root, shard.get("coverage_csv"))
        if coverage_path is not None:
            illegal_path = coverage_path.with_name(
                coverage_path.name.replace(".coverage.csv", ".illegalEntry.log")
            )
    illegal = load_illegal_addresses(illegal_path)
    stderr_log = shard_path(fixture_root, shard.get("stderr_log"))

    if addr in illegal:
        reason = "illegal_entry_suppression"
        priority = "high"
        if illegal_path is not None:
            evidence.append(str(illegal_path))
    elif status == "timeout":
        reason = "shard_timeout"
        priority = "high"
        if stderr_log:
            evidence.append(str(stderr_log))
    elif status == "error":
        reason = "shard_error"
        priority = "high"
        if stderr_log:
            evidence.append(str(stderr_log))
    elif status == "empty":
        reason = "shard_empty"
        priority = "high"
        if shard.get("shard_ll"):
            evidence.append(str(shard_path(fixture_root, shard["shard_ll"])))
    elif status == "ok" and addr in coverage:
        reason = "merge_missing"
        priority = "high"
        if shard.get("shard_ll"):
            evidence.append(str(shard_path(fixture_root, shard["shard_ll"])))
    elif status == "ok":
        reason = "outside_gt_coverage"
        priority = "medium"
    return {"reason": reason, "priority": priority, "evidence": evidence}


def fp_reason_for_address(addr: int, gt_instrs, data_ranges) -> Dict[str, object]:
    if is_continuation_byte(addr, gt_instrs):
        return {"reason": "continuation_byte", "priority": "medium", "evidence": []}
    if is_in_ranges(addr, data_ranges):
        return {"reason": "padding", "priority": "medium", "evidence": []}
    if neighbor_ground_truth(addr, gt_instrs) and addr % 4 == 0:
        return {"reason": "ground_truth_gap", "priority": "low", "evidence": []}
    upper_data_end = max((end for _, end in data_ranges), default=max(gt_instrs))
    if addr > upper_data_end:
        return {"reason": "outside_gt_coverage", "priority": "medium", "evidence": []}
    return {"reason": "extra_lifted_bytes", "priority": "medium", "evidence": []}


def main() -> int:
    args = parse_args()
    fixture_root = Path.cwd()
    summary = read_json(args.validation_summary)
    gt_instrs, data_ranges = load_ground_truth_csv(
        args.ground_truth_csv,
        csv_image_base=args.csv_image_base,
        rebase_base=args.rebase_base,
    )
    symbols = load_function_symbols_csv(
        args.function_symbols_csv,
        csv_image_base=args.csv_image_base,
        rebase_base=args.rebase_base,
    )
    load_lifted_instruction_map(args.merged_ll)
    shard_results = load_shard_results(args.shard_results_json)

    findings: List[Dict[str, object]] = []
    for addr_hex in summary["fn_addresses"]:
        addr = int(addr_hex, 16)
        symbol = find_symbol_for_address(symbols, addr)
        shard = shard_results.get(tag_for_symbol(symbol)) if symbol else None
        classification = fn_reason_for_address(addr, symbol, shard, fixture_root)
        findings.append(
            {
                "kind": "fn",
                "address": addr_hex,
                "reason": classification["reason"],
                "priority": classification["priority"],
                "symbol": None if symbol is None else symbol.name,
                "range": None if symbol is None else f"0x{symbol.start_runtime:x}-0x{symbol.end_runtime:x}",
                "evidence_paths": classification["evidence"],
            }
        )

    for addr_hex in summary["fp_addresses"]:
        addr = int(addr_hex, 16)
        classification = fp_reason_for_address(addr, gt_instrs, data_ranges)
        findings.append(
            {
                "kind": "fp",
                "address": addr_hex,
                "reason": classification["reason"],
                "priority": classification["priority"],
                "symbol": None,
                "range": None,
                "evidence_paths": classification["evidence"],
            }
        )

    payload = {
        "validation_summary": str(args.validation_summary.resolve()),
        "ground_truth_csv": str(args.ground_truth_csv.resolve()),
        "function_symbols_csv": str(args.function_symbols_csv.resolve()),
        "merged_ll": str(args.merged_ll.resolve()),
        "shard_results_json": str(args.shard_results_json.resolve()),
        "categories": sorted({finding["reason"] for finding in findings}),
        "findings": findings,
        "summary": {
            "fn_count": len(summary["fn_addresses"]),
            "fp_count": len(summary["fp_addresses"]),
            "fn_addresses": summary["fn_addresses"],
            "fp_addresses": summary["fp_addresses"],
        },
    }
    write_json(args.summary_out, payload)
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
