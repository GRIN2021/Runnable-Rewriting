# runnable-lift Empty PTCInstructionList Guard

Date: 2026-06-23

## Scope

This change only guards the current empty QEMU v2 PTC shim boundary. It does
not add real PTC v2 or vector translation support.

## Change

`CodeGenerator::translate()` now zero-initializes each `PTCInstructionList` and
checks the list before any `InstructionTranslator::preprocess()`,
`dumpTranslation()`, or `instructions[0]` access.

The guard fails closed when:

- `ptc.translate(...)` returns consumed size `0`.
- `instruction_count == 0`.
- `instructions == nullptr`.

The diagnostic includes the PC, consumed size, dynamic PC, instruction count,
and whether the instruction pointer is null.

## Verification

Built `runnable-lift` with:

```bash
cmake --build build-codex-dynamic-current --target runnable-lift -- -j2
```

Result: pass.

Ran the QEMU v2 empty-stub boundary smoke with the rebuilt binary:

```bash
runnable/scripts/qemu_v2_ptc_shim_dlopen_smoke.sh \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  --out-dir /tmp/qemu-v2-ptc-shim-empty-guard \
  --run-dir /tmp/qemu-v2-ptc-shim-empty-guard-run \
  --runnable-lift build-codex-dynamic-current/tools/runnable-lift/runnable-lift
```

Result:

```text
RUNNABLE_LIFT_EXIT=1
RUNNABLE_LIFT_SMOKE=boundary:empty-translation
runnable-lift: unsupported empty PTCInstructionList at pc=0x401020 consumed-size=0 dynamic-pc=0x401020 instruction-count=0 instructions=null
runnable-lift: PTC returned no usable legacy instructions; current QEMU v2 empty stubs are an unsupported boundary
REAL_PTC_TRANSLATION=not-migrated-empty-stub
```

Also attempted:

```bash
cmake --build build-runnable --target runnable-lift -- -j2
```

That tree is blocked before `CodeGenerator.cpp` by existing `-Werror`
diagnostics in `MonotoneFramework.h` / LLVM `ArrayRef`.
