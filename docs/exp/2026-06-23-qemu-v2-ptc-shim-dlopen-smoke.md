# 2026-06-23 QEMU V2 PTC Shim dlopen Smoke

Branch: `codex/qemu-upgrade-v2`

## Purpose

Validate the minimal standalone PTC shim at the dynamic ABI boundary and probe
whether `runnable-lift` can reach the expected empty-translation failure mode
when its local `libtinycode-x86_64.so` is replaced by the generated stub.

This check intentionally does not modify `runnable/tools/runnable-lift` C++
sources. The current shim is still a load-smoke stub: it exports `ptc_load` and
`ptc_translate`, plus forward-compatible optional ABI metadata through
`ptc_abi_metadata` and `ptc_get_abi_metadata()`. `ptc_translate` returns a
size `0` empty `PTCInstructionList`.

## Smoke Script

Added:

```bash
runnable/scripts/qemu_v2_ptc_shim_dlopen_smoke.sh
```

The script:

- Calls `runnable/scripts/qemu_v2_make_ptc_shim_tree.sh` with a QEMU `10.2.3`
  source tree.
- Generates the shim project under `/tmp/qemu-v2-ptc-shim-dlopen-smoke`.
- Builds `build/libtinycode-x86_64.so`.
- Runs the generated tree's `make smoke`.
- Builds an additional `/tmp` C harness that explicitly checks
  `dlopen`, `dlsym("ptc_load")`, `dlsym("ptc_translate")`,
  `dlsym("ptc_abi_metadata")`, and `dlsym("ptc_get_abi_metadata")`.
- Verifies the optional ABI metadata content includes `abi_version=2`,
  `stub_kind=empty_stub`, `real_translation=false`, and
  `vector_schema=false`, and that the metadata symbol and getter agree.
- Calls both the directly resolved `ptc_translate` symbol and
  `PTCInterface.translate`, then frees the returned empty
  `PTCInstructionList`.
- If a local `runnable-lift` is executable, copies it plus
  `libtinycode-helpers-x86_64.ll` and `early-linked-x86_64.ll` into a `/tmp`
  run directory, replaces only that run directory's `libtinycode-x86_64.so`
  with the stub, and runs a tiny generated probe binary.

## Command

```bash
runnable/scripts/qemu_v2_ptc_shim_dlopen_smoke.sh \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3
```

Environment note:

- The repository's checked-in `qemu/` tree reports `VERSION=2.4.50`, so it
  does not satisfy the shim generator's explicit `10.2.3` source-tree check.
  This smoke used an existing local `/tmp` QEMU `10.2.3` tree instead.

## Results

Required ABI smoke passed.

Generated-tree smoke:

```text
smoke ok: pc=128 sp=32 exception_index=136 helper_defs_size=0
```

Additional explicit `dlopen`/`dlsym` harness:

```text
dlopen smoke ok: ptc_load=... ptc_translate=... iface_translate=... metadata=abi_version=2,empty_stub helper_defs_size=0 stack_top=...
```

The harness confirmed:

- `libtinycode-x86_64.so` loads with `dlopen`.
- `ptc_load` resolves with `dlsym` and returns success.
- `ptc_translate` resolves with `dlsym`.
- `ptc_abi_metadata` resolves with `dlsym`.
- `ptc_get_abi_metadata()` resolves with `dlsym` and returns the same content
  as `ptc_abi_metadata`.
- Metadata fields match `abi_version=2`, `stub_kind=empty_stub`,
  `real_translation=false`, and `vector_schema=false`.
- `PTCInterface.translate` is non-null.
- Both translation call paths are callable.
- Both calls return size `0`, keep dynamic PC equal to the input PC, return an
  empty instruction list, and the result can be passed to
  `ptc_instruction_list_free`.

Optional `runnable-lift` outer smoke also reached the expected boundary:

```text
RUNNABLE_LIFT_ENTRY=0x401020
RUNNABLE_LIFT_EXIT=134
RUNNABLE_LIFT_SMOKE=boundary:empty-translation
PTC_ABI_METADATA_SMOKE=pass
REAL_PTC_TRANSLATION=not-migrated-empty-stub
```

Relevant stderr:

```text
qemu-v2 PTC shim stub: ptc_init is not wired to modern QEMU APIs yet
qemu-v2 PTC shim stub: ptc_translate is not wired to modern QEMU APIs yet
Assertion failed at .../runnable/tools/runnable-lift/InstructionTranslator.cpp:571
Instr != nullptr
```

This is not a load-path failure. `runnable-lift` found its local
`libtinycode-x86_64.so`, loaded it through `dlopen`, resolved `ptc_load`, and
called into the stub `ptc_translate`. The observed assert is consistent with
the current code path: `CodeGenerator` calls `ptc.translate(...)`, then still
reads `instructions[0]` even when the stub returned an empty list, which in
turn reaches the `Instr != nullptr` assert in `InstructionTranslator`.

## Interpretation

ABI stub status: loadable.

The generated stub shared object satisfies the immediate dynamic ABI smoke
requirements for `ptc_load`, `ptc_translate`, interface pointer population, and
freeable empty translation results. It also exports the optional ABI metadata
contract for the empty-stub state: `abi_version=2`,
`stub_kind=empty_stub`, `real_translation=false`, and `vector_schema=false`.

Translation status: not migrated.

The result does not demonstrate real PTC translation. The shim still has no
modern QEMU `tb_gen_code`/TCG op walker path, no real linux-user initialization,
and no non-empty `PTCInstructionList`. The `runnable-lift` outer smoke confirms
that the integration can reach the stub boundary, then fails where existing
`runnable-lift` code assumes libtinycode returned at least one instruction.

## Artifacts

Temporary artifacts from the run:

- `/tmp/qemu-v2-ptc-shim-dlopen-smoke/build/libtinycode-x86_64.so`
- `/tmp/qemu-v2-ptc-shim-dlopen-smoke-run/ptc_shim_dlopen_smoke`
- `/tmp/qemu-v2-ptc-shim-dlopen-smoke-run/runnable-lift/runnable-lift.stderr`
- `/tmp/qemu-v2-ptc-shim-dlopen-smoke-run/runnable-lift/probe`

No `runnable-lift` source file was changed.
