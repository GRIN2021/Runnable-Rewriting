# QEMU V2 Progress Ledger

Date: 2026-06-23
Purpose: one-page dispatch ledger for the next QEMU v2 subagents.
Evidence basis: current `docs/exp/2026-06-23-qemu-v2-*.md` reports plus
current QEMU v2 script names. This file records reported state only; it does
not add new validation.

## Current Bottom Line

This is not a complete QEMU migration. The current working state is an
experimental bridge:

- As of 2026-06-24, the PTC `runnable-lift` fast/full/trace smokes all pass on
  the replay-backed live-sidecar path, and the scripts now default to build-tree
  `runnable-lift` artifacts instead of the stale source-tree binary.

- Upstream QEMU `10.2.3` / `11.0.1` linux-user TCG still reject the aggregate
  EVEX/ZMM probe without patches because SIMD EVEX decode is missing and
  AVX-512 / VPCLMULQDQ CPUID plus AVX-512 XCR0 state are masked out.
- Exact-byte AVX-512 smoke patches have advanced the aggregate path, but they
  are not a general EVEX decoder and do not cover arbitrary operands, masks,
  memory forms, vector lengths, or exception behavior.
- The independent exact-byte smoke boundary is past `vaesenc`; the next
  reported aggregate failure is `vaesenclast`.
- The consolidated patch-series boundary is behind the independent smoke:
  patch-series is validated through `vpclmulhqhqdq` and still fails at
  `vaesenc`.
- PTC v2 is still a stub/prototype stack. The shim loads, the walker and JSON
  conversion models work for AVX2 evidence, but real non-empty
  `PTCInstructionList` translation is not migrated.

## AVX-512 Exact-Byte Ledger

Independent smoke reports mark these aggregate exact bytes as implemented:

| Order | Bytes | Instruction | Evidence state |
|---:|---|---|---|
| 1 | `62 f1 fd 48 ef c0` | `vpxorq zmm0,zmm0,zmm0` | independent smoke PASS; patch-series PASS |
| 2 | `62 f1 fd 48 6f c8` | `vmovdqa64 zmm1,zmm0` | independent smoke PASS; patch-series PASS |
| 3 | `62 f1 fe 48 7f 0d ea 0f 00 00` | `vmovdqu64 [rip+disp32],zmm1` | independent smoke PASS; patch-series PASS |
| 4 | `62 f1 fe 48 6f 15 e0 0f 00 00` | `vmovdqu64 zmm2,[rip+disp32]` | independent smoke PASS; patch-series PASS |
| 5 | `62 f2 6d 48 00 da` | `vpshufb zmm3,zmm2,zmm2` | independent smoke PASS; patch-series PASS |
| 6 | `62 f1 65 48 fe e2` | `vpaddd zmm4,zmm3,zmm2` | independent smoke PASS; patch-series PASS |
| 7 | `62 f3 dd 48 25 eb 96` | `vpternlogq zmm5,zmm4,zmm3,0x96` | independent smoke PASS; patch-series PASS |
| 8 | `62 f3 55 48 44 f4 00` | `vpclmullqlqdq zmm6,zmm5,zmm4` | independent smoke PASS; patch-series PASS |
| 9 | `62 f3 55 48 44 fc 10` | `vpclmullqhqdq zmm7,zmm5,zmm4` | independent smoke PASS; patch-series PASS |
| 10 | `62 73 55 48 44 c4 01` | `vpclmulhqlqdq zmm8,zmm5,zmm4` | independent smoke PASS; patch-series PASS |
| 11 | `62 73 55 48 44 cc 11` | `vpclmulhqhqdq zmm9,zmm5,zmm4` | independent smoke PASS; patch-series PASS |
| 12 | `62 52 35 48 dc d0` | `vaesenc zmm10,zmm9,zmm8` | independent smoke PASS only |

Next independent-smoke failure:

```text
401055: 62 72 2d 48 dd df    vaesenclast zmm11,zmm10,zmm7
```

Later aggregate queue from the inventory order:

```text
vbroadcastf64x2 zmm12,[rip+disp32]
vpslldq zmm13,zmm12,0x4
vpsrldq zmm14,zmm13,0x4
vextracti32x4 xmm15,zmm14,0x1
vextracti64x4 ymm16,zmm14,0x1
vmovdqu8 [rip+disp32],zmm14
```

Note: `2026-06-23-qemu-v2-evex-aggregate-inventory.md` is older than the latest
VPCLMUL HH and VAESENC reports. Use patch-series and independent smoke reports
as the latest boundary evidence until the inventory defaults are refreshed.

## Patch-Series Boundary

`runnable/scripts/qemu_v2_avx512_patch_series.sh` consolidates the long-running
QEMU `10.2.3` harness. Current reported content:

- `0001`: minimum TCG feature/state mask patch for `AVX512F`, `VPCLMULQDQ`,
  and AVX-512 XCR0 state.
- `0002` to `0011`: exact-byte EVEX smoke patches through
  `vpclmulhqhqdq zmm9,zmm5,zmm4`.
- Required validation matrix reports PASS for feature gate, AVX2 regression,
  and exact-byte cases through all four VPCLMUL variants.
- Aggregate boundary in patch-series is expected and observed at
  `vaesenc zmm10,zmm9,zmm8` at `0x40104f` with target SIGILL.

Not yet in patch-series:

- The independent `vaesenc` smoke report is not folded into patch-series.
- `vaesenclast`, broadcast, shift, extract, and `vmovdqu8` are not reported as
  patch-series coverage.
- Patch-series remains exact-byte smoke, not general EVEX translation.

## Docker And CI Smoke

Docker short smoke is covered by `docs/exp/2026-06-23-qemu-v2-docker-runtime-smoke.md`:

- Docker image build passed.
- Container smoke passed for AVX/AVX-512 probe compile plus `objdump`
  mnemonic checks.
- Minimal PTC shim generation, shared-object build, `make smoke`, and extra
  `dlopen` / `dlsym("ptc_load")` / `dlsym("ptc_translate")` harness passed.
- Build-wrapper `--ptc-shim-stub` path is covered and reports
  `REAL_PTC_TRANSLATION=not-migrated-empty-stub`.

Docker short smoke does not cover:

- The full long-running AVX-512 patch-series QEMU build/execution by default.
- Real PTC translation.
- Runnable-lift outer smoke in the default short container run; it was reported
  as skipped.

CI status: no current `.github` workflow evidence was found in the local file
list. Treat CI coverage as not established unless a later report or workflow
adds it.

## PTC Shim, Walker, And Conversion State

Stub/build state:

- `qemu_v2_make_ptc_shim_tree.sh` generates a standalone `/tmp` shim tree.
- The shim builds `libtinycode-x86_64.so`, exports `ptc_load` and
  `ptc_translate`, and passes load/dlopen smoke.
- `ptc_translate` deliberately returns size `0` with an empty
  `PTCInstructionList`.
- `build_qemu_libtinycode_v2.sh --ptc-shim-stub` is a reproducible transition
  path only. `--libtinycode` remains the real not-implemented migration path.

Walker/prototype state:

- The modern C-side TCG walker hook can walk `tcg_ctx->ops` after
  `translate_code` and before `tcg_gen_code`.
- AVX2 walker evidence reports 91 ops and 93 temps, including vector ops and
  temp metadata.
- Upstream AVX-512 aggregate walker evidence still only reaches the SIGILL
  fault path, not useful ZMM semantics.
- The PTC v2 manifest classifies AVX2 walker ops into direct legacy, typed
  aliases, proposed v2 ops (`extract_i64`, `qemu_ld2`, `qemu_st2`), and vector
  schema (`ld_vec`, `mov_vec`, `st_vec`).
- The JSONL converter emits a `PTCInstructionList`-like JSON model, not a real
  runnable-lift ABI. It marks entries `not_real_abi=true`, does not allocate C
  `PTCInstructionList` / `PTCTemp`, and does not wire real opcode enum values.

## Runnable-Lift State

- An empty-list guard is reported in `CodeGenerator::translate()`.
- The guard fails closed when `ptc.translate(...)` consumes `0`, returns
  `instruction_count == 0`, or returns `instructions == nullptr`.
- The empty-stub boundary smoke reports
  `RUNNABLE_LIFT_SMOKE=boundary:empty-translation` and
  `REAL_PTC_TRANSLATION=not-migrated-empty-stub`.
- This is only a safety guard. Runnable-lift still lacks PTC v2 ABI negotiation,
  v2 scalar op lowering, vector temp typing, vector operand schema, and vector
  op translation.

## Real Migration Items Still Open

- Replace exact-byte EVEX hooks with real or intentionally narrow EVEX decode
  and operand handling.
- Decide whether the CPUID/XCR0 feature-mask patch becomes a guarded runtime
  option tied to implemented EVEX coverage.
- Fold `vaesenc` into patch-series, then advance patch-series through
  `vaesenclast` and the remaining aggregate queue.
- Implement real modern QEMU `ptc_load` initialization instead of fake env
  placeholders.
- Replace empty `ptc_translate` with translate-only TB generation or equivalent
  in-tree integration.
- Replace JSONL conversion models with a real C `TCGOp -> PTCInstructionList`
  converter, including allocation/freeing, opcode enum mapping, temp IDs,
  label/control-flow handling, helper metadata, and fail-closed validation.
- Add runnable-lift support for `extract_i64`, `qemu_ld2`, `qemu_st2`, I128 /
  V128 / V256 temps, and vector schema for `ld_vec`, `mov_vec`, and `st_vec`.
- Promote Docker/CI coverage beyond short smoke to the full patch-series and
  non-empty PTC/runnable-lift path.

## Recommended Next Task Queue

1. `avx512-independent-vaesenclast`: produce a completed report for exact-byte
   `vaesenclast zmm11,zmm10,zmm7`; a script name exists, but no PASS report was
   found in `docs/exp`, so do not count it complete yet.
2. `patch-series-vaesenc`: fold the independent VAESENC smoke into
   `qemu_v2_avx512_patch_series.sh`; expected new patch-series boundary should
   become `vaesenclast`.
3. `aggregate-inventory-refresh`: update inventory defaults/status overlay so
   it reflects `vpclmulhqhqdq` and `vaesenc` correctly instead of the older
   VPCLMUL boundary.
4. `broadcast-shift-extract-vmovdqu8`: after VAESENCLAST, advance exact-byte
   smokes in aggregate order through `vbroadcastf64x2`, `vpslldq`, `vpsrldq`,
   `vextracti32x4`, `vextracti64x4`, and `vmovdqu8`.
5. `ptc-c-converter-avx2`: replace the JSON conversion model with a real C
   converter for AVX2 walker output first, with explicit reject paths for
   unhandled v2/vector schema.
6. `runnable-lift-vector-schema`: add ABI/version detection, accessor facade,
   v2 scalar opcode handling, and LLVM typing for I128/V128/V256 temps before
   attempting vector op lowering.
7. `docker-ci-long-smoke`: add an explicit long smoke target for patch-series
   QEMU build/execution and a later non-empty PTC/runnable-lift path; keep the
   short Docker smoke as a fast stub boundary check.
