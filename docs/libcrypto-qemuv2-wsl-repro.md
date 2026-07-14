# Libcrypto QEMU V2 WSL Reproduction

This branch publishes the WSL-ready reproduction artifact for the libcrypto
QEMU V2 precision/recall experiment.

## Artifact

```text
archive/runnable-libcrypto-wsl-repro-2026-07-14.tar.gz
archive/runnable-libcrypto-wsl-repro-2026-07-14.tar.gz.sha256
```

The tarball includes:

- runnable source and libcrypto orchestration scripts
- Ubuntu 24.04 Docker build context
- bundled `libcrypto.so.3` and `libcrypto.gtBlock.pb`
- the full QEMU V2 `libtinycode-x86_64.so` used by the reference run
- the matching `libtinycode-helpers-x86_64.ll`
- `build-libtinycode-qemuv2.sh`, an explicit QEMU V2 `libtinycode` build/stage
  script
- `run-libcrypto-full-qemuv2.sh`, an explicit full `libcrypto.so` experiment
  script with precision/recall compare enabled by default

Readable copies of those scripts are also committed at:

```text
scripts/repro/build-libtinycode-qemuv2.sh
scripts/repro/run-libcrypto-full-qemuv2.sh
```

The bundled QEMU V2 runtime hashes are:

```text
35c658bb35b838c40da4e0c6e94794d7a0ff3f9034affce755c3f17525f441ec  libtinycode-x86_64.so
5977b32dd6710d0459aa9b4fd4290350f69c9333e2aaa53005fcbb554ab27fb2  libtinycode-helpers-x86_64.ll
```

## WSL Requirements

- WSL2, preferably Ubuntu 22.04 or 24.04.
- Docker available from inside WSL.
- Keep the extracted package on the WSL Linux filesystem, for example under
  `~/work`, not under `/mnt/c/...`.
- The reference full run used a 32 GB Docker memory limit and 30 CPU limit.

## Full Commands

```bash
git clone https://github.com/GRIN2021/Runnable-Rewriting.git
cd Runnable-Rewriting
git fetch origin agent/libcrypto-qemuv2-libtinycode
git checkout agent/libcrypto-qemuv2-libtinycode

sha256sum -c archive/runnable-libcrypto-wsl-repro-2026-07-14.tar.gz.sha256

mkdir -p ~/work/libcrypto-qemuv2-repro
tar -C ~/work/libcrypto-qemuv2-repro \
  -xzf archive/runnable-libcrypto-wsl-repro-2026-07-14.tar.gz
cd ~/work/libcrypto-qemuv2-repro/runnable-libcrypto-wsl-repro-2026-07-14

sha256sum -c SHA256SUMS
chmod +x run-libcrypto-ubuntu2404.sh
chmod +x build-libtinycode-qemuv2.sh run-libcrypto-full-qemuv2.sh

./run-libcrypto-ubuntu2404.sh smoke
./run-libcrypto-full-qemuv2.sh
```

After the full run finishes:

```bash
RUN=$(find runs-libcrypto/runs -maxdepth 1 -type d -name 'libcrypto-full-*' | sort | tail -1)
cat "$RUN/eval/cmp.verdict.txt"
python3 - <<'PY'
import json
from pathlib import Path

run = sorted(Path("runs-libcrypto/runs").glob("libcrypto-full-*"))[-1]
cmp = json.loads((run / "eval/cmp.json").read_text())
for key in [
    "precision",
    "recall",
    "obj_count",
    "ll_count",
    "hit",
    "mismatch",
    "ll_only",
    "false_negative",
    "false_positive",
]:
    print(f"{key}: {cmp[key]}")
PY
```

The source-machine reference result was:

```text
precision: 0.987997
recall: 0.829073
ok: true
```

The raw `cmp.json` values from that run were:

```text
precision: 0.9879972781671121
recall: 0.8290728853019693
obj_count: 679506
ll_count: 570204
hit: 563360
mismatch: 2555
ll_only: 4289
false_negative: 116146
false_positive: 6844
```

## Resource Overrides

For smaller WSL machines:

```bash
RUNNABLE_LIBCRYPTO_FULL_MEM_GB=24 \
RUNNABLE_LIBCRYPTO_FULL_CPUS=12 \
./run-libcrypto-full-qemuv2.sh
```

To test lift only and skip precision/recall compare:

```bash
RUNNABLE_LIBCRYPTO_SKIP_CMP=1 ./run-libcrypto-full-qemuv2.sh
```

To rebuild QEMU V2 `libtinycode` from QEMU 10.2.3 instead of staging the
bundled runtime:

```bash
./build-libtinycode-qemuv2.sh rebuild
RUNNABLE_LIBTINYCODE_BUILD_MODE=rebuild ./run-libcrypto-full-qemuv2.sh
```
