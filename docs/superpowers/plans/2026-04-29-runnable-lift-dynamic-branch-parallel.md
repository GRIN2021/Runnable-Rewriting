# Runnable Lift Dynamic Branch Parallel Plan

## Purpose

This note is the repository-local reference for the current parallel lift architecture on `codex/dynamic-parallel-lift`. It exists so skills and future agents do not confuse the new online dynamic branch-driven flow with the older offline static sharding wrappers.

## Current Default: Online Dynamic Branch-Driven Parallelism

Primary entrypoint:

```bash
runnable-lift <binary> <output.ll> \
  -dynamic-parallel \
  -parallel-workers=<N> \
  -parallel-fragment-dir=<fragment-dir>
```

Implementation anchors:

- CLI flags: `runnable/tools/runnable-lift/Main.cpp`
- worker spawning and merge hook: `runnable/tools/runnable-lift/CodeGenerator.cpp`
- merge helper: `runnable/scripts/merge_dynamic_runnable_fragments.py`
- merge behavior test: `test/test_merge_dynamic_runnable_fragments.py`

Current behavior:

- the coordinator runs in the main `runnable-lift` process
- fresh branch frontiers can fork worker subprocesses
- workers write `worker_<pc>.ll` fragments into `-parallel-fragment-dir`
- successful fragments are merged back into the coordinator output module
- the final merged top-level module is written back to the original `<output.ll>` path

Dynamic artifacts:

- `<output.ll>`
- `<output.ll>.merged.ll` as a temporary pre-rename merge target
- `<fragment-dir>/worker_<pc>.ll`
- `<fragment-dir>/worker_<pc>.ll.stdout.log`
- `<fragment-dir>/worker_<pc>.ll.stderr.log`

Flags that are internal-only for worker subprocesses:

- `-parallel-worker-mode`
- `-parallel-seed-pc`

## Legacy Static Sharding Flow

Legacy static sharding refers to the older address-ranged workflow historically driven by `scripts/libcrypto_parallel_lift.py` and `run_libcrypto_parallel_lift_stable.py`.

The closest legacy helper and CLI specification that still exists in this repository is `runnable/scripts/_merge_dynamic_fragments_lib.py`. Its arguments and artifact model describe the old offline address-ranged orchestration family. That flow depends on `runnable-lift` binaries exposing `-addr-range-min` and `-addr-range-max`, as seen on `origin/wip/runnable-20260409-121909`.

Legacy artifacts are output-tree oriented rather than fragment-dir oriented:

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

Use the legacy flow only for historical per-function/address-range experiments, not for explaining the current default architecture.

## Validation

Dynamic validation:

```bash
rg -n "dynamic-parallel|parallel-workers|parallel-fragment-dir" \
  runnable/tools/runnable-lift/Main.cpp \
  runnable/tools/runnable-lift/CodeGenerator.cpp

python3 -m unittest discover -s test -p 'test_merge_dynamic_runnable_fragments.py' -v
```

Legacy validation:

```bash
python3 runnable/scripts/_merge_dynamic_fragments_lib.py --help
git grep -n "addr-range-min\\|addr-range-max" origin/wip/runnable-20260409-121909 -- runnable/tools/runnable-lift/JumpTargetManager.cpp test/lift_openssl_parallel.py
```

## Guardrails

- Default to the dynamic branch-driven path when a task says "current parallel lift architecture".
- Call out legacy/static sharding explicitly whenever a workflow depends on `-addr-range-min` or static shard manifests.
- Do not mix dynamic `worker_<pc>.ll` fragments with legacy `shards/` and `raw/` outputs.
- Do not claim that dynamic mode emits `merged_full.ll` or shard manifests.
- Do not manually pass worker-internal flags when exercising the public dynamic entrypoint.
