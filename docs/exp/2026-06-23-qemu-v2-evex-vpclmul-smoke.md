# QEMU V2 EVEX VPCLMUL Smoke Patch

Date: 2026-06-23
Branch: `codex/qemu-upgrade-v2`
Script: `runnable/scripts/qemu_v2_evex_vpclmul_smoke_patch.sh`
Scratch root used for fresh validation: `/tmp/rr-qemu-v2-evex-vpclmul-smoke-final`

## Summary

This experiment extends the exact-byte QEMU `10.2.3` EVEX smoke path through:

```text
62 f3 55 48 44 f4 00    vpclmullqlqdq zmm6,zmm5,zmm4
```

Validation result: **PASS** for the generated single-instruction probe, short
aggregate-prefix chain, and a low-128-bit semantic probe under patched
`qemu-x86_64`.

The aggregate probe now advances past `vpclmullqlqdq` and still fails at:

```text
40103a: 62 f3 55 48 44 fc 10    vpclmullqhqdq zmm7,zmm5,zmm4
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
```

## Operand Semantics

For the aggregate instruction:

```text
vpclmullqlqdq zmm6,zmm5,zmm4
```

the smoke patch implements `imm8=0x00`, i.e. low quadword from each 128-bit lane
of `zmm5` multiplied carry-less by the low quadword from the corresponding
128-bit lane of `zmm4`.  The 128-bit GF(2) product is written into the matching
128-bit lane of `zmm6`.

The patch reuses QEMU's existing PCLMUL helper instead of adding a new GF(2)
multiply implementation.  QEMU `10.2.3` exposes `gen_helper_pclmulqdq_xmm`; the
smoke path calls it four times, once for each `ZMM_X(0..3)` lane, with control
immediate `0x00`.

## Patch Shape

The script copies and patches QEMU under `/tmp` only.  The temporary patch
touches:

`target/i386/tcg/decode-new.c.inc`

It inserts an early fast path in `disas_insn`, before byte `0x62` can be treated
as legacy `BOUND`.

The added smoke helpers are:

- `rr_evex_exact_bytes(...)` for guest byte matching via `translator_ldub`.
- `rr_evex_rip_rel_addr(...)` for `pc + insn_len + disp32`.
- `rr_evex_store_zmm1_512(...)` and `rr_evex_load_zmm2_512(...)` for the prior memory boundary.
- `rr_evex_pshufb_zmm3_zmm2_zmm2_512(...)`, using the existing `pshufb_xmm` helper once per 128-bit lane.
- `rr_evex_add_zmm4_zmm3_zmm2_512(...)`, using `tcg_gen_gvec_add(MO_32, ...)`.
- `rr_evex_xor_zmm5_zmm5_zmm4_zmm3_512(...)`, using two `tcg_gen_gvec_xor(MO_64, ...)` operations to implement the previous `vpternlogq imm=0x96` parity case.
- `rr_evex_pclmul_zmm6_zmm5_zmm4_lqlq_512(...)`, using `gen_helper_pclmulqdq_xmm` four times for the `vpclmullqlqdq` exact case.
- `rr_try_evex_vpclmul_smoke(...)`, the exact-byte dispatcher.

This is not a general EVEX implementation.  It does not decode arbitrary EVEX
prefixes, masks, register choices, memory operands, CPUID/XCR0 behavior, or
other VPCLMUL immediates.

## Validation

Fresh command:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
bash runnable/scripts/qemu_v2_evex_vpclmul_smoke_patch.sh \
  --fresh \
  --scratch-root /tmp/rr-qemu-v2-evex-vpclmul-smoke-final \
  --qemu-tarball /tmp/rr-qemu-v2-evex-vpternlogq-smoke-final/download/qemu-10.2.3.tar.xz \
  --jobs 3
```

Result:

```text
probe:             vpclmul-single
result:            PASS
run_rc:            0
exception_hits:    0
vpclmul_hits:      4

probe:             vpclmul-chain
result:            PASS
run_rc:            0
exception_hits:    0
vpshufb_hits:      4
vpaddd_hits:       2
vpclmul_hits:      4
xor_hits:          4
memory_hits:       8

probe:             vpclmul-semantic
result:            PASS
run_rc:            0
exception_hits:    0
vpclmul_hits:      4
xor_hits:          2
memory_hits:       7

aggregate_result:             EXPECTED_FAIL_AFTER_VPCLMUL
aggregate_run_rc:             132
aggregate_exception_hits:     3
aggregate_vpshufb_hits:       4
aggregate_vpaddd_hits:        2
aggregate_vpclmul_hits:       4
aggregate_xor_hits:           4
aggregate_fail_pc:            40103a
aggregate_next:               40103a: 62 f3 55 48 44 fc 10 vpclmullqhqdq zmm7,zmm5,zmm4

failures:                     0
```

Exact-byte evidence from generated objdump:

```text
vpclmul-single:    401000: 62 f3 55 48 44 f4 00  vpclmullqlqdq zmm6,zmm5,zmm4
vpclmul-chain:     401033: 62 f3 55 48 44 f4 00  vpclmullqlqdq zmm6,zmm5,zmm4
vpclmul-semantic:  401010: 62 f3 55 48 44 f4 00  vpclmullqlqdq zmm6,zmm5,zmm4
aggregate:         401033: 62 f3 55 48 44 f4 00  vpclmullqlqdq zmm6,zmm5,zmm4
```

Semantic probe data:

```text
src1 low qword:    123456789abcdef0
src2 low qword:    0fedcba987654321
expected product:  00e038d8688850b0 40a0789828c810f0
```

The semantic probe stores `xmm6` after `vpclmullqlqdq` and exits `0` only if
the stored low 128 bits match that expected carry-less product.

Observed TCG evidence includes four existing PCLMUL helper calls for the zmm
case:

```text
vpclmul-chain.qemu.log:
112: call pclmulqdq_xmm,$0x0,$0,env,loc60,loc61,loc62,$0x0
116: call pclmulqdq_xmm,$0x0,$0,env,loc66,loc67,loc68,$0x0
120: call pclmulqdq_xmm,$0x0,$0,env,loc72,loc73,loc74,$0x0
124: call pclmulqdq_xmm,$0x0,$0,env,loc78,loc79,loc80,$0x0

aggregate.qemu.log:
111: call pclmulqdq_xmm,$0x0,$0,env,loc60,loc61,loc62,$0x0
115: call pclmulqdq_xmm,$0x0,$0,env,loc66,loc67,loc68,$0x0
119: call pclmulqdq_xmm,$0x0,$0,env,loc72,loc73,loc74,$0x0
123: call pclmulqdq_xmm,$0x0,$0,env,loc78,loc79,loc80,$0x0
127: mov_i64 rip,$0x40103a
128: call raise_exception,$0xa,$0,env,$0x6
```

## Next Failure Point

The next still-unimplemented EVEX instruction is:

```text
40103a: 62 f3 55 48 44 fc 10    vpclmullqhqdq zmm7,zmm5,zmm4
```

## Limitations

- Exact-byte only; no general EVEX opcode or operand decode.
- Only `vpclmullqlqdq zmm6,zmm5,zmm4` / `imm8=0x00` is implemented.
- The semantic check validates the low 128-bit lane directly; the emitted TCG path calls the existing XMM PCLMUL helper once per 128-bit lane.
- Masking, merge/zero modes, exception details, and CPUID/XCR0 exposure are not implemented.
- Previous `vpxorq`, `vmovdqa64`, `vmovdqu64`, `vpshufb`, `vpaddd`, and `vpternlogq` support remains smoke-level and limited to the listed byte strings.
