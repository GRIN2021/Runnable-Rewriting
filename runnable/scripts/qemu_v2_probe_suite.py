#!/usr/bin/env python3
"""Compile and validate small QEMU V2 instruction probes.

The default path is safe on hosts without AVX-512: compile probes and inspect
objdump output only. Execution happens only when --qemu-x86_64 is provided.
"""

from __future__ import annotations

import argparse
import dataclasses
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[2]
PROBE_ROOT = REPO_ROOT / "test" / "qemu-v2-probes"
DEFAULT_BUILD_DIR = REPO_ROOT / "build-qemu-v2-probes"


@dataclasses.dataclass(frozen=True)
class Probe:
    name: str
    source: Path
    expected_mnemonics: tuple[str, ...]
    aggregate: bool = False

    @property
    def binary_name(self) -> str:
        return self.name


PROBES: tuple[Probe, ...] = (
    Probe(
        name="avx2-vex",
        source=PROBE_ROOT / "avx2-vex.S",
        expected_mnemonics=(
            "vmovdqu",
            "vpxor",
            "vpshufb",
            "vperm2i128",
        ),
    ),
    Probe(
        name="avx512-vpxorq",
        source=PROBE_ROOT / "avx512-vpxorq.S",
        expected_mnemonics=("vpxorq",),
    ),
    Probe(
        name="avx512-vmovdqa64",
        source=PROBE_ROOT / "avx512-vmovdqa64.S",
        expected_mnemonics=("vmovdqa64",),
    ),
    Probe(
        name="avx512-vaesenc",
        source=PROBE_ROOT / "avx512-vaesenc.S",
        expected_mnemonics=("vaesenc",),
    ),
    Probe(
        name="avx512-vpclmullqlqdq",
        source=PROBE_ROOT / "avx512-vpclmullqlqdq.S",
        expected_mnemonics=("vpclmullqlqdq",),
    ),
    Probe(
        name="avx512-evex",
        source=PROBE_ROOT / "avx512-evex.S",
        expected_mnemonics=(
            "vpxorq",
            "vmovdqa64",
            "vmovdqu64",
            "vpshufb",
            "vpaddd",
            "vpternlogq",
            "vpclmullqlqdq",
            "vpclmullqhqdq",
            "vpclmulhqlqdq",
            "vpclmulhqhqdq",
            "vaesenc",
            "vaesenclast",
            "vbroadcastf64x2",
            "vpslldq",
            "vpsrldq",
            "vextracti32x4",
            "vextracti64x4",
            "vmovdqu8",
        ),
        aggregate=True,
    ),
)


def run(cmd: list[str], *, cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    print("+ " + " ".join(cmd))
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=check,
    )


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        raise SystemExit(f"missing required tool: {name}")
    return path


def selected_probes(names: Iterable[str], *, skip_aggregate: bool = False) -> list[Probe]:
    wanted = list(names)
    if not wanted or wanted == ["all"]:
        probes = list(PROBES)
        if skip_aggregate:
            probes = [probe for probe in probes if not probe.aggregate]
        if not probes:
            raise SystemExit("no probes selected")
        return probes

    by_name = {probe.name: probe for probe in PROBES}
    unknown = sorted(set(wanted) - set(by_name))
    if unknown:
        raise SystemExit(f"unknown probe(s): {', '.join(unknown)}")
    return [by_name[name] for name in wanted]


def compile_probe(probe: Probe, build_dir: Path, cc: str) -> Path:
    build_dir.mkdir(parents=True, exist_ok=True)
    output = build_dir / probe.binary_name
    cmd = [
        cc,
        "-nostdlib",
        "-no-pie",
        "-Wl,--build-id=none",
        "-o",
        str(output),
        str(probe.source),
    ]
    result = run(cmd)
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    return output


def objdump_probe(binary: Path, objdump: str) -> str:
    result = run([objdump, "-d", "-Mintel", str(binary)])
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    return result.stdout


def mnemonic_search_text(text: str, label: str) -> str:
    if label != "objdump":
        return text.lower()
    return "\n".join(
        line.lower()
        for line in text.splitlines()
        if re.match(r"^\s*[0-9a-f]+:\s", line)
    )


def assert_mnemonics(probe: Probe, text: str, label: str) -> None:
    searchable = mnemonic_search_text(text, label)
    missing = [
        mnemonic
        for mnemonic in probe.expected_mnemonics
        if re.search(rf"\b{re.escape(mnemonic.lower())}\b", searchable) is None
    ]
    if missing:
        raise SystemExit(
            f"{probe.name}: missing expected mnemonic(s) in {label}: {', '.join(missing)}"
        )
    print(f"{probe.name}: {label} contains {len(probe.expected_mnemonics)} expected mnemonic(s)")


def run_qemu(qemu: Path, binary: Path) -> None:
    result = run([str(qemu), str(binary)], check=False)
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    if result.returncode != 0:
        raise SystemExit(f"QEMU execution failed for {binary}: rc={result.returncode}")


def find_entry_symbol(binary: Path, symbol: str) -> int:
    nm = require_tool("nm")
    result = run([nm, "-n", str(binary)])
    pattern = re.compile(rf"^([0-9a-fA-F]+)\s+\w\s+{re.escape(symbol)}$")
    for line in result.stdout.splitlines():
        match = pattern.match(line.strip())
        if match:
            return int(match.group(1), 16)
    raise SystemExit(f"could not find symbol {symbol!r} in {binary}")


def run_runnable_lift(
    runnable_lift: Path,
    binary: Path,
    out_ll: Path,
    entry_symbol: str | None,
    extra_args: list[str],
) -> str:
    cmd = [str(runnable_lift), str(binary), str(out_ll)]
    if entry_symbol:
        entry = find_entry_symbol(binary, entry_symbol)
        cmd.append(f"-entry=0x{entry:x}")
    cmd.extend(extra_args)
    result = run(cmd, check=False)
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    if result.returncode != 0:
        raise SystemExit(f"runnable-lift failed for {binary}: rc={result.returncode}")
    if not out_ll.exists():
        raise SystemExit(f"runnable-lift did not create output: {out_ll}")
    return out_ll.read_text(errors="replace")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="list available probes and exit")
    parser.add_argument(
        "--probe",
        action="append",
        default=[],
        help="probe name to run exactly; repeatable; default/all runs all probes",
    )
    parser.add_argument(
        "--skip-aggregate",
        action="store_true",
        help="skip aggregate probes when default/all probe selection is used",
    )
    parser.add_argument("--build-dir", type=Path, default=DEFAULT_BUILD_DIR)
    parser.add_argument("--cc", default=os.environ.get("CC", "gcc"))
    parser.add_argument("--objdump-tool", default=os.environ.get("OBJDUMP", "objdump"))
    parser.add_argument("--compile", action="store_true", help="compile selected probes")
    parser.add_argument("--objdump", action="store_true", help="check objdump mnemonics")
    parser.add_argument("--qemu-x86_64", type=Path, help="optional qemu-x86_64 binary to execute probes")
    parser.add_argument("--runnable-lift", type=Path, help="optional runnable-lift binary to validate .ll comments")
    parser.add_argument(
        "--runnable-entry-symbol",
        default="_start",
        help="symbol passed as -entry to runnable-lift; use empty string to omit",
    )
    parser.add_argument(
        "--runnable-arg",
        action="append",
        default=[],
        help="extra argument passed through to runnable-lift; repeatable",
    )
    args = parser.parse_args()

    if args.list:
        for probe in PROBES:
            label = " [aggregate]" if probe.aggregate else ""
            print(f"{probe.name}{label}\t{probe.source.relative_to(REPO_ROOT)}")
            print("  expected: " + ", ".join(probe.expected_mnemonics))
        return 0

    probes = selected_probes(args.probe, skip_aggregate=args.skip_aggregate)
    if not (args.compile or args.objdump or args.qemu_x86_64 or args.runnable_lift):
        args.compile = True
        args.objdump = True

    require_tool(args.cc)
    if args.objdump:
        require_tool(args.objdump_tool)

    for probe in probes:
        if not probe.source.exists():
            raise SystemExit(f"missing probe source: {probe.source}")
        binary = args.build_dir / probe.binary_name
        if args.compile or not binary.exists():
            binary = compile_probe(probe, args.build_dir, args.cc)

        if args.objdump:
            disassembly = objdump_probe(binary, args.objdump_tool)
            assert_mnemonics(probe, disassembly, "objdump")

        if args.qemu_x86_64:
            run_qemu(args.qemu_x86_64, binary)
            print(f"{probe.name}: QEMU execution OK")

        if args.runnable_lift:
            out_ll = args.build_dir / f"{probe.binary_name}.ll"
            entry_symbol = args.runnable_entry_symbol or None
            ll_text = run_runnable_lift(
                args.runnable_lift,
                binary,
                out_ll,
                entry_symbol,
                args.runnable_arg,
            )
            assert_mnemonics(probe, ll_text, "runnable-lift .ll")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
