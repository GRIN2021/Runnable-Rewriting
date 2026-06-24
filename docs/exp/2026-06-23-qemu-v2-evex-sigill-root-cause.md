# QEMU V2 EVEX SIGILL Root Cause

Date: 2026-06-23
Branch: `codex/qemu-upgrade-v2`
Scratch root: `/tmp/rr-qemu-v2-upstream-probes`
Starting point: `docs/exp/2026-06-23-qemu-v2-upstream-baseline-probe.md`

## Summary

Upstream QEMU `10.2.3` and `11.0.1` linux-user TCG fail the existing
`avx512-evex` probe because x86 TCG does not implement the SIMD EVEX decode
path. The probe's first instruction is:

```text
401000: 62 f1 fd 48 ef c0     vpxorq zmm0,zmm0,zmm0
```

Both QEMU builds treat the leading byte `0x62` as the legacy `BOUND` opcode,
not as an EVEX prefix. In 64-bit mode QEMU's decoder marks `BOUND` illegal via
`chk(i64)`, so translation emits `EXCP06_ILLOP`, delivered by linux-user as
target `SIGILL`.

There are two independent upstream blockers:

1. Immediate SIGILL cause: no SIMD EVEX-prefix decode/translation path in x86
   TCG, so the first EVEX instruction is rejected before AVX-512 semantics are
   reached.
2. Feature/state exposure: TCG-supported CPUID masks also omit AVX-512 and
   `vpclmulqdq`, and linux-user does not expose AVX-512 `XCR0` bits for these
   CPU selections.

The failure is therefore not a PTC integration issue and not caused by the
probe's later memory operations. It is an upstream linux-user/TCG capability
gap.

## Commands Run

Reused existing `/tmp` source/build outputs from the baseline probe:

```bash
/tmp/rr-qemu-v2-upstream-probes/build-10.2.3/qemu-x86_64 --version
/tmp/rr-qemu-v2-upstream-probes/build-11.0.1/qemu-x86_64 --version
```

Probe execution through the existing harness:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting

python3 runnable/scripts/qemu_v2_probe_suite.py \
  --build-dir /tmp/rr-qemu-v2-upstream-probes/probes-build \
  --probe avx512-evex \
  --qemu-x86_64 /tmp/rr-qemu-v2-upstream-probes/build-10.2.3/qemu-x86_64

python3 runnable/scripts/qemu_v2_probe_suite.py \
  --build-dir /tmp/rr-qemu-v2-upstream-probes/probes-build \
  --probe avx512-evex \
  --qemu-x86_64 /tmp/rr-qemu-v2-upstream-probes/build-11.0.1/qemu-x86_64
```

Observed for both:

```text
qemu: uncaught target signal 4 (Illegal instruction) - core dumped
QEMU execution failed for /tmp/rr-qemu-v2-upstream-probes/probes-build/avx512-evex: rc=-4
```

First-instruction disassembly:

```bash
objdump -d -Mintel /tmp/rr-qemu-v2-upstream-probes/probes-build/avx512-evex | sed -n '1,120p'
objdump -d -Mintel /tmp/rr-qemu-v2-upstream-probes/micro-probes/vpxorq | sed -n '1,80p'
```

Micro-probe trace:

```bash
QEMU_LOG_FILENAME=/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3-vpxorq.log \
  /tmp/rr-qemu-v2-upstream-probes/build-10.2.3/qemu-x86_64 \
  -d in_asm,op,int,cpu \
  /tmp/rr-qemu-v2-upstream-probes/micro-probes/vpxorq

QEMU_LOG_FILENAME=/tmp/rr-qemu-v2-upstream-probes/qemu-11.0.1-vpxorq.log \
  /tmp/rr-qemu-v2-upstream-probes/build-11.0.1/qemu-x86_64 \
  -d in_asm,op,int,cpu \
  /tmp/rr-qemu-v2-upstream-probes/micro-probes/vpxorq
```

Representative trace, both versions:

```text
IN:
0x00401000:
OBJD-T: 62f1

OP:
...
mov_i64 rip,$0x401000
call raise_exception,$0xa,$0,env,$0x6
...
RIP=0000000000401000
check_exception old: 0xffffffff new 0x6
```

The shell return code was `132` for the direct micro-probe runs.

Feature-state probe compiled under `/tmp`:

```bash
mkdir -p /tmp/rr-qemu-v2-upstream-probes/feature-probes
gcc -O2 -Wall -Wextra \
  -o /tmp/rr-qemu-v2-upstream-probes/feature-probes/cpuid_xgetbv \
  /tmp/rr-qemu-v2-upstream-probes/feature-probes/cpuid_xgetbv.c

/tmp/rr-qemu-v2-upstream-probes/build-10.2.3/qemu-x86_64 \
  /tmp/rr-qemu-v2-upstream-probes/feature-probes/cpuid_xgetbv

QEMU_CPU=SapphireRapids \
  /tmp/rr-qemu-v2-upstream-probes/build-10.2.3/qemu-x86_64 \
  /tmp/rr-qemu-v2-upstream-probes/feature-probes/cpuid_xgetbv

/tmp/rr-qemu-v2-upstream-probes/build-11.0.1/qemu-x86_64 \
  -cpu max,+avx512f,+avx512dq,+avx512bw,+avx512vl,+vpclmulqdq,check=off \
  /tmp/rr-qemu-v2-upstream-probes/feature-probes/cpuid_xgetbv
```

Representative output:

```text
# 10.2.3 default/max
cpuid.7.0: eax=00000001 ebx=219c47a9 ecx=8041020c edx=84000010
xcr0=000000000000021f

# 10.2.3/11.0.1 SapphireRapids
qemu-x86_64: warning: TCG doesn't support requested feature: ... EBX.avx512f [bit 16]
qemu-x86_64: warning: TCG doesn't support requested feature: ... EBX.avx512dq [bit 17]
qemu-x86_64: warning: TCG doesn't support requested feature: ... EBX.avx512bw [bit 30]
qemu-x86_64: warning: TCG doesn't support requested feature: ... EBX.avx512vl [bit 31]
qemu-x86_64: warning: TCG doesn't support requested feature: ... ECX.vpclmulqdq [bit 10]
cpuid.7.0: eax=00000001 ebx=219c07a9 ecx=0041020c edx=a4000010
xcr0=0000000000000207
```

The relevant AVX-512 bits are absent in the observed guest CPUID values:
`EBX[16] avx512f`, `EBX[17] avx512dq`, `EBX[30] avx512bw`,
`EBX[31] avx512vl`, and `ECX[10] vpclmulqdq`. `XCR0` also lacks the AVX-512
state bits `5` opmask, `6` ZMM_Hi256, and `7` Hi16_ZMM.

## Source Files Inspected

TCG-supported CPUID masks:

```text
/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3/target/i386/cpu.c:996-1014
/tmp/rr-qemu-v2-upstream-probes/qemu-11.0.1/target/i386/cpu.c:973-991
```

Both versions include `AVX2` in `TCG_7_0_EBX_FEATURES` and `VAES` in
`TCG_7_0_ECX_FEATURES`, but omit the AVX-512 EBX bits and
`CPUID_7_0_ECX_VPCLMULQDQ`.

EVEX prefix handling:

```text
/tmp/rr-qemu-v2-upstream-probes/qemu-11.0.1/target/i386/tcg/decode-new.c.inc:2859-2917
```

The TCG decoder handles `0xc5` and `0xc4` as 2-byte and 3-byte VEX prefixes.
There is no equivalent SIMD EVEX prefix case for `0x62`.

Legacy `0x62` decode:

```text
/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3/target/i386/tcg/decode-new.c.inc:1638-1640
/tmp/rr-qemu-v2-upstream-probes/qemu-11.0.1/target/i386/tcg/decode-new.c.inc:1757-1759
```

Both map opcode `[0x62]` to `BOUND` with `chk(i64)`, making it illegal in
64-bit mode.

Illegal-instruction emission:

```text
/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3/target/i386/tcg/translate.c:1562-1567
/tmp/rr-qemu-v2-upstream-probes/qemu-11.0.1/target/i386/tcg/translate.c:1522-1527
```

`gen_illegal_opcode()` emits `EXCP06_ILLOP`, matching the trace's
`raise_exception(..., 0x6)`.

AVX-512 state structures and xsave wiring:

```text
/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3/target/i386/tcg/tcg-cpu.c:193-205
/tmp/rr-qemu-v2-upstream-probes/qemu-11.0.1/target/i386/tcg/tcg-cpu.c:193-205
/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3/target/i386/cpu.c:2040-2048
/tmp/rr-qemu-v2-upstream-probes/qemu-11.0.1/target/i386/cpu.c:2103-2123
```

QEMU has xsave layout entries for opmask and ZMM state, keyed on
`AVX512F`, but the TCG CPUID mask prevents those bits from being exposed for the
tested CPU configurations.

Linux-user `XCR0` initialization:

```text
/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3/target/i386/cpu.c:8724-8748
/tmp/rr-qemu-v2-upstream-probes/qemu-11.0.1/target/i386/cpu.c:9312-9336
```

In user-only mode QEMU enables xsave components based on guest feature bits.
Because AVX-512 bits are masked out, AVX-512 `XCR0` bits are not enabled.

Searches used:

```bash
rg -n "TCG_7_0_EBX_FEATURES|TCG_7_0_ECX_FEATURES|TCG_XSAVE_FEATURES|avx512|vpclmul|vaes|opmask|zmm|xsave" \
  /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3/target/i386 \
  /tmp/rr-qemu-v2-upstream-probes/qemu-11.0.1/target/i386

rg -n "PREFIX_EVEX|EVEX|evex|case 0x62|\\[0x62\\]" \
  /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3/target/i386/tcg \
  /tmp/rr-qemu-v2-upstream-probes/qemu-11.0.1/target/i386/tcg
```

The second search found VEX prefix handling and legacy `0x62` opcode entries,
but no SIMD EVEX prefix parser in TCG.

## Hypotheses Tested

| Hypothesis | Result | Evidence |
|---|---|---|
| CPUID feature gating alone causes the failure | Partly true, not the immediate trap | TCG masks out AVX-512 and `vpclmulqdq`; explicit AVX-512 CPU models warn that TCG does not support those features. However the trace shows failure before an AVX-512 feature predicate can accept any EVEX instruction. |
| Unsupported EVEX decoder/opcode causes the failure | True and immediate | First byte `0x62` is decoded as legacy `BOUND` with `chk(i64)`, not as EVEX; QEMU emits `EXCP06_ILLOP` at `RIP=0x401000`. |
| Missing xsave/ZMM state structures cause the failure | Not the primary cause | TCG has xsave offsets and state structs for opmask/ZMM, but they are not exposed because AVX-512 feature bits are masked. Even if exposed, the current decoder would still need EVEX support. |
| Probe fails on a later unsupported instruction family such as VAES or VPCLMUL | False for this probe | The full probe and `vpxorq` micro-probe both trap at the first EVEX instruction. Later opcodes are not reached. |
| This is specific to QEMU `10.2.3` | False | `10.2.3` and `11.0.1` show the same TCG mask pattern, same legacy `0x62` decode, and same `#UD` trace. |

## Recommendation

Do not treat upstream QEMU `10.2.3` or `11.0.1` linux-user TCG as an
AVX-512/EVEX-capable V2 backend baseline.

The smallest useful enablement spike is not PTC plumbing. It is a focused
upstream-TCG EVEX smoke test:

1. Add a minimal TCG EVEX-prefix decoder path for `0x62` that recognizes one
   instruction: `vpxorq zmm0,zmm0,zmm0`.
2. Temporarily expose the minimum guest feature/state set for that instruction:
   `AVX`, `OSXSAVE`, `AVX512F`, and `XCR0` bits `1`, `2`, `5`, `6`, `7`.
3. Implement or stub a correct zeroing semantic for that single ZMM register
   operation.
4. Re-run `/tmp/rr-qemu-v2-upstream-probes/micro-probes/vpxorq` under
   linux-user TCG and require it to exit `0`.
5. Only after that succeeds, expand to the existing `avx512-evex` probe
   families: ZMM moves, `vpshufb`, `vpternlogq`, `vpclmulqdq`, `vaesenc`, lane
   extract, and byte/quadword stores.

For project planning, QEMU `10.2.3` remains the better source baseline if the
modern QEMU port proceeds, because `11.0.1` does not improve the decisive EVEX
result. Keep `11.0.1` as a reference/diff target unless later upstream EVEX TCG
work lands there first.
