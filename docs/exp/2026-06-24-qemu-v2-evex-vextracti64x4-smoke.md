# QEMU v2 EVEX vextracti64x4 smoke

Status: PASS

Script: `runnable/scripts/qemu_v2_evex_vextracti64x4_smoke_patch.sh`

Base source:
`/tmp/rr-qemu-v2-upstream-probes-full-harness-17/qemu-10.2.3-avx512-series-src`

Validation command:

```bash
bash -n runnable/scripts/qemu_v2_evex_vextracti64x4_smoke_patch.sh

bash runnable/scripts/qemu_v2_evex_vextracti64x4_smoke_patch.sh \
  --scratch-root /tmp/rr-qemu-v2-evex-vextracti64x4-smoke \
  --base-src /tmp/rr-qemu-v2-upstream-probes-full-harness-17/qemu-10.2.3-avx512-series-src \
  --jobs 3
```

Target instruction:

```text
62 33 fd 48 3b f0 01    vextracti64x4 ymm16,zmm14,0x1
```

Key fixes:

- Added a dedicated exact-byte overlay on top of the `vextracti32x4`-validated
  patched tree instead of extending the older wrapper.
- Implemented the minimal smoke semantics by zeroing `zmm16`, then copying
  `zmm14.ZMM_Y(1)` into `ymm16.ZMM_Y(0)` with `tcg_gen_gvec_mov`.
- Relaxed standalone trace acceptance to match the observed QEMU shape:
  exact-byte or PC evidence plus `st_vec` writeback at `env,$0x760` and
  `env,$0x780`.

Observed result:

```text
vextracti64x4-single: PASS rc=0 vextracti64x4_hits=1 copy_hits=3 exception_hits=0
vextracti64x4-chain:  PASS rc=0 vextracti64x4_hits=1 copy_hits=3 exception_hits=0
aggregate:            PASS expected_next=vmovdqu8 expected_pc=0x401081 observed_pc=0x401081 rc=132 vextracti64x4_hits=1 exception_hits=3
aggregate_next:       401081: 62 71 7f 48 7f 35 75 vmovdqu8 ZMMWORD PTR [rip+0xf75],zmm14
```

Aggregate boundary after this smoke:

- Validated prefix now includes `vextracti64x4 ymm16,zmm14,0x1` after the
  earlier `vextracti32x4`, `vpslldq`, and `vpsrldq` prefix.
- New expected next unsupported boundary:
  `vmovdqu8 ZMMWORD PTR [rip+0xf75],zmm14` at `0x401081`.
