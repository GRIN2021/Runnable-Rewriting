# 2026-06-23 QEMU V2 PTC Port Spike Plan

Branch: `codex/qemu-upgrade-v2`

## Purpose

This spike maps the legacy PTC/libtinycode bridge from patched QEMU 2.4.50 to
likely modern QEMU APIs, with a concrete first slice for proving that modern
QEMU can produce `PTCInstructionList` data for the x86-64 blocks that currently
lose AVX-512 semantics.

The main conclusion is that V2 should preserve the existing `ptc_load` /
`PTCInterface` ABI at the `runnable-lift` boundary, but should replace the
legacy internals behind it. The current EVEX path in
`qemu/target-i386/translate.c` advances `s->pc` without emitting TCG ops; that
behavior is a correctness bug and should not be ported.

Primary local inputs:

- `docs/plan-qemu-upgrade-v2.md`
- `docs/exp/2026-06-23-qemu-v2-legacy-patch-inventory.md`
- `qemu/linux-user/ptc.c`
- `qemu/linux-user/ptc.h`
- `qemu/target-i386/translate.c`
- `runnable/tools/runnable-lift/InstructionTranslator.cpp`
- `runnable/tools/runnable-lift/PTCInterface.h`

Modern QEMU source references checked online without adding a source tree to the
repository:

- QEMU `v10.2.3`: `target/i386/tcg/translate.c`,
  `target/i386/tcg/decode-new.c.inc`, `target/i386/tcg/emit.c.inc`,
  `include/tcg/tcg.h`, `include/tcg/tcg-opc.h`,
  `accel/tcg/translate-all.c`,
  `accel/tcg/cpu-exec.c`, `accel/tcg/internal-common.h`,
  `include/exec/translator.h`, `include/exec/translation-block.h`,
  `linux-user/main.c`, `include/hw/core/cpu.h`, `target/i386/cpu.h`
- QEMU `v11.0.1`: release tag exists upstream and should remain the reference
  capability target if `v10.2.3` fails probes.

## Legacy Contracts To Preserve

### Runnable-lift ABI

`runnable/tools/runnable-lift/PTCInterface.h` includes `ptc.h` with
`USE_DYNAMIC_PTC`, then `dlopen`s a backend and resolves `ptc_load`. The
backend fills a `PTCInterface` containing:

- function pointers for translate, execute, memory map, disassembly, syscall,
  stack recovery, and dynamic-branch queue helpers
- `PTCOpcodeDef` and `PTCHelperDef` tables
- x86 env offsets for PC, SP, exception index, and register pointers
- live status pointers such as `isIndirect`, `isCall`, `isRet`, `isSyscall`,
  `BlockSize`, `iCount`, and `isIllegal`

This layout is a hard ABI for V2 unless `runnable-lift` gets an explicit
versioned adapter. The first port should preserve the existing field order and
function pointer names.

### PTC instruction list shape

`InstructionTranslator.cpp` assumes:

- instruction address markers are represented by
  `PTC_INSTRUCTION_op_debug_insn_start`
- helper calls are represented by `PTC_INSTRUCTION_op_call`, with helper
  identity resolvable through `ptc_find_helper`
- TCG temps have stable `name`, `val_type`, `base_type`, `type`, `mem_offset`,
  and global/local classification
- env loads/stores have offsets that `VariableManager` can map back to the
  emulated CPU state
- the supported opcode set is close to QEMU 2.4 TCG op names, especially
  `*_i32`, `*_i64`, `qemu_ld_i*`, `qemu_st_i*`, branches, labels, calls, and
  `debug_insn_start`

Modern QEMU uses generic opcode names such as `add`, `ld`, `qemu_ld`,
`insn_start`, plus vector opcodes such as `xor_vec`, `ld_vec`, `st_vec`,
`dupm_vec`, and `bitsel_vec`. A compatibility map is likely required before
`InstructionTranslator` can consume modern TCG output.

### Current broken EVEX behavior

Legacy `translate.c` handles `0x62` as a partial EVEX prefix and routes opcodes
to `case 0x200 ... 0x2ff`. That case calls `ptc_evex_tail_bytes(...)`, advances
`s->pc`, and emits no TCG semantics. V2 must replace this with modern x86
translation, not preserve the skip path.

## Modern QEMU API Map

The target implementation should treat modern QEMU as an in-tree dependency
with a narrow PTC adapter. Paths below refer to modern QEMU `v10.2.3` unless
noted.

| Legacy item | V1 implementation | Likely modern files/APIs | Port notes |
|---|---|---|---|
| `ptc_load` | Calls `ptc_init`, fills `PTCInterface`, exports raw offsets and live pointers. | New PTC shim in modern `linux-user` or a small libtinycode target; `target/i386/cpu.h` for `CPUX86State`; `include/hw/core/cpu.h` for `CPUState`; `include/tcg/tcg-opc.h` for opcode metadata. | Preserve V1 layout first. Add an internal `ptc_abi_version` only after V1 parity is proven. Recompute `pc`, `sp`, `exception_index`, and `regs` offsets from modern structs at compile time. |
| `ptc_init` | Reimplements part of old `linux-user/main.c`: QOM, CPU init, loader, signals, TCG prologue, helper/opcode tables. | `linux-user/main.c`; `module_call_init(MODULE_INIT_TRACE/QOM)`; `qemu_init_cpu_list`; `current_accel` / `AccelClass::init_machine`; `cpu_create`; `loader_exec`; `target_set_brk`; `syscall_init`; `signal_init`; `tcg_prologue_init`; `init_main_thread`. | Do not copy old initialization blindly. Extract a PTC-specific initialization path from modern linux-user startup and stop before `cpu_loop(env)`. |
| `ptc_translate` | Sets `env->eip`, allocates/generates a TB, dumps old `TCGContext` arrays, executes the TB under `sigsetjmp`, returns TB size and next PC. | `CPUClass::tcg_ops->get_tb_cpu_state`; `TCGTBCPUState`; `tb_gen_code(CPUState *, TCGTBCPUState)` declared in `accel/tcg/internal-common.h`; `cpu->cc->tcg_ops->translate_code`; `TranslationBlock` from `include/exec/translation-block.h`; `tcg_qemu_tb_exec`. | `tb_lookup` is internal to `accel/tcg/cpu-exec.c`; either add a tiny in-tree PTC wrapper or initially force `tb_gen_code` without cache lookup for the spike. Preserve `dymvirtual_address`, `isIllegal`, branch flags, `iCount`, and return-size semantics. |
| `tb_gen_code2` / `tb_gen_code3` | Hand-allocates `TranslationBlock`, calls `gen_intermediate_code(env, tb)`, then `tcg_gen_code`. | Modern `accel/tcg/translate-all.c::tb_gen_code`; `setjmp_gen_code`; `tcg_func_start`; `cpu->cc->tcg_ops->translate_code`; `tcg_gen_code(tcg_ctx, tb, pc)`. | Do not port old manual TB allocation first. For the spike, call modern `tb_gen_code` and inspect `tcg_ctx->ops` before or after code generation. If post-generation optimization mutates ops too much, add a dump hook after `translate_code` and before `tcg_gen_code`. |
| `dump_tinycode` | Walks `s->gen_first_op_idx`, `gen_op_buf`, `gen_opparam_buf`; copies `s->temps`; special-cases `INDEX_op_debug_insn_start` and `INDEX_op_call`. | `include/tcg/tcg.h`: `TCGContext` has `QTAILQ_HEAD ops`, `TCGOp` has flexible `args[]`, `TCGOP_CALLO`, `TCGOP_CALLI`, `tcg_get_insn_start_param`, `tcg_call_func`, `tcg_call_info`, `tcg_op_defs`, `tcg_op_defs_max`, `temps`, `nb_temps`, `nb_globals`. | Reimplement as `QTAILQ_FOREACH(op, &tcg_ctx->ops, link)`. Map modern `INDEX_op_insn_start` to legacy `PTC_INSTRUCTION_op_debug_insn_start` or update `InstructionTranslator`. Call args now include function pointer and `TCGHelperInfo *` at the end. |
| `ptc_exec`, `ptc_exec1`, `ptc_exec2` | Generates/fetches TB, executes `tb->tc_ptr` via `tcg_qemu_tb_exec`, returns next PC or block size. | `accel/tcg/cpu-exec.c::cpu_loop_exec_tb` is the model; `tcg_qemu_tb_exec(cpu_env(cpu), tb->tc.ptr)`; `CPUClass::tcg_ops->synchronize_from_tb`; `cpu->neg.can_do_io`. | Modern `TranslationBlock` stores code in `tb->tc.ptr` and generated size in `tb->tc.size`. Keep bounded-exec semantics for `exec1/exec2`; implement after translate-only spike passes. |
| `ptc_mmap`, `ptc_unmmap`, `ptc_cleanLowAddr` | Uses old `target_mmap`, host `munmap`, fixed guest addresses. | `linux-user/mmap.c` APIs via `target_mmap`, `target_munmap`, `mmap_lock` as needed. | Preserve fixed-address executable mapping behavior. Verify host pointer conversion expectations; modern linux-user may require `g2h_untagged` for direct host memory copies. |
| `ptc_disassemble`, `ptc_disassemble_bytes` | Uses QEMU disassembler helpers. | `disas/disas.h`, `target_disas`, modern `disas` APIs. | Low risk relative to translation; preserve output only enough for `.ll` comments and debug logs. |
| `ptc_do_syscall2`, loader/library syscall path | Manually handles exit/close and delegates to old syscall bridge. | `linux-user/syscall.c`, modern syscall helpers, `cpu->exception_index`, `env->exception_next_eip`. | Defer full syscall fidelity until `ptc_exec*` is ported. For translate-only probes, stubs may be enough. |
| CPU state queue helpers | Store/drop/traverse queue of `CPUArchState` copies plus data and stack snapshots. | Modern `linux-user/main.c::cpu_copy` already creates a new CPU with `cpu_create(cpu_type)`, copies `CPUArchState`, copies x86 GDT backing, and clones breakpoints. | Reuse modern `cpu_copy` logic rather than old `cpu_init("qemu64")`. Preserve queue depth/drop/store semantics because dynamic-parallel checks these at runtime. |
| Stack/data recovery helpers | Copy stack, data, and heap/code ranges by raw host address. | `image_info` from `linux-user/qemu.h`; `g2h_untagged`; `target_mmap`; modern `TaskState`. | Highest risk is stale host-vs-guest address assumptions. Verify with small branch-state replay tests before enabling dynamic-parallel. |
| Branch/control-flow flags | Old patched `TranslationBlock` has custom fields: `isIndirect`, `isCall`, `isDirectcall`, `isRet`, `CFIAddr`, etc. | Modern `TranslationBlock` has no these custom fields; target-specific x86 translator hooks are in `target/i386/tcg/translate.c` and table-generated emitters. | Either re-add custom TB fields in V2 patches or compute branch metadata from emitted TCG/address markers. Re-adding fields is the lower-risk first port. |

## Modern TCG Dump Details

The legacy `dump_tinycode` is the highest-risk mechanical migration. A concrete
modern dump implementation should do the following:

1. Iterate modern ops with `QTAILQ_FOREACH(op, &tcg_ctx->ops, link)`.
2. For normal ops, use `op->opc`, `tcg_op_defs[op->opc]`, and `op->args`.
3. For calls, use `TCGOP_CALLO(op)`, `TCGOP_CALLI(op)`, `tcg_call_func(op)`,
   and `tcg_call_info(op)`. Modern calls append the function pointer and
   `TCGHelperInfo *` to the argument list.
4. For instruction markers, translate modern `INDEX_op_insn_start` to the
   legacy address-marker opcode expected by `InstructionTranslator`, or update
   `InstructionTranslator::newInstruction` and `preprocess` together.
5. Copy temps from `tcg_ctx->temps[0..nb_temps)`, but update the old
   `PTCTemp` copy logic because modern `TCGTemp` uses `kind`, `mem_base`,
   `state`, and `state_ptr` instead of exactly the old fields.
6. Generate an opcode compatibility table because modern QEMU uses unsuffixed
   integer ops plus typed operands instead of only old `*_i32` and `*_i64`
   enum names. For scalar integer ops, use modern opcode type metadata such as
   `TCGOP_TYPE(op)` to synthesize the V1 `_i32` or `_i64` PTC opcode.
7. Decide how to expose vector ops. Options are listed below.

Vector handling choices:

| Option | Description | Pros | Cons |
|---|---|---|---|
| A: teach `InstructionTranslator` modern vector TCG ops | Extend PTC and LLVM translation for `*_vec`, `qemu_ld2`, `qemu_st2`, `extract`, `sextract`, etc. | Real semantics for AVX/AVX-512 families emitted through TCG gvec. | Larger runnable-lift change; may require LLVM vector state modeling. |
| B: lower vector ops to helper calls in the PTC adapter | Convert unsupported vector TCG ops into helper-like calls against generated helper IR. | Keeps `InstructionTranslator` closer to existing helper-call model. | Needs reliable helper IR for gvec operations; could hide semantics behind opaque helpers. |
| C: temporary explicit unsupported-vector markers | Emit measurable tombstones for modern vector ops while preserving PC coverage. | Useful diagnostic gate. | Not acceptable as the final backend replacement because it still omits semantics. |

Recommended first spike path: implement A only far enough to dump and classify
modern vector ops, while permitting C as a diagnostic report mode. Do not claim
V2 success until real vector semantics are represented in `.ll` or linked helper
IR.

## AVX/EVEX Source Expectations

Modern x86 translation is split:

- `target/i386/tcg/translate.c` owns `DisasContext`, `TranslatorOps`, and
  `x86_translate_code(...)`, which calls `translator_loop(...)`.
- `include/exec/translator.h` and `accel/tcg/translator.c` provide the generic
  translation loop and instruction marker emission.
- `target/i386/tcg/decode-new.c.inc` contains a table-driven decoder for many
  SSE/AVX forms.
- `target/i386/tcg/emit.c.inc` emits many vector instructions through
  `tcg_gen_gvec_*` or helper calls.

Source inspection of `v10.2.3` found entries for VAES, PCLMULQDQ, vector
broadcast, VEXTRACT, VPXOR/PXOR, VPSLLV/VPSRLV, and related XMM/YMM forms. The
unknown is not whether modern QEMU is generally newer than 2.4.50; the unknown
is whether the exact 512-bit EVEX/ZMM forms used by the libcrypto AES-GCM
functions decode, execute, and produce usable TCG for `runnable-lift`.

That unknown must be retired with probes before the port assumes `v10.2.3` is
sufficient.

## Unknowns And How To Retire Them

| Unknown | Why it matters | Spike experiment | Pass condition |
|---|---|---|---|
| Does `v10.2.3` execute the exact EVEX probe set? | QEMU source has many AVX entries, but libcrypto failures are dominated by EVEX/ZMM forms. | Build unmodified `qemu-x86_64` outside the repo and run probe binaries for `vpxorq`, `vaesenc`, `vaesenclast`, `vbroadcastf64x2`, `vpternlogq`, `vpclmul*`, `vmovdqu64`, `vmovdqa64`, `vmovdqu8`, `vpshufb`, `vpslldq`, `vpsrldq`, `vextracti32x4`, `vextracti64x4`. | No `SIGILL`; output matches native when hardware supports it or a reference implementation otherwise. |
| Are vector ops emitted as TCG vector ops, helper calls, or both? | Determines whether `InstructionTranslator` or helper IR needs the main update. | Add a temporary TCG-op dump hook around `x86_translate_code` for probe blocks. | Each probe block has non-empty ops after `insn_start`; no silent EVEX skip. |
| Can modern `TCGOp` be losslessly copied to V1 `PTCInstructionList`? | `InstructionTranslator` currently assumes old op names and old call arg layout. | Implement a standalone PTC dump prototype inside a modern QEMU build and serialize opcode names/args for scalar and AVX probes. | Scalar ops map to old translator-compatible forms; unmapped ops are listed with names and arity. |
| Does modern `CPUX86State` offset layout satisfy current env-offset logic? | Runnable-lift hard-codes or consumes register/env offsets. | Generate a compile-time/runtime offset report for `eip`, `regs[R_ESP]`, `xmm_regs`, `opmask_regs`, `exception_next_eip`, and `CPUState.exception_index`. | Offsets are recorded in a run manifest and checked by a smoke lift. |
| Can `ptc_translate` run without executing guest side effects? | Translation-only lift should avoid unnecessary concrete execution faults. | First implement translate-only mode that calls modern `tb_gen_code` and dumps TCG without `tcg_qemu_tb_exec`. | Scalar and AVX probe PTC lists are non-empty and include correct PC markers. |
| Can `ptc_exec*` reproduce old next-PC semantics? | Dynamic exploration and validation rely on concrete execution. | After translate-only dump works, execute straight-line, direct branch, indirect branch, syscall, and fault probes. | `ptc_translate` and `ptc_exec` agree on next PC for straight-line probes; branch flags match expected metadata. |
| Can CPU queue snapshots survive modern x86 state changes? | Dynamic-parallel depends on branch-state replay. | Port queue helpers using modern `cpu_copy` and replay two queued branch states with mutated stack/data. | `queueDepth`, `dropCPUState`, and branch replay produce deterministic register/stack/data state. |

## Proposed Spike Experiments

### Experiment 1: Upstream capability check

Use an external QEMU checkout or release tarball under `/tmp` or another
non-repo path. Build `qemu-x86_64` from `v10.2.3`; if a probe fails, repeat with
`v11.0.1`.

Output to record in a later report:

- QEMU tag and commit
- compiler/container image
- per-probe native result, QEMU result, and exit status
- objdump bytes and mnemonic for unsupported cases

Do not begin the PTC port on a baseline that cannot execute the required EVEX
probe set.

### Experiment 2: Modern TCG op census

Patch only the throwaway external QEMU checkout to dump TCG ops for the probe
blocks. The useful hook point is after `cpu->cc->tcg_ops->translate_code(...)`
and before `tcg_gen_code(...)` in the path modeled by
`accel/tcg/translate-all.c::setjmp_gen_code`.

Record:

- opcode names and arities
- instruction marker op and PC payload
- helper call names and flags
- temp count, global temp count, and env-offset temps
- vector op usage per mnemonic

Pass condition: the current AVX-512 probes do not collapse into only
`insn_start` plus `exit_tb`, and no probe is silently skipped.

### Experiment 3: PTC list prototype

In the external QEMU checkout, add a minimal PTC dump prototype that converts
modern `TCGOp` to a V1-shaped JSON or text dump. This can be done before
building `libtinycode-x86_64.so`.

The prototype should answer:

- Which modern opcodes are directly mappable to V1 opcodes?
- Which opcodes need new `InstructionTranslator` cases?
- Which helper names must appear in `libtinycode-helpers-x86_64.ll`?
- Whether `INDEX_op_insn_start` can be represented as V1
  `debug_insn_start` without changing downstream code.

### Experiment 4: Minimal libtinycode load shim

After the op census, build a modern shared object exporting only:

- `ptc_load`
- `ptc_init`
- `ptc_translate`
- `ptc_instruction_list_free` through existing header inline ownership
- opcode/helper metadata required for scalar smoke tests

This first shared object does not need `ptc_exec*` or dynamic queue helpers if
the interface function pointers are filled with safe stubs for non-called paths.
The goal is to prove `runnable-lift` can `dlopen` V2 and receive a non-empty PTC
list for a scalar block.

### Experiment 5: Execution and queue parity

Only after translate-only lift works, port:

- `ptc_exec`, `ptc_exec1`, `ptc_exec2`
- branch metadata fields
- `ptc_storeCPUState`, `ptc_dropCPUState`, `ptc_queueDepth`
- stack/data snapshot helpers

This experiment should be gated separately from serial lift because
dynamic-parallel is not the V2 acceptance path.

## First Implementation Slice

The first slice should be small enough to fail fast on the hardest API changes:
modern TCG dumping and opcode compatibility.

1. Select `v10.2.3` as the first implementation baseline only if the upstream
   EVEX probe suite passes. Otherwise switch to `v11.0.1`.
2. In an external checkout, add a throwaway TCG op dump hook around modern
   `translate_code` and run scalar plus AVX/EVEX probes.
3. Create a V2 PTC adapter skeleton that preserves `ptc_load` and the V1
   `PTCInterface` layout, with `ptc_exec*` and queue helpers initially stubbed
   but present.
4. Implement modern `dump_tinycode` over `tcg_ctx->ops` and a compatibility map
   for instruction markers, calls, scalar integer ops, `qemu_ld`, and `qemu_st`.
5. Wire `ptc_translate` to set the x86 PC, obtain `TCGTBCPUState` through
   `cpu->cc->tcg_ops->get_tb_cpu_state(cpu)`, call `tb_gen_code`, and return the
   dumped PTC list without executing the TB.
6. Run a scalar x86-64 smoke lift through `runnable-lift` with V2 selected.
7. Run one AVX2 and one EVEX probe and verify that the `.ll` contains address
   markers for the probe instructions and that the PTC dump contains real ops or
   explicit unmapped vector ops, not a silent skip.

Exit criteria for this slice:

- `dlopen` and `dlsym("ptc_load")` succeed.
- `ptc_translate` returns a non-zero TB size and non-empty instruction list for
  a scalar block.
- Modern `insn_start` markers reach `InstructionTranslator` as usable PCs.
- The AVX/EVEX probe dump identifies all unmapped modern opcodes by name.
- No execution or dynamic-parallel claims are made yet.

## Highest-Risk API Migrations

| Risk | Why it is high risk | Mitigation |
|---|---|---|
| Old TCG op buffers to modern `QTAILQ` ops | `dump_tinycode` is central to all lifting, and modern calls/opcodes/temps changed shape. | Prototype dump outside repo; add opcode census before editing runnable-lift. |
| `debug_insn_start` to `insn_start` | Existing block splitting and `.ll` comments depend on PC markers. | Map modern marker to V1 marker in the PTC adapter first. |
| Old suffixed TCG opcode enum to modern generic/vector opcodes | `InstructionTranslator` does not currently handle modern vector opcodes. | Add a compatibility map and an unmapped-op report; implement vector handling based on observed probes. |
| `gen_intermediate_code(env, tb)` to `translator_loop` / `translate_code` | The old direct frontend call no longer exists in the same form. | Use `tb_gen_code` first; only add a custom translate wrapper if the dump hook must occur before optimization. |
| Direct TB cache and `TranslationBlock` fields | Modern `tb_lookup` is internal and `TranslationBlock` has no PTC branch fields. | Avoid cache dependence in the first slice; re-add custom metadata fields or compute metadata explicitly later. |
| `tc_ptr` to `tb->tc.ptr` and `tcg_qemu_tb_exec` call path | Execution semantics and `can_do_io` handling moved. | Port `ptc_exec*` after translate-only success using `cpu-exec.c` as the model. |
| CPU state clone and queue helpers | Modern `cpu_copy` must copy x86 GDT backing and CPU cflags; raw `memcpy` alone is not enough. | Reuse modern `linux-user/main.c::cpu_copy` logic and add replay tests. |
| Guest/host address handling in stack/data snapshots | Modern linux-user uses tagged/untagged host conversions more explicitly. | Audit all raw `memcpy((void *)guest_addr, ...)` paths and convert through modern helpers where needed. |
| EVEX/ZMM support assumptions | Source contains many AVX forms, but exact libcrypto EVEX forms may still fail. | Gate baseline selection on executable probes, then gate PTC work on TCG op census. |

## Recommended Ownership Boundaries

For the PTC port, keep changes isolated by layer:

- QEMU adapter: modern `ptc.c` / `ptc.h`, TB generation, TCG dump, helper/opcode
  metadata, execution, and state queue internals.
- Runnable-lift adapter: only explicit ABI/version handling and new opcode
  translation cases proven necessary by the op census.
- Evaluation scripts: backend selection and manifest metadata only.

Avoid mixing V1 and V2 assets. Each run manifest should record QEMU tag,
commit, PTC ABI version, libtinycode path, helper IR path, and runtime image.

## Stop/Go Decision Points

| Decision | Go condition | Stop or branch condition |
|---|---|---|
| Baseline selection | `v10.2.3` passes required EVEX probes. | If not, test `v11.0.1`; if both fail, fallback baseline needs a separate rationale. |
| PTC dump port | Scalar and AVX probes produce inspectable modern TCG ops. | If vector ops are opaque or absent, investigate decoder support before building libtinycode. |
| Runnable-lift integration | V2 scalar smoke lift works through `ptc_load` without changing the ABI. | If ABI breaks, add a versioned adapter rather than silently changing field layout. |
| Execution port | Translate-only PTC output is stable and PC markers are correct. | If `ptc_translate` still mutates concrete state unexpectedly, keep execution disabled. |
| Dynamic-parallel port | Serial V2 is correct enough to evaluate libcrypto. | If queue replay is flaky, keep dynamic-parallel disabled for V2 acceptance. |

## Bottom Line

The fastest credible path is not a full one-shot port of `ptc.c`. The first
implementation slice should prove that modern QEMU can translate target blocks
into a PTC-compatible instruction stream, with exact opcode gaps measured. Once
that path works for scalar and AVX/EVEX probes, port execution and branch-state
helpers as separate compatibility layers.
