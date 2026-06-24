# QEMU v2 EVEX vpsrldq smoke

Status: PASS

Script: `runnable/scripts/qemu_v2_evex_vpsrldq_smoke_patch.sh`

Base source:
`/tmp/rr-qemu-v2-upstream-probes-full-harness-15/qemu-10.2.3-avx512-series-src`

Validation command:

```bash
bash -n runnable/scripts/qemu_v2_evex_vpsrldq_smoke_patch.sh

bash runnable/scripts/qemu_v2_evex_vpsrldq_smoke_patch.sh \
  --scratch-root /tmp/rr-qemu-v2-evex-vpsrldq-smoke-path-fixed \
  --base-src /tmp/rr-qemu-v2-upstream-probes-full-harness-15/qemu-10.2.3-avx512-series-src \
  --jobs 3
```

Target instruction:

```text
62 d1 0d 48 73 dd 04    vpsrldq zmm14,zmm13,0x4
```

Key fixes:

- Replaced the wrapper-style transform script with a true standalone script so
  `REPO_ROOT` resolves inside the current repo and aggregate source lookup uses
  `test/qemu-v2-probes/avx512-evex.S` instead of `//test/...`.
- Switched standalone probe generation from inherited `vpslldq-*` names to real
  `vpsrldq-single` and `vpsrldq-chain` probes.
- Verified the exact bytes and helper path for `vpsrldq zmm14,zmm13,0x4`.

Observed result:

```text
vpsrldq-single: PASS rc=0 psrldq_helper_hits=4
vpsrldq-chain:  PASS rc=0 pslldq_helper_hits=4 psrldq_helper_hits=4
aggregate:      PASS observed_pc=0x401073 rc=132
aggregate_next: 401073: 62 53 7d 48 39 f7 01 vextracti32x4 xmm15,zmm14,0x1
```

Aggregate boundary after this smoke:

- Validated prefix now includes both `vpslldq zmm13,zmm12,0x4` and
  `vpsrldq zmm14,zmm13,0x4`.
- New expected next unsupported boundary: `vextracti32x4 xmm15,zmm14,0x1` at
  `0x401073`.
