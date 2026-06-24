# QEMU V2 PTC Modern Op Compatibility

Date: 2026-06-23
Tool: `runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py`

## Purpose

This note records the compatibility admission table produced from the modern
`tcg_dump_ops` text dump and the legacy PTC `qemu/tcg/tcg-opc.h` ABI. It is a
preflight ABI guide for a future C implementation of
`dump_tinycode(TCGContext*) -> PTCInstructionList`; it is not translation and
does not copy `TCGOp` args, temps, labels, helper metadata, or memory operands
into PTC structures.

The inventory tool now emits these compatibility classes:

| Compatibility | Meaning |
|---|---|
| `direct` | Same opcode name exists in the legacy PTC opcode file. |
| `alias` | The dump opcode can be routed to a legacy name, subject to the alias rule. |
| `requires-ptc-v2-op` | No safe old `PTCOpcode` exists; add a PTC v2 opcode or implement an explicit lowering pass. |
| `requires-operand-schema` | The operation needs operands the old ABI cannot encode, especially vector width, element kind, or vector temps. |
| `unknown` | No default rule exists; reject until modern TCG semantics are inspected. |

## Validation Input

The required AVX2 dump existed and was used directly:

```text
/tmp/rr-qemu-v2-tcg-op-dump-smoke3/dumps/avx2-vex.tcg-ops.txt
```

Validation command:

```bash
python3 runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py \
  --dump /tmp/rr-qemu-v2-tcg-op-dump-smoke3/dumps/avx2-vex.tcg-ops.txt \
  --legacy-opc qemu/tcg/tcg-opc.h \
  --json-out /tmp/rr-qemu-v2-tcg-op-dump-smoke3/dumps/avx2-vex.ptc-inventory.json \
  --markdown-out /tmp/rr-qemu-v2-tcg-op-dump-smoke3/dumps/avx2-vex.ptc-inventory.md
```

The generated JSON schema is `qemu-v2-tcg-dump-ptc-inventory-v2`.

## AVX2 Classification

Summary:

| Compatibility | Names | Occurrences |
|---|---:|---:|
| `direct` | 12 | 39 |
| `alias` | 0 | 0 |
| `requires-ptc-v2-op` | 3 | 6 |
| `requires-operand-schema` | 3 | 37 |
| `unknown` | 0 | 0 |

Missing modern op ABI advice:

| Dump opcode | Count | Visible arity | Compatibility | Suggestion | Safe old PTCOpcode? | Proposed PTC v2 opcode |
|---|---:|---|---|---|---|---|
| `mov_vec` | 18 | 4 | `requires-operand-schema` | add vector operand schema | no | `PTC_OP_MOV_VEC` |
| `st_vec` | 18 | 5 | `requires-operand-schema` | add vector operand schema | no | `PTC_OP_ST_VEC` |
| `ld_vec` | 1 | 5 | `requires-operand-schema` | add vector operand schema | no | `PTC_OP_LD_VEC` |
| `qemu_ld2_i128` | 2 | 5 | `requires-ptc-v2-op` | add opcode or prove lowering | no | `PTC_OP_QEMU_LD2_I128` |
| `qemu_st2_i128` | 2 | 5 | `requires-ptc-v2-op` | add opcode or prove lowering | no | `PTC_OP_QEMU_ST2_I128` |
| `extract_i64` | 2 | 4 | `requires-ptc-v2-op` | add opcode or explicit shift/mask lowering | no | `PTC_OP_EXTRACT_I64` |

The vector ops cannot be safely mapped to old scalar `ld_*`, `st_*`, or `mov_*`
opcodes because their dump operands include vector width such as `v128` or
`v256`, element kind such as `e8`, and vector temps or vector constants. The old
PTC ABI has no field that records those operand classes.

The paired i128 qemu memory ops cannot be safely mapped to old `qemu_ld_i64` or
`qemu_st_i64` opcodes by name. Splitting them into scalar memory operations may
be viable later, but that must be an explicit lowering pass with memory ordering,
endianness, and exception behavior reviewed against QEMU 10.2.3 semantics.

`extract_i64` is scalar but absent from the legacy opcode file. It can either be
promoted to a PTC v2 opcode or lowered to existing shift/mask ops, but the
inventory tool should not silently alias it.

## C ABI Implications

The next C-side `TCGOp` walker should treat this table as an admission policy:
emit legacy PTC only for `direct` and validated `alias` ops, emit or require PTC
v2 records for `requires-ptc-v2-op`, require a new vector operand schema for
`requires-operand-schema`, and reject `unknown` by default.

A minimal PTC v2 vector operand schema needs to preserve at least vector width,
element kind, vector temp identity, scalar env/base operands, constant vector
values, and memory offsets. Without those fields, `mov_vec`, `ld_vec`, and
`st_vec` would lose ABI-visible semantics before `runnable-lift` sees them.

This step deliberately stops before translation. It supplies the C walker and
ABI work with a concrete compatibility table so the real
`dump_tinycode(TCGContext*) -> PTCInstructionList` migration can fail closed
instead of pretending modern vector ops are old PTC opcodes.
