# QEMU V2 EVEX VPTERNLOGQ Smoke Patch

Date: 2026-06-23
Branch: `codex/qemu-upgrade-v2`
Script: `runnable/scripts/qemu_v2_evex_vpternlogq_smoke_patch.sh`
Scratch root used for fresh validation: `/tmp/rr-qemu-v2-evex-vpternlogq-smoke-final`

## Summary

This experiment extends the exact-byte QEMU `10.2.3` EVEX smoke path through:

```text
62 f3 dd 48 25 eb 96    vpternlogq zmm5,zmm4,zmm3,0x96
```

Validation result: **PASS** for the generated single-instruction probe, short
aggregate-prefix chain, and a low-128-bit semantic probe under patched
`qemu-x86_64`.

The aggregate probe now advances past `vpternlogq` and still fails at:

```text
401033: 62 f3 55 48 44 f4 00    vpclmullqlqdq zmm6,zmm5,zmm4
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
```

## Operand And Immediate Semantics

For the aggregate instruction as rendered by GNU objdump:

```text
vpternlogq zmm5,zmm4,zmm3,0x96
```

the destructive ternary inputs for this smoke case are:

```text
A = original zmm5  (dest/src1)
B = zmm4           (src2)
C = zmm3           (src3)
```

The immediate `0x96` is binary `10010110`, so bits `1`, `2`, `4`, and `7` are
set. Those are exactly the truth-table rows where `A`, `B`, and `C` have odd
parity, so for this case:

```text
vpternlogq zmm5,zmm4,zmm3,0x96 == zmm5 = zmm5 ^ zmm4 ^ zmm3
```

XOR is symmetric, so this immediate remains the same parity function even if
the documentation names the three ternlog inputs in a different source order.

## Patch Shape

The script copies and patches QEMU under `/tmp` only. The temporary patch
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
- `rr_evex_xor_zmm5_zmm5_zmm4_zmm3_512(...)`, using two `tcg_gen_gvec_xor(MO_64, ...)` operations to implement `zmm5 ^ zmm4 ^ zmm3`.
- `rr_try_evex_vpternlogq_smoke(...)`, the exact-byte dispatcher.

This is not a general EVEX implementation. It does not decode arbitrary EVEX
prefixes, masks, register choices, memory operands, or CPUID/XCR0 behavior.

## Validation

Fresh command:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
bash runnable/scripts/qemu_v2_evex_vpternlogq_smoke_patch.sh \
  --fresh \
  --scratch-root /tmp/rr-qemu-v2-evex-vpternlogq-smoke-final \
  --qemu-tarball /tmp/rr-qemu-v2-evex-vpaddd-smoke-final/download/qemu-10.2.3.tar.xz \
  --jobs 3
```

Result:

```text
probe:             vpternlogq-single
result:            PASS
run_rc:            0
exception_hits:    0
xor_hits:          4

probe:             vpternlogq-chain
result:            PASS
run_rc:            0
exception_hits:    0
vpshufb_hits:      4
vpaddd_hits:       2
xor_hits:          4
memory_hits:       8

probe:             vpternlogq-semantic
result:            PASS
run_rc:            0
exception_hits:    0
xor_hits:          6
memory_hits:       8

aggregate_result:             EXPECTED_FAIL_AFTER_VPTERNLOGQ
aggregate_run_rc:             132
aggregate_exception_hits:     3
aggregate_vpshufb_hits:       4
aggregate_vpaddd_hits:        2
aggregate_xor_hits:           4
aggregate_fail_pc:            401033
aggregate_next:               401033: 62 f3 55 48 44 f4 00 vpclmullqlqdq zmm6,zmm5,zmm4

failures:                     0
```

Exact-byte evidence from generated objdump:

```text
vpternlogq-single:    401000: 62 f3 dd 48 25 eb 96  vpternlogq zmm5,zmm4,zmm3,0x96
vpternlogq-chain:     40102c: 62 f3 dd 48 25 eb 96  vpternlogq zmm5,zmm4,zmm3,0x96
vpternlogq-semantic:  401018: 62 f3 dd 48 25 eb 96  vpternlogq zmm5,zmm4,zmm3,0x96
aggregate:            40102c: 62 f3 dd 48 25 eb 96  vpternlogq zmm5,zmm4,zmm3,0x96
```

Semantic probe data:

```text
src_dest low 128:  0123456789abcdef fedcba9876543210
src2 low 128:      1111111111111111 2222222222222222
src3 low 128:      0101010101010101 1010101010101010
expected XOR:      1133557799bbddff ccee88aa44660022
```

The semantic probe stores `xmm5` after `vpternlogq` and exits `0` only if the
stored low 128 bits match that expected XOR value.

Observed TCG evidence includes XOR vector ops for the vpternlogq fast path:

```text
vpternlogq-semantic.qemu.log:
43:xor_vec v256,e8,tmp25,tmp23,tmp24
47:xor_vec v256,e8,tmp28,tmp26,tmp27
51:xor_vec v256,e8,tmp31,tmp29,tmp30
55:xor_vec v256,e8,tmp34,tmp32,tmp33

aggregate.qemu.log:
92:xor_vec v256,e8,tmp50,tmp48,tmp49
96:xor_vec v256,e8,tmp53,tmp51,tmp52
100:xor_vec v256,e8,tmp56,tmp54,tmp55
104:xor_vec v256,e8,tmp59,tmp57,tmp58
109:mov_i64 rip,$0x401033
110:call raise_exception,$0xa,$0,env,$0x6
```

## Next Failure Point

The next still-unimplemented EVEX instruction is:

```text
401033: 62 f3 55 48 44 f4 00    vpclmullqlqdq zmm6,zmm5,zmm4
```

## Limitations

- Exact-byte only; no general EVEX opcode or operand decode.
- Only `imm8=0x96` for `vpternlogq zmm5,zmm4,zmm3,0x96` is implemented.
- The semantic check validates low 128 bits directly; the emitted TCG path is 512-bit gvec XOR.
- Masking, merge/zero modes, exception details, and CPUID/XCR0 exposure are not implemented.
- Previous `vpxorq`, `vmovdqa64`, `vmovdqu64`, `vpshufb`, and `vpaddd` support remains smoke-level and limited to the listed byte strings.
