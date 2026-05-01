---
name: fn-fp-root-cause-analysis
description: Use when runnable lift metrics already exist and you need structured false-negative or false-positive root-cause analysis from ground-truth, merged LL, and shard artifacts such as coverage CSVs, illegalEntry logs, stderr logs, or shard result manifests
---

# FN/FP Root Cause Analysis

## Overview

This skill is for explaining *why* runnable lift missed or over-lifted addresses.
Do not use it just to compute aggregate precision or recall.

## When To Use

- You already have ground-truth and lifted output.
- You need evidence-backed FN or FP categories instead of only `tp/fp/fn`.
- You have shard artifacts such as `shard_results.json`, `*.coverage.csv`, `*.illegalEntry.log`, `*.stderr.log`, `*.ll`, `*.li.csv`, or `*.need.csv`.

Do not use this skill when the task is only “run evaluation and report metrics”.
For that, run the validator script first and stop there unless asked for causes.

## Inputs

- Ground truth:
  - preferred: final-layout CSV like `ground_truth.csv`
  - plus `function_symbols.csv` for function-to-shard attribution
- Lift output:
  - merged LL such as `merged.ll`
- Optional shard evidence:
  - `shard_results.json`
  - shard `*.coverage.csv`
  - shard `*.illegalEntry.log`
  - shard `*.stderr.log`
  - shard `*.ll`

## Workflow

1. Compute metrics and address sets:

```bash
python3 runnable/scripts/validate_libcrypto_ground_truth.py \
  --ground-truth-csv <ground_truth.csv> \
  --ll <merged.ll> \
  --function-symbols-csv <function_symbols.csv> \
  --csv-image-base <csv image base> \
  --rebase-base <runtime base> \
  --summary-out <validation.json>
```

2. Analyze FN and FP causes:

```bash
python3 runnable/scripts/analyze_fn_fp_root_causes.py \
  --validation-summary <validation.json> \
  --ground-truth-csv <ground_truth.csv> \
  --function-symbols-csv <function_symbols.csv> \
  --merged-ll <merged.ll> \
  --shard-results-json <shard_results.json> \
  --csv-image-base <csv image base> \
  --rebase-base <runtime base> \
  --summary-out <analysis.json>
```

## Minimal Reproduction

```bash
python3 runnable/scripts/validate_libcrypto_ground_truth.py \
  --ground-truth-csv test/fixtures/fn_fp_root_cause/ground_truth.csv \
  --ll test/fixtures/fn_fp_root_cause/merged.ll \
  --function-symbols-csv test/fixtures/fn_fp_root_cause/function_symbols.csv \
  --csv-image-base 0x1000 \
  --rebase-base 0x50000000 \
  --summary-out /tmp/fnfp.validation.json

python3 runnable/scripts/analyze_fn_fp_root_causes.py \
  --validation-summary /tmp/fnfp.validation.json \
  --ground-truth-csv test/fixtures/fn_fp_root_cause/ground_truth.csv \
  --function-symbols-csv test/fixtures/fn_fp_root_cause/function_symbols.csv \
  --merged-ll test/fixtures/fn_fp_root_cause/merged.ll \
  --shard-results-json test/fixtures/fn_fp_root_cause/shard_results.json \
  --csv-image-base 0x1000 \
  --rebase-base 0x50000000 \
  --summary-out /tmp/fnfp.analysis.json
```

## Output Shape

Expect JSON with:

- `findings[]`
- each finding includes:
  - `kind`: `fn` or `fp`
  - `address`
  - `reason`
  - `priority`
  - `symbol` and `range` when attributable
  - `evidence_paths`

## Supported Reason Categories

- `illegal_entry_suppression`
- `shard_timeout`
- `shard_error`
- `shard_empty`
- `merge_missing`
- `continuation_byte`
- `ground_truth_gap`
- `padding`
- `outside_gt_coverage`
- `extra_lifted_bytes`

## Interpretation Rules

- Prefer shard-state explanations for FN when shard evidence exists.
- Prefer address-shape explanations for FP:
  - continuation bytes
  - GT gap near nearby instruction starts
  - padding or data-section spill
  - outside coverage
  - extra lifted bytes inside covered space

## Reporting Standard

When summarizing results for reviewers, include:

- representative addresses
- category counts
- exact evidence paths
- first-priority investigation directions

Do not collapse everything back into only aggregate metrics.
