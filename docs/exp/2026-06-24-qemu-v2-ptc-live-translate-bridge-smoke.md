# QEMU V2 PTC Live Translate Bridge Smoke

Date: 2026-06-24
Tool: `runnable/scripts/qemu_v2_ptc_live_translate_bridge_smoke.sh`

## Purpose

This is the minimal bridge spike for the next PTC migration step. It does not
yet move live QEMU translation into `ptc_translate` itself. Instead, it proves
the bridge is fresh by regenerating the live QEMU walker/model immediately
before building the dynamic `ptc_translate` smoke in one end-to-end run.

The result is a bounded fallback: the dynamic library is still backed by the
scalar conversion model, but that model was rebuilt from live walker evidence in
the same command invocation.

## Command

```bash
bash runnable/scripts/qemu_v2_ptc_live_translate_bridge_smoke.sh --fresh
```

Scratch root:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-live-translate-bridge-smoke
```

The smoke regenerated live evidence under:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-live-translate-bridge-smoke/real
```

and built the dynamic library under:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-live-translate-bridge-smoke/dynamic/libtinycode-x86_64.so
```

## Evidence

Live walker/model regeneration in the same run:

| Check | Result |
|---|---|
| `real` QEMU walker run executed during this smoke | pass |
| scalar model regenerated before dynamic build | pass |
| `live_walker_regenerated_same_run` | `true` |

Real walker/model counts:

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

Dynamic library smoke counts:

| Counter | Count |
|---|---:|
| instruction_count | 45 |
| argument_count | 115 |
| temp_count | 93 |
| emitted | 45 |
| rejected | 0 |
| vector_schema | 0 |
| `ptc_translate` non-empty | pass |

The dynamic smoke also confirmed:

| Check | Result |
|---|---|
| `dlopen(libtinycode-x86_64.so)` | pass |
| `dlsym("ptc_load")` | pass |
| `dlsym("ptc_translate")` | pass |
| `ptc_load` | pass |
| `ptc_translate` returned a non-empty list | pass |
| `ptc_instruction_list_free` path | pass |

## What Is Fresh

- The live QEMU walker output was regenerated in the same command invocation as
  the dynamic library build.
- The dynamic library was built from the freshly regenerated model, not from a
  pre-existing model file.
- The smoke stayed under `/tmp` for all build and output paths.

## What Is Still Prototype

- `ptc_translate` itself still emits the scalar-model-backed payload.
- The live QEMU walker and the dynamic library are still chained by the
  wrapper script, not fused inside the shared object.
- This does not yet prove a `ptc_translate` implementation that calls live QEMU
  translation directly.

## Validation

Static checks:

```bash
bash -n runnable/scripts/qemu_v2_ptc_live_translate_bridge_smoke.sh
```

Runtime smoke:

```text
bridge smoke ok:
  scratch_root=/tmp/rr-qemu-v2-upstream-probes/ptc-live-translate-bridge-smoke
  live_walker_regenerated_same_run=1
  real_summary=/tmp/rr-qemu-v2-upstream-probes/ptc-live-translate-bridge-smoke/real/dumps/scalar-simple.smoke-summary.json
  dynamic_summary=/tmp/rr-qemu-v2-upstream-probes/ptc-live-translate-bridge-smoke/dynamic/qemu_v2_ptc_dynamic_scalar_translate_smoke.summary.json
  bridge_summary=/tmp/rr-qemu-v2-upstream-probes/ptc-live-translate-bridge-smoke/qemu_v2_ptc_live_translate_bridge_smoke.summary.json
```

## Next Blocker

The next blocker is moving the live QEMU translate/walker path into the dynamic
library itself so `ptc_translate` constructs `PTCInstructionList` from live
output rather than from a freshly regenerated scalar conversion model. That
requires an in-library bridge to modern QEMU translation or an equivalent
translate-only hook, plus ABI-owned allocation for the list and temps.
