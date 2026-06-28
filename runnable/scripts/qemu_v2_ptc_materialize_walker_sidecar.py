#!/usr/bin/env python3
"""Materialize a replayable sidecar root from a walker conversion model."""

from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
from typing import Any

VectorHalf = tuple[str, int]

SYNTHETIC_HELPER_FUNC_BASE = 0xFFE0000000000000
SYNTHETIC_HELPER_FUNC_MASK = 0x000FFFFFFFFFFFFF


QEMU_V2_TO_LEGACY_PTC_CONDITION = {
    0x0: 0x0,   # NEVER
    0x1: 0x1,   # ALWAYS
    0x2: 0x2,   # LT
    0x3: 0x3,   # GE
    0x6: 0xb,   # GT
    0x7: 0xa,   # LE
    0x8: 0x8,   # EQ
    0x9: 0x9,   # NE
    0xa: 0x4,   # LTU
    0xb: 0x5,   # GEU
    0xe: 0xd,   # GTU
    0xf: 0xc,   # LEU
}

QEMU_V2_TEST_CONDITION_EQNE = {
    0xc: 0x8,   # TSTEQ, if explicitly lowered as (a & b) == 0
    0xd: 0x9,   # TSTNE, if explicitly lowered as (a & b) != 0
}

CONDITION_ARG_INDEX_BY_OPCODE = {
    "brcond_i32": 2,
    "brcond_i64": 2,
    "setcond_i32": 3,
    "setcond_i64": 3,
    "movcond_i32": 5,
    "movcond_i64": 5,
}

PTC_OP_CONDITION_OPCODE_ALIASES = {
    "PTC_OP_BRCOND_I32": "brcond_i32",
    "PTC_OP_BRCOND_I64": "brcond_i64",
    "PTC_OP_SETCOND_I32": "setcond_i32",
    "PTC_OP_SETCOND_I64": "setcond_i64",
    "PTC_OP_MOVCOND_I32": "movcond_i32",
    "PTC_OP_MOVCOND_I64": "movcond_i64",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Emit sidecar.payload.txt, sidecar.model.json, and sidecar.summary.json from a walker model."
    )
    parser.add_argument("--model-json", type=Path, required=True, help="walker conversion model JSON")
    parser.add_argument("--manifest-json", type=Path, required=False, help="optional walker manifest JSON")
    parser.add_argument("--output-root", type=Path, required=True, help="root directory that will contain sidecar/")
    parser.add_argument("--captured-pc", required=True, help="actual captured PC, e.g. 0x7ffff6304f30")
    parser.add_argument("--canonical-pc", required=True, help="requested canonical PC, e.g. 0x50304f30")
    parser.add_argument(
        "--normalize-debug-pc",
        action="store_true",
        help="rewrite debug_insn_start arg0 from captured-pc space to canonical-pc space",
    )
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise SystemExit(f"expected JSON object: {path}")
    return data


def instruction_opcode(inst: dict[str, Any]) -> str | None:
    model = inst.get("ptc_list_model") or {}
    opc = model.get("opc")
    return str(opc) if isinstance(opc, str) and opc else None


def parse_int_like(value: Any) -> int | None:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value.strip(), 0)
        except ValueError:
            return None
    return None


def synthetic_helper_func(name: str) -> int:
    """Return a stable non-zero raw helper id for materializer-created calls."""

    h = 0xCBF29CE484222325
    for byte in name.encode("utf-8"):
        h ^= byte
        h = (h * 0x100000001B3) & ((1 << 64) - 1)
    return SYNTHETIC_HELPER_FUNC_BASE | (h & SYNTHETIC_HELPER_FUNC_MASK)


def debug_insn_start_pc(inst: dict[str, Any]) -> int | None:
    if instruction_opcode(inst) != "debug_insn_start":
        return None
    args = inst.get("args")
    if not isinstance(args, list) or not args:
        return None
    return parse_int_like(args[0])


def walker_tb_pc(inst: dict[str, Any]) -> int | None:
    walker = inst.get("walker")
    if not isinstance(walker, dict):
        return None
    return parse_int_like(walker.get("tb_pc"))


def to_int(value: Any) -> int:
    return 0 if value is None else int(value)


def temp_model_value(temp: dict[str, Any]) -> int | None:
    model = temp.get("ptc_temp_model")
    if not isinstance(model, dict):
        return None
    return parse_int_like(model.get("val"))


def walker_canonical_name(inst: dict[str, Any]) -> str:
    walker = inst.get("walker")
    if not isinstance(walker, dict):
        return ""
    name = walker.get("canonical_name") or walker.get("name") or ""
    return str(name)


def instruction_source_index(inst: dict[str, Any]) -> Any:
    return inst.get("source_index", inst.get("index"))


def walker_scalar_abi(inst: dict[str, Any], canonical_name: str) -> str | None:
    walker = inst.get("walker")
    if isinstance(walker, dict):
        decoded = walker.get("param1_decoded")
        if isinstance(decoded, dict):
            abi = decoded.get("abi")
            if abi in {"i32", "i64"}:
                return str(abi)
    if canonical_name.endswith("_i32"):
        return "i32"
    if canonical_name.endswith("_i64"):
        return "i64"
    return None


def is_goto_ptr_boundary(inst: dict[str, Any]) -> bool:
    return instruction_opcode(inst) in (None, "None") and walker_canonical_name(inst) == "goto_ptr"


def is_lookup_tb_call_boundary(selected_instructions: list[dict[str, Any]], index: int) -> bool:
    """Identify QEMU v2 lookup_tb_ptr call + goto_ptr TB chaining boundaries.

    QEMU v2 emits this as a TCG call whose returned TB pointer is consumed by
    the immediately following goto_ptr. The legacy runnable-lift ABI cannot name
    the process-local helper pointer, but the pair's architectural effect at
    the sidecar boundary is an explicit TB exit.
    """

    if index + 1 >= len(selected_instructions):
        return False
    inst = selected_instructions[index]
    next_inst = selected_instructions[index + 1]
    if instruction_opcode(inst) != "call" or not is_goto_ptr_boundary(next_inst):
        return False
    inst_args = inst.get("args")
    next_args = next_inst.get("args")
    if not isinstance(inst_args, list) or not isinstance(next_args, list):
        return False
    if not inst_args or not next_args:
        return False
    return str(inst_args[0]) == str(next_args[0])


def needs_temp_args_before_lowering(inst: dict[str, Any]) -> bool:
    if is_goto_ptr_boundary(inst):
        return False
    return True


def legacy_condition_opcode(opcode: str | None) -> str | None:
    if opcode in CONDITION_ARG_INDEX_BY_OPCODE:
        return opcode
    return PTC_OP_CONDITION_OPCODE_ALIASES.get(opcode or "")


def remap_qemu_v2_condition(inst: dict[str, Any], legacy_opcode: str) -> str | None:
    mapped_args = inst.get("args")
    if not isinstance(mapped_args, list):
        raise SystemExit(f"selected instruction {instruction_source_index(inst)} has no args array")

    condition_index = CONDITION_ARG_INDEX_BY_OPCODE[legacy_opcode]
    if len(mapped_args) <= condition_index:
        raise SystemExit(
            f"cannot remap condition for {legacy_opcode} instruction {instruction_source_index(inst)}: "
            f"expected condition arg at index {condition_index}, got {len(mapped_args)} args"
        )

    raw_condition = parse_int_like(mapped_args[condition_index])
    if raw_condition is None:
        raise SystemExit(
            f"cannot remap condition for {legacy_opcode} instruction {instruction_source_index(inst)}: "
            f"non-integer condition {mapped_args[condition_index]!r}"
        )

    if raw_condition in QEMU_V2_TEST_CONDITION_EQNE:
        legacy_condition = QEMU_V2_TEST_CONDITION_EQNE[raw_condition]
        raise SystemExit(
            f"cannot remap QEMU v2 test condition {raw_condition:#x} to legacy {legacy_condition:#x} "
            f"for {legacy_opcode} instruction {instruction_source_index(inst)} without explicit "
            "(a & b) compare-to-zero lowering"
        )

    legacy_condition = QEMU_V2_TO_LEGACY_PTC_CONDITION.get(raw_condition)
    if legacy_condition is None:
        raise SystemExit(
            f"cannot remap unsupported QEMU v2 condition {raw_condition:#x} for "
            f"{legacy_opcode} instruction {instruction_source_index(inst)}"
        )

    model = inst.get("ptc_list_model")
    if not isinstance(model, dict):
        raise SystemExit(f"selected instruction {instruction_source_index(inst)} has no ptc_list_model")

    original_opcode = instruction_opcode(inst)
    old_condition = mapped_args[condition_index]
    mapped_args[condition_index] = str(legacy_condition)
    model["opc"] = legacy_opcode
    model["argument_count"] = len(mapped_args)
    model["not_real_abi"] = False
    inst.setdefault("materializer", {})["condition_lowering"] = {
        "source": "qemu-v2-tcg-cond",
        "target": "legacy-ptc-condition",
        "arg_index": condition_index,
        "qemu_v2_condition": raw_condition,
        "legacy_condition": legacy_condition,
    }
    if str(old_condition) == str(legacy_condition) and original_opcode == legacy_opcode:
        return None
    return f"{legacy_opcode} condition {raw_condition:#x}->{legacy_condition:#x}"


def walker_param_int(inst: dict[str, Any], name: str) -> int | None:
    walker = inst.get("walker")
    if not isinstance(walker, dict):
        return None
    return parse_int_like(walker.get(name))


def lower_qemu_v2_call(inst: dict[str, Any]) -> str | None:
    model = inst.get("ptc_list_model")
    if not isinstance(model, dict):
        raise SystemExit(f"selected instruction {instruction_source_index(inst)} has no ptc_list_model")
    mapped_args = inst.get("args")
    if not isinstance(mapped_args, list):
        raise SystemExit(f"selected instruction {instruction_source_index(inst)} has no args array")

    calli = walker_param_int(inst, "param1")
    callo = walker_param_int(inst, "param2")
    if calli is None or callo is None:
        return None
    if not 0 <= callo <= 3:
        raise SystemExit(
            f"cannot lower QEMU v2 call instruction {instruction_source_index(inst)}: "
            f"callo={callo} is outside legacy 2-bit callo range"
        )
    if not 0 <= calli <= 63:
        raise SystemExit(
            f"cannot lower QEMU v2 call instruction {instruction_source_index(inst)}: "
            f"calli={calli} is outside legacy 6-bit calli range"
        )

    expected_args = callo + calli + 2
    if len(mapped_args) != expected_args:
        raise SystemExit(
            f"cannot lower QEMU v2 call instruction {instruction_source_index(inst)}: "
            f"expected out+in+2 args ({callo}+{calli}+2={expected_args}), got {len(mapped_args)}"
        )

    old_callo = model.get("callo")
    old_calli = model.get("calli")
    model["callo"] = callo
    model["calli"] = calli
    model["argument_count"] = len(mapped_args)
    model["not_real_abi"] = False
    inst.setdefault("materializer", {})["call_lowering"] = {
        "source": "qemu-v2-call-param1-param2",
        "target": "legacy-ptc-call-callo-calli",
        "callo": callo,
        "calli": calli,
        "const_arg_count": 2,
        "func_arg_index": callo + calli,
        "info_arg_index": callo + calli + 1,
    }
    if old_callo == callo and old_calli == calli:
        return None
    return f"call ABI param1/param2 -> calli/callo {calli}/{callo}"


def normalize_helper_name(name: Any) -> str | None:
    if not isinstance(name, str) or not name:
        return None
    return name.removeprefix("helper_")


def call_helper_def(inst: dict[str, Any]) -> dict[str, Any] | None:
    if instruction_opcode(inst) != "call":
        return None
    model = inst.get("ptc_list_model")
    inst_args = inst.get("args")
    walker = inst.get("walker")
    if not isinstance(model, dict) or not isinstance(inst_args, list) or not isinstance(walker, dict):
        return None
    callo = parse_int_like(model.get("callo"))
    calli = parse_int_like(model.get("calli"))
    if callo is None or calli is None:
        return None
    func_index = callo + calli
    info_index = func_index + 1
    if info_index >= len(inst_args):
        return None

    helper = walker.get("call_helper")
    if not isinstance(helper, dict):
        return None
    helper_name = normalize_helper_name(helper.get("name"))
    if helper_name is None:
        return None

    func = parse_int_like(inst_args[func_index])
    helper_func = parse_int_like(helper.get("func"))
    if func is None:
        func = helper_func
    if func is None:
        return None
    if helper_func is not None and helper_func != func:
        raise SystemExit(
            f"call helper metadata func mismatch at instruction {instruction_source_index(inst)}: "
            f"arg func={inst_args[func_index]} metadata func={helper.get('func')}"
        )

    flags = parse_int_like(helper.get("flags"))
    info = parse_int_like(helper.get("info"))
    return {
        "func": hex(func),
        "name": helper_name,
        "flags": 0 if flags is None else flags,
        "info": hex(info) if info is not None else None,
        "source_instruction_index": inst.get("index"),
        "source_index": inst.get("source_index"),
    }


def collect_helper_defs(instructions: list[dict[str, Any]]) -> list[dict[str, Any]]:
    helper_defs: list[dict[str, Any]] = []
    seen: set[int] = set()
    for inst in instructions:
        helper_def = call_helper_def(inst)
        if helper_def is None:
            continue
        func = parse_int_like(helper_def["func"])
        if func is None or func in seen:
            continue
        seen.add(func)
        helper_defs.append(helper_def)
        inst.setdefault("materializer", {})["helper_def"] = {
            "func": helper_def["func"],
            "name": helper_def["name"],
            "flags": helper_def["flags"],
        }
    return helper_defs


def payload_helper_name(name: Any) -> str:
    if not isinstance(name, str) or not name:
        raise SystemExit("cannot emit helper metadata with empty helper name")
    if any(char in name for char in "|\r\n"):
        raise SystemExit(f"cannot emit helper metadata with unsafe helper name {name!r}")
    return name


def ptc_scalar_type_for_opcode(opcode: str) -> int:
    if opcode.endswith("_i32"):
        return 0
    if opcode.endswith("_i64"):
        return 1
    raise SystemExit(f"cannot infer scalar type for opcode {opcode}")


def materializer_temp_record(index: int, name: str, ptc_type: int, val_type: int, val: int | None) -> dict[str, Any]:
    return {
        "index": index,
        "temp_id": index,
        "temp_index": index,
        "name": name,
        "walker_arg": None,
        "flags": {
            "is_global": False,
            "is_temp": True,
            "is_const": val_type == 3,
            "is_memory_backed": False,
            "is_register_value": False,
            "is_fixed_register": False,
            "has_register_field": False,
        },
        "ptc_temp_model": {
            "reg": 0,
            "mem_reg": 0,
            "mem_offset": 0,
            "val": val,
            "name": name,
            "val_type": val_type,
            "base_type": ptc_type,
            "type": ptc_type,
            "fixed_reg": False,
            "mem_coherent": False,
            "mem_allocated": False,
            "temp_local": False,
            "temp_allocated": True,
            "not_real_abi": False,
        },
        "materializer": {
            "synthetic_temp": True,
        },
    }


def qemu_v2_memop_idx_with_size(memop_idx: int, size: int) -> int:
    mmu_index = memop_idx & 0x1f
    memop = memop_idx >> 5
    return ((memop & ~0x7) | size) << 5 | mmu_index


def walker_vector_bits(inst: dict[str, Any]) -> int | None:
    walker = inst.get("walker")
    if not isinstance(walker, dict):
        return None
    decoded = walker.get("param1_decoded")
    if isinstance(decoded, dict):
        bits = parse_int_like(decoded.get("bits"))
        if bits is not None:
            return bits
    raw_type = parse_int_like(walker.get("param1"))
    return {
        3: 64,   # TCG_TYPE_V64
        4: 128,  # TCG_TYPE_V128
        5: 256,  # TCG_TYPE_V256
    }.get(raw_type)


def ensure_const_i64_temp(
    selected_temps: list[dict[str, Any]],
    const_temps: dict[int, int],
    value: int,
) -> int:
    value &= (1 << 64) - 1
    existing = const_temps.get(value)
    if existing is not None:
        return existing
    temp_index = len(selected_temps)
    const_temps[value] = temp_index
    selected_temps.append(
        materializer_temp_record(
            temp_index,
            f"materializer_vec_const_i64_{temp_index}",
            1,
            3,
            value,
        )
    )
    return temp_index


def qemu_v2_vector_half_values(
    inst: dict[str, Any],
    selected_temps: list[dict[str, Any]],
    vector_halves: dict[int, tuple[VectorHalf, ...]],
    src: int,
    bits: int,
) -> tuple[VectorHalf, ...] | None:
    known_halves = vector_halves.get(src)
    if known_halves is not None:
        return known_halves
    if src < 0 or src >= len(selected_temps):
        raise SystemExit(
            f"cannot lower vector instruction {instruction_source_index(inst)}: "
            f"source temp index {src} outside selected temp table"
        )
    value = temp_model_value(selected_temps[src])
    if value is None:
        return None
    half_count = bits // 64
    if half_count == 1:
        return (("const", value & ((1 << 64) - 1)),)
    if value == 0:
        return tuple(("const", 0) for _ in range(half_count))
    raise SystemExit(
        f"cannot lower vector instruction {instruction_source_index(inst)}: "
        f"non-zero {bits}-bit vector constant is not representable as legacy i64 halves"
    )


def vector_half_temp_index(
    selected_temps: list[dict[str, Any]],
    const_temps: dict[int, int],
    half: VectorHalf,
) -> int:
    kind, value = half
    if kind == "temp":
        return value
    if kind == "const":
        return ensure_const_i64_temp(selected_temps, const_temps, value)
    raise SystemExit(f"unknown vector half source kind {kind!r}")


def expand_qemu_v2_mov_vec(
    inst: dict[str, Any],
    selected_temps: list[dict[str, Any]],
    vector_halves: dict[int, tuple[VectorHalf, ...]],
) -> tuple[list[dict[str, Any]], str] | None:
    opcode = instruction_opcode(inst)
    canonical_name = walker_canonical_name(inst)
    if opcode != "PTC_OP_MOV_VEC" and canonical_name != "mov_vec":
        return None

    inst_args = inst.get("args")
    if not isinstance(inst_args, list):
        raise SystemExit(f"selected instruction {instruction_source_index(inst)} has no args array")
    if len(inst_args) != 2:
        raise SystemExit(
            f"cannot lower mov_vec instruction {instruction_source_index(inst)}: "
            f"expected 2 args, got {len(inst_args)}"
        )
    bits = walker_vector_bits(inst)
    if bits is None or bits <= 0 or bits % 64 != 0:
        raise SystemExit(
            f"cannot lower mov_vec instruction {instruction_source_index(inst)}: "
            f"unsupported vector width {bits if bits is not None else 'unknown'}"
        )
    dst = parse_int_like(inst_args[0])
    src = parse_int_like(inst_args[1])
    if dst is None or src is None:
        raise SystemExit(
            f"cannot lower mov_vec instruction {instruction_source_index(inst)}: "
            f"non-integer temp args {inst_args!r}"
        )
    halves = qemu_v2_vector_half_values(inst, selected_temps, vector_halves, src, bits)
    if halves is None:
        raise SystemExit(
            f"cannot lower mov_vec instruction {instruction_source_index(inst)}: "
            f"source vector temp {src} has no known scalar half state"
        )
    expected_halves = bits // 64
    if len(halves) != expected_halves:
        raise SystemExit(
            f"cannot lower mov_vec instruction {instruction_source_index(inst)}: "
            f"expected {expected_halves} i64 halves, got {len(halves)}"
        )
    vector_halves[dst] = tuple(halves)
    return [], f"mov_vec({bits})->vector half state"


def expand_qemu_v2_ld_vec(
    inst: dict[str, Any],
    selected_temps: list[dict[str, Any]],
    vector_halves: dict[int, tuple[VectorHalf, ...]],
) -> tuple[list[dict[str, Any]], str] | None:
    opcode = instruction_opcode(inst)
    canonical_name = walker_canonical_name(inst)
    if opcode != "PTC_OP_LD_VEC" and canonical_name != "ld_vec":
        return None

    inst_args = inst.get("args")
    if not isinstance(inst_args, list):
        raise SystemExit(f"selected instruction {instruction_source_index(inst)} has no args array")
    if len(inst_args) != 3:
        raise SystemExit(
            f"cannot lower ld_vec instruction {instruction_source_index(inst)}: "
            f"expected 3 args, got {len(inst_args)}"
        )
    bits = walker_vector_bits(inst)
    if bits is None or bits <= 0 or bits % 64 != 0:
        raise SystemExit(
            f"cannot lower ld_vec instruction {instruction_source_index(inst)}: "
            f"unsupported vector width {bits if bits is not None else 'unknown'}"
        )
    dst = parse_int_like(inst_args[0])
    base = parse_int_like(inst_args[1])
    offset = parse_int_like(inst_args[2])
    if dst is None or base is None or offset is None:
        raise SystemExit(
            f"cannot lower ld_vec instruction {instruction_source_index(inst)}: "
            f"non-integer args {inst_args!r}"
        )

    source_index = instruction_source_index(inst)
    first_index = int(inst["index"])
    lowering = f"ld_vec({bits})->ld_i64 env-load halves"
    half_sources: list[VectorHalf] = []

    def lowered_load(index: int, dst_temp: int, load_offset: int) -> dict[str, Any]:
        load_args = [str(dst_temp), str(base), hex(load_offset)]
        return {
            "source_index": source_index,
            "index": index,
            "walker": {
                "name": "ld_i64",
                "canonical_name": "ld_i64",
                "lowered_from": canonical_name,
            },
            "ptc_list_model": {
                "opc": "ld_i64",
                "argument_count": len(load_args),
                "callo": None,
                "calli": None,
                "not_real_abi": False,
            },
            "args": load_args,
            "materializer": {
                "lowering": lowering,
                "synthetic_instruction": True,
            },
        }

    lowered: list[dict[str, Any]] = []
    for half_index in range(bits // 64):
        half_temp = len(selected_temps)
        selected_temps.append(
            materializer_temp_record(
                half_temp,
                f"materializer_ld_vec_half_{half_temp}",
                1,
                0,
                None,
            )
        )
        half_sources.append(("temp", half_temp))
        lowered.append(lowered_load(first_index + half_index, half_temp, offset + half_index * 8))

    vector_halves[dst] = tuple(half_sources)
    return lowered, lowering


def expand_qemu_v2_st_vec(
    inst: dict[str, Any],
    selected_temps: list[dict[str, Any]],
    vector_halves: dict[int, tuple[VectorHalf, ...]],
    const_temps: dict[int, int],
) -> tuple[list[dict[str, Any]], str] | None:
    opcode = instruction_opcode(inst)
    canonical_name = walker_canonical_name(inst)
    if opcode != "PTC_OP_ST_VEC" and canonical_name != "st_vec":
        return None

    inst_args = inst.get("args")
    if not isinstance(inst_args, list):
        raise SystemExit(f"selected instruction {instruction_source_index(inst)} has no args array")
    if len(inst_args) != 3:
        raise SystemExit(
            f"cannot lower st_vec instruction {instruction_source_index(inst)}: "
            f"expected 3 args, got {len(inst_args)}"
        )
    bits = walker_vector_bits(inst)
    if bits is None or bits <= 0 or bits % 64 != 0:
        raise SystemExit(
            f"cannot lower st_vec instruction {instruction_source_index(inst)}: "
            f"unsupported vector width {bits if bits is not None else 'unknown'}"
        )
    src = parse_int_like(inst_args[0])
    base = parse_int_like(inst_args[1])
    offset = parse_int_like(inst_args[2])
    if src is None or base is None or offset is None:
        raise SystemExit(
            f"cannot lower st_vec instruction {instruction_source_index(inst)}: "
            f"non-integer args {inst_args!r}"
        )
    halves = qemu_v2_vector_half_values(inst, selected_temps, vector_halves, src, bits)
    if halves is None:
        raise SystemExit(
            f"cannot lower st_vec instruction {instruction_source_index(inst)}: "
            f"source vector temp {src} has no known scalar half state"
        )
    expected_halves = bits // 64
    if len(halves) != expected_halves:
        raise SystemExit(
            f"cannot lower st_vec instruction {instruction_source_index(inst)}: "
            f"expected {expected_halves} i64 halves, got {len(halves)}"
        )

    source_index = instruction_source_index(inst)
    first_index = int(inst["index"])
    lowering = f"st_vec({bits})->st_i64 env-store halves"

    def lowered_store(index: int, half: VectorHalf, store_offset: int) -> dict[str, Any]:
        src_index = vector_half_temp_index(selected_temps, const_temps, half)
        store_args = [str(src_index), str(base), hex(store_offset)]
        return {
            "source_index": source_index,
            "index": index,
            "walker": {
                "name": "st_i64",
                "canonical_name": "st_i64",
                "lowered_from": canonical_name,
            },
            "ptc_list_model": {
                "opc": "st_i64",
                "argument_count": len(store_args),
                "callo": None,
                "calli": None,
                "not_real_abi": False,
            },
            "args": store_args,
            "materializer": {
                "lowering": lowering,
                "synthetic_instruction": True,
            },
        }

    return [
        lowered_store(first_index + half_index, half, offset + half_index * 8)
        for half_index, half in enumerate(halves)
    ], lowering


def expand_qemu_v2_extract_i64(
    inst: dict[str, Any],
    selected_temps: list[dict[str, Any]],
    const_temps: dict[int, int],
) -> tuple[list[dict[str, Any]], str] | None:
    opcode = instruction_opcode(inst)
    canonical_name = walker_canonical_name(inst)
    if opcode != "PTC_OP_EXTRACT_I64" and canonical_name != "extract_i64":
        return None

    inst_args = inst.get("args")
    if not isinstance(inst_args, list):
        raise SystemExit(f"selected instruction {instruction_source_index(inst)} has no args array")
    if len(inst_args) != 4:
        raise SystemExit(
            f"cannot lower extract_i64 instruction {instruction_source_index(inst)}: "
            f"expected 4 args, got {len(inst_args)}"
        )
    bit_offset = parse_int_like(inst_args[2])
    bit_length = parse_int_like(inst_args[3])
    if bit_offset == 0 and bit_length in {8, 16, 32, 64}:
        return None
    if bit_offset is None or bit_length is None:
        raise SystemExit(
            f"cannot lower extract_i64 instruction {instruction_source_index(inst)}: "
            f"non-integer bit slice offset={inst_args[2]!r} length={inst_args[3]!r}"
        )
    if bit_offset < 0 or bit_length <= 0 or bit_offset + bit_length > 64:
        raise SystemExit(
            f"cannot lower extract_i64 instruction {instruction_source_index(inst)}: "
            f"unsupported bit slice offset={inst_args[2]} length={inst_args[3]}"
        )

    dst = parse_int_like(inst_args[0])
    src = parse_int_like(inst_args[1])
    if dst is None or src is None:
        raise SystemExit(
            f"cannot lower extract_i64 instruction {instruction_source_index(inst)}: "
            f"non-integer temp args {inst_args[:2]!r}"
        )

    source_index = instruction_source_index(inst)
    first_index = int(inst["index"])
    mask = (1 << bit_length) - 1 if bit_length < 64 else (1 << 64) - 1
    mask_temp = ensure_const_i64_temp(selected_temps, const_temps, mask)
    lowering = f"extract_i64({bit_offset},{bit_length})->shr_i64/and_i64"

    def lowered_inst(index: int, opc: str, lowered_args: list[str]) -> dict[str, Any]:
        return {
            "source_index": source_index,
            "index": index,
            "walker": {
                "name": opc,
                "canonical_name": opc,
                "lowered_from": canonical_name,
            },
            "ptc_list_model": {
                "opc": opc,
                "argument_count": len(lowered_args),
                "callo": None,
                "calli": None,
                "not_real_abi": False,
            },
            "args": lowered_args,
            "materializer": {
                "lowering": lowering,
                "synthetic_instruction": True,
            },
        }

    if bit_offset == 0:
        return [
            lowered_inst(first_index, "and_i64", [str(dst), str(src), str(mask_temp)])
        ], lowering

    shifted_temp = len(selected_temps)
    selected_temps.append(
        materializer_temp_record(
            shifted_temp,
            f"materializer_extract_i64_shifted_{shifted_temp}",
            1,
            0,
            None,
        )
    )
    shift_temp = ensure_const_i64_temp(selected_temps, const_temps, bit_offset)
    return [
        lowered_inst(first_index, "shr_i64", [str(shifted_temp), str(src), str(shift_temp)]),
        lowered_inst(first_index + 1, "and_i64", [str(dst), str(shifted_temp), str(mask_temp)]),
    ], lowering


def expand_qemu_v2_ctz(
    inst: dict[str, Any],
    selected_temps: list[dict[str, Any]],
    const_temps: dict[int, int],
) -> tuple[list[dict[str, Any]], str] | None:
    canonical_name = walker_canonical_name(inst)
    if canonical_name != "ctz":
        return None

    inst_args = inst.get("args")
    if not isinstance(inst_args, list):
        raise SystemExit(f"selected instruction {instruction_source_index(inst)} has no args array")
    if len(inst_args) != 3:
        raise SystemExit(
            f"cannot lower ctz instruction {instruction_source_index(inst)}: "
            f"expected 3 args, got {len(inst_args)}"
        )

    scalar_abi = walker_scalar_abi(inst, canonical_name)
    if scalar_abi != "i64":
        raise SystemExit(
            f"cannot lower ctz instruction {instruction_source_index(inst)}: "
            f"unsupported scalar type {scalar_abi or 'unknown'}"
        )

    dst = parse_int_like(inst_args[0])
    src = parse_int_like(inst_args[1])
    default = parse_int_like(inst_args[2])
    if dst is None or src is None or default is None:
        raise SystemExit(
            f"cannot lower ctz instruction {instruction_source_index(inst)}: "
            f"non-integer temp args {inst_args!r}"
        )

    source_index = instruction_source_index(inst)
    first_index = int(inst["index"])
    lowering = "ctz_i64->helper_ctz+movcond_i64 zero-default"
    helper_result = len(selected_temps)
    selected_temps.append(
        materializer_temp_record(
            helper_result,
            f"materializer_ctz_i64_result_{helper_result}",
            1,
            0,
            None,
        )
    )
    zero_temp = ensure_const_i64_temp(selected_temps, const_temps, 0)
    helper_func = synthetic_helper_func("ctz")

    call_args = [str(helper_result), str(src), hex(helper_func), "0x0"]
    movcond_args = [
        str(dst),
        str(src),
        str(zero_temp),
        str(helper_result),
        str(default),
        str(QEMU_V2_TO_LEGACY_PTC_CONDITION[0x9]),
    ]

    call_inst = {
        "source_index": source_index,
        "index": first_index,
        "walker": {
            "name": "call",
            "canonical_name": "call",
            "lowered_from": canonical_name,
            "call_helper": {
                "name": "helper_ctz",
                "func": hex(helper_func),
                "flags": 0,
                "info": "0x0",
            },
        },
        "ptc_list_model": {
            "opc": "call",
            "argument_count": len(call_args),
            "callo": 1,
            "calli": 1,
            "not_real_abi": False,
        },
        "args": call_args,
        "materializer": {
            "lowering": lowering,
            "synthetic_instruction": True,
        },
    }
    movcond_inst = {
        "source_index": source_index,
        "index": first_index + 1,
        "walker": {
            "name": "movcond_i64",
            "canonical_name": "movcond_i64",
            "lowered_from": canonical_name,
        },
        "ptc_list_model": {
            "opc": "movcond_i64",
            "argument_count": len(movcond_args),
            "callo": None,
            "calli": None,
            "not_real_abi": False,
        },
        "args": movcond_args,
        "materializer": {
            "lowering": lowering,
            "synthetic_instruction": True,
            "zero_default_semantics": {
                "source": "qemu-v2-ctz",
                "condition": "src != 0",
                "helper_result_temp": helper_result,
                "zero_temp": zero_temp,
                "default_temp": default,
            },
        },
    }
    return [call_inst, movcond_inst], lowering


def expand_qemu_v2_negsetcond(
    inst: dict[str, Any],
    selected_temps: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], str] | None:
    canonical_name = walker_canonical_name(inst)
    if canonical_name != "negsetcond":
        return None

    inst_args = inst.get("args")
    if not isinstance(inst_args, list):
        raise SystemExit(f"selected instruction {instruction_source_index(inst)} has no args array")
    if len(inst_args) != 4:
        raise SystemExit(
            f"cannot lower negsetcond instruction {instruction_source_index(inst)}: "
            f"expected 4 args, got {len(inst_args)}"
        )
    scalar_abi = walker_scalar_abi(inst, canonical_name)
    if scalar_abi not in {"i32", "i64"}:
        raise SystemExit(
            f"cannot lower negsetcond instruction {instruction_source_index(inst)}: "
            f"unsupported scalar type {scalar_abi or 'unknown'}"
        )
    raw_condition = parse_int_like(inst_args[3])
    if raw_condition in QEMU_V2_TEST_CONDITION_EQNE:
        raise SystemExit(
            f"cannot lower negsetcond instruction {instruction_source_index(inst)}: "
            f"QEMU v2 test condition {raw_condition:#x} needs explicit and-then-negsetcond lowering"
        )
    legacy_condition = QEMU_V2_TO_LEGACY_PTC_CONDITION.get(raw_condition)
    if legacy_condition is None:
        raise SystemExit(
            f"cannot lower negsetcond instruction {instruction_source_index(inst)}: "
            f"unsupported QEMU v2 condition {raw_condition if raw_condition is not None else inst_args[3]!r}"
        )

    ptc_type = 0 if scalar_abi == "i32" else 1
    setcond_opcode = f"setcond_{scalar_abi}"
    neg_opcode = f"neg_{scalar_abi}"
    setcond_temp = len(selected_temps)
    selected_temps.append(
        materializer_temp_record(
            setcond_temp,
            f"materializer_negsetcond_bool_{setcond_temp}",
            ptc_type,
            0,
            None,
        )
    )

    dst, lhs, rhs, _condition = inst_args
    source_index = instruction_source_index(inst)
    first_index = int(inst["index"])
    lowering = f"negsetcond_{scalar_abi}->setcond_{scalar_abi}+neg_{scalar_abi}"

    def lowered_inst(index: int, opc: str, lowered_args: list[str]) -> dict[str, Any]:
        return {
            "source_index": source_index,
            "index": index,
            "walker": {
                "name": opc,
                "canonical_name": opc,
                "lowered_from": canonical_name,
            },
            "ptc_list_model": {
                "opc": opc,
                "argument_count": len(lowered_args),
                "callo": None,
                "calli": None,
                "not_real_abi": False,
            },
            "args": lowered_args,
            "materializer": {
                "lowering": lowering,
                "synthetic_instruction": True,
            },
        }

    return [
        lowered_inst(first_index, setcond_opcode, [str(setcond_temp), str(lhs), str(rhs), str(legacy_condition)]),
        lowered_inst(first_index + 1, neg_opcode, [str(dst), str(setcond_temp)]),
    ], lowering


def expand_qemu_v2_test_brcond(
    inst: dict[str, Any],
    selected_temps: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], str] | None:
    legacy_opcode = legacy_condition_opcode(instruction_opcode(inst))
    if legacy_opcode not in {"brcond_i32", "brcond_i64"}:
        return None

    inst_args = inst.get("args")
    if not isinstance(inst_args, list):
        raise SystemExit(f"selected instruction {instruction_source_index(inst)} has no args array")
    if len(inst_args) != 4:
        raise SystemExit(
            f"cannot lower QEMU v2 test condition for {legacy_opcode} instruction "
            f"{instruction_source_index(inst)}: expected 4 args, got {len(inst_args)}"
        )

    raw_condition = parse_int_like(inst_args[2])
    if raw_condition not in QEMU_V2_TEST_CONDITION_EQNE:
        return None

    legacy_condition = QEMU_V2_TEST_CONDITION_EQNE[raw_condition]
    ptc_type = ptc_scalar_type_for_opcode(legacy_opcode)
    and_opcode = "and_i32" if ptc_type == 0 else "and_i64"

    tmp_index = len(selected_temps)
    zero_index = tmp_index + 1
    selected_temps.append(
        materializer_temp_record(
            tmp_index,
            f"materializer_{legacy_opcode}_test_tmp_{tmp_index}",
            ptc_type,
            0,
            None,
        )
    )
    selected_temps.append(
        materializer_temp_record(
            zero_index,
            f"materializer_{legacy_opcode}_zero_{zero_index}",
            ptc_type,
            3,
            0,
        )
    )

    source_index = instruction_source_index(inst)
    and_index = int(inst["index"])
    branch_index = and_index + 1
    lhs, rhs, _condition, label = inst_args
    lowering = (
        f"{legacy_opcode} test condition {raw_condition:#x}->and+"
        f"{'EQ' if legacy_condition == 8 else 'NE'} zero"
    )

    and_inst = {
        "source_index": source_index,
        "index": and_index,
        "walker": {
            "name": and_opcode,
            "canonical_name": and_opcode,
            "lowered_from": walker_canonical_name(inst),
        },
        "ptc_list_model": {
            "opc": and_opcode,
            "argument_count": 3,
            "callo": None,
            "calli": None,
            "not_real_abi": False,
        },
        "args": [str(tmp_index), str(lhs), str(rhs)],
        "materializer": {
            "lowering": lowering,
            "synthetic_instruction": True,
        },
    }

    branch_inst = json.loads(json.dumps(inst))
    branch_inst["index"] = branch_index
    branch_inst["args"] = [str(tmp_index), str(zero_index), str(legacy_condition), label]
    branch_model = branch_inst.get("ptc_list_model")
    if not isinstance(branch_model, dict):
        raise SystemExit(f"selected instruction {source_index} has no ptc_list_model")
    branch_model["opc"] = legacy_opcode
    branch_model["argument_count"] = 4
    branch_model["not_real_abi"] = False
    branch_inst.setdefault("materializer", {})["lowering"] = lowering
    branch_inst.setdefault("materializer", {})["condition_lowering"] = {
        "source": "qemu-v2-tcg-test-cond",
        "target": "legacy-and-then-ptc-condition",
        "qemu_v2_condition": raw_condition,
        "legacy_condition": legacy_condition,
        "and_opcode": and_opcode,
        "and_temp": tmp_index,
        "zero_temp": zero_index,
    }
    return [and_inst, branch_inst], lowering


def expand_qemu_v2_test_movcond(
    inst: dict[str, Any],
    selected_temps: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], str] | None:
    legacy_opcode = legacy_condition_opcode(instruction_opcode(inst))
    if legacy_opcode not in {"movcond_i32", "movcond_i64"}:
        return None

    inst_args = inst.get("args")
    if not isinstance(inst_args, list):
        raise SystemExit(f"selected instruction {instruction_source_index(inst)} has no args array")
    if len(inst_args) != 6:
        raise SystemExit(
            f"cannot lower QEMU v2 test condition for {legacy_opcode} instruction "
            f"{instruction_source_index(inst)}: expected 6 args, got {len(inst_args)}"
        )

    raw_condition = parse_int_like(inst_args[5])
    if raw_condition not in QEMU_V2_TEST_CONDITION_EQNE:
        return None

    legacy_condition = QEMU_V2_TEST_CONDITION_EQNE[raw_condition]
    ptc_type = ptc_scalar_type_for_opcode(legacy_opcode)
    and_opcode = "and_i32" if ptc_type == 0 else "and_i64"

    tmp_index = len(selected_temps)
    zero_index = tmp_index + 1
    selected_temps.append(
        materializer_temp_record(
            tmp_index,
            f"materializer_{legacy_opcode}_test_tmp_{tmp_index}",
            ptc_type,
            0,
            None,
        )
    )
    selected_temps.append(
        materializer_temp_record(
            zero_index,
            f"materializer_{legacy_opcode}_zero_{zero_index}",
            ptc_type,
            3,
            0,
        )
    )

    source_index = instruction_source_index(inst)
    and_index = int(inst["index"])
    movcond_index = and_index + 1
    dst, lhs, rhs, iftrue, iffalse, _condition = inst_args
    lowering = (
        f"{legacy_opcode} test condition {raw_condition:#x}->and+"
        f"{'EQ' if legacy_condition == 8 else 'NE'} zero"
    )

    and_inst = {
        "source_index": source_index,
        "index": and_index,
        "walker": {
            "name": and_opcode,
            "canonical_name": and_opcode,
            "lowered_from": walker_canonical_name(inst),
        },
        "ptc_list_model": {
            "opc": and_opcode,
            "argument_count": 3,
            "callo": None,
            "calli": None,
            "not_real_abi": False,
        },
        "args": [str(tmp_index), str(lhs), str(rhs)],
        "materializer": {
            "lowering": lowering,
            "synthetic_instruction": True,
        },
    }

    movcond_inst = json.loads(json.dumps(inst))
    movcond_inst["index"] = movcond_index
    movcond_inst["args"] = [
        str(dst),
        str(tmp_index),
        str(zero_index),
        str(iftrue),
        str(iffalse),
        str(legacy_condition),
    ]
    movcond_model = movcond_inst.get("ptc_list_model")
    if not isinstance(movcond_model, dict):
        raise SystemExit(f"selected instruction {source_index} has no ptc_list_model")
    movcond_model["opc"] = legacy_opcode
    movcond_model["argument_count"] = 6
    movcond_model["not_real_abi"] = False
    movcond_inst.setdefault("materializer", {})["lowering"] = lowering
    movcond_inst.setdefault("materializer", {})["condition_lowering"] = {
        "source": "qemu-v2-tcg-test-cond",
        "target": "legacy-and-then-ptc-condition",
        "qemu_v2_condition": raw_condition,
        "legacy_condition": legacy_condition,
        "and_opcode": and_opcode,
        "and_temp": tmp_index,
        "zero_temp": zero_index,
    }
    return [and_inst, movcond_inst], lowering


def expand_qemu_v2_test_setcond(
    inst: dict[str, Any],
    selected_temps: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], str] | None:
    legacy_opcode = legacy_condition_opcode(instruction_opcode(inst))
    if legacy_opcode not in {"setcond_i32", "setcond_i64"}:
        return None

    inst_args = inst.get("args")
    if not isinstance(inst_args, list):
        raise SystemExit(f"selected instruction {instruction_source_index(inst)} has no args array")
    if len(inst_args) != 4:
        raise SystemExit(
            f"cannot lower QEMU v2 test condition for {legacy_opcode} instruction "
            f"{instruction_source_index(inst)}: expected 4 args, got {len(inst_args)}"
        )

    raw_condition = parse_int_like(inst_args[3])
    if raw_condition not in QEMU_V2_TEST_CONDITION_EQNE:
        return None

    legacy_condition = QEMU_V2_TEST_CONDITION_EQNE[raw_condition]
    ptc_type = ptc_scalar_type_for_opcode(legacy_opcode)
    and_opcode = "and_i32" if ptc_type == 0 else "and_i64"

    tmp_index = len(selected_temps)
    zero_index = tmp_index + 1
    selected_temps.append(
        materializer_temp_record(
            tmp_index,
            f"materializer_{legacy_opcode}_test_tmp_{tmp_index}",
            ptc_type,
            0,
            None,
        )
    )
    selected_temps.append(
        materializer_temp_record(
            zero_index,
            f"materializer_{legacy_opcode}_zero_{zero_index}",
            ptc_type,
            3,
            0,
        )
    )

    source_index = instruction_source_index(inst)
    and_index = int(inst["index"])
    setcond_index = and_index + 1
    dst, lhs, rhs, _condition = inst_args
    lowering = (
        f"{legacy_opcode} test condition {raw_condition:#x}->and+"
        f"{'EQ' if legacy_condition == 8 else 'NE'} zero"
    )

    and_inst = {
        "source_index": source_index,
        "index": and_index,
        "walker": {
            "name": and_opcode,
            "canonical_name": and_opcode,
            "lowered_from": walker_canonical_name(inst),
        },
        "ptc_list_model": {
            "opc": and_opcode,
            "argument_count": 3,
            "callo": None,
            "calli": None,
            "not_real_abi": False,
        },
        "args": [str(tmp_index), str(lhs), str(rhs)],
        "materializer": {
            "lowering": lowering,
            "synthetic_instruction": True,
        },
    }

    setcond_inst = json.loads(json.dumps(inst))
    setcond_inst["index"] = setcond_index
    setcond_inst["args"] = [
        str(dst),
        str(tmp_index),
        str(zero_index),
        str(legacy_condition),
    ]
    setcond_model = setcond_inst.get("ptc_list_model")
    if not isinstance(setcond_model, dict):
        raise SystemExit(f"selected instruction {source_index} has no ptc_list_model")
    setcond_model["opc"] = legacy_opcode
    setcond_model["argument_count"] = 4
    setcond_model["not_real_abi"] = False
    setcond_inst.setdefault("materializer", {})["lowering"] = lowering
    setcond_inst.setdefault("materializer", {})["condition_lowering"] = {
        "source": "qemu-v2-tcg-test-cond",
        "target": "legacy-and-then-ptc-condition",
        "qemu_v2_condition": raw_condition,
        "legacy_condition": legacy_condition,
        "and_opcode": and_opcode,
        "and_temp": tmp_index,
        "zero_temp": zero_index,
    }
    return [and_inst, setcond_inst], lowering


def expand_qemu_v2_qemu_st2(
    inst: dict[str, Any],
    selected_temps: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], str] | None:
    opcode = instruction_opcode(inst)
    canonical_name = walker_canonical_name(inst)
    if opcode != "PTC_OP_QEMU_ST2" and canonical_name != "qemu_st2":
        return None

    inst_args = inst.get("args")
    if not isinstance(inst_args, list):
        raise SystemExit(f"selected instruction {instruction_source_index(inst)} has no args array")
    if len(inst_args) != 4:
        raise SystemExit(
            f"cannot lower qemu_st2 instruction {instruction_source_index(inst)}: "
            f"expected 4 args, got {len(inst_args)}"
        )

    memop_idx = parse_int_like(inst_args[3])
    if memop_idx is None:
        raise SystemExit(
            f"cannot lower qemu_st2 instruction {instruction_source_index(inst)}: "
            f"non-integer MemOpIdx {inst_args[3]!r}"
        )

    memop = memop_idx >> 5
    if (memop & 0x7) != 4:
        raise SystemExit(
            f"cannot lower qemu_st2 instruction {instruction_source_index(inst)}: "
            f"expected MO_128 MemOpIdx, got {inst_args[3]}"
        )

    memop64 = qemu_v2_memop_idx_with_size(memop_idx, 3)
    has_bswap = bool(memop & 0x10)
    src_lo, src_hi, addr, _memop = inst_args
    first_src, second_src = (src_hi, src_lo) if has_bswap else (src_lo, src_hi)

    const8_index = len(selected_temps)
    addr_hi_index = const8_index + 1
    selected_temps.append(
        materializer_temp_record(
            const8_index,
            f"materializer_qemu_st2_const8_{const8_index}",
            1,
            3,
            8,
        )
    )
    selected_temps.append(
        materializer_temp_record(
            addr_hi_index,
            f"materializer_qemu_st2_addr_hi_{addr_hi_index}",
            1,
            0,
            None,
        )
    )

    source_index = instruction_source_index(inst)
    first_index = int(inst["index"])
    add_index = first_index + 1
    second_index = first_index + 2
    lowering = "qemu_st2->qemu_st_i64 pair"
    if has_bswap:
        lowering += " with 128-bit byteswap half order"

    def lowered_inst(index: int, opc: str, inst_args: list[str]) -> dict[str, Any]:
        return {
            "source_index": source_index,
            "index": index,
            "walker": {
                "name": opc,
                "canonical_name": opc,
                "lowered_from": canonical_name,
            },
            "ptc_list_model": {
                "opc": opc,
                "argument_count": len(inst_args),
                "callo": None,
                "calli": None,
                "not_real_abi": False,
            },
            "args": inst_args,
            "materializer": {
                "lowering": lowering,
                "synthetic_instruction": True,
            },
        }

    return [
        lowered_inst(first_index, "qemu_st_i64", [str(first_src), str(addr), hex(memop64)]),
        lowered_inst(add_index, "add_i64", [str(addr_hi_index), str(addr), str(const8_index)]),
        lowered_inst(second_index, "qemu_st_i64", [str(second_src), str(addr_hi_index), hex(memop64)]),
    ], lowering


def lower_to_legacy_ptc(inst: dict[str, Any]) -> str | None:
    """Lower selected QEMU v2-only TCG ops to legacy PTC ops when semantics match."""

    model = inst.get("ptc_list_model")
    if not isinstance(model, dict):
        raise SystemExit(f"selected instruction {instruction_source_index(inst)} has no ptc_list_model")

    opcode = instruction_opcode(inst)
    canonical_name = walker_canonical_name(inst)
    mapped_args = inst.get("args")
    if not isinstance(mapped_args, list):
        raise SystemExit(f"selected instruction {instruction_source_index(inst)} has no args array")

    if opcode == "call":
        return lower_qemu_v2_call(inst)

    condition_opcode = legacy_condition_opcode(opcode)
    if condition_opcode is not None:
        return remap_qemu_v2_condition(inst, condition_opcode)

    if opcode == "debug_insn_start":
        if not mapped_args:
            raise SystemExit(f"debug_insn_start instruction {instruction_source_index(inst)} has no PC arg")
        if len(mapped_args) != 1:
            original_count = len(mapped_args)
            inst["args"] = mapped_args[:1]
            model["argument_count"] = 1
            model["not_real_abi"] = False
            return f"debug_insn_start[{original_count}]->debug_insn_start[1]"
        model["argument_count"] = 1
        model["not_real_abi"] = False
        return None

    if opcode == "PTC_OP_EXTRACT_I64" or canonical_name == "extract_i64":
        if len(mapped_args) != 4:
            raise SystemExit(
                f"cannot lower extract_i64 instruction {instruction_source_index(inst)}: "
                f"expected 4 args, got {len(mapped_args)}"
            )
        bit_offset = parse_int_like(mapped_args[2])
        bit_length = parse_int_like(mapped_args[3])
        if bit_offset == 0 and bit_length in {8, 16, 32}:
            legacy_opcode = f"ext{bit_length}u_i64"
            inst["args"] = mapped_args[:2]
            model["opc"] = legacy_opcode
            model["argument_count"] = 2
            model["not_real_abi"] = False
            return f"extract_i64(0,{bit_length})->{legacy_opcode}"
        if bit_offset == 0 and bit_length == 64:
            inst["args"] = mapped_args[:2]
            model["opc"] = "mov_i64"
            model["argument_count"] = 2
            model["not_real_abi"] = False
            return "extract_i64(0,64)->mov_i64"
        raise SystemExit(
            f"cannot lower extract_i64 instruction {instruction_source_index(inst)}: "
            f"unsupported bit slice offset={mapped_args[2]} length={mapped_args[3]}"
        )

    if opcode == "PTC_OP_EXTRL_I64_I32" or canonical_name == "extrl_i64_i32":
        if len(mapped_args) != 2:
            raise SystemExit(
                f"cannot lower extrl_i64_i32 instruction {instruction_source_index(inst)}: "
                f"expected 2 args, got {len(mapped_args)}"
            )
        inst["args"] = mapped_args[:2]
        model["opc"] = "mov_i32"
        model["argument_count"] = 2
        model["not_real_abi"] = False
        return "extrl_i64_i32->mov_i32"

    if opcode == "PTC_OP_EXTU_I32_I64" or canonical_name == "extu_i32_i64":
        if len(mapped_args) != 2:
            raise SystemExit(
                f"cannot lower extu_i32_i64 instruction {instruction_source_index(inst)}: "
                f"expected 2 args, got {len(mapped_args)}"
            )
        inst["args"] = mapped_args[:2]
        model["opc"] = "ext32u_i64"
        model["argument_count"] = 2
        model["not_real_abi"] = False
        return "extu_i32_i64->ext32u_i64"

    if opcode in {"PTC_OP_SEXTRACT_I32", "PTC_OP_SEXTRACT_I64"} or canonical_name in {
        "sextract",
        "sextract_i32",
        "sextract_i64",
    }:
        if len(mapped_args) != 4:
            raise SystemExit(
                f"cannot lower sextract instruction {instruction_source_index(inst)}: "
                f"expected 4 args, got {len(mapped_args)}"
            )
        scalar_abi = walker_scalar_abi(inst, canonical_name)
        if scalar_abi not in {"i32", "i64"}:
            raise SystemExit(
                f"cannot lower sextract instruction {instruction_source_index(inst)}: "
                f"unsupported scalar type {scalar_abi or 'unknown'}"
            )
        register_bits = 32 if scalar_abi == "i32" else 64
        bit_offset = parse_int_like(mapped_args[2])
        bit_length = parse_int_like(mapped_args[3])
        if bit_offset == 0 and bit_length in {8, 16}:
            legacy_opcode = f"ext{bit_length}s_{scalar_abi}"
            inst["args"] = mapped_args[:2]
            model["opc"] = legacy_opcode
            model["argument_count"] = 2
            model["not_real_abi"] = False
            return f"sextract_{scalar_abi}(0,{bit_length})->{legacy_opcode}"
        if bit_offset == 0 and bit_length == 32 and scalar_abi == "i64":
            inst["args"] = mapped_args[:2]
            model["opc"] = "ext32s_i64"
            model["argument_count"] = 2
            model["not_real_abi"] = False
            return "sextract_i64(0,32)->ext32s_i64"
        if bit_offset == 0 and bit_length == register_bits:
            inst["args"] = mapped_args[:2]
            model["opc"] = f"mov_{scalar_abi}"
            model["argument_count"] = 2
            model["not_real_abi"] = False
            return f"sextract_{scalar_abi}(0,{bit_length})->mov_{scalar_abi}"
        raise SystemExit(
            f"cannot lower sextract instruction {instruction_source_index(inst)}: "
            f"unsupported bit slice offset={mapped_args[2]} length={mapped_args[3]} "
            f"type={scalar_abi}"
        )

    if opcode in (None, "None"):
        if canonical_name == "goto_ptr":
            inst["args"] = ["0"]
            model["opc"] = "exit_tb"
            model["argument_count"] = 1
            model["callo"] = None
            model["calli"] = None
            model["not_real_abi"] = False
            return "goto_ptr->exit_tb(0)"
        raise SystemExit(
            f"cannot materialize unsupported walker instruction {instruction_source_index(inst)} "
            f"({canonical_name or 'unknown'}): missing legacy PTC opcode"
        )

    if opcode.startswith("PTC_OP_"):
        raise SystemExit(
            f"cannot materialize QEMU v2 opcode {opcode} at instruction "
            f"{instruction_source_index(inst)} without an explicit legacy lowering"
        )

    return None


def infer_dynamic_pc(
    renumbered_instructions: list[dict[str, Any]],
    selected_temps: list[dict[str, Any]],
    pc_delta: int,
) -> int | None:
    pc_temp_indices: set[int] = set()
    temp_values: dict[int, int] = {}
    for temp in selected_temps:
        temp_index = parse_int_like(temp.get("index"))
        if temp_index is None:
            continue
        temp_name = str(temp.get("name") or "").lower()
        if temp_name in {"pc", "eip", "rip"}:
            pc_temp_indices.add(temp_index)
        value = temp_model_value(temp)
        if value is not None:
            temp_values[temp_index] = value

    dynamic_pc: int | None = None
    for inst in renumbered_instructions:
        if instruction_opcode(inst) not in {"mov_i32", "mov_i64"}:
            continue
        inst_args = inst.get("args")
        if not isinstance(inst_args, list) or len(inst_args) < 2:
            continue
        dst = parse_int_like(inst_args[0])
        src = parse_int_like(inst_args[1])
        if dst not in pc_temp_indices or src is None:
            continue
        value = temp_values.get(src)
        if value is not None:
            dynamic_pc = value + pc_delta
    return dynamic_pc


def annotate_direct_exit_tb_targets(
    renumbered_instructions: list[dict[str, Any]],
    selected_temps: list[dict[str, Any]],
    lowered_instructions: list[dict[str, Any]],
    pc_delta: int,
) -> None:
    pc_temp_indices: set[int] = set()
    temp_values: dict[int, int] = {}
    for temp in selected_temps:
        temp_index = parse_int_like(temp.get("index"))
        if temp_index is None:
            continue
        temp_name = str(temp.get("name") or "").lower()
        if temp_name in {"pc", "eip", "rip"}:
            pc_temp_indices.add(temp_index)
        value = temp_model_value(temp)
        if value is not None:
            temp_values[temp_index] = value + pc_delta

    pending_pc: int | None = None
    for inst in renumbered_instructions:
        opcode = instruction_opcode(inst)
        inst_args = inst.get("args")
        if opcode in {"debug_insn_start", "set_label"}:
            pending_pc = None
            continue
        if opcode in {"mov_i32", "mov_i64"} and isinstance(inst_args, list) and len(inst_args) >= 2:
            dst = parse_int_like(inst_args[0])
            src = parse_int_like(inst_args[1])
            pending_pc = temp_values.get(src) if dst in pc_temp_indices and src is not None else pending_pc
            continue
        if opcode != "exit_tb":
            continue
        materializer = inst.get("materializer") if isinstance(inst.get("materializer"), dict) else {}
        if materializer.get("lowering") == "goto_ptr->exit_tb(0)":
            pending_pc = None
            continue
        if pending_pc is None:
            continue
        old_args = inst_args if isinstance(inst_args, list) else []
        old_arg = old_args[0] if old_args else None
        new_arg = hex(pending_pc)
        if str(old_arg) != new_arg:
            inst["args"] = [new_arg]
            model = inst.get("ptc_list_model")
            if isinstance(model, dict):
                model["argument_count"] = 1
                model["not_real_abi"] = False
            lowering = f"exit_tb target annotated from pc-store {new_arg}"
            inst.setdefault("materializer", {})["exit_tb_target"] = new_arg
            inst.setdefault("materializer", {})["exit_tb_target_lowering"] = lowering
            lowered_instructions.append(
                {
                    "new_index": inst.get("index"),
                    "source_index": inst.get("source_index"),
                    "walker_name": (inst.get("walker") or {}).get("name"),
                    "canonical_name": walker_canonical_name(inst),
                    "lowering": lowering,
                    "old_arg": old_arg,
                }
            )
        pending_pc = None


def main() -> int:
    args = parse_args()
    model = load_json(args.model_json)
    manifest = load_json(args.manifest_json) if args.manifest_json else None
    instructions = model.get("instructions")
    temps = model.get("temps")
    if not isinstance(instructions, list) or not isinstance(temps, list):
        raise SystemExit(f"model is missing instructions/temps arrays: {args.model_json}")

    source_rejected = [
        inst for inst in instructions
        if not bool((inst.get("decision") or {}).get("emitted", False))
    ]

    captured_pc = int(args.captured_pc, 0)
    canonical_pc = int(args.canonical_pc, 0)
    pc_delta = canonical_pc - captured_pc

    requested_candidates = [captured_pc, canonical_pc]
    selected_tb_pc = next(
        (
            walker_tb_pc(inst) for inst in instructions
            if walker_tb_pc(inst) in requested_candidates
        ),
        None,
    )
    selected_pc_matched = selected_tb_pc is not None
    debug_indices = [
        i for i, inst in enumerate(instructions)
        if instruction_opcode(inst) == "debug_insn_start"
    ]
    debug_index = None
    if selected_tb_pc is None:
        debug_index = next(
            (
                i for i in debug_indices
                if debug_insn_start_pc(instructions[i]) in requested_candidates
            ),
            None,
        )
        if debug_index is not None:
            selected_tb_pc = walker_tb_pc(instructions[debug_index])
            selected_pc_matched = selected_tb_pc is not None
    else:
        debug_index = next(
            (
                i for i in debug_indices
                if walker_tb_pc(instructions[i]) == selected_tb_pc
                and debug_insn_start_pc(instructions[i]) in requested_candidates
            ),
            None,
        )
        if debug_index is None:
            debug_index = next(
                (i for i in debug_indices if walker_tb_pc(instructions[i]) == selected_tb_pc),
                None,
            )
    if debug_index is None:
        debug_index = debug_indices[0] if debug_indices else None
    if debug_index is None:
        raise SystemExit(f"replay source model has no debug_insn_start instruction: {args.model_json}")

    if selected_tb_pc is None:
        selected_tb_pc = walker_tb_pc(instructions[debug_index])
    if selected_tb_pc is None:
        raise SystemExit(f"selected debug instruction has no walker tb_pc: {args.model_json}")

    selected_instructions = [
        inst for index, inst in enumerate(instructions)
        if index >= debug_index and walker_tb_pc(inst) == selected_tb_pc
    ]
    if not selected_instructions:
        raise SystemExit(f"replay source model is missing instructions for tb_pc={hex(selected_tb_pc)}: {args.model_json}")

    temp_by_walker_arg: dict[str, dict[str, Any]] = {}
    for temp in temps:
        walker_arg = temp.get("walker_arg")
        if walker_arg is not None:
            temp_by_walker_arg[str(walker_arg)] = temp

    dropped_boundary_positions = {
        index
        for index in range(len(selected_instructions))
        if is_lookup_tb_call_boundary(selected_instructions, index)
    }

    selected_temp_indices: list[int] = []
    selected_temp_set: set[int] = set()
    for selected_index, inst in enumerate(selected_instructions):
        if selected_index in dropped_boundary_positions:
            continue
        if not needs_temp_args_before_lowering(inst):
            continue
        for arg in inst.get("args", []):
            temp = temp_by_walker_arg.get(str(arg))
            if temp is None:
                continue
            temp_index = int(temp["index"])
            if temp_index not in selected_temp_set:
                selected_temp_set.add(temp_index)
                selected_temp_indices.append(temp_index)

    def temp_sort_key(temp_index: int) -> tuple[int, int]:
        temp = temps[temp_index]
        flags = temp.get("flags", {})
        return (0 if flags.get("is_global") else 1, int(temp["index"]))

    ordered_temp_indices = sorted(selected_temp_indices, key=temp_sort_key)
    if 0 not in ordered_temp_indices and any(temp.get("index") == 0 for temp in temps):
        ordered_temp_indices = [0] + [i for i in ordered_temp_indices if i != 0]

    temp_remap = {old_index: new_index for new_index, old_index in enumerate(ordered_temp_indices)}

    selected_temps: list[dict[str, Any]] = []
    for new_index, old_index in enumerate(ordered_temp_indices):
        temp = dict(temps[old_index])
        temp["index"] = new_index
        temp["temp_id"] = new_index
        temp["temp_index"] = new_index
        selected_temps.append(temp)

    renumbered_instructions: list[dict[str, Any]] = []
    payload_argument_count = 0
    normalized_debug_pc_count = 0
    lowered_instructions: list[dict[str, Any]] = []
    vector_halves: dict[int, tuple[VectorHalf, ...]] = {}
    vector_const_temps: dict[int, int] = {}
    for selected_index, inst in enumerate(selected_instructions):
        if selected_index in dropped_boundary_positions:
            lowered_instructions.append(
                {
                    "new_index": None,
                    "source_index": inst.get("index"),
                    "walker_name": (inst.get("walker") or {}).get("name"),
                    "canonical_name": walker_canonical_name(inst),
                    "lowering": "call+goto_ptr->exit_tb boundary: dropped lookup_tb_ptr call",
                    "dropped": True,
                }
            )
            continue

        new_index = len(renumbered_instructions)
        inst_copy = json.loads(json.dumps(inst))
        inst_copy["source_index"] = inst.get("index")
        inst_copy["index"] = new_index
        mapped_args: list[str] = []
        map_temp_args = needs_temp_args_before_lowering(inst)
        for arg_pos, arg in enumerate(inst.get("args", [])):
            temp = temp_by_walker_arg.get(str(arg)) if map_temp_args else None
            if temp is not None:
                old_index = int(temp["index"])
                if old_index not in temp_remap:
                    raise SystemExit(
                        f"replay source model instruction {inst.get('index')} references temp {old_index} "
                        "not captured by the selected replay subset"
                    )
                mapped_args.append(str(temp_remap[old_index]))
                continue
            if (
                args.normalize_debug_pc
                and arg_pos == 0
                and instruction_opcode(inst) == "debug_insn_start"
            ):
                try:
                    mapped_value = int(str(arg).strip(), 0) + pc_delta
                except ValueError:
                    mapped_args.append(arg)
                else:
                    mapped_args.append(hex(mapped_value))
                    normalized_debug_pc_count += 1
                continue
            mapped_args.append(arg)
        inst_copy["args"] = mapped_args
        if instruction_opcode(inst_copy) == "debug_insn_start":
            walker = inst_copy.get("walker")
            if isinstance(walker, dict):
                walker["pc"] = hex(canonical_pc if args.normalize_debug_pc else captured_pc)
        expanded = (
            expand_qemu_v2_test_brcond(inst_copy, selected_temps)
            or expand_qemu_v2_test_movcond(inst_copy, selected_temps)
            or expand_qemu_v2_test_setcond(inst_copy, selected_temps)
            or expand_qemu_v2_ld_vec(inst_copy, selected_temps, vector_halves)
            or expand_qemu_v2_mov_vec(inst_copy, selected_temps, vector_halves)
            or expand_qemu_v2_st_vec(inst_copy, selected_temps, vector_halves, vector_const_temps)
            or expand_qemu_v2_extract_i64(inst_copy, selected_temps, vector_const_temps)
            or expand_qemu_v2_ctz(inst_copy, selected_temps, vector_const_temps)
            or expand_qemu_v2_negsetcond(inst_copy, selected_temps)
            or expand_qemu_v2_qemu_st2(inst_copy, selected_temps)
        )
        if expanded is not None:
            expanded_instructions, lowering = expanded
            lowering_record = {
                "new_index": new_index,
                "source_index": inst.get("index"),
                "walker_name": (inst.get("walker") or {}).get("name"),
                "canonical_name": walker_canonical_name(inst),
                "lowering": lowering,
                "emitted_instruction_count": len(expanded_instructions),
            }
            if len(expanded_instructions) > 1:
                lowering_record["inserted_instruction_count"] = len(expanded_instructions) - 1
            lowered_instructions.append(lowering_record)
            renumbered_instructions.extend(expanded_instructions)
            payload_argument_count += sum(len(expanded_inst["args"]) for expanded_inst in expanded_instructions)
            continue
        lowering = lower_to_legacy_ptc(inst_copy)
        if lowering is not None:
            inst_copy.setdefault("materializer", {})["lowering"] = lowering
            lowered_instructions.append(
                {
                    "new_index": new_index,
                    "source_index": inst.get("index"),
                    "walker_name": (inst.get("walker") or {}).get("name"),
                    "canonical_name": walker_canonical_name(inst),
                    "lowering": lowering,
                }
            )
        renumbered_instructions.append(inst_copy)
        payload_argument_count += len(inst_copy["args"])

    annotate_direct_exit_tb_targets(
        renumbered_instructions,
        selected_temps,
        lowered_instructions,
        pc_delta if args.normalize_debug_pc else 0,
    )
    helper_defs = collect_helper_defs(renumbered_instructions)

    global_temps = sum(1 for temp in selected_temps if (temp.get("flags") or {}).get("is_global"))
    if global_temps == 0:
        raise SystemExit(f"replay source model selected no global temps: {args.model_json}")
    first_selected_debug = next(
        (inst for inst in renumbered_instructions if instruction_opcode(inst) == "debug_insn_start"),
        None,
    )
    first_selected_debug_pc = (
        first_selected_debug["args"][0]
        if first_selected_debug is not None and first_selected_debug.get("args")
        else None
    )
    dynamic_pc = infer_dynamic_pc(
        renumbered_instructions,
        selected_temps,
        pc_delta if args.normalize_debug_pc else 0,
    )

    summary = {
        "schema": "qemu-v2-ptc-live-sidecar-summary-v1",
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "source_model_json": str(args.model_json),
        "source_manifest_json": str(args.manifest_json) if args.manifest_json else None,
        "source_instruction_count": len(instructions),
        "source_temp_count": len(temps),
        "selected_instruction_count": len(renumbered_instructions),
        "selected_argument_count": payload_argument_count,
        "selected_temp_count": len(selected_temps),
        "selected_global_temps": global_temps,
        "captured_actual_pc": hex(captured_pc),
        "canonical_requested_pc": hex(canonical_pc),
        "debug_pc_normalized": bool(args.normalize_debug_pc),
        "debug_pc_delta": hex(pc_delta),
        "normalized_debug_insn_start_count": normalized_debug_pc_count,
        "first_debug_insn_start_pc": first_selected_debug_pc,
        "dynamic_pc": hex(dynamic_pc) if dynamic_pc is not None else None,
        "selected_debug_index": debug_index,
        "selected_tb_pc": hex(selected_tb_pc),
        "selected_debug_source_pc": (
            hex(debug_insn_start_pc(instructions[debug_index]))
            if debug_index is not None and debug_insn_start_pc(instructions[debug_index]) is not None
            else None
        ),
        "selected_pc_matched_request": selected_pc_matched,
        "source_rejected_instruction_count": len(source_rejected),
        "rejected_instruction_count": 0,
        "rejected_instruction": None,
        "helper_def_count": len(helper_defs),
        "helper_defs": helper_defs,
        "lowered_instruction_count": len(lowered_instructions),
        "lowered_instructions": lowered_instructions,
        "payload_format": "PTC_LIVE_SIDECAR v1",
        "payload_instruction_count": len(renumbered_instructions),
        "payload_argument_count": payload_argument_count,
        "payload_temp_count": len(selected_temps),
    }

    side_root = args.output_root / "sidecar"
    side_root.mkdir(parents=True, exist_ok=True)
    payload_path = side_root / "sidecar.payload.txt"
    model_path = side_root / "sidecar.model.json"
    summary_path = side_root / "sidecar.summary.json"

    model_out = {
        "schema": "qemu-v2-ptc-live-sidecar-model-v1",
        "generated_at_utc": summary["generated_at_utc"],
        "source_model_json": str(args.model_json),
        "source_manifest_json": str(args.manifest_json) if args.manifest_json else None,
        "captured_actual_pc": hex(captured_pc),
        "canonical_requested_pc": hex(canonical_pc),
        "debug_pc_normalized": bool(args.normalize_debug_pc),
        "debug_pc_delta": hex(pc_delta),
        "dynamic_pc": hex(dynamic_pc) if dynamic_pc is not None else None,
        "summary": {
            "instruction_count": len(renumbered_instructions),
            "argument_count": payload_argument_count,
            "temp_count": len(selected_temps),
            "global_temps": global_temps,
            "total_temps": len(selected_temps),
        },
        "lowered_instructions": lowered_instructions,
        "helper_defs": helper_defs,
        "instructions": renumbered_instructions,
        "temps": selected_temps,
    }
    if manifest is not None:
        model_out["source_manifest_schema"] = manifest.get("schema")
    if summary["rejected_instruction"] is not None:
        model_out["rejected_instruction"] = summary["rejected_instruction"]

    payload_lines = [
        "PTC_LIVE_SIDECAR v1",
        f"instruction_count={len(renumbered_instructions)}",
        f"argument_count={payload_argument_count}",
        f"temp_count={len(selected_temps)}",
        f"global_temps={global_temps}",
        f"total_temps={len(selected_temps)}",
        f"model_json={model_path}",
        f"summary_json={summary_path}",
        f"payload_source={args.model_json}",
    ]
    if dynamic_pc is not None:
        payload_lines.append(f"dynamic_pc={hex(dynamic_pc)}")
    for helper in helper_defs:
        payload_lines.append(
            "helper|%s|%s|%d"
            % (
                helper["func"],
                payload_helper_name(helper["name"]),
                int(helper["flags"]),
            )
        )
    for inst in renumbered_instructions:
        model_entry = inst["ptc_list_model"]
        args_csv = ",".join(str(arg) for arg in inst["args"])
        payload_lines.append(
            "instruction|%d|%s|%s|%s|%d|%s"
            % (
                int(inst["index"]),
                model_entry["opc"],
                to_int(model_entry["callo"]),
                to_int(model_entry["calli"]),
                len(inst["args"]),
                args_csv,
            )
        )
    for temp in selected_temps:
        model_entry = temp["ptc_temp_model"]
        temp_name = temp.get("name") or f"temp_{int(temp['index'])}"
        temp_val = model_entry["val"]
        payload_lines.append(
            "temp|%d|%s|%d|%d|%d|%d|%d|%d|%s|%d|%d|%d|%d|%d"
            % (
                int(temp["index"]),
                str(temp_name).replace("|", "/"),
                to_int(model_entry["val_type"]),
                to_int(model_entry["base_type"]),
                to_int(model_entry["type"]),
                to_int(model_entry["reg"]),
                to_int(model_entry["mem_reg"]),
                to_int(model_entry["mem_offset"]),
                "0" if temp_val is None else temp_val,
                1 if model_entry["fixed_reg"] else 0,
                1 if model_entry["mem_coherent"] else 0,
                1 if model_entry["mem_allocated"] else 0,
                1 if model_entry["temp_local"] else 0,
                1 if model_entry["temp_allocated"] else 0,
            )
        )
    payload_text = "\n".join(payload_lines) + "\n"

    payload_path.write_text(payload_text, encoding="utf-8")
    model_path.write_text(json.dumps(model_out, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(f"payload_path={payload_path}")
    print(f"model_path={model_path}")
    print(f"summary_path={summary_path}")
    print(f"instruction_count={len(renumbered_instructions)}")
    print(f"argument_count={payload_argument_count}")
    print(f"temp_count={len(selected_temps)}")
    print(f"global_temps={global_temps}")
    print(f"debug_pc={summary['first_debug_insn_start_pc']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
