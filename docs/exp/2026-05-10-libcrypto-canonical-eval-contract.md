# 2026-05-10 libcrypto canonical eval contract

## Goal

修复 `SYM-20` 里 `libcrypto` 的评估口径错配，把当前 workspace 可直接验证的 canonical contract、历史 non-canonical 路径、以及 repo-local compare tooling 拆开记录清楚。

## Canonical Inputs In This Workspace

- Canonical binary:
  - `../GroudTruth/groundtruth-gap-analysis-skill/results/libcrypto-artifacts/libcrypto.so.3`
- Canonical GT:
  - `../GroudTruth/groundtruth-gap-analysis-skill/results/libcrypto-artifacts/libcrypto.gtBlock.pb`
- Canonical protobuf loader:
  - `../GroudTruth/protobuf_def/blocks_pb2.py`
- Canonical compare wrapper:
  - `runnable/scripts/run_cmp_eval.py`
- Canonical audit / compare entrypoint:
  - `runnable/scripts/validate_libcrypto_ground_truth.py`

These paths are discovered by `runnable/scripts/libcrypto_bench_paths.py`.

## Important Correction

The earlier `SYM-20` branch version assumed top-level `scripts/`, `tests/`, and `archives/...` paths inside `Runnable-Rewriting`. That does not match the current `codex/dynamic-parallel-lift` branch layout.

For this branch, the correct repo-local structure is:

- scripts under `runnable/scripts/`
- tests under `test/`
- canonical binary / gtBlock bundle discovered from the sibling `GroudTruth` checkout

## Commands

Resolve canonical assets:

```bash
python3 runnable/scripts/libcrypto_bench_paths.py binary --must-exist
python3 runnable/scripts/libcrypto_bench_paths.py groundtruth-pb --must-exist
python3 runnable/scripts/libcrypto_bench_paths.py blocks-pb2 --must-exist
python3 runnable/scripts/libcrypto_bench_paths.py cmp-tool --must-exist
python3 runnable/scripts/libcrypto_bench_paths.py text-start
```

Gap-audit canonical GT coverage:

```bash
python3 runnable/scripts/validate_libcrypto_ground_truth.py gap-audit \
  --out-dir runs/groundtruth_validation/canonical_gap_audit
```

Compare a lift under the canonical contract:

```bash
python3 runnable/scripts/validate_libcrypto_ground_truth.py cmp \
  --ll /abs/path/to/libcrypto.ll \
  --out-dir runs/groundtruth_validation/canonical_cmp
```

## Historical vs Canonical

`SYM-19` results using:

- `coverage_sidecar_union_threadpool16`
- CSV GT bundles
- `rebase_base=0x50400000`
- the old `test/openssl_data/libcrypto.so.3`

must be treated as `historical sidecar-union / non-canonical`, not directly compared against canonical `gtBlock.pb` metrics.

## Current Caveat

This branch now contains the canonical compare wrappers and path resolution logic, but it does **not** vendor the large libcrypto run artifacts themselves into the `Runnable-Rewriting` git repository. The workflow is repo-local in the sense that the scripts and skill are committed here; the binary / protobuf assets are discovered from the co-located `GroudTruth` checkout.
