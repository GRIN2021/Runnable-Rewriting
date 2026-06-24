# QEMU V2 EVEX VPCLMUL HH Smoke Patch

Date: 2026-06-23
Branch: `codex/qemu-upgrade-v2`
Script: `runnable/scripts/qemu_v2_evex_vpclmul_hh_smoke_patch.sh`
Fresh scratch root: `/tmp/rr-qemu-v2-evex-vpclmul-hh-smoke-final2`

## Summary

This experiment adds the next exact-byte QEMU `10.2.3` EVEX VPCLMUL smoke
case:

```text
62 73 55 48 44 cc 11    vpclmulhqhqdq zmm9,zmm5,zmm4
```

Validation result: **PASS** for the generated single-instruction probe, short
aggregate-prefix chain, and low-128-bit semantic probe under patched
`qemu-x86_64`.

The aggregate probe now advances past `vpclmulhqhqdq` at `401048` and fails at
the next unimplemented EVEX instruction:

```text
40104f: 62 52 35 48 dc d0    vaesenc zmm10,zmm9,zmm8
```

## Patch Shape

The script keeps all QEMU source, build, patch, and probe outputs under `/tmp`.
It first prepares the existing HQLQ smoke tree as the carried-forward aggregate
prefix, then copies that throwaway source tree and applies a small overlay to:

```text
target/i386/tcg/decode-new.c.inc
```

The overlay adds one exact-byte match for:

```text
62 73 55 48 44 cc 11    vpclmulhqhqdq zmm9,zmm5,zmm4
```

The carried-forward path still covers the earlier aggregate VPCLMUL variants:

```text
62 f3 55 48 44 f4 00    vpclmullqlqdq zmm6,zmm5,zmm4
62 f3 55 48 44 fc 10    vpclmullqhqdq zmm7,zmm5,zmm4
62 73 55 48 44 c4 01    vpclmulhqlqdq zmm8,zmm5,zmm4
62 73 55 48 44 cc 11    vpclmulhqhqdq zmm9,zmm5,zmm4
```

## Operand Semantics

For:

```text
vpclmulhqhqdq zmm9,zmm5,zmm4
```

the smoke patch implements `imm8=0x11`: high quadword from each 128-bit lane of
`zmm5` multiplied carry-less by the high quadword from the corresponding
128-bit lane of `zmm4`. The 128-bit GF(2) product is written into the matching
128-bit lane of `zmm9`.

The implementation reuses QEMU's existing `gen_helper_pclmulqdq_xmm` helper. It
calls the helper four times, once per `ZMM_X(0..3)` lane, with destination
offsets for `zmm9`, first-source offsets for `zmm5`, second-source offsets for
`zmm4`, and control immediate `0x11`.

## Validation

Fresh command:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
bash runnable/scripts/qemu_v2_evex_vpclmul_hh_smoke_patch.sh \
  --fresh \
  --scratch-root /tmp/rr-qemu-v2-evex-vpclmul-hh-smoke-final2 \
  --qemu-tarball /tmp/rr-qemu-v2-evex-vpclmul-hqlq-smoke-final/download/qemu-10.2.3.tar.xz \
  --jobs 3
```

Result:

```text
probe:                 vpclmul-hh-single
result:                PASS
run_rc:                0
exception_hits:        0
pclmul_helper_hits:    4

probe:                 vpclmul-hh-chain
result:                PASS
run_rc:                0
exception_hits:        0
pclmul_helper_hits:    16

probe:                 vpclmul-hh-semantic
result:                PASS
run_rc:                0
exception_hits:        0
pclmul_helper_hits:    4

aggregate_result:             EXPECTED_FAIL_AFTER_VPCLMUL_HH
aggregate_run_rc:             132
aggregate_exception_hits:     3
aggregate_pclmul_helper_hits: 16
aggregate_fail_pc:            40104f
aggregate_next:               40104f: 62 52 35 48 dc d0 vaesenc zmm10,zmm9,zmm8

failures:                     0
```

Exact-byte evidence from generated objdump:

```text
vpclmul-hh-single:    401000: 62 73 55 48 44 cc 11  vpclmulhqhqdq zmm9,zmm5,zmm4
vpclmul-hh-chain:     401041: 62 73 55 48 44 c4 01  vpclmulhqlqdq zmm8,zmm5,zmm4
vpclmul-hh-chain:     401048: 62 73 55 48 44 cc 11  vpclmulhqhqdq zmm9,zmm5,zmm4
vpclmul-hh-semantic:  401010: 62 73 55 48 44 cc 11  vpclmulhqhqdq zmm9,zmm5,zmm4
aggregate:            401041: 62 73 55 48 44 c4 01  vpclmulhqlqdq zmm8,zmm5,zmm4
aggregate:            401048: 62 73 55 48 44 cc 11  vpclmulhqhqdq zmm9,zmm5,zmm4
aggregate:            40104f: 62 52 35 48 dc d0     vaesenc zmm10,zmm9,zmm8
```

Semantic probe data:

```text
src1 high qword:    feedfacecafebeef
src2 high qword:    0123456789abcdef
expected product:   00e00fef5abbd302 5d145a8b347cb555
```

The semantic probe stores `xmm9` after `vpclmulhqhqdq` and exits `0` only if
the stored low 128 bits match that expected carry-less product.

TCG evidence for the new instruction includes four helper calls with
`imm8=0x11`:

```text
vpclmul-hh-semantic.qemu.log:
35: call pclmulqdq_xmm,$0x0,$0,env,loc18,loc19,loc20,$0x11
39: call pclmulqdq_xmm,$0x0,$0,env,loc25,loc26,loc27,$0x11
43: call pclmulqdq_xmm,$0x0,$0,env,loc31,loc32,loc33,$0x11
47: call pclmulqdq_xmm,$0x0,$0,env,loc37,loc38,loc39,$0x11

aggregate.qemu.log:
166: call pclmulqdq_xmm,$0x0,$0,env,loc118,loc119,loc120,$0x11
170: call pclmulqdq_xmm,$0x0,$0,env,loc123,loc124,loc125,$0x11
174: call pclmulqdq_xmm,$0x0,$0,env,loc127,loc128,loc129,$0x11
178: call pclmulqdq_xmm,$0x0,$0,env,loc131,loc132,loc133,$0x11
182: mov_i64 rip,$0x40104f
183: call raise_exception,$0xa,$0,env,$0x6
```

## Next Failure Point

The next still-unimplemented EVEX instruction is:

```text
40104f: 62 52 35 48 dc d0    vaesenc zmm10,zmm9,zmm8
```

## Limitations

This remains an exact-byte smoke patch, not a general EVEX implementation. It
does not decode arbitrary operands, masks, memory forms, VL variants, exception
details, CPUID/XCR0 behavior, or unrelated VPCLMUL immediates.
