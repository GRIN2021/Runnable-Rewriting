# QEMU V2 Runtime

This image is the reproducible container path for QEMU V2 migration smoke
testing. It is meant to run from a mounted `Runnable-Rewriting` checkout and to
keep host glibc/libstdc++ drift away from QEMU linux-user, the AVX-512 probe
suite, and the minimal PTC shim smoke.

## Contents

- `Dockerfile`: Ubuntu 24.04 runtime with QEMU linux-user build dependencies,
  probe-suite tools, and PTC shim smoke tools.
- `smoke.sh`: short container smoke installed as `qemu-v2-runtime-smoke`.
- `run-smoke.sh`: host-side wrapper that builds the image and runs the short
  smoke with a cached `/tmp` QEMU 10.2.3 tree when available.
- `run-validation.sh`: generic host-side launcher for reproducible in-container
  AVX and PTC validation commands.
- `runnable/scripts/build_runnable_lift_v2.sh`: host/container build wrapper for
  the current `build-codex-dynamic-current` runnable-lift artifact.

## Build The Image

Run from the `Runnable-Rewriting` repository root:

```bash
docker build -t rr_qemu_v2_runtime:latest docker/qemu-v2-runtime
```

The apt dependency layer is intentionally before the `smoke.sh` copy so script
and README changes do not invalidate the slow package-install layer.

## Host Entry

The smallest reproducible entry point is the host wrapper:

```bash
docker/qemu-v2-runtime/run-smoke.sh --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3
```

By default it builds `rr_qemu_v2_runtime:latest`, mounts the repository, uses
`/tmp/rr-qemu-v2-runtime-smoke` for scratch space, and runs the aggregate
`avx512-evex` probe before the PTC shim stub checks. Override the default
probe selection with repeated `--probe` flags or pass `--download-qemu` if you
do not have a cached source tree.

For anything beyond the short smoke, use the generic launcher:

```bash
docker/qemu-v2-runtime/run-validation.sh \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  -- bash
```

It mounts the repo at `/workspace/Runnable-Rewriting`, mounts the selected QEMU
10.2.3 source tree at `/workspace/qemu-10.2.3`, exports
`QEMU_V2_SRC=/workspace/qemu-10.2.3`, and keeps scratch paths under `/tmp`.

## Build Runnable-Lift V2

The current tested runnable-lift is the build-tree binary under
`build-codex-dynamic-current`. Build it from the host through the runtime image:

```bash
runnable/scripts/build_runnable_lift_v2.sh --verify
```

This builds `rr_qemu_v2_runtime:latest`, mounts the repository at
`/workspace/Runnable-Rewriting`, configures CMake with
`LLVM_DIR=/workspace/Runnable-Rewriting/root/lib/cmake/llvm`, and builds:

```text
build-codex-dynamic-current/tools/runnable-lift/runnable-lift
```

When already inside the runtime container, skip the Docker handoff:

```bash
bash runnable/scripts/build_runnable_lift_v2.sh --no-docker --verify
```

For direct host execution of the build-tree binary, carry the matching analysis
DSOs and LLVM runtime on `LD_LIBRARY_PATH`:

```bash
export LD_LIBRARY_PATH="$PWD/build-codex-dynamic-current/lib/StackAnalysis:$PWD/build-codex-dynamic-current/lib/BasicAnalyses:$PWD/build-codex-dynamic-current/lib/Support:$PWD/root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

## Mount The Repo

Use `/workspace/Runnable-Rewriting` as the in-container repo path:

```bash
docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$PWD":/workspace/Runnable-Rewriting \
  -w /workspace/Runnable-Rewriting \
  rr_qemu_v2_runtime:latest \
  bash
```

For the PTC shim smoke, also provide a QEMU 10.2.3 source tree. Either mount an
existing host checkout:

```bash
docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$PWD":/workspace/Runnable-Rewriting \
  -v "$PWD/../qemu-10.2.3":/workspace/qemu-10.2.3:ro \
  -w /workspace/Runnable-Rewriting \
  rr_qemu_v2_runtime:latest \
  bash
```

Or let the smoke script download and verify `qemu-10.2.3.tar.xz` inside its
scratch root with `--download-qemu`.

## Scratch And Build Paths

The short smoke defaults to `/tmp/rr-qemu-v2-runtime-smoke`. Keep that default
for disposable runs:

```bash
qemu-v2-runtime-smoke \
  --repo /workspace/Runnable-Rewriting \
  --qemu-src /workspace/qemu-10.2.3
```

The current PTC shim scripts require outputs under `/tmp`, so
`--scratch-root` must resolve under `/tmp`:

```bash
qemu-v2-runtime-smoke \
  --repo /workspace/Runnable-Rewriting \
  --qemu-src /workspace/qemu-10.2.3 \
  --scratch-root /tmp/rr-qemu-v2-runtime-smoke
```

If you want artifacts to survive container exit, bind-mount a host directory to
a `/tmp` path:

```bash
mkdir -p .scratch/qemu-v2-runtime-smoke
docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$PWD":/workspace/Runnable-Rewriting \
  -v "$PWD/../qemu-10.2.3":/workspace/qemu-10.2.3:ro \
  -v "$PWD/.scratch/qemu-v2-runtime-smoke":/tmp/rr-qemu-v2-runtime-smoke \
  -w /workspace/Runnable-Rewriting \
  rr_qemu_v2_runtime:latest \
  qemu-v2-runtime-smoke \
    --repo /workspace/Runnable-Rewriting \
    --qemu-src /workspace/qemu-10.2.3 \
    --scratch-root /tmp/rr-qemu-v2-runtime-smoke
```

For larger QEMU linux-user builds, either use `/tmp/...` for throwaway builds
or mount a host cache/build directory and pass that mounted path as the build
or install prefix.

## Short Smoke

The required short smoke covers:

- probe compile plus `objdump -d -Mintel` mnemonic checks through
  `runnable/scripts/qemu_v2_probe_suite.py`.
- the build wrapper transition path:
  `runnable/scripts/build_qemu_libtinycode_v2.sh --ptc-shim-stub`, which writes
  the current empty-stub `libtinycode-x86_64.so` under `/tmp` and verifies the
  `REAL_PTC_TRANSLATION=not-migrated-empty-stub` marker.
- PTC shim generation, `make`, `make smoke`, and an extra
  `dlopen`/`dlsym("ptc_load")`/`dlsym("ptc_translate")` harness through
  `runnable/scripts/qemu_v2_ptc_shim_dlopen_smoke.sh`.

Run with a mounted QEMU source tree:

```bash
docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$PWD":/workspace/Runnable-Rewriting \
  -v "$PWD/../qemu-10.2.3":/workspace/qemu-10.2.3:ro \
  -w /workspace/Runnable-Rewriting \
  rr_qemu_v2_runtime:latest \
  qemu-v2-runtime-smoke \
    --repo /workspace/Runnable-Rewriting \
    --qemu-src /workspace/qemu-10.2.3
```

Run without a host QEMU source tree:

```bash
docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$PWD":/workspace/Runnable-Rewriting \
  -w /workspace/Runnable-Rewriting \
  rr_qemu_v2_runtime:latest \
  qemu-v2-runtime-smoke \
    --repo /workspace/Runnable-Rewriting \
    --download-qemu
```

Limit the probe subset when debugging:

```bash
docker/qemu-v2-runtime/run-smoke.sh \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  --probe avx512-evex
```

## Run AVX Validation

The full AVX harness is intentionally separate from the short smoke:

```bash
docker/qemu-v2-runtime/run-validation.sh \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  -- bash runnable/scripts/qemu_v2_avx512_patch_series.sh \
       --qemu-src /workspace/qemu-10.2.3 \
       --scratch-root /tmp/rr-qemu-v2-avx512-patch-series \
       --jobs 3
```

This is the reproducible container command for rerunning the AVX-512 evidence.
It is longer-running than `run-smoke.sh` because it builds and executes patched
QEMU probes.

## Run PTC Validation

The current container smoke keeps the PTC side at the stub/loadability level:

```bash
docker/qemu-v2-runtime/run-validation.sh \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  -- qemu-v2-runtime-smoke \
       --repo /workspace/Runnable-Rewriting \
       --qemu-src /workspace/qemu-10.2.3 \
       --scratch-root /tmp/rr-qemu-v2-runtime-smoke
```

Build `runnable-lift` first, then run the canonical subset or sweep through the
same launcher. The subset/sweep scripts default to
`build-codex-dynamic-current` for `libtinycode`, helper IR, and the V2 lift when
those artifacts exist.

Example subset command:

```bash
runnable/scripts/build_runnable_lift_v2.sh --verify

docker/qemu-v2-runtime/run-validation.sh \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  -- bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh \
       --scratch-root /tmp/rr-qemu-v2-libcrypto-canonical-subset
```

Example sweep command:

```bash
runnable/scripts/build_runnable_lift_v2.sh --verify

docker/qemu-v2-runtime/run-validation.sh \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  -- bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_sweep.sh \
       --scratch-root /tmp/rr-qemu-v2-libcrypto-canonical-sweep \
       --profile next-family
```

The optional runnable-lift outer smoke is disabled by default. Enable it only
when the mounted repo contains a compatible `runnable-lift` binary and companion
IR files:

```bash
qemu-v2-runtime-smoke \
  --repo /workspace/Runnable-Rewriting \
  --qemu-src /workspace/qemu-10.2.3 \
  --with-runnable-lift
```

## Transition PTC Shim Stub

To run only the build-wrapper transition artifact inside the image:

```bash
docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$PWD":/workspace/Runnable-Rewriting \
  -v "$PWD/../qemu-10.2.3":/workspace/qemu-10.2.3:ro \
  -w /workspace/Runnable-Rewriting \
  rr_qemu_v2_runtime:latest \
  bash runnable/scripts/build_qemu_libtinycode_v2.sh \
    --ptc-shim-stub \
    --qemu-src /workspace/qemu-10.2.3 \
    --ptc-shim-out-dir /tmp/qemu-v2-ptc-shim-build-wrapper \
    --no-docker
```

Expected summary marker:

```text
REAL_PTC_TRANSLATION=not-migrated-empty-stub
```

This is intentionally a short transition build. It generates the current empty
stub under `/tmp`; it is not the full QEMU/libtinycode migration.

## Build Upstream Linux-User QEMU

Place or mount an upstream QEMU source tree at `qemu-v2/` in the repository
root. The source tree must contain QEMU's `configure` script and `meson.build`.

Inside the image:

```bash
bash runnable/scripts/build_qemu_libtinycode_v2.sh \
  --linux-user-only \
  --qemu-src qemu-v2 \
  --build-dir /tmp/build-qemu-v2-linux-user \
  --install-dir /tmp/root-qemu-v2-linux-user \
  --jobs "$(nproc)" \
  --no-docker
```

The installed binary is expected at:

```bash
/tmp/root-qemu-v2-linux-user/bin/qemu-x86_64
```

The wrapper can also be run from the host; in that mode it builds the image and
re-runs itself inside the container:

```bash
runnable/scripts/build_qemu_libtinycode_v2.sh \
  --linux-user-only \
  --qemu-src qemu-v2 \
  --build-dir build-qemu-v2-linux-user \
  --install-dir root-qemu-v2-linux-user
```

## Long-Running AVX-512 Patch-Series Smoke

The full patched QEMU AVX-512 path builds QEMU 10.2.3 and runs execution
probes, so treat it as long-running rather than part of the default container
smoke:

```bash
docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$PWD":/workspace/Runnable-Rewriting \
  -w /workspace/Runnable-Rewriting \
  rr_qemu_v2_runtime:latest \
  bash runnable/scripts/qemu_v2_avx512_patch_series.sh \
    --scratch-root /tmp/rr-qemu-v2-avx512-patch-series \
    --jobs 3
```

If you already have a verified QEMU 10.2.3 source tree or tarball, add
`--qemu-src /workspace/qemu-10.2.3` or
`--tarball /workspace/cache/qemu-10.2.3.tar.xz` to avoid downloading again.

## Notes And Limits

- The implemented QEMU build path is vanilla upstream `x86_64-linux-user`.
- `build_runnable_lift_v2.sh` is the canonical Docker-backed build entry for the
  tested `build-codex-dynamic-current` lift.
- `build_qemu_libtinycode_v2.sh --ptc-shim-stub` remains the short transition
  smoke for shim loadability; `--libtinycode` is still intentionally marked as
  not implemented until the full upstream QEMU/libtinycode build wrapper lands.
- The canonical libcrypto PTC scripts depend on the `build-codex-dynamic-current`
  build-tree lift, `libtinycode-x86_64.so`, and companion helper IR files.
- Host-built binaries should not be copied into this environment unless they
  were linked against compatible runtime libraries.
