# 2026-05-10 libcrypto canonical eval contract

## Goal

修复 `SYM-20` 里 `libcrypto` 的评估口径错配，把当前 repo-local authoritative contract、历史 non-canonical 路径、以及本工作区可直接验证的结果拆开记录清楚。

## Inputs

- Canonical binary:
  - `archives/groundtruth/libcrypto_groudtruth_20260428/libcrypto.so.3`
- Canonical GT:
  - `archives/groundtruth/libcrypto_groudtruth_20260428/libcrypto.gtBlock.pb`
- Historical old-binary baseline:
  - `archives/experiments/libcrypto_master_test_20260414/libcrypto.so.3`
  - `runs/validate-libcrypto-llm-agent-current/baseline/cmp.repaired.json`
  - `runs/validate-libcrypto-llm-agent-current/baseline/summary.json`
- Historical SYM-19 note:
  - `/hdd/code/runnable/SYM-19/docs/exp/2026-05-02-sym-19-libcrypto-eval.md`
- Canonical new-GT serial run:
  - `runs/runnable-dev-2026-0429-newgt-serial/libcrypto.so.3`
  - `runs/runnable-dev-2026-0429-newgt-serial/libcrypto.so.3.entry_0x500cf000.ll`

## Environment

- Workspace root: `/home/iskindar/Project/runnable`
- Canonical path resolver:
  - `scripts/libcrypto_bench_paths.py`
- Canonical GT audit / compare wrapper:
  - `scripts/validate_libcrypto_ground_truth.py`
- Fresh compare wrapper:
  - `.codex/skills/runnable-cmp-eval/scripts/run_cmp_eval.py`

## Commands

Resolve canonical assets:

```bash
python3 scripts/libcrypto_bench_paths.py binary --must-exist
python3 scripts/libcrypto_bench_paths.py groundtruth-pb --must-exist
```

Gap-audit canonical GT coverage:

```bash
python3 scripts/validate_libcrypto_ground_truth.py gap-audit \
  --out-dir runs/groundtruth_validation/canonical_gap_audit
```

Show that the old baseline `.ll` is not comparable to canonical GT:

```bash
python3 scripts/validate_libcrypto_ground_truth.py cmp \
  --ll runs/validate-libcrypto-llm-agent-current/docker_exec/baseline/libcrypto.so.3.entry_0x500cf000.ll \
  --out-dir runs/groundtruth_validation/canonical_baseline_cmp \
  --examples 10
```

Re-run a comparable canonical baseline using the repo-local `newgt-serial` artifact:

```bash
python3 scripts/validate_libcrypto_ground_truth.py cmp \
  --binary runs/runnable-dev-2026-0429-newgt-serial/libcrypto.so.3 \
  --groundtruth archives/groundtruth/libcrypto_groudtruth_20260428/libcrypto.gtBlock.pb \
  --ll runs/runnable-dev-2026-0429-newgt-serial/libcrypto.so.3.entry_0x500cf000.ll \
  --out-dir runs/groundtruth_validation/newgt_serial_cmp \
  --examples 10
```

Binary identity checks:

```bash
sha256sum \
  /hdd/code/runnable/SYM-19/test/openssl_data/libcrypto.so.3 \
  archives/experiments/libcrypto_master_test_20260414/libcrypto.so.3 \
  archives/groundtruth/libcrypto_groudtruth_20260428/libcrypto.so.3

readelf -WS archives/experiments/libcrypto_master_test_20260414/libcrypto.so.3
readelf -WS archives/groundtruth/libcrypto_groudtruth_20260428/libcrypto.so.3
```

## Artifacts

- Canonical GT gap audit:
  - `runs/groundtruth_validation/canonical_gap_audit/gap.summary.json`
  - `runs/groundtruth_validation/canonical_gap_audit/gap.summary.txt`
- Canonical compare against old baseline `.ll`:
  - `runs/groundtruth_validation/canonical_baseline_cmp/cmp.json`
  - `runs/groundtruth_validation/canonical_baseline_cmp/cmp.verdict.txt`
- Canonical comparable serial baseline:
  - `runs/groundtruth_validation/newgt_serial_cmp/cmp.json`
  - `runs/groundtruth_validation/newgt_serial_cmp/cmp.txt`
  - `runs/groundtruth_validation/newgt_serial_cmp/cmp.verdict.txt`
- Canonical textstart baseline:
  - `runs/groundtruth_validation/textstart_serial_cmp/cmp.json`
  - `runs/groundtruth_validation/textstart_serial_cmp/cmp.txt`
  - `runs/groundtruth_validation/textstart_serial_cmp/cmp.verdict.txt`
- Canonical textstart optimized:
  - `runs/groundtruth_validation/textstart_dynamic_cmp/cmp.json`
  - `runs/groundtruth_validation/textstart_dynamic_cmp/cmp.verdict.txt`
- Historical old-binary baseline:
  - `runs/validate-libcrypto-llm-agent-current/baseline/cmp.repaired.json`
  - `runs/validate-libcrypto-llm-agent-current/baseline/summary.json`

## Results

### Canonical authoritative contract

- Binary:
  - `archives/groundtruth/libcrypto_groudtruth_20260428/libcrypto.so.3`
  - sha256 `2d4faaa94bb53b5f92a7d8d0b581eea1ad0446c30f34a8ddf4baef713f744d04`
- GT:
  - `archives/groundtruth/libcrypto_groudtruth_20260428/libcrypto.gtBlock.pb`
- Address mapping:
  - ELF `.text` start: `0xcef80`
  - Runnable base: `0x50000000`
- Compare path:
  - fresh `runnable-cmp-eval`
  - do not use cached `.result`
  - do not use `coverage_sidecar_union_threadpool16` as final authority

### Canonical GT coverage caveat

`gap-audit` shows the current `gtBlock.pb` bundle is not a byte-for-byte mirror of `objdump -d -j .text`:

- `objdump_real_instruction_count=707311`
- `groundtruth_instruction_count=670703`
- `unseen_instruction_count=36610`
- `unseen_ratio_over_groundtruth=0.05458451803555374`
- `instruction_category_counts.outside_gt_coverage=35257`
- `instruction_category_counts.padding=1353`

This caveat must be reported with canonical results instead of assuming GT and objdump are identical.

### Why the SYM-19 `recall=0.445502995810004` result is not directly comparable

`SYM-19` used a different binary, different GT representation, different address contract, and different evaluator:

1. Binary generation mismatch:
   - `/hdd/code/runnable/SYM-19/test/openssl_data/libcrypto.so.3`
   - `archives/experiments/libcrypto_master_test_20260414/libcrypto.so.3`
   - both share sha256 `932923d4498c83f75c60a7a02404267297df9f7a2844ed6f3f8d154041b558db`
   - canonical `2026-04-28` binary has sha256 `2d4faaa94bb53b5f92a7d8d0b581eea1ad0446c30f34a8ddf4baef713f744d04`
2. `.text` layout mismatch:
   - old binary `.text` starts at `0xcf000`
   - canonical binary `.text` starts at `0xcef80`
3. GT representation mismatch:
   - `SYM-19`: CSV GT bundle under `out/sym-19/gt/ground_truth.csv`
   - canonical: `gtBlock.pb`
4. Evaluator mismatch:
   - `SYM-19`: `coverage_sidecar_union_threadpool16`
   - canonical: fresh `runnable-cmp-eval`
5. Address-domain mismatch:
   - `SYM-19`: `rebase_base=0x50400000`
   - canonical compare: `runnable_base=0x50000000`

So `SYM-19`’s:

- baseline `precision=0.9885320776927604`, `recall=0.445502995810004`
- optimized `precision=0.9885531253892196`, `recall=0.4463316579715496`

must be labeled `historical sidecar-union / non-canonical`, not compared numerically against canonical `gtBlock.pb` results.

### Historical old-binary baseline under the old contract

From `runs/validate-libcrypto-llm-agent-current/baseline/cmp.repaired.json`:

- binary: old `2026-04-14` binary
- `.text` start: `0xcf000`
- `runnable_base=0x50000000`
- `obj_count=932388`
- `ll_count=847589`
- `HIT=787564`
- `MISMATCH=1414`
- `OBJ_ONLY=143410`
- `LL_ONLY=58611`
- `FALSE_NEGATIVE=144824`
- `FALSE_POSITIVE=60025`
- `precision=0.929181478287236`
- `recall=0.8446741056298451`

This is a valid old-binary compare, but not the `SYM-20` canonical authority.

### Proof that the old baseline `.ll` fails under the canonical contract

Comparing the old baseline `.ll` against canonical `2026-04-28` GT produces a catastrophic mismatch:

- `obj_count=679506`
- `ll_count=847618`
- `HIT=24175`
- `MISMATCH=112631`
- `OBJ_ONLY=542700`
- `LL_ONLY=710812`
- `FALSE_NEGATIVE=655331`
- `FALSE_POSITIVE=823443`
- `precision=0.028521102666531385`
- `recall=0.03557731646225346`

This is the direct proof that “old `.ll` + canonical GT” is not a legitimate comparison target.

### Corrected comparable baseline available in the current workspace

The current workspace does contain one directly comparable canonical baseline artifact:

- binary: `runs/runnable-dev-2026-0429-newgt-serial/libcrypto.so.3`
- ll: `runs/runnable-dev-2026-0429-newgt-serial/libcrypto.so.3.entry_0x500cf000.ll`
- binary sha256 matches canonical `2026-04-28` GT binary

Fresh canonical compare result:

- `obj_count=679506`
- `ll_count=593206`
- `HIT=532849`
- `MISMATCH=1466`
- `OBJ_ONLY=145191`
- `LL_ONLY=58891`
- `FALSE_NEGATIVE=146657`
- `FALSE_POSITIVE=60357`
- `precision=0.8982528834839837`
- `recall=0.7841711478633007`

### Corrected comparable baseline / optimized pair for SYM-20

The current workspace also contains one full corrected pair that satisfies the ticket's comparability rule:

- same canonical binary:
  - `archives/groundtruth/libcrypto_groudtruth_20260428/libcrypto.so.3`
- same canonical GT:
  - `archives/groundtruth/libcrypto_groudtruth_20260428/libcrypto.gtBlock.pb`
- same address mapping:
  - `.text_start=0xcef80`
  - `runnable_base=0x50000000`
- same compare path:
  - fresh `runnable-cmp-eval` through `scripts/validate_libcrypto_ground_truth.py cmp`
- same artifact contract:
  - `cmp.json`
  - `cmp.txt`
  - `cmp.verdict.txt`

Baseline:

- ll: `runs/runnable-dev-2026-0429-textstart-serial/libcrypto.so.3.entry_0x500cef80.ll`
- `obj_count=679506`
- `ll_count=554051`
- `HIT=527641`
- `MISMATCH=1044`
- `OBJ_ONLY=150821`
- `LL_ONLY=25366`
- `FALSE_NEGATIVE=151865`
- `FALSE_POSITIVE=26410`
- `precision=0.9523329079813952`
- `recall=0.7765067563788988`

Optimized:

- ll: `runs/runnable-dev-2026-0501-textstart-dynamic-reapfix/libcrypto.so.3.entry_0x500cef80.dynamic.ll`
- `obj_count=679506`
- `ll_count=569562`
- `HIT=529848`
- `MISMATCH=1217`
- `OBJ_ONLY=148441`
- `LL_ONLY=38497`
- `FALSE_NEGATIVE=149658`
- `FALSE_POSITIVE=39714`
- `precision=0.9302727358917905`
- `recall=0.7797547041527227`

Delta (`optimized - baseline`):

- `HIT=+2207`
- `MISMATCH=+173`
- `OBJ_ONLY=-2380`
- `LL_ONLY=+13131`
- `FALSE_NEGATIVE=-2207`
- `FALSE_POSITIVE=+13304`
- `precision=-0.022060172089604757`
- `recall=+0.003247947773823978`

Verdict under the corrected canonical contract:

- recall `improved`
- precision `regressed`
- overall verdict: `mixed`, not a clean improvement

### Remaining evidence gap

I still could not find the raw artifact behind the older historical claim:

- accepted baseline `precision=0.960596`, `recall=0.845340`
- historical llm `precision=0.966030`, `recall=0.841228`

The historical “accepted baseline `0.960596 / 0.845340` and llm `0.966030 / 0.841228`” numbers currently appear in OpenSpec design text, but no raw compare artifact for them was found in this workspace or the scanned `/hdd/code/runnable/SYM-20` tree.

So the truthful current state is:

- canonical comparable baseline: reproduced
- canonical comparable optimized: reproduced
- corrected comparable verdict: reproduced
- historical non-canonical sidecar-union metrics: explained and fenced off
- older accepted 0.960596 / 0.845340 claim: still lacks raw artifact provenance in the current workspace

## Conclusion

`SYM-20`’s main bug is now explicit:

- historical `SYM-19` numbers were reported from a different binary generation and a different evaluator contract
- current repo scripts also carried forward a stale `0xcf000` default that belongs to the old binary generation, not the canonical `2026-04-28` GT bundle

The repo-local canonical contract is:

- canonical `2026-04-28` binary
- canonical `gtBlock.pb`
- ELF-derived `.text` start
- `runnable_base=0x50000000`
- fresh `runnable-cmp-eval`

Under that corrected contract, the currently reproducible pair in this workspace is:

- baseline: `precision=0.9523329079813952`, `recall=0.7765067563788988`
- optimized: `precision=0.9302727358917905`, `recall=0.7797547041527227`
- verdict: recall improves slightly, precision regresses materially, so the result is `mixed`

## Next Step

1. If the historical accepted `0.960596 / 0.845340` pair still matters, recover its raw compare artifact or regenerate it under a documented run directory
2. Decide whether the repo should standardize on the `textstart-*` pair above or on a separately recovered accepted baseline lineage
3. Keep future libcrypto claims on the canonical skill + `validate_libcrypto_ground_truth.py cmp` path only
