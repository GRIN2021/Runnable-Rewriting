# QEMU V2 PTC Real Translate Scalar Smoke

Date: 2026-06-24
Tool: `runnable/scripts/qemu_v2_ptc_real_translate_scalar_smoke.sh`

## Purpose

This smoke advances the PTC migration past the empty metadata-stub state for a
small scalar/simple slice. It proves that a throwaway patched QEMU 10.2.3
linux-user build can emit real modern TCG walker records, that those records can
be filtered to scalar/simple operations, and that the existing manifest-driven
converter can produce a non-empty `PTCInstructionList`-like artifact.

This is not full runnable-lift consumption. The final artifact is still the
converter's JSON behavior model, not an allocated C `PTCInstructionList`, not a
real `PTCInstructionArg` array, and not the legacy or v2 in-memory `PTCTemp`
ABI consumed by runnable-lift.

## Command

```bash
bash runnable/scripts/qemu_v2_ptc_real_translate_scalar_smoke.sh \
  --fresh \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  --jobs 3
```

Scratch root:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-real-translate-scalar-smoke
```

The script did not edit repository `qemu/`. It copied the upstream source into:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-real-translate-scalar-smoke/walker/qemu-10.2.3-ptc-tcg-op-walker-src
```

and built:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-real-translate-scalar-smoke/walker/build-10.2.3-ptc-tcg-op-walker/qemu-x86_64
```

## Artifacts

Inputs and generated outputs:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-real-translate-scalar-smoke/walker/dumps/avx2-vex.tcg-op-walk.jsonl
/tmp/rr-qemu-v2-upstream-probes/ptc-real-translate-scalar-smoke/dumps/scalar-simple.tcg-op-walk.jsonl
/tmp/rr-qemu-v2-upstream-probes/ptc-real-translate-scalar-smoke/dumps/scalar-simple.ptc-v2-manifest.json
/tmp/rr-qemu-v2-upstream-probes/ptc-real-translate-scalar-smoke/dumps/scalar-simple.ptc-v2-opc.h
/tmp/rr-qemu-v2-upstream-probes/ptc-real-translate-scalar-smoke/dumps/scalar-simple.ptc-conversion-model.json
/tmp/rr-qemu-v2-upstream-probes/ptc-real-translate-scalar-smoke/dumps/scalar-simple.smoke-summary.json
```

## Evidence

The real walker run produced an AVX2 translation block from QEMU 10.2.3:

| Counter | Count |
|---|---:|
| TB records | 1 |
| op records | 91 |
| temp records | 93 |
| QEMU return code | 0 |

The scalar/simple filter preserved non-vector, non-v2-proposal ops:

| Counter | Count |
|---|---:|
| input JSONL lines | 185 |
| input ops | 91 |
| scalar/simple ops kept | 45 |
| vector or v2 ops dropped | 46 |
| temp records kept | 93 |
| output JSONL lines | 139 |

The scalar manifest had no unknown, vector, or v2-op requirements:

| Category | Names | Occurrences |
|---|---:|---:|
| direct | 4 | 7 |
| alias | 7 | 38 |
| v2-op | 0 | 0 |
| vector-schema | 0 | 0 |
| unknown | 0 | 0 |

The conversion model passed the smoke assertions:

| Counter | Count |
|---|---:|
| instruction_count | 45 |
| argument_count | 115 |
| temp_count | 93 |
| emitted | 45 |
| rejected | 0 |
| legacy emit | 45 |
| ptc-v2-op emit | 0 |
| vector-schema-required emit | 0 |

Emitted opcode counts:

| Opcode | Count |
|---|---:|
| `debug_insn_start` | 9 |
| `add_i64` | 8 |
| `mov_i64` | 8 |
| `ld_i64` | 4 |
| `st_i64` | 4 |
| `discard` | 3 |
| `exit_tb` | 2 |
| `st8_i32` | 2 |
| `brcond_i32` | 1 |
| `call` | 1 |
| `ld_i32` | 1 |
| `mov_i32` | 1 |
| `set_label` | 1 |

## What Is Real

- QEMU 10.2.3 linux-user translation executed in a throwaway patched `/tmp`
  tree.
- TCG op/temp records came from the C walker JSONL emitted during that
  translation.
- The scalar manifest was generated from that walker JSONL evidence.
- The smoke fails closed when the walker JSONL is empty, has no op records, the
  scalar subset is empty, `instruction_count <= 0`, `argument_count <= 0`, or
  `rejected != 0`.

## What Is Still Prototype

- The output is a `PTCInstructionList`-like JSON model, not an allocated
  `PTCInstructionList`.
- Arguments are raw walker `TCGArg` evidence, not final ABI-compatible
  `PTCInstructionArg` records.
- Temps are a `PTCTemp`-like JSON projection, not runnable-lift-compatible temp
  memory.
- This smoke filters out vector ops and the scalar v2 proposals
  `extract_i64`, `qemu_ld2`, and `qemu_st2`; it does not solve their runnable
  semantics.
- The existing walker helper also ran the EVEX probe and saw target SIGILL
  after emitting a small dump. This did not affect the scalar AVX2 smoke result,
  but the wrapper currently inherits that extra EVEX run from
  `qemu_v2_ptc_tcg_op_walker_probe.sh`.

## Validation

Static checks:

```bash
bash -n runnable/scripts/qemu_v2_ptc_real_translate_scalar_smoke.sh runnable/scripts/qemu_v2_ptc_tcg_op_walker_probe.sh
python3 -m py_compile \
  runnable/scripts/qemu_v2_ptc_convert_walker_jsonl.py \
  runnable/scripts/qemu_v2_ptc_v2_manifest.py \
  runnable/scripts/qemu_v2_tcg_dump_ptc_inventory.py
```

Runtime smoke:

```text
Scalar PTC real-translate smoke passed.
instruction_count=45 argument_count=115 temp_count=93 emitted=45 rejected=0
```

## Next Blocker

The next real PTC blocker is replacing the JSON model with a C-side allocator
that fills an ABI-compatible instruction list and temp table. The scalar direct
and alias path now has evidence, but runnable-lift still cannot consume it
until temp IDs, typed arguments, opcode enum values, memory access encoding,
and ownership/freeing semantics are implemented in a real `ptc_translate`
bridge.
