# QEMU V2 EVEX VPCLMUL HQLQ Smoke Patch

Date: 2026-06-23
Branch: `codex/qemu-upgrade-v2`
Script: `runnable/scripts/qemu_v2_evex_vpclmul_hqlq_smoke_patch.sh`
Scratch root used for fresh validation: `/tmp/rr-qemu-v2-evex-vpclmul-hqlq-smoke-final`

## Summary

This experiment completes the exact-byte QEMU `10.2.3` EVEX smoke path through:

```text
62 73 55 48 44 c4 01    vpclmulhqlqdq zmm8,zmm5,zmm4
```

Validation result: **PASS** for the generated single-instruction probe, short
aggregate-prefix chain, and low-128-bit semantic probe under patched
`qemu-x86_64`.

The aggregate probe now advances past `vpclmulhqlqdq` at `401041` and fails at
the next unimplemented EVEX instruction:

```text
401048: 62 73 55 48 44 cc 11    vpclmulhqhqdq zmm9,zmm5,zmm4
```

## Patch Shape

The script keeps all QEMU source, build, patch, and probe outputs under `/tmp`.
The temporary patch touches only:

```text
target/i386/tcg/decode-new.c.inc
```

The half-finished script already matched the new `hqlq` byte string, but it had
regressed the carried-forward aggregate path into pure instruction skipping.
The completed version restores the previous exact-byte smoke semantics for:

```text
62 f1 fd 48 ef c0                vpxorq zmm0,zmm0,zmm0
62 f1 fd 48 6f c8                vmovdqa64 zmm1,zmm0
62 f1 fe 48 7f 0d f6 0f 00 00    vmovdqu64 ZMMWORD PTR [rip+0xff6],zmm1
62 f1 fe 48 6f 15 f6 0f 00 00    vmovdqu64 zmm2,ZMMWORD PTR [rip+0xff6]
62 f1 fe 48 7f 0d ea 0f 00 00    vmovdqu64 ZMMWORD PTR [rip+0xfea],zmm1
62 f1 fe 48 6f 15 e0 0f 00 00    vmovdqu64 zmm2,ZMMWORD PTR [rip+0xfe0]
62 f2 6d 48 00 da                vpshufb zmm3,zmm2,zmm2
62 f1 65 48 fe e2                vpaddd zmm4,zmm3,zmm2
62 f3 dd 48 25 eb 96             vpternlogq zmm5,zmm4,zmm3,0x96
62 f3 55 48 44 f4 00             vpclmullqlqdq zmm6,zmm5,zmm4
62 f3 55 48 44 fc 10             vpclmullqhqdq zmm7,zmm5,zmm4
62 73 55 48 44 c4 01             vpclmulhqlqdq zmm8,zmm5,zmm4
```

## Operand Semantics

For:

```text
vpclmulhqlqdq zmm8,zmm5,zmm4
```

the smoke patch implements `imm8=0x01`: high quadword from each 128-bit lane of
`zmm5` multiplied carry-less by the low quadword from the corresponding
128-bit lane of `zmm4`. The 128-bit GF(2) product is written into the matching
128-bit lane of `zmm8`.

The implementation reuses QEMU's existing `gen_helper_pclmulqdq_xmm` helper.
It calls the helper four times, once per `ZMM_X(0..3)` lane, with destination
offsets for `zmm8`, first-source offsets for `zmm5`, second-source offsets for
`zmm4`, and control immediate `0x01`.

## Validation

Fresh command:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
bash runnable/scripts/qemu_v2_evex_vpclmul_hqlq_smoke_patch.sh \
  --fresh \
  --scratch-root /tmp/rr-qemu-v2-evex-vpclmul-hqlq-smoke-final \
  --qemu-tarball /tmp/rr-qemu-v2-evex-vpclmul-smoke-final/download/qemu-10.2.3.tar.xz \
  --jobs 3
```

Result:

```text
probe:                 vpclmul-hqlq-single
result:                PASS
run_rc:                0
exception_hits:        0
pclmul_helper_hits:    4

probe:                 vpclmul-hqlq-chain
result:                PASS
run_rc:                0
exception_hits:        0
pclmul_helper_hits:    12

probe:                 vpclmul-hqlq-semantic
result:                PASS
run_rc:                0
exception_hits:        0
pclmul_helper_hits:    4

aggregate_result:             EXPECTED_FAIL_AFTER_VPCLMUL_HQLQ
aggregate_run_rc:             132
aggregate_exception_hits:     3
aggregate_pclmul_helper_hits: 12
aggregate_fail_pc:            401048
aggregate_next:               401048: 62 73 55 48 44 cc 11 vpclmulhqhqdq zmm9,zmm5,zmm4

failures:                     0
```

Exact-byte evidence from generated objdump:

```text
vpclmul-hqlq-single:    401000: 62 73 55 48 44 c4 01  vpclmulhqlqdq zmm8,zmm5,zmm4
vpclmul-hqlq-chain:     401033: 62 f3 55 48 44 f4 00  vpclmullqlqdq zmm6,zmm5,zmm4
vpclmul-hqlq-chain:     40103a: 62 f3 55 48 44 fc 10  vpclmullqhqdq zmm7,zmm5,zmm4
vpclmul-hqlq-chain:     401041: 62 73 55 48 44 c4 01  vpclmulhqlqdq zmm8,zmm5,zmm4
vpclmul-hqlq-semantic:  401010: 62 73 55 48 44 c4 01  vpclmulhqlqdq zmm8,zmm5,zmm4
aggregate:              401041: 62 73 55 48 44 c4 01  vpclmulhqlqdq zmm8,zmm5,zmm4
aggregate:              401048: 62 73 55 48 44 cc 11  vpclmulhqhqdq zmm9,zmm5,zmm4
```

Semantic probe data:

```text
src1 high qword:    feedfacecafebeef
src2 low qword:     0fedcba987654321
expected product:   05544a6551cee46a 708b0f331722920f
```

The semantic probe stores `xmm8` after `vpclmulhqlqdq` and exits `0` only if
the stored low 128 bits match that expected carry-less product.

TCG evidence for the new instruction includes four helper calls with
`imm8=0x1`:

```text
vpclmul-hqlq-semantic.qemu.log:
35: call pclmulqdq_xmm,$0x0,$0,env,loc18,loc19,loc20,$0x1
39: call pclmulqdq_xmm,$0x0,$0,env,loc25,loc26,loc27,$0x1
43: call pclmulqdq_xmm,$0x0,$0,env,loc31,loc32,loc33,$0x1
47: call pclmulqdq_xmm,$0x0,$0,env,loc37,loc38,loc39,$0x1

aggregate.qemu.log:
148: call pclmulqdq_xmm,$0x0,$0,env,loc101,loc102,loc103,$0x1
152: call pclmulqdq_xmm,$0x0,$0,env,loc106,loc107,loc108,$0x1
156: call pclmulqdq_xmm,$0x0,$0,env,loc110,loc111,loc112,$0x1
160: call pclmulqdq_xmm,$0x0,$0,env,loc114,loc115,loc116,$0x1
164: mov_i64 rip,$0x401048
165: call raise_exception,$0xa,$0,env,$0x6
```

## Next Failure Point

The next still-unimplemented EVEX instruction is:

```text
401048: 62 73 55 48 44 cc 11    vpclmulhqhqdq zmm9,zmm5,zmm4
```

## Limitations

This remains an exact-byte smoke patch, not a general EVEX implementation. It
does not decode arbitrary operands, masks, memory forms, VL variants, exception
details, CPUID/XCR0 behavior, or unrelated VPCLMUL immediates.
