# QEMU V2 PTC Walker Temp Conversion

Date: 2026-06-23
Tool: `runnable/scripts/qemu_v2_ptc_convert_walker_jsonl.py`

## Scope

This extends the manifest-driven walker conversion prototype to consume
walker JSONL `record:"temp"` rows and emit a top-level `temps` array with
`global_temps` and `total_temps` counts.

This remains a behavior model. It is not the runnable-lift ABI and does not
allocate/free `PTCInstructionList` or `PTCTemp` memory. The next C-side step is
real allocation/free plus opcode enum wiring and temp-argument wiring.

## Input

Temp-aware walker JSONL:

```text
/tmp/rr-qemu-v2-ptc-tcg-temp-walker-task-t/dumps/avx2-vex.tcg-op-walk.jsonl
```

Manifest:

```text
/tmp/rr-qemu-v2-ptc-v2-manifest/avx2-walker.ptc-v2-manifest.json
```

The manifest existed for validation. If absent, regenerate it with:

```bash
python3 runnable/scripts/qemu_v2_ptc_v2_manifest.py \
  --inventory /tmp/rr-qemu-v2-ptc-tcg-op-walker-task-k/dumps/avx2-combined.ptc-inventory.json \
  --walker-jsonl /tmp/rr-qemu-v2-ptc-tcg-temp-walker-task-t/dumps/avx2-vex.tcg-op-walk.jsonl \
  --json-out /tmp/rr-qemu-v2-ptc-v2-manifest/avx2-walker.ptc-v2-manifest.json \
  --header-out /tmp/rr-qemu-v2-ptc-v2-manifest/ptc-v2-opc.h
```

## PTCTemp-Like Mapping

Each top-level `temps[]` row includes:

- identity: `temp_id`, `temp_index`, `name`, and `walker_arg`.
- modern classifications: `kind`, `val_type`, `base_type`, and `type`.
- inspection flags: `is_global`, `is_const`, `is_memory_backed`,
  `is_register_value`, and `is_fixed_register`.
- `ptc_temp_model`: legacy-shaped fields such as `reg`, `mem_offset`, `val`,
  `val_type`, `base_type`, `type`, `fixed_reg`, `mem_coherent`,
  `mem_allocated`, `temp_local`, and `temp_allocated`.
- `derived_candidates`: approximate values that are useful for inspection but
  intentionally not written into nullable legacy fields.
- `mapping_status`: per-field reliability notes.

Unreliable or impossible legacy mappings are explicit:

- `mem_reg` stays `null` because modern walker records expose
  `mem_base_id` / `mem_base_arg`, not the old QEMU 2.4 `mem_reg`.
- `temp_local` stays `null` in `ptc_temp_model`; `TEMP_TB` maps to true and
  other modern temp kinds map to false only under `derived_candidates`.
- legacy `PTCType` is only `I32/I64`; modern `I128`, `V128`, and `V256` are
  preserved in modern fields and mapped to `null` in `ptc_temp_model`.
- `reg` is only populated in `ptc_temp_model` for `TEMP_FIXED` or
  `TEMP_VAL_REG`; raw walker `reg` remains under `modern_walker`.
- `val` is only populated in `ptc_temp_model` for `TEMP_CONST` or
  `TEMP_VAL_CONST`; raw walker `val` remains under `modern_walker`.

## Validation Result

Commands:

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

Temp walker output:

```text
wrote: /tmp/rr-qemu-v2-ptc-convert-walker-temps/avx2-vex.ptc-conversion-model.json
conversion summary: instructions=91 arguments=248 temps=93 global_temps=37 total_temps=93 emitted=91 rejected=0
emit kinds: legacy=48 ptc-v2-op=6 vector-schema-required=37 reject=0
```

Old op-only compatibility output:

```text
wrote: /tmp/rr-qemu-v2-ptc-convert-walker-jsonl/avx2-vex.compat-op-only.ptc-conversion-model.json
conversion summary: instructions=91 arguments=248 temps=0 global_temps=0 total_temps=0 emitted=91 rejected=0
emit kinds: legacy=48 ptc-v2-op=6 vector-schema-required=37 reject=0
```

Temp summary:

| Counter | Count |
|---|---:|
| temps | 93 |
| global temps | 37 |
| total temps | 93 |
| const temps | 16 |
| memory-backed temps | 35 |
| fixed-register temps | 2 |
| legacy type mapped | 72 |
| legacy type unmapped modern type | 21 |
| legacy base type mapped | 66 |
| legacy base type unmapped modern type | 27 |
| val type mapped by name | 93 |
| reg mapped for fixed/register-valued temps | 2 |
| reg null for non-register-valued temps | 91 |
| val mapped for const-valued temps | 16 |
| val null for non-const-valued temps | 77 |
