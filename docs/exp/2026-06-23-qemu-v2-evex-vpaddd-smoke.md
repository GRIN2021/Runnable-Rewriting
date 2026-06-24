# QEMU V2 EVEX VPADDD Smoke Patch

Date: 2026-06-23
Branch: `codex/qemu-upgrade-v2`
Script: `runnable/scripts/qemu_v2_evex_vpaddd_smoke_patch.sh`
Scratch root used for fresh validation: `/tmp/rr-qemu-v2-evex-vpaddd-smoke-final`

## Summary

This experiment extends the exact-byte QEMU `10.2.3` EVEX smoke path through
the next aggregate AVX-512 boundary:

```text
62 f2 6d 48 00 da    vpshufb zmm3,zmm2,zmm2
```

Validation result: **PASS** for the generated single-instruction probe and the
short aggregate-prefix chain under patched `qemu-x86_64`.

The aggregate probe now advances past `vpaddd` and still fails at:

```text
62 f3 dd 48 25 eb 96    vpternlogq zmm5,zmm4,zmm3,0x96
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
```

The `0xff6` forms come from standalone generated `vmovdqu64` store/load probes.
The `0xfea` and `0xfe0` forms match the aggregate
`test/qemu-v2-probes/avx512-evex.S` store/load bytes.

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
- `rr_evex_add_zmm4_zmm3_zmm2_512(...)`, which uses `tcg_gen_gvec_add(MO_32, ...)` for 128-bit lane-wise 32-bit addition.
- `rr_evex_pshufb_zmm3_zmm2_zmm2_512(...)`, which calls the existing `pshufb_xmm` helper once per 128-bit lane.
- `rr_try_evex_vpaddd_smoke(...)`, the exact-byte dispatcher.

This is not a general EVEX implementation. It does not decode arbitrary EVEX
prefixes, masks, register choices, memory operands, or CPUID/XCR0 behavior.

## Validation

Fresh command:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
bash runnable/scripts/qemu_v2_evex_vpaddd_smoke_patch.sh \
  --fresh \
  --scratch-root /tmp/rr-qemu-v2-evex-vpaddd-smoke-final \
  --qemu-tarball /tmp/rr-qemu-v2-evex-vmovdqu64-smoke-final/download/qemu-10.2.3.tar.xz \
  --jobs 3
```

Result:

```text
probe:          vpaddd-single
result:         PASS
run_rc:         0
exception_hits: 0
vpshufb_hits:   0
vpaddd_hits:    2
memory_hits:    0

probe:          vpaddd-chain
result:         PASS
run_rc:         0
exception_hits: 0
vpshufb_hits:   4
vpaddd_hits:    2
memory_hits:    8

aggregate_result:          EXPECTED_FAIL_AFTER_VPADDD
aggregate_run_rc:          132
aggregate_exception_hits:  3
aggregate_vpshufb_hits:    4
aggregate_vpaddd_hits:     2
aggregate_fail_pc:         40102c
aggregate_next:            40102c: 62 f3 dd 48 25 eb 96 vpternlogq zmm5,zmm4,zmm3,0x96

failures:                  0
```

Observed TCG for the `vpaddd` smoke path includes four lane helper calls for
the preceding `vpshufb` step:

```text
call pshufb_xmm,$0x0,$0,env,loc22,loc23,loc24
call pshufb_xmm,$0x0,$0,env,loc27,loc28,loc29
call pshufb_xmm,$0x0,$0,env,loc32,loc33,loc34
call pshufb_xmm,$0x0,$0,env,loc37,loc38,loc39
```

Aggregate boundary evidence:

```text
mov_i64 rip,$0x40102c
call raise_exception,$0xa,$0,env,$0x6
check_exception old: 0xffffffff new 0x6
```

## Next Failure Point

The next still-unimplemented EVEX instruction is:

```text
40102c: 62 f3 dd 48 25 eb 96    vpternlogq zmm5,zmm4,zmm3,0x96
```

## Limitations

- Exact-byte only; no general EVEX opcode or operand decode.
- Only the exact-byte `vpshufb` and `vpaddd` smoke paths are covered.
- Masking, merge/zero modes, exception details, and CPUID/XCR0 exposure are not implemented.
- Previous `vpxorq`, `vmovdqa64`, and `vmovdqu64` support remains smoke-level and limited to the listed byte strings.
