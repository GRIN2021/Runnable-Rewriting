# QEMU V2 EVEX VPCLMUL HQ Smoke Patch

Date: 2026-06-23
Branch: `codex/qemu-upgrade-v2`
Script: `runnable/scripts/qemu_v2_evex_vpclmul_hq_smoke_patch.sh`
Scratch root used for fresh validation: `/tmp/rr-qemu-v2-evex-vpclmul-hq-smoke-final`

## Summary

This experiment extends the exact-byte QEMU `10.2.3` EVEX smoke path through:

```text
62 f3 55 48 44 fc 10    vpclmullqhqdq zmm7,zmm5,zmm4
```

Validation result: **PASS** for the generated single-instruction probe, short
aggregate-prefix chain, and a low-128-bit semantic probe under patched
`qemu-x86_64`.

The aggregate probe now advances past `vpclmullqhqdq` and still fails at:

```text
401041: 62 73 55 48 44 c4 01    vpclmulhqlqdq zmm8,zmm5,zmm4
```

## Exact Bytes

The throwaway patch recognizes these byte strings:

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
```

## Operand Semantics

For the aggregate instruction:

```text
vpclmullqhqdq zmm7,zmm5,zmm4
```

the smoke patch implements `imm8=0x10`: low quadword from each 128-bit lane of
`zmm5` multiplied carry-less by the high quadword from the corresponding
128-bit lane of `zmm4`.  The 128-bit GF(2) product is written into the matching
128-bit lane of `zmm7`.

The implementation reuses QEMU's existing `gen_helper_pclmulqdq_xmm` helper.
The smoke path calls it four times, once for each `ZMM_X(0..3)` lane, with
control immediate `0x10`.

## Patch Shape

The script copies and patches QEMU under `/tmp` only.  The temporary patch
touches:

`target/i386/tcg/decode-new.c.inc`

It inserts an early fast path in `disas_insn`, before byte `0x62` can be treated
as legacy `BOUND`.

The added smoke helpers include:

- `rr_evex_exact_bytes(...)` for guest byte matching via `translator_ldub`.
- `rr_evex_rip_rel_addr(...)` for `pc + insn_len + disp32`.
- `rr_evex_store_zmm1_512(...)` and `rr_evex_load_zmm2_512(...)` for the prior memory boundary.
- `rr_evex_pshufb_zmm3_zmm2_zmm2_512(...)`, using the existing `pshufb_xmm` helper once per 128-bit lane.
- `rr_evex_add_zmm4_zmm3_zmm2_512(...)`, using `tcg_gen_gvec_add(MO_32, ...)`.
- `rr_evex_xor_zmm5_zmm5_zmm4_zmm3_512(...)`, using two `tcg_gen_gvec_xor(MO_64, ...)` operations to implement the previous `vpternlogq imm=0x96` parity case.
- `rr_evex_pclmul_zmm6_zmm5_zmm4_lqlq_512(...)`, using `gen_helper_pclmulqdq_xmm` with `imm8=0x00`.
- `rr_evex_pclmul_zmm7_zmm5_zmm4_lqhq_512(...)`, using `gen_helper_pclmulqdq_xmm` with `imm8=0x10`.
- `rr_try_evex_vpclmul_hq_smoke(...)`, the exact-byte dispatcher.

This is not a general EVEX implementation.  It does not decode arbitrary EVEX
prefixes, masks, register choices, memory operands, CPUID/XCR0 behavior, or
other VPCLMUL immediates.

## Validation

Fresh command:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
bash runnable/scripts/qemu_v2_evex_vpclmul_hq_smoke_patch.sh \
  --fresh \
  --scratch-root /tmp/rr-qemu-v2-evex-vpclmul-hq-smoke-final \
  --qemu-tarball /tmp/rr-qemu-v2-evex-vpclmul-smoke-final/download/qemu-10.2.3.tar.xz \
  --jobs 3
```

Result:

```text
probe:                 vpclmul-hq-single
result:                PASS
run_rc:                0
exception_hits:        0
pclmul_helper_hits:    4

probe:                 vpclmul-hq-chain
result:                PASS
run_rc:                0
exception_hits:        0
vpshufb_hits:          4
vpaddd_hits:           2
pclmul_helper_hits:    8
xor_hits:              4
memory_hits:           8

probe:                 vpclmul-hq-semantic
result:                PASS
run_rc:                0
exception_hits:        0
pclmul_helper_hits:    4
xor_hits:              2
memory_hits:           7

aggregate_result:             EXPECTED_FAIL_AFTER_VPCLMUL_HQ
aggregate_run_rc:             132
aggregate_exception_hits:     3
aggregate_vpshufb_hits:       4
aggregate_vpaddd_hits:        2
aggregate_pclmul_helper_hits: 8
aggregate_xor_hits:           4
aggregate_fail_pc:            401041
aggregate_next:               401041: 62 73 55 48 44 c4 01 vpclmulhqlqdq zmm8,zmm5,zmm4

failures:                     0
```

Exact-byte evidence from generated objdump:

```text
vpclmul-hq-single:    401000: 62 f3 55 48 44 fc 10  vpclmullqhqdq zmm7,zmm5,zmm4
vpclmul-hq-chain:     401033: 62 f3 55 48 44 f4 00  vpclmullqlqdq zmm6,zmm5,zmm4
vpclmul-hq-chain:     40103a: 62 f3 55 48 44 fc 10  vpclmullqhqdq zmm7,zmm5,zmm4
vpclmul-hq-semantic:  401010: 62 f3 55 48 44 fc 10  vpclmullqhqdq zmm7,zmm5,zmm4
aggregate:            40103a: 62 f3 55 48 44 fc 10  vpclmullqhqdq zmm7,zmm5,zmm4
aggregate:            401041: 62 73 55 48 44 c4 01  vpclmulhqlqdq zmm8,zmm5,zmm4
```

Semantic probe data:

```text
src1 low qword:     123456789abcdef0
src2 high qword:    0123456789abcdef
expected product:   0010405101114154 0414445505154550
```

The semantic probe stores `xmm7` after `vpclmullqhqdq` and exits `0` only if
the stored low 128 bits match that expected carry-less product.

Observed TCG evidence includes four existing PCLMUL helper calls for the new zmm
case:

```text
vpclmul-hq-chain.qemu.log:
130: call pclmulqdq_xmm,$0x0,$0,env,loc84,loc85,loc86,$0x10
134: call pclmulqdq_xmm,$0x0,$0,env,loc89,loc90,loc91,$0x10
138: call pclmulqdq_xmm,$0x0,$0,env,loc93,loc94,loc95,$0x10
142: call pclmulqdq_xmm,$0x0,$0,env,loc97,loc98,loc99,$0x10

aggregate.qemu.log:
130: call pclmulqdq_xmm,$0x0,$0,env,loc84,loc85,loc86,$0x10
134: call pclmulqdq_xmm,$0x0,$0,env,loc89,loc90,loc91,$0x10
138: call pclmulqdq_xmm,$0x0,$0,env,loc93,loc94,loc95,$0x10
142: call pclmulqdq_xmm,$0x0,$0,env,loc97,loc98,loc99,$0x10
146: mov_i64 rip,$0x401041
147: call raise_exception,$0xa,$0,env,$0x6
```

## Next Failure Point

The next still-unimplemented EVEX instruction is:

```text
401041: 62 73 55 48 44 c4 01    vpclmulhqlqdq zmm8,zmm5,zmm4
```

## Limitations

- Exact-byte only; no general EVEX opcode or operand decode.
- Only `vpclmullqhqdq zmm7,zmm5,zmm4` / `imm8=0x10` is newly implemented.
- The prior `vpclmullqlqdq zmm6,zmm5,zmm4` / `imm8=0x00` smoke case is carried forward only as aggregate-prefix support.
- The semantic check validates the low 128-bit lane directly; the emitted TCG path calls the existing XMM PCLMUL helper once per 128-bit lane.
- Masking, merge/zero modes, exception details, and CPUID/XCR0 exposure are not implemented.
- Previous `vpxorq`, `vmovdqa64`, `vmovdqu64`, `vpshufb`, `vpaddd`, and `vpternlogq` support remains smoke-level and limited to the listed byte strings.
