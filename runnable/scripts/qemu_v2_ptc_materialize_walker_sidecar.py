#!/usr/bin/env python3
"""Materialize a replayable sidecar root from a walker conversion model."""

from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
from typing import Any


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


def to_int(value: Any) -> int:
    return 0 if value is None else int(value)


def main() -> int:
    args = parse_args()
    model = load_json(args.model_json)
    manifest = load_json(args.manifest_json) if args.manifest_json else None
    instructions = model.get("instructions")
    temps = model.get("temps")
    if not isinstance(instructions, list) or not isinstance(temps, list):
        raise SystemExit(f"model is missing instructions/temps arrays: {args.model_json}")

    rejected = [
        inst for inst in instructions
        if not bool((inst.get("decision") or {}).get("emitted", False))
    ]
    first_rejected = rejected[0] if rejected else None

    debug_index = next(
        (i for i, inst in enumerate(instructions) if instruction_opcode(inst) == "debug_insn_start"),
        None,
    )
    if debug_index is None:
        raise SystemExit(f"replay source model has no debug_insn_start instruction: {args.model_json}")

    next_debug_index = next(
        (i for i in range(debug_index + 1, len(instructions)) if instruction_opcode(instructions[i]) == "debug_insn_start"),
        len(instructions),
    )
    selected_instructions = instructions[debug_index:next_debug_index]
    if not selected_instructions:
        raise SystemExit(f"replay source model is missing instructions after debug_insn_start: {args.model_json}")

    captured_pc = int(args.captured_pc, 0)
    canonical_pc = int(args.canonical_pc, 0)
    pc_delta = canonical_pc - captured_pc

    temp_by_walker_arg: dict[str, dict[str, Any]] = {}
    for temp in temps:
        walker_arg = temp.get("walker_arg")
        if walker_arg is not None:
            temp_by_walker_arg[str(walker_arg)] = temp

    selected_temp_indices: list[int] = []
    selected_temp_set: set[int] = set()
    for inst in selected_instructions:
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
    for new_index, inst in enumerate(selected_instructions):
        inst_copy = json.loads(json.dumps(inst))
        inst_copy["index"] = new_index
        mapped_args: list[str] = []
        for arg_pos, arg in enumerate(inst.get("args", [])):
            temp = temp_by_walker_arg.get(str(arg))
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
        renumbered_instructions.append(inst_copy)
        payload_argument_count += len(mapped_args)

    global_temps = sum(1 for temp in selected_temps if (temp.get("flags") or {}).get("is_global"))
    if global_temps == 0:
        raise SystemExit(f"replay source model selected no global temps: {args.model_json}")

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
        "first_debug_insn_start_pc": renumbered_instructions[0]["args"][0] if renumbered_instructions else None,
        "rejected_instruction_count": len(rejected),
        "rejected_instruction": None,
        "payload_format": "PTC_LIVE_SIDECAR v1",
        "payload_instruction_count": len(renumbered_instructions),
        "payload_argument_count": payload_argument_count,
        "payload_temp_count": len(selected_temps),
    }
    if first_rejected is not None:
        summary["rejected_instruction"] = {
            "index": first_rejected.get("index"),
            "walker_name": (first_rejected.get("walker") or {}).get("name"),
            "canonical_name": (first_rejected.get("walker") or {}).get("canonical_name"),
            "opcode": (first_rejected.get("walker") or {}).get("opcode"),
            "reject_reason": (first_rejected.get("decision") or {}).get("reject_reason"),
            "args": first_rejected.get("args"),
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
        "summary": {
            "instruction_count": len(renumbered_instructions),
            "argument_count": payload_argument_count,
            "temp_count": len(selected_temps),
            "global_temps": global_temps,
            "total_temps": len(selected_temps),
        },
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
