# QEMU Upgrade V2 Plan

Date: 2026-06-23
Branch: `codex/qemu-upgrade-v2`

## 1. Objective

Build a new upgraded `runnable-rewriting` branch whose primary fix is replacing the
current patched QEMU 2.4.50 / `libtinycode-x86_64.so` backend with a modern QEMU
backend that can correctly translate and execute the x86-64 instructions that now
drive most false negatives and some downstream false positives.

The upgrade must be treated as a real backend replacement, not only an evaluation
filter. Tombstone markers and FP filters are useful as diagnostics or temporary
guardrails, but the V2 success criterion is that the lifted IR is produced from
real QEMU/TCG semantics for the problematic instruction families.

## 2. Current Evidence

The current repository uses QEMU `2.4.50` (`qemu/VERSION`) with a custom
`x86_64-libtinycode` target and a PTC bridge implemented mainly in
`qemu/linux-user/ptc.c`, `qemu/linux-user/ptc.h`, and
`qemu/target-i386/translate.c`.

The experimental reports under `docs/exp/` show the main failure modes:

| Area | Evidence | Impact |
|---|---:|---|
| Serial libcrypto lift | Precision `0.9107`, recall `0.7799` | Good precision, unacceptable recall |
| AVX-512 concentration | About `103K / 149K` FN in `ossl_aes_gcm_encrypt_avx512` and `ossl_aes_gcm_decrypt_avx512` | Dominant recall loss |
| AVX-512 exclusion | Recall rises to `0.927`; excluding all SIMD-heavy functions reaches `0.971` | Backend instruction support is the bottleneck |
| Parallel lift | Precision `0.7104`, recall `0.6714`, FP `185,986`, FN `223,317` | Parallel exploration is not the right first fix |
| Build environment | Host-built `runnable-lift` fails inside bionic due `GLIBC_2.34` / `GLIBCXX_3.4.32` | Builder/runtime must be unified |

The AVX-512 root cause is already visible in the patched translator:

- `0x62` EVEX prefixes are partially decoded in `qemu/target-i386/translate.c`.
- `case 0x200 ... 0x2ff` calls `ptc_evex_tail_bytes(...)`.
- Supported EVEX instructions are only consumed by advancing `s->pc`.
- No TCG operations are emitted for those instructions.
- Unsupported EVEX opcodes still go to `illegal_op`.

This means known EVEX bytes can disappear from `PTCInstructionList` and from the
final `.ll`; skipped semantics can also corrupt later execution and produce
secondary misses or bad paths.

## 3. Upgrade Scope

### In Scope

- Introduce a modern QEMU source baseline for `x86_64-libtinycode`.
- Preserve or version the existing PTC ABI used by `runnable-lift`.
- Rebuild `libtinycode-x86_64.so` and `libtinycode-helpers-x86_64.ll` from the
  upgraded backend.
- Make `runnable-lift` load the new backend in the same container/runtime where
  it is executed.
- Validate AVX/AVX2/AVX-512 instruction coverage with small probes before running
  full `libcrypto.so.3`.
- Re-run canonical libcrypto evaluation with the existing contract:
  `runnable/scripts/run_cmp_eval.py`,
  `runnable/scripts/validate_libcrypto_ground_truth.py`, `.text` start `0xcef80`,
  runnable base `0x50000000`.

### Out Of Scope For The First V2 Milestone

- Making dynamic-parallel the default path. Serial lift must be fixed first.
- Claiming better recall by excluding AVX-512 from GT.
- Claiming better precision solely by LLM data filtering.
- Rewriting the full `runnable-lift` IR generator unless modern TCG op drift
  forces targeted compatibility changes.

## 4. QEMU Baseline Choice

The current patched QEMU is from 2015. The official QEMU download page lists
`11.0.1` as the latest source release on 2026-05-25 and also lists maintained
`10.2.3` and `10.1.5` releases near the current date:
https://www.qemu.org/download/

Use a two-step baseline decision:

| Candidate | Role | Rationale |
|---|---|---|
| QEMU `10.2.3` | Primary implementation target | Recent stable line, likely enough x86 SIMD/EVEX coverage, slightly less churn than the newest major |
| QEMU `11.0.1` | Reference/capability target | Latest upstream behavior for instruction probes and source comparison |
| QEMU `6.2.x` | Fallback target only | Smaller migration gap if modern build/runtime constraints block progress; must pass EVEX probes before use |

Decision gate: run the AVX-512 probe suite against unmodified upstream QEMU
linux-user for `10.2.3` and `11.0.1`. If `10.2.3` passes all required probes,
stay there. If it fails and `11.0.1` passes, move the implementation target to
`11.0.1`. If both are blocked by build/runtime constraints, evaluate `6.2.x`
only as a fallback.

### 2026-06-23 Probe Result Update

The decision gate has now been run and recorded in
`docs/exp/2026-06-23-qemu-v2-upstream-baseline-probe.md`:

- QEMU `10.2.3` and `11.0.1` can both be downloaded, configured, and built as
  `x86_64-linux-user`.
- Both candidates pass the AVX2/VEX probe.
- Both candidates fail the AVX-512/EVEX probe with target `SIGILL`, even when
  run with explicit `SapphireRapids` / `max` CPU settings.

Updated decision:

- Keep QEMU `10.2.3` as the practical source baseline because it builds cleanly
  and `11.0.1` does not improve the decisive AVX-512 result.
- Keep QEMU `11.0.1` as a reference source for API/capability comparison.
- Insert an explicit **EVEX/AVX-512 TCG enablement spike** before the full PTC
  port. A plain upstream QEMU replacement is not enough to resolve the current
  AVX-512 false negatives.

## 5. Architecture

### 5.1 Source Layout

Do not overwrite the current `qemu/` directory in the first pass. It is the
working legacy backend and contains the patch inventory needed for porting.

Recommended branch layout:

```text
qemu/                         # legacy QEMU 2.4.50 backend, kept as reference
qemu-v2/                      # modern QEMU baseline plus V2 PTC/libtinycode patches
runnable/scripts/
  build_qemu_libtinycode_v2.sh
  build_runnable_lift_v2.sh
  qemu_v2_probe_suite.py
docs/
  plan-qemu-upgrade-v2.md
  exp/<new V2 reports>
```

If repository size or history policy makes vendoring `qemu-v2/` undesirable,
use a scripted external checkout under `third_party/qemu-v2-src/` or a git
subtree. The important requirement is that the exact source revision and patch
series are reproducible from the branch.

### 5.2 Stable PTC Boundary

Treat `qemu/linux-user/ptc.h` as the V1 ABI consumed by `runnable-lift`.
Create an explicit V2 compatibility boundary instead of allowing modern QEMU
internals to leak into `runnable/tools/runnable-lift`.

Required exports for parity:

- `ptc_load`
- `ptc_translate`
- `ptc_exec`, `ptc_exec1`, `ptc_exec2`
- `ptc_mmap`, `ptc_unmmap`, `ptc_cleanLowAddr`
- `ptc_storeCPUState`, `ptc_dropCPUState`, `ptc_queueDepth`
- branch/state helpers used by dynamic-parallel mode
- `ptc_disassemble` and `ptc_disassemble_bytes`
- helper metadata, opcode metadata, env offsets, and global register pointers

Additive V2 fields are allowed only behind capability/version checks. Existing
V1 function pointer order and struct layout should stay stable until
`runnable-lift` has a deliberate adapter.

### 5.3 Modern QEMU Adapter

The old `ptc.c` relies on QEMU 2.4 globals such as `tcg_ctx` and old
translation-block internals. Modern QEMU has changed these APIs substantially.
The V2 port should isolate those changes in a narrow adapter:

- `ptc_translate`: initialize a modern `TranslationBlock`, run x86 translation,
  and dump modern `TCGOp` into `PTCInstructionList`.
- `dump_tinycode`: map modern TCG opcode definitions, temps, constants, calls,
  labels, and memory ops to the existing PTC representation.
- `ptc_exec*`: execute translated blocks and preserve the current branch
  exploration behavior expected by `runnable-lift`.
- state cloning: replace direct `CPUState` / `CPUX86State` assumptions with
  modern QEMU APIs where available.
- signal/fault handling: preserve `illegalEntry.log`, bad block suppression,
  and unknown address reporting semantics used by current evaluation tooling.

### 5.4 Build And Runtime

The V2 backend must avoid the current host/container ABI mismatch.

Acceptable implementation paths:

1. Build both `runnable-lift` and `libtinycode-v2` inside a single upgraded
   runtime image.
2. Keep the bionic runtime only if modern QEMU and all dependencies can be
   built there without linking against newer host glibc/libstdc++.

Path 1 is more maintainable if QEMU `10.x/11.x` requires newer Meson, Python, or
compiler versions. If the runtime image changes, rebuild LLVM 7 / Boost / QEMU
dependencies in that image or create a new reproducible dependency layer.

## 6. Implementation Phases

### Phase 0: Baseline Freeze And Patch Inventory

Deliverables:

- Current branch status report.
- Legacy patch inventory for:
  - `qemu/linux-user/ptc.c`
  - `qemu/linux-user/ptc.h`
  - `qemu/target-i386/translate.c`
  - `support/components/qemu.mk`
  - `runnable/tools/runnable-lift/PTCInterface.h`
  - dynamic-parallel changes that depend on `queueDepth` and `dropCPUState`
- Reproducible baseline metrics copied into a V2 report:
  - serial canonical metrics
  - parallel canonical metrics
  - AVX-512 FN breakdown
  - known build/runtime failure mode

Exit criteria:

- A reviewer can see exactly which legacy behaviors must be preserved.
- The baseline report can be regenerated from scripts, not only from notes.

### Phase 1: Upstream QEMU Intake

Tasks:

- Add or script a modern QEMU source checkout.
- Verify source authenticity through release tarball signatures if using
  tarballs.
- Build unmodified `x86_64-linux-user` for the chosen candidate.
- Run a native-vs-QEMU probe suite for the problematic instructions.

Probe instruction families:

- `vpxorq`
- `vaesenc`
- `vaesenclast`
- `vbroadcastf64x2`
- `vpternlogq`
- `vpclmullqlqdq`, `vpclmullqhqdq`, `vpclmulhqlqdq`, `vpclmulhqhqdq`
- `vmovdqu64`, `vmovdqa64`, `vmovdqu8`
- `vpshufb`
- `vpslldq`, `vpsrldq`
- `vextracti32x4`, `vextracti64x4`

Exit criteria:

- Selected upstream baseline executes the probe binaries without `SIGILL`.
- Probe outputs match native execution where native hardware supports the
  instruction; otherwise compare against an objdump/capstone decode and QEMU
  successful execution.

### Phase 2: `x86_64-libtinycode` Target Bootstrap

Tasks:

- Add a V2 `x86_64-libtinycode` build target in the modern QEMU build system.
- Produce `libtinycode-x86_64.so`.
- Produce or adapt `libtinycode-helpers-x86_64.ll`.
- Export `ptc_load` from the shared object.
- Make `runnable-lift` find V2 runtime assets via a deterministic path.

Build script target:

```bash
runnable/scripts/build_qemu_libtinycode_v2.sh \
  --qemu-src qemu-v2 \
  --build-dir build-qemu-v2 \
  --install-dir root-qemu-v2
```

Exit criteria:

- `dlopen(root-qemu-v2/lib/libtinycode-x86_64.so)` succeeds inside the runtime
  container.
- `dlsym("ptc_load")` succeeds.
- `runnable-lift --help` still works with the V2 library path present.

### Phase 3: PTC Translation Port

Tasks:

- Port `ptc_translate` to modern QEMU translation APIs.
- Port `dump_tinycode` from old `TCGContext` arrays to modern `TCGOp` lists.
- Generate `PTCOpcodeDef` and helper metadata compatible with
  `InstructionTranslator.cpp`.
- Add an opcode compatibility map if modern TCG renamed, split, or removed ops
  used by `runnable-lift`.
- Preserve instruction address markers so `.ll` comments remain comparable with
  `objdump` and existing evaluators.

Exit criteria:

- A scalar x86-64 smoke binary lifts to `.ll`.
- Existing non-SIMD smoke tests still produce instruction comments.
- PTC instruction list is non-empty for AVX-512 probe blocks.

### Phase 4: PTC Execution And State Port

Tasks:

- Port user-mode loader initialization from old `ptc_init`.
- Port memory mapping helpers.
- Port CPU state clone/store/drop queues needed by dynamic branch exploration.
- Port stack recovery helpers.
- Preserve bad address, illegal entry, and fault logging behavior.
- Confirm PC/SP/register offsets consumed by `runnable-lift` are correct for
  modern `CPUX86State`.

Exit criteria:

- `ptc_exec` and `ptc_translate` agree on next PC for straight-line probes.
- Branch probes exercise both direct and indirect control flow.
- Fault logs use the same filenames and address formats as current scripts
  expect.

### Phase 5: Runnable-Lift Integration

Tasks:

- Add `build_runnable_lift_v2.sh` or extend the current bionic build script with
  a `--qemu-v2-prefix` argument.
- Make `findFiles(...)` prefer explicit V2 paths when provided.
- Keep legacy QEMU as a fallback path for A/B comparison.
- Update `runnable/scripts/libcrypto_dynamic_parallel_lift.py` staging logic so
  `--libtinycode-path` and `--libtinycode-helpers-path` can select V2 assets.
- Add a `--backend-id` or metadata field in run manifests to prevent mixing V1
  and V2 results.

Exit criteria:

- One command builds runnable-lift and V2 libtinycode in the selected runtime.
- Run manifests record the QEMU version, commit, backend path, and PTC ABI
  version.

### Phase 6: Instruction Probe Suite

Tasks:

- Add a small assembly/C probe corpus under `test/qemu-v2-probes/`.
- For each probe:
  - compile binary
  - objdump `.text`
  - run `runnable-lift`
  - assert expected instruction addresses appear in `.ll`
  - assert no `illegalEntry.log` for supported instructions
  - optionally compare native and QEMU execution output

Exit criteria:

- All listed AVX-512 probe mnemonics appear in lifted `.ll`.
- No probe is represented as a no-op tombstone unless explicitly marked
  diagnostic-only.
- Probe suite runs in CI or a documented local container command.

### Phase 7: Canonical Libcrypto Evaluation

Run serial lift first. Do not use dynamic-parallel to judge the backend upgrade.

Canonical inputs:

- Binary:
  `../GroudTruth/groundtruth-gap-analysis-skill/results/libcrypto-artifacts/libcrypto.so.3`
- Ground truth:
  `../GroudTruth/groundtruth-gap-analysis-skill/results/libcrypto-artifacts/libcrypto.gtBlock.pb`
- Compare:
  `runnable/scripts/run_cmp_eval.py`
- Audit:
  `runnable/scripts/validate_libcrypto_ground_truth.py`

Evaluation commands should resolve paths through:

```bash
python3 runnable/scripts/libcrypto_bench_paths.py binary --must-exist
python3 runnable/scripts/libcrypto_bench_paths.py groundtruth-pb --must-exist
python3 runnable/scripts/libcrypto_bench_paths.py text-start
```

Metrics to report:

- all-GT precision/recall
- AVX-512 function-only precision/recall
- non-AVX-512 precision/recall
- FN by function and mnemonic
- FP by category: mid-instruction overlap, inline data, mismatch, unknown
- runtime, memory peak, timeout count
- illegal entry count

Exit criteria for V2 backend milestone:

| Metric | Minimum acceptable | Target |
|---|---:|---:|
| All-GT recall | `>= 0.92` | `>= 0.95` |
| AVX-512 FN reduction in the two AES-GCM functions | `>= 90%` | `>= 98%` |
| Precision | `>= 0.90` | `>= 0.93` before optional data filters |
| Known EVEX illegal entries | `0` for probe list | `0` |
| Serial runtime | No hard regression beyond `2x` baseline without explanation | Near baseline |

The `0.92` recall minimum is chosen because the existing report already reaches
`0.927` by excluding AVX-512 functions. A real QEMU upgrade should at least
recover that missing region without excluding it.

### Phase 8: FP Cleanup After Backend Fix

Only after serial recall improves, revisit precision. The known FP sources are:

- inline data / jump tables
- mid-instruction overlap
- speculative dynamic-parallel exploration
- mnemonic mismatch between objdump and `.ll` comments

Allowed cleanup:

- deterministic overlap pruning
- deterministic inline-data heuristics
- LLM data filter as a reporting/post-process experiment with replayable JSON

Do not hide backend failures by filtering `.ll` before root-cause accounting.

### Phase 9: Dynamic-Parallel Reassessment

Once serial V2 is validated:

- rerun per-function dynamic-parallel with V2 backend
- rerun dynsym/worklist mode with `.text` bounds
- measure whether instruction support reduces timeouts or branch explosion
- tune branch-depth limits only after backend correctness is established

Parallel mode should remain an optimization/coverage experiment, not the first
acceptance gate for QEMU V2.

## 7. Risk Matrix

| Risk | Severity | Mitigation |
|---|---:|---|
| Modern QEMU TCG internals differ too much from 2.4 | High | Port through a narrow adapter; spike `ptc_translate` and `dump_tinycode` before full exec |
| Modern QEMU cannot build in bionic | High | Move to a unified newer runtime image; rebuild LLVM/Boost deps there |
| Modern TCG opcode set breaks `InstructionTranslator` | High | Generate opcode diff; add compatibility mapping; update translator only for observed ops |
| ZMM/YMM/XMM state layout differs from current assumptions | High | Add offset assertions and execution probes that read/write vector state |
| AVX-512 executes but generated PTC list loses address markers | Medium | Make address-marker preservation an explicit probe assertion |
| New backend increases FP by exploring more code/data | Medium | Categorize FP after recall fix; do not optimize precision blindly |
| External GT artifacts missing | Medium | Keep path resolver checks and fail early with actionable messages |
| Runtime becomes too slow | Medium | Profile after correctness gates; keep V1 fallback for A/B comparisons |
| Dynamic-parallel queue semantics regress | Medium | Keep dynamic-parallel tests separate from serial acceptance; preserve `queueDepth`/`dropCPUState` API |

## 8. Rollback And Fallback Strategy

Keep three backend modes available during development:

| Mode | Purpose |
|---|---|
| `qemu-v1` | Current QEMU 2.4.50 backend for baseline and regression comparison |
| `qemu-v1-evex-marker` | Optional diagnostic branch if a quick recall accounting fix is needed |
| `qemu-v2` | Real modern QEMU backend |

If V2 port blocks for more than one milestone:

1. Land the probe suite and baseline report anyway.
2. Add the minimal EVEX marker path only as a clearly labeled diagnostic mode.
3. Use filtered metrics only to guide prioritization, not as final claims.

## 9. Proposed Work Breakdown

| Phase | Estimate | Main Output |
|---|---:|---|
| Phase 0: baseline freeze | 1-2 days | Patch inventory and reproducible baseline report |
| Phase 1: QEMU intake | 2-3 days | Selected upstream baseline and probe execution result |
| Phase 2: libtinycode bootstrap | 3-5 days | V2 shared library with `ptc_load` |
| Phase 3: PTC translation port | 5-8 days | PTC lists from modern TCG |
| Phase 4: PTC execution/state port | 4-7 days | Runnable execution and branch state parity |
| Phase 5: runnable-lift integration | 2-3 days | One-command V2 build and staging |
| Phase 6: probe suite | 2-3 days | Automated SIMD/EVEX gate |
| Phase 7: libcrypto eval | 2-3 days | Canonical V2 metrics report |
| Phase 8-9: cleanup and parallel reassessment | 3-6 days | Precision cleanup and parallel follow-up |

Expected total: roughly 4-6 engineering weeks depending on QEMU API churn and
runtime image work.

## 10. First Concrete Tasks On This Branch

1. Commit this plan document.
2. Add a generated patch inventory document for the legacy QEMU/PTC changes.
3. Add `test/qemu-v2-probes/` with source-only AVX-512 probes.
4. Add `runnable/scripts/qemu_v2_probe_suite.py`.
5. Add `runnable/scripts/build_qemu_libtinycode_v2.sh` as a skeleton that can
   build unmodified upstream QEMU linux-user before PTC patches.
6. Choose the QEMU baseline using probe results, not assumptions.
7. Start the `ptc_translate`/`dump_tinycode` spike before porting all exec/state
   functions.

## 11. Definition Of Done

The V2 branch is ready to replace the current backend when:

- `runnable-lift` can run with V1 or V2 backend by explicit configuration.
- V2 probe suite passes for all listed AVX-512 mnemonics.
- V2 serial libcrypto canonical recall is at least `0.92` and precision is not
  worse than `0.90` before optional filters.
- The two AVX-512 AES-GCM functions no longer dominate FN.
- Build and evaluation commands are documented and reproducible in one runtime
  environment.
- Run artifacts record QEMU version, QEMU commit, PTC ABI version, container
  image, and exact input binary/GT paths.
