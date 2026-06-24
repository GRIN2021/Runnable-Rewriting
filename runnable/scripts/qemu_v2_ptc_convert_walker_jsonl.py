#!/usr/bin/env python3
"""Convert QEMU v2 TCG walker JSONL into a PTCInstructionList-like model.

This is a manifest-driven behavior prototype.  It validates the
direct/alias/v2/vector/reject decision chain before the real C-side
TCGOp -> PTCInstructionList converter exists, and can also project walker
temp records into a PTCTemp-like table.  The JSON it writes is intentionally
not a runnable-lift consumable ABI.
"""

from __future__ import annotations

import argparse
import collections
import datetime as _datetime
import json
import sys
from pathlib import Path
from typing import Any


OUTPUT_SCHEMA = "qemu-v2-ptc-walker-conversion-model-v2"
EXPECTED_MANIFEST_SCHEMA = "qemu-v2-ptc-v2-opcode-schema-manifest-v1"

CATEGORY_ORDER = ("direct", "alias", "v2-op", "vector-schema", "unknown")
CATEGORY_TO_COMPATIBILITY = {
    "direct": "direct",
    "alias": "alias",
    "v2-op": "requires-ptc-v2-op",
    "vector-schema": "requires-operand-schema",
    "unknown": "unknown",
}
CATEGORY_TO_EMIT_KIND = {
    "direct": "legacy",
    "alias": "legacy",
    "v2-op": "ptc-v2-op",
    "vector-schema": "vector-schema-required",
    "unknown": "reject",
}

DEFAULT_TCG_TYPE_INFO = {
    0: {"name": "TCG_TYPE_I32", "abi": "i32", "bits": 32, "kind": "scalar"},
    1: {"name": "TCG_TYPE_I64", "abi": "i64", "bits": 64, "kind": "scalar"},
    2: {"name": "TCG_TYPE_I128", "abi": "i128", "bits": 128, "kind": "scalar"},
    3: {"name": "TCG_TYPE_V64", "abi": "v64", "bits": 64, "kind": "vector"},
    4: {"name": "TCG_TYPE_V128", "abi": "v128", "bits": 128, "kind": "vector"},
    5: {"name": "TCG_TYPE_V256", "abi": "v256", "bits": 256, "kind": "vector"},
}

DEFAULT_MEMOP_SIZE_INFO = {
    0: {"name": "MO_8", "abi": "e8", "bits": 8},
    1: {"name": "MO_16", "abi": "e16", "bits": 16},
    2: {"name": "MO_32", "abi": "e32", "bits": 32},
    3: {"name": "MO_64", "abi": "e64", "bits": 64},
    4: {"name": "MO_128", "abi": "e128", "bits": 128},
    5: {"name": "MO_256", "abi": "e256", "bits": 256},
    6: {"name": "MO_512", "abi": "e512", "bits": 512},
    7: {"name": "MO_1024", "abi": "e1024", "bits": 1024},
}

PTC_VAL_TYPE_BY_TEMP_VAL_NAME = {
    "TEMP_VAL_DEAD": {"name": "PTC_TEMP_VAL_DEAD", "value": 0, "status": "mapped-by-name"},
    "TEMP_VAL_REG": {"name": "PTC_TEMP_VAL_REG", "value": 1, "status": "mapped-by-name"},
    "TEMP_VAL_MEM": {"name": "PTC_TEMP_VAL_MEM", "value": 2, "status": "mapped-by-name"},
    "TEMP_VAL_CONST": {"name": "PTC_TEMP_VAL_CONST", "value": 3, "status": "mapped-by-name"},
}

TEMP_KIND_CLASS_BY_NAME = {
    "TEMP_EBB": "ebb",
    "TEMP_TB": "tb",
    "TEMP_GLOBAL": "global",
    "TEMP_FIXED": "fixed",
    "TEMP_CONST": "const",
}


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Apply a PTC v2 manifest to C walker JSONL and write a "
            "PTCInstructionList-like decision-model JSON."
        )
    )
    parser.add_argument("--walker-jsonl", type=Path, required=True, help="C walker JSONL input")
    parser.add_argument("--manifest", type=Path, required=True, help="PTC v2 manifest JSON")
    parser.add_argument("--json-out", type=Path, required=True, help="converted model JSON output")
    return parser.parse_args(argv)


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    try:
        with path.open() as stream:
            data = json.load(stream)
    except FileNotFoundError as exc:
        raise SystemExit(f"{label} does not exist: {path}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{label} is not valid JSON: {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise SystemExit(f"{label} must be a JSON object: {path}")
    return data


def normalize_int_key_map(raw: Any, fallback: dict[int, dict[str, Any]]) -> dict[int, dict[str, Any]]:
    if not isinstance(raw, dict):
        return fallback
    result: dict[int, dict[str, Any]] = {}
    for key, value in raw.items():
        try:
            int_key = int(key)
        except (TypeError, ValueError):
            continue
        if isinstance(value, dict):
            item = dict(value)
            item.pop("raw", None)
            result[int_key] = item
    return result or fallback


def decode_tcg_type(value: Any, tcg_type_info: dict[int, dict[str, Any]]) -> dict[str, Any]:
    if not isinstance(value, int):
        return {"raw": value, "name": "unknown", "abi": "unknown", "bits": None, "kind": "unknown"}
    info = tcg_type_info.get(value)
    if not info:
        return {"raw": value, "name": f"unknown({value})", "abi": "unknown", "bits": None, "kind": "unknown"}
    return {"raw": value, **info}


def decode_memop_size(value: Any, memop_size_info: dict[int, dict[str, Any]]) -> dict[str, Any]:
    if not isinstance(value, int):
        return {"raw": value, "name": "unknown", "abi": "unknown", "bits": None}
    info = memop_size_info.get(value & 0x7)
    if not info:
        return {"raw": value, "name": f"unknown({value})", "abi": "unknown", "bits": None}
    return {"raw": value, **info}


def decode_temp_type(value: Any, name: Any, tcg_type_info: dict[int, dict[str, Any]]) -> dict[str, Any]:
    decoded = decode_tcg_type(value, tcg_type_info)
    decoded["source_name"] = name if isinstance(name, str) else None
    if isinstance(name, str) and name and decoded.get("name") in {None, "unknown"}:
        decoded["name"] = name
    return decoded


def legacy_ptc_type(decoded_type: dict[str, Any]) -> dict[str, Any]:
    """Map modern TCG types to the old runnable-lift PTCType when safe."""
    abi = decoded_type.get("abi")
    if abi == "i32":
        return {"name": "PTC_TYPE_I32", "value": 0, "status": "mapped"}
    if abi == "i64":
        return {"name": "PTC_TYPE_I64", "value": 1, "status": "mapped"}
    return {"name": None, "value": None, "status": "unmapped-modern-type"}


def decode_ptc_val_type(record: dict[str, Any]) -> dict[str, Any]:
    val_type_name = record.get("val_type_name")
    if isinstance(val_type_name, str) and val_type_name in PTC_VAL_TYPE_BY_TEMP_VAL_NAME:
        mapped = PTC_VAL_TYPE_BY_TEMP_VAL_NAME[val_type_name]
        return {"raw": record.get("val_type"), "source_name": val_type_name, **mapped}

    raw_value = record.get("val_type")
    if isinstance(raw_value, int) and raw_value in {0, 1, 2, 3}:
        names = {
            0: "PTC_TEMP_VAL_DEAD",
            1: "PTC_TEMP_VAL_REG",
            2: "PTC_TEMP_VAL_MEM",
            3: "PTC_TEMP_VAL_CONST",
        }
        return {
            "raw": raw_value,
            "source_name": val_type_name,
            "name": names[raw_value],
            "value": raw_value,
            "status": "mapped-by-value",
        }

    return {
        "raw": raw_value,
        "source_name": val_type_name,
        "name": None,
        "value": None,
        "status": "unmapped",
    }


def nullable_bool(value: Any) -> bool | None:
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return bool(value)
    return None


def canonical_name(raw_name: str, record: dict[str, Any], tcg_type_info: dict[int, dict[str, Any]]) -> str:
    if raw_name == "extract":
        tcg_type = decode_tcg_type(record.get("param1"), tcg_type_info)
        if tcg_type.get("abi") in {"i32", "i64", "i128"}:
            return f"extract_{tcg_type['abi']}"
    return raw_name


def normalize_category(category: str, entry: dict[str, Any]) -> str:
    if category in CATEGORY_TO_EMIT_KIND:
        return category
    if category == "v2_opcode_proposals":
        return "v2-op"
    if category == "vector_operand_schema_proposals":
        return "vector-schema"

    compatibility = str(entry.get("compatibility", ""))
    if compatibility in {"direct", "alias", "unknown"}:
        return compatibility
    if compatibility == "requires-ptc-v2-op":
        return "v2-op"
    if compatibility == "requires-operand-schema":
        return "vector-schema"

    action = str(entry.get("converter_action", ""))
    if action == "direct-emit":
        return "direct"
    if action == "select-typed-legacy-op-or-reject":
        return "alias"
    if action == "emit-ptc-v2-opcode-or-reject":
        return "v2-op"
    if action == "apply-vector-operand-schema-or-reject":
        return "vector-schema"
    return "unknown"


def observed_raw_names(entry: dict[str, Any]) -> list[str]:
    names: list[str] = []
    own_name = entry.get("name")
    if isinstance(own_name, str):
        names.append(own_name)
    for item in entry.get("observed_names", []):
        if isinstance(item, dict) and isinstance(item.get("name"), str):
            names.append(item["name"])
    result: list[str] = []
    for name in names:
        if name not in result:
            result.append(name)
    return result


def merge_entry(existing: dict[str, Any], incoming: dict[str, Any]) -> None:
    for key, value in incoming.items():
        if key not in existing or existing[key] in (None, "", []):
            existing[key] = value


def build_manifest_index(
    manifest: dict[str, Any],
) -> tuple[dict[str, dict[str, Any]], dict[str, list[dict[str, Any]]]]:
    by_name: dict[str, dict[str, Any]] = {}

    def add_entry(category: str, raw_entry: Any) -> None:
        if not isinstance(raw_entry, dict) or not isinstance(raw_entry.get("name"), str):
            return
        normalized = normalize_category(category, raw_entry)
        name = raw_entry["name"]
        incoming = dict(raw_entry)
        incoming["manifest_category"] = normalized
        incoming["compatibility"] = CATEGORY_TO_COMPATIBILITY[normalized]
        if name in by_name:
            merge_entry(by_name[name], incoming)
        else:
            by_name[name] = incoming

    categories = manifest.get("categories", {})
    if isinstance(categories, dict):
        for category, entries in categories.items():
            if isinstance(entries, list):
                for entry in entries:
                    add_entry(str(category), entry)

    for entry in manifest.get("v2_opcode_proposals", []):
        add_entry("v2_opcode_proposals", entry)
    for entry in manifest.get("vector_operand_schema_proposals", []):
        add_entry("vector_operand_schema_proposals", entry)

    by_raw_name: dict[str, list[dict[str, Any]]] = collections.defaultdict(list)
    for entry in by_name.values():
        for raw_name in observed_raw_names(entry):
            if entry not in by_raw_name[raw_name]:
                by_raw_name[raw_name].append(entry)

    return by_name, dict(by_raw_name)


def compact_metadata(record: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value
        for key, value in record.items()
        if isinstance(value, (str, int, float, bool)) or value is None
    }


def read_walker_jsonl(
    path: Path,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    op_records: list[dict[str, Any]] = []
    temp_records: list[dict[str, Any]] = []
    metadata_records: list[dict[str, Any]] = []
    skipped_records: list[dict[str, Any]] = []
    json_lines = 0

    try:
        stream = path.open()
    except FileNotFoundError as exc:
        raise SystemExit(f"walker JSONL does not exist: {path}") from exc

    with stream:
        for line_number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            json_lines += 1
            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                skipped_records.append({"line": line_number, "reason": f"invalid-json: {exc}"})
                continue
            if not isinstance(record, dict):
                skipped_records.append({"line": line_number, "reason": "record is not a JSON object"})
                continue
            record_kind = record.get("record")
            event = record.get("event")
            if record_kind == "op" or event == "op":
                if not isinstance(record.get("name"), str):
                    skipped_records.append({"line": line_number, "reason": "op record missing string name"})
                    continue
                record["_source_file"] = str(path)
                record["_source_line"] = line_number
                op_records.append(record)
            elif record_kind == "temp" or event == "temp":
                if not isinstance(record.get("temp_id"), int):
                    skipped_records.append({"line": line_number, "reason": "temp record missing integer temp_id"})
                    continue
                record["_source_file"] = str(path)
                record["_source_line"] = line_number
                temp_records.append(record)
            else:
                item = compact_metadata(record)
                item["_source_line"] = line_number
                metadata_records.append(item)

    stats = {
        "path": str(path),
        "json_lines": json_lines,
        "op_records": len(op_records),
        "temp_records": len(temp_records),
        "metadata_records": len(metadata_records),
        "skipped_records": skipped_records,
    }
    return op_records, temp_records, metadata_records, stats


def resolve_manifest_entry(
    record: dict[str, Any],
    by_name: dict[str, dict[str, Any]],
    by_raw_name: dict[str, list[dict[str, Any]]],
    tcg_type_info: dict[int, dict[str, Any]],
) -> tuple[str, dict[str, Any] | None]:
    raw_name = str(record["name"])
    canonical = canonical_name(raw_name, record, tcg_type_info)
    if canonical in by_name:
        return canonical, by_name[canonical]

    matches = by_raw_name.get(raw_name, [])
    if len(matches) == 1:
        return str(matches[0].get("name", canonical)), matches[0]
    for entry in matches:
        if entry.get("name") == canonical:
            return canonical, entry
    return canonical, None


def legacy_candidates(entry: dict[str, Any]) -> list[str]:
    values = entry.get("legacy_candidates", [])
    if isinstance(values, list):
        return [value for value in values if isinstance(value, str)]
    legacy = entry.get("legacy", [])
    if isinstance(legacy, list):
        return [value for value in legacy if isinstance(value, str)]
    return []


def select_legacy_opcode(
    category: str,
    entry: dict[str, Any],
    decoded_param1: dict[str, Any],
) -> tuple[str | None, str]:
    if category == "direct":
        opcode = entry.get("legacy_opcode") or entry.get("name")
        return (str(opcode) if isinstance(opcode, str) else None, "direct-legacy-opcode")

    candidates = legacy_candidates(entry)
    if len(candidates) == 1:
        return candidates[0], "single-legacy-candidate"

    abi = decoded_param1.get("abi")
    if isinstance(abi, str) and abi != "unknown":
        suffix = f"_{abi}"
        for candidate in candidates:
            if candidate.endswith(suffix):
                return candidate, "selected-by-param1-type"

    if candidates:
        return candidates[0], "fallback-first-legacy-candidate"

    name = entry.get("name")
    return (str(name) if isinstance(name, str) else None, "fallback-manifest-name")


def argument_schema(entry: dict[str, Any] | None, args: list[Any]) -> list[dict[str, Any]]:
    schema = entry.get("operand_schema", []) if entry else []
    if not isinstance(schema, list):
        schema = []

    result: list[dict[str, Any]] = []
    for index, raw_arg in enumerate(args):
        item = {"index": index, "raw": raw_arg, "encoding": "raw-walker-tcgarg"}
        if index < len(schema) and isinstance(schema[index], dict):
            item["schema"] = schema[index]
        result.append(item)
    return result


def convert_record(
    *,
    record: dict[str, Any],
    index: int,
    argument_start: int,
    entry: dict[str, Any] | None,
    canonical: str,
    tcg_type_info: dict[int, dict[str, Any]],
    memop_size_info: dict[int, dict[str, Any]],
) -> dict[str, Any]:
    raw_args = record.get("args", [])
    if not isinstance(raw_args, list):
        raw_args = []

    decoded_param1 = decode_tcg_type(record.get("param1"), tcg_type_info)
    decoded_param2 = decode_memop_size(record.get("param2"), memop_size_info)

    category = str(entry.get("manifest_category", "unknown")) if entry else "unknown"
    if category not in CATEGORY_TO_EMIT_KIND:
        category = "unknown"
    compatibility = CATEGORY_TO_COMPATIBILITY[category]
    emit_kind = CATEGORY_TO_EMIT_KIND[category]

    emit_opcode: str | None = None
    selection_status = "not-selected"
    reject_reason: str | None = None

    if category in {"direct", "alias"} and entry:
        emit_opcode, selection_status = select_legacy_opcode(category, entry, decoded_param1)
    elif category == "v2-op" and entry:
        opcode = entry.get("ptc_v2_opcode")
        emit_opcode = str(opcode) if isinstance(opcode, str) and opcode else None
        selection_status = "manifest-ptc-v2-opcode"
    elif category == "vector-schema" and entry:
        opcode = entry.get("ptc_v2_opcode")
        emit_opcode = str(opcode) if isinstance(opcode, str) and opcode else None
        selection_status = "manifest-vector-schema"

    if category == "unknown":
        reject_reason = "no manifest decision for opcode"
    elif emit_kind in {"legacy", "ptc-v2-op"} and not emit_opcode:
        emit_kind = "reject"
        reject_reason = "manifest decision did not provide an opcode"
    elif emit_kind == "vector-schema-required" and not entry:
        emit_kind = "reject"
        reject_reason = "manifest decision did not provide a vector schema"

    emitted = emit_kind != "reject"
    expected_arg_count = record.get("arg_count")
    arg_count_matches = expected_arg_count == len(raw_args) if isinstance(expected_arg_count, int) else None

    return {
        "index": index,
        "walker": {
            "source_line": record.get("_source_line"),
            "op_index": record.get("op_index"),
            "tb_pc": record.get("tb_pc"),
            "pc": record.get("pc"),
            "opcode": record.get("opcode"),
            "name": record.get("name"),
            "canonical_name": canonical,
            "param1": record.get("param1"),
            "param1_decoded": decoded_param1,
            "param2": record.get("param2"),
            "param2_decoded_as_memop_size": decoded_param2,
            "life": record.get("life"),
            "def_oargs": record.get("def_oargs"),
            "def_iargs": record.get("def_iargs"),
            "def_cargs": record.get("def_cargs"),
            "def_args": record.get("def_args"),
            "def_flags": record.get("def_flags"),
            "arg_count": record.get("arg_count"),
            "op_capacity": record.get("op_capacity"),
            "args_truncated": record.get("args_truncated"),
        },
        "decision": {
            "manifest_category": category,
            "compatibility": compatibility,
            "converter_action": entry.get("converter_action") if entry else "reject",
            "emit_kind": emit_kind,
            "emit_opcode": emit_opcode,
            "emitted": emitted,
            "selection_status": selection_status,
            "reject_reason": reject_reason,
            "proposal": bool(entry.get("proposal")) if entry else False,
            "proposal_status": entry.get("proposal_status") if entry else None,
        },
        "ptc_list_model": {
            "opc": emit_opcode,
            "argument_start": argument_start,
            "argument_count": len(raw_args),
            "callo": record.get("callo"),
            "calli": record.get("calli"),
            "not_real_abi": True,
        },
        "args": raw_args,
        "argument_schema": argument_schema(entry, raw_args),
        "arg_count_matches_walker": arg_count_matches,
    }


def parse_int_like(value: Any) -> int | None:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value, 0)
        except ValueError:
            return None
    return None


def temp_local_mapping(kind_name: Any) -> dict[str, Any]:
    if kind_name == "TEMP_TB":
        return {"candidate": True, "status": "approx-derived-from-TEMP_TB"}
    if kind_name in {"TEMP_EBB", "TEMP_GLOBAL", "TEMP_FIXED", "TEMP_CONST"}:
        return {"candidate": False, "status": "approx-derived-from-modern-kind"}
    return {"candidate": None, "status": "unmapped"}


def convert_temp_record(
    *,
    record: dict[str, Any],
    index: int,
    tcg_type_info: dict[int, dict[str, Any]],
) -> dict[str, Any]:
    kind_name = record.get("kind_name")
    val_type_name = record.get("val_type_name")
    decoded_type = decode_temp_type(record.get("type"), record.get("type_name"), tcg_type_info)
    decoded_base_type = decode_temp_type(record.get("base_type"), record.get("base_type_name"), tcg_type_info)
    ptc_type = legacy_ptc_type(decoded_type)
    ptc_base_type = legacy_ptc_type(decoded_base_type)
    ptc_val_type = decode_ptc_val_type(record)
    temp_local = temp_local_mapping(kind_name)
    is_global = nullable_bool(record.get("is_global"))
    mem_allocated = nullable_bool(record.get("mem_allocated"))
    mem_coherent = nullable_bool(record.get("mem_coherent"))
    temp_allocated = nullable_bool(record.get("temp_allocated"))
    fixed_reg = kind_name == "TEMP_FIXED" if isinstance(kind_name, str) else None
    has_mem_base = record.get("mem_base_id") is not None or record.get("mem_base_arg") is not None
    is_const = kind_name == "TEMP_CONST" or val_type_name == "TEMP_VAL_CONST"
    is_memory_backed = bool(mem_allocated or has_mem_base or val_type_name == "TEMP_VAL_MEM")
    is_register_value = val_type_name == "TEMP_VAL_REG"
    mapped_reg = record.get("reg") if isinstance(record.get("reg"), int) and (is_register_value or fixed_reg) else None
    mapped_val = parse_int_like(record.get("val")) if is_const else None

    return {
        "index": index,
        "temp_id": record.get("temp_id"),
        "temp_index": record.get("temp_index"),
        "name": record.get("temp_name"),
        "walker_arg": record.get("arg"),
        "kind": {
            "raw": record.get("kind"),
            "name": kind_name,
            "class": TEMP_KIND_CLASS_BY_NAME.get(kind_name, "unknown"),
        },
        "val_type": {
            "raw": record.get("val_type"),
            "name": val_type_name,
            "ptc_mapping": ptc_val_type,
        },
        "base_type": {
            "modern": decoded_base_type,
            "ptc_mapping": ptc_base_type,
        },
        "type": {
            "modern": decoded_type,
            "ptc_mapping": ptc_type,
        },
        "flags": {
            "is_global": is_global,
            "is_temp": (not is_global) if isinstance(is_global, bool) else None,
            "is_const": is_const,
            "is_memory_backed": is_memory_backed,
            "is_register_value": is_register_value,
            "is_fixed_register": fixed_reg,
            "has_register_field": isinstance(record.get("reg"), int),
        },
        "ptc_temp_model": {
            "reg": mapped_reg,
            "mem_reg": None,
            "mem_offset": record.get("mem_offset") if isinstance(record.get("mem_offset"), int) else None,
            "val": mapped_val,
            "name": record.get("temp_name"),
            "val_type": ptc_val_type.get("value"),
            "val_type_name": ptc_val_type.get("name"),
            "base_type": ptc_base_type.get("value"),
            "base_type_name": ptc_base_type.get("name"),
            "type": ptc_type.get("value"),
            "type_name": ptc_type.get("name"),
            "fixed_reg": fixed_reg,
            "mem_coherent": mem_coherent,
            "mem_allocated": mem_allocated,
            "temp_local": None,
            "temp_allocated": temp_allocated,
            "not_real_abi": True,
        },
        "derived_candidates": {
            "temp_local": temp_local,
        },
        "modern_walker": {
            "source_line": record.get("_source_line"),
            "tb_pc": record.get("tb_pc"),
            "pc": record.get("pc"),
            "reg": record.get("reg"),
            "val": record.get("val"),
            "val_s": record.get("val_s"),
            "mem_base_id": record.get("mem_base_id"),
            "mem_base_arg": record.get("mem_base_arg"),
            "mem_offset": record.get("mem_offset"),
            "mem_offset_hex": record.get("mem_offset_hex"),
            "indirect_reg": record.get("indirect_reg"),
            "indirect_base": record.get("indirect_base"),
            "mem_coherent": record.get("mem_coherent"),
            "mem_allocated": record.get("mem_allocated"),
            "temp_allocated": record.get("temp_allocated"),
            "temp_subindex": record.get("temp_subindex"),
            "state": record.get("state"),
            "state_ptr": record.get("state_ptr"),
        },
        "mapping_status": {
            "val_type": ptc_val_type.get("status"),
            "base_type": ptc_base_type.get("status"),
            "type": ptc_type.get("status"),
            "fixed_reg": "derived-from-kind" if fixed_reg is not None else "unmapped",
            "mem_reg": "unmapped-modern-mem_base_id-does-not-equal-legacy-mem_reg",
            "temp_local": "null-approximation-available" if temp_local["candidate"] is not None else "unmapped",
            "reg": "mapped-for-TEMP_FIXED-or-TEMP_VAL_REG" if mapped_reg is not None else "null-not-register-valued",
            "value": "mapped-for-TEMP_CONST-or-TEMP_VAL_CONST" if mapped_val is not None else "null-not-const-valued",
        },
    }


def convert_temp_records(
    temp_records: list[dict[str, Any]],
    tcg_type_info: dict[int, dict[str, Any]],
) -> list[dict[str, Any]]:
    records = sorted(temp_records, key=lambda item: (item.get("temp_id", 0), item.get("_source_line", 0)))
    return [
        convert_temp_record(record=record, index=index, tcg_type_info=tcg_type_info)
        for index, record in enumerate(records)
    ]


def temp_mapping_report(
    temps: list[dict[str, Any]],
    metadata_records: list[dict[str, Any]],
) -> dict[str, Any]:
    by_kind: collections.Counter[str] = collections.Counter()
    by_type: collections.Counter[str] = collections.Counter()
    by_base_type: collections.Counter[str] = collections.Counter()
    by_val_type: collections.Counter[str] = collections.Counter()
    type_mapping_status: collections.Counter[str] = collections.Counter()
    base_type_mapping_status: collections.Counter[str] = collections.Counter()
    val_type_mapping_status: collections.Counter[str] = collections.Counter()

    for temp in temps:
        by_kind[str(temp["kind"].get("name"))] += 1
        by_type[str(temp["type"]["modern"].get("name"))] += 1
        by_base_type[str(temp["base_type"]["modern"].get("name"))] += 1
        by_val_type[str(temp["val_type"].get("name"))] += 1
        type_mapping_status[str(temp["mapping_status"].get("type"))] += 1
        base_type_mapping_status[str(temp["mapping_status"].get("base_type"))] += 1
        val_type_mapping_status[str(temp["mapping_status"].get("val_type"))] += 1

    declared_total = None
    declared_globals = None
    for record in metadata_records:
        if declared_total is None and isinstance(record.get("nb_temps"), int):
            declared_total = record["nb_temps"]
        if declared_globals is None and isinstance(record.get("nb_globals"), int):
            declared_globals = record["nb_globals"]

    global_count = sum(1 for temp in temps if temp["flags"].get("is_global") is True)
    const_count = sum(1 for temp in temps if temp["flags"].get("is_const") is True)
    memory_count = sum(1 for temp in temps if temp["flags"].get("is_memory_backed") is True)
    fixed_register_count = sum(1 for temp in temps if temp["flags"].get("is_fixed_register") is True)
    register_value_count = sum(1 for temp in temps if temp["flags"].get("is_register_value") is True)

    return {
        "status": "ptc-temp-like-behavior-model",
        "not_runnable_lift_abi": True,
        "temp_records": len(temps),
        "global_temps_observed": global_count,
        "total_temps_observed": len(temps),
        "walker_declared_global_temps": declared_globals,
        "walker_declared_total_temps": declared_total,
        "declared_counts_match_observed": {
            "global_temps": declared_globals == global_count if declared_globals is not None else None,
            "total_temps": declared_total == len(temps) if declared_total is not None else None,
        },
        "flags": {
            "global": global_count,
            "const": const_count,
            "memory_backed": memory_count,
            "fixed_register": fixed_register_count,
            "register_value": register_value_count,
        },
        "by_kind": counter_to_dict(by_kind),
        "by_type": counter_to_dict(by_type),
        "by_base_type": counter_to_dict(by_base_type),
        "by_val_type": counter_to_dict(by_val_type),
        "legacy_mapping_status": {
            "type": counter_to_dict(type_mapping_status),
            "base_type": counter_to_dict(base_type_mapping_status),
            "val_type": counter_to_dict(val_type_mapping_status),
        },
        "unreliable_or_unmapped_fields": [
            {
                "field": "mem_reg",
                "status": "null",
                "reason": "modern walker exposes mem_base_id/mem_base_arg, not the legacy QEMU 2.4 mem_reg field",
            },
            {
                "field": "temp_local",
                "status": "null",
                "reason": "derived from TEMP_TB versus other modern TCGTempKind values, not copied from a legacy temp_local bit",
            },
            {
                "field": "base_type/type",
                "status": "nullable",
                "reason": "legacy runnable-lift PTCType only has I32/I64; modern I128/vector types are preserved and mapped to null",
            },
            {
                "field": "reg",
                "status": "nullable",
                "reason": "PTCTemp.reg is only populated for TEMP_FIXED or TEMP_VAL_REG records; raw walker reg is preserved separately",
            },
            {
                "field": "val",
                "status": "nullable",
                "reason": "PTCTemp.val is only populated for TEMP_CONST or TEMP_VAL_CONST records; raw walker val is preserved separately",
            },
        ],
        "direct_but_raw_fields": [
            {
                "field": "reg",
                "status": "raw-pre-regalloc-field",
                "reason": "direct walker field preserved under modern_walker.reg, but not treated as a final allocation guarantee",
            },
            {
                "field": "val",
                "status": "raw-field",
                "reason": "direct walker field preserved under modern_walker.val; PTCTemp.val is only populated for const-valued temps",
            },
        ],
    }


def counter_to_dict(counter: collections.Counter[str]) -> dict[str, int]:
    return {key: counter[key] for key in sorted(counter)}


def summarize(
    instructions: list[dict[str, Any]],
    arguments: list[Any],
    temps: list[dict[str, Any]],
    temp_report: dict[str, Any],
    walker_stats: dict[str, Any],
) -> dict[str, Any]:
    by_emit_kind: collections.Counter[str] = collections.Counter()
    by_category: collections.Counter[str] = collections.Counter()
    by_compatibility: collections.Counter[str] = collections.Counter()
    by_emit_opcode: collections.Counter[str] = collections.Counter()
    reject_reasons: collections.Counter[str] = collections.Counter()

    emitted = 0
    rejected = 0
    for instruction in instructions:
        decision = instruction["decision"]
        emit_kind = str(decision.get("emit_kind", "reject"))
        category = str(decision.get("manifest_category", "unknown"))
        compatibility = str(decision.get("compatibility", "unknown"))
        by_emit_kind[emit_kind] += 1
        by_category[category] += 1
        by_compatibility[compatibility] += 1
        opcode = decision.get("emit_opcode")
        if isinstance(opcode, str):
            by_emit_opcode[opcode] += 1
        if decision.get("emitted"):
            emitted += 1
        else:
            rejected += 1
            reason = decision.get("reject_reason") or "unspecified"
            reject_reasons[str(reason)] += 1

    for emit_kind in ("legacy", "ptc-v2-op", "vector-schema-required", "reject"):
        by_emit_kind.setdefault(emit_kind, 0)
    for category in CATEGORY_ORDER:
        by_category.setdefault(category, 0)

    return {
        "instruction_count": len(instructions),
        "argument_count": len(arguments),
        "temp_count": len(temps),
        "temps": len(temps),
        "global_temps": temp_report["global_temps_observed"],
        "total_temps": temp_report["total_temps_observed"],
        "emitted": emitted,
        "rejected": rejected,
        "by_emit_kind": counter_to_dict(by_emit_kind),
        "by_manifest_category": counter_to_dict(by_category),
        "by_compatibility": counter_to_dict(by_compatibility),
        "by_emit_opcode": counter_to_dict(by_emit_opcode),
        "reject_reasons": counter_to_dict(reject_reasons),
        "temp_mapping_report": temp_report,
        "walker_stats": walker_stats,
    }


def convert(args: argparse.Namespace) -> dict[str, Any]:
    manifest = load_json_object(args.manifest, "manifest")
    schema_limits = manifest.get("schema_limits", {})
    if not isinstance(schema_limits, dict):
        schema_limits = {}
    tcg_type_info = normalize_int_key_map(schema_limits.get("tcg_type_decode"), DEFAULT_TCG_TYPE_INFO)
    memop_size_info = normalize_int_key_map(schema_limits.get("memop_size_decode"), DEFAULT_MEMOP_SIZE_INFO)

    by_name, by_raw_name = build_manifest_index(manifest)
    records, temp_records, metadata_records, walker_stats = read_walker_jsonl(args.walker_jsonl)

    instructions: list[dict[str, Any]] = []
    flat_arguments: list[Any] = []
    for index, record in enumerate(records):
        canonical, entry = resolve_manifest_entry(record, by_name, by_raw_name, tcg_type_info)
        instruction = convert_record(
            record=record,
            index=index,
            argument_start=len(flat_arguments),
            entry=entry,
            canonical=canonical,
            tcg_type_info=tcg_type_info,
            memop_size_info=memop_size_info,
        )
        flat_arguments.extend(instruction["args"])
        instructions.append(instruction)

    temps = convert_temp_records(temp_records, tcg_type_info)
    temp_report = temp_mapping_report(temps, metadata_records)
    summary = summarize(instructions, flat_arguments, temps, temp_report, walker_stats)
    global_temps = temp_report["global_temps_observed"]
    total_temps = temp_report["total_temps_observed"]
    return {
        "schema": OUTPUT_SCHEMA,
        "generated_at_utc": _datetime.datetime.now(_datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat(),
        "model_policy": {
            "status": "prototype-behavior-model",
            "manifest_driven": True,
            "not_runnable_lift_abi": True,
            "not_real_ptc_instruction_list": True,
            "statement": (
                "This JSON models TCGOp conversion decisions before the C converter. "
                "It preserves raw walker args and PTCTemp-like temp projections as "
                "evidence and must not be consumed as the real runnable-lift "
                "PTCInstructionList ABI."
            ),
            "decision_chain": [
                "direct -> emit_kind=legacy",
                "alias -> emit_kind=legacy",
                "requires-ptc-v2-op -> emit_kind=ptc-v2-op",
                "vector-schema -> emit_kind=vector-schema-required",
                "unknown -> emit_kind=reject",
            ],
        },
        "source": {
            "walker_jsonl": str(args.walker_jsonl),
            "manifest": str(args.manifest),
            "manifest_schema": manifest.get("schema"),
            "expected_manifest_schema": EXPECTED_MANIFEST_SCHEMA,
            "manifest_summary": manifest.get("summary"),
            "metadata_records": metadata_records,
        },
        "instruction_count": len(instructions),
        "argument_count": len(flat_arguments),
        "temp_count": len(temps),
        "global_temps": global_temps,
        "total_temps": total_temps,
        "instructions": instructions,
        "arguments": flat_arguments,
        "temps": temps,
        "summary": summary,
    }


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    result = convert(args)
    args.json_out.parent.mkdir(parents=True, exist_ok=True)
    with args.json_out.open("w") as stream:
        json.dump(result, stream, indent=2, sort_keys=True)
        stream.write("\n")

    summary = result["summary"]
    by_emit_kind = summary["by_emit_kind"]
    print(f"wrote: {args.json_out}")
    print(
        "conversion summary: "
        f"instructions={summary['instruction_count']} "
        f"arguments={summary['argument_count']} "
        f"temps={summary['temp_count']} "
        f"global_temps={summary['global_temps']} "
        f"total_temps={summary['total_temps']} "
        f"emitted={summary['emitted']} "
        f"rejected={summary['rejected']}"
    )
    print(
        "emit kinds: "
        f"legacy={by_emit_kind.get('legacy', 0)} "
        f"ptc-v2-op={by_emit_kind.get('ptc-v2-op', 0)} "
        f"vector-schema-required={by_emit_kind.get('vector-schema-required', 0)} "
        f"reject={by_emit_kind.get('reject', 0)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
