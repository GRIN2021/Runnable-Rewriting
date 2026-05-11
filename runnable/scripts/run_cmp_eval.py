#!/usr/bin/env python3

import argparse
from collections import Counter
import json
import re
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import _compare_runnable_text_lib as compare_text


OBJ_INST_RE = re.compile(r"^\s+([0-9a-fA-F]+):\t")
LL_INST_RE = re.compile(r"^\s*;\s*(0x[0-9a-fA-F]+):")
READELF_TEXT_RE = re.compile(r"^\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+([0-9a-fA-F]+)\s")
OBJDUMP_TEXT_RE = re.compile(r"^\s*\d+\s+(\S+)\s+[0-9a-fA-F]+\s+([0-9a-fA-F]+)\s")
ELF_MAGIC = b"\x7fELF"


def is_elf(path: Path):
    try:
        with path.open("rb") as f:
            return f.read(4) == ELF_MAGIC
    except OSError:
        return False


def parse_int(value: str):
    return int(value, 0)


def resolve_paths(args):
    sample_base = Path(args.base).resolve() if args.base else None
    binary = Path(args.binary).resolve() if args.binary else sample_base
    ll = Path(args.ll).resolve() if args.ll else (Path(str(sample_base) + ".ll") if sample_base else None)

    if binary is None or ll is None:
        raise ValueError("provide --base, or provide both --binary and --ll")

    missing = [str(path) for path in (binary, ll) if not path.exists()]
    if missing:
        raise FileNotFoundError("\n".join(missing))

    if not is_elf(binary):
        raise ValueError(
            f"{binary} is not an ELF binary. "
            "The compare_runnable_text workflow needs the real ground-truth binary or shared library."
        )

    return sample_base, binary, ll


def detect_text_start_readelf(binary: Path):
    import subprocess

    out = subprocess.check_output(["readelf", "-WS", str(binary)], text=True)
    for line in out.splitlines():
        match = READELF_TEXT_RE.match(line)
        if match and match.group(1) == ".text":
            return int(match.group(2), 16)
    return None


def detect_text_start_objdump(binary: Path):
    import subprocess

    out = subprocess.check_output(["objdump", "-h", str(binary)], text=True)
    for line in out.splitlines():
        match = OBJDUMP_TEXT_RE.match(line)
        if match and match.group(1) == ".text":
            return int(match.group(2), 16)
    return None


def detect_text_start(binary: Path):
    for detector in (detect_text_start_readelf, detect_text_start_objdump):
        try:
            text_start = detector(binary)
        except Exception:
            text_start = None
        if text_start is not None:
            return text_start
    raise RuntimeError(f"cannot detect .text start for {binary}")


def sample_obj_addresses(binary: Path, text_start: int, limit: int = 4096):
    import subprocess

    addrs = []
    proc = subprocess.Popen(
        ["objdump", "-d", str(binary)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        assert proc.stdout is not None
        for line in proc.stdout:
            match = OBJ_INST_RE.match(line.rstrip("\n"))
            if not match:
                continue
            addr = int(match.group(1), 16)
            if addr < text_start:
                continue
            addrs.append(addr)
            if len(addrs) >= limit:
                break
    finally:
        if proc.stdout is not None:
            proc.stdout.close()
        proc.kill()
        proc.wait()
    return addrs


def sample_ll_raw_addresses(ll_path: Path, limit: int = 4096):
    addrs = []
    with ll_path.open("r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            match = LL_INST_RE.match(line.rstrip("\n"))
            if not match:
                continue
            addrs.append(int(match.group(1), 16))
            if len(addrs) >= limit:
                break
    return addrs


def detect_runnable_base(binary: Path, ll_path: Path, text_start: int):
    obj_addrs = sample_obj_addresses(binary, text_start)
    ll_addrs = sample_ll_raw_addresses(ll_path)
    if not obj_addrs or not ll_addrs:
        return 0

    obj_set = set(obj_addrs)
    counts = Counter()
    for ll_addr in set(ll_addrs):
        for obj_addr in obj_set:
            delta = ll_addr - obj_addr
            if (delta & 0xFFF) == 0:
                counts[delta] += 1

    if counts:
        return counts.most_common(1)[0][0]
    return min(ll_addrs) - min(obj_addrs)


def format_example_block(name: str, examples, formatter):
    lines = [f"[{name}]"]
    for item in examples:
        lines.append(formatter(item))
    return "\n".join(lines)


def serialize_examples(examples, kind: str):
    payload = []
    for item in examples:
        if kind == "mismatch":
            addr, obj_ins, ll_ins = item
            payload.append({"address": hex(addr), "obj": obj_ins, "ll": ll_ins})
        else:
            addr, ins = item
            payload.append({"address": hex(addr), "instruction": ins})
    return payload


def write_text_summary(path: Path, payload: dict):
    lines = [
        f"sample_base={payload['sample_base']}",
        f"binary={payload['binary']}",
        f"ll={payload['ll']}",
        f"source={payload['source']}",
        f"text_start=0x{payload['text_start']:x}",
        f"runnable_base=0x{payload['runnable_base']:x}",
        f"obj_count={payload['obj_count']}",
        f"ll_count={payload['ll_count']}",
        f"hit={payload['hit']}",
        f"mismatch={payload['mismatch']}",
        f"obj_only={payload['obj_only']}",
        f"ll_only={payload['ll_only']}",
        f"false_negative={payload['false_negative']}",
        f"false_positive={payload['false_positive']}",
        f"precision={payload['precision']:.6f}",
        f"recall={payload['recall']:.6f}",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def build_payload(sample_base, binary, ll, text_start, runnable_base, examples, result):
    return {
        "sample_base": str(sample_base) if sample_base is not None else None,
        "binary": str(binary),
        "ll": str(ll),
        "source": "fresh_compare_runnable_text",
        "text_start": text_start,
        "runnable_base": runnable_base,
        "example_limit": examples,
        "obj_count": result["obj_count"],
        "ll_count": result["ll_count"],
        "hit": result["hit"],
        "mismatch": result["mismatch"],
        "obj_only": result["obj_only"],
        "ll_only": result["ll_only"],
        "false_negative": result["false_negative"],
        "false_positive": result["false_positive"],
        "precision": result["precision"],
        "recall": result["recall"],
        "mismatch_examples": serialize_examples(result["mismatch_examples"], "mismatch"),
        "obj_only_examples": serialize_examples(result["obj_only_examples"], "single"),
        "ll_only_examples": serialize_examples(result["ll_only_examples"], "single"),
    }


def main():
    ap = argparse.ArgumentParser(description="Run Runnable compare_runnable_text evaluation.")
    ap.add_argument("--base", help="Common base where <base> is the ELF and <base>.ll is the lift")
    ap.add_argument("--binary", help="Path to the ground-truth ELF/shared library")
    ap.add_argument("--ll", help="Path to the Runnable lift .ll file")
    ap.add_argument(
        "--text-start",
        default="auto",
        help="First binary virtual address to include. Use 'auto' or an integer like 0xcf000.",
    )
    ap.add_argument(
        "--runnable-base",
        default="auto",
        help="Base to subtract from ll addresses. Use 'auto' or an integer like 0x50000000.",
    )
    ap.add_argument("--examples", type=int, default=10, help="How many sample lines to keep for each category")
    ap.add_argument("--json-out", help="Optional JSON summary output path")
    ap.add_argument("--text-out", help="Optional text summary output path")
    ap.add_argument(
        "--rerun",
        action="store_true",
        help="Accepted for compatibility. The compare workflow already runs fresh each time.",
    )
    args = ap.parse_args()

    try:
        sample_base, binary, ll = resolve_paths(args)
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 2

    if args.text_start == "auto":
        text_start = detect_text_start(binary)
    else:
        text_start = parse_int(args.text_start)

    if args.runnable_base == "auto":
        runnable_base = detect_runnable_base(binary, ll, text_start)
    else:
        runnable_base = parse_int(args.runnable_base)

    obj_instructions = compare_text.parse_objdump(binary, text_start)
    ll_raw = compare_text.parse_ll_raw(ll)
    ll_instructions = compare_text.normalize_ll_addresses(ll_raw, text_start, runnable_base)
    result = compare_text.compare(obj_instructions, ll_instructions, args.examples)

    payload = build_payload(sample_base, binary, ll, text_start, runnable_base, args.examples, result)

    if args.json_out:
        json_path = Path(args.json_out).resolve()
        json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if args.text_out:
        write_text_summary(Path(args.text_out).resolve(), payload)

    print(f"sample_base={payload['sample_base']}")
    print(f"binary={payload['binary']}")
    print(f"ll={payload['ll']}")
    print(f"source={payload['source']}")
    print(f"text_start=0x{payload['text_start']:x}")
    print(f"runnable_base=0x{payload['runnable_base']:x}")
    print(f"obj_count={payload['obj_count']}")
    print(f"ll_count={payload['ll_count']}")
    print(f"hit={payload['hit']}")
    print(f"mismatch={payload['mismatch']}")
    print(f"obj_only={payload['obj_only']}")
    print(f"ll_only={payload['ll_only']}")
    print(f"false_negative={payload['false_negative']}")
    print(f"false_positive={payload['false_positive']}")
    print(f"precision={payload['precision']:.6f}")
    print(f"recall={payload['recall']:.6f}")
    print("formula_false_negative=obj_only + mismatch")
    print("formula_false_positive=ll_only + mismatch")
    print()
    print(
        format_example_block(
            "MISMATCH_EXAMPLES",
            result["mismatch_examples"],
            lambda item: f"{hex(item[0])}\tOBJ={item[1]}\tLL={item[2]}",
        )
    )
    print()
    print(
        format_example_block(
            "OBJ_ONLY_EXAMPLES",
            result["obj_only_examples"],
            lambda item: f"{hex(item[0])}\tOBJ={item[1]}",
        )
    )
    print()
    print(
        format_example_block(
            "LL_ONLY_EXAMPLES",
            result["ll_only_examples"],
            lambda item: f"{hex(item[0])}\tLL={item[1]}",
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
