#!/usr/bin/env python3
"""Inventory TCG op observations against the legacy PTC opcode ABI."""

from __future__ import annotations

import argparse
import collections
import dataclasses
import json
import re
import sys
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_LEGACY_OPC = REPO_ROOT / "archive" / "qemu-legacy-2.4.50" / "tcg" / "tcg-opc.h"

OP_LINE_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\b(?:\s+(.*))?$")
HEADER_RE = re.compile(r"^====\s+rr tcg dump:\s*(.*?)\s*====$")
KEY_VALUE_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)")

EXACT_ALIASES: dict[str, tuple[str, ...]] = {
    "insn_start": ("debug_insn_start",),
}

BASE_RENAMES: dict[str, str] = {
    "divs": "div",
    "rems": "rem",
}

GENERIC_INT_BASES = {
    "add",
    "and",
    "andc",
    "brcond",
    "bswap16",
    "bswap32",
    "bswap64",
    "deposit",
    "divu",
    "eqv",
    "ld",
    "ld8s",
    "ld8u",
    "ld16s",
    "ld16u",
    "ld32s",
    "ld32u",
    "mov",
    "movcond",
    "mul",
    "muls2",
    "mulsh",
    "mulu2",
    "muluh",
    "nand",
    "neg",
    "nor",
    "not",
    "or",
    "orc",
    "remu",
    "rotl",
    "rotr",
    "sar",
    "setcond",
    "shl",
    "shr",
    "st",
    "st8",
    "st16",
    "st32",
    "sub",
    "xor",
}

QEMU_MEMORY_BASES = {
    "qemu_ld": ("qemu_ld_i32", "qemu_ld_i64"),
    "qemu_st": ("qemu_st_i32", "qemu_st_i64"),
}

COMPATIBILITY_CLASSES = (
    "direct",
    "alias",
    "requires-ptc-v2-op",
    "requires-operand-schema",
    "unknown",
)

RECOMMEND_OLD_ABI = "old-abi-compatible"
RECOMMEND_NEW_OPCODE = "needs-new-ptc-opcode"
RECOMMEND_VECTOR_SCHEMA = "needs-vector-operand-schema"
RECOMMEND_UNKNOWN = "unknown"


@dataclasses.dataclass(frozen=True)
class CompatRule:
    compatibility: str
    recommendation: str
    safe_legacy_mapping: bool
    legacy_aliases: tuple[str, ...] = ()
    proposed_ptc_v2_opcode: str = ""
    note: str = ""


DEFAULT_COMPAT_RULES: dict[str, CompatRule] = {
    "insn_start": CompatRule(
        compatibility="alias",
        recommendation=RECOMMEND_OLD_ABI,
        safe_legacy_mapping=True,
        legacy_aliases=("debug_insn_start",),
        note="modern instruction marker name maps to legacy debug_insn_start",
    ),
    "mov_vec": CompatRule(
        compatibility="requires-operand-schema",
        recommendation=RECOMMEND_VECTOR_SCHEMA,
        safe_legacy_mapping=False,
        proposed_ptc_v2_opcode="PTC_OP_MOV_VEC",
        note=(
            "vector move carries vector width, element size, and vector temp/constant "
            "operands; no legacy PTCOpcode can encode those operands safely"
        ),
    ),
    "ld_vec": CompatRule(
        compatibility="requires-operand-schema",
        recommendation=RECOMMEND_VECTOR_SCHEMA,
        safe_legacy_mapping=False,
        proposed_ptc_v2_opcode="PTC_OP_LD_VEC",
        note=(
            "vector load carries vector width, element size, env/base, offset, and "
            "vector destination operands; legacy scalar ld_* opcodes are not safe aliases"
        ),
    ),
    "st_vec": CompatRule(
        compatibility="requires-operand-schema",
        recommendation=RECOMMEND_VECTOR_SCHEMA,
        safe_legacy_mapping=False,
        proposed_ptc_v2_opcode="PTC_OP_ST_VEC",
        note=(
            "vector store carries vector width, element size, vector source, env/base, "
            "and offset operands; legacy scalar st_* opcodes are not safe aliases"
        ),
    ),
    "qemu_ld2_i128": CompatRule(
        compatibility="requires-ptc-v2-op",
        recommendation=RECOMMEND_NEW_OPCODE,
        safe_legacy_mapping=False,
        proposed_ptc_v2_opcode="PTC_OP_QEMU_LD2_I128",
        note=(
            "paired 128-bit qemu memory load has no old qemu_ld_i* opcode equivalent; "
            "lowering to scalar loads needs a separate memory-semantics proof"
        ),
    ),
    "qemu_ld2": CompatRule(
        compatibility="requires-ptc-v2-op",
        recommendation=RECOMMEND_NEW_OPCODE,
        safe_legacy_mapping=False,
        proposed_ptc_v2_opcode="PTC_OP_QEMU_LD2",
        note=(
            "walker raw opcode name omits the text dump's _i128 suffix; keep it "
            "distinct until param1/param2 and memory operands are mapped into a "
            "PTC v2 schema, not a legacy qemu_ld_i* direct hit"
        ),
    ),
    "qemu_st2_i128": CompatRule(
        compatibility="requires-ptc-v2-op",
        recommendation=RECOMMEND_NEW_OPCODE,
        safe_legacy_mapping=False,
        proposed_ptc_v2_opcode="PTC_OP_QEMU_ST2_I128",
        note=(
            "paired 128-bit qemu memory store has no old qemu_st_i* opcode equivalent; "
            "lowering to scalar stores needs a separate memory-semantics proof"
        ),
    ),
    "qemu_st2": CompatRule(
        compatibility="requires-ptc-v2-op",
        recommendation=RECOMMEND_NEW_OPCODE,
        safe_legacy_mapping=False,
        proposed_ptc_v2_opcode="PTC_OP_QEMU_ST2",
        note=(
            "walker raw opcode name omits the text dump's _i128 suffix; keep it "
            "distinct until param1/param2 and memory operands are mapped into a "
            "PTC v2 schema, not a legacy qemu_st_i* direct hit"
        ),
    ),
    "extract": CompatRule(
        compatibility="requires-ptc-v2-op",
        recommendation=RECOMMEND_NEW_OPCODE,
        safe_legacy_mapping=False,
        proposed_ptc_v2_opcode="PTC_OP_EXTRACT",
        note=(
            "walker raw opcode name omits the text dump's type suffix; using "
            "shifts and masks would be a lowering pass, not a safe PTCOpcode alias"
        ),
    ),
    "extract_i64": CompatRule(
        compatibility="requires-ptc-v2-op",
        recommendation=RECOMMEND_NEW_OPCODE,
        safe_legacy_mapping=False,
        proposed_ptc_v2_opcode="PTC_OP_EXTRACT_I64",
        note=(
            "modern bit extract is absent from the legacy opcode file; using shifts "
            "and masks would be a lowering pass, not a safe PTCOpcode alias"
        ),
    ),
    "sextract": CompatRule(
        compatibility="requires-ptc-v2-op",
        recommendation=RECOMMEND_NEW_OPCODE,
        safe_legacy_mapping=False,
        proposed_ptc_v2_opcode="PTC_OP_SEXTRACT",
        note=(
            "walker raw opcode name omits the text dump's type suffix; using "
            "signed shifts or sign-extension ops is a lowering pass, not a "
            "safe PTCOpcode alias"
        ),
    ),
    "sextract_i64": CompatRule(
        compatibility="requires-ptc-v2-op",
        recommendation=RECOMMEND_NEW_OPCODE,
        safe_legacy_mapping=False,
        proposed_ptc_v2_opcode="PTC_OP_SEXTRACT_I64",
        note=(
            "modern signed bit extract is absent from the legacy opcode file; "
            "offset-zero slices can lower to signed-extension legacy ops"
        ),
    ),
    "sextract_i32": CompatRule(
        compatibility="requires-ptc-v2-op",
        recommendation=RECOMMEND_NEW_OPCODE,
        safe_legacy_mapping=False,
        proposed_ptc_v2_opcode="PTC_OP_SEXTRACT_I32",
        note=(
            "modern signed bit extract is absent from the legacy opcode file; "
            "offset-zero slices can lower to signed-extension legacy ops"
        ),
    ),
}


@dataclasses.dataclass(frozen=True)
class LegacyOpcodeDef:
    name: str
    oargs: str
    iargs: str
    cargs: str
    flags: str
    line: int
    ordinal: int

    @property
    def total_arity(self) -> int | None:
        parts = [parse_literal_int(self.oargs), parse_literal_int(self.iargs), parse_literal_int(self.cargs)]
        if any(part is None for part in parts):
            return None
        return sum(part for part in parts if part is not None)


@dataclasses.dataclass
class DumpStats:
    path: Path
    source_type: str = "text-dump"
    op_lines: int = 0
    marker_lines: int = 0
    json_lines: int = 0
    metadata_records: int = 0
    headers: list[dict[str, object]] = dataclasses.field(default_factory=list)
    skipped_lines: list[tuple[int, str]] = dataclasses.field(default_factory=list)


@dataclasses.dataclass(frozen=True)
class OpcodeReport:
    name: str
    count: int
    files: tuple[str, ...]
    arities: tuple[tuple[int, int], ...]
    status: str
    compatibility: str
    recommendation: str
    safe_legacy_mapping: bool
    legacy: tuple[str, ...]
    arity_status: str
    proposed_ptc_v2_opcode: str
    compatibility_note: str
    note: str
    sample: str


def strip_c_comments(text: str) -> str:
    def replace_block(match: re.Match[str]) -> str:
        return "\n" * match.group(0).count("\n")

    without_blocks = re.sub(r"/\*.*?\*/", replace_block, text, flags=re.DOTALL)
    return re.sub(r"//.*", "", without_blocks)


def split_top_level_commas(text: str) -> list[str]:
    fields: list[str] = []
    start = 0
    depth = 0
    for index, char in enumerate(text):
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif char == "," and depth == 0:
            fields.append(text[start:index].strip())
            start = index + 1
    fields.append(text[start:].strip())
    return fields


def parse_literal_int(expr: str) -> int | None:
    expr = expr.strip()
    if re.fullmatch(r"[0-9]+", expr):
        return int(expr, 10)
    return None


def parse_legacy_opc(path: Path) -> list[LegacyOpcodeDef]:
    text = strip_c_comments(path.read_text())
    defs: list[LegacyOpcodeDef] = []
    ordinal = 0
    for match in re.finditer(r"\bDEF\s*\(", text):
        start = match.end()
        depth = 1
        index = start
        while index < len(text) and depth:
            char = text[index]
            if char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
            index += 1
        if depth != 0:
            raise ValueError(f"{path}: unterminated DEF(...) starting at byte {match.start()}")

        body = text[start : index - 1]
        fields = split_top_level_commas(body)
        if len(fields) < 5:
            line = text.count("\n", 0, match.start()) + 1
            raise ValueError(f"{path}:{line}: expected 5 DEF fields, got {len(fields)}")

        name = fields[0].strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            continue
        defs.append(
            LegacyOpcodeDef(
                name=name,
                oargs=fields[1],
                iargs=fields[2],
                cargs=fields[3],
                flags=fields[4],
                line=text.count("\n", 0, match.start()) + 1,
                ordinal=ordinal,
            )
        )
        ordinal += 1
    return defs


def parse_dump_args(rest: str | None) -> list[str]:
    if not rest or not rest.strip():
        return []
    return [part.strip() for part in rest.split(",") if part.strip()]


def parse_header(line: str) -> dict[str, object]:
    match = HEADER_RE.match(line.strip())
    if not match:
        return {}
    parsed: dict[str, object] = {}
    for key, raw_value in KEY_VALUE_RE.findall(match.group(1)):
        try:
            parsed[key] = int(raw_value, 0)
        except ValueError:
            parsed[key] = raw_value
    return parsed


def parse_dump_file(
    path: Path,
    counts: collections.Counter[str],
    arities: dict[str, collections.Counter[int]],
    files_by_op: dict[str, set[str]],
    samples: dict[str, str],
) -> DumpStats:
    stats = DumpStats(path=path)
    with path.open() as stream:
        for line_number, line in enumerate(stream, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith("===="):
                header = parse_header(stripped)
                if header:
                    stats.headers.append(header)
                continue
            if stripped.startswith("----"):
                stats.marker_lines += 1
                continue

            match = OP_LINE_RE.match(line)
            if not match:
                stats.skipped_lines.append((line_number, stripped))
                continue

            name = match.group(1)
            args = parse_dump_args(match.group(2))
            counts[name] += 1
            arities.setdefault(name, collections.Counter())[len(args)] += 1
            files_by_op.setdefault(name, set()).add(str(path))
            samples.setdefault(name, stripped)
            stats.op_lines += 1
    return stats


def walker_opcode_name(record: object) -> str:
    if not isinstance(record, dict):
        return ""

    name = record.get("name")
    if isinstance(name, str) and name:
        return name

    opcode = record.get("opcode")
    if isinstance(opcode, str) and opcode:
        if opcode.startswith("INDEX_op_"):
            return opcode.removeprefix("INDEX_op_")
        return opcode

    return ""


def walker_arg_count(record: dict[str, object]) -> int | None:
    for key in ("arg_count", "def_args", "nb_args"):
        value = record.get(key)
        if isinstance(value, int):
            return value

    args = record.get("args")
    if isinstance(args, list):
        return len(args)

    return None


def parse_walker_jsonl_file(
    path: Path,
    counts: collections.Counter[str],
    arities: dict[str, collections.Counter[int]],
    files_by_op: dict[str, set[str]],
    samples: dict[str, str],
) -> DumpStats:
    stats = DumpStats(path=path, source_type="walker-jsonl")
    with path.open() as stream:
        for line_number, line in enumerate(stream, start=1):
            stripped = line.strip()
            if not stripped:
                continue

            stats.json_lines += 1
            try:
                record = json.loads(stripped)
            except json.JSONDecodeError as error:
                stats.skipped_lines.append((line_number, f"invalid JSON: {error.msg}"))
                continue

            if not isinstance(record, dict):
                stats.skipped_lines.append((line_number, "JSONL record is not an object"))
                continue

            event = record.get("event")
            name = walker_opcode_name(record)
            is_op_record = event == "op" or (event is None and bool(name))
            if not is_op_record:
                stats.metadata_records += 1
                if event == "tb":
                    stats.headers.append(
                        {
                            "pc": record.get("pc", record.get("tb_pc", "?")),
                            "tb_pc": record.get("tb_pc", record.get("pc", "?")),
                            "nb_ops": record.get("tb_nb_ops", "?"),
                            "icount": record.get("tb_icount", "?"),
                            "tb_size": record.get("tb_size", "?"),
                            "nb_temps": record.get("nb_temps", "?"),
                            "nb_globals": record.get("nb_globals", "?"),
                        }
                    )
                continue

            if not name:
                stats.skipped_lines.append((line_number, "op record has no opcode name"))
                continue

            counts[name] += 1
            arity = walker_arg_count(record)
            if arity is not None:
                arities.setdefault(name, collections.Counter())[arity] += 1
            else:
                arities.setdefault(name, collections.Counter())
            files_by_op.setdefault(name, set()).add(str(path))
            samples.setdefault(name, stripped)
            stats.op_lines += 1
    return stats


def legacy_by_name(defs: Iterable[LegacyOpcodeDef]) -> dict[str, list[LegacyOpcodeDef]]:
    result: dict[str, list[LegacyOpcodeDef]] = {}
    for definition in defs:
        result.setdefault(definition.name, []).append(definition)
    return result


def candidate_aliases(name: str, legacy: dict[str, list[LegacyOpcodeDef]]) -> tuple[str, ...]:
    candidates: list[str] = []

    rule = DEFAULT_COMPAT_RULES.get(name)
    if rule:
        candidates.extend(target for target in rule.legacy_aliases if target in legacy)

    for target in EXACT_ALIASES.get(name, ()):
        if target in legacy:
            candidates.append(target)

    signed_match = re.fullmatch(r"(divs|rems)_(i32|i64)", name)
    if signed_match:
        target = f"{BASE_RENAMES[signed_match.group(1)]}_{signed_match.group(2)}"
        if target in legacy:
            candidates.append(target)

    if name in QEMU_MEMORY_BASES:
        candidates.extend(target for target in QEMU_MEMORY_BASES[name] if target in legacy)

    if name in GENERIC_INT_BASES:
        candidates.extend(target for target in (f"{name}_i32", f"{name}_i64") if target in legacy)

    if name in {"brcond", "setcond"}:
        candidates.extend(target for target in (f"{name}_i32", f"{name}_i64") if target in legacy)

    return tuple(dict.fromkeys(candidates))


def generic_alias_note(name: str, aliases: tuple[str, ...]) -> str:
    if name == "insn_start":
        return "modern instruction marker name maps to legacy debug_insn_start"
    if len(aliases) > 1:
        return "requires selecting a legacy typed opcode from operand type"
    if aliases:
        return "requires validating the renamed legacy opcode against modern operands"
    return ""


def compatibility_rule_for(
    name: str,
    status: str,
    aliases: tuple[str, ...],
) -> CompatRule:
    if status == "direct":
        return CompatRule(
            compatibility="direct",
            recommendation=RECOMMEND_OLD_ABI,
            safe_legacy_mapping=True,
            legacy_aliases=(name,),
        )

    explicit = DEFAULT_COMPAT_RULES.get(name)
    if status == "alias":
        if explicit and explicit.compatibility == "alias":
            return dataclasses.replace(explicit, legacy_aliases=aliases)
        return CompatRule(
            compatibility="alias",
            recommendation=RECOMMEND_OLD_ABI,
            safe_legacy_mapping=False,
            legacy_aliases=aliases,
            note=generic_alias_note(name, aliases),
        )

    if explicit and explicit.compatibility != "alias":
        return explicit

    return CompatRule(
        compatibility="unknown",
        recommendation=RECOMMEND_UNKNOWN,
        safe_legacy_mapping=False,
        note="no default compatibility rule; inspect modern TCG opcode semantics before ABI work",
    )


def arity_status(
    name: str,
    observed_arities: collections.Counter[int],
    definitions: Iterable[LegacyOpcodeDef],
    *,
    alias: bool = False,
) -> str:
    if name == "call":
        return "variable-call"

    totals = {definition.total_arity for definition in definitions}
    if None in totals:
        return "unknown-legacy-expression"
    numeric_totals = {total for total in totals if total is not None}
    if not numeric_totals:
        return "not-applicable"

    observed = set(observed_arities)
    if observed <= numeric_totals:
        return "alias-target-matches" if alias else "matches"
    return "alias-target-mismatch" if alias else "mismatch"


def note_for(name: str, status: str, arity: str, aliases: tuple[str, ...]) -> str:
    if name == "call":
        return "legacy PTC stores call output/input arity in callo/calli fields"
    if status == "alias":
        if name == "insn_start":
            return "modern instruction marker name maps to legacy debug_insn_start"
        if aliases:
            return "requires selecting a legacy typed/renamed opcode from operand type"
    if name.endswith("_vec") or "_vec" in name:
        return "modern vector TCG op; legacy PTC has no vector opcode family"
    if name.startswith("qemu_ld2") or name.startswith("qemu_st2"):
        return "modern paired memory op; requires lowering or a PTC ABI extension"
    if name.startswith("qemu_ld") or name.startswith("qemu_st"):
        return "modern memory op is not represented by the legacy qemu_ld_i*/qemu_st_i* ABI"
    if name in {"extract_i32", "extract_i64", "sextract_i32", "sextract_i64", "extract", "sextract"}:
        return "modern bit extract op; no direct legacy opcode"
    if arity.endswith("mismatch"):
        return "name exists but visible dump arity does not match legacy DEF arity"
    return ""


def build_opcode_reports(
    counts: collections.Counter[str],
    arities: dict[str, collections.Counter[int]],
    files_by_op: dict[str, set[str]],
    samples: dict[str, str],
    legacy: dict[str, list[LegacyOpcodeDef]],
) -> list[OpcodeReport]:
    reports: list[OpcodeReport] = []
    for name, count in sorted(counts.items(), key=lambda item: (-item[1], item[0])):
        if name in legacy:
            status = "direct"
            targets = (name,)
            arity = arity_status(name, arities[name], legacy[name])
        else:
            aliases = candidate_aliases(name, legacy)
            if aliases:
                status = "alias"
                targets = aliases
                alias_defs = [definition for alias in aliases for definition in legacy[alias]]
                arity = arity_status(name, arities[name], alias_defs, alias=True)
            else:
                status = "missing"
                targets = ()
                arity = "not-applicable"
        compat = compatibility_rule_for(name, status, targets)
        note = compat.note or note_for(name, status, arity, targets)
        reports.append(
            OpcodeReport(
                name=name,
                count=count,
                files=tuple(sorted(files_by_op.get(name, set()))),
                arities=tuple(sorted(arities[name].items())),
                status=status,
                compatibility=compat.compatibility,
                recommendation=compat.recommendation,
                safe_legacy_mapping=compat.safe_legacy_mapping,
                legacy=targets,
                arity_status=arity,
                proposed_ptc_v2_opcode=compat.proposed_ptc_v2_opcode,
                compatibility_note=compat.note,
                note=note,
                sample=samples.get(name, ""),
            )
        )
    return reports


def markdown_escape(text: object) -> str:
    return str(text).replace("|", "\\|")


def format_arities(arities: Iterable[tuple[int, int]]) -> str:
    return ", ".join(f"{arity} ({count}x)" for arity, count in arities)


def format_bool(value: bool) -> str:
    return "yes" if value else "no"


def format_table(headers: list[str], rows: list[list[object]]) -> str:
    if not rows:
        return "_None._\n"
    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(markdown_escape(cell) for cell in row) + " |")
    return "\n".join(lines) + "\n"


def summarize_headers(stats: DumpStats) -> str:
    if not stats.headers:
        return "0"
    parts: list[str] = []
    for header in stats.headers:
        pc = header.get("pc", "?")
        if isinstance(pc, int):
            pc_text = hex(pc)
        else:
            pc_text = str(pc)
        nb_ops = header.get("nb_ops", "?")
        icount = header.get("icount", "?")
        parts.append(f"pc={pc_text} nb_ops={nb_ops} icount={icount}")
    return "<br>".join(parts)


def input_stats_to_json(stats: DumpStats) -> dict[str, object]:
    return {
        "path": str(stats.path),
        "source_type": stats.source_type,
        "op_lines": stats.op_lines,
        "marker_lines": stats.marker_lines,
        "json_lines": stats.json_lines,
        "metadata_records": stats.metadata_records,
        "headers": stats.headers,
        "skipped_lines": stats.skipped_lines,
    }


def render_markdown(
    *,
    legacy_path: Path,
    legacy_defs: list[LegacyOpcodeDef],
    input_stats: list[DumpStats],
    reports: list[OpcodeReport],
) -> str:
    status_counts: dict[str, int] = collections.Counter(report.status for report in reports)
    status_occurrences: dict[str, int] = collections.Counter()
    compatibility_counts: dict[str, int] = collections.Counter(
        report.compatibility for report in reports
    )
    compatibility_occurrences: dict[str, int] = collections.Counter()
    for report in reports:
        status_occurrences[report.status] += report.count
        compatibility_occurrences[report.compatibility] += report.count

    duplicate_names = sorted(
        name for name, defs in legacy_by_name(legacy_defs).items() if len(defs) > 1
    )
    total_op_lines = sum(stats.op_lines for stats in input_stats)
    total_markers = sum(stats.marker_lines for stats in input_stats)
    total_json_lines = sum(stats.json_lines for stats in input_stats)
    total_metadata_records = sum(stats.metadata_records for stats in input_stats)
    has_walker_jsonl = any(stats.source_type == "walker-jsonl" for stats in input_stats)

    lines: list[str] = [
        "# QEMU TCG PTC Opcode Inventory",
        "",
        "This report is an opcode inventory only. It does not translate TCG ops,",
        "copy TCG args, copy temps, or build `PTCInstructionList`; it is a",
        "preflight map for a future `dump_tinycode(TCGContext*) ->",
        "PTCInstructionList` implementation.",
        "",
        "## Inputs",
        "",
        f"- Legacy opcode file: `{legacy_path}`",
        f"- Legacy DEF entries: {len(legacy_defs)}",
        f"- Legacy opcode names: {len(legacy_by_name(legacy_defs))}",
        f"- Duplicate legacy names: {', '.join(duplicate_names) if duplicate_names else 'none'}",
        "",
        format_table(
            [
                "Input",
                "source type",
                "TB headers",
                "marker lines",
                "JSONL lines",
                "metadata records",
                "op records",
                "skipped",
            ],
            [
                [
                    stats.path,
                    stats.source_type,
                    summarize_headers(stats),
                    stats.marker_lines,
                    stats.json_lines,
                    stats.metadata_records,
                    stats.op_lines,
                    len(stats.skipped_lines),
                ]
                for stats in input_stats
            ],
        ).rstrip(),
        "",
        "## Summary",
        "",
        f"- Total parsed op records: {total_op_lines}",
        f"- Total instruction marker lines: {total_markers}",
        f"- Total JSONL lines: {total_json_lines}",
        f"- Total non-op JSONL metadata records: {total_metadata_records}",
        f"- Unique opcodes: {len(reports)}",
        (
            "- Direct legacy hits: "
            f"{status_counts.get('direct', 0)} names / {status_occurrences.get('direct', 0)} occurrences"
        ),
        (
            "- Alias or compatibility candidates: "
            f"{status_counts.get('alias', 0)} names / {status_occurrences.get('alias', 0)} occurrences"
        ),
        (
            "- Missing from legacy PTC ABI: "
            f"{status_counts.get('missing', 0)} names / {status_occurrences.get('missing', 0)} occurrences"
        ),
        "",
        "Compatibility classification is separate from the legacy inventory",
        "status. `requires-*` means this inventory found no safe old",
        "`PTCOpcode` mapping; the C-side op walker and ABI must make an",
        "explicit migration decision before translation.",
        "",
        format_table(
            ["compatibility", "names", "occurrences"],
            [
                [
                    class_name,
                    compatibility_counts.get(class_name, 0),
                    compatibility_occurrences.get(class_name, 0),
                ]
                for class_name in COMPATIBILITY_CLASSES
            ],
        ).rstrip(),
        "",
    ]

    if has_walker_jsonl:
        lines.extend(
            [
                "Walker JSONL is closer to the real C-side `dump_tinycode`",
                "integration point because it walks `tcg_ctx->ops` after",
                "`translate_code`; it still records observations only and does",
                "not build `PTCInstructionList`.",
                "",
                "Raw walker names such as `qemu_ld2`/`qemu_st2` intentionally",
                "remain distinct from text dump names such as",
                "`qemu_ld2_i128`/`qemu_st2_i128`; this report does not silently",
                "promote them to legacy direct hits.",
                "",
            ]
        )

    if total_markers:
        lines.extend(
            [
                "Instruction marker lines in `tcg_dump_ops` correspond to modern",
                "`insn_start` records. They are not counted as opcode lines above,",
                "but a real PTC dumper must map them to legacy `debug_insn_start`",
                "or update the runnable-lift consumer together with the ABI.",
                "",
            ]
        )

    def rows_for(status: str) -> list[list[object]]:
        return [
            [
                report.name,
                report.count,
                format_arities(report.arities),
                ", ".join(report.legacy) if report.legacy else "-",
                report.arity_status,
                report.note or "-",
            ]
            for report in reports
            if report.status == status
        ]

    lines.extend(
        [
            "## Direct Legacy Hits",
            "",
            format_table(["Opcode", "count", "visible arity", "legacy opcode", "arity", "note"], rows_for("direct")).rstrip(),
            "",
            "## Alias Or Compatibility Candidates",
            "",
            format_table(["Opcode", "count", "visible arity", "candidate legacy opcode", "arity", "note"], rows_for("alias")).rstrip(),
            "",
            "## Non-Direct Opcode ABI Advice",
            "",
            format_table(
                [
                    "Opcode",
                    "count",
                    "visible arity",
                    "compatibility",
                    "suggestion",
                    "safe old PTCOpcode?",
                    "proposed PTC v2 opcode",
                    "ABI note",
                ],
                [
                    [
                        report.name,
                        report.count,
                        format_arities(report.arities),
                        report.compatibility,
                        report.recommendation,
                        format_bool(report.safe_legacy_mapping),
                        report.proposed_ptc_v2_opcode or "-",
                        report.note or "-",
                    ]
                    for report in reports
                    if report.status != "direct"
                ],
            ).rstrip(),
            "",
        ]
    )
    return "\n".join(lines) + "\n"


def report_to_json(
    *,
    legacy_path: Path,
    legacy_defs: list[LegacyOpcodeDef],
    input_stats: list[DumpStats],
    reports: list[OpcodeReport],
) -> dict[str, object]:
    legacy_index = legacy_by_name(legacy_defs)
    compatibility_counts: dict[str, int] = collections.Counter(
        report.compatibility for report in reports
    )
    compatibility_occurrences: dict[str, int] = collections.Counter()
    for report in reports:
        compatibility_occurrences[report.compatibility] += report.count
    return {
        "schema": "qemu-v2-tcg-ptc-inventory-v3",
        "compatibility_classes": COMPATIBILITY_CLASSES,
        "default_compat_rules": {
            name: {
                "compatibility": rule.compatibility,
                "recommendation": rule.recommendation,
                "safe_legacy_mapping": rule.safe_legacy_mapping,
                "legacy_aliases": rule.legacy_aliases,
                "proposed_ptc_v2_opcode": rule.proposed_ptc_v2_opcode,
                "note": rule.note,
            }
            for name, rule in sorted(DEFAULT_COMPAT_RULES.items())
        },
        "legacy_opcode_file": str(legacy_path),
        "legacy_def_entries": [
            dataclasses.asdict(definition) | {"total_arity": definition.total_arity}
            for definition in legacy_defs
        ],
        "legacy_duplicate_names": sorted(name for name, defs in legacy_index.items() if len(defs) > 1),
        "inputs": [input_stats_to_json(stats) for stats in input_stats],
        "dumps": [input_stats_to_json(stats) for stats in input_stats],
        "compatibility_summary": [
            {
                "compatibility": class_name,
                "names": compatibility_counts.get(class_name, 0),
                "occurrences": compatibility_occurrences.get(class_name, 0),
            }
            for class_name in COMPATIBILITY_CLASSES
        ],
        "opcodes": [
            {
                "name": report.name,
                "count": report.count,
                "files": report.files,
                "visible_arities": [{"arity": arity, "count": count} for arity, count in report.arities],
                "status": report.status,
                "compatibility": report.compatibility,
                "recommendation": report.recommendation,
                "safe_legacy_mapping": report.safe_legacy_mapping,
                "legacy": report.legacy,
                "arity_status": report.arity_status,
                "proposed_ptc_v2_opcode": report.proposed_ptc_v2_opcode,
                "compatibility_note": report.compatibility_note,
                "note": report.note,
                "sample": report.sample,
            }
            for report in reports
        ],
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Parse QEMU tcg_dump_ops text dumps and/or C-side walker JSONL "
            "records, then inventory opcode names against the legacy PTC "
            "tcg-opc.h ABI."
        )
    )
    parser.add_argument(
        "--dump",
        action="append",
        type=Path,
        default=[],
        help="tcg_dump_ops text file to parse; may be passed multiple times",
    )
    parser.add_argument(
        "--walker-jsonl",
        action="append",
        type=Path,
        default=[],
        help="C-side TCG op walker JSONL file to parse; may be passed multiple times",
    )
    parser.add_argument(
        "--legacy-opc",
        type=Path,
        default=DEFAULT_LEGACY_OPC,
        help=f"archived legacy tcg-opc.h path (default: {DEFAULT_LEGACY_OPC})",
    )
    parser.add_argument("--json-out", type=Path, help="write full inventory JSON to this file")
    parser.add_argument("--markdown-out", type=Path, help="write markdown report to this file")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    legacy_path = args.legacy_opc
    if not legacy_path.is_file():
        raise SystemExit(f"legacy opcode file does not exist: {legacy_path}")

    dump_paths = list(args.dump)
    walker_jsonl_paths = list(args.walker_jsonl)
    if not dump_paths and not walker_jsonl_paths:
        raise SystemExit("at least one --dump or --walker-jsonl input is required")
    for dump_path in dump_paths:
        if not dump_path.is_file():
            raise SystemExit(f"dump file does not exist: {dump_path}")
    for walker_jsonl_path in walker_jsonl_paths:
        if not walker_jsonl_path.is_file():
            raise SystemExit(f"walker JSONL file does not exist: {walker_jsonl_path}")

    legacy_defs = parse_legacy_opc(legacy_path)
    legacy_index = legacy_by_name(legacy_defs)

    counts: collections.Counter[str] = collections.Counter()
    arities: dict[str, collections.Counter[int]] = {}
    files_by_op: dict[str, set[str]] = {}
    samples: dict[str, str] = {}
    input_stats = [
        parse_dump_file(dump_path, counts, arities, files_by_op, samples)
        for dump_path in dump_paths
    ]
    input_stats.extend(
        parse_walker_jsonl_file(walker_jsonl_path, counts, arities, files_by_op, samples)
        for walker_jsonl_path in walker_jsonl_paths
    )
    reports = build_opcode_reports(counts, arities, files_by_op, samples, legacy_index)

    markdown = render_markdown(
        legacy_path=legacy_path,
        legacy_defs=legacy_defs,
        input_stats=input_stats,
        reports=reports,
    )
    if args.markdown_out:
        args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
        args.markdown_out.write_text(markdown)
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(
            json.dumps(
                report_to_json(
                    legacy_path=legacy_path,
                    legacy_defs=legacy_defs,
                    input_stats=input_stats,
                    reports=reports,
                ),
                indent=2,
                sort_keys=True,
            )
            + "\n"
        )

    if not args.markdown_out:
        print(markdown, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
