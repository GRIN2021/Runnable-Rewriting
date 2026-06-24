# QEMU V2 TCG Op Dump Hook

Date: 2026-06-23
Branch: `codex/qemu-upgrade-v2`
Scratch root: `/tmp/rr-qemu-v2-tcg-op-dump`

## Purpose

This is a practical throwaway experiment for QEMU `10.2.3`. It does not add
QEMU source, patched source, build products, or probe binaries to the repository.
It patches a copied QEMU source tree under `/tmp`, builds `qemu-x86_64`, and
runs the existing `test/qemu-v2-probes` AVX2 and AVX-512 probes with a temporary
TCG op dump hook enabled.

The point is not to make a durable PTC/libtinycode port. The point is to answer
one narrow question before deeper porting work: after modern x86 translation,
does a probe block produce real TCG ops, only instruction markers/control-flow,
or no dump at all?

## Script

Run from the repository root:

```bash
runnable/scripts/qemu_v2_tcg_dump_probe.sh --fresh
```

Useful variants:

```bash
# Reuse an existing downloaded/extracted QEMU source tree.
runnable/scripts/qemu_v2_tcg_dump_probe.sh \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3

# Only create the patch file and print exact manual commands.
runnable/scripts/qemu_v2_tcg_dump_probe.sh --show-instructions

# Reuse an existing patched build and rerun probes.
runnable/scripts/qemu_v2_tcg_dump_probe.sh --run-only
```

Primary outputs:

```text
/tmp/rr-qemu-v2-tcg-op-dump/qemu-10.2.3-tcg-dump.patch
/tmp/rr-qemu-v2-tcg-op-dump/qemu-10.2.3-tcg-dump-src/
/tmp/rr-qemu-v2-tcg-op-dump/build-10.2.3-tcg-dump/qemu-x86_64
/tmp/rr-qemu-v2-tcg-op-dump/probes-build/avx2-vex
/tmp/rr-qemu-v2-tcg-op-dump/probes-build/avx512-evex
/tmp/rr-qemu-v2-tcg-op-dump/dumps/avx2-vex.tcg-ops.txt
/tmp/rr-qemu-v2-tcg-op-dump/dumps/avx512-evex.tcg-ops.txt
```

## Hook Point

The patch modifies QEMU `10.2.3` in:

```text
accel/tcg/translate-all.c::setjmp_gen_code
```

The hook is inserted after:

```c
cs->cc->tcg_ops->translate_code(cs, tb, max_insns, pc, host_pc);
```

and before:

```c
return tcg_gen_code(tcg_ctx, tb, pc);
```

That window is the useful one for this experiment because the frontend has
already decoded guest instructions and emitted TCG IR, but the backend has not
yet lowered, optimized, allocated registers, or generated host code. The dump
uses QEMU's built-in:

```c
tcg_dump_ops(tcg_ctx, stream, false);
```

The hook is environment-gated:

```text
RR_TCG_OP_DUMP=/tmp/path/to/output.txt
RR_TCG_OP_DUMP_PC=401000
```

`RR_TCG_OP_DUMP` enables dumping. `RR_TCG_OP_DUMP_PC` is optional; when set, it
limits output to translation blocks whose start PC matches the probe `_start`
symbol. The script computes that PC with `nm -n`.

## Expected Output

For `avx2-vex`, expect a non-empty dump and QEMU exit code `0`. The dump should
begin with a header like:

```text
==== rr tcg dump: pc=0x401000 tb_pc=0x401000 size=... icount=... nb_ops=... ====
```

Then `tcg_dump_ops` prints instruction markers and TCG ops. Instruction markers
look like:

```text
 ---- 0000000000401000 ...
```

Useful AVX2 evidence is a block with marker lines followed by scalar, vector,
load/store, helper-call, or gvec-related ops. Exact opcode names can vary as
QEMU expands vector operations, so the first-pass check is structural:
non-empty ops after instruction markers means the translator did not silently
consume the VEX instructions without IR.

For `avx512-evex`, the current upstream-baseline expectation is different:
QEMU `10.2.3` linux-user TCG rejects the EVEX/ZMM probe with target `SIGILL`.
The dump may therefore be missing or may contain only code for the fault path
before the unsupported instruction. That is still useful evidence: it shows the
block did not reach a meaningful EVEX/ZMM TCG op sequence.

The script records per-probe exit codes in:

```text
/tmp/rr-qemu-v2-tcg-op-dump/dumps/*.exit-code
```

and stderr/stdout in:

```text
/tmp/rr-qemu-v2-tcg-op-dump/dumps/*.run.log
```

## Interpreting Missing Or Empty Ops

Treat these cases differently:

| Observation | Likely meaning | Next action |
|---|---|---|
| Dump file missing or zero bytes, QEMU exits before running | The patched binary did not load, the env var was not set, or QEMU failed before translating the probe TB. | Check `*.run.log`, confirm `RR_TCG_OP_DUMP` is set, and rerun with `--run-only`. |
| Dump file missing or zero bytes, exit code is `132` or `-4` / `SIGILL` | The CPU feature/decode gate rejected the instruction before useful TB translation. This matches the current AVX-512 baseline failure. | Inspect QEMU CPU feature masks and x86 decode support before PTC work. |
| Header exists but `nb_ops=0` or no marker/op lines follow | The hook fired before useful TCG was present, or translation aborted before emitting ops. | Move the hook later only for diagnosis, or inspect translator abort paths. |
| Only `insn_start`, `exit_tb`, or exception-generation ops appear for EVEX | The instruction was decoded only far enough to raise illegal instruction or exit, not to represent semantics. | Do not count this as AVX-512 semantic support. |
| AVX2 has vector/helper ops but AVX-512 has none | Modern QEMU is usable for AVX2 TCG census but not sufficient for the current libcrypto AVX-512 recall problem. | Keep QEMU `10.2.3` as a source baseline only if an explicit EVEX enablement plan exists. |
| AVX-512 shows real vector/helper ops after EVEX instruction markers | This would contradict the upstream baseline result and is the desired evidence for continuing a PTC dump prototype. | Classify opcode names/arity and map them against `runnable-lift` support. |

An empty AVX-512 dump is not automatically a script failure. It should be read
together with the exit code and run log. For this project, the dangerous case is
not a loud `SIGILL`; it is a block that advances PC while emitting no semantic
TCG ops. This hook is designed to expose that distinction.

## Local Smoke Result

A smoke run against `/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3` validated that
the generated patch applies and builds:

```bash
runnable/scripts/qemu_v2_tcg_dump_probe.sh \
  --scratch-root /tmp/rr-qemu-v2-tcg-op-dump-smoke3 \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  --fresh \
  --apply-patch-only

runnable/scripts/qemu_v2_tcg_dump_probe.sh \
  --scratch-root /tmp/rr-qemu-v2-tcg-op-dump-smoke3 \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  --jobs 3 \
  --build-only

runnable/scripts/qemu_v2_tcg_dump_probe.sh \
  --scratch-root /tmp/rr-qemu-v2-tcg-op-dump-smoke3 \
  --run-only
```

Observed result:

```text
avx2-vex: qemu rc=0, dump header size=43 icount=9 nb_ops=91
avx512-evex: qemu rc=132, dump header size=2 icount=1 nb_ops=8
```

The AVX2 dump included real vector/helper activity such as `ld_vec`,
`st_vec`, `qemu_ld2_i128`, `qemu_st2_i128`, `pshufb_ymm`, and `vpermdq_ymm`.
The AVX-512 dump did not include ZMM semantics; it contained an instruction
marker at `_start`, `mov_i64 rip,$0x401000`, `call raise_exception`, and
`exit_tb`. That means QEMU `10.2.3` rejected the first EVEX instruction loudly
rather than silently translating it to an empty semantic block.

## Patch Shape

The generated patch is intentionally minimal:

1. Include no new source files.
2. Do not change normal QEMU behavior unless `RR_TCG_OP_DUMP` is set.
3. Open one output stream per process.
4. Optionally filter by start PC through `RR_TCG_OP_DUMP_PC`.
5. Dump immediately after `translate_code` and before `tcg_gen_code`.

If the automatic patch ever fails against a nearby QEMU checkout, run:

```bash
runnable/scripts/qemu_v2_tcg_dump_probe.sh --show-instructions
```

Then apply the emitted patch manually under `/tmp`. Do not apply it to the
repository `qemu/` directory and do not commit QEMU source or build outputs.
