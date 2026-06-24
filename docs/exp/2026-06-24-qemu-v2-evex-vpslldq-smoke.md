# QEMU v2 EVEX vpslldq smoke

Date: 2026-06-24
Branch: `codex/qemu-upgrade-v2`
Script: `runnable/scripts/qemu_v2_evex_vpslldq_smoke_patch.sh`
Fresh scratch root: `/tmp/rr-qemu-v2-evex-vpslldq-standalone-trimmed`

## Summary

This experiment tracks the exact-byte QEMU `10.2.3` EVEX smoke path to the
next aggregate boundary after `vbroadcastf64x2`:

```text
62 d1 15 48 73 fc 04    vpslldq zmm13,zmm12,0x4
```

The smoke is intentionally narrow. The old `--fresh` recursion into the
`vbroadcastf64x2` smoke script is retired. The script takes the verified
patch-series `0014` source tree via `--base-src`, copies that tree into the
current scratch area, and then overlays one exact-byte `vpslldq` hook plus
standalone probe bodies that reach that hook without depending on the
unsupported `vmovdqu64` standalone forms.

## Exact Bytes

The overlay recognizes:

```text
62 d1 15 48 73 fc 04    vpslldq zmm13,zmm12,0x4
```

The carried-forward path keeps the previously validated aggregate bytes for
`vpxorq`, `vmovdqa64`, `vmovdqu64`, `vpshufb`, `vpaddd`, `vpternlogq`,
`vpclmullqlqdq`, `vpclmullqhqdq`, `vpclmulhqlqdq`, `vpclmulhqhqdq`,
`vaesenc`, `vaesenclast`, and `vbroadcastf64x2`.

## Patch Shape

The throwaway patch touches one QEMU source file under `/tmp`:

`target/i386/tcg/decode-new.c.inc`

It adds:

- `rr_evex_pslldq_xmm_lane(...)`, which uses the existing `gen_helper_pslldq_xmm` helper.
- `rr_evex_pslldq_zmm13_zmm12_512()`, which applies the helper once per 128-bit lane.
- `rr_try_evex_vpslldq_smoke(...)`, the exact-byte dispatcher.

The lane semantics are the expected PSLLDQ behavior per 128-bit lane:

- shift left by 4 bytes within each 16-byte lane
- zero-fill the low bytes
- do not cross lane boundaries

## Validation

Runtime validation was run with:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
bash runnable/scripts/qemu_v2_evex_vpslldq_smoke_patch.sh \
  --scratch-root /tmp/rr-qemu-v2-evex-vpslldq-standalone-trimmed \
  --base-src /tmp/rr-qemu-v2-upstream-probes-full-harness-12/qemu-10.2.3-avx512-series-src \
  --jobs 3
```

This run passed the standalone probes directly on the exact-byte `vpslldq`
hook:

- `vpslldq-single`: `PASS`, `run_rc=0`, `pslldq_helper_hits=4`
- `vpslldq-chain`: `PASS`, `run_rc=0`, `pslldq_helper_hits=4`
- `vpslldq-semantic`: `SKIPPED`, semantic verification would require a
  `zmm13` store hook that is outside this exact-byte smoke
- `aggregate`: `PASS`, `run_rc=132`, `aggregate_fail_pc=40106c`

The aggregate probe still stops at the next unsupported instruction after
`vpslldq`, and the script treats that as a passing exact-byte boundary check:

```text
40106c: 62 d1 0d 48 73 dd 04    vpsrldq zmm14,zmm13,0x4
```

## Current Status

Single and chain now validate the `vpslldq` hook directly. Aggregate is
counted as pass at the expected post-`vpslldq` boundary, and semantic remains
skipped because there is no `zmm13` store hook in this smoke.

## Boundary

The exact-byte smoke remains narrow: it validates the one listed `vpslldq`
encoding and does not claim general EVEX coverage, full semantic storage, or
arbitrary operand forms.

## Limitations

This remains an exact-byte smoke patch, not a general EVEX implementation. It
does not decode arbitrary operands, masks, memory forms, VL variants, or
exception behavior beyond the single listed instruction.
