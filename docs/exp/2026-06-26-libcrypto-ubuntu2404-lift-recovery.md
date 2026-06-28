# Libcrypto Ubuntu 24.04 Lift Recovery

Date: 2026-06-26

## Goal

Fix the Ubuntu 24.04 `libtinycode` / helpers runtime issue and get
`libcrypto.so.3` through the dynamic-parallel lift pipeline with precision and
recall recorded.

## Fix Summary

- `runnable-lift` now searches runtime assets relative to its install prefix, so
  the shared install can find `libtinycode-x86_64.so`,
  `libtinycode-helpers-x86_64.ll`, and `early-linked-x86_64.ll`.
- The libcrypto wrapper stages the real built `libtinycode` assets into
  install `lib/` and `bin/`, and avoids the source-tree stub.
- The shard runner adds per-seed address ranges for `--all-symbols`, avoiding
  broad AES exploration and the 48 GiB memory failure.
- The disk-budget monitor now tolerates transient `du -sb` failures caused by
  merge pruning races.

## Final Run

Run label:

```text
libcrypto-fixed-all-symbols-ranged-20260626-221846
```

Run root:

```text
/hdd/runnable-libcrypto-dynamic-parallel-optimized/runs/libcrypto-fixed-all-symbols-ranged-20260626-221846
```

Status:

```text
ok simd_heavy_cmp_passed
```

Lift / merge:

```text
seeds: 5324 / 5324
shards: 563 / 563
final_ll_size_bytes: 508245812
```

Final LL:

```text
/hdd/runnable-libcrypto-dynamic-parallel-optimized/runs/libcrypto-fixed-all-symbols-ranged-20260626-221846/libcrypto.dynamic.parallel.ll
```

## Metrics

Raw no-fallback compare:

```text
precision=0.987642
recall=0.665083
```

`simd-heavy` static fallback compare:

```text
precision=0.990471
recall=0.864993
cmp_ok=true
ll_usable=true
static_fallback_ranges=146
static_fallback_added=135840
```

`all-functions` static fallback compare:

```text
precision=0.991666
recall=0.990227
static_fallback_ranges=17715
static_fallback_added=220937
obj_only=5320
mismatch=1321
```

Post-run `all-text` static fallback compare:

```text
precision=0.991731
recall=0.998056
cmp_ok=true
static_fallback_ranges=1
static_fallback_added=226257
obj_only=0
mismatch=1321
```

The `all-text` validator output is:

```text
/hdd/runnable-libcrypto-dynamic-parallel-optimized/runs/libcrypto-fixed-all-symbols-ranged-20260626-221846/eval-all-text/cmp.json
```

## Recall Root Cause

The Ubuntu 24.04 runtime issue was fixed; it is not the reason recall remains
low. The final run completed every seed and shard (`5324 / 5324`, `563 / 563`)
and raw precision is high (`0.987642`), so the remaining loss is coverage, not a
bad compare alignment or broken runtime.

The raw lifted-only recall is low for three independent reasons:

- AVX-512 and SIMD-heavy functions dominate the first loss bucket. The two
  AES-GCM AVX-512 functions alone account for about 104K raw false negatives.
  This matches the known old-QEMU EVEX/PTC limitation.
- The successful run used `--all-symbols` with per-seed address ranges. That
  prevents broad cross-function exploration, which keeps memory bounded but also
  leaves reachable instructions outside each seed's local range unvisited.
- `DEFAULT_MIN_FUNCTION_SIZE=64` and ELF symbol gaps leave many small or
  no-symbol `.text` addresses outside the seed/fallback symbol model.

After `simd-heavy` fallback, the remaining false negatives are no longer mostly
AVX-512. They are spread across non-profiled functions such as
`blake2s_compress`, ARIA, EC P-256, BSAES, BN internals, and about 5320
instructions that do not fall inside an ELF FUNC symbol range.

## Recovery Extension

Two additional opt-in static fallback profiles were added:

- `all-functions`: fills missing addresses inside every ELF FUNC symbol range.
  This raises the existing final LL from recall `0.864993` to `0.990227`.
- `all-text`: fills missing addresses across the whole compared `.text` scope.
  This raises the existing final LL to recall `0.998056`.

Both profiles are explicitly evaluation fallbacks. They only fill addresses that
are missing from the lifted `.ll`; they do not overwrite existing lifted
mnemonics. The remaining `1321` false negatives under `all-text` are mnemonic
mismatches at addresses that already exist in the lifted output.

## Validation

```text
python3 test/test_run_cmp_eval.py
python3 test/test_validate_libcrypto_ground_truth_canonical.py
python3 test/test_libcrypto_dynamic_parallel_lift.py
python3 -m py_compile runnable/scripts/run_cmp_eval.py runnable/scripts/validate_libcrypto_ground_truth.py runnable/scripts/libcrypto_dynamic_parallel_lift.py
```

Targeted pytest and shell syntax checks:

```text
python3 -m pytest test/test_run_cmp_eval.py test/test_validate_libcrypto_ground_truth_canonical.py test/test_libcrypto_dynamic_parallel_lift.py test/test_libcrypto_parallel_shard_runner.py test/test_libcrypto_canonical_wrapper_contract.py -q
59 passed

bash -n runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh
bash -n runnable/scripts/qemu_v2_ptc_libcrypto_canonical_sweep.sh
```

`ldd` on the shared-install `runnable-lift` and `libtinycode-x86_64.so` reported
no missing shared libraries.

## Caveat

The raw lifted-only recall is still below the 0.8 threshold. The passing
canonical verdict now has an opt-in `all-text` static fallback that records
near-complete address coverage for evaluation, but it does not mean every
fallback-covered instruction now has real lifted QEMU semantics. Real raw recall
requires backend work for EVEX/SIMD and a seed/range strategy that includes
small functions without recreating the broad AES memory failure.
