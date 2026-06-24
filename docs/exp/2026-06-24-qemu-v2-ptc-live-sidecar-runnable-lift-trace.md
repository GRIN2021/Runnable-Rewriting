# QEMU V2 PTC Live Sidecar Runnable-Lift Trace

Date: 2026-06-24
Tool: `runnable/scripts/qemu_v2_ptc_live_sidecar_runnable_lift_trace.sh`

## Purpose

This trace is the narrow follow-up to the runnable-lift smoke. The live-sidecar
library already proved `ptc_translate` can return a non-empty list, but the
consumer probe still times out. This script keeps the same staged runnable-lift
setup and adds short `timeout` + `strace -ff -tt -T` sampling so the hang can be
assigned to a specific layer without touching runnable-lift C++.

## Command

```bash
bash runnable/scripts/qemu_v2_ptc_live_sidecar_runnable_lift_trace.sh --fresh
```

Scratch root:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-trace
```

Trace output:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-trace/trace
```

## Runtime Result

State progression on 2026-06-24:

```text
blocked:timeout
-> blocked:replay-library-rebuild
-> consumed:rewrite-success
```

Current traced run:

```text
RUNNABLE_LIFT_EXIT=0
RUNNABLE_LIFT_RESULT=consumed:rewrite-success
RUNNABLE_LIFT_TRACE_CONCLUSION=other
```

The replay-backed library was rebuilt successfully at:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-trace/replay-translate/libtinycode-x86_64.so
```

with the rebuild transcript at the real parent-level path:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-trace/replay-translate.rebuild.log
```

The run now completes successfully through `runnable-lift`:

```text
Rewrite Successful
runnable-lift: PTC ABI metadata detected abi_version=2 stub_kind=<unknown> real_translation=true vector_schema=<unknown>
runnable-lift: ptc.disassemble is null; skipping disassembly metadata for pc=0x401000
```

## Conclusion

The replay rebuild blocker is cleared for trace smoke. The earlier
`ptc payload parse instruction arg overflow: cursor=20 seen=0 limit=20`
message no longer reproduces during validation. With the replay payload helper
fixed to emit a single payload stream, the traced consumer run now reaches
`consumed:rewrite-success`.

The trace script now uses the same hardened binary resolution rule as the full
smoke: default auto-discovery only considers build-tree `runnable-lift`
artifacts, while an explicitly forced source-tree binary is still allowed but
is marked as a stale-binary risk via warning and summary fields.

## Artifacts

- `scratch_root`: `/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-trace`
- `trace_root`: `/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-trace/trace`
- `replay_rebuild_log_path`: `/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-trace/replay-translate.rebuild.log`
- `trace_summary`: `/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-trace/trace/trace.summary.txt`
- `process_tree_log`: `/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-trace/trace/process-tree.log`
- `summary_json`: `/tmp/rr-qemu-v2-upstream-probes/ptc-live-sidecar-runnable-lift-trace/qemu_v2_ptc_live_sidecar_runnable_lift_trace.summary.json`

## Next Step

The remaining work is no longer replay rebuild for trace smoke. Any next probe
should stay focused on downstream PTC migration rather than this consumer
launch path. The stale source-tree binary remains a manual misuse risk, not
the default trace path.
