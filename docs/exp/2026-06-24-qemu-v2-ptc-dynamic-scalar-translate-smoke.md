# QEMU V2 PTC Dynamic Scalar Translate Smoke

Date: 2026-06-24
Tool: `runnable/scripts/qemu_v2_ptc_dynamic_scalar_translate_smoke.sh`

## Purpose

This smoke advances the PTC migration one layer past the standalone
allocation harness. It builds a throwaway `libtinycode-x86_64.so` under
`/tmp`, exports `ptc_load` and `ptc_translate`, then `dlopen`s the shared
object and verifies that `ptc_translate` returns a non-empty scalar
`PTCInstructionList`.

The library is still scalar-model-backed. It does not wire modern QEMU
translation into the same shared object yet. Instead, the generated library
materializes a non-empty list from the prior scalar conversion-model JSON and
keeps the ABI surface loadable through `dlopen`.

## Command

```bash
bash runnable/scripts/qemu_v2_ptc_dynamic_scalar_translate_smoke.sh --fresh
```

Scratch root:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-dynamic-scalar-translate-smoke
```

The script reused the existing scalar model from the previous slice:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-real-translate-scalar-smoke/dumps/scalar-simple.ptc-conversion-model.json
```

## Artifacts

Generated outputs:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-dynamic-scalar-translate-smoke/libtinycode-x86_64.so
/tmp/rr-qemu-v2-upstream-probes/ptc-dynamic-scalar-translate-smoke/qemu_v2_ptc_dynamic_scalar_translate_lib.c
/tmp/rr-qemu-v2-upstream-probes/ptc-dynamic-scalar-translate-smoke/qemu_v2_ptc_dynamic_scalar_translate_smoke.c
/tmp/rr-qemu-v2-upstream-probes/ptc-dynamic-scalar-translate-smoke/qemu_v2_ptc_dynamic_scalar_translate_smoke
/tmp/rr-qemu-v2-upstream-probes/ptc-dynamic-scalar-translate-smoke/qemu_v2_ptc_dynamic_scalar_translate_smoke.log
/tmp/rr-qemu-v2-upstream-probes/ptc-dynamic-scalar-translate-smoke/qemu_v2_ptc_dynamic_scalar_translate_smoke.summary.json
```

## Evidence

The scalar model backing the library retained the previous slice counts:

| Counter | Count |
|---|---:|
| instruction_count | 45 |
| argument_count | 115 |
| temp_count | 93 |
| emitted | 45 |
| rejected | 0 |
| vector-schema-required | 0 |
| global_temps | 37 |
| total_temps | 93 |

The generated shared object then exported the dynamic PTC ABI and the harness
confirmed:

| Check | Result |
|---|---|
| `dlopen(libtinycode-x86_64.so)` | pass |
| `dlsym("ptc_load")` | pass |
| `dlsym("ptc_translate")` | pass |
| `dlsym("ptc_get_abi_metadata")` | pass |
| `ptc_load` | pass |
| `ptc_translate` returned non-empty list | pass |
| `instruction_count > 0` | pass |
| `argument_count > 0` | pass |
| `temp_count > 0` | pass |
| `rejected == 0` | pass |
| `vector_schema == 0` | pass |
| `ptc_instruction_list_free` path | pass |

## What Is Exact ABI

- The smoke compiled the generated library against the repository's checked-in
  `qemu/linux-user/ptc.h`.
- The generated library also compiled against the repository's checked-in
  `qemu/tcg/tcg-opc.h` through the real header include path.
- The harness used `USE_DYNAMIC_PTC` to exercise the dynamic ABI typedefs and
  still freed the returned allocation with the repo header's
  `ptc_instruction_list_free` helper.

## What Is Still Scalar-Model-Backed

- `ptc_translate` does not call into modern QEMU.
- The emitted `PTCInstructionList` comes from embedded/generated scalar model
  data, not from a live `tb_gen_code` or modern TCG walk.
- The shared object is a throwaway `/tmp` artifact, not a repo build product.

## Validation

Static checks:

```bash
bash -n runnable/scripts/qemu_v2_ptc_dynamic_scalar_translate_smoke.sh
```

Runtime smoke:

```text
dynamic scalar smoke ok: library=/tmp/rr-qemu-v2-upstream-probes/ptc-dynamic-scalar-translate-smoke/libtinycode-x86_64.so instruction_count=45 argument_count=115 temp_count=93 emitted=45 rejected=0 vector_schema=0 ptc_translate_non_empty=1 translated_size=45 iface_translated_size=45 metadata=abi_version=2
```

## Next Blocker

The next blocker is replacing the scalar-model-backed `ptc_translate` payload
with a real modern QEMU translation bridge. That still requires wiring
`tb_gen_code` or an equivalent translate-only path into the dynamic library,
then mapping the modern TCG op and temp stream into the legacy PTC ABI-owned
storage.
