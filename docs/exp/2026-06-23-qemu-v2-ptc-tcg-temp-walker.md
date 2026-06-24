# QEMU V2 PTC TCGTemp Walker

Date: 2026-06-23
Scratch root: `/tmp/rr-qemu-v2-ptc-tcg-temp-walker-task-t`
Related script: `runnable/scripts/qemu_v2_ptc_tcg_op_walker_probe.sh`

## Goal

Extend the C-side TCGOp walker probe so it also emits machine-readable
`TCGTemp` metadata records. This is a preparatory step for replacing the JSONL
probe with a real `PTCTemp` table in the modern QEMU `10.2.3` PTC adapter.

## JSONL Contract

The walker now emits:

```json
{"record":"tb","event":"tb", "...":"..."}
{"record":"temp","event":"temp", "...":"..."}
{"record":"op","event":"op", "...":"..."}
```

The `event` field is retained so older consumers that filter
`"event":"op"` continue to work. New consumers should prefer `record`.

Temp records are emitted before op records for the same TB. The stable key is
`temp_id`, which equals the `ctx->temps[]` index for that TB. Op records include
`arg_temp_ids`; each element is either a `temp_id` or `null` for immediates,
labels, call metadata, or other non-temp arguments.

Example join:

```json
{"record":"temp","temp_id":43,"arg":"0x5d168ac131a8","type_name":"TCG_TYPE_I64"}
{"record":"op","name":"ld","args":["0x5d168ac131a8","0x5d168ac12840","0xffffffffffffffec"],"arg_temp_ids":[43,0,null]}
```

## Mapping To Old `PTCTemp`

The old QEMU-side `PTCTemp` copy logic came from the QEMU 2.4 layout:

| Old `PTCTemp` field | Modern JSONL source | Status |
|---|---|---|
| `reg` | `reg` | Direct field exists. At this probe point it is pre-regalloc for most temps, so it should not be treated as final host allocation. |
| `mem_reg` | None directly | Missing direct equivalent. Use `mem_base_id` to find the base temp, then derive from that temp's `reg` only when the adapter explicitly wants QEMU 2.4 compatibility. |
| `val_type` | `val_type` / `val_type_name` | Direct field exists, but after `translate_code` most records still show initial values rather than post-regalloc liveness. |
| `base_type` | `base_type` / `base_type_name` | Direct and important for split/wide temps. |
| `type` | `type` / `type_name` | Direct and important for scalar/vector typing. |
| `fixed_reg` | `kind_name == "TEMP_FIXED"` | Derived. Modern QEMU represents this through `TCGTempKind`. |
| `mem_coherent` | `mem_coherent` | Direct field exists. |
| `mem_allocated` | `mem_allocated` | Direct field exists. |
| `temp_local` | `kind_name == "TEMP_TB"` is the closest candidate | Not a direct semantic match. Modern QEMU distinguishes `TEMP_EBB`, `TEMP_TB`, `TEMP_GLOBAL`, `TEMP_FIXED`, and `TEMP_CONST`; the adapter should preserve `kind` rather than collapse this too early. |
| `temp_allocated` | `temp_allocated` | Direct field exists. |
| `val` | `val` / `val_s` | Direct field exists. For `TEMP_CONST`, this is meaningful. For other temps, treat according to `val_type/kind`. |
| `mem_offset` | `mem_offset` / `mem_offset_hex` | Direct field exists. |
| `name` | `temp_name` | Direct when QEMU assigns a name; many transient temps have `null`. |

Modern fields that should be kept in a v2 `PTCTemp` instead of forcing the old
shape are `kind`, `mem_base_id`, `indirect_reg`, `indirect_base`,
`temp_subindex`, `state`, and `state_ptr`.

## Verified Counts

The patch/build/run command was:

```bash
runnable/scripts/qemu_v2_ptc_tcg_op_walker_probe.sh \
  --scratch-root /tmp/rr-qemu-v2-ptc-tcg-temp-walker-task-t \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3
```

Record counts:

```text
avx2-vex: tb=1, op=91, temp=93, qemu rc=0
avx512-evex: tb=1, op=8, temp=48, qemu rc=132 target SIGILL
```

AVX2 temp distribution:

```text
TEMP_FIXED=2, TEMP_GLOBAL=35, TEMP_TB=21, TEMP_CONST=16, TEMP_EBB=19
TCG_TYPE_I64=65, TCG_TYPE_I32=7, TCG_TYPE_V256=4, TCG_TYPE_V128=17
```

## Remaining Gaps

The JSONL probe does not yet allocate a real `PTCInstructionList` or `PTCTemp`
array. It only proves the safe source fields and join keys.

The old `mem_reg`, `fixed_reg`, and `temp_local` shape needs an explicit
compatibility policy. Directly copying those names would hide modern QEMU's
`kind/mem_base` semantics.

Helper call metadata is still only preserved through raw op args and existing
call arity fields. A real adapter still needs `tcg_call_func(op)` and
`tcg_call_info(op)` handling.

Vector temp types are visible (`TCG_TYPE_V128`, `TCG_TYPE_V256`), but
runnable-lift still needs a real v2 operand schema and semantics for vector ops
before AVX/AVX2 correctness can be claimed.
