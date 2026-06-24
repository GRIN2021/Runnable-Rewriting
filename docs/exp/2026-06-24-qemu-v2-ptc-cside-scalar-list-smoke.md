# QEMU V2 PTC C-Side Scalar List Smoke

Date: 2026-06-24
Tool: `runnable/scripts/qemu_v2_ptc_cside_scalar_list_smoke.sh`

## Purpose

This smoke takes the scalar conversion-model JSON from the previous slice and
pushes one step farther: it allocates a real `PTCInstructionList`-shaped
payload on the C side, fills it from the scalar model counts and legacy opcode
metadata where safely available, validates the basic ownership/invariant
contract, and frees the allocation.

This run uses the repository's legacy `qemu/linux-user/ptc.h` ABI directly.
It does not modify `qemu/`, and it does not yet run inside QEMU. The harness
is a `/tmp` C program that links only against the header layout and its copied
`tcg-opc.h` enum definitions.

## Command

```bash
bash runnable/scripts/qemu_v2_ptc_cside_scalar_list_smoke.sh --fresh
```

Scratch root:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-cside-scalar-list-smoke
```

The script reused the existing scalar model when present:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-real-translate-scalar-smoke/dumps/scalar-simple.ptc-conversion-model.json
```

## Artifacts

Generated outputs:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-cside-scalar-list-smoke/qemu_v2_ptc_cside_scalar_list_smoke.c
/tmp/rr-qemu-v2-upstream-probes/ptc-cside-scalar-list-smoke/qemu_v2_ptc_cside_scalar_list_smoke
/tmp/rr-qemu-v2-upstream-probes/ptc-cside-scalar-list-smoke/qemu_v2_ptc_cside_scalar_list_smoke.log
/tmp/rr-qemu-v2-upstream-probes/ptc-cside-scalar-list-smoke/qemu_v2_ptc_cside_scalar_list_smoke.summary.json
```

## Evidence

The source model remained the same scalar subset from the previous slice:

| Counter | Count |
|---|---:|
| instruction_count | 45 |
| argument_count | 115 |
| temp_count | 93 |
| emitted | 45 |
| rejected | 0 |
| vector-schema-required | 0 |
| global_temps | 37 |

The generated C harness then allocated a non-empty list and validated:

| Check | Result |
|---|---|
| `instructions` allocation | pass |
| `arguments` allocation | pass |
| `temps` allocation | pass |
| `instruction_count == 45` | pass |
| `argument_count == 115` | pass |
| `temp_count == 93` | pass |
| `global_temps > 0` | pass |
| `ptc_temp_is_global` / `ptc_temp_get_by_mem_offset` | pass |
| free path | pass |

The harness populated the list with:

- legacy opcode names resolved from the scalar model
- flat `PTCInstructionArg` values copied from the model's raw argument list
- `PTCTemp` names, types, offsets, and flags where safely available from the
  scalar model

## What Is Exact ABI

- The harness includes the repository's checked-in `qemu/linux-user/ptc.h`
  directly.
- The harness also compiles against the repository's checked-in
  `qemu/tcg/tcg-opc.h`.
- The `PTCInstructionList`, `PTCInstruction`, and `PTCTemp` layout comes from
  the real legacy header.

## What Is Still Compatible, Not In-QEMU

- The allocator/free logic lives in the generated `/tmp` harness, not inside
  `qemu/linux-user/ptc.c`.
- `ptc_instruction_list_free` comes from the repository header as a static
  inline helper, not from an exported QEMU symbol.
- The smoke does not yet build a real `ptc_translate` implementation.
- It does not prove that QEMU itself can allocate and free the structure.

## Validation

Static checks:

```bash
bash -n runnable/scripts/qemu_v2_ptc_cside_scalar_list_smoke.sh
```

Runtime smoke:

```text
cside scalar list smoke ok: header_mode=exact_repo_ptc.h instruction_count=45 argument_count=115 temp_count=93 global_temps=37
```

## Next Blocker

The next blocker is moving the same allocation/free behavior into a real
QEMU-side `ptc_translate` path. The remaining gap is not the scalar model
shape anymore; it is wiring modern TCG walk data into in-tree ABI-owned
storage, including the actual `ptc_instruction_list_free` ownership path and
the temp/opcode mapping needed inside QEMU.
