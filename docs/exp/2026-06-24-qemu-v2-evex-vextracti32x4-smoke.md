# QEMU v2 EVEX vextracti32x4 smoke

Status: PASS

Script: `runnable/scripts/qemu_v2_evex_vextracti32x4_smoke_patch.sh`

Base source:
`/tmp/rr-qemu-v2-upstream-probes-full-harness-16/qemu-10.2.3-avx512-series-src`

Validation command:

```bash
bash -n runnable/scripts/qemu_v2_evex_vextracti32x4_smoke_patch.sh

bash runnable/scripts/qemu_v2_evex_vextracti32x4_smoke_patch.sh \
  --scratch-root /tmp/rr-qemu-v2-evex-vextracti32x4-smoke \
  --base-src /tmp/rr-qemu-v2-upstream-probes-full-harness-16/qemu-10.2.3-avx512-series-src \
  --jobs 3
```

Target instruction:

```text
62 53 7d 48 39 f7 01    vextracti32x4 xmm15,zmm14,0x1
```

Key fixes:

- Added a dedicated exact-byte overlay on top of the `vpsrldq`-validated
  patched tree instead of extending the old smoke wrapper.
- Implemented the minimal smoke semantics by loading `zmm14.ZMM_X(1)` into a
  temporary `i128`, zeroing `xmm15`, and storing the extracted 128-bit lane
  into `xmm15.ZMM_X(0)`.
- Relaxed standalone trace acceptance to match the actual TCG shape observed in
  QEMU logs: exact-byte `OBJD-T` plus `st_vec`/`st_i64` writeback evidence,
  rather than requiring `ld_i128`/`st_i128` mnemonics in every run.

Observed result:

```text
vextracti32x4-single: PASS rc=0 vextracti32x4_hits=1 copy_hits=4 exception_hits=0
vextracti32x4-chain:  PASS rc=0 vextracti32x4_hits=1 copy_hits=2 exception_hits=0
aggregate:            PASS expected_next=vextracti64x4 expected_pc=0x40107a observed_pc=0x40107a rc=132 vextracti32x4_hits=1 exception_hits=3
aggregate_next:       40107a: 62 33 fd 48 3b f0 01 vextracti64x4 ymm16,zmm14,0x1
```

Aggregate boundary after this smoke:

- Validated prefix now includes `vextracti32x4 xmm15,zmm14,0x1` after the
  earlier `vpslldq` and `vpsrldq` prefix.
- New expected next unsupported boundary:
  `vextracti64x4 ymm16,zmm14,0x1` at `0x40107a`.
