# QEMU V2 PTC Live Sidecar Runnable-Lift Smoke

Date: 2026-06-24
Tool: `runnable/scripts/qemu_v2_ptc_live_sidecar_runnable_lift_smoke.sh`

## Purpose

This smoke stages the now-passing live-sidecar `libtinycode-x86_64.so` where
`runnable-lift` can discover it, then runs one minimal lift probe to see whether
the consumer path actually consumes the non-empty `PTCInstructionList` or hits
a concrete opcode, temp, or ABI failure.

It is intentionally a consumer-layer check. It does not change
`runnable/tools/runnable-lift` C++.

## Command

```bash
bash runnable/scripts/qemu_v2_ptc_live_sidecar_runnable_lift_smoke.sh --fresh
```

Scratch root:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-smoke
```

Staged runnable-lift run directory:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-smoke/run
```

The smoke stages these files in that run directory:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-smoke/run/libtinycode-x86_64.so
/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-smoke/run/libtinycode-helpers-x86_64.ll
/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-smoke/run/early-linked-x86_64.ll
```

Live-sidecar library source:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/libtinycode-x86_64.so
```

## Sidecar Evidence

The library was produced by the earlier live-sidecar translate smoke, which
recorded a non-empty `PTCInstructionList`:

| Counter | Count |
|---|---:|
| instruction_count | 45 |
| argument_count | 115 |
| temp_count | 93 |

That evidence is documented in
[`docs/exp/2026-06-24-qemu-v2-ptc-live-sidecar-translate-smoke.md`](./2026-06-24-qemu-v2-ptc-live-sidecar-translate-smoke.md).

## Validation

Static check:

```bash
bash -n runnable/scripts/qemu_v2_ptc_live_sidecar_runnable_lift_smoke.sh
```

Runtime smoke:

```text
SCRATCH_ROOT=/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-smoke
LIBRARY_PATH=/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-smoke/replay-translate/libtinycode-x86_64.so
RUNNABLE_LIFT_ENTRY=0x401020
RUNNABLE_LIFT_EXIT=0
RUNNABLE_LIFT_RESULT=consumed:rewrite-success
```

Summary JSON:

```json
{
  "run_rc": 0,
  "result": "consumed:rewrite-success",
  "failure_class": "consumed:rewrite-success",
  "used_stale_source_tree_binary": false
}
```

## Result

State progression on 2026-06-24:

- Initial result: `blocked:timeout`
- Intermediate regression: `blocked:replay-library-rebuild`
- Previous full-smoke regression: `blocked:unknown` with `run_rc=139`
- Current result after smoke-script fix: `consumed:rewrite-success`

The replay rebuild blocker is cleared. The smoke now rebuilds the replay-backed
live-sidecar library at:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-smoke/replay-translate/libtinycode-x86_64.so
```

and the rebuild transcript lives at the real parent-level path:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-smoke/replay-translate.rebuild.log
```

The earlier `ptc payload parse instruction arg overflow: cursor=20 seen=0 limit=20`
failure no longer reproduces during replay rebuild.

The full smoke failure was not in the replay-backed live-sidecar library
itself. The script was preferring the stale source-tree
`runnable/tools/runnable-lift/runnable-lift` binary ahead of the freshly built
`build-codex-dynamic-current/runnable-lift`. That older binary did not contain
the `ptc.disassemble == nullptr` guard, so it segfaulted when the replay-backed
library intentionally left `PTCInterface.disassemble` unset.

The smoke script now:

- prefers `build-codex-dynamic-current/runnable-lift`, then other build trees,
  and no longer auto-selects the source-tree binary
- falls back to source-tree `libtinycode-helpers-x86_64.ll` and
  `early-linked-x86_64.ll` when the selected build tree lacks those companions
- emits a warning and summary fields when `--runnable-lift` explicitly points
  at the stale source-tree binary
- captures `strace` and `gdb` retry evidence when `run_rc=139` so the summary
  records a concrete `failure_class`

With the stale source-tree binary forced explicitly:

```bash
bash runnable/scripts/qemu_v2_ptc_live_sidecar_runnable_lift_smoke.sh \
  --fresh \
  --runnable-lift runnable/tools/runnable-lift/runnable-lift
```

the smoke no longer stops at `blocked:unknown`. It now classifies:

```json
{
  "run_rc": 139,
  "result": "blocked:runnable-lift-segv:disassemble",
  "failure_class": "runnable-lift-segv:disassemble"
}
```

The repo-local crash chain from the retry diagnostics is:

```text
PTCDump.cpp:258 disassemble
InstructionTranslator.cpp:582 InstructionTranslator::newInstruction
CodeGenerator.cpp:984 CodeGenerator::translate
Main.cpp:248 main
```

## Next Blocker

The full runnable-lift smoke is now passing against the replay-backed
live-sidecar library. The remaining blocker is outside this smoke: the
source-tree `runnable/tools/runnable-lift/runnable-lift` binary is stale
relative to the current C++ guard, but it is no longer selected by default.
It will still classify as `runnable-lift-segv:disassemble` if someone forces
that binary explicitly, and the script now records that stale-binary risk in
stderr and the summary JSON.
