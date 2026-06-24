# QEMU V2 EVEX Move Smoke Patch

Date: 2026-06-23
Branch: `codex/qemu-upgrade-v2`
Script: `runnable/scripts/qemu_v2_evex_move_smoke_patch.sh`
Scratch root used for validation: `/tmp/rr-qemu-v2-evex-move-smoke-dev`

## Summary

This experiment extends the exact-byte QEMU `10.2.3` EVEX smoke path beyond
`vpxorq` to one prerequisite move instruction:

- `62 f1 fd 48 ef c0`: `vpxorq zmm0,zmm0,zmm0`
- `62 f1 fd 48 6f c8`: `vmovdqa64 zmm1,zmm0`

Validation result: **PASS** for the existing single-instruction probes
`avx512-vpxorq` and `avx512-vmovdqa64` in `test/qemu-v2-probes`.

The patch remains experimental and exact-byte only. It does not implement a
general EVEX decoder, CPUID/XCR0 exposure, mask semantics, memory operands, or
general register selection.

## Patch Shape

The throwaway patch touches exactly one QEMU source file under `/tmp`:

`target/i386/tcg/decode-new.c.inc`

It adds two helpers before `disas_insn`:

- `rr_evex_exact_bytes(...)`: compares guest instruction bytes using
  `translator_ldub`.
- `rr_try_evex_move_smoke(...)`: recognizes the two exact EVEX byte strings and
  emits TCG directly.

The `disas_insn` entry path calls `rr_try_evex_move_smoke` immediately after the
usual per-instruction decode state reset and before normal byte dispatch. This
prevents the leading EVEX byte `0x62` from falling through to the legacy BOUND
decode for only these byte strings.

Emitted TCG shape:

- `vpxorq zmm0,zmm0,zmm0`: `tcg_gen_gvec_dup_imm(MO_64, xmm_regs[0], 64, 64, 0)`
- `vmovdqa64 zmm1,zmm0`: `tcg_gen_gvec_mov(MO_64, xmm_regs[1], xmm_regs[0], 64, 64)`

## Validation

Command:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
PATH=/tmp/rr-qemu-v2-upstream-probes/venv/bin:$PATH \
  bash runnable/scripts/qemu_v2_evex_move_smoke_patch.sh \
    --fresh \
    --scratch-root /tmp/rr-qemu-v2-evex-move-smoke-dev \
    --qemu-tarball /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3.tar.xz \
    --jobs 3
```

Built binary:

```text
qemu-x86_64 version 10.2.3
```

Script result:

```text
probe:        avx512-vpxorq
result:       PASS
suite_rc:     0
debug_rc:     0
vector_hits:  3
exception_hits: 0

probe:        avx512-vmovdqa64
result:       PASS
suite_rc:     0
debug_rc:     0
vector_hits:  6
exception_hits: 0

failures:     0
```

The probe-suite output confirmed both expected mnemonics by `objdump` and both
executions returned successfully under patched `qemu-x86_64`.

## TCG Ops Observed

For `avx512-vpxorq`:

```text
mov_vec v256,e8,tmp8,v256$0x0
st_vec v256,e8,tmp8,env,$0x360
st_vec v256,e8,tmp8,env,$0x380
```

For `avx512-vmovdqa64`:

```text
ld_vec v256,e8,tmp8,env,$0x360
mov_vec v256,e8,tmp9,tmp8
st_vec v256,e8,tmp9,env,$0x3a0
ld_vec v256,e8,tmp10,env,$0x380
mov_vec v256,e8,tmp11,tmp10
st_vec v256,e8,tmp11,env,$0x3c0
```

No `raise_exception`, `Illegal instruction`, `EXCP06`, or `check_exception`
markers appeared in either passing single-instruction debug log.

## Memory Move Boundary

The `vmovdqu64` memory store/load forms from the aggregate probe were not
implemented in this pass. Reasons:

- `test/qemu-v2-probes` currently has a standalone `avx512-vmovdqa64` register
  probe, but no standalone `vmovdqu64` memory store/load probes.
- The exact-byte hook runs before normal EVEX/prefix/ModRM operand decode, so a
  memory form would need a hand-decoded RIP-relative effective address.
- A correct ZMM memory form would also need 64 bytes of guest memory traffic,
  likely as four 128-bit or eight 64-bit QEMU memory operations, plus alignment
  and masking decisions.

An aggregate-probe sanity check confirmed the expected boundary. After the two
implemented instructions, `avx512-evex` still fails at the first unimplemented
memory form:

```asm
vpxorq zmm0,zmm0,zmm0
vmovdqa64 zmm1,zmm0
vmovdqu64 zmmword ptr [rip + scratch],zmm1
```

The aggregate debug log emitted vector ops for `vpxorq` and `vmovdqa64`, then:

```text
call raise_exception,$0xa,$0,env,$0x6
check_exception old: 0xffffffff new 0x6
```

## Limitations

- Exact-byte only: no alternate registers, vector lengths, masks, or EVEX
  variants are decoded.
- `vmovdqa64` only supports `zmm1,zmm0`.
- No AVX-512 CPUID/XCR0 exposure is changed.
- No memory operands are supported.
- Semantics are smoke-level only; the single `vmovdqa64` probe validates
  non-raising TCG generation, not end-to-end dataflow from initialized ZMM
  state.

## Next Instruction

The next useful instruction is the aggregate probe's first memory move:

`vmovdqu64 zmmword ptr [rip+scratch],zmm1`

Implement it only after adding or selecting a standalone memory probe, then use
an exact RIP-relative byte match as a bridge. The likely minimal implementation
is to hand-decode the fixed disp32 form and emit 64 bytes of guest stores from
`xmm_regs[1]`. The load form
`vmovdqu64 zmm2,zmmword ptr [rip+scratch]` should follow immediately after so
the aggregate probe can progress to `vpshufb`.
