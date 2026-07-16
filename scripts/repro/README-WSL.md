# Libcrypto QEMU V2 WSL Reproduction Package

This package is prepared for Windows WSL2. Docker is optional: the top-level
helper uses Docker when available and automatically falls back to native
WSL/host execution when Docker is unavailable or
`RUNNABLE_LIBCRYPTO_NO_DOCKER=1` is set.

## Contents

- `Runnable-Rewriting/runnable/`: runnable source and libcrypto scripts.
- `Runnable-Rewriting/runnable/scripts/host-build/`: native WSL/Ubuntu build
  helpers for `runnable-lift`.
- `Runnable-Rewriting/docker/qemu-v2-runtime/`: Ubuntu 24.04 Docker image
  context for users who want the container path.
- `GroudTruth/groundtruth-gap-analysis-skill/results/libcrypto-artifacts/`:
  bundled `libcrypto.so.3` and `libcrypto.gtBlock.pb`.
- `Runnable-Rewriting/runnable/tools/runnable-lift/libtinycode-x86_64.so`:
  bundled full QEMU V2 live-sidecar runtime used by the libcrypto run.
- `Runnable-Rewriting/runnable/tools/runnable-lift/libtinycode-helpers-x86_64.ll`:
  helper IR paired with the bundled QEMU V2 runtime.
- `build-libtinycode-qemuv2.sh`: build/stage helper for `runnable-lift` and
  QEMU V2 `libtinycode`.
- `run-libcrypto-full-qemuv2.sh`: full libcrypto precision/recall runner.
- `run-libcrypto-ubuntu2404.sh`: compatibility entrypoint for
  `smoke|full|build-only`.

## Requirements

- WSL2, preferably Ubuntu 24.04 or 22.04.
- Keep the package under the WSL Linux filesystem, such as `~/work/`, not under
  `/mnt/c/...`, for much better filesystem performance.
- For no-Docker runs, install native host dependencies with the bundled helper:

  ```bash
  sudo bash Runnable-Rewriting/runnable/scripts/host-build/install-host-deps.sh
  ```

## Quick Start

```bash
tar -xzf runnable-libcrypto-wsl-repro-2026-07-14.tar.gz
cd runnable-libcrypto-wsl-repro-2026-07-14
sha256sum -c SHA256SUMS
sudo bash Runnable-Rewriting/runnable/scripts/host-build/install-host-deps.sh
RUNNABLE_LIBCRYPTO_NO_DOCKER=1 ./run-libcrypto-ubuntu2404.sh smoke
```

Smoke mode builds/stages `runnable-lift`, stages the bundled QEMU V2
`libtinycode`, and lifts one small libcrypto shard.

## Full Precision/Recall Run

```bash
RUNNABLE_LIBCRYPTO_NO_DOCKER=1 ./run-libcrypto-ubuntu2404.sh full
```

By default `full` runs the compare phase and writes:

```text
runs-libcrypto/runs/<run-label>/eval/cmp.json
runs-libcrypto/runs/<run-label>/eval/cmp.verdict.txt
```

Check the result with:

```bash
RUN=$(find runs-libcrypto/runs -maxdepth 1 -type d -name 'libcrypto-full-*' | sort | tail -1)
cat "$RUN/eval/cmp.verdict.txt"
```

The reference result from the source machine was:

```text
precision: 0.987997
recall: 0.829073
ok: true
```

Small differences are possible if the bundled source or system toolchain is
changed, but this package includes the same ground truth binary and QEMU V2
`libtinycode` runtime used by the reference run.

## Useful Overrides

Use a different output location:

```bash
RUNNABLE_LIBCRYPTO_RUN_ROOT="$PWD/runs-libcrypto" \
RUNNABLE_LIBCRYPTO_NO_DOCKER=1 \
./run-libcrypto-ubuntu2404.sh full
```

Skip precision/recall compare when only testing lift:

```bash
RUNNABLE_LIBCRYPTO_SKIP_CMP=1 \
RUNNABLE_LIBCRYPTO_NO_DOCKER=1 \
./run-libcrypto-ubuntu2404.sh full
```

Use Docker explicitly when available:

```bash
./run-libcrypto-ubuntu2404.sh smoke
./run-libcrypto-ubuntu2404.sh full
```

## Notes

- The packaged `libtinycode-x86_64.so` is the full QEMU V2 runtime, not the
  66 KB empty stub.
- If Docker is missing, the top-level helper no longer exits with a Docker
  error; it dispatches to the native WSL/host path.
- The full run is long and disk-heavy. The validated no-Docker source-machine
  run used about 48 GB of output disk and took 4313 seconds.
