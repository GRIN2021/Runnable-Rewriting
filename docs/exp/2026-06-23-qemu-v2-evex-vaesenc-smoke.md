# QEMU V2 EVEX VAESENC Smoke Patch

Date: 2026-06-23
Branch: `codex/qemu-upgrade-v2`
Script: `runnable/scripts/qemu_v2_evex_vaesenc_smoke_patch.sh`
Fresh scratch root: `/tmp/rr-qemu-v2-evex-vaesenc-smoke-final`

## Summary

This experiment adds the next exact-byte QEMU `10.2.3` EVEX smoke case:

```text
62 52 35 48 dc d0    vaesenc zmm10,zmm9,zmm8
```

Validation result: **PASS** for the generated single-instruction probe, short
aggregate-prefix chain, and low-128-bit semantic probe under patched
`qemu-x86_64`.

The aggregate probe now advances past `vaesenc` at `40104f` and fails at the
next unimplemented EVEX instruction:

```text
401055: 62 72 2d 48 dd df    vaesenclast zmm11,zmm10,zmm7
```

## Patch Shape

The script keeps all QEMU source, build, patch, and probe outputs under `/tmp`.
It first prepares the existing VPCLMUL HH smoke tree as the carried-forward
aggregate prefix, then copies that throwaway source tree and applies a small
overlay to:

```text
target/i386/tcg/decode-new.c.inc
```

The overlay adds one exact-byte match for:

```text
62 52 35 48 dc d0    vaesenc zmm10,zmm9,zmm8
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
```

## Operand Semantics

For:

```text
vaesenc zmm10,zmm9,zmm8
```

the smoke patch implements AESENC independently for each 128-bit lane:

```text
zmm10.lane[i] = AESENC(zmm9.lane[i], zmm8.lane[i]), i = 0..3
```

The implementation reuses QEMU's existing `gen_helper_aesenc_xmm` helper. It
calls the helper four times, once per `ZMM_X(0..3)` lane, with destination
offsets for `zmm10`, first-source offsets for `zmm9`, and second-source offsets
for `zmm8`.

## Validation

Fresh command:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
bash runnable/scripts/qemu_v2_evex_vaesenc_smoke_patch.sh \
  --fresh \
  --scratch-root /tmp/rr-qemu-v2-evex-vaesenc-smoke-final \
  --qemu-tarball /tmp/rr-qemu-v2-evex-vpclmul-hqlq-smoke-final/download/qemu-10.2.3.tar.xz \
  --jobs 3
```

Result:

```text
probe:                 vaesenc-single
result:                PASS
run_rc:                0
exception_hits:        0
aesenc_helper_hits:    4
pclmul_helper_hits:    0

probe:                 vaesenc-chain
result:                PASS
run_rc:                0
exception_hits:        0
aesenc_helper_hits:    4
pclmul_helper_hits:    16

probe:                 vaesenc-semantic
result:                PASS
run_rc:                0
exception_hits:        0
aesenc_helper_hits:    4
pclmul_helper_hits:    0

aggregate_result:             EXPECTED_FAIL_AFTER_VAESENC
aggregate_run_rc:             132
aggregate_exception_hits:     3
aggregate_aesenc_helper_hits: 4
aggregate_pclmul_helper_hits: 16
aggregate_fail_pc:            401055
aggregate_next:               401055: 62 72 2d 48 dd df vaesenclast zmm11,zmm10,zmm7

failures:                     0
```

Exact-byte evidence from generated objdump:

```text
vaesenc-single:    401000: 62 52 35 48 dc d0     vaesenc zmm10,zmm9,zmm8
vaesenc-chain:     401048: 62 73 55 48 44 cc 11  vpclmulhqhqdq zmm9,zmm5,zmm4
vaesenc-chain:     40104f: 62 52 35 48 dc d0     vaesenc zmm10,zmm9,zmm8
vaesenc-semantic:  401012: 62 52 35 48 dc d0     vaesenc zmm10,zmm9,zmm8
aggregate:         401048: 62 73 55 48 44 cc 11  vpclmulhqhqdq zmm9,zmm5,zmm4
aggregate:         40104f: 62 52 35 48 dc d0     vaesenc zmm10,zmm9,zmm8
aggregate:         401055: 62 72 2d 48 dd df     vaesenclast zmm11,zmm10,zmm7
```

Semantic probe data:

```text
state:      00112233445566778899aabbccddeeff
round_key:  0f0e0d0c0b0a09080706050403020100
expected:   6c77ebd5ff6df27eaa0039f0d1e98ba3
```

The semantic probe stores `xmm10` after `vaesenc` and exits `0` only if the
stored low 128 bits match that expected AESENC round output.

TCG evidence for the new instruction includes four helper calls:

```text
vaesenc-semantic.qemu.log:
35: call aesenc_xmm,$0x0,$0,env,loc18,loc19,loc20
39: call aesenc_xmm,$0x0,$0,env,loc24,loc25,loc26
43: call aesenc_xmm,$0x0,$0,env,loc30,loc31,loc32
47: call aesenc_xmm,$0x0,$0,env,loc36,loc37,loc38

aggregate.qemu.log:
184: call aesenc_xmm,$0x0,$0,env,loc135,loc136,loc137
188: call aesenc_xmm,$0x0,$0,env,loc139,loc140,loc141
192: call aesenc_xmm,$0x0,$0,env,loc143,loc144,loc145
196: call aesenc_xmm,$0x0,$0,env,loc147,loc148,loc149
200: mov_i64 rip,$0x401055
201: call raise_exception,$0xa,$0,env,$0x6
```

## Next Failure Point

The next still-unimplemented EVEX instruction is:

```text
401055: 62 72 2d 48 dd df    vaesenclast zmm11,zmm10,zmm7
```

## Limitations

This remains an exact-byte smoke patch, not a general EVEX implementation. It
does not decode arbitrary operands, masks, memory forms, VL variants, exception
details, CPUID/XCR0 behavior, or unrelated VAES instructions.
