# QEMU V2 EVEX Aggregate Inventory

Date: 2026-06-23
Branch: `codex/qemu-upgrade-v2`
Tool: `runnable/scripts/qemu_v2_evex_aggregate_inventory.py`

## Purpose

This adds an offline instruction-queue inventory for the aggregate AVX-512 EVEX
probe at `test/qemu-v2-probes/avx512-evex.S`.

The tool compiles the probe or accepts an already-built probe binary, runs
`objdump -d -Mintel`, reconstructs objdump-wrapped byte lines, and records each
`_start` instruction as address, exact bytes, mnemonic, operands, and dispatch
status.

It does not run QEMU. The output is intended to keep subagent dispatch aligned
to the next aggregate failure point.

## Status Rules

- `implemented-smoke`: exact aggregate bytes already covered by exact-byte smoke
  work: `vpxorq`, `vmovdqa64`, both aggregate `vmovdqu64` forms, `vpshufb`,
  `vpaddd`, `vpternlogq`, `vpclmullqlqdq`, `vpclmullqhqdq`, and
  `vpclmulhqlqdq`.
- `next`: current aggregate boundary, `vpclmulhqhqdq` at `0x401048`.
- `pending`: later EVEX instructions not covered by exact-byte smoke yet.
- `non-evex`: cleanup/syscall instructions outside the AVX-512 queue.

## Tool Usage

Default source and build-dir mode:

```bash
python3 runnable/scripts/qemu_v2_evex_aggregate_inventory.py \
  --build-dir /tmp/rr-qemu-v2-evex-aggregate-inventory/build \
  --markdown-out /tmp/rr-qemu-v2-evex-aggregate-inventory/inventory.md \
  --json-out /tmp/rr-qemu-v2-evex-aggregate-inventory/inventory.json
```

Already-built binary mode:

```bash
python3 runnable/scripts/qemu_v2_evex_aggregate_inventory.py \
  --binary /tmp/rr-qemu-v2-evex-aggregate-inventory/build/avx512-evex \
  --build-dir /tmp/rr-qemu-v2-evex-aggregate-inventory/build \
  --markdown-out /tmp/rr-qemu-v2-evex-aggregate-inventory/inventory-from-binary.md \
  --json-out /tmp/rr-qemu-v2-evex-aggregate-inventory/inventory-from-binary.json
```

When `--binary` exists, the tool only needs `objdump`; `--source` and `cc` are
used only if a binary must be compiled.

Supported path options:

- `--source`
- `--binary`
- `--build-dir`
- `--markdown-out`
- `--json-out`
- `--status-json`

Optional status override format:

```json
{
  "statuses": {
    "implemented-smoke": {
      "62 73 55 48 44 cc 11": "temporary override: vpclmulhqhqdq exact-byte smoke"
    },
    "next": {
      "62 52 35 48 dc d0": "temporary override: vaesenc boundary"
    }
  }
}
```

The override map overlays the built-in byte-status map by default. Set
`"replace_defaults": true` when the JSON should provide the complete status
map instead.

## Validation

Syntax check:

```bash
python3 -m py_compile runnable/scripts/qemu_v2_evex_aggregate_inventory.py
```

Compile plus objdump inventory:

```bash
python3 runnable/scripts/qemu_v2_evex_aggregate_inventory.py \
  --build-dir /tmp/rr-qemu-v2-evex-aggregate-inventory/build \
  --markdown-out /tmp/rr-qemu-v2-evex-aggregate-inventory/inventory.md \
  --json-out /tmp/rr-qemu-v2-evex-aggregate-inventory/inventory.json
```

Observed result:

```text
+ cc -nostdlib -no-pie -Wl,--build-id=none -o /tmp/rr-qemu-v2-evex-aggregate-inventory/build/avx512-evex /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting/test/qemu-v2-probes/avx512-evex.S
+ objdump -d -Mintel /tmp/rr-qemu-v2-evex-aggregate-inventory/build/avx512-evex
inventory: 23 instructions, 19 EVEX, 10 implemented-smoke, 1 next, 8 pending
```

Already-built binary mode:

```bash
python3 runnable/scripts/qemu_v2_evex_aggregate_inventory.py \
  --binary /tmp/rr-qemu-v2-evex-aggregate-inventory/build/avx512-evex \
  --build-dir /tmp/rr-qemu-v2-evex-aggregate-inventory/build \
  --markdown-out /tmp/rr-qemu-v2-evex-aggregate-inventory/inventory-from-binary.md \
  --json-out /tmp/rr-qemu-v2-evex-aggregate-inventory/inventory-from-binary.json
```

Observed result:

```text
+ objdump -d -Mintel /tmp/rr-qemu-v2-evex-aggregate-inventory/build/avx512-evex
inventory: 23 instructions, 19 EVEX, 10 implemented-smoke, 1 next, 8 pending
```

Status JSON override mode:

```bash
python3 runnable/scripts/qemu_v2_evex_aggregate_inventory.py \
  --binary /tmp/rr-qemu-v2-evex-aggregate-inventory/build/avx512-evex \
  --build-dir /tmp/rr-qemu-v2-evex-aggregate-inventory/build \
  --status-json /tmp/rr-qemu-v2-evex-aggregate-inventory/status-overlay-check.json \
  --markdown-out /tmp/rr-qemu-v2-evex-aggregate-inventory/inventory-status-json.md \
  --json-out /tmp/rr-qemu-v2-evex-aggregate-inventory/inventory-status-json.json
```

Observed result with a temporary override that promotes `vpclmulhqhqdq` and
moves `next` to `vaesenc`:

```text
+ objdump -d -Mintel /tmp/rr-qemu-v2-evex-aggregate-inventory/build/avx512-evex
inventory: 23 instructions, 19 EVEX, 11 implemented-smoke, 1 next, 7 pending
```

Generated artifacts:

- `/tmp/rr-qemu-v2-evex-aggregate-inventory/inventory.md`
- `/tmp/rr-qemu-v2-evex-aggregate-inventory/inventory.json`
- `/tmp/rr-qemu-v2-evex-aggregate-inventory/inventory-from-binary.md`
- `/tmp/rr-qemu-v2-evex-aggregate-inventory/inventory-from-binary.json`
- `/tmp/rr-qemu-v2-evex-aggregate-inventory/inventory-status-json.md`
- `/tmp/rr-qemu-v2-evex-aggregate-inventory/inventory-status-json.json`

## Inventory Summary

| Metric | Value |
| --- | ---: |
| Total instructions | 23 |
| EVEX instructions | 19 |
| `implemented-smoke` | 10 |
| `next` | 1 |
| `pending` | 8 |
| `non-evex` | 4 |

## First 10 Instructions

| # | Address | Bytes | Instruction | Status |
| --- | --- | --- | --- | --- |
| 1 | `0x401000` | `62 f1 fd 48 ef c0` | `vpxorq zmm0,zmm0,zmm0` | `implemented-smoke` |
| 2 | `0x401006` | `62 f1 fd 48 6f c8` | `vmovdqa64 zmm1,zmm0` | `implemented-smoke` |
| 3 | `0x40100c` | `62 f1 fe 48 7f 0d ea 0f 00 00` | `vmovdqu64 ZMMWORD PTR [rip+0xfea],zmm1` | `implemented-smoke` |
| 4 | `0x401016` | `62 f1 fe 48 6f 15 e0 0f 00 00` | `vmovdqu64 zmm2,ZMMWORD PTR [rip+0xfe0]` | `implemented-smoke` |
| 5 | `0x401020` | `62 f2 6d 48 00 da` | `vpshufb zmm3,zmm2,zmm2` | `implemented-smoke` |
| 6 | `0x401026` | `62 f1 65 48 fe e2` | `vpaddd zmm4,zmm3,zmm2` | `implemented-smoke` |
| 7 | `0x40102c` | `62 f3 dd 48 25 eb 96` | `vpternlogq zmm5,zmm4,zmm3,0x96` | `implemented-smoke` |
| 8 | `0x401033` | `62 f3 55 48 44 f4 00` | `vpclmullqlqdq zmm6,zmm5,zmm4` | `implemented-smoke` |
| 9 | `0x40103a` | `62 f3 55 48 44 fc 10` | `vpclmullqhqdq zmm7,zmm5,zmm4` | `implemented-smoke` |
| 10 | `0x401041` | `62 73 55 48 44 c4 01` | `vpclmulhqlqdq zmm8,zmm5,zmm4` | `implemented-smoke` |

## Pending Queue

Dispatch order starts with the `next` row and then proceeds through later
`pending` EVEX rows.

| # | Address | Bytes | Instruction | Status |
| --- | --- | --- | --- | --- |
| 11 | `0x401048` | `62 73 55 48 44 cc 11` | `vpclmulhqhqdq zmm9,zmm5,zmm4` | `next` |
| 12 | `0x40104f` | `62 52 35 48 dc d0` | `vaesenc zmm10,zmm9,zmm8` | `pending` |
| 13 | `0x401055` | `62 72 2d 48 dd df` | `vaesenclast zmm11,zmm10,zmm7` | `pending` |
| 14 | `0x40105b` | `62 72 fd 48 1a 25 9b 0f 00 00` | `vbroadcastf64x2 zmm12,XMMWORD PTR [rip+0xf9b]` | `pending` |
| 15 | `0x401065` | `62 d1 15 48 73 fc 04` | `vpslldq zmm13,zmm12,0x4` | `pending` |
| 16 | `0x40106c` | `62 d1 0d 48 73 dd 04` | `vpsrldq zmm14,zmm13,0x4` | `pending` |
| 17 | `0x401073` | `62 53 7d 48 39 f7 01` | `vextracti32x4 xmm15,zmm14,0x1` | `pending` |
| 18 | `0x40107a` | `62 33 fd 48 3b f0 01` | `vextracti64x4 ymm16,zmm14,0x1` | `pending` |
| 19 | `0x401081` | `62 71 7f 48 7f 35 75 0f 00 00` | `vmovdqu8 ZMMWORD PTR [rip+0xf75],zmm14` | `pending` |

## Notes

The exact failure boundary is now:

```text
0x401048: 62 73 55 48 44 cc 11    vpclmulhqhqdq zmm9,zmm5,zmm4
```

`vpclmullqlqdq`, `vpclmullqhqdq`, and `vpclmulhqlqdq` are now recorded as
`implemented-smoke` after exact-byte smoke and patch-series validation passed.
The next queue entry remains pending until an exact-byte smoke path covers the
`vpclmulhqhqdq` aggregate bytes.

The two aggregate `vmovdqu64` rows and the later RIP-relative memory rows are
10-byte instructions. Objdump wraps those byte sequences across two physical
lines; the inventory tool appends byte-only continuation lines back to the
owning instruction before classification.
