# Ubuntu 24.04 LLVM 18 Runtime and bzip Lift Status

Date: 2026-06-26

## Goal

Check whether the migrated Ubuntu 24.04 / LLVM 18 runtime can run a SPEC bzip
lift, then report precision and recall.

## Runtime State

The QEMU V2 runtime image now builds from Ubuntu 24.04:

```bash
docker build -t rr_qemu_v2_runtime:latest docker/qemu-v2-runtime
```

Verified in the container:

```text
Ubuntu 24.04.4 LTS
llvm-config --version = 18.1.3
llvm-config --cmakedir = /usr/lib/llvm-18/lib/cmake/llvm
```

`runnable-lift` also builds and passes the lightweight verify path:

```bash
docker run --rm \
  -v "$PWD":/workspace/Runnable-Rewriting \
  -v /tmp/rr-runnable-lift-llvm18-host:/tmp/rr-runnable-lift-llvm18 \
  -w /workspace/Runnable-Rewriting \
  rr_qemu_v2_runtime:latest \
  bash runnable/scripts/build_runnable_lift_v2.sh \
    --no-docker \
    --build-dir /tmp/rr-runnable-lift-llvm18 \
    --jobs 2 \
    --verify
```

Result:

```text
BUILD_OK=1
RUNNABLE_LIFT=/tmp/rr-runnable-lift-llvm18/tools/runnable-lift/runnable-lift
LD_LIBRARY_PATH=/tmp/rr-runnable-lift-llvm18/lib/StackAnalysis:...:/usr/lib/llvm-18/lib
```

## bzip New Lift Attempt

Test target:

```text
test/spec/bzip2_base.x86.O1
```

The first attempt staged the current source-tree `libtinycode-x86_64.so` next to
the LLVM 18 `runnable-lift`. That library is the QEMU V2 empty-stub transition
artifact, so lift is intentionally refused:

```text
runnable-lift: PTC ABI metadata detected abi_version=2 stub_kind=<unknown> real_translation=false vector_schema=<unknown>
runnable-lift: refusing QEMU V2 empty-stub library: real_translation=false
```

The second attempt staged the larger existing real legacy runtime from:

```text
build-codex-dynamic-current/tools/runnable-lift/libtinycode-x86_64.so
build-codex-dynamic-current/tools/runnable-lift/libtinycode-helpers-x86_64.ll
```

This progressed further but exposed two compatibility gaps:

1. The helper IR is LLVM 7-era IR. LLVM 18 rejects old `sret` / `byval`
   attribute syntax, for example:

   ```text
   error: expected '('
     call void @float32ToCommonNaN(%struct.commonNaNT* sret %9, ...)
   ```

2. After locally upgrading the staged helper IR copy to LLVM 18-compatible
   `sret(%struct.commonNaNT)` / `byval(%struct.commonNaNT)` syntax, execution
   still segfaulted inside the legacy `libtinycode` generated code:

   ```text
   Thread 1 "runnable-lift" received signal SIGSEGV, Segmentation fault.
   0x... in static_code_gen_buffer () from /tmp/build/tools/runnable-lift/libtinycode-x86_64.so
   #1 cpu_tb_exec(...)
   #2 ptc_translate(...)
   #3 CodeGenerator::translate(...)
   ```

`bzip2_base.x86.O0` was also tested and failed with a similar runtime instability
class, including pass registry errors and stack smashing before segfault.

The old matched `build-codex-dynamic-current/tools/runnable-lift/runnable-lift`
binary is not usable in the Ubuntu 24.04 runtime because it still depends on
LLVM 7 shared objects:

```text
error while loading shared libraries: libLLVMIRReader.so.7: cannot open shared object file
```

## Code Fixes Made While Testing

These fixes were needed to get beyond early LLVM 18 runtime blockers:

- `BinaryFile.cpp`: accept lowercase LLVM 18 file format names such as
  `elf64-x86-64` instead of requiring `ELF`.
- `VariableManager.cpp`: infer pointee struct types under opaque pointers by
  following helper function parameter uses through store/load/GEP chains.
- `JumpTargetManager.cpp`: skip mutating LLVM command-line options with
  `setInitialValue()` on LLVM 15+, which segfaulted under LLVM 18.

After these fixes, `build_runnable_lift_v2.sh --verify` still passes.

## Precision / Recall From Existing bzip Artifact

Because the current Ubuntu 24.04 path cannot generate a fresh bzip `.ll` yet,
precision/recall was computed from the existing bzip O2 artifact:

```text
/tmp/rr-spec2006-qemu-v2-20260624-smoke2/bzip2_base.x86.O2.ll
```

Compared against:

```text
test/spec/bzip2_base.x86.O2
```

Command:

```bash
python3 runnable/scripts/run_cmp_eval.py \
  --binary /tmp/rr-bzip-eval/bzip2_base.x86.O2.stripped \
  --ll /tmp/rr-spec2006-qemu-v2-20260624-smoke2/bzip2_base.x86.O2.ll \
  --json-out /tmp/rr-bzip-eval/bzip2_base.x86.O2.existing.cmp.json \
  --text-out /tmp/rr-bzip-eval/bzip2_base.x86.O2.existing.cmp.txt
```

Metrics:

```text
obj_count=13286
ll_count=13319
hit=13281
mismatch=0
obj_only=5
ll_only=38
false_negative=5
false_positive=38
precision=0.997147
recall=0.999624
```

## Current Conclusion

The Ubuntu 24.04 / LLVM 18 `runnable-lift` binary is buildable and loadable, but
fresh bzip lifting is not yet normal because the runtime `libtinycode` side is
not fully migrated:

- QEMU V2 default shim is still `real_translation=false`.
- Existing real legacy `libtinycode` can load on Ubuntu 24.04, but its helper IR
  and generated-code execution path are not a stable match for the LLVM 18
  `runnable-lift` pipeline.

The next required milestone is a real Ubuntu 24.04-compatible
`libtinycode-x86_64.so` plus LLVM 18-compatible helper IR, not another
`runnable-lift` CMake-only fix.

## Final Update

The bzip O2 fresh lift now succeeds with Ubuntu 24.04 / LLVM 18 after fixing
both runnable-lift and the real legacy PTC runtime path.

Root causes found:

- LLVM 18 requires explicit legacy pass initialization before the old pass
  manager pipeline can use DCE and related passes.
- Legacy helper IR generated by the old QEMU/LLVM toolchain uses LLVM 7
  `sret` / `byval` syntax. `CodeGenerator::parseIR()` now falls back to a
  small in-memory syntax upgrade before reparsing.
- `libtinycode` installed a process-global `SIGSEGV` / `SIGBUS` handler that
  blindly longjmped through stale PTC state. That masked real LLVM-side crashes
  as hangs. PTC now longjmps only while executing a TB, and PTC fault returns no
  longer expose the faulting PC as a dynamic successor.
- `ptc_exec()` / `ptc_exec1()` / `ptc_run_library()` needed the same guarded
  TB-execution window as `ptc_translate()`, because jump-table probing also
  executes generated code.
- `CPUStateAccessAnalysisPass` created case blocks detached from their function
  and then used `IRBuilder` on them. LLVM 18 load creation consults the parent
  module through the insertion block, so these blocks must be inserted before
  instructions are built.
- `DebugHelper` assumed debug metadata constants were always wrapped in a
  `ConstantExpr`; LLVM 18 can expose a `GlobalVariable` directly.
- Static and branch frontier target queues needed stricter `isPC()` filtering
  to avoid data/host-like addresses entering PTC exploration.

Fresh lift verification:

```text
LIFT_RC=0
stdout: Rewrite Successful
ll: /tmp/rr-bzip-llvm18-debug/bzip2_base.x86.O2.ll
```

Final compare result:

```text
obj_count=13286
ll_count=13300
hit=13281
mismatch=0
false_negative=5
false_positive=19
precision=0.998571
recall=0.999624
```

This matches the old recall (`0.999624`) and improves precision versus the
previous artifact (`0.997147` -> `0.998571`).
