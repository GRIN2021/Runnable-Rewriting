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
- a bundled prebuilt `runnable-lift` install used by the no-Docker WSL path
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

The bundled no-Docker `runnable-lift` was checked on the source machine with:

```text
runnable-lift: 1addc607d7f9d6a06ba61cff01581101973e63b1b5bdc7e166f88e6e244dd839
```

## WSL Requirements

- WSL2, preferably Ubuntu 22.04 or 24.04.
- No Docker is required for the native WSL path. The default native path uses
  the bundled prebuilt `runnable-lift` install so it can reproduce the measured
  precision/recall without rebuilding the whole toolchain first.
- Keep the extracted package on the WSL Linux filesystem, for example under
  `~/work`, not under `/mnt/c/...`.
- Install runtime dependencies with `apt` as shown below. Install LLVM 18 only
  if you want to rebuild `runnable-lift`/`libtinycode` locally.
- The validated no-Docker host run used about 48 GB of output disk and took
  4313 seconds on the source machine.

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

sudo apt update
sudo apt install -y \
  build-essential cmake ninja-build git rsync python3 python3-pip \
  protobuf-compiler binutils zlib1g libzstd1 libtinfo6

RUNNABLE_LIBCRYPTO_NO_DOCKER=1 ./run-libcrypto-full-qemuv2.sh
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

The no-Docker host path in this artifact was validated on the source machine
before publishing:

```text
execution_model: host-shards
range_mode: seed
seed_count: 5326
successful_seed_count: 5326
precision: 0.9881612470784759
recall: 0.8287800254891053
ok: true
end_to_end_wall_time_sec: 4313.401302576065
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
RUNNABLE_LIBCRYPTO_NO_DOCKER=1 \
RUNNABLE_LIBCRYPTO_FULL_MEM_GB=24 \
RUNNABLE_LIBCRYPTO_FULL_CPUS=12 \
./run-libcrypto-full-qemuv2.sh
```

To test lift only and skip precision/recall compare:

```bash
RUNNABLE_LIBCRYPTO_SKIP_CMP=1 ./run-libcrypto-full-qemuv2.sh
```

If Docker is available and you want the containerized path:

```bash
./run-libcrypto-ubuntu2404.sh smoke
./run-libcrypto-full-qemuv2.sh
```

To rebuild QEMU V2 `libtinycode`/`runnable-lift` locally instead of using the
bundled prebuilt runtime, install LLVM 18 and run:

```bash
sudo apt install -y clang-18 llvm-18 llvm-18-dev llvm-18-tools lld-18
RUNNABLE_LIBCRYPTO_NO_DOCKER=1 RUNNABLE_LIBCRYPTO_REBUILD=1 \
  ./build-libtinycode-qemuv2.sh stage-bundled
RUNNABLE_LIBCRYPTO_NO_DOCKER=1 RUNNABLE_LIBCRYPTO_REBUILD=1 \
  ./run-libcrypto-full-qemuv2.sh
```

For metric reproduction, use the default prebuilt path above. The rebuild path
is provided so the QEMU V2 `libtinycode` build can be inspected on WSL.
