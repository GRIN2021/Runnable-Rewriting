# QEMU V2 PTC In-Library Live Translate Spike

Date: 2026-06-24
Tool: `runnable/scripts/qemu_v2_ptc_inlibrary_live_translate_spike.sh`

## Purpose

Attempt the stronger PTC bridge: make a `/tmp/libtinycode-x86_64.so` whose
`ptc_translate` path itself reaches live QEMU translation/walker plumbing, then
fills a `PTCInstructionList` using the exact repo `qemu/linux-user/ptc.h`.

This pass did not achieve the strong outcome. It produced a compiling candidate
object and a precise linker blocker for embedding the existing QEMU linux-user
TCG translation objects into a shared `libtinycode`.

## Command

```bash
bash runnable/scripts/qemu_v2_ptc_inlibrary_live_translate_spike.sh --fresh
```

Scratch root:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-inlibrary-live-translate-spike
```

Generated candidate:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-inlibrary-live-translate-spike/qemu_v2_ptc_inlibrary_live_translate_candidate.c
```

Candidate object:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-inlibrary-live-translate-spike/qemu_v2_ptc_inlibrary_live_translate_candidate.o
```

Strong dynamic library path if created:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-inlibrary-live-translate-spike/libtinycode-x86_64.so
```

Result: not created.

Summary JSON:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-inlibrary-live-translate-spike/qemu_v2_ptc_inlibrary_live_translate_spike.summary.json
```

## Strong Attempt

The script generated a candidate `ptc_translate` implementation that includes
the exact repo `qemu/linux-user/ptc.h` and intentionally calls QEMU
`translator_loop` rather than falling back to a model payload. It then attempted
to link that candidate into `libtinycode-x86_64.so` with existing QEMU 10.2.3
linux-user build objects from:

```text
/tmp/rr-qemu-v2-upstream-probes/build-10.2.3
```

Objects attempted:

```text
/tmp/rr-qemu-v2-upstream-probes/build-10.2.3/libuser.a.p/accel_tcg_translator.c.o
/tmp/rr-qemu-v2-upstream-probes/build-10.2.3/libuser.a.p/accel_tcg_translate-all.c.o
/tmp/rr-qemu-v2-upstream-probes/build-10.2.3/libqemu-x86_64-linux-user.a.p/target_i386_tcg_translate.c.o
/tmp/rr-qemu-v2-upstream-probes/build-10.2.3/libuser.a.p/tcg_tcg.c.o
/tmp/rr-qemu-v2-upstream-probes/build-10.2.3/libuser.a.p/tcg_tcg-op.c.o
/tmp/rr-qemu-v2-upstream-probes/build-10.2.3/libuser.a.p/tcg_tcg-op-ldst.c.o
/tmp/rr-qemu-v2-upstream-probes/build-10.2.3/libuser.a.p/tcg_optimize.c.o
```

Compile result:

```text
candidate compiled against exact repo ptc.h
compile_log=/tmp/rr-qemu-v2-upstream-probes/ptc-inlibrary-live-translate-spike/compile.log
```

Link command failed:

```text
link_rc=1
link_log=/tmp/rr-qemu-v2-upstream-probes/ptc-inlibrary-live-translate-spike/link.log
```

Exact linker blocker:

```text
/usr/bin/ld: /tmp/rr-qemu-v2-upstream-probes/build-10.2.3/libuser.a.p/tcg_tcg.c.o: relocation R_X86_64_TPOFF32 against symbol `tcg_ctx' can not be used when making a shared object; recompile with -fPIC
/usr/bin/ld: failed to set dynamic section sizes: bad value
collect2: error: ld returned 1 exit status
```

## Interpretation

Strong in-library live translation was not achieved. The immediate concrete
blocker is that QEMU's existing linux-user TCG objects were not built as a
reusable PIC shared-library dependency. The first hard failure is non-PIC TLS
relocation for `tcg_ctx` from `tcg_tcg.c.o`.

This is a stronger blocker than a missing symbol: the current available QEMU
build artifacts cannot be directly embedded into `libtinycode-x86_64.so`.
Even after a PIC/shared build, the bridge still needs explicit QEMU-owned
initialization for the linux-user translation graph: CPUState/X86CPU setup,
TCGContext, TranslationBlock, target page/mmap state, and byte mapping before
`ptc_translate` can safely call a live walker and allocate exact `ptc.h`
`PTCInstructionList` memory.

## Fallback Comparison

The same spike also ran the existing fallback bridge once for comparison. This
is not the strong outcome: it regenerated the live walker/model in the same run,
then built a model-backed dynamic library.

Fallback summary:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-inlibrary-live-translate-spike/bridge-fallback/qemu_v2_ptc_live_translate_bridge_smoke.summary.json
```

Fallback dynamic library:

```text
/tmp/rr-qemu-v2-upstream-probes/ptc-inlibrary-live-translate-spike/bridge-fallback/dynamic/libtinycode-x86_64.so
```

Fallback counts:

| Counter | Count |
|---|---:|
| instruction_count | 45 |
| argument_count | 115 |
| temp_count | 93 |
| live_walker_regenerated_same_run | true |
| model_backed | true |

The fallback dynamic metadata still reports:

```text
stub_kind=scalar_model_backed
real_translation=false
model_source=scalar-simple.ptc-conversion-model.json
```

## Validation

Static check:

```bash
bash -n runnable/scripts/qemu_v2_ptc_inlibrary_live_translate_spike.sh
```

Runtime spike:

```text
in-library live translate spike complete:
  scratch_root=/tmp/rr-qemu-v2-upstream-probes/ptc-inlibrary-live-translate-spike
  candidate_object=/tmp/rr-qemu-v2-upstream-probes/ptc-inlibrary-live-translate-spike/qemu_v2_ptc_inlibrary_live_translate_candidate.o
  dynamic_library=not-created
  link_rc=1
  link_log=/tmp/rr-qemu-v2-upstream-probes/ptc-inlibrary-live-translate-spike/link.log
  summary=/tmp/rr-qemu-v2-upstream-probes/ptc-inlibrary-live-translate-spike/qemu_v2_ptc_inlibrary_live_translate_spike.summary.json
```

## Next Implementation Plan

1. Under `/tmp`, patch/copy QEMU to add an exported
   `rr_ptc_translate_one_tb(CPUState *, vaddr, PTCInstructionList *)` helper
   near the existing walker hook in `setjmp_gen_code`, while `TCGContext` and
   the translated TB are live.
2. Build that patched path as an intentional PIC/shared QEMU-derived artifact,
   not by ad hoc linking Meson private non-PIC objects from `qemu-x86_64`.
3. Make `libtinycode-x86_64.so` own `ptc_load` initialization: create/configure
   an X86CPU, initialize linux-user TCG/page/mmap state, map caller bytes, call
   the exported helper from `ptc_translate`, and allocate/free exact `ptc.h`
   `PTCInstructionList` structures.
