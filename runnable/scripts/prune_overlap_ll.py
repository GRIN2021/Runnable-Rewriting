#!/usr/bin/env python3
"""Plan B: overlap-pruning post-pass for runnable-lift .ll output.

The dynamic-parallel lift over-disassembles: ~98% of its false positives are
instructions decoded starting *inside* a real instruction (mid-instruction
byte offsets). Real x86 instructions never overlap, so the true instruction
stream is recovered with a leftmost, length-aware greedy sweep over the
instruction-start addresses recorded as `; 0xADDR: mnemonic` comments.

Any `bb.0xADDR` basic block whose entry address is not a real boundary (i.e.
it starts inside another instruction) is a phantom. We neutralize each phantom
block to a single `unreachable` instruction: the spurious lifted IR and its
`; 0x:` comments are dropped, while the block label survives as a valid
branch/dispatcher target. Lifted IR keeps register state in memory
(`load/store @rax`) with block-local SSA temporaries and no cross-block PHIs
referencing `bb.0x` blocks, so neutralization needs no reference fix-up.

Usage:
  prune_overlap_ll.py input.ll --output pruned.ll [--llvm-as <path>] [--report]
"""
import argparse
import re
import subprocess
import sys
from collections import Counter

INSN_RE = re.compile(r"^\s*;\s*(0x[0-9a-fA-F]+):\s")
# A lifted instruction-block label is `bb.0x<hex>` optionally followed by a
# sub-block suffix such as `_L0` / `_L0_ft` (conditional-branch sub-blocks).
# Every such label is its own basic block and must keep its label even when
# neutralized, so that cross-block references stay defined.
BB_RE = re.compile(r"^(bb\.0x[0-9a-fA-F]+\w*):")
BB_ADDR_RE = re.compile(r"^bb\.0x([0-9a-fA-F]+)")
OTHER_LABEL_RE = re.compile(r"^[A-Za-z_][\w.]*:")
MAX_X86 = 15


def collect_insn_addrs(lines):
    """All instruction-start addresses from `; 0x..:` comments."""
    out = []
    for ln in lines:
        m = INSN_RE.match(ln)
        if m:
            out.append(int(m.group(1), 16))
    return out


def infer_lengths(lines, spans):
    """Estimate instruction lengths from consecutive `; 0x:` comments WITHIN the
    same basic block (instructions inside a block are contiguous in memory, so
    next_addr-addr is the true length). Computing deltas globally across block
    boundaries over-estimates lengths at the last instruction of each block and
    would wrongly flag the following real instruction as overlapping."""
    deltas = {}
    for _addr, _lbl, s, e in spans:
        seq = []
        for ln in lines[s:e]:
            m = INSN_RE.match(ln)
            if m:
                seq.append(int(m.group(1), 16))
        for a, b in zip(seq, seq[1:]):
            d = b - a
            if 1 <= d <= MAX_X86:
                deltas.setdefault(a, Counter())[d] += 1
    return {a: c.most_common(1)[0][0] for a, c in deltas.items()}


def kept_addresses(addrs, length):
    """Leftmost non-overlapping greedy: keep an address only if it starts at or
    after the end of the previously kept instruction."""
    kept = set()
    next_free = -1
    for a in sorted(set(addrs)):
        if a >= next_free:
            kept.add(a)
            next_free = a + length.get(a, 1)
    return kept


def block_spans(lines):
    """Return list of (entry_addr, label, start_idx, end_idx) for each bb.0x
    block (including `_L0`-style sub-blocks). end_idx is exclusive (next label
    or end of function)."""
    spans = []
    cur = None  # (addr, label, start_idx)
    for i, ln in enumerate(lines):
        m = BB_RE.match(ln)
        if m:
            if cur is not None:
                spans.append((cur[0], cur[1], cur[2], i))
            addr = int(BB_ADDR_RE.match(ln).group(1), 16)
            cur = (addr, m.group(1), i)
            continue
        # any other label line (dispatcher.*, anyPC, ...) or end-of-function
        # closes the current bb block
        if cur is not None and (OTHER_LABEL_RE.match(ln) or ln.rstrip() == "}"):
            spans.append((cur[0], cur[1], cur[2], i))
            cur = None
    if cur is not None:
        spans.append((cur[0], cur[1], cur[2], len(lines)))
    return spans


def main():
    ap = argparse.ArgumentParser(description="Overlap-pruning post-pass for runnable-lift .ll")
    ap.add_argument("input")
    ap.add_argument("--output", required=True)
    ap.add_argument("--llvm-as", default="", help="path to llvm-as for validation")
    ap.add_argument("--report", action="store_true")
    args = ap.parse_args()

    with open(args.input, "r", errors="ignore") as f:
        lines = f.readlines()

    spans = block_spans(lines)
    addrs = collect_insn_addrs(lines)
    length = infer_lengths(lines, spans)
    keep = kept_addresses(addrs, length)

    phantom = [(a, lbl, s, e) for (a, lbl, s, e) in spans if a not in keep]

    # Neutralize each phantom block individually: keep its label (so any
    # cross-block reference stays defined), replace the body with `unreachable`.
    drop = [False] * len(lines)
    inject_unreachable = {}  # index of label line -> True
    for a, lbl, s, e in phantom:
        lines[s] = lbl + ":\n"
        inject_unreachable[s] = True
        for j in range(s + 1, e):
            drop[j] = True

    out_lines = []
    for i, ln in enumerate(lines):
        if drop[i]:
            continue
        out_lines.append(ln)
        if inject_unreachable.get(i):
            out_lines.append("  unreachable\n")

    with open(args.output, "w") as f:
        f.writelines(out_lines)

    if args.report:
        print(f"blocks_total={len(spans)} phantom_blocks_pruned={len(phantom)}")
        print(f"insn_addrs={len(set(addrs))} kept={len(keep)} dropped={len(set(addrs))-len(keep)}")

    if args.llvm_as:
        r = subprocess.run([args.llvm_as, args.output, "-o", "/dev/null"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("llvm-as FAILED on pruned output:\n" + r.stderr[:2000], file=sys.stderr)
            return 1
        if args.report:
            print("llvm-as: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
