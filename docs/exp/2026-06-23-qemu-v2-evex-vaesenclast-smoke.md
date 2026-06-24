# QEMU V2 EVEX VAESENCLAST Smoke Patch

Date: 2026-06-23
Branch: `codex/qemu-upgrade-v2`
Script: `runnable/scripts/qemu_v2_evex_vaesenclast_smoke_patch.sh`
Fresh scratch root: `/tmp/rr-qemu-v2-evex-vaesenclast-smoke-final`

## Summary

This experiment adds the next exact-byte QEMU `10.2.3` EVEX smoke case:

```text
62 72 2d 48 dd df    vaesenclast zmm11,zmm10,zmm7
```

Validation result: **PASS** for the generated single-instruction probe, short
aggregate-prefix chain, and low-128-bit semantic probe under patched
`qemu-x86_64`.

The aggregate probe now advances past `vaesenclast` at `401055` and fails at
the next unimplemented EVEX instruction:

```text
40105b: 62 72 fd 48 1a 25 9b 0f 00 00    vbroadcastf64x2 zmm12,XMMWORD PTR [rip+0xf9b]
```

## Patch Shape

The script keeps all QEMU source, build, patch, and probe outputs under `/tmp`.
It first prepares the existing VAESENC smoke tree as the carried-forward
aggregate prefix, then copies that throwaway source tree and applies a small
overlay to:

```text
target/i386/tcg/decode-new.c.inc
```

The overlay adds one exact-byte match for:

```text
62 72 2d 48 dd df    vaesenclast zmm11,zmm10,zmm7
```

The carried-forward path still covers the earlier aggregate prefix:

```text
62 f1 fd 48 ef c0       vpxorq zmm0,zmm0,zmm0
62 f1 fd 48 6f c8       vmovdqa64 zmm1,zmm0
62 f1 fe 48 7f 0d ...   vmovdqu64 zmmword ptr [rip+...],zmm1
62 f1 fe 48 6f 15 ...   vmovdqu64 zmm2,zmmword ptr [rip+...]
62 f2 6d 48 00 da       vpshufb zmm3,zmm2,zmm2
62 f1 65 48 fe e2       vpaddd zmm4,zmm3,zmm2
62 f3 dd 48 25 eb 96    vpternlogq zmm5,zmm4,zmm3,0x96
62 f3 55 48 44 f4 00    vpclmullqlqdq zmm6,zmm5,zmm4
62 f3 55 48 44 fc 10    vpclmullqhqdq zmm7,zmm5,zmm4
62 73 55 48 44 c4 01    vpclmulhqlqdq zmm8,zmm5,zmm4
62 73 55 48 44 cc 11    vpclmulhqhqdq zmm9,zmm5,zmm4
62 52 35 48 dc d0       vaesenc zmm10,zmm9,zmm8
62 72 2d 48 dd df       vaesenclast zmm11,zmm10,zmm7
```

## Operand Semantics

For:

```text
vaesenclast zmm11,zmm10,zmm7
```

the smoke patch implements AESENCLAST independently for each 128-bit lane:

```text
zmm11.lane[i] = AESENCLAST(zmm10.lane[i], zmm7.lane[i]), i = 0..3
```

The implementation reuses QEMU's existing `gen_helper_aesenclast_xmm` helper.
It calls the helper four times, once per `ZMM_X(0..3)` lane.

## Validation

Fresh command:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
bash runnable/scripts/qemu_v2_evex_vaesenclast_smoke_patch.sh \
  --fresh \
  --scratch-root /tmp/rr-qemu-v2-evex-vaesenclast-smoke-final \
  --qemu-tarball /tmp/rr-qemu-v2-evex-vpclmul-hqlq-smoke-final/download/qemu-10.2.3.tar.xz \
  --jobs 3
```

Result:

```text
probe:                    vaesenclast-single
result:                   PASS
run_rc:                   0
exception_hits:           0
aesenclast_helper_hits:   4

probe:                    vaesenclast-chain
result:                   PASS
run_rc:                   0
exception_hits:           0
aesenc_helper_hits:       4
aesenclast_helper_hits:   4
pclmul_helper_hits:       16

probe:                    vaesenclast-semantic
result:                   PASS
run_rc:                   0
exception_hits:           0
aesenclast_helper_hits:   4

aggregate_result:                EXPECTED_FAIL_AFTER_VAESENCLAST
aggregate_run_rc:                132
aggregate_exception_hits:        3
aggregate_aesenc_helper_hits:    4
aggregate_aesenclast_helper_hits: 4
aggregate_pclmul_helper_hits:    16
aggregate_fail_pc:               40105b
aggregate_next:                  40105b: 62 72 fd 48 1a 25 9b ... vbroadcastf64x2 zmm12,XMMWORD PTR [rip+0xf9b]

failures:                        0
```

Exact-byte evidence from generated objdump:

```text
vaesenclast-single:    401000: 62 72 2d 48 dd df     vaesenclast zmm11,zmm10,zmm7
vaesenclast-chain:     40104f: 62 52 35 48 dc d0     vaesenc zmm10,zmm9,zmm8
vaesenclast-chain:     401055: 62 72 2d 48 dd df     vaesenclast zmm11,zmm10,zmm7
vaesenclast-semantic:  401011: 62 72 2d 48 dd df     vaesenclast zmm11,zmm10,zmm7
aggregate:             40104f: 62 52 35 48 dc d0     vaesenc zmm10,zmm9,zmm8
aggregate:             401055: 62 72 2d 48 dd df     vaesenclast zmm11,zmm10,zmm7
aggregate:             40105b: 62 72 fd 48 1a 25 9b 0f 00 00  vbroadcastf64x2 zmm12,XMMWORD PTR [rip+0xf9b]
```

Semantic probe data:

```text
state:      00112233445566778899aabbccddeeff
round_key:  0f0e0d0c0b0a09080706050403020100
expected:   6cf2a11a10e421cbc3c796f1488032ea
```

The semantic probe stores `xmm11` after `vaesenclast` and exits `0` only if the
stored low 128 bits match that expected AESENCLAST last-round output.

TCG evidence for the new instruction includes four helper calls:

```text
vaesenclast-semantic.qemu.log:
35: call aesenclast_xmm,$0x0,$0,env,loc18,loc19,loc20
39: call aesenclast_xmm,$0x0,$0,env,loc24,loc25,loc26
43: call aesenclast_xmm,$0x0,$0,env,loc30,loc31,loc32
47: call aesenclast_xmm,$0x0,$0,env,loc36,loc37,loc38

aggregate.qemu.log:
202: call aesenclast_xmm,$0x0,$0,env,loc151,loc152,loc153
206: call aesenclast_xmm,$0x0,$0,env,loc155,loc156,loc157
210: call aesenclast_xmm,$0x0,$0,env,loc159,loc160,loc161
214: call aesenclast_xmm,$0x0,$0,env,loc163,loc164,loc165
218: mov_i64 rip,$0x40105b
219: call raise_exception,$0xa,$0,env,$0x6
```

## Next Failure Point

The next still-unimplemented EVEX instruction is:

```text
40105b: 62 72 fd 48 1a 25 9b 0f 00 00    vbroadcastf64x2 zmm12,XMMWORD PTR [rip+0xf9b]
```

## Limitations

This remains an exact-byte smoke patch, not a general EVEX implementation. It
does not decode arbitrary operands, masks, memory forms beyond this exact
aggregate shape, VL variants, exception details, CPUID/XCR0 behavior, or
unrelated VAES instructions.
