#!/usr/bin/env python3
"""Validate the refreshed libcrypto ground truth and compare lift outputs safely."""

from __future__ import annotations

import argparse
import bisect
import collections
import importlib.util
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Tuple

from libcrypto_bench_paths import default_ground_truth_binary, default_groundtruth_pb


ROOT_DIR = Path(__file__).resolve().parents[1]
SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_BINARY = default_ground_truth_binary(ROOT_DIR)
DEFAULT_GROUNDTRUTH = default_groundtruth_pb(ROOT_DIR)
DEFAULT_RUN_CMP_EVAL = (
    ROOT_DIR / ".codex" / "skills" / "runnable-cmp-eval" / "scripts" / "run_cmp_eval.py"
)
DEFAULT_VENDOR_BLOCKS_PB2 = SCRIPT_DIR / "_vendor" / "blocks_pb2.py"
DEFAULT_OUT_DIR = ROOT_DIR / "runs" / "groundtruth_validation"
DEFAULT_RUNNABLE_BASE = 0x50000000
DEFAULT_MIN_PRECISION = 0.80
DEFAULT_MIN_RECALL = 0.80
READELF_TEXT_RE = re.compile(r"^\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+([0-9a-fA-F]+)\s")
OBJDUMP_INST_RE = re.compile(r"^\s*([0-9a-fA-F]+):\s+((?:[0-9a-fA-F]{2}\s)+)\s*(.*)$")


@dataclass
class CmpVerdict:
    ok: bool
    reasons: List[str]


def parse_int(value: str) -> int:
    return int(value, 0)


def ensure_file(path: Path, label: str) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"{label} not found: {path}")


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def run_cmd(cmd: Sequence[str], *, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=check, text=True, capture_output=True)


def read_json(path: Path) -> Dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: Dict[str, object]) -> None:
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def write_text(path: Path, lines: Iterable[str]) -> None:
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def detect_text_start(binary: Path) -> int:
    out = run_cmd(["readelf", "-WS", str(binary)]).stdout
    for line in out.splitlines():
        match = READELF_TEXT_RE.match(line)
        if match and match.group(1) == ".text":
            return int(match.group(2), 16)
    raise RuntimeError(f"cannot detect .text start for {binary}")


def resolve_default_groundtruth_path(binary: Path) -> Path:
    candidates: List[Path] = []
    if ".so" in binary.name:
        base = binary.name.split(".so", 1)[0]
        candidates.append(binary.with_name(f"{base}.gtBlock.pb"))
    candidates.append(Path(str(binary) + ".gtBlock.pb"))
    candidates.append(binary.with_name(f"{binary.name}.gtBlock.pb"))

    seen = set()
    for candidate in candidates:
        if candidate in seen:
            continue
        seen.add(candidate)
        if candidate.exists():
            return candidate
    raise FileNotFoundError(
        f"could not infer groundtruth protobuf next to {binary}; tried: "
        + ", ".join(str(path) for path in candidates)
    )


def load_blocks_pb2(path: Path):
    spec = importlib.util.spec_from_file_location("groundtruth_blocks_pb2", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load protobuf module from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def merge_ranges(ranges: Iterable[Tuple[int, int]]) -> List[Tuple[int, int]]:
    sorted_ranges = sorted(ranges)
    merged: List[List[int]] = []
    for start, end in sorted_ranges:
        if not merged or start > merged[-1][1]:
            merged.append([start, end])
            continue
        merged[-1][1] = max(merged[-1][1], end)
    return [(start, end) for start, end in merged]


def in_ranges(addr: int, ranges: Sequence[Tuple[int, int]], starts: Sequence[int]) -> bool:
    idx = bisect.bisect_right(starts, addr) - 1
    if idx < 0:
        return False
    start, end = ranges[idx]
    return start <= addr < end


def parse_groundtruth(gt_path: Path, blocks_pb2_path: Path) -> Tuple[set[int], List[Tuple[int, int]], List[Tuple[int, int]]]:
    blocks_pb2 = load_blocks_pb2(blocks_pb2_path)
    module = blocks_pb2.module()
    module.ParseFromString(gt_path.read_bytes())

    gt_inst_addrs: set[int] = set()
    covered_ranges: List[Tuple[int, int]] = []
    padding_ranges: List[Tuple[int, int]] = []
    for func in module.fuc:
        for bb in func.bb:
            for inst in bb.instructions:
                gt_inst_addrs.add(int(inst.va))
            va = int(bb.va)
            size = int(bb.size)
            padding = int(bb.padding)
            covered_end = va + size - padding
            if covered_end > va:
                covered_ranges.append((va, covered_end))
            if padding > 0:
                pad_start = covered_end
                pad_end = va + size
                if pad_end > pad_start:
                    padding_ranges.append((pad_start, pad_end))

    return gt_inst_addrs, merge_ranges(covered_ranges), merge_ranges(padding_ranges)


def parse_objdump_instructions(binary: Path) -> List[Tuple[int, int, str]]:
    out = run_cmd(["objdump", "-d", "-j", ".text", str(binary)]).stdout
    instructions: List[Tuple[int, int, str]] = []
    for line in out.splitlines():
        match = OBJDUMP_INST_RE.match(line)
        if not match:
            continue
        addr = int(match.group(1), 16)
        bytes_field = match.group(2).strip()
        asm = match.group(3).strip()
        if not asm:
            continue
        size = len(bytes_field.split())
        instructions.append((addr, size, asm))
    return instructions


def merge_unseen_ranges(unseen: Sequence[Tuple[int, int, str]]) -> List[Tuple[int, int, int, List[str]]]:
    if not unseen:
        return []
    ranges: List[Tuple[int, int, int, List[str]]] = []
    start = unseen[0][0]
    end = unseen[0][0] + unseen[0][1]
    count = 1
    sample = [unseen[0][2]]
    for addr, size, asm in unseen[1:]:
        if addr == end:
            end = addr + size
            count += 1
            if len(sample) < 3:
                sample.append(asm)
            continue
        ranges.append((start, end, count, sample))
        start = addr
        end = addr + size
        count = 1
        sample = [asm]
    ranges.append((start, end, count, sample))
    return ranges


def analyze_groundtruth_gap(
    binary: Path,
    groundtruth: Path,
    blocks_pb2_path: Path,
) -> Dict[str, object]:
    gt_inst_addrs, covered_ranges, padding_ranges = parse_groundtruth(
        groundtruth, blocks_pb2_path
    )
    covered_starts = [start for start, _ in covered_ranges]
    padding_starts = [start for start, _ in padding_ranges]

    obj_insts = parse_objdump_instructions(binary)
    unseen = [
        (addr, size, asm) for addr, size, asm in obj_insts if addr not in gt_inst_addrs
    ]
    unseen_ranges = merge_unseen_ranges(unseen)

    instruction_category_counts = collections.Counter()
    range_category_counts = collections.Counter()
    instruction_examples = {"padding": [], "outside_gt_coverage": []}
    range_examples = {"padding": [], "outside_gt_coverage": []}

    for addr, size, asm in unseen:
        category = (
            "padding"
            if in_ranges(addr, padding_ranges, padding_starts)
            else "outside_gt_coverage"
        )
        instruction_category_counts[category] += 1
        if len(instruction_examples[category]) < 20:
            instruction_examples[category].append(
                {"addr": hex(addr), "size": size, "asm": asm}
            )

    unseen_range_items = []
    for start, end, inst_count, sample_asm in unseen_ranges:
        category = (
            "padding"
            if in_ranges(start, padding_ranges, padding_starts)
            else "outside_gt_coverage"
        )
        range_category_counts[category] += 1
        item = {
            "start": hex(start),
            "end": hex(end),
            "inst_count": inst_count,
            "category": category,
            "sample_asm": sample_asm,
        }
        unseen_range_items.append(item)
        if len(range_examples[category]) < 20:
            range_examples[category].append(item)

    unseen_ratio = len(unseen) / len(gt_inst_addrs) if gt_inst_addrs else 0.0
    return {
        "binary": str(binary),
        "groundtruth": str(groundtruth),
        "blocks_pb2": str(blocks_pb2_path),
        "objdump_real_instruction_count": len(obj_insts),
        "groundtruth_instruction_count": len(gt_inst_addrs),
        "unseen_instruction_count": len(unseen),
        "unseen_ratio_over_groundtruth": unseen_ratio,
        "covered_range_count": len(covered_ranges),
        "padding_range_count": len(padding_ranges),
        "unseen_contiguous_range_count": len(unseen_ranges),
        "instruction_category_counts": dict(instruction_category_counts),
        "range_category_counts": dict(range_category_counts),
        "instruction_examples": instruction_examples,
        "range_examples": range_examples,
        "unseen_ranges": unseen_range_items,
    }


def write_gap_outputs(out_dir: Path, summary: Dict[str, object]) -> Tuple[Path, Path]:
    ensure_dir(out_dir)
    json_path = out_dir / "gap.summary.json"
    txt_path = out_dir / "gap.summary.txt"
    write_json(json_path, summary)

    lines = [
        f"binary: {summary['binary']}",
        f"groundtruth: {summary['groundtruth']}",
        f"blocks_pb2: {summary['blocks_pb2']}",
        f"objdump_real_instruction_count: {summary['objdump_real_instruction_count']}",
        f"groundtruth_instruction_count: {summary['groundtruth_instruction_count']}",
        f"unseen_instruction_count: {summary['unseen_instruction_count']}",
        "unseen_ratio_over_groundtruth: "
        f"{float(summary['unseen_ratio_over_groundtruth']):.12f}",
        f"unseen_contiguous_range_count: {summary['unseen_contiguous_range_count']}",
        "",
        "[instruction_category_counts]",
    ]
    for key, value in summary["instruction_category_counts"].items():
        lines.append(f"{key}: {value}")
    lines.append("")
    lines.append("[range_category_counts]")
    for key, value in summary["range_category_counts"].items():
        lines.append(f"{key}: {value}")
    write_text(txt_path, lines)
    return json_path, txt_path


def assess_cmp_payload(
    payload: Dict[str, object],
    *,
    min_precision: float,
    min_recall: float,
) -> CmpVerdict:
    reasons: List[str] = []
    precision = float(payload.get("precision", 0.0))
    recall = float(payload.get("recall", 0.0))

    if precision < min_precision:
        reasons.append(f"precision {precision:.6f} < {min_precision:.6f}")
    if recall < min_recall:
        reasons.append(f"recall {recall:.6f} < {min_recall:.6f}")
    if precision < 0.20 and recall < 0.20:
        reasons.append(
            "metrics are catastrophically low; the .ll likely comes from a different binary build"
        )
    return CmpVerdict(ok=not reasons, reasons=reasons)


def write_cmp_verdict(out_dir: Path, payload: Dict[str, object], verdict: CmpVerdict) -> Path:
    verdict_path = out_dir / "cmp.verdict.txt"
    lines = [
        f"binary: {payload.get('binary', '')}",
        f"ll: {payload.get('ll', '')}",
        f"text_start: 0x{int(payload.get('text_start', 0)):x}",
        f"runnable_base: 0x{int(payload.get('runnable_base', 0)):x}",
        f"precision: {float(payload.get('precision', 0.0)):.6f}",
        f"recall: {float(payload.get('recall', 0.0)):.6f}",
        f"ok: {str(verdict.ok).lower()}",
    ]
    if verdict.reasons:
        lines.append("")
        lines.append("[reasons]")
        lines.extend(verdict.reasons)
    write_text(verdict_path, lines)
    return verdict_path


def run_cmp(
    *,
    binary: Path,
    ll_path: Path,
    out_dir: Path,
    run_cmp_eval: Path,
    text_start: int | None,
    runnable_base: int,
    min_precision: float,
    min_recall: float,
    examples: int,
) -> Tuple[Dict[str, object], CmpVerdict, Path, Path, Path]:
    ensure_file(binary, "binary")
    ensure_file(ll_path, "ll")
    ensure_file(run_cmp_eval, "run_cmp_eval.py")
    ensure_dir(out_dir)

    resolved_text_start = detect_text_start(binary) if text_start is None else text_start
    json_out = out_dir / "cmp.json"
    text_out = out_dir / "cmp.txt"
    cmd = [
        "python3",
        str(run_cmp_eval),
        "--binary",
        str(binary),
        "--ll",
        str(ll_path),
        "--text-start",
        hex(resolved_text_start),
        "--runnable-base",
        hex(runnable_base),
        "--examples",
        str(examples),
        "--json-out",
        str(json_out),
        "--text-out",
        str(text_out),
    ]
    result = run_cmd(cmd, check=False)
    if result.returncode != 0:
        raise RuntimeError(
            "run_cmp_eval.py failed:\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    payload = read_json(json_out)
    verdict = assess_cmp_payload(
        payload,
        min_precision=min_precision,
        min_recall=min_recall,
    )
    verdict_path = write_cmp_verdict(out_dir, payload, verdict)
    return payload, verdict, json_out, text_out, verdict_path


def print_gap_summary(summary: Dict[str, object], txt_path: Path) -> None:
    print(f"gap_summary={txt_path}")
    print(
        "gap_counts="
        f"unseen={summary['unseen_instruction_count']} "
        f"outside_gt_coverage={summary['instruction_category_counts'].get('outside_gt_coverage', 0)} "
        f"padding={summary['instruction_category_counts'].get('padding', 0)}"
    )


def print_cmp_summary(
    payload: Dict[str, object],
    verdict: CmpVerdict,
    verdict_path: Path,
) -> None:
    print(f"cmp_verdict={verdict_path}")
    print(
        "cmp_metrics="
        f"precision={float(payload.get('precision', 0.0)):.6f} "
        f"recall={float(payload.get('recall', 0.0)):.6f} "
        f"text_start=0x{int(payload.get('text_start', 0)):x} "
        f"runnable_base=0x{int(payload.get('runnable_base', 0)):x}"
    )
    if verdict.reasons:
        for reason in verdict.reasons:
            print(f"cmp_reason={reason}", file=sys.stderr)


def add_shared_binary_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--binary", type=Path, default=DEFAULT_BINARY)
    parser.add_argument("--groundtruth", type=Path, default=None)
    parser.add_argument("--blocks-pb2", type=Path, default=DEFAULT_VENDOR_BLOCKS_PB2)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate the refreshed libcrypto ground truth and compare lift outputs."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    gap = subparsers.add_parser("gap-audit", help="Check binary .text addresses against gtBlock.pb")
    add_shared_binary_args(gap)

    cmp_parser = subparsers.add_parser("cmp", help="Run runnable-cmp-eval with safe defaults")
    add_shared_binary_args(cmp_parser)
    cmp_parser.add_argument("--ll", type=Path, required=True)
    cmp_parser.add_argument("--run-cmp-eval", type=Path, default=DEFAULT_RUN_CMP_EVAL)
    cmp_parser.add_argument("--text-start", default="elf")
    cmp_parser.add_argument("--runnable-base", default=hex(DEFAULT_RUNNABLE_BASE))
    cmp_parser.add_argument("--min-precision", type=float, default=DEFAULT_MIN_PRECISION)
    cmp_parser.add_argument("--min-recall", type=float, default=DEFAULT_MIN_RECALL)
    cmp_parser.add_argument("--examples", type=int, default=10)
    cmp_parser.add_argument("--allow-low-metrics", action="store_true")

    all_parser = subparsers.add_parser("all", help="Run gap audit and then compare a lift")
    add_shared_binary_args(all_parser)
    all_parser.add_argument("--ll", type=Path, required=True)
    all_parser.add_argument("--run-cmp-eval", type=Path, default=DEFAULT_RUN_CMP_EVAL)
    all_parser.add_argument("--text-start", default="elf")
    all_parser.add_argument("--runnable-base", default=hex(DEFAULT_RUNNABLE_BASE))
    all_parser.add_argument("--min-precision", type=float, default=DEFAULT_MIN_PRECISION)
    all_parser.add_argument("--min-recall", type=float, default=DEFAULT_MIN_RECALL)
    all_parser.add_argument("--examples", type=int, default=10)
    all_parser.add_argument("--allow-low-metrics", action="store_true")
    return parser


def resolve_groundtruth(binary: Path, groundtruth: Path | None) -> Path:
    return groundtruth.resolve() if groundtruth else resolve_default_groundtruth_path(binary.resolve())


def parse_text_start_arg(value: str) -> int | None:
    if value == "elf":
        return None
    return parse_int(value)


def cmd_gap_audit(args: argparse.Namespace) -> int:
    binary = args.binary.resolve()
    groundtruth = resolve_groundtruth(binary, args.groundtruth)
    blocks_pb2 = args.blocks_pb2.resolve()
    ensure_file(binary, "binary")
    ensure_file(groundtruth, "groundtruth")
    ensure_file(blocks_pb2, "blocks_pb2")

    summary = analyze_groundtruth_gap(binary, groundtruth, blocks_pb2)
    _, txt_path = write_gap_outputs(args.out_dir.resolve(), summary)
    print_gap_summary(summary, txt_path)
    return 0


def cmd_cmp(args: argparse.Namespace) -> int:
    binary = args.binary.resolve()
    groundtruth = resolve_groundtruth(binary, args.groundtruth)
    ensure_file(groundtruth, "groundtruth")
    payload, verdict, _, _, verdict_path = run_cmp(
        binary=binary,
        ll_path=args.ll.resolve(),
        out_dir=args.out_dir.resolve(),
        run_cmp_eval=args.run_cmp_eval.resolve(),
        text_start=parse_text_start_arg(args.text_start),
        runnable_base=parse_int(args.runnable_base),
        min_precision=args.min_precision,
        min_recall=args.min_recall,
        examples=args.examples,
    )
    print_cmp_summary(payload, verdict, verdict_path)
    if verdict.ok or args.allow_low_metrics:
        return 0
    return 3


def cmd_all(args: argparse.Namespace) -> int:
    gap_rc = cmd_gap_audit(args)
    if gap_rc != 0:
        return gap_rc
    return cmd_cmp(args)


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "gap-audit":
            return cmd_gap_audit(args)
        if args.command == "cmp":
            return cmd_cmp(args)
        if args.command == "all":
            return cmd_all(args)
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 2
    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
