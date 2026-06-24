# QEMU V2 PTC Live Sidecar Runnable-Lift Fast Smoke

Date: 2026-06-24
Tool: `runnable/scripts/qemu_v2_ptc_live_sidecar_runnable_lift_fast_smoke.sh`

## Purpose

This smoke replays a live-sidecar payload from the translate smoke and runs it
through `runnable-lift` without re-entering the heavy QEMU tree copy path.

## Fixes

`InstructionTranslator::newInstruction()` no longer segfaults on missing
disassembly metadata. `PTCDump::disassemble()` now checks `ptc.disassemble`
and emits a diagnostic instead of calling a null function pointer.

`CodeGenerator::embeddedData()` no longer treats guest virtual addresses as
host pointers. It now slices bytes from the loaded ELF segment data and skips
uncovered ranges with a diagnostic.

The smoke parser was also tightened to classify these failures more
specifically when they reappear.

## Validation

```bash
bash -n runnable/scripts/qemu_v2_ptc_live_sidecar_runnable_lift_fast_smoke.sh
cmake --build build-codex-dynamic-current --target runnable-lift -j"$(nproc)"
bash runnable/scripts/qemu_v2_ptc_live_sidecar_runnable_lift_fast_smoke.sh --fresh
python3 -m json.tool /tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-fast-smoke/qemu_v2_ptc_live_sidecar_runnable_lift_fast_smoke.summary.json
```

Runtime result:

```text
result=passed
failure_class=consumed:rewrite-success
```

Key diagnostics from the retry path:

```text
runnable-lift: PTC ABI metadata detected abi_version=2 stub_kind=<unknown> real_translation=true vector_schema=<unknown>
runnable-lift: ptc.disassemble is null; skipping disassembly metadata for pc=0x401000
Rewrite Successful
```

The earlier gdb backtrace showed:

```text
#2 InstructionTranslator::newInstruction(...)
#3 CodeGenerator::translate(...)
#4 main()
```

Before the second guard, the next crash moved to
`CodeGenerator::embeddedData()`. Both are now handled.

## Result

The fast smoke now completes successfully on the replayed live-sidecar
payload. Fast smoke delegates the actual consumer run to the hardened trace
script, so its default path also avoids auto-selecting the stale source-tree
`runnable/tools/runnable-lift/runnable-lift` binary.

The remaining work is downstream PTC migration, not this startup crash.
