# QEMU V2 AVX-512 CPUID/XCR0 Gating

Date: 2026-06-23
Branch: `codex/qemu-upgrade-v2`
Target: QEMU `10.2.3` `x86_64-linux-user` TCG
Harness: `runnable/scripts/qemu_v2_avx512_feature_probe.sh`

## Summary

QEMU `10.2.3` linux-user TCG does not expose the AVX-512 foundation bit
(`CPUID.7.0.EBX[16] avx512f`), does not expose
`CPUID.7.0.ECX[10] vpclmulqdq`, and does not expose the AVX-512 `XCR0` state
bits `5/6/7` under either `-cpu max` or `-cpu SapphireRapids`. It does expose
`VAES` (`CPUID.7.0.ECX[9]`), so the relevant mask-out is selective rather than
"all new vector features are off".

The new probe harness also ran an optional throwaway `/tmp` patch experiment
that only changed TCG-advertised feature masks. That patch made `AVX512F`,
`VPCLMULQDQ`, and `XCR0` bits `5/6/7` visible to the guest, but a minimal EVEX
microprobe (`vpxorq zmm0,zmm0,zmm0`) still failed with target `SIGILL` and the
same `0x62` legacy-decode trace.

Conclusion:

1. Overall primary gate today: missing EVEX decode/translation, not CPUID/XCR0.
2. After EVEX decode exists, the primary feature gate is the TCG CPUID support
   mask.
3. `XCR0` is a secondary/derived gate in this code path, because QEMU enables
   AVX-512 `XCR0` bits from the same feature-word machinery that decides whether
   `AVX512F` is exposed.

## Script

The harness accepts a `qemu-x86_64` binary, a build dir, or a source tree:

```bash
bash runnable/scripts/qemu_v2_avx512_feature_probe.sh \
  --qemu-x86_64 /tmp/rr-qemu-v2-upstream-probes/build-10.2.3/qemu-x86_64 \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  --out-dir /tmp/rr-qemu-v2-avx512-feature-probe-test \
  --with-qemu-log \
  --run-min-feature-patch \
  --venv /tmp/rr-qemu-v2-upstream-probes/venv
```

What it records:

- `qemu-x86_64 --version`
- `qemu-x86_64 -cpu help`
- Guest `cpuid`/`xgetbv` output under:
  - default CPU
  - `-cpu max`
  - `-cpu SapphireRapids`
  - `-cpu max,+avx512f,+vpclmulqdq,+vaes,check=off`
- A minimal EVEX `vpxorq` microprobe under default, `max`, and
  `SapphireRapids`
- Optional `QEMU_LOG` traces with `-d in_asm,op,int,cpu`
- Optional `/tmp` feature-mask patch/build that exposes the minimum advertised
  bits without attempting EVEX semantics

The tested run wrote its machine-readable summary to:

`/tmp/rr-qemu-v2-avx512-feature-probe-test/summary.md`

## Baseline Result

Observed guest feature-state values from the harness:

| CPU selection | CPUID.7.0.EBX | CPUID.7.0.ECX | XCR0 | AVX512F | VAES | VPCLMULQDQ | AVX-512 XCR0 state |
|---|---|---|---|---|---|---|---|
| default | `219c47a9` | `8041020c` | `0x021f` | no | yes | no | no |
| `-cpu max` | `219c47a9` | `8041020c` | `0x021f` | no | yes | no | no |
| `-cpu SapphireRapids` | `219c07a9` | `0041020c` | `0x0207` | no | yes | no | no |
| `-cpu max,+avx512f,+vpclmulqdq,+vaes,check=off` | `219c47a9` | `8041020c` | `0x021f` | no | yes | no | no |

Interpretation:

- `VAES` is already exposed by upstream TCG.
- `AVX512F` is not exposed even when explicitly requested with `check=off`.
- `VPCLMULQDQ` is also masked out even when explicitly requested.
- `XCR0` lacks bits `5` opmask, `6` ZMM_Hi256, and `7` Hi16_ZMM, so AVX-512
  architectural state is not guest-visible.

`-cpu SapphireRapids` emitted warnings such as:

```text
qemu-x86_64: warning: TCG doesn't support requested feature: CPUID[eax=07h,ecx=00h].EBX.avx512f [bit 16]
qemu-x86_64: warning: TCG doesn't support requested feature: CPUID[eax=07h,ecx=00h].ECX.vpclmulqdq [bit 10]
```

## Source-Side Cause

The source scan done by the harness lines up with the runtime result.

TCG supported-feature masks in
`/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3/target/i386/cpu.c`:

- `cpu.c:996-1014`
  - `TCG_7_0_EBX_FEATURES` includes `AVX2`, but not `AVX512F`
  - `TCG_7_0_ECX_FEATURES` includes `VAES`, but not `VPCLMULQDQ`
- `cpu.c:1512-1527`
  - `FEAT_XSAVE_XCR0_LO.tcg_features` includes FP/SSE/YMM/MPX/PKRU, but not
    `XSTATE_OPMASK`, `XSTATE_ZMM_Hi256`, or `XSTATE_Hi16_ZMM`
- `cpu.c:2040-2046`
  - QEMU does have xsave descriptors for opmask and ZMM state, keyed on
    `AVX512F`
- `cpu.c:8860-8890`
  - `x86_cpu_enable_xsave_components()` derives the guest-visible `XCR0` mask
    from `cpuid_has_xsave_feature()`

That means the baseline XCR0 result is not an independent mystery. If the CPU
feature words do not expose `AVX512F`, the AVX-512 xsave components are not
enabled either.

## Optional `/tmp` Patch Experiment

The harness can copy the QEMU source under `/tmp`, patch only
`target/i386/cpu.c`, build a fresh `qemu-x86_64`, and rerun the same probes.

Patch intent:

- Add `CPUID_7_0_EBX_AVX512F` to `TCG_7_0_EBX_FEATURES`
- Add `CPUID_7_0_ECX_VPCLMULQDQ` to `TCG_7_0_ECX_FEATURES`
- Add `XSTATE_OPMASK_MASK`, `XSTATE_ZMM_Hi256_MASK`, and
  `XSTATE_Hi16_ZMM_MASK` to `FEAT_XSAVE_XCR0_LO.tcg_features`

Observed result from the patched build:

| CPU selection | CPUID.7.0.EBX | CPUID.7.0.ECX | XCR0 | AVX512F | VAES | VPCLMULQDQ | AVX-512 XCR0 state |
|---|---|---|---|---|---|---|---|
| default | `219d47a9` | `8041060c` | `0x02ff` | yes | yes | yes | yes |
| `-cpu max` | `219d47a9` | `8041060c` | `0x02ff` | yes | yes | yes | yes |
| `-cpu SapphireRapids` | `219d07a9` | `0041060c` | `0x02e7` | yes | yes | yes | yes |

This is the decisive feature-state result:

- A small mask-only patch is enough to expose `AVX512F`, `VPCLMULQDQ`, and the
  corresponding `XCR0` bits.
- The baseline lack of AVX-512 `XCR0` state is therefore secondary to the
  feature-mask decision.

## EVEX Result

The same harness also runs a minimal EVEX microprobe:

```text
62 f1 fd 48 ef c0    vpxorq zmm0,zmm0,zmm0
```

That microprobe failed in both baseline and patched builds:

| Build | `-cpu max` result |
|---|---|
| baseline | `SIGILL`, shell rc `132` |
| min-feature patch | `SIGILL`, shell rc `132` |

The `QEMU_LOG` traces were identical at the trap point. Representative lines:

```text
IN:
0x00401000:
OBJD-T: 62f1
...
mov_i64 rip,$0x401000
call raise_exception,$0xa,$0,env,$0x6
...
check_exception old: 0xffffffff new 0x6
```

And the source scan still shows only VEX prefix handling plus legacy `0x62`
decode entries:

- `decode-new.c.inc:1640`
  - `[0x62] = X86_OP_ENTRYrr(BOUND, G,v, M,a, chk(i64)),`
- `decode-new.c.inc:2617-2673`
  - VEX prefix handling for `0xc5` and `0xc4`
  - no SIMD EVEX prefix path

So even after the feature-state patch, QEMU still treats the EVEX prefix byte
`0x62` as legacy `BOUND` and raises `#UD`.

## Gating Conclusion

Primary vs secondary gates:

1. Primary gate today: EVEX decode/translation. This fires first and makes the
   current guest trap before any AVX-512 semantic execution happens.
2. Primary gate after EVEX decode exists: CPUID support masks in
   `TCG_7_0_EBX_FEATURES` and `TCG_7_0_ECX_FEATURES`.
3. Secondary gate after EVEX decode: `XCR0` AVX-512 state exposure, because in
   linux-user TCG it is derived from the same feature-word/xsave-component logic
   rather than being independently enabled.

Practically, the next enablement step is still an EVEX decode/translation spike.
But once that exists, the project will also need the AVX-512 CPUID/XCR0 mask
changes proved by the optional `/tmp` patch experiment.
