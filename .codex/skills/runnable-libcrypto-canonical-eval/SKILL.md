---
name: runnable-libcrypto-canonical-eval
description: Run or audit the canonical libcrypto evaluation contract for SYM-20 using the repo-local ground-truth bundle reachable from this workspace, fresh compare_runnable_text-based compares, and explicit address mapping. Use when a task mentions SYM-20, canonical libcrypto eval, gtBlock.pb, or when historical CSV/coverage-sidecar results must be distinguished from the authoritative compare path.
---

# Runnable Libcrypto Canonical Eval

Use this skill when the task is specifically about the authoritative libcrypto benchmark contract, not just generic Runnable compare metrics.

## Canonical Contract

For `SYM-20`, the authoritative contract in this workspace is:

1. Canonical binary:
   - `python3 runnable/scripts/libcrypto_bench_paths.py binary --must-exist`
2. Canonical ground truth protobuf:
   - `python3 runnable/scripts/libcrypto_bench_paths.py groundtruth-pb --must-exist`
3. Protobuf loader:
   - `python3 runnable/scripts/libcrypto_bench_paths.py blocks-pb2 --must-exist`
4. Compare tool:
   - `python3 runnable/scripts/libcrypto_bench_paths.py cmp-tool --must-exist`
5. Address mapping:
   - derive `.text` start from the ELF
   - quick check: `python3 runnable/scripts/libcrypto_bench_paths.py text-start`
   - keep Runnable rebase at `0x50000000` unless the user explicitly provides another contract
6. Compare path:
   - `python3 runnable/scripts/validate_libcrypto_ground_truth.py cmp --ll /abs/path/to/file.ll --out-dir /abs/path/to/out`

The wrapper records fresh `HIT`, `MISMATCH`, `OBJ_ONLY`, `LL_ONLY`, `FALSE_NEGATIVE`, `FALSE_POSITIVE`, `precision`, and `recall`.

## Quick Start

Gap-audit the canonical GT bundle:

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

## Historical / Non-Canonical Paths

Do **not** report the following as the canonical `SYM-20` result without an explicit label:

- `coverage_sidecar_union_threadpool16`
- CSV-only GT flows such as `ground_truth.csv`
- `rebase_base=0x50400000`
- old libcrypto binaries whose SHA differs from the repo-local canonical bundle

When historical artifacts are involved, report them as:

- `historical sidecar-union / non-canonical`
- `old-binary compare / non-canonical`
- `canonical gtBlock.pb compare / authoritative`

## Required Reporting

Always include:

- absolute binary path
- absolute GT path
- absolute `.ll` path
- `.text` start
- Runnable base
- `HIT`, `MISMATCH`, `OBJ_ONLY`, `LL_ONLY`
- `FALSE_NEGATIVE`, `FALSE_POSITIVE`
- `precision`, `recall`
- whether the result is `canonical` or `non-canonical`

## Repo Notes

- The canonical binary / protobuf are auto-discovered from this workspace's `GroudTruth` checkout, not from a checked-in `archives/` directory under `Runnable-Rewriting`.
- `runnable/scripts/validate_libcrypto_ground_truth.py` still supports the legacy CSV validation mode used by existing fn/fp root-cause tests; use `csv-validate` only for that older flow.
