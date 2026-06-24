# QEMU V2 TCG Walker PTC Inventory

Date: 2026-06-23
Tool: `runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py`
Walker scratch root: `/tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k`

## Purpose

This validates that the PTC inventory tool can consume the new C-side walker
JSONL output from `runnable/scripts/qemu_v2_ptc_tcg_op_walker_probe.sh`.

The walker JSONL is closer to the real C-side `dump_tinycode` integration point
than text `tcg_dump_ops`: it walks `tcg_ctx->ops` after `translate_code` and
records raw `TCGOp` identity and fields. It is still only an inventory source
and does not build `PTCInstructionList`.

## Input Discovery

The expected verification directory existed:

```text
/tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k
```

The AVX2 JSONL input was:

```text
/tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-vex.tcg-op-walk.jsonl
```

The lookup command used to confirm the path was:

```bash
find /tmp -maxdepth 5 -type f \( -name '*.jsonl' -o -name '*jsonl*' \) 2>/dev/null | sort | rg 'walker|tcg|avx|ptc'
```

## Command

```bash
python3 runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py \
  --walker-jsonl /tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-vex.tcg-op-walk.jsonl \
  --legacy-opc qemu/tcg/tcg-opc.h
```

The parser also supports mixed text and walker inputs:

```bash
python3 runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py \
  --dump /tmp/rr-qemu-v2-tcg-op-dump-smoke3/dumps/avx2-vex.tcg-ops.txt \
  --walker-jsonl /tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-vex.tcg-op-walk.jsonl \
  --legacy-opc qemu/tcg/tcg-opc.h \
  --json-out /tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-combined.ptc-inventory.json \
  --markdown-out /tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-combined.ptc-inventory.md
```

JSON/Markdown outputs now mark input source type as `text-dump` or
`walker-jsonl`.

## AVX2 Walker Result

Observed input stats:

```text
source type: walker-jsonl
TB header: pc=0x401000 nb_ops=91 icount=9
JSONL lines: 92
metadata records: 1
op records: 91
skipped records: 0
```

Observed inventory summary:

```text
Unique opcodes: 17
Direct legacy hits: 4 names / 10 occurrences
Alias or compatibility candidates: 7 names / 38 occurrences
Missing from legacy PTC ABI: 6 names / 43 occurrences
```

Compatibility summary:

| Compatibility | Names | Occurrences |
|---|---:|---:|
| `direct` | 4 | 10 |
| `alias` | 7 | 38 |
| `requires-ptc-v2-op` | 3 | 6 |
| `requires-operand-schema` | 3 | 37 |
| `unknown` | 0 | 0 |

Direct legacy hits:

| Opcode | Count |
|---|---:|
| `call` | 4 |
| `discard` | 3 |
| `exit_tb` | 2 |
| `set_label` | 1 |

Alias candidates:

| Opcode | Count | Candidate legacy opcodes |
|---|---:|---|
| `insn_start` | 9 | `debug_insn_start` |
| `mov` | 9 | `mov_i32`, `mov_i64` |
| `add` | 8 | `add_i32`, `add_i64` |
| `ld` | 5 | `ld_i32`, `ld_i64` |
| `st` | 4 | `st_i32`, `st_i64` |
| `st8` | 2 | `st8_i32`, `st8_i64` |
| `brcond` | 1 | `brcond_i32`, `brcond_i64` |

Non-direct ABI gaps:

| Opcode | Count | Compatibility | Proposed opcode/schema |
|---|---:|---|---|
| `mov_vec` | 18 | `requires-operand-schema` | `PTC_OP_MOV_VEC` plus vector operand schema |
| `st_vec` | 18 | `requires-operand-schema` | `PTC_OP_ST_VEC` plus vector operand schema |
| `extract` | 2 | `requires-ptc-v2-op` | `PTC_OP_EXTRACT` |
| `qemu_ld2` | 2 | `requires-ptc-v2-op` | `PTC_OP_QEMU_LD2` |
| `qemu_st2` | 2 | `requires-ptc-v2-op` | `PTC_OP_QEMU_ST2` |
| `ld_vec` | 1 | `requires-operand-schema` | `PTC_OP_LD_VEC` plus vector operand schema |

## Name Compatibility Note

The text inventory sees type-decorated names such as `qemu_ld2_i128`,
`qemu_st2_i128`, and `extract_i64`. The walker JSONL sees raw C-side opcode
names such as `qemu_ld2`, `qemu_st2`, and `extract`, with type details in
fields such as `param1`/`param2` and raw args.

The inventory keeps those spellings distinct. `qemu_ld2` and `qemu_st2` are
explicitly classified as `requires-ptc-v2-op`, not as direct legacy
`qemu_ld_i*`/`qemu_st_i*` hits. Generic scalar names like `ld`, `st`, and `add`
are `alias` only because they still require operand-type selection before
mapping to `_i32` or `_i64` legacy opcodes.

## Validation

```bash
python3 -m py_compile runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py

python3 runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py \
  --walker-jsonl /tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-vex.tcg-op-walk.jsonl \
  --legacy-opc qemu/tcg/tcg-opc.h

python3 runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py \
  --dump /tmp/rr-qemu-v2-tcg-op-dump-smoke3/dumps/avx2-vex.tcg-ops.txt \
  --walker-jsonl /tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-vex.tcg-op-walk.jsonl \
  --legacy-opc qemu/tcg/tcg-opc.h \
  --json-out /tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-combined.ptc-inventory.json \
  --markdown-out /tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-combined.ptc-inventory.md
```

All commands completed successfully.
