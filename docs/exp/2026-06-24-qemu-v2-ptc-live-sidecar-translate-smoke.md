# QEMU V2 PTC Live Sidecar Translate Smoke

Date: 2026-06-24
Tool: `runnable/scripts/qemu_v2_ptc_live_sidecar_translate_smoke.sh`

## Purpose

This smoke targets the stronger PTC bridge shape: a throwaway `/tmp/libtinycode-x86_64.so` whose `ptc_translate` path shells out to a `/tmp` sidecar, regenerates live QEMU walker/model data during the translate call, and then rebuilds a non-empty `PTCInstructionList` through the exact repo `qemu/linux-user/ptc.h` ABI.

The shared object itself remains PIC-only and does not link non-PIC QEMU linux-user objects.

## Command

```bash
bash runnable/scripts/qemu_v2_ptc_live_sidecar_translate_smoke.sh --fresh
```

Scratch root:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke
```

Generated library:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/libtinycode-x86_64.so
```

Sidecar paths:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/sidecar/sidecar.log
/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/sidecar/sidecar.model.json
/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/sidecar/sidecar.summary.json
```

## Evidence

Static check:

```bash
bash -n runnable/scripts/qemu_v2_ptc_live_sidecar_translate_smoke.sh
```

Result: pass.

Runtime smoke:

```bash
bash runnable/scripts/qemu_v2_ptc_live_sidecar_translate_smoke.sh --fresh
```

Result: pass.

The sidecar log shows the live QEMU regeneration path ran in the same `ptc_translate` call chain and completed the real walker/model conversion pipeline. The captured output includes the real smoke summary with these counts:

| Counter | Count |
|---|---:|
| instruction_count | 45 |
| argument_count | 115 |
| temp_count | 93 |
| emitted | 45 |
| rejected | 0 |
| global_temps | 37 |
| total_temps | 93 |

The sidecar log also records that the model and summary were materialized during the run:

```text
[2026-06-24T03:08:20.955043Z] model_json=/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/sidecar/sidecar.model.json
[2026-06-24T03:08:20.955113Z] summary_json=/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/sidecar/sidecar.summary.json
[2026-06-24T03:08:20.955154Z] sidecar-generated-lines=144
[2026-06-24T03:08:20Z] sidecar-finished model_json=/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/sidecar/sidecar.model.json summary_json=/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/sidecar/sidecar.summary.json payload=/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/sidecar/sidecar.payload.txt
```

The harness completed successfully and reported a non-empty translation:

```text
live sidecar smoke ok: library=/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/libtinycode-x86_64.so instruction_count=45 argument_count=94 temp_count=93 translated_size=45 iface_translated_size=45 sidecar_log=/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/sidecar/sidecar.log sidecar_model=/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/sidecar/sidecar.model.json sidecar_summary=/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/sidecar/sidecar.summary.json metadata=abi_version=2
bridge_kind=live_sidecar
real_translation=true
sidecar_triggered_during_ptc_translate=true
exact_repo_ptc_h=true
```

Artifacts:

- `scratch_root`: `/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke`
- `library_path`: `/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/libtinycode-x86_64.so`
- `sidecar_log`: `/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/sidecar/sidecar.log`
- `sidecar_model_json`: `/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/sidecar/sidecar.model.json`
- `sidecar_summary_json`: `/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-translate-smoke/sidecar/sidecar.summary.json`

## Notes

- The shared library is still a sidecar bridge, but it now reports
  `real_translation=true` because `ptc_translate` executes the real sidecar
  translation path before rebuilding the ABI list.
- The payload parser now skips the banner preamble, streams the payload through stdout, and reconstructs a non-empty `PTCInstructionList`.
- No blocker remains for this smoke.
