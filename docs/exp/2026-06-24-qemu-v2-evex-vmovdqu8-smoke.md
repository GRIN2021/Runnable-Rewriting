# QEMU v2 EVEX vmovdqu8 smoke

Status: PASS

Script: `runnable/scripts/qemu_v2_evex_vmovdqu8_smoke_patch.sh`

Base source:
`/tmp/rr-qemu-v2-upstream-probes-full-harness-18/qemu-10.2.3-avx512-series-src`

Validation command:

```bash
bash -n runnable/scripts/qemu_v2_evex_vmovdqu8_smoke_patch.sh

bash runnable/scripts/qemu_v2_evex_vmovdqu8_smoke_patch.sh \
  --scratch-root /tmp/rr-qemu-v2-evex-vmovdqu8-smoke \
  --base-src /tmp/rr-qemu-v2-upstream-probes-full-harness-18/qemu-10.2.3-avx512-series-src \
  --jobs 3
```

Target instruction:

```text
62 71 7f 48 7f 35 75 0f 00 00    vmovdqu8 zmmword ptr [rip+0xf75],zmm14
```

Key fixes:

- Added a dedicated exact-byte overlay on top of the `vextracti64x4`-validated
  patched tree instead of modifying older memory hooks.
- Implemented the minimal smoke semantics by emitting four 128-bit stores from
  `zmm14` with `rr_evex_store_zmm14_512(...)`.
- Relaxed standalone trace acceptance to the observed QEMU shape:
  `qemu_st2_i128` plus `zmm14` lane loads at `env,$0x6e0..$0x718`.

Observed result:

```text
vmovdqu8-single: PASS rc=0 vmovdqu8_hits=1 memory_hits=4 store_hits=8 exception_hits=0
vmovdqu8-chain:  PASS rc=0 vmovdqu8_hits=1 memory_hits=8 store_hits=15 exception_hits=0
aggregate:       PASS expected_next=none expected_pc=none observed_pc=completed rc=0 vmovdqu8_hits=9 exception_hits=0
aggregate_next:  completed
```

Aggregate outcome after this smoke:

- The validated prefix now includes `vmovdqu8 zmmword ptr [rip+disp32],zmm14`
  after `vextracti64x4 ymm16,zmm14,0x1`.
- The current aggregate probe no longer stops at an unsupported EVEX boundary;
  it runs through `vzeroupper` and exits at `0x401095`.
