#!/usr/bin/env python3

from __future__ import print_function

import collections
import re
import subprocess


OBJ_RE = re.compile(r"^\s+([0-9a-fA-F]+):\t(.*?)\t(.*)$")
OBJ_BLANK_RE = re.compile(r"^\s+([0-9a-fA-F]+):\t(.*)$")
LL_RE = re.compile(r"^\s*;\s*(0x[0-9a-fA-F]+):\s+(.*)$")
IGNORE_TOKENS = ("nop", "data", "xchg")
ADV_MAP = {
    "cqto": "cqo",
    "cltd": "cdq",
    "cltq": "cdqe",
    "cbtw": "cbw",
    "cwtl": "cwde",
}


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


def parse_objdump(binary_path, text_start):
    out = subprocess.check_output(["objdump", "-d", str(binary_path)], universal_newlines=True)
    instructions = collections.OrderedDict()

    for line in out.splitlines():
        match = OBJ_RE.match(line)
        if match is not None:
            addr = int(match.group(1), 16)
            if addr < text_start:
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
            if addr < text_start:
                continue

    return instructions


def parse_ll_raw(ll_path):
    instructions = collections.OrderedDict()
    with open(ll_path, "r", errors="ignore") as handle:
        for line in handle:
            match = LL_RE.match(line)
            if match is None:
                continue
            raw_addr = int(match.group(1), 16)
            asm = match.group(2).strip()
            op_matcher = re.match(r"^(\S+)\s*(\S*)", asm)
            ins = op_matcher.group(1) if op_matcher else asm.split()[0]
            if ins and not any(token in ins for token in IGNORE_TOKENS):
                instructions[raw_addr] = ins
    return instructions


def normalize_ll_addresses(raw_instructions, text_start, base):
    instructions = collections.OrderedDict()
    for raw_addr, ins in raw_instructions.items():
        addr = raw_addr - base if raw_addr >= base else raw_addr
        if addr < text_start:
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
