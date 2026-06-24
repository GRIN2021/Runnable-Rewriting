# QEMU V2 PTC TCGOp Walker Probe

Date: 2026-06-23
Scratch root: `/tmp/rr-qemu-v2-ptc-tcg-temp-walker-task-t`
Script: `runnable/scripts/qemu_v2_ptc_tcg_op_walker_probe.sh`

## Purpose

This experiment validates the C-side shape needed for a real modern
`dump_tinycode(TCGContext*) -> PTCInstructionList` port. It patches a copied
QEMU `10.2.3` tree under `/tmp`, builds `x86_64-linux-user`, hooks
`accel/tcg/translate-all.c::setjmp_gen_code` after:

```c
cs->cc->tcg_ops->translate_code(cs, tb, max_insns, pc, host_pc);
```

and before:

```c
return tcg_gen_code(tcg_ctx, tb, pc);
```

The hook is disabled by default. It only writes JSONL when
`RR_PTC_OP_WALK_DUMP=/tmp/...` is set, and `RR_PTC_OP_WALK_PC=...` optionally
filters by translation-block start PC.

## C-Side Access Pattern

The patch walks modern QEMU ops directly:

```c
QTAILQ_FOREACH(op, &ctx->ops, link) {
    def = &tcg_op_defs[op->opc];
    name = def->name;
    arg_count = op->opc == INDEX_op_call
        ? TCGOP_CALLO(op) + TCGOP_CALLI(op) + 2
        : def->nb_args;
}
```

It now emits three JSONL record classes, each with both `record` and legacy
`event` tags:

| Record | Purpose |
|---|---|
| `record:"tb"` | One TB header with `tb_pc`, `pc`, `tb_size`, `tb_icount`, `tb_nb_ops`, `nb_temps`, and `nb_globals`. |
| `record:"temp"` | One `TCGTemp` metadata record for each `ctx->temps[0..nb_temps)`. |
| `record:"op"` | Existing op walker record, still carrying `event:"op"`, raw `args[]`, opcode name, arity, params, and life fields. |

Op records keep the previous raw fields for compatibility. The only additive
op-side field is `arg_temp_ids`, which resolves raw temp-pointer arguments to
the stable temp table index when the argument falls inside
`ctx->temps[0..nb_temps)`, otherwise `null`.

## Temp Metadata

The temp walker uses `temp_id == temp_index == &ctx->temps[i] - ctx->temps`.
This is stable inside the current TB and is the correct key for a modern
`PTCTemp` table. Each temp record also emits `arg:"0x..."`, the raw
`temp_arg(&ctx->temps[i])` value, so existing raw op `args[]` can be joined
back to the temp table.

Safe fields emitted from QEMU `10.2.3` include:

| Field group | JSON fields |
|---|---|
| Identity | `temp_index`, `temp_id`, `arg`, `is_global` |
| Kind and type | `kind`, `kind_name`, `base_type`, `base_type_name`, `type`, `type_name`, `val_type`, `val_type_name` |
| Storage/value | `reg`, `val`, `val_s`, `mem_base_id`, `mem_base_arg`, `mem_offset`, `mem_offset_hex` |
| Flags/name | `indirect_reg`, `indirect_base`, `mem_coherent`, `mem_allocated`, `temp_allocated`, `temp_subindex`, `temp_name` |
| Opaque pass state | `state`, `state_ptr` |

`state_ptr` is reported only as an opaque pointer value. It is not safe to
interpret in the JSONL adapter.

## Validation Result

Build and run completed with all QEMU source/build/output under `/tmp`:

```text
/tmp/rr-qemu-v2-ptc-tcg-temp-walker-task-t/qemu-10.2.3-ptc-tcg-op-walker-src/
/tmp/rr-qemu-v2-ptc-tcg-temp-walker-task-t/build-10.2.3-ptc-tcg-op-walker/qemu-x86_64
/tmp/rr-qemu-v2-ptc-tcg-temp-walker-task-t/dumps/avx2-vex.tcg-op-walk.jsonl
/tmp/rr-qemu-v2-ptc-tcg-temp-walker-task-t/dumps/avx512-evex.tcg-op-walk.jsonl
```

Commands used:

```bash
runnable/scripts/qemu_v2_ptc_tcg_op_walker_probe.sh \
  --scratch-root /tmp/rr-qemu-v2-ptc-tcg-temp-walker-task-t \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  --fresh --apply-patch-only

runnable/scripts/qemu_v2_ptc_tcg_op_walker_probe.sh \
  --scratch-root /tmp/rr-qemu-v2-ptc-tcg-temp-walker-task-t \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3
```

Observed:

```text
avx2-vex: rc=0, 185 JSONL lines, 1 tb record, 91 op records, 93 temp records
avx512-evex: rc=132, SIGILL, 57 JSONL lines, 1 tb record, 8 op records, 48 temp records
```

AVX2 temp summary:

```text
kind: TEMP_FIXED=2, TEMP_GLOBAL=35, TEMP_TB=21, TEMP_CONST=16, TEMP_EBB=19
type: TCG_TYPE_I64=65, TCG_TYPE_I32=7, TCG_TYPE_V256=4, TCG_TYPE_V128=17
```

AVX2 top opcode names:

```text
18 st_vec
18 mov_vec
9 mov
9 insn_start
8 add
5 ld
4 st
4 call
3 discard
2 st8
2 qemu_st2
2 qemu_ld2
2 extract
2 exit_tb
1 set_label
1 ld_vec
1 brcond
```

This proves the hook can see non-empty modern vector and memory TCG ops plus
their temp metadata directly from `tcg_ctx` after `translate_code`. The AVX-512
aggregate probe still raises target `SIGILL`; its walker output contains only
the fault-path block, not ZMM semantics.

## Difference From Text `tcg_dump_ops`

The existing text dump is human-readable and type-decorated, for example it
prints names like `ld_i64` or `qemu_ld2_i128` and formats memory arguments.
This walker emits QEMU's raw modern op identity: generic opcode names such as
`ld`, `st`, `add`, `qemu_ld2`, plus `param1`/`param2` type fields, raw args,
and now stable temp IDs.

That difference matters for PTC migration. A real adapter must synthesize old
typed names or new PTC v2 opcodes from `TCGOpDef`, `TCGOP_TYPE(op)`,
`TCGOP_VECE(op)`, temp `type/base_type`, and memory/call-specific layouts,
rather than parse pretty-printed text.

## PTCInstructionList Next Step

The next implementation step is to replace the JSONL writer with allocation of
a `PTCInstructionList`:

1. Copy `tcg_ctx->temps[0..nb_temps)` into modernized `PTCTemp` records keyed by `temp_id`.
2. Convert each `TCGOp` into a PTC instruction while preserving op order and using `arg_temp_ids` for temp operands.
3. Map `INDEX_op_insn_start` to the current lift-side instruction marker ABI or add an explicit v2 marker.
4. For scalar integer ops, combine generic opcode plus `TCGOP_TYPE(op)` into the legacy `_i32`/`_i64` forms where safe.
5. For calls, store `TCGOP_CALLO`, `TCGOP_CALLI`, raw temp args, function pointer, and `TCGHelperInfo *` metadata.
6. For vector and paired memory ops (`*_vec`, `qemu_ld2`, `qemu_st2`), add a v2 operand schema or emit explicit unsupported markers until runnable-lift has real semantics.

The successful AVX2 walker result makes the C-side traversal viable. The EVEX
boundary remains separate: QEMU `10.2.3` rejects this aggregate ZMM probe before
emitting useful AVX-512 semantics.
