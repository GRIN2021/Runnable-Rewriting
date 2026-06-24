# QEMU V2 TCG Dump PTC Inventory

Date: 2026-06-23
Branch: `codex/qemu-upgrade-v2`
Tool: `runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py`

## Purpose

This adds a small offline analysis step between the existing modern QEMU
`tcg_dump_ops` hook, the new C-side `TCGOp` walker JSONL records, and a real
PTC port. The script reads one or more text dumps from `tcg_dump_ops` and/or
walker JSONL files, counts opcode names, parses the legacy
`qemu/tcg/tcg-opc.h` `DEF(name, oargs, iargs, cargs, flags)` declarations, and
classifies observed modern dump opcodes as:

- direct legacy PTC opcode hits
- compatibility alias candidates
- missing from the legacy PTC opcode ABI

The script now also emits a separate compatibility classification for ABI
planning:

- `direct`
- `alias`
- `requires-ptc-v2-op`
- `requires-operand-schema`
- `unknown`

This is not PTC translation. It does not copy `TCGOp` arguments, temps, helper
metadata, labels, or memory arguments, and it does not build a
`PTCInstructionList`. The intended use is to establish the opcode inventory that
a future `dump_tinycode(TCGContext*) -> PTCInstructionList` implementation must
handle.

## Tool Usage

Default output is a Markdown summary on stdout:

```bash
python3 runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py \
  --dump /tmp/rr-qemu-v2-tcg-op-dump-smoke3/dumps/avx2-vex.tcg-ops.txt \
  --legacy-opc qemu/tcg/tcg-opc.h
```

The same run can also write durable machine-readable and human-readable files:

```bash
python3 runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py \
  --dump /tmp/rr-qemu-v2-tcg-op-dump-smoke3/dumps/avx2-vex.tcg-ops.txt \
  --legacy-opc qemu/tcg/tcg-opc.h \
  --json-out /tmp/rr-qemu-v2-tcg-op-dump-smoke3/dumps/avx2-vex.ptc-inventory.json \
  --markdown-out /tmp/rr-qemu-v2-tcg-op-dump-smoke3/dumps/avx2-vex.ptc-inventory.md
```

Multiple dumps can be passed by repeating `--dump FILE`; walker JSONL inputs can
be passed by repeating `--walker-jsonl FILE`. The two input kinds can be mixed,
counts are aggregated, and JSON/Markdown outputs mark each input source type as
`text-dump` or `walker-jsonl`.

Walker JSONL-only run:

```bash
python3 runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py \
  --walker-jsonl /tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-vex.tcg-op-walk.jsonl \
  --legacy-opc qemu/tcg/tcg-opc.h
```

Mixed text dump plus walker JSONL run:

```bash
python3 runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py \
  --dump /tmp/rr-qemu-v2-tcg-op-dump-smoke3/dumps/avx2-vex.tcg-ops.txt \
  --walker-jsonl /tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-vex.tcg-op-walk.jsonl \
  --legacy-opc qemu/tcg/tcg-opc.h \
  --json-out /tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-combined.ptc-inventory.json \
  --markdown-out /tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-combined.ptc-inventory.md
```

The JSON schema tag is now `qemu-v2-tcg-ptc-inventory-v3`; it keeps a
compatibility `dumps` array while adding the explicit `inputs` array.

The tool intentionally does not invoke a C preprocessor. It preserves raw
legacy arity expressions such as `TLADDR_ARGS` or `DATA64_ARGS`, and reports
unknown arity when the `DEF(...)` fields are not integer literals. The legacy
file also contains two conditional `debug_insn_start` definitions; the report
marks that duplicate name because only the real C build configuration decides
which branch is active.

## Verification Input

The validation used the existing dump:

```text
/tmp/rr-qemu-v2-tcg-op-dump-smoke3/dumps/avx2-vex.tcg-ops.txt
```

This file already existed, so no QEMU rebuild was needed. If the dump is absent,
regenerate it with the existing probe script under `/tmp`, for example:

```bash
runnable/scripts/qemu_v2_tcg_dump_probe.sh \
  --scratch-root /tmp/rr-qemu-v2-tcg-op-dump-smoke3 \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  --fresh \
  --apply-patch-only

runnable/scripts/qemu_v2_tcg_dump_probe.sh \
  --scratch-root /tmp/rr-qemu-v2-tcg-op-dump-smoke3 \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  --jobs 3 \
  --build-only

runnable/scripts/qemu_v2_tcg_dump_probe.sh \
  --scratch-root /tmp/rr-qemu-v2-tcg-op-dump-smoke3 \
  --run-only
```

Those commands keep the patched QEMU source and build products in `/tmp`.

## AVX2 VEX Inventory Result

Command:

```bash
python3 runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py \
  --dump /tmp/rr-qemu-v2-tcg-op-dump-smoke3/dumps/avx2-vex.tcg-ops.txt \
  --legacy-opc qemu/tcg/tcg-opc.h
```

Observed summary:

```text
Legacy DEF entries: 121
Legacy opcode names: 120
Duplicate legacy names: debug_insn_start
TB header: pc=0x401000 nb_ops=91 icount=9
Instruction marker lines: 9
Parsed op lines: 82
Unique dump opcodes: 18
Direct legacy hits: 12 names / 39 occurrences
Alias or compatibility candidates: 0 names / 0 occurrences
Missing from legacy PTC ABI: 6 names / 43 occurrences
```

Direct legacy hits:

| Dump opcode | Count | Visible arity | Notes |
|---|---:|---|---|
| `add_i64` | 8 | 3 | matches `DEF(add_i64, 1, 2, 0, ...)` |
| `mov_i64` | 8 | 2 | matches `DEF(mov_i64, 1, 1, 0, ...)` |
| `call` | 4 | 4, 5, 7 | variable call arity; legacy PTC stores `callo`/`calli` separately |
| `ld_i64` | 4 | 3 | direct hit |
| `st_i64` | 4 | 3 | direct hit |
| `discard` | 3 | 1 | direct hit |
| `exit_tb` | 2 | 1 | direct hit |
| `st8_i32` | 2 | 3 | direct hit |
| `brcond_i32` | 1 | 4 | direct hit |
| `ld_i32` | 1 | 3 | direct hit |
| `mov_i32` | 1 | 2 | direct hit |
| `set_label` | 1 | 1 | direct hit |

Missing legacy opcodes:

| Dump opcode | Count | Visible arity | Compatibility | Suggestion | Safe old PTCOpcode? |
|---|---:|---|---|---|---|
| `mov_vec` | 18 | 4 | `requires-operand-schema` | needs vector operand schema, proposed `PTC_OP_MOV_VEC` | no |
| `st_vec` | 18 | 5 | `requires-operand-schema` | needs vector operand schema, proposed `PTC_OP_ST_VEC` | no |
| `extract_i64` | 2 | 4 | `requires-ptc-v2-op` | needs new opcode, proposed `PTC_OP_EXTRACT_I64` | no |
| `qemu_ld2_i128` | 2 | 5 | `requires-ptc-v2-op` | needs new opcode, proposed `PTC_OP_QEMU_LD2_I128` | no |
| `qemu_st2_i128` | 2 | 5 | `requires-ptc-v2-op` | needs new opcode, proposed `PTC_OP_QEMU_ST2_I128` | no |
| `ld_vec` | 1 | 5 | `requires-operand-schema` | needs vector operand schema, proposed `PTC_OP_LD_VEC` | no |

Compatibility summary from the v2 report:

| Compatibility | Names | Occurrences |
|---|---:|---:|
| `direct` | 12 | 39 |
| `alias` | 0 | 0 |
| `requires-ptc-v2-op` | 3 | 6 |
| `requires-operand-schema` | 3 | 37 |
| `unknown` | 0 | 0 |

There were no alias candidates in this AVX2 dump. Future dumps from a less
specialized modern dump hook may expose generic modern names such as
`insn_start`, `qemu_ld`, `qemu_st`, `add`, or `extract`; the tool has explicit
classification hooks for the obvious compatibility cases, but those still need
real operand-type inspection in the eventual PTC dumper.

The walker JSONL input exposes raw C-side names such as `qemu_ld2` and
`qemu_st2`, while the text dump exposes type-decorated names such as
`qemu_ld2_i128` and `qemu_st2_i128`. The inventory keeps both spellings
explicitly classified as `requires-ptc-v2-op`; it does not silently treat raw
walker names as direct legacy `qemu_ld_i*`/`qemu_st_i*` hits. See
`docs/exp/2026-06-23-qemu-v2-tcg-walker-ptc-inventory.md` for the walker-only
validation result.

## Interpretation

The AVX2 dump is not blocked at the scalar-control-flow layer: scalar loads,
stores, arithmetic, labels, exits, and helper calls mostly match the legacy PTC
opcode names and visible arities.

The first real ABI gap is vector state and wide memory movement. `mov_vec`,
`ld_vec`, and `st_vec` account for 37 occurrences in the sample, while
`qemu_ld2_i128` and `qemu_st2_i128` account for another 4 occurrences. These
cannot be claimed as direct PTC compatibility. A real port must either extend
the PTC opcode ABI and `runnable-lift` translation for vector ops, or lower
these modern ops into a representation the existing translator can consume.

`extract_i64` is a smaller but still concrete semantic gap. The old opcode file
has no `extract_i64`; the old bridge cannot represent it by name without either
lowering to shifts/masks or adding an opcode.

The v2 compatibility table is an ABI admission table, not a translator. It gives
the next C-side `TCGOp` walker a concrete allow/extend/reject policy before
attempting `dump_tinycode(TCGContext*) -> PTCInstructionList`: direct scalar ops
can continue through the old ABI, modern vector ops require a vector operand
schema, paired i128 qemu memory ops and `extract_i64` require new PTC v2 opcodes
or an explicit, separately validated lowering pass, and unknown modern ops should
remain rejected until classified.

Instruction marker lines printed by `tcg_dump_ops` are not counted as op lines
because the text dump prints them as `---- ...` markers. A real
`dump_tinycode(TCGContext*)` must still map modern `insn_start` records to the
legacy `debug_insn_start` convention expected by the current lift path, or move
the consumer to a new explicit marker ABI.

## Validation Commands

```bash
python3 -m py_compile runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py

python3 runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py \
  --dump /tmp/rr-qemu-v2-tcg-op-dump-smoke3/dumps/avx2-vex.tcg-ops.txt \
  --legacy-opc qemu/tcg/tcg-opc.h

python3 runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py \
  --dump /tmp/rr-qemu-v2-tcg-op-dump-smoke3/dumps/avx2-vex.tcg-ops.txt \
  --legacy-opc qemu/tcg/tcg-opc.h \
  --json-out /tmp/rr-qemu-v2-tcg-op-dump-smoke3/dumps/avx2-vex.ptc-inventory.json \
  --markdown-out /tmp/rr-qemu-v2-tcg-op-dump-smoke3/dumps/avx2-vex.ptc-inventory.md

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

All five commands completed successfully.
