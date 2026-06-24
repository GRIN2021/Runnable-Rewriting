# QEMU v2 EVEX vbroadcastf64x2 smoke

Status: FAIL - v7 completed after the second exact-byte semantic guard change. `vbroadcastf64x2-single` and `vbroadcastf64x2-chain` passed, `vbroadcastf64x2-semantic` failed with `run_rc=132` and an illegal instruction, and the aggregate boundary still stops at `vpslldq @ 0x401065`.

## Commands

Syntax validation:
```bash
bash -n runnable/scripts/qemu_v2_evex_vbroadcastf64x2_smoke_patch.sh
```

Result: `0`.

Post-edit syntax validation:
```bash
bash -n runnable/scripts/qemu_v2_evex_vbroadcastf64x2_smoke_patch.sh
```

Result: `0` (`bash_n_ok`).

Fresh smoke run:
```bash
RUNNABLE_QEMU_V2_EVEX_VBROADCASTF64X2_SMOKE_ROOT=/tmp/rr-qemu-v2-evex-vbroadcastf64x2-smoke-v4 \
bash runnable/scripts/qemu_v2_evex_vbroadcastf64x2_smoke_patch.sh \
  --scratch-root /tmp/rr-qemu-v2-evex-vbroadcastf64x2-smoke-v4 \
  --fresh \
  --qemu-tarball /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3.tar.xz \
  --jobs 3
```

Result: `FAIL` with exit `1` from the script. The run reached the top-level `vbroadcastf64x2` probe phase and then failed in the `vbroadcastf64x2-semantic` probe plus the aggregate boundary check.

Fresh v7 smoke run:
```bash
RUNNABLE_QEMU_V2_EVEX_VBROADCASTF64X2_SMOKE_ROOT=/tmp/rr-qemu-v2-evex-vbroadcastf64x2-smoke-v7 \
bash runnable/scripts/qemu_v2_evex_vbroadcastf64x2_smoke_patch.sh \
  --scratch-root /tmp/rr-qemu-v2-evex-vbroadcastf64x2-smoke-v7 \
  --fresh \
  --qemu-tarball /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3.tar.xz \
  --jobs 3
```

Result: `FAIL` overall. `vbroadcastf64x2-single` and `vbroadcastf64x2-chain` both `PASS`. `vbroadcastf64x2-semantic` `FAIL`ed with `run_rc=132`, `exception_hits=3`, and an illegal instruction at the semantic probe boundary. The aggregate probe produced the expected post-vbroadcast failure boundary: `EXPECTED_FAIL_AFTER_VBROADCASTF64X2`.

## Diagnosis

The previous nonzero exit was script plumbing, not a vbroadcast semantic/build failure. The exact failing command was the overlay diff generation under `set -e`:

```bash
diff -u \
  --label a/target/i386/tcg/decode-new.c.inc \
  --label b/target/i386/tcg/decode-new.c.inc \
  /tmp/rr-qemu-v2-evex-vbroadcastf64x2-smoke-v2/vaesenclast-base/qemu-10.2.3-evex-vaesenclast-smoke-src/target/i386/tcg/decode-new.c.inc \
  /tmp/rr-qemu-v2-evex-vbroadcastf64x2-smoke-v2/qemu-10.2.3-evex-vbroadcastf64x2.9HLgb4
```

Evidence: `/tmp/rr-vbroadcast-rerun.trace.stderr:78`.

`diff -u` returns `1` when files differ, which is the expected successful patch-generation condition. The script treated that as fatal because of `set -e`, so it exited after writing the overlay patch and before `prepare_patched_tree`, top-level configure/build, or vbroadcast probes.

Fix applied in `runnable/scripts/qemu_v2_evex_vbroadcastf64x2_smoke_patch.sh`: temporarily disable `set -e` around `diff -u`, accept rc `1`, and fail only on other diff return codes.

## Current Evidence

Fresh root: `/tmp/rr-qemu-v2-evex-vbroadcastf64x2-smoke-v7`.

The v7 run progressed through the full carried-forward stack and the vbroadcast top-level probes:
- Carried-forward `vpclmul-hqlq` single/chain/semantic probes passed.
- Carried-forward `vpclmul-hh` single/chain/semantic probes passed.
- Carried-forward `vaesenc` single/chain/semantic probes passed.
- Carried-forward `vaesenclast` single/chain/semantic probes passed.
- Top-level `vbroadcastf64x2` overlay applied cleanly.
- Top-level `vbroadcastf64x2` single and chain probes passed.
- Top-level `vbroadcastf64x2` semantic probe failed with an illegal instruction.
- Aggregate probe stopped at the first unsupported instruction after vbroadcast, `vpslldq zmm13,zmm12,0x4 @ 0x401065`.

Evidence:
- `/tmp/rr-qemu-v2-evex-vbroadcastf64x2-smoke-v7/qemu-10.2.3-evex-vbroadcastf64x2-smoke-src/.rr-evex-vbroadcastf64x2-smoke-patched` exists.
- `/tmp/rr-qemu-v2-evex-vbroadcastf64x2-smoke-v7/build-10.2.3-evex-vbroadcastf64x2-smoke/config.log` exists.

Top-level vbroadcast probe status:
- `vbroadcastf64x2-single`: `PASS` in the fresh `v7` run, `run_rc=0`, `qemu_ld2_i128_hits=1`, `st_i64_hits=8`, `last_rip=40106c`.
- `vbroadcastf64x2-chain`: `PASS` in the fresh `v7` run, `run_rc=0`, `qemu_ld2_i128_hits=5`, `st_i64_hits=16`, `last_rip=40106c`.
- `vbroadcastf64x2-semantic`: `FAIL` in the fresh `v7` run, `run_rc=132`, `exception_hits=3`, `qemu_ld2_i128_hits=1`, `st_i64_hits=8`, `last_rip=401065`.
- Aggregate boundary after vbroadcast: `EXPECTED_FAIL_AFTER_VBROADCASTF64X2` with `aggregate_run_rc=132`.

Refined artifact readback from v7:
- `vbroadcastf64x2-single`: script result `PASS`, `run_rc=0`, `exception_hits=0`, `qemu_ld2_i128_hits=1`, `st_i64_hits=8`, `last_rip=40106c`.
- `vbroadcastf64x2-chain`: script result `PASS`, `run_rc=0`, `exception_hits=0`, `qemu_ld2_i128_hits=5`, `st_i64_hits=16`, `last_rip=40106c`.
- `vbroadcastf64x2-semantic`: script result `FAIL`, `run_rc=132`, `exception_hits=3`, `qemu_ld2_i128_hits=1`, `st_i64_hits=8`, `last_rip=401065`.
- `aggregate`: script result `EXPECTED_FAIL_AFTER_VBROADCASTF64X2`, `aggregate_run_rc=132`, `exception_hits=3`, `qemu_ld2_i128_hits=5`, `st_i64_hits=16`, `last_rip=401065`.

Interpretation:
- The v7 single/chain `PASS`es confirm the second exact-byte semantic guard fixed the probe expectations for both direct and chained vbroadcast cases.
- The v7 semantic `FAIL` is now a real execution boundary: the probe trips `Illegal instruction` at the semantic path and stops at `401065`.
- The v7 aggregate boundary is still the expected post-vbroadcast next instruction, `vpslldq zmm13,zmm12,0x4 @ 0x401065`.

Attempted v5 rerun:
```bash
RUNNABLE_QEMU_V2_EVEX_VBROADCASTF64X2_SMOKE_ROOT=/tmp/rr-qemu-v2-evex-vbroadcastf64x2-smoke-v5 \
bash runnable/scripts/qemu_v2_evex_vbroadcastf64x2_smoke_patch.sh \
  --scratch-root /tmp/rr-qemu-v2-evex-vbroadcastf64x2-smoke-v5 \
  --fresh \
  --qemu-tarball /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3.tar.xz \
  --jobs 3
```

Result: incomplete/stopped before top-level vbroadcast validation. Existing v5 artifacts only cover carried-forward layers through `vaesenc`; `find /tmp/rr-qemu-v2-evex-vbroadcastf64x2-smoke-v5 -maxdepth 3 ... vbroadcastf64x2/aggregate ...` returned `0` top-level vbroadcast/aggregate artifacts. No v5 single/chain/semantic/aggregate PASS/FAIL result is validated.

Failure artifacts:
- `/tmp/rr-qemu-v2-evex-vbroadcastf64x2-smoke-v4/out/vbroadcastf64x2-single.qemu.log`
- `/tmp/rr-qemu-v2-evex-vbroadcastf64x2-smoke-v4/out/vbroadcastf64x2-chain.qemu.log`
- `/tmp/rr-qemu-v2-evex-vbroadcastf64x2-smoke-v4/out/vbroadcastf64x2-semantic.qemu.log`
- `/tmp/rr-qemu-v2-evex-vbroadcastf64x2-smoke-v4/out/aggregate.qemu.log`

Aggregate boundary evidence:
- `aggregate_result: FAIL_BEFORE_OR_AT_VBROADCASTF64X2`
- `aggregate_fail_pc: 401065`
- `aggregate_next: 401065: 62 d1 15 48 73 fc 04 vpslldq zmm13,zmm12,0x4`
- `aggregate_aesenc_helper_hits: 4`
- `aggregate_aesenclast_helper_hits: 4`
- `aggregate_pclmul_helper_hits: 16`
- `aggregate_exception_hits: 3`
