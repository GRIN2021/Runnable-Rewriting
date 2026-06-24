# QEMU V2 PTC Walker JSONL Conversion Model

Date: 2026-06-23
Tool: `runnable/scripts/qemu_v2_ptc_convert_walker_jsonl.py`

## Purpose

This adds a manifest-driven prototype converter from C walker JSONL to a
`PTCInstructionList`-like JSON model. It validates the direct/alias/v2/vector
decision chain before implementing the real C-side
`TCGOp -> PTCInstructionList` converter, and now also projects walker
`record:"temp"` rows into a `PTCTemp`-like table.

This is not a runnable-lift consumable ABI. The output keeps raw walker
`TCGArg` values as evidence and marks every instruction/temp model with
`not_real_abi=true`. It does not allocate `PTCInstructionList`, does not wire
real opcode enum values, and does not provide the legacy in-memory `PTCTemp`
ABI expected by runnable-lift.

## Inputs

Walker JSONL:

```text
/tmp/rr-qemu-v2-ptc-tcg-temp-walker-task-t/dumps/avx2-vex.tcg-op-walk.jsonl
```

Manifest:

```text
/tmp/rr-qemu-v2-ptc-v2-manifest/avx2-walker.ptc-v2-manifest.json
```

The manifest already existed for this validation run. If it is missing, it can
be regenerated with:

```bash
python3 runnable/scripts/qemu_v2_ptc_v2_manifest.py \
  --inventory /tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-combined.ptc-inventory.json \
  --walker-jsonl /tmp/rr-qemu-v2-ptc-tcg-temp-walker-task-t/dumps/avx2-vex.tcg-op-walk.jsonl \
  --json-out /tmp/rr-qemu-v2-ptc-v2-manifest/avx2-walker.ptc-v2-manifest.json \
  --header-out /tmp/rr-qemu-v2-ptc-v2-manifest/ptc-v2-opc.h
```

## Conversion

Command:

```bash
python3 runnable/scripts/qemu_v2_ptc_convert_walker_jsonl.py \
  --walker-jsonl /tmp/rr-qemu-v2-ptc-tcg-temp-walker-task-t/dumps/avx2-vex.tcg-op-walk.jsonl \
  --manifest /tmp/rr-qemu-v2-ptc-v2-manifest/avx2-walker.ptc-v2-manifest.json \
  --json-out /tmp/rr-qemu-v2-ptc-convert-walker-temps/avx2-vex.ptc-conversion-model.json
```

Output:

```text
/tmp/rr-qemu-v2-ptc-convert-walker-temps/avx2-vex.ptc-conversion-model.json
```

The JSON contains:

- `instructions`: one converted decision record per walker `event=op`.
- `arguments`: a flat array of raw walker args, referenced by each
  instruction's `argument_start` and `argument_count`.
- `temps`: a top-level `PTCTemp`-like table projected from walker
  `record:"temp"` rows.
- `global_temps` and `total_temps`: observed temp counts that mirror the
  old `PTCInstructionList` shape.
- per-instruction `args` and `argument_schema` for local inspection.
- `summary`: emitted/rejected counts, category/opcode counters, temp counts,
  and a temp mapping report.

Decision policy:

| Manifest decision | Output `emit_kind` |
|---|---|
| `direct` | `legacy` |
| `alias` | `legacy` |
| `requires-ptc-v2-op` | `ptc-v2-op` |
| `vector-schema` / `requires-operand-schema` | `vector-schema-required` |
| `unknown` | `reject` |

Alias entries are still model decisions. For this prototype, the converter uses
manifest legacy candidates plus walker `param1` to choose `_i32` or `_i64`
opcodes where possible. A real C converter must validate the actual operand
shape before emitting.

## Temp Table Model

Each temp row includes the walker identity fields `temp_id`, `temp_index`,
`temp_name` as `name`, and `arg` as `walker_arg`. The `kind`, `val_type`,
`base_type`, and `type` fields preserve the modern walker raw/name values and
add a `ptc_mapping` object when the value can be safely mapped to the old
runnable-lift enum space.

The old `PTCType` only contains `I32` and `I64`. Modern `I128`, `V128`, and
`V256` temps are preserved in the modern type fields, while the old
`ptc_temp_model.type` / `base_type` values are left `null` and reported as
`unmapped-modern-type`.

The model derives boolean inspection flags:

- `is_global` from walker `is_global`.
- `is_const` from `kind_name == "TEMP_CONST"` or `val_type_name == "TEMP_VAL_CONST"`.
- `is_memory_backed` from `mem_allocated`, `mem_base_id`, `mem_base_arg`, or `TEMP_VAL_MEM`.
- `is_register_value` from `TEMP_VAL_REG`.
- `is_fixed_register` from `TEMP_FIXED`.

Fields that cannot be reliably mapped are explicitly reported in
`summary.temp_mapping_report.unreliable_or_unmapped_fields`. In this run,
`mem_reg` is always `null`; `temp_local` is left `null` in
`ptc_temp_model` with only an approximate `derived_candidates.temp_local`
value; vector/I128 type mappings are nullable; `reg` is only populated for
`TEMP_FIXED` or `TEMP_VAL_REG`; and `val` is only populated for
`TEMP_CONST` or `TEMP_VAL_CONST`. Raw walker `reg`/`val` remain available under
`modern_walker`.

## AVX2 Result

The validation run printed:

```text
wrote: /tmp/rr-qemu-v2-ptc-convert-walker-temps/avx2-vex.ptc-conversion-model.json
conversion summary: instructions=91 arguments=248 temps=93 global_temps=37 total_temps=93 emitted=91 rejected=0
emit kinds: legacy=48 ptc-v2-op=6 vector-schema-required=37 reject=0
```

Summary from the output JSON:

| Counter | Count |
|---|---:|
| instructions | 91 |
| arguments | 248 |
| temps | 93 |
| global temps | 37 |
| total temps | 93 |
| emitted | 91 |
| rejected | 0 |
| legacy emit | 48 |
| PTC v2 op emit | 6 |
| vector schema required | 37 |
| reject | 0 |

Category counts:

| Category | Count |
|---|---:|
| `direct` | 10 |
| `alias` | 38 |
| `v2-op` | 6 |
| `vector-schema` | 37 |
| `unknown` | 0 |

Opcode decisions:

| Input opcode | Canonical opcode | `emit_kind` | Emitted opcode | Count |
|---|---|---|---|---:|
| `ld` | `ld` | `legacy` | `ld_i32` / `ld_i64` | 5 |
| `brcond` | `brcond` | `legacy` | `brcond_i32` | 1 |
| `st8` | `st8` | `legacy` | `st8_i32` | 2 |
| `insn_start` | `insn_start` | `legacy` | `debug_insn_start` | 9 |
| `mov` | `mov` | `legacy` | `mov_i32` / `mov_i64` | 9 |
| `add` | `add` | `legacy` | `add_i64` | 8 |
| `st` | `st` | `legacy` | `st_i64` | 4 |
| `call` | `call` | `legacy` | `call` | 4 |
| `discard` | `discard` | `legacy` | `discard` | 3 |
| `exit_tb` | `exit_tb` | `legacy` | `exit_tb` | 2 |
| `set_label` | `set_label` | `legacy` | `set_label` | 1 |
| `extract` | `extract_i64` | `ptc-v2-op` | `PTC_OP_EXTRACT_I64` | 2 |
| `qemu_ld2` | `qemu_ld2` | `ptc-v2-op` | `PTC_OP_QEMU_LD2` | 2 |
| `qemu_st2` | `qemu_st2` | `ptc-v2-op` | `PTC_OP_QEMU_ST2` | 2 |
| `ld_vec` | `ld_vec` | `vector-schema-required` | `PTC_OP_LD_VEC` | 1 |
| `mov_vec` | `mov_vec` | `vector-schema-required` | `PTC_OP_MOV_VEC` | 18 |
| `st_vec` | `st_vec` | `vector-schema-required` | `PTC_OP_ST_VEC` | 18 |

The `extract` walker records are canonicalized to `extract_i64` using walker
`param1=TCG_TYPE_I64`, matching the manifest's v2 proposal.

Temp table counts:

| Counter | Count |
|---|---:|
| `TEMP_GLOBAL` | 35 |
| `TEMP_TB` | 21 |
| `TEMP_EBB` | 19 |
| `TEMP_CONST` | 16 |
| `TEMP_FIXED` | 2 |
| `TCG_TYPE_I64` | 65 |
| `TCG_TYPE_V128` | 17 |
| `TCG_TYPE_I32` | 7 |
| `TCG_TYPE_V256` | 4 |

Legacy temp type mapping status:

| Mapping | Count |
|---|---:|
| `type.mapped` | 72 |
| `type.unmapped-modern-type` | 21 |
| `base_type.mapped` | 66 |
| `base_type.unmapped-modern-type` | 27 |
| `val_type.mapped-by-name` | 93 |
| `reg.mapped-for-TEMP_FIXED-or-TEMP_VAL_REG` | 2 |
| `reg.null-not-register-valued` | 91 |
| `val.mapped-for-TEMP_CONST-or-TEMP_VAL_CONST` | 16 |
| `val.null-not-const-valued` | 77 |

## C-Side Gaps Before Real `PTCInstructionList`

The C converter still needs fields and validation that this JSON model does not
provide:

- Stable temp ID wiring from op arguments into the legacy `PTCInstructionArg`
  temp namespace. The walker exposes `arg_temp_ids`, but this behavior model
  still preserves raw walker args as evidence rather than producing real ABI
  arguments.
- Real `PTCTemp` table allocation/freeing and ABI-compatible population. The
  JSON `temps` table is a PTCTemp-like inspection model, not allocated C
  memory consumed by runnable-lift.
- Correct argument layout rules for special cases such as
  `debug_insn_start` and `call`; this model currently preserves walker args and
  does not perform legacy ABI truncation or call argument packing.
- Opcode enum mapping for both legacy names and proposed PTC v2 opcodes, not
  just string names.
- Operand-shape validation for alias ops before selecting `_i32` or `_i64`
  legacy opcodes.
- PTC v2 opcode definitions and consumer-side handling for `extract_i64`,
  `qemu_ld2`, and `qemu_st2`.
- Vector operand schema materialization for vector size, element size,
  lane count, whole-vector semantics, and any future lane-indexed ops.
- Memory operation decoding for `MemOpIdx`, endianness, sign/zero extension,
  alignment, MMU index, and paired load/store semantics.
- Label and control-flow target handling with stable label IDs.
- Ownership/allocation/freeing behavior for `PTCInstructionList.instructions`,
  `.arguments`, and `.temps`.
- Fail-closed reject paths when an opcode, type, arity, vector shape, or memory
  schema does not match the manifest.

## Validation

```bash
python3 -m py_compile runnable/scripts/qemu_v2_ptc_convert_walker_jsonl.py

python3 runnable/scripts/qemu_v2_ptc_convert_walker_jsonl.py \
  --walker-jsonl /tmp/rr-qemu-v2-ptc-tcg-temp-walker-task-t/dumps/avx2-vex.tcg-op-walk.jsonl \
  --manifest /tmp/rr-qemu-v2-ptc-v2-manifest/avx2-walker.ptc-v2-manifest.json \
  --json-out /tmp/rr-qemu-v2-ptc-convert-walker-temps/avx2-vex.ptc-conversion-model.json

python3 runnable/scripts/qemu_v2_ptc_convert_walker_jsonl.py \
  --walker-jsonl /tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-vex.tcg-op-walk.jsonl \
  --manifest /tmp/rr-qemu-v2-ptc-v2-manifest/avx2-walker.ptc-v2-manifest.json \
  --json-out /tmp/rr-qemu-v2-ptc-convert-walker-jsonl/avx2-vex.compat-op-only.ptc-conversion-model.json
```

All commands completed successfully. The temp walker conversion reported
`instructions=91 arguments=248 temps=93 global_temps=37 total_temps=93`. The
op-only compatibility conversion reported
`instructions=91 arguments=248 temps=0 global_temps=0 total_temps=0`.
