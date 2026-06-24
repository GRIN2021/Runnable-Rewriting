# QEMU V2 PTC v2 Opcode/Schema Manifest

Date: 2026-06-23
Tool: `runnable/scripts/qemu_v2_ptc_v2_manifest.py`

## Purpose

This adds a machine-readable PTC v2 ABI manifest on top of the existing
walker/inventory output. The manifest is still not translation: it does not copy
`TCGOp` arguments into `PTCInstruction`, allocate `PTCInstructionList`, or
change `runnable-lift`. Its role is to give the future C-side
`TCGOp -> PTCInstructionList` converter a fail-closed input contract.

Converter policy encoded by the manifest:

- `direct`: emit a legacy opcode only when operands fit the old ABI.
- `alias`: select a typed legacy opcode from operand evidence or reject.
- `v2-op`: emit the proposed PTC v2 opcode or reject.
- `vector-schema`: apply the proposed vector operand schema or reject.
- `unknown`: reject.

## Inputs

Primary inventory input:

```text
/tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-combined.ptc-inventory.json
```

The input is a mixed text-dump plus walker inventory. The manifest generator
defaults to `--source-filter auto`, which uses readable walker JSONL evidence
listed by the inventory and therefore reports the AVX2 walker-only view:

```text
/tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-vex.tcg-op-walk.jsonl
```

If `--inventory` does not exist, the script does not invent results. It requires
a readable walker JSONL input or the default walker JSONL path, invokes the
existing `runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py`, and writes the
derived inventory under `/tmp`.

## Generation

Command:

```bash
python3 runnable/scripts/qemu_v2_ptc_v2_manifest.py \
  --inventory /tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-combined.ptc-inventory.json \
  --json-out /tmp/rr-qemu-v2-ptc-v2-manifest/avx2-walker.ptc-v2-manifest.json \
  --header-out /tmp/rr-qemu-v2-ptc-v2-manifest/ptc-v2-opc.h
```

Generated sample outputs:

```text
/tmp/rr-qemu-v2-ptc-v2-manifest/avx2-walker.ptc-v2-manifest.json
/tmp/rr-qemu-v2-ptc-v2-manifest/ptc-v2-opc.h
```

Observed summary:

```text
manifest schema: qemu-v2-ptc-v2-opcode-schema-manifest-v1
source mode: walker-jsonl
direct: 4 names / 10 occurrences
alias: 7 names / 38 occurrences
v2-op: 3 names / 6 occurrences
vector-schema: 3 names / 37 occurrences
unknown: 0 names / 0 occurrences
```

## Manifest Summary

Direct legacy entries:

| Category | Opcodes |
|---|---|
| `direct` | `call`, `discard`, `exit_tb`, `set_label` |

Alias entries:

| Category | Opcodes |
|---|---|
| `alias` | `add`, `brcond`, `insn_start`, `ld`, `mov`, `st`, `st8` |

PTC v2 opcode proposals:

| Opcode | Count | Proposed `DEF(...)` |
|---|---:|---|
| `extract_i64` | 2 | `DEF(extract_i64, 1, 1, 2, TCG_OPF_INT)` |
| `qemu_ld2` | 2 | `DEF(qemu_ld2, 2, 1, 1, TCG_OPF_CALL_CLOBBER \| TCG_OPF_SIDE_EFFECTS \| TCG_OPF_INT)` |
| `qemu_st2` | 2 | `DEF(qemu_st2, 0, 3, 1, TCG_OPF_CALL_CLOBBER \| TCG_OPF_SIDE_EFFECTS \| TCG_OPF_INT)` |

These are proposals only. They are not a direct replacement for
`qemu/tcg/tcg-opc.h` or the legacy Runnable PTC ABI. The future converter must
either emit a PTC v2 record matching this manifest or reject the op.

Vector operand schema proposals:

| Opcode | Count | Required schema evidence |
|---|---:|---|
| `ld_vec` | 1 | `vector_size` from `param1`, `element_size` from `param2`, derived `lane_count`, whole-vector load operands |
| `mov_vec` | 18 | `vector_size` from `param1`, `element_size` from `param2`, derived `lane_count`, whole-vector move operands |
| `st_vec` | 18 | `vector_size` from `param1`, `element_size` from `param2`, derived `lane_count`, whole-vector store operands |

Observed vector shapes in this AVX2 walker sample:

| Opcode | Shapes |
|---|---|
| `ld_vec` | `v256/e8`, 32 lanes |
| `mov_vec` | `v128/e8`, 16 lanes; `v256/e8`, 32 lanes |
| `st_vec` | `v128/e8`, 16 lanes; `v256/e8`, 32 lanes |

The current walker still lacks stable decoded temp IDs, global/env names, host
register allocation data, and explicit lane indexes. The lane index is absent
because the observed `mov_vec`, `ld_vec`, and `st_vec` records are whole-vector
operations.

## Header Sample

The generated `/tmp/rr-qemu-v2-ptc-v2-manifest/ptc-v2-opc.h` contains only the
new opcode proposal lines:

```c
DEF(extract_i64, 1, 1, 2, TCG_OPF_INT)
DEF(qemu_ld2, 2, 1, 1, TCG_OPF_CALL_CLOBBER | TCG_OPF_SIDE_EFFECTS | TCG_OPF_INT)
DEF(qemu_st2, 0, 3, 1, TCG_OPF_CALL_CLOBBER | TCG_OPF_SIDE_EFFECTS | TCG_OPF_INT)
```

Vector entries intentionally remain JSON schema proposals instead of standalone
legacy-compatible `DEF(...)` replacements.

## Fallback Check

Command:

```bash
python3 runnable/scripts/qemu_v2_ptc_v2_manifest.py \
  --inventory /tmp/rr-qemu-v2-ptc-v2-manifest/missing-input.ptc-inventory.json \
  --walker-jsonl /tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-vex.tcg-op-walk.jsonl \
  --tmp-dir /tmp/rr-qemu-v2-ptc-v2-manifest/fallback \
  --json-out /tmp/rr-qemu-v2-ptc-v2-manifest/fallback/avx2-walker.ptc-v2-manifest.json \
  --header-out /tmp/rr-qemu-v2-ptc-v2-manifest/fallback/ptc-v2-opc.h
```

This completed successfully and produced the same walker-only category summary.
The fallback generated a derived inventory from the real walker JSONL through
the existing inventory tool.

## Validation

```bash
python3 -m py_compile runnable/scripts/qemu_v2_ptc_v2_manifest.py

python3 runnable/scripts/qemu_v2_ptc_v2_manifest.py \
  --inventory /tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-combined.ptc-inventory.json \
  --json-out /tmp/rr-qemu-v2-ptc-v2-manifest/avx2-walker.ptc-v2-manifest.json \
  --header-out /tmp/rr-qemu-v2-ptc-v2-manifest/ptc-v2-opc.h
```

Both commands completed successfully.
