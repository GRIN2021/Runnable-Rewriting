# 2026-06-23 QEMU V2 Minimal PTC Shim Design

Branch: `codex/qemu-upgrade-v2`

## Purpose

Prepare the smallest credible path from upstream QEMU `10.2.3` to a
`libtinycode-x86_64.so`-style backend without attempting the full PTC port in
one step.

The first artifact is only a throwaway overlay skeleton generated under `/tmp`.
It copies the existing V1 `ptc.h` ABI header and creates explicit stubs for the
three core port points:

- `ptc_load`
- `ptc_translate`
- modern `dump_tinycode`

The generated skeleton does not claim to build. Its job is to pin the ABI shape
and TODO markers before QEMU-specific integration work starts.

## Local Inputs Read

- `qemu/linux-user/ptc.h`
- `qemu/linux-user/ptc.c`
- `runnable/tools/runnable-lift/Main.cpp`
- `runnable/tools/runnable-lift/PTCInterface.h`
- `docs/exp/2026-06-23-qemu-v2-ptc-port-spike.md`

## Generated Overlay Skeleton

Use:

```bash
runnable/scripts/qemu_v2_make_ptc_shim_tree.sh \
  --qemu-src /path/to/qemu-10.2.3 \
  --out-dir /tmp/qemu-v2-ptc-shim
```

The script validates that the input looks like QEMU `10.2.3`, refuses output
outside `/tmp`, and writes:

- `overlay/linux-user/ptc.h`
- `overlay/linux-user/ptc_shim_internal.h`
- `overlay/linux-user/ptc_load_stub.c`
- `overlay/linux-user/ptc_translate_stub.c`
- `overlay/linux-user/dump_tinycode_stub.c`
- `overlay/meson.build.fragment.todo`
- `README.md`
- `source-manifest.txt`

The output is an overlay skeleton, not a QEMU worktree and not a build
directory.

## Smallest Buildable Milestone

The smallest useful buildable milestone is not a working lift. It is a shared
object that can be loaded by a dedicated ABI smoke harness and can fill a
`PTCInterface` without crashing.

Minimum requirements:

- Build a QEMU-integrated `libtinycode-x86_64.so` or equivalent shared object
  outside the repo.
- Export `ptc_load`.
- Compile the copied `ptc.h` or a strictly layout-compatible V2 header.
- Fill every `PTCInterface` function pointer with either a real function or a
  safe stub.
- Fill every status pointer with stable static storage.
- Expose non-null `opcode_defs`, `helper_defs`, `regs`, and `initialized_env`
  pointers, while clearly marking placeholder values.
- Return success from `ptc_load` only after the interface is internally
  consistent.

This milestone should be tested with a small `dlopen`/`dlsym("ptc_load")`
harness, not by running full `runnable-lift`. Full `runnable-lift` reaches
`VariableManager` and `CodeGenerator::translate`, which need real CPU env
offsets and a non-empty `PTCInstructionList`.

## First Runnable-Lift Milestone

The next milestone is the first scalar translate smoke. That requires more than
ABI stubs:

- Real modern linux-user initialization before `ptc_load` returns success.
- Correct x86 offsets for `pc`, `sp`, `exception_index`, and `regs`.
- Real `ptc_opcode_defs` arity/name data or an explicit V1 compatibility map.
- `ptc_translate` wired to a translate-only modern QEMU path.
- `dump_tinycode` returning a non-empty `PTCInstructionList`.
- Modern `INDEX_op_insn_start` mapped to the V1
  `PTC_INSTRUCTION_op_debug_insn_start` marker expected downstream.

Execution, syscall replay, CPU-state queues, and dynamic-parallel helpers stay
out of this first scalar milestone.

## ABI Stub Policy

`ptc_load` should preserve the V1 `PTCInterface` layout. In the stub milestone
it may use static placeholder storage, but it must not silently expose null
pointers on fields that `runnable-lift` dereferences.

Stub behavior:

- `ptc_translate`: returns size `0`, writes an empty instruction list, and emits
  an unimplemented warning. This is load-smoke only, not a runnable translation.
- `dump_tinycode`: returns an empty `PTCInstructionList` until the modern
  `TCGContext->ops` walker exists.
- `ptc_exec`, `ptc_exec1`, `ptc_do_syscall2`, and `ptc_run_library`: return
  conservative failure or zero values and warn once.
- `ptc_exec2`, queue helpers, stack helpers, and address predicates: safe
  no-ops until execution and branch-state replay are ported.
- `ptc_parse_load_store_arg` and `ptc_get_arg_label_id`: ABI placeholders only;
  real modern `MemOpIdx` and label mapping are required before lift output can
  be trusted.
- `opcode_defs`: non-null storage is acceptable for load-smoke, but real arity
  data is mandatory before translating even scalar instructions.
- `helper_defs`: size `0` is acceptable for load-smoke, but helper identity must
  come from modern QEMU before helper calls are translated.

## Modern API TODOs

The generated stubs intentionally point at the high-risk modern API replacements:

- Replace old `gen_op_buf`/`gen_opparam_buf` traversal with
  `QTAILQ_FOREACH(op, &tcg_ctx->ops, link)`.
- Use modern call metadata through `TCGOP_CALLO`, `TCGOP_CALLI`,
  `tcg_call_func`, and `tcg_call_info`.
- Copy modern `TCGTemp` fields into `PTCTemp` without assuming the QEMU 2.4
  layout.
- Decide the opcode compatibility map for generic scalar ops and vector ops.
- Use modern `CPUClass::tcg_ops->get_tb_cpu_state` and `tb_gen_code` or an
  in-tree wrapper for translate-only blocks.
- Keep TB execution and queue replay disabled until translate-only output is
  correct.

## Non-Goals

- No QEMU source or build output is added to the repository.
- No claim is made that QEMU V2 `libtinycode` builds.
- No EVEX or AVX-512 correctness claim is made.
- No dynamic-parallel or concrete-execution parity claim is made.
