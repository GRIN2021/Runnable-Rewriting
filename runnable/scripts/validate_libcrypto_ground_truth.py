#!/usr/bin/env python3

import argparse
import json
from pathlib import Path

from _fn_fp_root_cause_lib import (
    csv_to_runtime,
    hex_list,
    load_function_symbols_csv,
    load_ground_truth_csv,
    load_lifted_instruction_map,
    write_json,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate lifted instructions against a ground-truth CSV and emit TP/FP/FN summary."
    )
    parser.add_argument("--ground-truth-csv", required=True, type=Path)
    parser.add_argument("--ll", required=True, type=Path)
    parser.add_argument("--function-symbols-csv", required=True, type=Path)
    parser.add_argument("--csv-image-base", required=True, type=lambda value: int(value, 0))
    parser.add_argument("--rebase-base", required=True, type=lambda value: int(value, 0))
    parser.add_argument("--summary-out", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
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
    lifted = load_lifted_instruction_map(args.ll)
    lifted_addrs = set(lifted)

    tp = sorted(gt_instrs & lifted_addrs)
    fn = sorted(gt_instrs - lifted_addrs)
    fp = sorted(lifted_addrs - gt_instrs)

    symbol_payload = []
    for symbol in symbols:
        symbol_gt = {addr for addr in gt_instrs if symbol.start_runtime <= addr <= symbol.end_runtime}
        symbol_lifted = {addr for addr in lifted_addrs if symbol.start_runtime <= addr <= symbol.end_runtime}
        symbol_payload.append(
            {
                "name": symbol.name,
                "tag": f"fn_{symbol.start_csv:016x}",
                "start_csv": f"0x{symbol.start_csv:x}",
                "end_csv": f"0x{symbol.end_csv:x}",
                "start_runtime": f"0x{symbol.start_runtime:x}",
                "end_runtime": f"0x{symbol.end_runtime:x}",
                "tp_addresses": hex_list(symbol_gt & symbol_lifted),
                "fn_addresses": hex_list(symbol_gt - symbol_lifted),
            }
        )

    payload = {
        "ground_truth_csv": str(args.ground_truth_csv.resolve()),
        "ll": str(args.ll.resolve()),
        "function_symbols_csv": str(args.function_symbols_csv.resolve()),
        "csv_image_base": f"0x{args.csv_image_base:x}",
        "rebase_base": f"0x{args.rebase_base:x}",
        "tp": len(tp),
        "fp": len(fp),
        "fn": len(fn),
        "precision": 0.0 if not (len(tp) + len(fp)) else len(tp) / float(len(tp) + len(fp)),
        "recall": 0.0 if not (len(tp) + len(fn)) else len(tp) / float(len(tp) + len(fn)),
        "tp_addresses": hex_list(tp),
        "fp_addresses": hex_list(fp),
        "fn_addresses": hex_list(fn),
        "data_ranges": [
            {"start": f"0x{start:x}", "end": f"0x{end:x}"}
            for start, end in data_ranges
        ],
        "symbols": symbol_payload,
    }
    write_json(args.summary_out, payload)
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
