# QEMU V2 Upstream Baseline Probe

Date: 2026-06-23
Branch: `codex/qemu-upgrade-v2`
Scratch root: `/tmp/rr-qemu-v2-upstream-probes`

## Summary

Both candidate upstream releases can be obtained and built locally as
`x86_64-linux-user` without adding QEMU source trees or build outputs to this
repository. The existing probe harness compiles and disassembles the AVX2 and
AVX-512 probes successfully. Both QEMU `10.2.3` and `11.0.1` execute the AVX2
probe, but both fail the existing AVX-512/EVEX probe with target `SIGILL`.

The blocker is not source acquisition or basic build feasibility. The practical
blocker is upstream x86 TCG capability: linux-user TCG masks out AVX-512 feature
bits, and even explicit CPU models such as `SapphireRapids` or `max` do not make
the EVEX probe executable.

Recommendation: do not treat unmodified upstream QEMU `10.2.3` or `11.0.1` as
an AVX-512-capable V2 backend baseline. If a modern QEMU codebase is still
needed for the port, use `10.2.3` as the practical implementation baseline
because it builds cleanly, matches the existing plan's stability rationale, and
`11.0.1` does not improve the decisive AVX-512 result. Keep `11.0.1` only as a
reference/capability comparison. The V2 plan needs an explicit EVEX/AVX-512 TCG
enablement spike before committing to a full PTC port.

## Candidate Sources

| Candidate | Source URL | Git tag | Local result |
|---|---|---|---|
| QEMU `10.2.3` | `https://download.qemu.org/qemu-10.2.3.tar.xz` | `refs/tags/v10.2.3` = `2eac5ce9722e819072171cfbf8f2d34b39e84b80` | Downloaded, configured, built `qemu-x86_64` |
| QEMU `11.0.1` | `https://download.qemu.org/qemu-11.0.1.tar.xz` | `refs/tags/v11.0.1` = `08b0c2a55172d6176aa8356ea38698ff307b0082` | Downloaded, configured, built `qemu-x86_64` |

Downloaded tarball hashes:

```text
2aa0e420e4ea89ea34a833f4c4eced96a35b51a9ee8568b232692729b60b064d  qemu-10.2.3.tar.xz
0d235f5820278d914a3155ec27af8e4258d697ea892895570807d69c0cb8cd64  qemu-11.0.1.tar.xz
```

Detached signatures were available from:

```text
https://download.qemu.org/qemu-10.2.3.tar.xz.sig
https://download.qemu.org/qemu-11.0.1.tar.xz.sig
```

Local signature verification was blocked by a missing public key:

```text
gpg --verify qemu-10.2.3.tar.xz.sig qemu-10.2.3.tar.xz
gpg: Signature made Thu May 28 06:12:30 2026 CST
gpg:                using RSA key CEACC9E15534EBABB82D3FA03353C9CEF108B584
gpg: Can't check signature: No public key

gpg --verify qemu-11.0.1.tar.xz.sig qemu-11.0.1.tar.xz
gpg: Signature made Thu May 28 05:21:48 2026 CST
gpg:                using RSA key CEACC9E15534EBABB82D3FA03353C9CEF108B584
gpg: Can't check signature: No public key
```

Next command for a verification-only follow-up, after validating the key through
QEMU-maintained release-key documentation:

```bash
gpg --keyserver keyserver.ubuntu.com --recv-keys CEACC9E15534EBABB82D3FA03353C9CEF108B584
gpg --verify qemu-10.2.3.tar.xz.sig qemu-10.2.3.tar.xz
gpg --verify qemu-11.0.1.tar.xz.sig qemu-11.0.1.tar.xz
```

## Local Environment

Host tools observed:

```text
gcc: /usr/bin/gcc
gcc: Ubuntu 13.3.0-6ubuntu2~24.04.1
python3: /usr/bin/python3
python3: 3.12.3
make: /usr/bin/make
pkg-config: /usr/bin/pkg-config
docker: /usr/bin/docker
docker: 28.4.0
host meson: missing
host ninja: missing
glib-2.0: 2.80.0
pixman-1: missing from pkg-config
```

Host CPU SIMD flags relevant to native execution:

```text
avx avx2 pclmulqdq
```

The host does not expose AVX-512, `vaes`, or `vpclmulqdq`, so native execution
of the AVX-512 probe is not a useful oracle here. The QEMU test is therefore
whether linux-user TCG can emulate the probe when given an AVX-512-capable guest
CPU model.

Meson/Ninja were installed only in `/tmp`:

```bash
cd /tmp/rr-qemu-v2-upstream-probes
python3 -m venv /tmp/rr-qemu-v2-upstream-probes/venv
/tmp/rr-qemu-v2-upstream-probes/venv/bin/pip install --upgrade pip meson ninja
```

Installed versions:

```text
meson 1.11.1
ninja 1.13.0.git.kitware.jobserver-pipe-1
```

## Docker Runtime Check

The repository runtime image build with BuildKit failed before reaching the
Dockerfile body:

```bash
docker build -t rr_qemu_v2_runtime:latest docker/qemu-v2-runtime
```

Observed blocker:

```text
failed to resolve source metadata for docker.io/docker/dockerfile:1:
Head "https://docker.m.daocloud.io/v2/docker/dockerfile/manifests/1?ns=docker.io":
proxyconnect tcp: dial tcp 192.168.2.13:7890: connect: no route to host
```

The cached `ubuntu:24.04` base image exists locally, but it is minimal and lacks
compiler/build tools. Retrying with the legacy Docker builder bypassed the
unreachable BuildKit frontend and successfully began the `apt-get` path:

```bash
DOCKER_BUILDKIT=0 docker build -t rr_qemu_v2_runtime:latest docker/qemu-v2-runtime
```

This fetched Ubuntu package metadata and archives, including a 266 MB dependency
set. I interrupted the container build after it had proven that the legacy
builder path can reach Ubuntu apt repositories, because the host build/probe
result was already sufficient and a long Docker package install was not needed
for the baseline decision.

Practical Docker next step:

```bash
DOCKER_BUILDKIT=0 docker build -t rr_qemu_v2_runtime:latest docker/qemu-v2-runtime
```

If BuildKit is required, fix the Docker proxy/mirror configuration for
`docker.m.daocloud.io` or remove the unreachable proxy `192.168.2.13:7890`.

## Build Commands

Source acquisition:

```bash
mkdir -p /tmp/rr-qemu-v2-upstream-probes
cd /tmp/rr-qemu-v2-upstream-probes
curl -L --fail --retry 3 -o qemu-10.2.3.tar.xz https://download.qemu.org/qemu-10.2.3.tar.xz
curl -L --fail --retry 3 -o qemu-11.0.1.tar.xz https://download.qemu.org/qemu-11.0.1.tar.xz
curl -L --fail --max-time 30 -o qemu-10.2.3.tar.xz.sig https://download.qemu.org/qemu-10.2.3.tar.xz.sig
curl -L --fail --max-time 30 -o qemu-11.0.1.tar.xz.sig https://download.qemu.org/qemu-11.0.1.tar.xz.sig
tar -xf qemu-10.2.3.tar.xz
tar -xf qemu-11.0.1.tar.xz
mkdir -p build-10.2.3 build-11.0.1 install-10.2.3 install-11.0.1
```

QEMU `10.2.3` configure/build:

```bash
cd /tmp/rr-qemu-v2-upstream-probes/build-10.2.3
PATH=/tmp/rr-qemu-v2-upstream-probes/venv/bin:$PATH \
  ../qemu-10.2.3/configure \
  --target-list=x86_64-linux-user \
  --disable-system \
  --disable-tools \
  --disable-docs \
  --disable-gtk \
  --disable-sdl \
  --disable-vnc \
  --disable-curses \
  --disable-slirp \
  --disable-capstone \
  --disable-werror \
  --prefix=/tmp/rr-qemu-v2-upstream-probes/install-10.2.3

PATH=/tmp/rr-qemu-v2-upstream-probes/venv/bin:$PATH ninja -j3 qemu-x86_64
```

QEMU `11.0.1` configure/build:

```bash
cd /tmp/rr-qemu-v2-upstream-probes/build-11.0.1
PATH=/tmp/rr-qemu-v2-upstream-probes/venv/bin:$PATH \
  ../qemu-11.0.1/configure \
  --target-list=x86_64-linux-user \
  --disable-system \
  --disable-tools \
  --disable-docs \
  --disable-gtk \
  --disable-sdl \
  --disable-vnc \
  --disable-curses \
  --disable-slirp \
  --disable-capstone \
  --disable-werror \
  --prefix=/tmp/rr-qemu-v2-upstream-probes/install-11.0.1

PATH=/tmp/rr-qemu-v2-upstream-probes/venv/bin:$PATH ninja -j3 qemu-x86_64
```

Build outputs:

```text
/tmp/rr-qemu-v2-upstream-probes/build-10.2.3/qemu-x86_64  15173936 bytes
/tmp/rr-qemu-v2-upstream-probes/build-11.0.1/qemu-x86_64  15141952 bytes
```

Version checks:

```text
/tmp/rr-qemu-v2-upstream-probes/build-10.2.3/qemu-x86_64 --version
qemu-x86_64 version 10.2.3

/tmp/rr-qemu-v2-upstream-probes/build-11.0.1/qemu-x86_64 --version
qemu-x86_64 version 11.0.1
```

## Probe Commands And Results

Compile and objdump probes into `/tmp`:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
python3 runnable/scripts/qemu_v2_probe_suite.py \
  --compile \
  --objdump \
  --build-dir /tmp/rr-qemu-v2-upstream-probes/probes-build
```

Observed result:

```text
avx2-vex: objdump contains 4 expected mnemonic(s)
avx512-evex: objdump contains 18 expected mnemonic(s)
```

AVX2 probe under QEMU `10.2.3`:

```bash
python3 runnable/scripts/qemu_v2_probe_suite.py \
  --build-dir /tmp/rr-qemu-v2-upstream-probes/probes-build \
  --probe avx2-vex \
  --qemu-x86_64 /tmp/rr-qemu-v2-upstream-probes/build-10.2.3/qemu-x86_64
```

Observed result:

```text
avx2-vex: QEMU execution OK
```

AVX2 probe under QEMU `11.0.1`:

```bash
python3 runnable/scripts/qemu_v2_probe_suite.py \
  --build-dir /tmp/rr-qemu-v2-upstream-probes/probes-build \
  --probe avx2-vex \
  --qemu-x86_64 /tmp/rr-qemu-v2-upstream-probes/build-11.0.1/qemu-x86_64
```

Observed result:

```text
avx2-vex: QEMU execution OK
```

AVX-512/EVEX probe under QEMU `10.2.3`:

```bash
python3 runnable/scripts/qemu_v2_probe_suite.py \
  --build-dir /tmp/rr-qemu-v2-upstream-probes/probes-build \
  --probe avx512-evex \
  --qemu-x86_64 /tmp/rr-qemu-v2-upstream-probes/build-10.2.3/qemu-x86_64
```

Observed result:

```text
qemu: uncaught target signal 4 (Illegal instruction) - core dumped
QEMU execution failed for /tmp/rr-qemu-v2-upstream-probes/probes-build/avx512-evex: rc=-4
```

AVX-512/EVEX probe under QEMU `11.0.1`:

```bash
python3 runnable/scripts/qemu_v2_probe_suite.py \
  --build-dir /tmp/rr-qemu-v2-upstream-probes/probes-build \
  --probe avx512-evex \
  --qemu-x86_64 /tmp/rr-qemu-v2-upstream-probes/build-11.0.1/qemu-x86_64
```

Observed result:

```text
qemu: uncaught target signal 4 (Illegal instruction) - core dumped
QEMU execution failed for /tmp/rr-qemu-v2-upstream-probes/probes-build/avx512-evex: rc=-4
```

Explicit CPU model tests:

```bash
QEMU_CPU=SapphireRapids \
  /tmp/rr-qemu-v2-upstream-probes/build-10.2.3/qemu-x86_64 \
  /tmp/rr-qemu-v2-upstream-probes/probes-build/avx512-evex

QEMU_CPU=SapphireRapids \
  /tmp/rr-qemu-v2-upstream-probes/build-11.0.1/qemu-x86_64 \
  /tmp/rr-qemu-v2-upstream-probes/probes-build/avx512-evex

QEMU_CPU=max \
  /tmp/rr-qemu-v2-upstream-probes/build-10.2.3/qemu-x86_64 \
  /tmp/rr-qemu-v2-upstream-probes/probes-build/avx512-evex

QEMU_CPU=max \
  /tmp/rr-qemu-v2-upstream-probes/build-11.0.1/qemu-x86_64 \
  /tmp/rr-qemu-v2-upstream-probes/probes-build/avx512-evex
```

Observed result: all returned `SIGILL` / shell `rc=132`.

Representative `SapphireRapids` warning:

```text
qemu-x86_64: warning: TCG doesn't support requested feature: CPUID[eax=07h,ecx=00h].EBX.avx512f [bit 16]
qemu-x86_64: warning: TCG doesn't support requested feature: CPUID[eax=07h,ecx=00h].EBX.avx512dq [bit 17]
qemu-x86_64: warning: TCG doesn't support requested feature: CPUID[eax=07h,ecx=00h].EBX.avx512bw [bit 30]
qemu-x86_64: warning: TCG doesn't support requested feature: CPUID[eax=07h,ecx=00h].EBX.avx512vl [bit 31]
qemu-x86_64: warning: TCG doesn't support requested feature: CPUID[eax=07h,ecx=00h].ECX.vpclmulqdq [bit 10]
qemu: uncaught target signal 4 (Illegal instruction) - core dumped
```

Forcing CPU flags did not help:

```bash
/tmp/rr-qemu-v2-upstream-probes/build-10.2.3/qemu-x86_64 \
  -cpu max,+avx512f,check=off \
  /tmp/rr-qemu-v2-upstream-probes/micro-probes/vpxorq

/tmp/rr-qemu-v2-upstream-probes/build-11.0.1/qemu-x86_64 \
  -cpu max,+avx512f,check=off \
  /tmp/rr-qemu-v2-upstream-probes/micro-probes/vpxorq
```

Observed result: both returned `SIGILL` / shell `rc=132`.

## Root-Cause Evidence

QEMU `11.0.1` x86 TCG feature masks in `target/i386/cpu.c` include AVX2 and
VAES, but not AVX-512 feature bits or `vpclmulqdq`:

```c
#define TCG_7_0_EBX_FEATURES (... CPUID_7_0_EBX_AVX2 ... )
#define TCG_7_0_ECX_FEATURES (... CPUID_7_0_ECX_VAES ...)
```

The AVX-512 bits that the probe requires, including `avx512f`, `avx512dq`,
`avx512bw`, `avx512vl`, and `vpclmulqdq`, are not in the TCG-supported feature
mask. QEMU `10.2.3` has the same decisive behavior for this probe gate.

Focused micro-probes under QEMU `11.0.1` also failed at the first EVEX
instruction. Each binary had `_start` plus one relevant operation family:

| Micro-probe | Default CPU | `QEMU_CPU=SapphireRapids` |
|---|---:|---:|
| `vpxorq` | `SIGILL` / `132` | `SIGILL` / `132` |
| `vmovdqa64` | `SIGILL` / `132` | `SIGILL` / `132` |
| `vpternlogq` | `SIGILL` / `132` | `SIGILL` / `132` |
| `vaesenc` with ZMM operands | `SIGILL` / `132` | `SIGILL` / `132` |
| `vpclmullqlqdq` with ZMM operands | `SIGILL` / `132` | `SIGILL` / `132` |
| `vmovdqu8` with ZMM operands | `SIGILL` / `132` | `SIGILL` / `132` |

This makes the current V2 gate fail before PTC integration: unmodified upstream
linux-user TCG cannot execute the EVEX/ZMM instruction family that dominates
the current libcrypto false negatives.

## Candidate Assessment

| Candidate | Build as `x86_64-linux-user` | AVX2 probe | AVX-512/EVEX probe | Practical assessment |
|---|---|---|---|---|
| QEMU `10.2.3` | Pass | Pass | Fail: target `SIGILL` | Best practical source baseline only if V2 adds/ports EVEX support itself |
| QEMU `11.0.1` | Pass | Pass | Fail: target `SIGILL` | Useful as latest-reference source, but no decisive capability advantage |
| QEMU `6.2.x` | Not attempted | Not attempted | Expected high risk | Not a promising fallback for this gate unless there is contrary evidence that old TCG exposed AVX-512 |

## Recommendation

The original decision gate in `docs/plan-qemu-upgrade-v2.md` says to choose
`10.2.3` if it passes the AVX-512 probe, move to `11.0.1` if only `11.0.1`
passes, and consider fallback if both are blocked. The observed result is
stronger than a build/runtime block: both current upstream candidates build and
run AVX2, but both fail the AVX-512 capability gate in unmodified linux-user
TCG.

Recommended baseline decision:

1. Do not claim either `10.2.3` or `11.0.1` as an upstream AVX-512-capable
   backend baseline.
2. If the project still wants to proceed with the modern QEMU port, choose
   `10.2.3` as the source baseline for PTC/libtinycode integration work because
   it has the same probe outcome as `11.0.1`, appears slightly less churny, and
   matches the current plan's primary-target rationale.
3. Add an explicit pre-port milestone: prove one EVEX/ZMM instruction such as
   `vpxorq zmm0, zmm0, zmm0` can execute under linux-user TCG, or decide to
   implement a runnable-specific EVEX semantic path outside unmodified upstream
   TCG.
4. Keep `11.0.1` as a reference target and source-diff target, not as the
   implementation baseline unless a later EVEX patch is materially easier there.

Concrete next commands:

```bash
# Reproduce the current decisive failure from scratch after sources are present.
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
python3 runnable/scripts/qemu_v2_probe_suite.py \
  --build-dir /tmp/rr-qemu-v2-upstream-probes/probes-build \
  --probe avx512-evex \
  --qemu-x86_64 /tmp/rr-qemu-v2-upstream-probes/build-10.2.3/qemu-x86_64

# Inspect/patch the TCG feature mask and translator around EVEX support.
rg -n "TCG_7_0_EBX_FEATURES|TCG_7_0_ECX_FEATURES|avx512|EVEX|vpxorq" \
  /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3/target/i386

# If using the Docker runtime instead of host builds, avoid the current BuildKit proxy failure.
DOCKER_BUILDKIT=0 docker build -t rr_qemu_v2_runtime:latest docker/qemu-v2-runtime
```
