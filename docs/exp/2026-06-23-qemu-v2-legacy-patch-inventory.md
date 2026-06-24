# 2026-06-23 QEMU V2 Legacy Patch Inventory

## Purpose

This document inventories the legacy QEMU/PTC customizations currently relied on by `runnable-lift` and the dynamic-parallel pipeline. It is the Phase 0 handoff artifact for the QEMU V2 upgrade: the goal is not to preserve every historical implementation detail, but to preserve the externally visible behavior that current tooling depends on.

Primary references:

- `docs/plan-qemu-upgrade-v2.md`
- `docs/plan-avx512-lift.md`
- `docs/exp/2026-06-23-serial-vs-parallel-lift-libcrypto-eval.md`
- `docs/exp/2026-05-10-libcrypto-canonical-eval-contract.md`
- `docs/exp/2026-06-23-llm-fp-filter-v1-design.md`

## What This Inventory Covers

Scope is limited to the legacy backend surface that must be preserved or explicitly replaced in V2:

- QEMU linux-user PTC ABI and runtime behavior
- x86 translation customizations in `translate.c`
- QEMU build wiring that selects `x86_64-libtinycode`
- `runnable-lift` backend loading and ABI consumption
- dynamic-parallel branch exploration dependencies on queue/state helpers

## High-Risk Summary

The current backend is not just "old QEMU". It encodes several behavioral contracts:

1. `ptc_translate` and `dump_tinycode` produce a legacy `PTCInstructionList` format that `InstructionTranslator` expects.
2. The x86 translator preserves a partial EVEX path by skipping some AVX-512 instructions rather than executing them, which is a major source of false negatives.
3. Dynamic-parallel depends on queue depth and CPU state snapshot helpers that are not part of a generic QEMU API.
4. `runnable-lift` discovers runtime assets by filename convention and `dlopen`/`dlsym` rather than through an install manifest.

The migration risk is highest wherever V1 behavior is accidental but depended on, especially:

- vector/EVEX decoding behavior in `qemu/target-i386/translate.c`
- exact `PTCInterface` field order and function pointer availability
- the legacy `TCGContext`-based `dump_tinycode` implementation
- dynamic-parallel state queue semantics

## Inventory

### 1) `qemu/linux-user/ptc.h`

| Area | Behavior in V1 | Migration risk | Recommended V2 handling |
|---|---|---:|---|
| PTC instruction model | Defines `PTCInstruction`, `PTCInstructionList`, `PTCOpcodeDef`, `PTCHelperDef`, temp/load-store enums, and helper accessors. | High | Preserve the serialized semantics of instruction/opcode metadata, but allow a V2 compatibility layer if modern QEMU changes TCG naming or arity. |
| Exported API | Declares the legacy backend entry points consumed by `runnable-lift`. | High | Keep a stable C ABI shim for `ptc_load` plus the minimum loader/translate/exec helpers required by current callers. |
| `PTCInterface` layout | Field order is the contract between QEMU and `runnable-lift`; it exposes function pointers, opcode/helper tables, register offsets, and global state pointers. | Very high | Treat this as the V1 ABI boundary. For V2, either preserve the existing layout or version it explicitly and add an adapter in `runnable-lift`. |
| Dynamic-parallel extras | Includes `storeCPUState`, `dropCPUState`, `queueDepth`, `getBranchCPUeip`, `deletCPULINEState`, `recoverStack`, `recoverOnlyStack`, `storeStack`, `storeOnlyStack`, and address classification helpers. | Very high | Preserve compatibility for serial and parallel modes. If the implementation changes, the ABI should still expose equivalent semantics or provide compatibility wrappers. |

Important details to preserve:

- `ptc_instruction_list_free` and the list ownership model used by `unique_ptr` in `PTCInterface.h`
- `ptc_find_helper` / `ptc_instruction_opcode_def` access patterns
- `PTC_CALL_*` helper flag constants and `PTC_CALL_DUMMY_ARG`
- load/store type encoding used by `InstructionTranslator`

### 2) `qemu/linux-user/ptc.c`

| Area | Behavior in V1 | Migration risk | Recommended V2 handling |
|---|---|---:|---|
| QEMU bootstrap | Initializes `tcg_exec_init`, QOM, a target CPU, loader state, signals, and helper/opcode tables. | High | Rebuild initialization around modern QEMU entry points, but keep the same high-level startup contract: one call to `ptc_init` should still prepare a runnable backend and populate the interface. |
| `ptc_load` | Constructs the `PTCInterface`, fills offsets for x86 and other targets, and exports helper/metadata pointers. | Very high | This is the most important compatibility shim. Preserve the caller-visible fields, especially `pc`, `sp`, `exception_index`, `regs`, helper tables, and branch/state function pointers. |
| `cpu_copy` | Clones `CPUArchState` by creating a new CPU, resetting it, copying the full arch state, and cloning break/watchpoints. | High | Modern QEMU will likely require a different clone path. Preserve the semantic outcome: a snapshot usable for branch exploration, with break/watchpoints not lost. |
| `ptc_init` | Builds loader state, parses executable arguments, sets up guest memory, installs signal handlers, initializes TCG, captures the initial CPU state, and builds opcode/helper tables from the current QEMU globals. | High | Split into modern QEMU bootstrap plus adapter-specific setup. Keep the same observable side effects: loaded binary, initialized CPU state, helper metadata, and signal-based fault recovery. |
| `dump_tinycode` | Walks `TCGContext` op buffers and converts them to `PTCInstructionList`/argument/temp arrays. | Very high | This must be reimplemented against modern TCG/IR structures. Preserve opcode mapping and argument ordering as seen by `InstructionTranslator`. |
| `tb_gen_code2` / `tb_gen_code3` | Generates a TB, calls `gen_intermediate_code`, dumps PTC instructions, optionally disassembles, generates machine code, and sets TB linkage metadata. | High | Keep the same “translate then optionally execute” flow, but isolate the modern TB/API differences behind a thin adapter. |
| `ptc_mmap` / `ptc_unmmap` / `ptc_cleanLowAddr` | Allocates and clears guest executable mappings with fixed addresses. | Medium | Preserve guest-memory semantics. These helpers matter to the loader/runtime contract, but they can be reimplemented with modern user-mode mapping APIs. |
| `ptc_lockexec` / `ptc_unlockexec` | Temporarily mprotects the code region. | Medium | Recreate only if the V2 backend still needs execution-region protection; otherwise keep the API as a compatibility no-op or equivalent guard. |
| `ptc_translate` | Translates one TB, caches it, sets per-TB flags, executes it under `sigsetjmp`, and returns the next virtual address plus instruction metadata. | Very high | Preserve all caller-visible results: TB size, illegal-block detection, indirect/direct branch flags, syscall/ret markers, and the returned next PC. |
| `ptc_exec`, `ptc_exec1`, `ptc_exec2` | Execute a translated TB or bounded block and report the next PC or block size. | High | Keep return-value semantics stable because `runnable-lift` and validation scripts treat them as control-flow probes. |
| `ptc_isdecodeblock` / `ptc_getBadBlockSize` | Quick TB classification helpers used by the decoder and bad-block logic. | Medium | Preserve their coarse control-flow classification, even if modern QEMU exposes better APIs internally. |
| `ptc_run_library` | Replays the loaded library until the data segment boundary, using the same execution/exception path as `ptc_exec`. | High | Preserve library execution semantics because current tooling uses this path for staged runtime behavior. |
| `ptc_do_syscall2` | Bridges syscall handling to the target loader/runtime. | Medium | Keep if current scripts still call it directly; otherwise provide a stub-compatible export. |
| `ptc_storeCPUState`, `ptc_dropCPUState`, `ptc_queueDepth` | Manage the branch-exploration queue by storing, dropping, and counting CPU snapshots. | Very high | Preserve these semantics for dynamic-parallel compatibility. The exact storage structure may change, but queue behavior and counts must remain meaningful. |
| `ptc_getBranchCPUeip`, `ptc_deletCPULINEState` | Traverse/remove queued branch state. | Very high | These are coupled to parallel exploration. Keep equivalent operations or adapt `CodeGenerator` accordingly. |
| `ptc_recoverStack`, `ptc_recoverOnlyStack`, `ptc_storeOnlyStack`, `ptc_storeStack` | Snapshot and restore stack/data/code regions around branch exploration. | High | Preserve the observable snapshot/restore effect. These functions are a major source of hidden state coupling. |
| `ptc_is_stack_addr`, `ptc_is_image_addr`, `ptc_isValidExecuteAddr` | Classify guest addresses used by branch exploration and fault suppression. | Medium | Maintain the same conservative classification behavior or update downstream code that depends on it. |

Notable behavior to carry forward:

- `sig_handle` uses `siglongjmp(cpu->jmp_env, 1)` to recover from faults during translation/execution.
- `ptc_translate` currently returns `tb->size` even on certain fault paths while also populating `dymvirtual_address`.
- `ptc_exec` and related functions currently rely on `cpu->exception_index`, `tb->isIllegal`, and the current TB cache.
- `ptc_load` exports a large number of state pointers into the interface, not just function pointers.

### 3) `qemu/target-i386/translate.c`

| Area | Behavior in V1 | Migration risk | Recommended V2 handling |
|---|---|---:|---|
| `ptc_evex_tail_bytes` | Computes instruction length for a subset of EVEX instructions so the decoder can advance `s->pc`. | High | Preserve length accounting, but replace the hard-coded subset with a real modern decode path or a safer compatibility decoder. |
| `case 0x62` EVEX prefix decode | Parses EVEX bytes, sets `rex_*`, `vex_v`, `vex_l`, and `PREFIX_VEX`, then advances into `0x200..0x2ff` opcode space. | Very high | This path is the AVX-512 hotspot. In V2, either execute the instruction correctly or explicitly emit a compatibility marker. Skipping semantics is not acceptable for the backend replacement goal. |
| `case 0x200 ... 0x2ff` EVEX opcode handling | For supported opcodes, advances `s->pc` by the calculated tail bytes and emits no TCG ops. Unsupported ones go to `illegal_op`. | Very high | This is the current source of silent semantic loss. V2 must not silently drop supported instructions. If some instruction families remain unsupported, make that explicit and measurable. |
| `illegal_op` fallback | Routes unsupported instructions to fault handling. | High | Preserve the error path for genuinely unsupported instructions, but do not conflate “unsupported” with “silently skipped”. |

Why this matters:

- The plan/analysis documents already show that EVEX bytes currently disappear from `PTCInstructionList` and `.ll`.
- This behavior causes false negatives by erasing AVX-512-heavy regions from the lifted output.
- For V2, this file is the main correctness gap, not just a build compatibility issue.

### 4) `support/components/qemu.mk`

| Area | Behavior in V1 | Migration risk | Recommended V2 handling |
|---|---|---:|---|
| QEMU configure target list | Builds `x86_64-libtinycode` and `x86_64-linux-user`. | High | Add a V2 build target rather than replacing V1 in place until the new backend is validated. |
| Configure flags | Uses `--enable-llvm-helpers`, disables system/kvm/tools, and pins `python2`. | High | Expect modern QEMU to require a different configure path. Preserve the ability to build a libtinycode backend and produce the helper artifacts that `runnable-lift` consumes. |
| Autotools component wiring | Treats QEMU as a local dependency component with debug and release variants. | Medium | Keep reproducible build outputs and explicit install paths so the runtime loader can find V2 assets deterministically. |

Recommended handling:

- Separate the V2 source/build tree from the legacy one.
- Keep reproducible install locations for `libtinycode-x86_64.so`, `libtinycode-helpers-x86_64.ll`, and any early-linked artifacts.
- Do not assume the old `configure` invocation will work unchanged on modern QEMU.

### 5) `runnable/tools/runnable-lift/PTCInterface.h`

| Area | Behavior in V1 | Migration risk | Recommended V2 handling |
|---|---|---:|---|
| `USE_DYNAMIC_PTC` include path | Forces the dynamic loading variant of `ptc.h`. | Medium | Preserve dynamic loading support. V2 should still load backend code at runtime, not statically link it into `runnable-lift`. |
| `PTCDestructor` / `PTCInstructionListPtr` | Owns PTC instruction-list cleanup with `ptc_instruction_list_free`. | Low | Keep the ownership model intact, even if the internal instruction list representation changes. |
| Compatibility probes | `ptc_compat::queueDepth()` and `ptc_compat::dropCPUState()` detect whether the loaded backend exposes the newer dynamic-parallel helpers. | Very high | This is the downstream adapter that allows serial and parallel paths to coexist across ABI versions. Preserve it or replace it with a versioned backend capability query. |
| Register offset constants | Hard-coded offsets for x86 registers and temp identifiers. | High | Treat these as ABI-sensitive. If V2 changes register layout, add a versioned mapping rather than silently reusing stale offsets. |

### 6) `runnable/tools/runnable-lift/Main.cpp`

| Area | Behavior in V1 | Migration risk | Recommended V2 handling |
|---|---|---:|---|
| Backend discovery | Searches the install prefix, executable directory, and `QEMU_INSTALL_PATH/lib` for `libtinycode-<arch>.so`, `libtinycode-helpers-<arch>.ll`, and `early-linked-<arch>.ll`. | High | Make V2 asset discovery deterministic and explicit. Keep the old fallback search for compatibility during migration, but prefer a versioned V2 path. |
| `dlopen` / `dlsym("ptc_load")` | Loads the backend shared object and resolves the entry point dynamically. | High | Preserve dynamic loading, but add explicit backend version metadata if the V2 ABI changes. |
| `ptc_load(...)` initialization | Fills a global `PTCInterface` instance, which is then consumed by `CodeGenerator` and downstream translation code. | Very high | The `ptc_load` contract is the boundary that `runnable-lift` depends on. Preserve the fields it reads today, or provide a thin adapter. |
| Command-line options | Accepts `-dynamic-parallel`, `-parallel-workers`, worker mode, seed PC, fragment dir, and executable args. | Medium | Keep these flags unchanged unless there is a deliberate migration plan, because scripts already pass them through. |

### 7) `runnable/tools/runnable-lift/CodeGenerator.h`

| Area | Behavior in V1 | Migration risk | Recommended V2 handling |
|---|---|---:|---|
| Parallel configuration | Stores dynamic-parallel toggles, worker counts, seed PC, seed register snapshot, fragment directory, and binary arguments. | High | Preserve the user-visible options and worker snapshot semantics. V2 backend changes should not force a rewrite of the scheduler contract. |
| Worker state bookkeeping | Tracks spawned workers, success/failure counts, and pending state drops. | High | Keep the same accounting so dynamic-parallel reporting remains meaningful after a backend swap. |

### 8) `runnable/tools/runnable-lift/CodeGenerator.cpp`

| Area | Behavior in V1 | Migration risk | Recommended V2 handling |
|---|---|---:|---|
| `workerOutputPath` / `switchToWorkerOutput` | Redirects worker output into `worker_<seed>.ll` and associated CSV/log files. | Medium | Preserve file naming so shard merging and debugging tools keep working. |
| `runFreshBranchWorker` | Replays a branch seed in a forked child, clears stale state, and re-translates from the seed PC using the snapshot register context. | Very high | This is the core dynamic-parallel compatibility path. Preserve the seed replay semantics or disable the feature until V2 is adapted. |
| `activateBranchFrontierState` | Drops pending queued states before exploring the next branch frontier. | Very high | Requires `ptc.deletCPULINEState()` or an equivalent queue-pop semantic. |
| `trySpawnBranchWorker` | Captures `ptc.regs`, forks, drops queued CPU state in the parent, and seeds the child with the captured register file. | Very high | Preserve register snapshot behavior and the queue-drop contract. Without it, branch workers will decode with incorrect concrete state and produce spurious `illegalEntry` failures. |
| `mergeForkWorkerFragments` | Merges worker fragments into the parent `.ll` and optionally deletes the worker artifacts. | Medium | Preserve output merge format or update the merge script in tandem with any V2 format changes. |

Important downstream dependency:

- The dynamic-parallel code assumes that `ptc.regs` is a live concrete register file snapshot at the branch point.
- It also assumes `dropCPUState()` and `queueDepth()` are meaningful for the backend queue, not just placeholders.

### 9) `runnable/scripts/libcrypto_dynamic_parallel_lift.py`

This script is not part of the backend itself, but it is a major consumer of the legacy ABI.

| Area | Behavior in V1 | Migration risk | Recommended V2 handling |
|---|---|---:|---|
| Build fallback logic | Detects whether the current branch’s `runnable-lift` supports `queueDepth` and `dropCPUState`, and emits a specific diagnostic when the build tree/runtime mismatch exposes an older `PTCInterface`. | High | Keep this detection path until V2 is fully rolled out. It is a useful compatibility guard, not dead code. |
| Backend staging | Assumes current dynamic-parallel assets can be built and staged into shared and run-local install prefixes. | Medium | Add explicit V2 asset selection (`--libtinycode-path`, `--libtinycode-helpers-path`, or equivalent) so V1 and V2 do not mix accidentally. |

### 10) `runnable/scripts/libcrypto_parallel_shard_runner.py`

| Area | Behavior in V1 | Migration risk | Recommended V2 handling |
|---|---|---:|---|
| Per-shard coordinator flags | Runs `runnable-lift` with `-dynamic-parallel`, `-parallel-workers`, and shard-specific fragment dirs. | Medium | Keep this script compatible with both backends. It should not need backend-specific logic beyond selecting the correct asset paths. |

## Recommended V2 Handling by Category

### Preserve As ABI

Keep these stable unless there is a deliberate versioned adapter:

- `ptc_load`
- `PTCInterface` field order and visible members
- `PTCInstructionList` ownership and cleanup
- `queueDepth`, `dropCPUState`, `storeCPUState`, `getBranchCPUeip`
- `ptc_translate`, `ptc_exec`, `ptc_exec1`, `ptc_exec2`
- register offset exposure for x86-64

### Port Through An Adapter

These should be rewritten for modern QEMU internals, but the user-visible behavior should remain:

- `cpu_copy`
- `ptc_init`
- `dump_tinycode`
- `tb_gen_code2` / `tb_gen_code3`
- `ptc_mmap` / `ptc_unmmap`
- stack/data snapshot helpers

### Replace Correctly, Do Not Preserve Broken Semantics

These are current legacy hacks that must not survive unchanged:

- EVEX instructions being consumed but not emitted
- silent omission of AVX-512 semantics from the lifted IR
- any assumption that old `tcg_ctx` globals still exist in the same form
- build assumptions tied to `python2` or the old configure layout if modern QEMU no longer supports them

## Phase 0 Exit Criteria This Document Supports

This inventory is intended to make the following questions answerable before any porting begins:

- Which current behaviors are load-bearing for serial lift?
- Which ones are only required for dynamic-parallel?
- Which pieces are ABI-stable and must be preserved exactly?
- Which pieces are legacy implementation details that should be reimplemented for V2?

The main conclusion is that V2 should preserve the `ptc_load`/`PTCInterface` contract and the parallel-state helpers, but it should not preserve the current EVEX skip path in `translate.c`. That path is a correctness bug, not a compatibility requirement.
