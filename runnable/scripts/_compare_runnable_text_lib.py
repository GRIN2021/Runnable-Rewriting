#!/usr/bin/env python3

from __future__ import print_function

import collections
import re
import subprocess


OBJ_RE = re.compile(r"^\s+([0-9a-fA-F]+):\t(.*?)\t(.*)$")
OBJ_BLANK_RE = re.compile(r"^\s+([0-9a-fA-F]+):\t(.*)$")
LL_RE = re.compile(r"^\s*;\s*(0x[0-9a-fA-F]+):(?:\s+(.*))?$")
LL_BB_RE = re.compile(r"^\s*bb\.(0x[0-9a-fA-F]+)\w*:\s*(?:;.*)?$")
LL_ASM_ADDR_PREFIX_RE = re.compile(r"^0x[0-9a-fA-F]+:\s*")
IGNORE_TOKENS = ("nop", "data", "xchg")
ADV_MAP = {
    "cqto": "cqo",
    "cltd": "cdq",
    "cltq": "cdqe",
    "cbtw": "cbw",
    "cwtl": "cwde",
}
LL_OPCODE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9.]*$")


def adv_cmp(op1, op2):
    return ADV_MAP.get(op1) == op2


def op_match(op1, op2):
    return (
        op1 == op2
        or op1 in op2
        or op2 in op1
        or ("mov" in op1 and "mov" in op2)
        or adv_cmp(op1, op2)
        or adv_cmp(op2, op1)
    )


def extract_ll_instruction(asm):
    asm = asm.strip()
    asm = LL_ASM_ADDR_PREFIX_RE.sub("", asm, count=1)
    if not asm:
        return None
    op_matcher = re.match(r"^(\S+)\s*(\S*)", asm)
    ins = op_matcher.group(1) if op_matcher else None
    if not ins:
        return None
    if ins.startswith("<"):
        return None
    if not LL_OPCODE_RE.match(ins):
        return None
    if any(token in ins for token in IGNORE_TOKENS):
        return None
    return ins


def should_include_address(addr, text_start, text_end=None, include_pcs=None):
    if addr < text_start:
        return False
    if text_end is not None and addr >= text_end:
        return False
    if include_pcs is not None and addr not in include_pcs:
        return False
    return True


def parse_objdump(binary_path, text_start, text_end=None, include_pcs=None):
    out = subprocess.check_output(["objdump", "-d", str(binary_path)], universal_newlines=True)
    instructions = collections.OrderedDict()

    for line in out.splitlines():
        match = OBJ_RE.match(line)
        if match is not None:
            addr = int(match.group(1), 16)
            if not should_include_address(addr, text_start, text_end=text_end, include_pcs=include_pcs):
                continue
            asm = match.group(3)
            op_matcher = re.match(r"^(\S+)\s*(.*)$", asm)
            ins = op_matcher.group(1) if op_matcher else asm.strip()
            if ins and not any(token in ins for token in IGNORE_TOKENS):
                instructions[addr] = ins
            continue

        match = OBJ_BLANK_RE.match(line)
        if match is not None:
            addr = int(match.group(1), 16)

    return instructions


def parse_ll_raw(ll_path, include_address_markers=False):
    instructions = collections.OrderedDict()
    saw_comment_addresses = False
    marker_addrs = collections.OrderedDict()
    bb_addrs = collections.OrderedDict()
    with open(ll_path, "r", errors="ignore") as handle:
        for line in handle:
            match = LL_RE.match(line)
            if match is not None:
                saw_comment_addresses = True
                raw_addr = int(match.group(1), 16)
                asm = (match.group(2) or "").strip()
                ins = extract_ll_instruction(asm) if asm else None
                if ins:
                    instructions[raw_addr] = ins
                elif include_address_markers:
                    marker_addrs.setdefault(raw_addr, "marker")
                continue
            match = LL_BB_RE.match(line)
            if match is None:
                if saw_comment_addresses:
                    continue
                continue
            raw_addr = int(match.group(1), 16)
            bb_addrs.setdefault(raw_addr, "bb")
            if not saw_comment_addresses:
                instructions.setdefault(raw_addr, "bb")
    if include_address_markers:
        for raw_addr, marker in bb_addrs.items():
            instructions.setdefault(raw_addr, marker)
        for raw_addr, marker in marker_addrs.items():
            instructions.setdefault(raw_addr, marker)
    return instructions


def normalize_ll_addresses(raw_instructions, text_start, base, text_end=None, include_pcs=None):
    instructions = collections.OrderedDict()
    for raw_addr, ins in raw_instructions.items():
        addr = raw_addr - base if raw_addr >= base else raw_addr
        if not should_include_address(addr, text_start, text_end=text_end, include_pcs=include_pcs):
            continue
        instructions[addr] = ins
    return instructions


def compare(obj_instructions, ll_instructions, example_limit):
    hits = 0
    mismatch = 0
    obj_only = 0
    ll_only = 0
    mismatch_examples = []
    obj_only_examples = []
    ll_only_examples = []

    for addr, obj_ins in obj_instructions.items():
        ll_ins = ll_instructions.get(addr)
        if ll_ins is None:
            obj_only += 1
            if len(obj_only_examples) < example_limit:
                obj_only_examples.append((addr, obj_ins))
            continue
        if op_match(obj_ins, ll_ins):
            hits += 1
        else:
            mismatch += 1
            if len(mismatch_examples) < example_limit:
                mismatch_examples.append((addr, obj_ins, ll_ins))

    for addr, ll_ins in ll_instructions.items():
        if addr not in obj_instructions:
            ll_only += 1
            if len(ll_only_examples) < example_limit:
                ll_only_examples.append((addr, ll_ins))

    false_negative = obj_only + mismatch
    false_positive = ll_only + mismatch
    obj_count = len(obj_instructions)
    ll_count = len(ll_instructions)
    recall = float(hits) / obj_count if obj_count else 0.0
    precision = float(hits) / ll_count if ll_count else 0.0

    return {
        "obj_count": obj_count,
        "ll_count": ll_count,
        "hit": hits,
        "mismatch": mismatch,
        "obj_only": obj_only,
        "ll_only": ll_only,
        "false_negative": false_negative,
        "false_positive": false_positive,
        "recall": recall,
        "precision": precision,
        "mismatch_examples": mismatch_examples,
        "obj_only_examples": obj_only_examples,
        "ll_only_examples": ll_only_examples,
    }
