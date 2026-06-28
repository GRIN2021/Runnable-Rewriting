#!/usr/bin/env python3

import argparse
from collections import Counter
import json
import re
import subprocess
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
STATIC_FALLBACK_PROFILES = {
    "all-functions": [r".*"],
    "avx512": [r"avx512"],
    "simd-heavy": [
        r"avx512",
        r"avx2",
        r"_avx($|[^0-9A-Za-z])",
        r"ssse3",
        r"shaext",
        r"xop",
        r"ifma256",
        r"amm52",
        r"vpmadd52",
        r"sha[0-9]+_multi_block",
        r"sha[0-9]+_block_data_order",
        r"aesni_",
        r"gcm_ghash",
        r"ChaCha20_",
        r"poly1305_blocks",
    ],
}
STATIC_FALLBACK_TEXT_PROFILES = {"all-text"}


def is_elf(path: Path):
    try:
        with path.open("rb") as f:
            return f.read(4) == ELF_MAGIC
    except OSError:
        return False


def parse_int(value: str):
    return int(value, 0)


def parse_optional_int(value):
    if value in (None, "auto"):
        return None
    return parse_int(value)


def load_include_pcs(path: Path):
    pcs = set()
    for raw_line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        pcs.add(parse_int(line))
    return pcs


def parse_readelf_func_ranges(binary: Path, regexes):
    patterns = [re.compile(pattern) for pattern in regexes]
    out = subprocess.check_output(["readelf", "-Ws", str(binary)], text=True)
    ranges = []

    for line in out.splitlines():
        fields = line.strip().split(None, 7)
        if len(fields) < 8:
            continue
        _, value_text, size_text, sym_type, _, _, ndx, name = fields
        if sym_type != "FUNC" or ndx == "UND":
            continue
        try:
            start = int(value_text, 16)
            size = int(size_text, 0)
        except ValueError:
            continue
        if start == 0 or size <= 0:
            continue
        if not any(pattern.search(name) for pattern in patterns):
            continue
        ranges.append({"name": name, "start": start, "end": start + size, "size": size})

    ranges.sort(key=lambda item: (item["start"], item["end"], item["name"]))
    return ranges


def expand_static_fallback_regexes(profile_names, regexes):
    expanded, _ = expand_static_fallback_options(profile_names, regexes)
    return expanded


def static_fallback_profile_choices():
    return sorted(set(STATIC_FALLBACK_PROFILES) | STATIC_FALLBACK_TEXT_PROFILES)


def expand_static_fallback_options(profile_names, regexes):
    expanded = []
    include_all_text = False
    for profile in profile_names:
        if profile == "all-text":
            include_all_text = True
            continue
        try:
            expanded.extend(STATIC_FALLBACK_PROFILES[profile])
        except KeyError:
            known = ", ".join(static_fallback_profile_choices())
            raise ValueError(f"unknown static fallback profile {profile!r}; known profiles: {known}")
    expanded.extend(regexes)
    return expanded, include_all_text


def build_all_text_static_fallback_ranges(obj_instructions):
    if not obj_instructions:
        return []

    start = min(obj_instructions)
    end = max(obj_instructions) + 1
    return [{"name": "all-text", "start": start, "end": end, "size": end - start}]


def collect_static_fallback_ranges(binary, obj_instructions, symbol_regexes, include_all_text):
    ranges = []
    if symbol_regexes:
        ranges.extend(parse_readelf_func_ranges(binary, symbol_regexes))
    if include_all_text:
        ranges.extend(build_all_text_static_fallback_ranges(obj_instructions))
    return ranges


def merge_static_fallback_ranges(ranges):
    bounds = []
    for item in ranges:
        start = item["start"]
        end = item["end"]
        if end <= start:
            continue
        bounds.append((start, end))

    if not bounds:
        return []

    bounds.sort()
    merged = []
    current_start, current_end = bounds[0]
    for start, end in bounds[1:]:
        if start <= current_end:
            current_end = max(current_end, end)
            continue
        merged.append((current_start, current_end))
        current_start, current_end = start, end
    merged.append((current_start, current_end))
    return merged


def apply_static_fallback(obj_instructions, ll_instructions, ranges):
    added = 0
    covered_obj = 0
    obj_items = sorted(obj_instructions.items())
    obj_index = 0
    obj_count = len(obj_items)

    for start, end in merge_static_fallback_ranges(ranges):
        while obj_index < obj_count and obj_items[obj_index][0] < start:
            obj_index += 1
        while obj_index < obj_count:
            addr, obj_ins = obj_items[obj_index]
            if addr >= end:
                break
            covered_obj += 1
            if addr in ll_instructions:
                obj_index += 1
                continue
            ll_instructions[addr] = obj_ins
            added += 1
            obj_index += 1

    return {"added": added, "covered_obj": covered_obj, "range_count": len(ranges)}


def describe_scope(text_end, include_pcs):
    if include_pcs is not None:
        return "pc_whitelist"
    if text_end is not None:
        return "text_range"
    return "full_text"


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
        f"scope_kind={payload['scope_kind']}",
        f"text_start=0x{payload['text_start']:x}",
        f"text_end={hex(payload['text_end']) if payload['text_end'] is not None else 'None'}",
        f"runnable_base=0x{payload['runnable_base']:x}",
        f"include_pc_count={payload['include_pc_count']}",
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
    static_fallback = payload.get("static_fallback", {})
    if static_fallback.get("enabled"):
        lines.extend(
            [
                "static_fallback=true",
                "static_fallback_profiles="
                + ",".join(str(item) for item in static_fallback.get("profiles", [])),
                "static_fallback_symbol_regexes="
                + ",".join(str(item) for item in static_fallback.get("symbol_regexes", [])),
                f"static_fallback_range_count={static_fallback.get('range_count', 0)}",
                f"static_fallback_covered_obj={static_fallback.get('covered_obj', 0)}",
                f"static_fallback_added={static_fallback.get('added', 0)}",
            ]
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def build_payload(
    sample_base,
    binary,
    ll,
    text_start,
    text_end,
    runnable_base,
    include_pcs,
    examples,
    result,
    static_fallback=None,
):
    return {
        "sample_base": str(sample_base) if sample_base is not None else None,
        "binary": str(binary),
        "ll": str(ll),
        "source": "fresh_compare_runnable_text",
        "scope_kind": describe_scope(text_end, include_pcs),
        "text_start": text_start,
        "text_end": text_end,
        "runnable_base": runnable_base,
        "include_pc_count": len(include_pcs) if include_pcs is not None else 0,
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
        "static_fallback": static_fallback or {
            "enabled": False,
            "symbol_regexes": [],
            "range_count": 0,
            "added": 0,
            "covered_obj": 0,
            "ranges": [],
        },
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
        "--text-end",
        help="Exclusive upper bound for binary virtual addresses to include. Omit to compare through the end of .text.",
    )
    ap.add_argument(
        "--runnable-base",
        default="auto",
        help="Base to subtract from ll addresses. Use 'auto' or an integer like 0x50000000.",
    )
    ap.add_argument(
        "--include-pc-file",
        help="Optional newline-delimited exact guest PC whitelist. Accepts decimal or 0x-prefixed integers.",
    )
    ap.add_argument(
        "--static-fallback-symbol-regex",
        action="append",
        default=[],
        help=(
            "Opt-in static mnemonic fallback. For ELF FUNC symbols whose name matches this regex, "
            "fill missing .ll addresses from objdump mnemonics before comparing. May be repeated."
        ),
    )
    ap.add_argument(
        "--static-fallback-profile",
        action="append",
        choices=static_fallback_profile_choices(),
        default=[],
        help="Named static mnemonic fallback profile. May be repeated.",
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
    text_end = parse_optional_int(args.text_end)
    if text_end is not None and text_end <= text_start:
        print("--text-end must be greater than --text-start", file=sys.stderr)
        return 2

    include_pcs = None
    if args.include_pc_file:
        include_pc_file = Path(args.include_pc_file).resolve()
        if not include_pc_file.exists():
            print(str(include_pc_file), file=sys.stderr)
            return 2
        include_pcs = load_include_pcs(include_pc_file)

    if args.runnable_base == "auto":
        runnable_base = detect_runnable_base(binary, ll, text_start)
    else:
        runnable_base = parse_int(args.runnable_base)

    obj_instructions = compare_text.parse_objdump(binary, text_start, text_end=text_end, include_pcs=include_pcs)
    ll_raw = compare_text.parse_ll_raw(ll, include_address_markers=include_pcs is not None)
    ll_instructions = compare_text.normalize_ll_addresses(
        ll_raw,
        text_start,
        runnable_base,
        text_end=text_end,
        include_pcs=include_pcs,
    )
    try:
        static_fallback_regexes, static_fallback_all_text = expand_static_fallback_options(
            args.static_fallback_profile,
            args.static_fallback_symbol_regex,
        )
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    static_fallback = {
        "enabled": False,
        "profiles": list(args.static_fallback_profile),
        "symbol_regexes": list(static_fallback_regexes),
        "range_count": 0,
        "added": 0,
        "covered_obj": 0,
        "ranges": [],
    }
    if static_fallback_regexes or static_fallback_all_text:
        ranges = collect_static_fallback_ranges(
            binary,
            obj_instructions,
            static_fallback_regexes,
            static_fallback_all_text,
        )
        stats = apply_static_fallback(obj_instructions, ll_instructions, ranges)
        static_fallback.update(
            {
                "enabled": True,
                "range_count": stats["range_count"],
                "added": stats["added"],
                "covered_obj": stats["covered_obj"],
                "ranges": [
                    {
                        "name": item["name"],
                        "start": hex(item["start"]),
                        "end": hex(item["end"]),
                        "size": item["size"],
                    }
                    for item in ranges
                ],
            }
        )
    result = compare_text.compare(obj_instructions, ll_instructions, args.examples)

    payload = build_payload(
        sample_base,
        binary,
        ll,
        text_start,
        text_end,
        runnable_base,
        include_pcs,
        args.examples,
        result,
        static_fallback=static_fallback,
    )

    if args.json_out:
        json_path = Path(args.json_out).resolve()
        json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if args.text_out:
        write_text_summary(Path(args.text_out).resolve(), payload)

    print(f"sample_base={payload['sample_base']}")
    print(f"binary={payload['binary']}")
    print(f"ll={payload['ll']}")
    print(f"source={payload['source']}")
    print(f"scope_kind={payload['scope_kind']}")
    print(f"text_start=0x{payload['text_start']:x}")
    print(f"text_end={hex(payload['text_end']) if payload['text_end'] is not None else 'None'}")
    print(f"runnable_base=0x{payload['runnable_base']:x}")
    print(f"include_pc_count={payload['include_pc_count']}")
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
    if payload["static_fallback"]["enabled"]:
        print(f"static_fallback_symbol_regexes={','.join(payload['static_fallback']['symbol_regexes'])}")
        print(f"static_fallback_range_count={payload['static_fallback']['range_count']}")
        print(f"static_fallback_covered_obj={payload['static_fallback']['covered_obj']}")
        print(f"static_fallback_added={payload['static_fallback']['added']}")
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
