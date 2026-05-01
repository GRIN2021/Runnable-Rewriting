---
name: runnable-parallel-lift
description: Use when working on runnable parallel lift workflows and deciding whether a task should use the current dynamic branch-driven runnable-lift path or the legacy offline static sharding path.
---

# Runnable Parallel Lift

## Overview

There are two different parallel lift models in this repository. The default current architecture is the online dynamic branch-driven mode inside `runnable-lift`. The older offline static sharding flow exists only for legacy address-ranged experiments and must not be treated as the current default.

## Default Workflow: Dynamic Branch-Driven `runnable-lift`

Use this when the task is about the current parallel lift architecture.

Entry command:

```bash
runnable-lift <binary> <output.ll> \
  -dynamic-parallel \
  -parallel-workers=<N> \
  -parallel-fragment-dir=<fragment-dir> \
  [other normal runnable-lift flags]
```

Current user-facing flags:

- `-dynamic-parallel`
- `-parallel-workers=<N>`
- `-parallel-fragment-dir=<PATH>`

Internal flags that agents should not pass manually:

- `-parallel-worker-mode`
- `-parallel-seed-pc`

Dynamic artifacts:

- coordinator output: `<output.ll>`
- worker fragments: `<fragment-dir>/worker_<pc>.ll`
- worker logs:
  - `<fragment-dir>/worker_<pc>.ll.stdout.log`
  - `<fragment-dir>/worker_<pc>.ll.stderr.log`
- temporary merge output before rename: `<output.ll>.merged.ll`

Dynamic merge behavior:

- `runnable/tools/runnable-lift/CodeGenerator.cpp` spawns branch workers from the coordinator.
- Successful worker fragments are merged back into the top-level module with `runnable/scripts/merge_dynamic_runnable_fragments.py`.
- The final merged module replaces the coordinator output path. Dynamic mode does not produce `merged_full.ll`, `shard_results.json`, `raw/`, or `shards/`.

Recommended validation:

```bash
rg -n "dynamic-parallel|parallel-workers|parallel-fragment-dir" \
  runnable/tools/runnable-lift/Main.cpp \
  runnable/tools/runnable-lift/CodeGenerator.cpp

python3 -m unittest discover -s test -p 'test_merge_dynamic_runnable_fragments.py' -v
```

## Legacy Workflow: Offline Static Sharding

This is the old address-ranged family. Historical wrappers for it were `scripts/libcrypto_parallel_lift.py` together with `run_libcrypto_parallel_lift_stable.py`.

In this repository snapshot, the surviving legacy helper and CLI specification for that workflow is `runnable/scripts/_merge_dynamic_fragments_lib.py`. That path expects `runnable-lift` builds with `-addr-range-min` and `-addr-range-max` support and describes the offline per-function/static-shard artifact model instead of online branch spawning.

Legacy outputs are different from the dynamic mode:

- `shards/`
- `raw/`
- `eval/`
- `logs/`
- `shard_results.json`
- `shard_results.jsonl`
- `status.json`
- `merged.ll`
- `merged_full.ll`
- `final_report.json`
- `final_report.md`

Use the legacy flow only when the task explicitly calls for static address-ranged lifting, libcrypto/OpenSSL-style offline evaluation, or comparing against historical shard reports.

Recommended validation:

```bash
python3 runnable/scripts/_merge_dynamic_fragments_lib.py --help
git show origin/wip/runnable-20260409-121909:test/lift_openssl_parallel.py | sed -n '1,120p'
```

## Guardrails

- Treat dynamic branch-driven `runnable-lift` as the default explanation unless the task explicitly asks for the old static sharding flow.
- Do not mix dynamic worker fragments (`worker_<pc>.ll`) with legacy `shards/` or `raw/` outputs in the same interpretation or report.
- Do not describe `scripts/libcrypto_parallel_lift.py` or `run_libcrypto_parallel_lift_stable.py` as the current architecture.
- Do not expect `merged_full.ll`, `parallel.eval.json`, or shard manifests from dynamic mode.
- Do not feed dynamic fragments into the legacy offline evaluation pipeline. Dynamic fragments are only for `merge_dynamic_runnable_fragments.py`.
- Do not pass `-parallel-worker-mode` or `-parallel-seed-pc` by hand. Those are worker-internal flags.
- If a task depends on `-addr-range-min` or `-addr-range-max`, call it legacy/static sharding explicitly and verify the target branch still exposes those flags before proceeding.

## References

- `README.md` dynamic parallel prototype section
- `runnable/tools/runnable-lift/Main.cpp`
- `runnable/tools/runnable-lift/CodeGenerator.cpp`
- `runnable/scripts/merge_dynamic_runnable_fragments.py`
- `runnable/scripts/_merge_dynamic_fragments_lib.py`
- `docs/superpowers/plans/2026-04-29-runnable-lift-dynamic-branch-parallel.md`
- `test/test_merge_dynamic_runnable_fragments.py`
