# QEMU V2 Probe Corpus

Small source-only probes for validating the QEMU V2 backend before running full
`libcrypto.so.3`.

These probes intentionally use assembly instead of compiler intrinsics so the
expected mnemonics appear predictably in `objdump` output. Do not run the
AVX-512 probe natively on machines that may not support AVX-512; use
`runnable/scripts/qemu_v2_probe_suite.py` and pass a QEMU linux-user binary when
execution is needed.

Typical usage:

```bash
python3 runnable/scripts/qemu_v2_probe_suite.py --list
python3 runnable/scripts/qemu_v2_probe_suite.py --probe avx512-evex --compile --objdump
python3 runnable/scripts/qemu_v2_probe_suite.py --probe avx512-evex --compile --objdump \
  --qemu-x86_64 /path/to/qemu-x86_64
python3 runnable/scripts/qemu_v2_probe_suite.py --probe avx512-evex --compile --objdump \
  --runnable-lift /path/to/runnable-lift
```
