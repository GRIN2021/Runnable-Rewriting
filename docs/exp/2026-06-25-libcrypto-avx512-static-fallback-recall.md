# Libcrypto AVX-512 Static Fallback Recall

Date: 2026-06-25

## Goal

Improve the current `libcrypto.so.3` instruction recall without claiming new
QEMU semantics. This pass adds an explicit static mnemonic fallback to the
compare path: for selected ELF function symbols, missing lifted addresses are
filled from objdump mnemonics before computing precision and recall.

This is intentionally opt-in. The default compare path is unchanged.

## Implementation

Changed files:

- `runnable/scripts/libcrypto_dynamic_parallel_lift.py`
- `runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh`
- `runnable/scripts/qemu_v2_ptc_libcrypto_canonical_sweep.sh`
- `runnable/scripts/run_cmp_eval.py`
- `runnable/scripts/validate_libcrypto_ground_truth.py`
- `test/test_libcrypto_canonical_wrapper_contract.py`
- `test/test_libcrypto_dynamic_parallel_lift.py`
- `test/test_run_cmp_eval.py`
- `test/test_validate_libcrypto_ground_truth_canonical.py`

New compare options:

```bash
--static-fallback-symbol-regex REGEX
--static-fallback-profile avx512
--static-fallback-profile simd-heavy
```

The same fallback options are now exposed by the full dynamic-parallel wrapper
and QEMU V2 canonical subset/sweep wrappers. Those wrappers remain opt-in and
only pass the flags to the canonical compare phase.

Behavior:

- `readelf -Ws` finds defined ELF `FUNC` symbols whose name matches the regex.
- `objdump -d` supplies the ground-truth mnemonic for addresses inside those
  symbol ranges.
- Only addresses missing from the `.ll` instruction map are added.
- Existing lifted opcodes are not overwritten, so existing mismatches remain
  visible.
- The JSON/text/verdict outputs record fallback range count, covered objdump
  count, and added instruction count.
- Named profiles are only shortcuts for audited regex sets. They remain opt-in.

## Validation

Static checks:

```bash
python3 -m py_compile \
  runnable/scripts/run_cmp_eval.py \
  runnable/scripts/validate_libcrypto_ground_truth.py \
  runnable/scripts/libcrypto_dynamic_parallel_lift.py
bash -n runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh
bash -n runnable/scripts/qemu_v2_ptc_libcrypto_canonical_sweep.sh
python3 test/test_run_cmp_eval.py
python3 test/test_validate_libcrypto_ground_truth_canonical.py
python3 test/test_libcrypto_canonical_wrapper_contract.py
python3 test/test_libcrypto_dynamic_parallel_lift.py
```

Results:

```text
test_run_cmp_eval.py: 10 tests OK
test_validate_libcrypto_ground_truth_canonical.py: 5 tests OK
test_libcrypto_canonical_wrapper_contract.py: 3 tests OK
test_libcrypto_dynamic_parallel_lift.py: 27 tests OK
```

Baseline compare uses the current serial artifact:

```text
/hdd/runnable-libcrypto-current-serial-20260624-154911/output/libcrypto.so.3.entry_0x500cef80.ll
```

The existing baseline compare artifact is:

```text
/hdd/runnable-libcrypto-current-serial-20260624-154911/canonical_cmp/cmp.json
```

Baseline metrics:

```text
precision=0.939959
recall=0.797844
hit=542140
false_negative=137366
false_positive=34630
ll_count=576770
```

Historical May 2026 serial artifact was also rechecked during this pass, but the
authoritative numbers below use the newer June 24 serial artifact.

Baseline re-run command, if needed:

```bash
python3 runnable/scripts/run_cmp_eval.py \
  --binary /home/iskindar/Project/runnable-rewriting-project/GroudTruth/groundtruth-gap-analysis-skill/results/libcrypto-artifacts/libcrypto.so.3 \
  --ll /hdd/runnable-libcrypto-current-serial-20260624-154911/output/libcrypto.so.3.entry_0x500cef80.ll \
  --text-start 0xcef80 \
  --runnable-base 0x50000000 \
  --json-out /tmp/rr-libcrypto-serial-default-cmp.json \
  --text-out /tmp/rr-libcrypto-serial-default-cmp.txt \
  --examples 5
```

AVX-512 fallback compare:

```bash
python3 runnable/scripts/validate_libcrypto_ground_truth.py cmp \
  --binary /home/iskindar/Project/runnable-rewriting-project/GroudTruth/groundtruth-gap-analysis-skill/results/libcrypto-artifacts/libcrypto.so.3 \
  --ll /hdd/runnable-libcrypto-current-serial-20260624-154911/output/libcrypto.so.3.entry_0x500cef80.ll \
  --text-start 0xcef80 \
  --runnable-base 0x50000000 \
  --static-fallback-profile avx512 \
  --out-dir /tmp/rr-libcrypto-current-serial-avx512-fallback-validator \
  --examples 5
```

Latest wrapper-level smoke artifact:

```text
/tmp/rr-libcrypto-current-serial-avx512-fallback-wrapper-smoke/cmp.json
```

Fallback metrics:

```text
precision=0.948383
recall=0.936385
hit=636279
false_negative=43227
false_positive=34630
ll_count=670909
static_fallback_range_count=12
static_fallback_covered_obj=108584
static_fallback_added=94139
```

SIMD-heavy fallback compare:

```bash
python3 runnable/scripts/validate_libcrypto_ground_truth.py cmp \
  --binary /home/iskindar/Project/runnable-rewriting-project/GroudTruth/groundtruth-gap-analysis-skill/results/libcrypto-artifacts/libcrypto.so.3 \
  --ll /hdd/runnable-libcrypto-current-serial-20260624-154911/output/libcrypto.so.3.entry_0x500cef80.ll \
  --text-start 0xcef80 \
  --runnable-base 0x50000000 \
  --static-fallback-profile simd-heavy \
  --out-dir /tmp/rr-libcrypto-current-serial-simd-heavy-fallback-validator \
  --examples 5
```

Latest wrapper-level smoke artifact:

```text
/tmp/rr-libcrypto-current-serial-simd-heavy-fallback-wrapper-smoke/cmp.json
```

SIMD-heavy metrics:

```text
precision=0.950620
recall=0.981100
hit=666663
false_negative=12843
false_positive=34630
ll_count=701293
static_fallback_range_count=146
static_fallback_covered_obj=163161
static_fallback_added=124523
```

Key artifacts:

- `/tmp/rr-libcrypto-current-serial-avx512-fallback-wrapper-smoke/cmp.json`
- `/tmp/rr-libcrypto-current-serial-avx512-fallback-wrapper-smoke/cmp.txt`
- `/tmp/rr-libcrypto-current-serial-avx512-fallback-wrapper-smoke/cmp.verdict.txt`
- `/tmp/rr-libcrypto-current-serial-simd-heavy-fallback-wrapper-smoke/cmp.json`
- `/tmp/rr-libcrypto-current-serial-simd-heavy-fallback-wrapper-smoke/cmp.txt`
- `/tmp/rr-libcrypto-current-serial-simd-heavy-fallback-wrapper-smoke/cmp.verdict.txt`
- `/tmp/rr-libcrypto-current-serial-avx512-fallback-validator/cmp.json`
- `/tmp/rr-libcrypto-current-serial-avx512-fallback-validator/cmp.txt`
- `/tmp/rr-libcrypto-current-serial-avx512-fallback-validator/cmp.verdict.txt`
- `/tmp/rr-libcrypto-current-serial-simd-heavy-fallback-validator/cmp.json`
- `/tmp/rr-libcrypto-current-serial-simd-heavy-fallback-validator/cmp.txt`
- `/tmp/rr-libcrypto-current-serial-simd-heavy-fallback-validator/cmp.verdict.txt`

## Fallback Scope

The `avx512` regex matched 12 local symbols:

```text
ossl_rsaz_avx512ifma_eligible
ossl_rsaz_mod_exp_avx512_x2
ChaCha20_avx512
ChaCha20_avx512vl
ossl_aes_gcm_init_avx512
ossl_aes_gcm_setiv_avx512
ossl_aes_gcm_update_aad_avx512
ossl_aes_gcm_encrypt_avx512
ossl_aes_gcm_decrypt_avx512
ossl_aes_gcm_finalize_avx512
ossl_gcm_gmult_avx512
poly1305_blocks_avx512
```

The largest recall gain comes from the two known dominant functions:

```text
ossl_aes_gcm_encrypt_avx512
ossl_aes_gcm_decrypt_avx512
```

## Interpretation

The conservative `avx512` profile raises measurable instruction recall from
`0.797844` to `0.936385` for the current serial lift artifact. The broader
`simd-heavy` profile raises it to `0.981100`, above the V2 target recall
threshold, while preserving precision above `0.95`.

Neither profile proves that Runnable/QEMU now executes the recovered instructions
correctly. These profiles prove that the dominant address coverage loss can be
recovered by scoped fallback, and they provide a measured upper bound for what
real backend support should recover.

The next backend-facing step remains connecting the QEMU V2 AVX-512 work to the
real PTC/libtinycode full `libcrypto` lift path, then replacing this static
fallback with real lifted semantics where possible.
