---
name: runnable-parallel-lift
description: Use when working on runnable parallel lift workflows — choosing between worklist (dynsym) mode and legacy static sharding, understanding the full libcrypto orchestration pipeline, or debugging lift failures.
---

# Runnable Parallel Lift

## Overview

There are two parallel lift architectures in this repository:

1. **Worklist mode** (current default): dynsym exported symbols as seeds, `.text`-scoped exploration, no per-function address-range constraints.
2. **Legacy static sharding**: per-function `-addr-range-min/-addr-range-max` constraints, all internal symbols as seeds.

The full libcrypto pipeline is orchestrated by `runnable/scripts/libcrypto_dynamic_parallel_lift.py`.

---

## Full Libcrypto Pipeline (Recommended)

### Worklist mode (default, `--dynsym-only`)

Seeds are the ~2050 exported (`.dynsym`) symbols. Each seed runs `runnable-lift -dynamic-parallel` and explores all reachable code within the `.text` section — no function-level address-range constraint. The `.text` bounds are auto-detected and injected as `-addr-range-min/-addr-range-max` coordinator flags to prevent PLT/GOT segfaults.

```bash
python3 Runnable-Rewriting/runnable/scripts/libcrypto_dynamic_parallel_lift.py \
  --hdd-root /hdd/runnable-libcrypto-dynamic-parallel-optimized \
  --run-label <label> \
  --container-memory-limit-gb 32 \
  --container-cpus 30 \
  --parallel-workers 5 \
  --shard-concurrency 6 \
  --max-concurrent-coordinators 6 \
  --worker-memory-gb 1 \
  --merge-workers 2 \
  --merge-batch-size 2 \
  --streaming-merge \
  --skip-cmp \
  --no-rebuild-lift \
  --dynsym-only
```

Key flags:
- `--dynsym-only` (default on): use exported symbols only as worklist seeds
- `--all-symbols`: revert to all internal symbols with per-function bounds (legacy behavior)
- `--no-rebuild-lift`: skip recompiling `runnable-lift`; requires a pre-staged `build-runnable/` dir

### Pre-staging the binary

The pipeline looks for `<hdd-root>/runs/<label>/build-runnable/runnable-lift`. To reuse a known-good binary:

```bash
SRC=/hdd/runnable-libcrypto-dynamic-parallel-optimized/runs/<good-run>/build-runnable
DST=/hdd/runnable-libcrypto-dynamic-parallel-optimized/runs/<new-label>/build-runnable
mkdir -p "$DST"
cp -r "$SRC"/. "$DST/"
```

Then pass `--no-rebuild-lift`.

### Small-scale test

```bash
python3 ... --max-seeds 5 --dynsym-only --no-rebuild-lift --skip-cmp
```

---

## Worklist Design

The worklist mechanism works at two levels:

| Level | Mechanism |
|---|---|
| Within each seed | `-dynamic-parallel` inside `runnable-lift` — coordinator explores main path, spawns workers at branch points |
| Across seeds | Python thread pool — each dynsym entry point is an independent worklist item |

**Why `.text` bounds instead of no bounds:** Without any `-addr-range-max`, exploration follows branches into PLT stubs. PLT reads GOT which is zero in a static-lift context → jump to address 0 → segfault. Setting `-addr-range-max` to the end of `.text` allows cross-function exploration while blocking PLT.

**Why dynsym only:** Internal functions are discovered naturally when exported functions call them. Starting from all ~5000 internal symbols causes massive redundancy and doesn't improve recall.

---

## Direct `runnable-lift` Usage

```bash
runnable-lift <binary> <output.ll> \
  -base=<base_addr> \
  -entry=<entry_addr> \
  -dynamic-parallel \
  -parallel-workers=<N> \
  -parallel-fragment-dir=<fragment-dir> \
  -addr-range-min=<text_start> \
  -addr-range-max=<text_end> \
  -use-debug-symbols -no-link
```

For a shared library, set `-addr-range-min/-addr-range-max` to the `.text` section bounds (relative VMA + base). For an executable with a `main`, a single entry from `main` without range constraints works fine.

Internal flags — do not pass manually:
- `-parallel-worker-mode`
- `-parallel-seed-pc`

---

## Disk Guardrails

- Host monitors `/hdd` free space; run terminates if free space drops below `--hdd-min-free-gb` (default 50 GB)
- `--prune-intermediate-files` (default on) deletes worker fragments, raw `.ll`, and per-seed merged files as soon as they are no longer needed

---

## Key Files

| File | Role |
|---|---|
| `runnable/scripts/libcrypto_dynamic_parallel_lift.py` | Main orchestrator — seed selection, sharding, streaming merge |
| `runnable/scripts/libcrypto_parallel_shard_runner.py` | Runs inside Docker; invokes `runnable-lift` per seed |
| `runnable/scripts/libcrypto_bench_paths.py` | Asset path resolution; `detect_text_bounds()` for `.text` section |
| `runnable/scripts/merge_dynamic_runnable_fragments.py` | Merges coordinator + worker fragments per seed |
| `runnable/scripts/_merge_dynamic_fragments_lib.py` | Merge library; handles per-shard and batch tree merges |
| `runnable/tools/runnable-lift/JumpTargetManager.cpp` | `isOutOfAddrRange()` — addr-range enforcement in C++ |

---

## Guardrails

- Default to `--dynsym-only` for new runs; only use `--all-symbols` when reproducing old results.
- Always pre-stage a known-good `build-runnable/` when using `--no-rebuild-lift`; a freshly compiled binary from an unstable branch may segfault.
- Do not remove both `-addr-range-min` and `-addr-range-max` without also preventing PLT exploration (the `.text` bound is required).
- Do not mix dynamic worker fragments (`worker_<pc>.ll`) with legacy `shards/` outputs.
- Do not pass `-parallel-worker-mode` or `-parallel-seed-pc` manually.
