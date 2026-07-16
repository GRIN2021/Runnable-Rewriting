#!/usr/bin/env python3

import csv
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple


LL_COMMENT_RE = re.compile(r"^\s*;\s*(0x[0-9a-fA-F]+):(.*)$")
HEX_RE = re.compile(r"0x[0-9a-fA-F]+|[0-9a-fA-F]{4,}")
ILLEGAL_RANGE_RE = re.compile(r"^\s*([0-9a-fA-Fx]+)\s*,\s*([0-9a-fA-Fx]+)\s*$")


@dataclass(frozen=True)
class SymbolRange:
    start_csv: int
    end_csv: int
    start_runtime: int
    end_runtime: int
    name: str


def parse_int(value: str) -> int:
    return int(value, 0)


def csv_to_runtime(addr_csv: int, csv_image_base: int, rebase_base: int) -> int:
    return rebase_base + (addr_csv - csv_image_base)


def runtime_to_csv(addr_runtime: int, csv_image_base: int, rebase_base: int) -> int:
    return csv_image_base + (addr_runtime - rebase_base)


def load_ground_truth_csv(
    path: Path,
    *,
    csv_image_base: int,
    rebase_base: int,
) -> Tuple[Set[int], List[Tuple[int, int]]]:
    instruction_addrs: Set[int] = set()
    data_ranges: List[Tuple[int, int]] = []
    with path.open("r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            kind = row["kind"]
            start_csv = parse_int(row["start_hex"])
            end_csv = parse_int(row["end_hex"])
            start_runtime = csv_to_runtime(start_csv, csv_image_base, rebase_base)
            end_runtime = csv_to_runtime(end_csv, csv_image_base, rebase_base)
            if kind == "instruction_start":
                instruction_addrs.add(start_runtime)
            elif kind == "data_section":
                data_ranges.append((start_runtime, end_runtime))
    return instruction_addrs, data_ranges


def load_function_symbols_csv(
    path: Path,
    *,
    csv_image_base: int,
    rebase_base: int,
) -> List[SymbolRange]:
    rows: List[Tuple[int, str]] = []
    with path.open("r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            start_csv = parse_int(row["address_hex"])
            rows.append((start_csv, row["symbol"]))
    rows.sort(key=lambda item: item[0])
    ranges: List[SymbolRange] = []
    for idx, (start_csv, name) in enumerate(rows):
        next_start = rows[idx + 1][0] if idx + 1 < len(rows) else start_csv + 0x100
        end_csv = max(start_csv, next_start - 1)
        ranges.append(
            SymbolRange(
                start_csv=start_csv,
                end_csv=end_csv,
                start_runtime=csv_to_runtime(start_csv, csv_image_base, rebase_base),
                end_runtime=csv_to_runtime(end_csv, csv_image_base, rebase_base),
                name=name,
            )
        )
    return ranges


def load_lifted_addresses_from_ll(path: Path) -> List[int]:
    addrs: Dict[int, str] = {}
    with path.open("r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            match = LL_COMMENT_RE.match(line)
            if match is None:
                continue
            addr = int(match.group(1), 16)
            addrs[addr] = match.group(2).strip()
    return sorted(addrs)


def load_lifted_instruction_map(path: Path) -> Dict[int, str]:
    lifted: Dict[int, str] = {}
    with path.open("r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            match = LL_COMMENT_RE.match(line)
            if match is None:
                continue
            addr = int(match.group(1), 16)
            lifted[addr] = match.group(2).strip()
    return lifted


def write_json(path: Optional[Path], payload: Dict[str, object]) -> None:
    if path is None:
        return
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def hex_list(values: Iterable[int]) -> List[str]:
    return [f"0x{value:x}" for value in sorted(values)]


def find_symbol_for_address(symbols: Sequence[SymbolRange], runtime_addr: int) -> Optional[SymbolRange]:
    for symbol in symbols:
        if symbol.start_runtime <= runtime_addr <= symbol.end_runtime:
            return symbol
    return None


def read_json(path: Path) -> Dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def load_shard_results(path: Path) -> Dict[str, Dict[str, object]]:
    items = read_json(path)
    return {item["tag"]: item for item in items}


def tag_for_symbol(symbol: SymbolRange) -> str:
    return f"fn_{symbol.start_csv:016x}"


def shard_path(root: Path, relative_or_abs: Optional[str]) -> Optional[Path]:
    if not relative_or_abs:
        return None
    candidate = Path(relative_or_abs)
    if candidate.is_absolute():
        return candidate
    return root / candidate


def read_text_if_exists(path: Optional[Path]) -> str:
    if path is None or not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="ignore")


def load_illegal_addresses(path: Optional[Path]) -> Set[int]:
    if path is None or not path.exists():
        return set()
    results: Set[int] = set()
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        range_match = ILLEGAL_RANGE_RE.match(stripped)
        if range_match is not None:
            start_token = range_match.group(1)
            end_token = range_match.group(2)
            start = int(start_token, 16 if not start_token.lower().startswith("0x") else 0)
            end = int(end_token, 16 if not end_token.lower().startswith("0x") else 0)
            results.update(range(start, end + 1))
            continue
        for token in HEX_RE.findall(stripped):
            try:
                results.add(int(token, 16 if not token.lower().startswith("0x") else 0))
            except ValueError:
                continue
    return results


def load_coverage_addresses(path: Optional[Path]) -> Set[int]:
    if path is None or not path.exists():
        return set()
    covered: Set[int] = set()
    with path.open("r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            parts = line.strip().split(",")
            if not parts or not parts[0]:
                continue
            try:
                covered.add(int(parts[0], 16))
            except ValueError:
                continue
    return covered


def is_continuation_byte(addr: int, gt_instrs: Set[int]) -> bool:
    if addr in gt_instrs:
        return False
    for base in gt_instrs:
        if 0 < addr - base <= 3:
            return True
    return False


def is_in_ranges(addr: int, ranges: Sequence[Tuple[int, int]]) -> bool:
    return any(start <= addr <= end for start, end in ranges)


def neighbor_ground_truth(addr: int, gt_instrs: Set[int], max_distance: int = 8) -> bool:
    return any(abs(addr - gt) <= max_distance for gt in gt_instrs)
