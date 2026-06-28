# QEMU V2 AVX-512 Real Semantics Long-Term Plan

Date: 2026-06-27
Scope: `libcrypto.so.3` recall recovery through real backend semantics

## 1. Decision

We should move the recall fix to the long-term QEMU V2 path.

The goal is not to make the metric look good through fallback, exclusion, or
tombstone markers. The goal is to make raw no-fallback lifted IR recover the
missing instructions from real QEMU/TCG semantics, then make dynamic-parallel
coverage use that backend without reintroducing the old memory explosion.

The first acceptance target is serial raw recall. Dynamic-parallel is useful
only after the backend can already translate the hard SIMD regions; otherwise
parallel seed/range noise hides the real backend failure.

## 2. Evidence We Must Preserve

The prior "around 93% recall" result was not a completed real-semantics result:

| Result | Metric | Meaning |
|---|---:|---|
| AVX-512 exclusion | recall `0.927` | Ground-truth scope excludes the failing AVX-512 functions. Good diagnosis, not a fix. |
| Serial AVX-512 static fallback | recall `0.936385` | Missing addresses inside selected AVX-512 symbols are filled from objdump. Good upper bound, not lifted semantics. |
| Serial SIMD-heavy static fallback | recall `0.981100` | Larger static fill. Good upper bound, not lifted semantics. |
| Dynamic-parallel raw no-fallback, Ubuntu 24.04 run | precision `0.987642`, recall `0.665083` | Real lifted-only metric. This is the current problem. |
| Dynamic-parallel SIMD-heavy fallback | recall `0.864993` | Still below the historical serial fallback because range policy loses non-SIMD coverage too. |
| Dynamic-parallel all-functions fallback | recall `0.990227` | Function-range static upper bound. Not lifted semantics. |
| Dynamic-parallel all-text fallback | recall `0.998056` | Address accounting upper bound. Not lifted semantics. |

The current facts imply three separate recall buckets:

- SIMD / AVX-512 semantics are still incomplete in the real lift path.
- Dynamic-parallel `--all-symbols` with per-seed address ranges prevents broad
  AES exploration, but also misses cross-function and no-symbol `.text` code.
- Small functions and symbol gaps are still outside the seed/fallback model;
  the latest all-text fallback leaves `1321` mnemonic mismatches at addresses
  already present in lifted output.

## 3. Current QEMU V2 Boundary

QEMU V2 has made real progress, but it is not production-complete:

- `runnable/scripts/qemu_v2_avx512_patch_series.sh` now validates exact-byte
  AVX-512 smoke hooks through the aggregate probe from `vpxorq` to `vmovdqu8`.
- Broader exact-byte standalone forms for `vaesenc zmm1,zmm0,zmm0` and
  `vpclmullqlqdq zmm1,zmm0,zmm0` were added and pass.
- The patch series is still exact-byte matching. It is not a general EVEX
  decoder and does not cover arbitrary registers, masks, memory forms, vector
  lengths, or exception behavior.
- The PTC live-sidecar smoke can rebuild a non-empty `PTCInstructionList`, but
  that is still a sidecar bridge/prototype, not an in-process production
  `libtinycode-x86_64.so`.
- Ubuntu 24.04 / LLVM 18 `runnable-lift` can build and a fresh bzip O2 lift now
  succeeds with the real legacy PTC runtime, but QEMU V2 `libtinycode` is not
  fully migrated for libcrypto.

Therefore the long-term path is:

1. Make QEMU V2 EVEX support operand-aware for the libcrypto instruction
   families.
2. Replace sidecar/stub PTC with an in-process, versioned PTC V2 ABI.
3. Add runnable-lift lowering for the V2 scalar/vector schema.
4. Pass serial libcrypto raw no-fallback first.
5. Rebuild dynamic-parallel coverage only after serial raw passes.

## 4. Non-Goals

- Do not count static fallback, all-text fill, AVX-512 exclusion, or tombstone
  markers as the final success criterion.
- Do not claim "QEMU V2 complete" from subset canonical PASS rows.
- Do not make dynamic-parallel the primary backend acceptance test.
- Do not overexpose CPUID/XCR0 bits unless the corresponding EVEX instruction
  families are implemented or fail closed.
- Do not silently emit empty `PTCInstructionList` output. Empty V2 translation
  must remain a hard failure outside explicit stub-smoke tests.

## 5. Success Gates

| Gate | Minimum | Target |
|---|---:|---:|
| EVEX probe matrix | no SIGILL for supported family variants | operand matrix passes for register/memory, high registers, and representative masks |
| PTC V2 translation | non-empty in-process `PTCInstructionList` for scalar, AVX2, and AVX-512 probes | no sidecar dependency; ABI metadata records schema and QEMU commit |
| Runnable-lift V2 lowering | probe `.ll` contains expected instruction addresses and no unsupported-vector tombstones | lifted vector ops/helpers typecheck under LLVM 18 |
| Serial libcrypto raw no-fallback recall | `>= 0.92` | `>= 0.95` |
| Serial libcrypto raw precision | `>= 0.90` | `>= 0.93` before optional data filters |
| Two AES-GCM AVX-512 functions | `>= 90%` FN reduction | `>= 98%` FN reduction |
| Dynamic-parallel raw no-fallback recall | `>= 0.90` after serial gate | `>= 0.95` with bounded memory |
| Dynamic-parallel raw precision | `>= 0.93` | `>= 0.95` |

The serial recall minimum is set to `0.92` because previous exclusion/fallback
experiments already show that the missing region is recoverable in the address
space. A real backend fix should recover it without changing the metric scope.

## 6. Architecture

### 6.1 Backend Layout

Keep the legacy backend as a regression oracle:

```text
archive/qemu-legacy-2.4.50/   # archived legacy QEMU 2.4.50 backend reference
third_party/qemu-v2-src/       # reproducible QEMU 10.2.3 source checkout, or equivalent external cache
docker/qemu-v2-runtime/        # Ubuntu 24.04 / LLVM 18 runtime
runnable/scripts/qemu_v2_*     # build, probe, and migration harnesses
test/qemu-v2-probes/           # source-only probe corpus
```

If `qemu-v2/` is eventually vendored, it must be reproducible from an upstream
release plus patch series. Until then, the scripts must record QEMU version,
source path, patch set, build path, and output artifact paths.

### 6.2 EVEX Implementation Rule

The exact-byte patch series is evidence and a safety net, not the final design.
For each supported instruction family, the implementation must move from
literal byte strings to operand-aware decode:

- decode EVEX prefix fields, ModRM, SIB, displacement, immediate, vector length,
  destination/source register IDs, and memory operands;
- support the libcrypto-observed register and memory forms first;
- explicitly reject unimplemented masks, broadcast forms, or vector lengths with
  a classified failure instead of pretending success;
- use QEMU helpers where available for AES and PCLMUL semantics;
- emit TCG ops that the PTC V2 converter and runnable-lift can lower.

Initial supported families:

```text
vpxorq, vmovdqa64, vmovdqu64, vmovdqu8,
vpshufb, vpaddd, vpternlogq,
vpclmullqlqdq, vpclmullqhqdq, vpclmulhqlqdq, vpclmulhqhqdq,
vaesenc, vaesenclast,
vbroadcastf64x2, vpslldq, vpsrldq,
vextracti32x4, vextracti64x4
```

### 6.3 PTC V2 ABI

`archive/qemu-legacy-2.4.50/linux-user/ptc.h` remains the V1 ABI reference. V2
must be explicit and versioned:

- `ptc_get_abi_metadata()` reports `abi_version`, `backend_id`, QEMU version,
  QEMU commit/source hash, vector schema version, and `real_translation=true`.
- `ptc_translate()` returns a non-empty `PTCInstructionList` or a structured
  failure; it must not silently return an empty list for real V2 runs.
- `PTCInstructionList` allocation/free ownership is documented and tested.
- Modern TCG ops are converted in C, in-process, not by JSONL as the production
  path.
- The converter records opcode enum mapping, temp IDs, temp types, labels,
  helper calls, memory ops, and instruction address markers.
- Unsupported V2 ops fail closed with opcode/temp context.

### 6.4 Runnable-Lift V2 Adapter

`runnable/tools/runnable-lift` should consume V2 through a narrow adapter:

- `PTCInterface.h`: ABI metadata negotiation and capability checks.
- `InstructionTranslator.cpp`: V2 scalar op aliases, vector ops, helper calls,
  and fail-closed unsupported op handling.
- `VariableManager.cpp`: I128/V128/V256/V512 temp type mapping and LLVM 18
  opaque-pointer-safe value creation.
- `CodeGenerator.cpp`: empty-list rejection, vector helper declarations,
  address comment preservation, and per-block diagnostics.
- `JumpTargetManager.cpp`: keep original instruction address registration
  stable for compare tooling.

This adapter must keep V1 runnable for A/B comparison until V2 has passed the
libcrypto gates.

### 6.5 Dynamic-Parallel Coverage

Dynamic-parallel should become a coverage strategy, not a backend workaround.
After serial V2 passes:

- keep per-seed ranges for expensive AES/SIMD functions to bound memory;
- add a separate queue for small ELF functions below the current size cutoff;
- add no-symbol `.text` interval seeds for gaps not covered by ELF `FUNC`
  ranges;
- allow selected cross-function expansion only for call targets that stay in
  `.text` and do not enter known high-explosion regions;
- record seed class, range policy, branch budget, timeout, and backend ID in
  the run manifest;
- merge by address with deterministic duplicate and mismatch accounting.

## 7. Phased Execution Plan

### Phase 0: Metric Freeze

Duration: 0.5-1 day.

Tasks:

- Create one current metrics ledger that distinguishes raw, exclusion, static
  fallback, all-functions fallback, and all-text fallback.
- Regenerate or link the current compare artifacts for:
  - serial raw no-fallback;
  - dynamic-parallel raw no-fallback;
  - dynamic-parallel fallback upper bounds.
- Add a manifest field for `backend_id`, `ptc_abi_version`,
  `real_translation`, and static fallback profile.

Exit criteria:

- Everyone can answer "which recall number is real raw semantics?" from one
  document.
- Any run with fallback is labeled as fallback in JSON, text, and markdown
  reports.

### Phase 1: Reproducible QEMU V2 Runtime

Duration: 1-3 days.

Tasks:

- Make `docker/qemu-v2-runtime/` the default build/runtime surface for V2.
- Make `runnable/scripts/build_qemu_libtinycode_v2.sh` record QEMU version,
  source hash, patch series hash, and `REAL_PTC_TRANSLATION`.
- Keep `qemu_v2_avx512_patch_series.sh --fresh` as a long validation target.
- Keep short smoke fast, but add an explicit long smoke that runs the AVX-512
  patch series and probe suite.

Exit criteria:

- Fresh runtime build can reproduce the current AVX-512 exact-byte patch-series
  PASS.
- V2 artifacts cannot be confused with legacy `libtinycode` artifacts.

### Phase 2: Replace Exact-Byte EVEX Hooks With Operand-Aware Support

Duration: 1-2 weeks.

Tasks:

- Generate an EVEX operand inventory from canonical `libcrypto.so.3` objdump and
  QEMU probe failures.
- For each initial family, implement decode by mnemonic family and operand
  fields rather than exact instruction bytes.
- Gate CPUID/XCR0 exposure behind implemented family coverage.
- Expand `test/qemu-v2-probes/` into an operand matrix:
  - low and high ZMM registers;
  - register-register and memory forms;
  - RIP-relative and base+disp memory;
  - immediate variants for ternlog, pclmul, shifts, and extracts;
  - unsupported mask cases that must fail closed.

Exit criteria:

- The supported families no longer rely on exact PC/byte-string matchers.
- The operand matrix passes under QEMU V2 with no unclassified SIGILL.
- Unsupported forms produce classified failures, not silent skips.

### Phase 3: Production In-Process PTC V2 Translation

Duration: 1 week.

Tasks:

- Move the live-sidecar translation proof into an in-process `libtinycode` path.
- Replace JSONL/model conversion with a C `TCGOp -> PTCInstructionList`
  converter.
- Implement allocation/free tests using the exact `qemu/linux-user/ptc.h` ABI.
- Preserve original instruction address markers and TB boundaries.
- Add converter support for observed V2 ops:
  `extract_i64`, `qemu_ld2`, `qemu_st2`, vector loads, vector moves, vector
  stores, helper calls, labels, and branches.

Exit criteria:

- `ptc_translate()` returns non-empty lists for scalar, AVX2, and AVX-512 probe
  blocks without shelling out to a sidecar.
- Empty-stub metadata is impossible in normal V2 runs.
- Converter failures report opcode, temp, and source PC context.

### Phase 4: Runnable-Lift Vector Lowering

Duration: 1 week.

Tasks:

- Add ABI/version negotiation in `PTCInterface.h`.
- Add vector temp typing and LLVM 18-safe construction in `VariableManager.cpp`.
- Lower V2 scalar aliases and vector schema in `InstructionTranslator.cpp`.
- Wire helper declarations and vector helper calls in `CodeGenerator.cpp`.
- Preserve compare comments in `.ll` for every translated instruction address.

Exit criteria:

- Probe `.ll` output typechecks under LLVM 18.
- Probe compare sees expected instruction addresses without tombstones.
- Unsupported vector ops abort with structured diagnostics.

### Phase 5: Probe-To-LL Validation Matrix

Duration: 3-5 days.

Tasks:

- For every probe, validate four layers:
  1. objdump expected mnemonic and address;
  2. QEMU V2 execution has no unexpected SIGILL/fault;
  3. `ptc_translate()` returns a non-empty list with expected ops;
  4. runnable-lift `.ll` contains expected address comments and typechecks.
- Add native-vs-QEMU output comparison where the host supports the instruction.
- Add log parsing for helper hits, exception hits, final PC, and PTC list size.

Exit criteria:

- Probe failures identify the failing layer.
- All initial AVX-512 families pass through final `.ll`, not only QEMU execution.

### Phase 6: Serial Libcrypto Raw Campaign

Duration: 3-5 days for the first run, then iterate until gate.

Tasks:

- Run canonical serial libcrypto with V2 and no fallback.
- Report:
  - all-GT precision/recall;
  - AVX-512-only precision/recall;
  - non-AVX-512 precision/recall;
  - FN by function and mnemonic;
  - FP categories;
  - illegal entries and converter failures.
- If recall is below `0.92`, route the top FN families back to Phase 2 or Phase
  4; do not patch evaluation first.

Exit criteria:

- Serial raw recall `>= 0.92`, precision `>= 0.90`.
- The two AES-GCM AVX-512 functions no longer dominate FN.
- There is a written residual FN/FP ledger with exact next families.

### Phase 7: Dynamic-Parallel Coverage Redesign

Duration: 1 week after Phase 6 passes.

Tasks:

- Split seeds into classes:
  - exported symbols;
  - all ELF `FUNC` symbols;
  - small functions below `DEFAULT_MIN_FUNCTION_SIZE`;
  - no-symbol `.text` intervals;
  - selected call-target expansions.
- Assign range/timeout/branch-budget policy per class.
- Keep AES/SIMD-heavy functions on bounded ranges or serial-special handling.
- Merge by address and record mismatch provenance.
- Compare raw no-fallback first; fallback profiles remain upper-bound reports.

Exit criteria:

- Dynamic-parallel raw recall `>= 0.90` without 48 GiB memory failure.
- Precision remains `>= 0.93`.
- Remaining missed addresses are bucketed into semantic, coverage, or mismatch
  causes.

### Phase 8: CI And Reproducibility

Duration: 2-3 days.

Tasks:

- Add fast CI/smoke:
  - build runnable-lift V2;
  - run scalar and AVX2 probes;
  - verify empty-stub rejection.
- Add opt-in long CI/local command:
  - build QEMU V2 patch series;
  - run AVX-512 operand matrix;
  - run PTC-to-LL probe validation;
  - optionally run serial libcrypto subset.
- Store summaries under `docs/exp/` with exact artifact paths.

Exit criteria:

- A fresh machine can rebuild V2 and reproduce probe PASS without reading chat
  history.
- Long smoke catches regression from operand-aware EVEX, PTC ABI, and
  runnable-lift lowering.

### Phase 9: Rollout

Duration: 1-2 days.

Tasks:

- Keep `qemu-v1` and `qemu-v2` selectable by explicit backend ID.
- Make run manifests reject mixed V1/V2 artifacts.
- Update `docs/qemu-v2-runnable-reproduce.md` with the final build/eval path.
- Only switch default backend after serial and dynamic raw gates pass.

Exit criteria:

- V2 can replace V1 for libcrypto without fallback to pass recall.
- V1 remains available for regression comparison until V2 has multiple binary
  confirmations beyond libcrypto.

## 8. Immediate Task Queue

1. Write `docs/exp/<date>-libcrypto-metric-ledger.md` with one table for raw,
   exclusion, fallback, and upper-bound metrics.
2. Extend the AVX-512 probe corpus from 6 files to the operand matrix required
   by Phase 2.
3. Convert two existing exact-byte families first:
   `vaesenc` and `vpclmullqlqdq`, because broader standalone exact forms already
   exposed the current generalization gap.
4. Add CPUID/XCR0 capability metadata that names exactly which EVEX families are
   implemented.
5. Replace the live-sidecar `PTCInstructionList` path with an in-process
   converter for AVX2 first, then AVX-512.
6. Add runnable-lift V2 ABI negotiation and reject unsupported vector schema
   before attempting broad lowering.
7. Lower `extract_i64`, `qemu_ld2`, `qemu_st2`, vector load/move/store, AES, and
   PCLMUL helper shapes observed in the walker inventory.
8. Run serial libcrypto raw no-fallback and route top FN back to EVEX or
   lowering work.
9. Only after serial passes, implement small-function and no-symbol seed queues
   for dynamic-parallel.
10. Add long smoke to the Ubuntu 24.04 runtime so the exact patch/probe/PTC/LL
    chain is reproducible.

## 9. Risk Register

| Risk | Impact | Mitigation |
|---|---|---|
| Exact-byte hooks appear green but fail real libcrypto variants | False confidence | Require operand matrix and objdump-derived libcrypto inventory before serial gate |
| CPUID/XCR0 exposes unsupported forms | Guest paths enter fake support or crash | Capability gating by implemented family; unsupported forms fail closed |
| PTC V2 ABI mismatch crashes runnable-lift | Hard-to-debug runtime failures | Versioned metadata, allocation/free tests, strict empty-list rejection |
| Vector lowering becomes too broad at once | Type bugs and silent bad IR | Lower observed ops first; every unsupported op aborts with opcode/temp/PC context |
| Dynamic-parallel broad `.text` exploration explodes memory | Repeats 48 GiB failure | Seed class policies, bounded AES ranges, branch budgets, serial gate first |
| Fallback metrics get mixed into raw claims | Misleading progress | Manifest fields and reports must label fallback; final gates use raw only |

## 10. Definition Of Done

The long-term recall fix is done when all of the following are true:

- QEMU V2 supports the libcrypto AVX-512 instruction families with operand-aware
  semantics, not exact-byte-only smoke hooks.
- `ptc_translate()` produces in-process non-empty `PTCInstructionList` output
  for scalar, AVX2, and AVX-512 probes.
- runnable-lift lowers the V2 vector schema into LLVM 18-valid `.ll`.
- Serial libcrypto raw no-fallback recall is at least `0.92` with precision at
  least `0.90`.
- Dynamic-parallel raw no-fallback recall is at least `0.90` without the broad
  AES memory explosion.
- Fallback/exclusion/all-text reports remain available only as upper bounds and
  diagnostics, not completion evidence.
