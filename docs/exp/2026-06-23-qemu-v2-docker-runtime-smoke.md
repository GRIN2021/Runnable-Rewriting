# QEMU V2 Docker Runtime Smoke

Date: 2026-06-23

## Scope

This records the containerized short smoke path for the QEMU V2 migration work.
The default smoke covers:

- AVX/AVX-512 probe compile and `objdump -d -Mintel` mnemonic checks.
- Minimal PTC shim generation, shared-object build, `make smoke`, and an extra
  `dlopen`/`dlsym("ptc_load")`/`dlsym("ptc_translate")` harness.

The full AVX-512 patched QEMU build remains a long-running path and was not
included in this short smoke.

## Commands Run

Static checks:

```bash
bash -n docker/qemu-v2-runtime/smoke.sh
git diff --check -- docker/qemu-v2-runtime/Dockerfile docker/qemu-v2-runtime/README.md docker/qemu-v2-runtime/smoke.sh
python3 runnable/scripts/qemu_v2_probe_suite.py \
  --probe avx2-vex \
  --probe avx512-vpxorq \
  --build-dir /tmp/rr-qemu-v2-host-static-probes \
  --compile \
  --objdump
```

Docker checks:

```bash
docker --version
docker info --format '{{.ServerVersion}}'
docker build -t rr_qemu_v2_runtime:task-f docker/qemu-v2-runtime
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$PWD":/workspace/Runnable-Rewriting \
  -w /workspace/Runnable-Rewriting \
  rr_qemu_v2_runtime:task-f \
  qemu-v2-runtime-smoke \
    --repo /workspace/Runnable-Rewriting \
    --download-qemu
```

## Results

- Docker CLI: `Docker version 28.4.0, build d8eb465`.
- Docker daemon: `28.4.0`.
- Image build: passed as `rr_qemu_v2_runtime:task-f`.
- First build attempt failed before Dockerfile execution because BuildKit tried
  to pull `docker/dockerfile:1` through an unreachable proxy
  `192.168.2.13:7890`. The nonessential syntax directive was removed, and the
  next build passed.
- Container smoke: passed.
- QEMU source path verified in container:
  `/tmp/rr-qemu-v2-runtime-smoke/qemu-10.2.3`.
- QEMU tarball verification: sha256 passed for
  `/tmp/rr-qemu-v2-runtime-smoke/download/qemu-10.2.3.tar.xz`.
- Probe output directory:
  `/tmp/rr-qemu-v2-runtime-smoke/probes`.
- PTC shim directory:
  `/tmp/rr-qemu-v2-runtime-smoke/ptc-shim`.
- PTC run directory:
  `/tmp/rr-qemu-v2-runtime-smoke/ptc-shim-run`.

Container smoke summary:

```text
QEMU_V2_RUNTIME_SMOKE=pass
DLOPEN_DLSYM_SMOKE=pass
RUNNABLE_LIFT_SMOKE=skipped
REAL_PTC_TRANSLATION=not-migrated-empty-stub
```

Probe coverage in the container:

- `avx2-vex`: 4 expected mnemonics found.
- `avx512-vpxorq`: 1 expected mnemonic found.
- `avx512-vmovdqa64`: 1 expected mnemonic found.
- `avx512-vaesenc`: 1 expected mnemonic found.
- `avx512-vpclmullqlqdq`: 1 expected mnemonic found.
- `avx512-evex`: 18 expected mnemonics found.

PTC shim smoke coverage in the container:

- Generated the shim tree under `/tmp`.
- Built `build/libtinycode-x86_64.so`.
- Ran generated `make smoke`.
- Ran the extra `dlopen` harness.
- Resolved and called `ptc_load`.
- Resolved and called `ptc_translate`.
- Verified the expected empty-translation stub boundary.

## Remaining Risks

- Full AVX-512 patched QEMU build/execution was not run in this short smoke; it
  is documented as a long-running command in the README.
- The PTC shim still validates an empty loadable stub. It does not prove real
  PTC translation has been migrated.
- Optional runnable-lift outer smoke was skipped in the container run because
  the short smoke defaults to container-only `dlopen`/`dlsym` validation.
- The verified QEMU source path used `--download-qemu`; a host-mounted
  read-only QEMU source tree path is documented but was not separately run.

## Task AK Update: Build Wrapper PTC Stub Path

The container smoke now includes the `build_qemu_libtinycode_v2.sh
--ptc-shim-stub` transition path as part of the default short smoke. The check
uses the same QEMU 10.2.3 source tree as the PTC dlopen smoke, writes the
wrapper-generated shim tree under the smoke scratch root in `/tmp`, verifies
`build/libtinycode-x86_64.so`, and greps the wrapper log for:

```text
REAL_PTC_TRANSLATION=not-migrated-empty-stub
```

Additional commands run for this update:

```bash
bash -n docker/qemu-v2-runtime/smoke.sh
bash -n runnable/scripts/build_qemu_libtinycode_v2.sh
bash runnable/scripts/build_qemu_libtinycode_v2.sh \
  --ptc-shim-stub \
  --qemu-src /tmp/rr-qemu-v2-evex-vpaddd-smoke-final/qemu-10.2.3 \
  --ptc-shim-out-dir /tmp/rr-qemu-v2-task-ak-wrapper-stub \
  --jobs 2 \
  --no-docker
docker build -t rr_qemu_v2_runtime:task-ak docker/qemu-v2-runtime
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$PWD":/workspace/Runnable-Rewriting \
  -v /tmp/rr-qemu-v2-evex-vpaddd-smoke-final/qemu-10.2.3:/workspace/qemu-10.2.3:ro \
  -w /workspace/Runnable-Rewriting \
  rr_qemu_v2_runtime:task-ak \
  qemu-v2-runtime-smoke \
    --repo /workspace/Runnable-Rewriting \
    --qemu-src /workspace/qemu-10.2.3 \
    --scratch-root /tmp/rr-qemu-v2-task-ak-container-smoke \
    --probe avx2-vex \
    --jobs 2
```

Results:

- Host-side wrapper stub smoke: passed.
- Docker CLI and daemon: available, `28.4.0`.
- Image build: passed as `rr_qemu_v2_runtime:task-ak`.
- Minimal container smoke with `--probe avx2-vex`: passed.
- Wrapper stub artifact verified at
  `/tmp/rr-qemu-v2-task-ak-container-smoke/ptc-shim-wrapper/build/libtinycode-x86_64.so`.
- Container summary included `QEMU_V2_RUNTIME_SMOKE=pass` and
  `REAL_PTC_TRANSLATION=not-migrated-empty-stub`.

The long-running AVX-512 patch-series QEMU build remains outside the default
container smoke and is still documented as a manual path.

## 2026-06-24 Host Wrapper Smoke

This update added a thin host-side entry point:
`docker/qemu-v2-runtime/run-smoke.sh`.
It builds the runtime image if needed, mounts the repository and a cached QEMU
10.2.3 tree, then runs the short container smoke with a light AVX-512 probe
selection.

Commands run for this update:

```bash
docker build -t rr_qemu_v2_runtime:codex docker/qemu-v2-runtime
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e RUNNABLE_QEMU_V2_IMAGE=rr_qemu_v2_runtime:codex \
  -v "$PWD":/workspace/Runnable-Rewriting \
  -v /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3:/workspace/qemu-10.2.3:ro \
  -w /workspace/Runnable-Rewriting \
  rr_qemu_v2_runtime:codex \
  qemu-v2-runtime-smoke \
    --repo /workspace/Runnable-Rewriting \
    --qemu-src /workspace/qemu-10.2.3 \
    --scratch-root /tmp/rr-qemu-v2-runtime-smoke \
    --probe avx512-evex
chmod +x docker/qemu-v2-runtime/run-smoke.sh
docker/qemu-v2-runtime/run-smoke.sh \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  --probe avx512-evex
```

Results:

- Image build: passed as `rr_qemu_v2_runtime:codex`.
- Manual container smoke: passed.
- Host wrapper smoke: passed.
- Probe coverage in the container: `avx512-evex` found 18 expected mnemonics.
- PTC shim wrapper stub build: passed and kept the expected
  `REAL_PTC_TRANSLATION=not-migrated-empty-stub` marker.
- PTC shim dlopen smoke: passed.

Current limits remain unchanged:

- The smoke still validates the empty PTC stub; it does not prove real PTC
  translation migration.
- The full AVX-512 patched QEMU build/execution path was not run here.
- The optional runnable-lift outer smoke stays disabled by default.
