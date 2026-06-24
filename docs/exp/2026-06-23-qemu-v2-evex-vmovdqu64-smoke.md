# QEMU V2 EVEX VMOVDQU64 Smoke Patch

Date: 2026-06-23
Branch: `codex/qemu-upgrade-v2`
Script: `runnable/scripts/qemu_v2_evex_vmovdqu64_smoke_patch.sh`
Scratch root used for validation: `/tmp/rr-qemu-v2-evex-vmovdqu64-smoke-final`

## Summary

This experiment extends the exact-byte QEMU `10.2.3` EVEX smoke path through
the first memory store/load boundary in the aggregate AVX-512 probe.

Validation result: **PASS** for three generated throwaway probes under patched
`qemu-x86_64`:

- `vmovdqu64-store`: single instruction `vmovdqu64 [rip+scratch],zmm1`
- `vmovdqu64-load`: single instruction `vmovdqu64 zmm2,[rip+scratch]`
- `vmovdqu64-chain`: `vpxorq`, `vmovdqa64`, `vmovdqu64` store, `vmovdqu64` load

The patch remains exact-byte and smoke-only. It does not implement a general
EVEX decoder, masks, CPUID/XCR0 exposure, alternate addressing modes, or
general register selection.

## Exact Bytes

The patch recognizes these byte strings:

```text
62 f1 fd 48 ef c0                vpxorq zmm0,zmm0,zmm0
62 f1 fd 48 6f c8                vmovdqa64 zmm1,zmm0
62 f1 fe 48 7f 0d f6 0f 00 00    vmovdqu64 ZMMWORD PTR [rip+0xff6],zmm1
62 f1 fe 48 6f 15 f6 0f 00 00    vmovdqu64 zmm2,ZMMWORD PTR [rip+0xff6]
62 f1 fe 48 7f 0d ea 0f 00 00    vmovdqu64 ZMMWORD PTR [rip+0xfea],zmm1
62 f1 fe 48 6f 15 e0 0f 00 00    vmovdqu64 zmm2,ZMMWORD PTR [rip+0xfe0]
```

The `0xff6` forms come from standalone single-instruction store/load probes.
The `0xfea` and `0xfe0` forms come from the short chain probe and match the
aggregate `test/qemu-v2-probes/avx512-evex.S` store/load bytes.

## Patch Shape

The throwaway patch touches one QEMU source file under `/tmp`:

`target/i386/tcg/decode-new.c.inc`

It inserts an early fast path in `disas_insn`, before normal byte dispatch would
interpret leading byte `0x62` as legacy `BOUND`.

The patch adds:

- `rr_evex_exact_bytes(...)` to compare guest bytes via `translator_ldub`.
- `rr_evex_rip_rel_addr(...)` to compute `pc + insn_len + disp32`.
- `rr_evex_store_zmm1_512(...)` to emit four `tcg_gen_qemu_st_i128` chunks.
- `rr_evex_load_zmm2_512(...)` to emit four `tcg_gen_qemu_ld_i128` chunks.
- `rr_try_evex_vmovdqu64_smoke(...)` to recognize the exact byte strings.

Observed TCG for the chain store/load includes:

```text
qemu_st2_i128 loc14,loc15,loc2,noat+un+leo,2
qemu_st2_i128 loc14,loc15,loc2,noat+un+leo,2
qemu_st2_i128 loc14,loc15,loc2,noat+un+leo,2
qemu_st2_i128 loc14,loc15,loc2,noat+un+leo,2
qemu_ld2_i128 loc20,loc21,loc2,noat+un+leo,2
qemu_ld2_i128 loc20,loc21,loc2,noat+un+leo,2
qemu_ld2_i128 loc20,loc21,loc2,noat+un+leo,2
qemu_ld2_i128 loc20,loc21,loc2,noat+un+leo,2
```

## Validation

Command:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
bash runnable/scripts/qemu_v2_evex_vmovdqu64_smoke_patch.sh \
  --fresh \
  --scratch-root /tmp/rr-qemu-v2-evex-vmovdqu64-smoke-final \
  --qemu-tarball /tmp/rr-qemu-v2-evex-move-smoke-dev/download/qemu-10.2.3.tar.xz \
  --jobs 3
```

Result:

```text
probe:          vmovdqu64-store
result:         PASS
run_rc:         0
exception_hits: 0
memory_hits:    4

probe:          vmovdqu64-load
result:         PASS
run_rc:         0
exception_hits: 0
memory_hits:    4

probe:          vmovdqu64-chain
result:         PASS
run_rc:         0
exception_hits: 0
memory_hits:    8

failures:       0
```

The script kept all QEMU source, build, patch, probe binaries, and debug logs
under `/tmp/rr-qemu-v2-evex-vmovdqu64-smoke-final`.

## Aggregate Boundary

An extra manual aggregate sanity check used the patched binary against
`test/qemu-v2-probes/avx512-evex.S`. The result was expected failure after the
newly implemented memory pair:

```text
40100c: 62 f1 fe 48 7f 0d ea 0f 00 00    vmovdqu64 [rip+scratch],zmm1
401016: 62 f1 fe 48 6f 15 e0 0f 00 00    vmovdqu64 zmm2,[rip+scratch]
401020: 62 f2 6d 48 00 da                vpshufb zmm3,zmm2,zmm2
```

The TCG log showed the four 128-bit stores and four 128-bit loads, then:

```text
mov_i64 rip,$0x401020
call raise_exception,$0xa,$0,env,$0x6
check_exception old: 0xffffffff new 0x6
```

So the next still-unimplemented EVEX instruction is:

`62 f2 6d 48 00 da`: `vpshufb zmm3,zmm2,zmm2`

## Limitations

- Exact-byte only: no general EVEX prefix, opcode, ModRM, or operand decode.
- Only `zmm1 -> [rip+disp32]` store and `[rip+disp32] -> zmm2` load are covered.
- Only the two observed displacement pairs are accepted.
- No mask semantics, fault-suppression semantics, alignment policy, or CPUID/XCR0
  changes are implemented.
- The memory implementation is smoke-level and copies 64 bytes as four 128-bit
  QEMU memory operations.
