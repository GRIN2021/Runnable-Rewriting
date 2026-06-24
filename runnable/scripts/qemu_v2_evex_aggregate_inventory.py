#!/usr/bin/env python3
"""Build an objdump inventory for the AVX-512 EVEX aggregate probe.

The tool is intentionally offline: it compiles the probe if needed, runs
``objdump -d -Mintel``, and classifies each instruction for exact-byte smoke
dispatch planning. It does not execute the probe under QEMU.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = REPO_ROOT / "test" / "qemu-v2-probes" / "avx512-evex.S"
DEFAULT_BUILD_DIR = REPO_ROOT / "build-qemu-v2-probes"
DEFAULT_SYMBOL = "_start"

OBJDUMP_SYMBOL_RE = re.compile(r"^\s*([0-9a-fA-F]+)\s+<([^>]+)>:\s*$")
OBJDUMP_INSN_RE = re.compile(
    r"^\s*([0-9a-fA-F]+):\s*((?:[0-9a-fA-F]{2}\s*)+)\s*(.*?)\s*$"
)

IMPLEMENTED_SMOKE_BY_BYTES: dict[tuple[str, ...], str] = {
    ("62", "f1", "fd", "48", "ef", "c0"): "vpxorq exact-byte smoke",
    ("62", "f1", "fd", "48", "6f", "c8"): "vmovdqa64 exact-byte smoke",
    (
        "62",
        "f1",
        "fe",
        "48",
        "7f",
        "0d",
        "ea",
        "0f",
        "00",
        "00",
    ): "aggregate vmovdqu64 store exact-byte smoke",
    (
        "62",
        "f1",
        "fe",
        "48",
        "6f",
        "15",
        "e0",
        "0f",
        "00",
        "00",
    ): "aggregate vmovdqu64 load exact-byte smoke",
    ("62", "f2", "6d", "48", "00", "da"): "vpshufb exact-byte smoke",
    ("62", "f1", "65", "48", "fe", "e2"): "vpaddd exact-byte smoke",
    ("62", "f3", "dd", "48", "25", "eb", "96"): "vpternlogq exact-byte smoke",
    ("62", "f3", "55", "48", "44", "f4", "00"): "vpclmullqlqdq exact-byte smoke",
    ("62", "f3", "55", "48", "44", "fc", "10"): "vpclmullqhqdq exact-byte smoke",
    ("62", "73", "55", "48", "44", "c4", "01"): "vpclmulhqlqdq exact-byte smoke",
}

NEXT_BY_BYTES: dict[tuple[str, ...], str] = {
    (
        "62",
        "73",
        "55",
        "48",
        "44",
        "cc",
        "11",
    ): "current aggregate failure boundary after vpclmulhqlqdq",
}

VALID_STATUSES = {"implemented-smoke", "next", "pending", "non-evex"}
StatusByBytes = dict[tuple[str, ...], tuple[str, str]]


@dataclasses.dataclass
class Instruction:
    index: int
    address: int
    bytes: list[str]
    mnemonic: str
    operands: str
    text: str
    status: str
    status_note: str
    is_evex: bool

    @property
    def address_hex(self) -> str:
        return f"0x{self.address:x}"

    @property
    def bytes_text(self) -> str:
        return " ".join(self.bytes)

    @property
    def instruction_text(self) -> str:
        if self.operands:
            return f"{self.mnemonic} {self.operands}"
        return self.mnemonic

    def to_json(self) -> dict[str, object]:
        return {
            "index": self.index,
            "address": self.address_hex,
            "bytes": self.bytes_text,
            "mnemonic": self.mnemonic,
            "operands": self.operands,
            "instruction": self.instruction_text,
            "status": self.status,
            "status_note": self.status_note,
            "is_evex": self.is_evex,
        }


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    print("+ " + " ".join(cmd), file=sys.stderr)
    return subprocess.run(
        cmd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        raise SystemExit(f"missing required tool: {name}")
    return path


def compile_probe(source: Path, binary: Path, cc: str) -> Path:
    binary.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        cc,
        "-nostdlib",
        "-no-pie",
        "-Wl,--build-id=none",
        "-o",
        str(binary),
        str(source),
    ]
    result = run(cmd)
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    return binary


def objdump(binary: Path, objdump_tool: str) -> str:
    result = run([objdump_tool, "-d", "-Mintel", str(binary)])
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    return result.stdout


def strip_comment(asm_text: str) -> str:
    return asm_text.split("#", 1)[0].strip()


def split_instruction_text(asm_text: str) -> tuple[str, str]:
    text = strip_comment(asm_text)
    if not text:
        return "", ""
    parts = text.split(None, 1)
    mnemonic = parts[0].lower()
    operands = parts[1].strip() if len(parts) == 2 else ""
    return mnemonic, operands


def default_status_by_bytes() -> StatusByBytes:
    status_by_bytes: StatusByBytes = {}
    for key, note in IMPLEMENTED_SMOKE_BY_BYTES.items():
        status_by_bytes[key] = ("implemented-smoke", note)
    for key, note in NEXT_BY_BYTES.items():
        status_by_bytes[key] = ("next", note)
    return status_by_bytes


def parse_byte_key(bytes_text: str) -> tuple[str, ...]:
    parts = [part.lower() for part in bytes_text.split()]
    if not parts:
        raise ValueError("empty byte key")
    for part in parts:
        if not re.fullmatch(r"[0-9a-f]{2}", part):
            raise ValueError(f"invalid byte token {part!r}")
    return tuple(parts)


def status_note_from_json(value: object, path: Path) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        note = value.get("note")
        if isinstance(note, str):
            return note
    return f"status override from {path}"


def load_status_json(path: Path) -> tuple[bool, StatusByBytes]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise SystemExit(f"--status-json must contain a JSON object: {path}")

    replace_defaults = bool(payload.get("replace_defaults", False))
    status_payload = payload.get("statuses", payload)
    if not isinstance(status_payload, dict):
        raise SystemExit(f"--status-json statuses must be an object: {path}")

    overrides: StatusByBytes = {}
    for status, entries in status_payload.items():
        if status in {"replace_defaults", "statuses"}:
            continue
        if status not in VALID_STATUSES:
            raise SystemExit(
                f"--status-json has unsupported status {status!r}; "
                f"expected one of {sorted(VALID_STATUSES)}"
            )
        if not isinstance(entries, dict):
            raise SystemExit(f"--status-json entries for {status!r} must be an object")
        for bytes_text, note_value in entries.items():
            try:
                key = parse_byte_key(str(bytes_text))
            except ValueError as exc:
                raise SystemExit(f"--status-json invalid byte key {bytes_text!r}: {exc}")
            overrides[key] = (status, status_note_from_json(note_value, path))

    return replace_defaults, overrides


def apply_status_json(status_by_bytes: StatusByBytes, path: Path) -> StatusByBytes:
    replace_defaults, overrides = load_status_json(path)
    merged: StatusByBytes = {} if replace_defaults else dict(status_by_bytes)
    merged.update(overrides)
    return merged


def classify(bytes_: list[str], status_by_bytes: StatusByBytes) -> tuple[str, str, bool]:
    key = tuple(byte.lower() for byte in bytes_)
    is_evex = bool(bytes_) and bytes_[0].lower() == "62"
    if key in status_by_bytes:
        status, note = status_by_bytes[key]
        return status, note, is_evex
    if is_evex:
        return "pending", "EVEX instruction not covered by exact-byte smoke yet", True
    return "non-evex", "outside the AVX-512 EVEX queue", False


def parse_objdump_start(
    disassembly: str,
    symbol: str = DEFAULT_SYMBOL,
    status_by_bytes: StatusByBytes | None = None,
) -> list[Instruction]:
    if status_by_bytes is None:
        status_by_bytes = default_status_by_bytes()

    raw_rows: list[dict[str, object]] = []
    in_symbol = False

    for line in disassembly.splitlines():
        symbol_match = OBJDUMP_SYMBOL_RE.match(line)
        if symbol_match:
            current_symbol = symbol_match.group(2)
            if in_symbol and current_symbol != symbol:
                break
            in_symbol = current_symbol == symbol
            continue

        if not in_symbol:
            continue

        insn_match = OBJDUMP_INSN_RE.match(line)
        if not insn_match:
            continue

        address = int(insn_match.group(1), 16)
        bytes_ = [part.lower() for part in insn_match.group(2).split()]
        asm_text = insn_match.group(3).strip()
        mnemonic, operands = split_instruction_text(asm_text)

        if not mnemonic:
            if not raw_rows:
                raise SystemExit(f"objdump continuation before instruction: {line}")
            raw_rows[-1]["bytes"].extend(bytes_)  # type: ignore[index, union-attr]
            continue

        raw_rows.append(
            {
                "address": address,
                "bytes": bytes_,
                "mnemonic": mnemonic,
                "operands": operands,
                "text": strip_comment(asm_text),
            }
        )

    if not raw_rows:
        raise SystemExit(f"could not parse symbol {symbol!r} from objdump output")

    instructions: list[Instruction] = []
    for index, row in enumerate(raw_rows, start=1):
        bytes_list = list(row["bytes"])  # type: ignore[arg-type]
        status, note, is_evex = classify(bytes_list, status_by_bytes)
        instructions.append(
            Instruction(
                index=index,
                address=int(row["address"]),
                bytes=bytes_list,
                mnemonic=str(row["mnemonic"]),
                operands=str(row["operands"]),
                text=str(row["text"]),
                status=status,
                status_note=note,
                is_evex=is_evex,
            )
        )
    return instructions


def status_counts(instructions: list[Instruction]) -> dict[str, int]:
    counts = {
        "implemented-smoke": 0,
        "next": 0,
        "pending": 0,
        "non-evex": 0,
    }
    for insn in instructions:
        counts[insn.status] = counts.get(insn.status, 0) + 1
    return counts


def markdown_table(rows: list[list[str]], headers: list[str]) -> str:
    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(row) + " |")
    return "\n".join(lines)


def render_markdown(
    *,
    source: Path,
    binary: Path,
    build_dir: Path,
    status_json: Path | None,
    compiled: bool,
    instructions: list[Instruction],
) -> str:
    counts = status_counts(instructions)
    evex_count = sum(1 for insn in instructions if insn.is_evex)
    pending_queue = [
        insn for insn in instructions if insn.status in {"next", "pending"}
    ]

    lines = [
        "# QEMU V2 EVEX Aggregate Instruction Inventory",
        "",
        "Generated by `runnable/scripts/qemu_v2_evex_aggregate_inventory.py`.",
        "",
        "## Inputs",
        "",
        f"- Source: `{source}`",
        f"- Binary: `{binary}`",
        f"- Build dir: `{build_dir}`",
        f"- Status JSON: `{status_json}`" if status_json else "- Status JSON: default built-in map",
        f"- Binary compiled by this run: `{str(compiled).lower()}`",
        "- Execution: not run; inventory uses compile plus `objdump -d -Mintel` only.",
        "",
        "## Summary",
        "",
        markdown_table(
            [
                ["total instructions", str(len(instructions))],
                ["EVEX instructions", str(evex_count)],
                ["implemented-smoke", str(counts.get("implemented-smoke", 0))],
                ["next", str(counts.get("next", 0))],
                ["pending", str(counts.get("pending", 0))],
                ["non-evex", str(counts.get("non-evex", 0))],
            ],
            ["Metric", "Value"],
        ),
        "",
        "Status rules:",
        "",
        "- `implemented-smoke`: exact aggregate bytes covered by the existing smoke path.",
        "- `next`: current aggregate boundary, expected dispatch target for the next subagent.",
        "- `pending`: EVEX instruction after the current boundary.",
        "- `non-evex`: cleanup/syscall instruction outside the AVX-512 queue.",
        "",
        "## First 10 Instructions",
        "",
        markdown_table(
            [
                [
                    str(insn.index),
                    insn.address_hex,
                    f"`{insn.bytes_text}`",
                    f"`{insn.instruction_text}`",
                    f"`{insn.status}`",
                ]
                for insn in instructions[:10]
            ],
            ["#", "Address", "Bytes", "Instruction", "Status"],
        ),
        "",
        "## Pending Queue",
        "",
    ]

    if pending_queue:
        lines.append(
            markdown_table(
                [
                    [
                        str(insn.index),
                        insn.address_hex,
                        f"`{insn.bytes_text}`",
                        f"`{insn.instruction_text}`",
                        f"`{insn.status}`",
                        insn.status_note,
                    ]
                    for insn in pending_queue
                ],
                ["#", "Address", "Bytes", "Instruction", "Status", "Note"],
            )
        )
    else:
        lines.append("No EVEX pending queue entries remain.")

    lines.extend(
        [
            "",
            "## Full Inventory",
            "",
            markdown_table(
                [
                    [
                        str(insn.index),
                        insn.address_hex,
                        f"`{insn.bytes_text}`",
                        f"`{insn.mnemonic}`",
                        f"`{insn.operands}`" if insn.operands else "",
                        f"`{insn.status}`",
                        insn.status_note,
                    ]
                    for insn in instructions
                ],
                ["#", "Address", "Bytes", "Mnemonic", "Operands", "Status", "Note"],
            ),
            "",
        ]
    )
    return "\n".join(lines)


def render_json(
    *,
    source: Path,
    binary: Path,
    build_dir: Path,
    status_json: Path | None,
    compiled: bool,
    instructions: list[Instruction],
) -> dict[str, object]:
    counts = status_counts(instructions)
    return {
        "schema": "qemu-v2-evex-aggregate-inventory-v1",
        "source": str(source),
        "binary": str(binary),
        "build_dir": str(build_dir),
        "status_json": str(status_json) if status_json else None,
        "compiled": compiled,
        "summary": {
            "total_instructions": len(instructions),
            "evex_instructions": sum(1 for insn in instructions if insn.is_evex),
            "status_counts": counts,
        },
        "first_10": [insn.to_json() for insn in instructions[:10]],
        "pending_queue": [
            insn.to_json()
            for insn in instructions
            if insn.status in {"next", "pending"}
        ],
        "instructions": [insn.to_json() for insn in instructions],
    }


def resolve_binary(args: argparse.Namespace) -> tuple[Path, bool]:
    source = args.source.resolve()
    build_dir = args.build_dir.resolve()

    if args.binary:
        binary = args.binary.resolve()
        if binary.exists():
            return binary, False
        if not source.exists():
            raise SystemExit(f"missing source for compile: {source}")
        require_tool(args.cc)
        return compile_probe(source, binary, args.cc), True

    if not source.exists():
        raise SystemExit(f"missing source for compile: {source}")
    require_tool(args.cc)
    binary = build_dir / source.stem
    return compile_probe(source, binary, args.cc), True


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--build-dir", type=Path, default=DEFAULT_BUILD_DIR)
    parser.add_argument("--markdown-out", type=Path)
    parser.add_argument("--json-out", type=Path)
    parser.add_argument(
        "--status-json",
        type=Path,
        help=(
            "optional JSON status override map; statuses map byte strings to notes "
            "and overlay the built-in map unless replace_defaults is true"
        ),
    )
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    parser.add_argument("--objdump-tool", default=os.environ.get("OBJDUMP", "objdump"))
    parser.add_argument(
        "--symbol",
        default=DEFAULT_SYMBOL,
        help="entry symbol to parse from objdump output",
    )
    args = parser.parse_args()

    source = args.source.resolve()
    build_dir = args.build_dir.resolve()
    status_json = args.status_json.resolve() if args.status_json else None

    require_tool(args.objdump_tool)
    status_by_bytes = default_status_by_bytes()
    if status_json:
        status_by_bytes = apply_status_json(status_by_bytes, status_json)

    binary, compiled = resolve_binary(args)
    if not binary.exists():
        raise SystemExit(f"missing binary after compile decision: {binary}")

    disassembly = objdump(binary, args.objdump_tool)
    instructions = parse_objdump_start(
        disassembly,
        symbol=args.symbol,
        status_by_bytes=status_by_bytes,
    )

    markdown = render_markdown(
        source=source,
        binary=binary,
        build_dir=build_dir,
        status_json=status_json,
        compiled=compiled,
        instructions=instructions,
    )
    payload = render_json(
        source=source,
        binary=binary,
        build_dir=build_dir,
        status_json=status_json,
        compiled=compiled,
        instructions=instructions,
    )

    if args.markdown_out:
        write_text(args.markdown_out, markdown)
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    if not args.markdown_out:
        print(markdown)
    else:
        counts = status_counts(instructions)
        print(
            "inventory: "
            f"{len(instructions)} instructions, "
            f"{sum(1 for insn in instructions if insn.is_evex)} EVEX, "
            f"{counts.get('implemented-smoke', 0)} implemented-smoke, "
            f"{counts.get('next', 0)} next, "
            f"{counts.get('pending', 0)} pending",
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
