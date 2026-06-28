#!/usr/bin/env python3
"""Build a PTC v2 opcode/schema manifest from QEMU v2 TCG inventory JSON."""

from __future__ import annotations

import argparse
import collections
import datetime as _datetime
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_INVENTORY = Path(
    "/tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-combined.ptc-inventory.json"
)
DEFAULT_WALKER_JSONL = Path(
    "/tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-vex.tcg-op-walk.jsonl"
)
DEFAULT_TMP_DIR = Path("/tmp/rr-qemu-v2-ptc-v2-manifest")
DEFAULT_INVENTORY_TOOL = REPO_ROOT / "runnable" / "scripts" / "qemu_v2_tcg_dump_ptc_inventory.py"
DEFAULT_LEGACY_OPC = REPO_ROOT / "archive" / "qemu-legacy-2.4.50" / "tcg" / "tcg-opc.h"

MANIFEST_SCHEMA = "qemu-v2-ptc-v2-opcode-schema-manifest-v1"
INVENTORY_SCHEMA = "qemu-v2-tcg-ptc-inventory-v3"

CATEGORY_ORDER = ("direct", "alias", "v2-op", "vector-schema", "unknown")
COMPATIBILITY_TO_CATEGORY = {
    "direct": "direct",
    "alias": "alias",
    "requires-ptc-v2-op": "v2-op",
    "requires-operand-schema": "vector-schema",
    "unknown": "unknown",
}

TCG_TYPE_INFO = {
    0: {"name": "TCG_TYPE_I32", "abi": "i32", "bits": 32, "kind": "scalar"},
    1: {"name": "TCG_TYPE_I64", "abi": "i64", "bits": 64, "kind": "scalar"},
    2: {"name": "TCG_TYPE_I128", "abi": "i128", "bits": 128, "kind": "scalar"},
    3: {"name": "TCG_TYPE_V64", "abi": "v64", "bits": 64, "kind": "vector"},
    4: {"name": "TCG_TYPE_V128", "abi": "v128", "bits": 128, "kind": "vector"},
    5: {"name": "TCG_TYPE_V256", "abi": "v256", "bits": 256, "kind": "vector"},
}

MEMOP_SIZE_INFO = {
    0: {"name": "MO_8", "abi": "e8", "bits": 8},
    1: {"name": "MO_16", "abi": "e16", "bits": 16},
    2: {"name": "MO_32", "abi": "e32", "bits": 32},
    3: {"name": "MO_64", "abi": "e64", "bits": 64},
    4: {"name": "MO_128", "abi": "e128", "bits": 128},
    5: {"name": "MO_256", "abi": "e256", "bits": 256},
    6: {"name": "MO_512", "abi": "e512", "bits": 512},
    7: {"name": "MO_1024", "abi": "e1024", "bits": 1024},
}

TCG_OP_FLAGS = (
    (0x001, "TCG_OPF_BB_EXIT"),
    (0x002, "TCG_OPF_BB_END"),
    (0x004, "TCG_OPF_CALL_CLOBBER"),
    (0x008, "TCG_OPF_SIDE_EFFECTS"),
    (0x010, "TCG_OPF_INT"),
    (0x020, "TCG_OPF_NOT_PRESENT"),
    (0x040, "TCG_OPF_VECTOR"),
    (0x080, "TCG_OPF_COND_BRANCH"),
    (0x100, "TCG_OPF_CARRY_OUT"),
    (0x200, "TCG_OPF_CARRY_IN"),
)

V2_OPCODE_PROPOSALS = {
    "extract_i64": {
        "ptc_v2_opcode": "PTC_OP_EXTRACT_I64",
        "def_name": "extract_i64",
        "fallback_def": (1, 1, 2, "TCG_OPF_INT"),
        "operands": [
            {"index": 0, "role": "dst", "kind": "tcg-temp", "type": "i64"},
            {"index": 1, "role": "src", "kind": "tcg-temp", "type": "i64"},
            {"index": 2, "role": "offset", "kind": "constant", "unit": "bit"},
            {"index": 3, "role": "length", "kind": "constant", "unit": "bit"},
        ],
        "note": (
            "Modern walker reports raw opcode extract with TCG_TYPE_I64 in param1; "
            "the manifest canonicalizes that to extract_i64 for the PTC v2 ABI."
        ),
    },
    "sextract_i64": {
        "ptc_v2_opcode": "PTC_OP_SEXTRACT_I64",
        "def_name": "sextract_i64",
        "fallback_def": (1, 1, 2, "TCG_OPF_INT"),
        "operands": [
            {"index": 0, "role": "dst", "kind": "tcg-temp", "type": "i64"},
            {"index": 1, "role": "src", "kind": "tcg-temp", "type": "i64"},
            {"index": 2, "role": "offset", "kind": "constant", "unit": "bit"},
            {"index": 3, "role": "length", "kind": "constant", "unit": "bit"},
        ],
        "note": (
            "Modern walker reports raw opcode sextract with TCG_TYPE_I64 in "
            "param1; the manifest canonicalizes that to sextract_i64 for the "
            "PTC v2 ABI. Offset-zero slices are lowered by the materializer to "
            "legacy signed-extension ops."
        ),
    },
    "sextract_i32": {
        "ptc_v2_opcode": "PTC_OP_SEXTRACT_I32",
        "def_name": "sextract_i32",
        "fallback_def": (1, 1, 2, "TCG_OPF_INT"),
        "operands": [
            {"index": 0, "role": "dst", "kind": "tcg-temp", "type": "i32"},
            {"index": 1, "role": "src", "kind": "tcg-temp", "type": "i32"},
            {"index": 2, "role": "offset", "kind": "constant", "unit": "bit"},
            {"index": 3, "role": "length", "kind": "constant", "unit": "bit"},
        ],
        "note": (
            "Modern walker reports raw opcode sextract with TCG_TYPE_I32 in "
            "param1; offset-zero slices are lowered by the materializer to "
            "legacy signed-extension ops when a matching legacy opcode exists."
        ),
    },
    "qemu_ld2": {
        "ptc_v2_opcode": "PTC_OP_QEMU_LD2",
        "def_name": "qemu_ld2",
        "fallback_def": (
            2,
            1,
            1,
            "TCG_OPF_CALL_CLOBBER | TCG_OPF_SIDE_EFFECTS | TCG_OPF_INT",
        ),
        "operands": [
            {"index": 0, "role": "dst_lo", "kind": "tcg-temp", "type": "i64-part"},
            {"index": 1, "role": "dst_hi", "kind": "tcg-temp", "type": "i64-part"},
            {"index": 2, "role": "addr", "kind": "tcg-temp", "type": "target-address"},
            {"index": 3, "role": "memop_idx", "kind": "constant", "type": "MemOpIdx"},
        ],
        "note": (
            "Paired qemu memory load needs a distinct ABI entry; lowering to scalar "
            "qemu_ld_i* would be a separate semantic proof, not a safe alias."
        ),
    },
    "qemu_st2": {
        "ptc_v2_opcode": "PTC_OP_QEMU_ST2",
        "def_name": "qemu_st2",
        "fallback_def": (
            0,
            3,
            1,
            "TCG_OPF_CALL_CLOBBER | TCG_OPF_SIDE_EFFECTS | TCG_OPF_INT",
        ),
        "operands": [
            {"index": 0, "role": "src_lo", "kind": "tcg-temp", "type": "i64-part"},
            {"index": 1, "role": "src_hi", "kind": "tcg-temp", "type": "i64-part"},
            {"index": 2, "role": "addr", "kind": "tcg-temp", "type": "target-address"},
            {"index": 3, "role": "memop_idx", "kind": "constant", "type": "MemOpIdx"},
        ],
        "note": (
            "Paired qemu memory store needs a distinct ABI entry; lowering to scalar "
            "qemu_st_i* would be a separate semantic proof, not a safe alias."
        ),
    },
}

VECTOR_SCHEMA_PROPOSALS = {
    "mov_vec": {
        "ptc_v2_opcode": "PTC_OP_MOV_VEC",
        "operands": [
            {"index": 0, "role": "dst", "kind": "tcg-temp-vector", "type": "param1"},
            {"index": 1, "role": "src", "kind": "tcg-temp-vector", "type": "param1"},
        ],
        "note": "Whole-vector move; no lane index operand is expected.",
    },
    "ld_vec": {
        "ptc_v2_opcode": "PTC_OP_LD_VEC",
        "operands": [
            {"index": 0, "role": "dst", "kind": "tcg-temp-vector", "type": "param1"},
            {"index": 1, "role": "base", "kind": "tcg-temp", "type": "host-pointer"},
            {"index": 2, "role": "offset", "kind": "constant", "unit": "byte"},
        ],
        "note": "Whole-vector load; vector type and element size are carried by params.",
    },
    "st_vec": {
        "ptc_v2_opcode": "PTC_OP_ST_VEC",
        "operands": [
            {"index": 0, "role": "src", "kind": "tcg-temp-vector", "type": "param1"},
            {"index": 1, "role": "base", "kind": "tcg-temp", "type": "host-pointer"},
            {"index": 2, "role": "offset", "kind": "constant", "unit": "byte"},
        ],
        "note": "Whole-vector store; vector type and element size are carried by params.",
    },
}


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate a reviewable PTC v2 opcode/schema manifest from the "
            "QEMU v2 PTC inventory JSON and, when available, walker JSONL evidence."
        )
    )
    parser.add_argument(
        "--inventory",
        type=Path,
        default=DEFAULT_INVENTORY,
        help=f"inventory JSON input (default: {DEFAULT_INVENTORY})",
    )
    parser.add_argument(
        "--walker-jsonl",
        action="append",
        type=Path,
        default=[],
        help="walker JSONL evidence; may be passed more than once",
    )
    parser.add_argument(
        "--source-filter",
        choices=("auto", "walker-jsonl", "inventory"),
        default="auto",
        help=(
            "auto uses walker JSONL evidence when available, otherwise inventory "
            "aggregate counts; walker-jsonl requires walker evidence"
        ),
    )
    parser.add_argument(
        "--inventory-tool",
        type=Path,
        default=DEFAULT_INVENTORY_TOOL,
        help=f"inventory tool used only when --inventory is missing (default: {DEFAULT_INVENTORY_TOOL})",
    )
    parser.add_argument(
        "--legacy-opc",
        type=Path,
        default=DEFAULT_LEGACY_OPC,
        help=f"legacy tcg-opc.h path for fallback inventory generation (default: {DEFAULT_LEGACY_OPC})",
    )
    parser.add_argument(
        "--tmp-dir",
        type=Path,
        default=DEFAULT_TMP_DIR,
        help=f"fallback/generated output directory (default: {DEFAULT_TMP_DIR})",
    )
    parser.add_argument("--json-out", type=Path, help="write JSON manifest to this path")
    parser.add_argument("--header-out", type=Path, help="write ptc-v2-opc.h proposal to this path")
    return parser.parse_args(argv)


def load_json_file(path: Path) -> dict[str, Any]:
    with path.open() as stream:
        data = json.load(stream)
    if not isinstance(data, dict):
        raise SystemExit(f"inventory JSON is not an object: {path}")
    return data


def ensure_inventory(args: argparse.Namespace) -> tuple[Path, list[dict[str, Any]]]:
    if args.inventory.is_file():
        return args.inventory, []

    walker_paths = [path for path in args.walker_jsonl if path.is_file()]
    if not walker_paths and DEFAULT_WALKER_JSONL.is_file():
        walker_paths = [DEFAULT_WALKER_JSONL]
    if not walker_paths:
        raise SystemExit(
            "inventory JSON does not exist and no walker JSONL evidence is available: "
            f"{args.inventory}"
        )
    if not args.inventory_tool.is_file():
        raise SystemExit(f"inventory fallback tool does not exist: {args.inventory_tool}")
    if not args.legacy_opc.is_file():
        raise SystemExit(f"legacy opcode file does not exist: {args.legacy_opc}")

    args.tmp_dir.mkdir(parents=True, exist_ok=True)
    generated_json = args.tmp_dir / "derived.ptc-inventory.json"
    generated_md = args.tmp_dir / "derived.ptc-inventory.md"
    cmd = [
        sys.executable,
        str(args.inventory_tool),
        "--legacy-opc",
        str(args.legacy_opc),
        "--json-out",
        str(generated_json),
        "--markdown-out",
        str(generated_md),
    ]
    for walker_path in walker_paths:
        cmd.extend(["--walker-jsonl", str(walker_path)])

    completed = subprocess.run(cmd, text=True, capture_output=True, check=False)
    event = {
        "reason": "inventory-missing",
        "command": cmd,
        "returncode": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
        "generated_inventory": str(generated_json),
        "generated_markdown": str(generated_md),
    }
    if completed.returncode != 0:
        raise SystemExit(
            "fallback inventory generation failed with return code "
            f"{completed.returncode}: {completed.stderr.strip()}"
        )
    if not generated_json.is_file():
        raise SystemExit(f"fallback inventory tool did not create JSON: {generated_json}")
    return generated_json, [event]


def inventory_op_reports(inventory: dict[str, Any]) -> dict[str, dict[str, Any]]:
    reports: dict[str, dict[str, Any]] = {}
    for item in inventory.get("opcodes", []):
        if isinstance(item, dict) and isinstance(item.get("name"), str):
            reports[item["name"]] = item
    return reports


def inventory_walker_paths(inventory: dict[str, Any]) -> list[Path]:
    paths: list[Path] = []
    for key in ("inputs", "dumps"):
        for item in inventory.get(key, []):
            if not isinstance(item, dict):
                continue
            if item.get("source_type") != "walker-jsonl":
                continue
            raw_path = item.get("path")
            if isinstance(raw_path, str):
                path = Path(raw_path)
                if path.is_file() and path not in paths:
                    paths.append(path)
    return paths


def read_walker_records(paths: list[Path]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    records: list[dict[str, Any]] = []
    stats: list[dict[str, Any]] = []
    for path in paths:
        file_stats = {
            "path": str(path),
            "json_lines": 0,
            "op_records": 0,
            "metadata_records": 0,
            "skipped_records": [],
        }
        with path.open() as stream:
            for line_number, line in enumerate(stream, start=1):
                stripped = line.strip()
                if not stripped:
                    continue
                file_stats["json_lines"] += 1
                try:
                    record = json.loads(stripped)
                except json.JSONDecodeError as error:
                    file_stats["skipped_records"].append(
                        {"line": line_number, "reason": f"invalid JSON: {error.msg}"}
                    )
                    continue
                if not isinstance(record, dict):
                    file_stats["skipped_records"].append(
                        {"line": line_number, "reason": "record is not an object"}
                    )
                    continue
                if record.get("event") == "op" and isinstance(record.get("name"), str):
                    record["_source_file"] = str(path)
                    records.append(record)
                    file_stats["op_records"] += 1
                else:
                    file_stats["metadata_records"] += 1
        stats.append(file_stats)
    return records, stats


def decode_tcg_type(value: Any) -> dict[str, Any]:
    if not isinstance(value, int):
        return {"raw": value, "name": "unknown", "abi": "unknown", "bits": None, "kind": "unknown"}
    info = TCG_TYPE_INFO.get(value)
    if not info:
        return {"raw": value, "name": f"unknown({value})", "abi": "unknown", "bits": None, "kind": "unknown"}
    return {"raw": value, **info}


def decode_memop_size(value: Any) -> dict[str, Any]:
    if not isinstance(value, int):
        return {"raw": value, "name": "unknown", "abi": "unknown", "bits": None}
    info = MEMOP_SIZE_INFO.get(value & 0x7)
    if not info:
        return {"raw": value, "name": f"unknown({value})", "abi": "unknown", "bits": None}
    return {"raw": value, **info}


def decode_flags(value: Any) -> dict[str, Any]:
    if not isinstance(value, int):
        return {"raw": value, "names": [], "expr": "unknown"}
    names = [name for bit, name in TCG_OP_FLAGS if value & bit]
    unknown_bits = value & ~sum(bit for bit, _ in TCG_OP_FLAGS)
    if unknown_bits:
        names.append(hex(unknown_bits))
    return {"raw": value, "names": names, "expr": " | ".join(names) if names else "0"}


def canonical_name(raw_name: str, record: dict[str, Any] | None) -> str:
    if raw_name in {"extract", "sextract"} and record:
        tcg_type = decode_tcg_type(record.get("param1"))
        if tcg_type.get("abi") in {"i32", "i64", "i128"}:
            return f"{raw_name}_{tcg_type['abi']}"
    return raw_name


def category_for_report(report: dict[str, Any] | None) -> str:
    if not report:
        return "unknown"
    return COMPATIBILITY_TO_CATEGORY.get(str(report.get("compatibility", "unknown")), "unknown")


def arities_from_reports(reports: list[dict[str, Any]]) -> list[dict[str, int]]:
    counter: collections.Counter[int] = collections.Counter()
    for report in reports:
        for item in report.get("visible_arities", []):
            if isinstance(item, dict) and isinstance(item.get("arity"), int):
                counter[item["arity"]] += int(item.get("count", 0) or 0)
    return [{"arity": arity, "count": count} for arity, count in sorted(counter.items())]


def arities_from_records(records: list[dict[str, Any]]) -> list[dict[str, int]]:
    counter: collections.Counter[int] = collections.Counter()
    for record in records:
        value = record.get("arg_count")
        if not isinstance(value, int):
            args = record.get("args")
            value = len(args) if isinstance(args, list) else None
        if isinstance(value, int):
            counter[value] += 1
    return [{"arity": arity, "count": count} for arity, count in sorted(counter.items())]


def def_line_from_record(name: str, record: dict[str, Any] | None, fallback: tuple[int, int, int, str]) -> str:
    if record:
        fields = (record.get("def_oargs"), record.get("def_iargs"), record.get("def_cargs"))
        if all(isinstance(field, int) for field in fields):
            flags = decode_flags(record.get("def_flags"))["expr"]
            return f"DEF({name}, {fields[0]}, {fields[1]}, {fields[2]}, {flags})"
    oargs, iargs, cargs, flags = fallback
    return f"DEF({name}, {oargs}, {iargs}, {cargs}, {flags})"


def compact_sample(record: dict[str, Any] | None, report: dict[str, Any] | None) -> Any:
    if record:
        keys = (
            "name",
            "op_index",
            "def_oargs",
            "def_iargs",
            "def_cargs",
            "def_flags",
            "arg_count",
            "param1",
            "param2",
            "args",
        )
        return {key: record[key] for key in keys if key in record}
    if report:
        return report.get("sample", "")
    return ""


def observed_param_variants(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    counter: collections.Counter[tuple[Any, Any, Any, Any, Any, Any, Any]] = collections.Counter()
    for record in records:
        key = (
            record.get("param1"),
            record.get("param2"),
            record.get("def_oargs"),
            record.get("def_iargs"),
            record.get("def_cargs"),
            record.get("def_flags"),
            record.get("arg_count"),
        )
        counter[key] += 1

    variants: list[dict[str, Any]] = []
    for (param1, param2, oargs, iargs, cargs, flags, arg_count), count in sorted(
        counter.items(), key=lambda item: (-item[1], str(item[0]))
    ):
        vector_type = decode_tcg_type(param1)
        element = decode_memop_size(param2)
        lane_count = None
        if vector_type.get("kind") == "vector" and vector_type.get("bits") and element.get("bits"):
            lane_count = vector_type["bits"] // element["bits"]
        variants.append(
            {
                "count": count,
                "param1": param1,
                "param1_decoded": vector_type,
                "param2": param2,
                "param2_decoded_as_memop_size": element,
                "lane_count": lane_count,
                "def_oargs": oargs,
                "def_iargs": iargs,
                "def_cargs": cargs,
                "def_flags": decode_flags(flags),
                "arg_count": arg_count,
            }
        )
    return variants


def select_primary_record(records: list[dict[str, Any]]) -> dict[str, Any] | None:
    if not records:
        return None
    return sorted(records, key=lambda record: (str(record.get("_source_file", "")), int(record.get("op_index", 0))))[0]


def build_groups_from_walker(
    records: list[dict[str, Any]],
    reports_by_name: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    grouped: dict[str, dict[str, Any]] = {}
    for record in records:
        raw_name = str(record["name"])
        name = canonical_name(raw_name, record)
        report = reports_by_name.get(raw_name) or reports_by_name.get(name)
        category = category_for_report(report)
        group = grouped.setdefault(
            name,
            {
                "name": name,
                "category": category,
                "records": [],
                "raw_names": collections.Counter(),
                "reports": [],
            },
        )
        group["records"].append(record)
        group["raw_names"][raw_name] += 1
        if report and report not in group["reports"]:
            group["reports"].append(report)
        if group["category"] == "unknown" and category != "unknown":
            group["category"] = category
    return list(grouped.values())


def build_groups_from_inventory(reports_by_name: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    groups: list[dict[str, Any]] = []
    for raw_name, report in reports_by_name.items():
        name = canonical_name(raw_name, None)
        groups.append(
            {
                "name": name,
                "category": category_for_report(report),
                "records": [],
                "raw_names": collections.Counter({raw_name: int(report.get("count", 0) or 0)}),
                "reports": [report],
            }
        )
    return groups


def legacy_candidates(reports: list[dict[str, Any]]) -> list[str]:
    candidates: list[str] = []
    for report in reports:
        for item in report.get("legacy", []):
            if isinstance(item, str) and item not in candidates:
                candidates.append(item)
    return candidates


def common_entry(group: dict[str, Any]) -> dict[str, Any]:
    records = group["records"]
    reports = group["reports"]
    count = len(records) if records else sum(group["raw_names"].values())
    files = sorted(
        {record.get("_source_file") for record in records if isinstance(record.get("_source_file"), str)}
        | {file for report in reports for file in report.get("files", []) if isinstance(file, str)}
    )
    return {
        "name": group["name"],
        "observed_names": [
            {"name": name, "count": count}
            for name, count in sorted(group["raw_names"].items(), key=lambda item: item[0])
        ],
        "count": count,
        "source_files": files,
        "visible_arities": arities_from_records(records) if records else arities_from_reports(reports),
        "sample": compact_sample(select_primary_record(records), reports[0] if reports else None),
    }


def direct_entry(group: dict[str, Any]) -> dict[str, Any]:
    entry = common_entry(group)
    entry.update(
        {
            "converter_action": "direct-emit",
            "proposal": False,
            "legacy_opcode": group["name"],
            "legacy_candidates": legacy_candidates(group["reports"]) or [group["name"]],
            "safe_legacy_mapping": True,
        }
    )
    return entry


def alias_entry(group: dict[str, Any]) -> dict[str, Any]:
    entry = common_entry(group)
    reports = group["reports"]
    entry.update(
        {
            "converter_action": "select-typed-legacy-op-or-reject",
            "proposal": False,
            "legacy_candidates": legacy_candidates(reports),
            "safe_legacy_mapping": any(bool(report.get("safe_legacy_mapping")) for report in reports),
            "note": (
                "Alias entries are admission decisions only; the converter still "
                "must inspect operand type/shape before emitting a legacy opcode."
            ),
        }
    )
    return entry


def v2_opcode_entry(group: dict[str, Any]) -> dict[str, Any]:
    name = group["name"]
    records = group["records"]
    reports = group["reports"]
    primary = select_primary_record(records)
    proposal = V2_OPCODE_PROPOSALS.get(name)
    fallback_def = proposal["fallback_def"] if proposal else (0, 0, 0, "0")
    def_name = proposal["def_name"] if proposal else name
    report_opcode = next(
        (report.get("proposed_ptc_v2_opcode") for report in reports if report.get("proposed_ptc_v2_opcode")),
        "",
    )
    entry = common_entry(group)
    param_variants = observed_param_variants(records)
    entry.update(
        {
            "converter_action": "emit-ptc-v2-opcode-or-reject",
            "proposal": True,
            "proposal_status": "proposal-not-legacy-abi-replacement",
            "ptc_v2_opcode": proposal["ptc_v2_opcode"] if proposal else report_opcode,
            "def_line": def_line_from_record(def_name, primary, fallback_def),
            "operand_schema": proposal["operands"] if proposal else [],
            "observed_param_variants": param_variants,
            "note": proposal["note"] if proposal else "No built-in schema proposal; inspect before converter use.",
        }
    )
    return entry


def vector_schema_entry(group: dict[str, Any]) -> dict[str, Any]:
    name = group["name"]
    proposal = VECTOR_SCHEMA_PROPOSALS.get(name, {})
    records = group["records"]
    reports = group["reports"]
    report_opcode = next(
        (report.get("proposed_ptc_v2_opcode") for report in reports if report.get("proposed_ptc_v2_opcode")),
        "",
    )
    entry = common_entry(group)
    entry.update(
        {
            "converter_action": "apply-vector-operand-schema-or-reject",
            "proposal": True,
            "proposal_status": "operand-schema-proposal-not-legacy-abi-replacement",
            "ptc_v2_opcode": proposal.get("ptc_v2_opcode") or report_opcode,
            "schema_fields": {
                "vector_size": {
                    "source": "walker param1 / TCGOP_TYPE(op)",
                    "decoded_from": "TCG_TYPE_V64/TCG_TYPE_V128/TCG_TYPE_V256",
                },
                "element_size": {
                    "source": "walker param2 / TCGOP_VECE(op)",
                    "decoded_from": "MO_8/MO_16/MO_32/MO_64",
                },
                "lane_count": {
                    "source": "derived",
                    "formula": "vector_size_bits / element_bits",
                },
                "lane_index": {
                    "source": "not present for observed whole-vector move/load/store ops",
                    "value": None,
                },
            },
            "operand_schema": proposal.get("operands", []),
            "observed_vector_shapes": observed_param_variants(records),
            "missing_walker_fields": [
                "raw TCGArg values are not decoded into stable temp IDs or global/env names",
                "register allocation and host register class are not represented",
                "lane index is absent because observed mov_vec/ld_vec/st_vec operate on whole vectors",
            ],
            "note": proposal.get("note", "Vector op needs an explicit operand schema before conversion."),
        }
    )
    return entry


def unknown_entry(group: dict[str, Any]) -> dict[str, Any]:
    entry = common_entry(group)
    entry.update(
        {
            "converter_action": "reject",
            "proposal": False,
            "note": "No compatibility rule exists; reject until semantics and operands are specified.",
        }
    )
    return entry


def build_manifest(
    *,
    inventory_path: Path,
    inventory: dict[str, Any],
    fallback_events: list[dict[str, Any]],
    source_mode: str,
    walker_paths: list[Path],
    walker_stats: list[dict[str, Any]],
    groups: list[dict[str, Any]],
) -> dict[str, Any]:
    categories: dict[str, list[dict[str, Any]]] = {category: [] for category in CATEGORY_ORDER}
    builders = {
        "direct": direct_entry,
        "alias": alias_entry,
        "v2-op": v2_opcode_entry,
        "vector-schema": vector_schema_entry,
        "unknown": unknown_entry,
    }
    for group in sorted(groups, key=lambda item: (CATEGORY_ORDER.index(item["category"]), item["name"])):
        category = group["category"] if group["category"] in categories else "unknown"
        categories[category].append(builders[category](group))

    summary = {
        category: {
            "names": len(entries),
            "occurrences": sum(int(entry.get("count", 0)) for entry in entries),
        }
        for category, entries in categories.items()
    }
    v2_proposals = [entry for entry in categories["v2-op"] if entry.get("proposal")]
    vector_proposals = [entry for entry in categories["vector-schema"] if entry.get("proposal")]

    return {
        "schema": MANIFEST_SCHEMA,
        "generated_at_utc": _datetime.datetime.now(_datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat(),
        "abi_policy": {
            "status": "proposal",
            "translation_implemented": False,
            "not_legacy_abi_replacement": True,
            "statement": (
                "This manifest is an ABI input contract for a future C-side "
                "TCGOp -> PTCInstructionList converter. It does not translate TCG ops."
            ),
            "converter_decisions": [
                "direct: emit the legacy opcode only when operands fit the legacy ABI",
                "alias: select a typed legacy opcode from operands or reject",
                "v2-op: emit the proposed PTC v2 opcode or reject",
                "vector-schema: apply the proposed vector operand schema or reject",
                "unknown: reject",
            ],
        },
        "source": {
            "inventory_json": str(inventory_path),
            "inventory_schema": inventory.get("schema"),
            "source_mode": source_mode,
            "walker_jsonl": [str(path) for path in walker_paths],
            "walker_stats": walker_stats,
            "fallback_events": fallback_events,
            "note": (
                "source_mode=walker-jsonl is the AVX2 walker-only view; inventory mode "
                "uses the aggregate inventory counts and can include text dump records."
            ),
        },
        "schema_limits": {
            "tcg_type_decode": TCG_TYPE_INFO,
            "memop_size_decode": MEMOP_SIZE_INFO,
            "flag_decode": [{"bit": bit, "name": name} for bit, name in TCG_OP_FLAGS],
            "walker_limitations": [
                "walker params are decoded by QEMU 10.2 TCG conventions, not by a stable public ABI",
                "raw args are preserved as evidence but are not yet a PTCInstructionList encoding",
            ],
        },
        "summary": summary,
        "categories": categories,
        "v2_opcode_proposals": v2_proposals,
        "vector_operand_schema_proposals": vector_proposals,
    }


def render_header(manifest: dict[str, Any]) -> str:
    lines = [
        "/*",
        " * PTC v2 opcode proposal generated from walker/inventory evidence.",
        " * This is not a drop-in replacement for the legacy PTC opcode ABI.",
        " * See the JSON manifest for operand schemas and reject/direct/alias policy.",
        " */",
        "#ifndef RR_PTC_V2_OPC_H",
        "#define RR_PTC_V2_OPC_H",
        "",
        "/* Proposed new PTC v2 opcode DEF(name, oargs, iargs, cargs, flags) lines. */",
    ]
    proposals = manifest.get("v2_opcode_proposals", [])
    if not proposals:
        lines.append("/* None. */")
    for entry in proposals:
        lines.append(str(entry["def_line"]))
    lines.extend(
        [
            "",
            "/*",
            " * Vector entries are intentionally schema proposals in the JSON manifest,",
            " * not standalone legacy-compatible DEF replacements.",
            " */",
            "",
            "#endif /* RR_PTC_V2_OPC_H */",
            "",
        ]
    )
    return "\n".join(lines)


def choose_source_mode(
    requested: str,
    inventory: dict[str, Any],
    cli_walker_paths: list[Path],
) -> tuple[str, list[Path]]:
    walker_paths: list[Path] = []
    for path in inventory_walker_paths(inventory) + cli_walker_paths:
        if path.is_file() and path not in walker_paths:
            walker_paths.append(path)

    if requested == "inventory":
        return "inventory", []
    if requested == "walker-jsonl":
        if not walker_paths:
            raise SystemExit("source-filter walker-jsonl requested but no readable walker JSONL was found")
        return "walker-jsonl", walker_paths
    if walker_paths:
        return "walker-jsonl", walker_paths
    return "inventory", []


def print_summary(manifest: dict[str, Any]) -> None:
    summary = manifest["summary"]
    print(f"manifest schema: {manifest['schema']}")
    print(f"source mode: {manifest['source']['source_mode']}")
    for category in CATEGORY_ORDER:
        item = summary[category]
        print(f"{category}: {item['names']} names / {item['occurrences']} occurrences")


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    inventory_path, fallback_events = ensure_inventory(args)
    inventory = load_json_file(inventory_path)
    if inventory.get("schema") != INVENTORY_SCHEMA:
        print(
            f"warning: expected inventory schema {INVENTORY_SCHEMA}, got {inventory.get('schema')!r}",
            file=sys.stderr,
        )
    reports_by_name = inventory_op_reports(inventory)
    source_mode, walker_paths = choose_source_mode(args.source_filter, inventory, args.walker_jsonl)

    walker_stats: list[dict[str, Any]] = []
    if source_mode == "walker-jsonl":
        records, walker_stats = read_walker_records(walker_paths)
        groups = build_groups_from_walker(records, reports_by_name)
    else:
        groups = build_groups_from_inventory(reports_by_name)

    manifest = build_manifest(
        inventory_path=inventory_path,
        inventory=inventory,
        fallback_events=fallback_events,
        source_mode=source_mode,
        walker_paths=walker_paths,
        walker_stats=walker_stats,
        groups=groups,
    )

    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(manifest, indent=2) + "\n")
    else:
        print(json.dumps(manifest, indent=2))

    if args.header_out:
        args.header_out.parent.mkdir(parents=True, exist_ok=True)
        args.header_out.write_text(render_header(manifest))

    if args.json_out or args.header_out:
        print_summary(manifest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
