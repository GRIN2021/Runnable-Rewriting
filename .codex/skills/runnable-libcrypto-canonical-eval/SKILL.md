---
name: runnable-libcrypto-canonical-eval
description: Run or audit the canonical libcrypto evaluation contract for SYM-20 using the repo-local 2026-04-28 ground-truth bundle, fresh runnable-cmp-eval compares, and explicit address mapping. Use when a task mentions SYM-20, canonical libcrypto eval, gtBlock.pb, the 2026-04-28 ground truth, or when historical CSV/coverage-sidecar results must be distinguished from the authoritative compare path.
---

# Runnable Libcrypto Canonical Eval

Use this skill when the task is specifically about the authoritative libcrypto benchmark contract, not just generic Runnable compare metrics.

## Canonical Contract

For `SYM-20`, the authoritative repo-local contract is:

1. Canonical binary:
   - `python3 scripts/libcrypto_bench_paths.py binary --must-exist`
2. Canonical ground truth protobuf:
   - `python3 scripts/libcrypto_bench_paths.py groundtruth-pb --must-exist`
3. Address mapping:
   - derive `.text` start from the ELF
   - quick check: `python3 scripts/libcrypto_bench_paths.py text-start`
   - keep Runnable rebase at `0x50000000` unless the user explicitly provides another contract
4. Compare path:
   - `python3 scripts/validate_libcrypto_ground_truth.py cmp --ll /abs/path/to/file.ll --out-dir /abs/path/to/out`

The wrapper records fresh `HIT`, `MISMATCH`, `OBJ_ONLY`, `LL_ONLY`, `FALSE_NEGATIVE`, `FALSE_POSITIVE`, `precision`, and `recall`.

## Quick Start

Gap-audit the canonical GT bundle:

```bash
python3 scripts/validate_libcrypto_ground_truth.py gap-audit \
  --out-dir runs/groundtruth_validation/canonical_gap_audit
```

Compare a lift under the canonical contract:

```bash
python3 scripts/validate_libcrypto_ground_truth.py cmp \
  --ll /abs/path/to/libcrypto.ll \
  --out-dir runs/groundtruth_validation/canonical_cmp
```

If you already know the exact binary and want the lower-level wrapper:

```bash
python3 .codex/skills/runnable-cmp-eval/scripts/run_cmp_eval.py \
  --binary /abs/path/to/libcrypto.so.3 \
  --ll /abs/path/to/libcrypto.ll \
  --text-start 0x... \
  --runnable-base 0x50000000
```

## Historical / Non-Canonical Paths

Do **not** report the following as the canonical `SYM-20` result without an explicit label:

- `coverage_sidecar_union_threadpool16`
- CSV-only GT flows such as `ground_truth.csv`
- `rebase_base=0x50400000`
- old libcrypto binaries whose SHA differs from the repo-local canonical `2026-04-28` bundle

Those paths are useful for forensics and side-by-side experiments, but they are not the authoritative compare contract.

When historical artifacts are involved, report them as:

- `historical sidecar-union / non-canonical`
- `old-binary compare / non-canonical`
- `canonical gtBlock.pb compare / authoritative`

## Required Reporting

Always include:

- absolute binary path
- absolute GT path
- absolute `.ll` path
- binary SHA when contract mismatch is possible
- `.text` start
- Runnable base
- `HIT`, `MISMATCH`, `OBJ_ONLY`, `LL_ONLY`
- `FALSE_NEGATIVE`, `FALSE_POSITIVE`
- `precision`, `recall`
- whether the result is `canonical` or `non-canonical`

## Current Repo Evidence

Use this note when you need the latest repo-local evidence and caveats:

- `docs/exp/2026-05-10-libcrypto-canonical-eval-contract.md`

Current repo-local comparable pair:

- baseline:
  - `runs/runnable-dev-2026-0429-textstart-serial/libcrypto.so.3.entry_0x500cef80.ll`
- optimized:
  - `runs/runnable-dev-2026-0501-textstart-dynamic-reapfix/libcrypto.so.3.entry_0x500cef80.dynamic.ll`

Both already compare against the canonical `2026-04-28` binary with:

- `.text_start=0xcef80`
- `runnable_base=0x50000000`

Prefer these over old `2026-04-14` baseline artifacts when the goal is to produce a same-contract baseline/optimized comparison for `SYM-20`.

## Caveat

The canonical `gtBlock.pb` bundle still has documented coverage gaps. Run the gap audit and report those counts instead of assuming objdump and GT are identical.
