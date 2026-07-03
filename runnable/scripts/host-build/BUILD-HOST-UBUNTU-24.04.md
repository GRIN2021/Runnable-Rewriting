# Building runnable-lift on Ubuntu 24.04 (No Docker)

This guide builds and runs the QEMU-v2-line `runnable-lift` directly on an
Ubuntu 24.04 host. The default LLVM is the Ubuntu 24.04 apt LLVM package
(usually LLVM 18), resolved with `llvm-config --cmakedir`.

The helper scripts live under `runnable/scripts/host-build/`.

## Why this works without Docker

The QEMU-v2 runtime Docker image keeps the `runnable-lift` binary and the
environment it runs in on the same glibc/libstdc++. A binary built against a
newer glibc than the runtime fails with errors like:

```text
runnable-lift: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.34' not found
runnable-lift: .../libstdc++.so.6: version `GLIBCXX_3.4.32' not found
```

On Ubuntu 24.04 build host to Ubuntu 24.04 run host, glibc matches by
construction. The existing `build_runnable_lift_v2.sh` already supports native
`--no-docker` mode; the host wrapper here just installs the apt dependencies,
resolves LLVM, and delegates to that build.

## Scope

This builds `runnable-lift` only (the QEMU-v2 migration line, artifact under
`build-codex-dynamic-current/`). It does not build QEMU 10.2.3, the libcrypto
canonical evaluation, or the classic `make install-runnable` toolchain.

`runnable-lift --help` should work after the build. An actual lift additionally
needs the libtinycode runtime artifacts described below.

## Prerequisites

- Ubuntu 24.04 (noble), x86_64. Check with `lsb_release -a`.
- `sudo` for `apt`.
- The repo checked out at a writable path:

  ```bash
  git clone git@github.com:GRIN2021/Runnable-Rewriting.git
  cd Runnable-Rewriting
  git checkout codex/qemu-upgrade-v2
  ```

## LLVM model

The default path is the Ubuntu apt LLVM:

```bash
sudo bash runnable/scripts/host-build/install-host-deps.sh
llvm-config --version
llvm-config --cmakedir
```

On Ubuntu 24.04 this is normally LLVM 18, with CMake files under:

```text
/usr/lib/llvm-18/lib/cmake/llvm
```

The host build wrapper resolves LLVM in this order:

1. `--llvm-dir DIR`: exact directory containing `LLVMConfig.cmake`.
2. `--llvm-root DIR`: LLVM/Clang prefix containing `lib/cmake/llvm`.
3. System `llvm-config --cmakedir`: the default after installing `llvm-dev`.

The old repo-local `root/` LLVM 7 tree is only a legacy fallback. Use it only
when you explicitly want that toolchain:

```bash
bash runnable/scripts/host-build/build-runnable-lift-host.sh \
  --llvm-root root \
  --verify
```

or:

```bash
bash runnable/scripts/host-build/build-runnable-lift-host.sh \
  --llvm-dir root/lib/cmake/llvm \
  --verify
```

A fresh Ubuntu 24.04 host build does not require copying `root/`.

## QEMU V2 libtinycode artifacts

`runnable-lift` dlopens `libtinycode-<arch>.so` at runtime (see
`runnable/tools/runnable-lift/Main.cpp`, function `findFiles`). These files are
not produced by runnable's CMake build and are not git-tracked.

The preferred Ubuntu 24.04 path is the QEMU V2 wrapper:

```bash
bash runnable/scripts/build_qemu_libtinycode_v2.sh \
  --libtinycode \
  --no-docker \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  --build-dir /tmp/rr-qemu-v2-libtinycode-build/build \
  --install-dir /tmp/rr-qemu-v2-libtinycode-build/root \
  --jobs 3
```

This installs:

- `/tmp/rr-qemu-v2-libtinycode-build/root/lib/libtinycode-x86_64.so`
- `/tmp/rr-qemu-v2-libtinycode-build/root/lib/libtinycode-helpers-x86_64.ll`
- `/tmp/rr-qemu-v2-libtinycode-build/root/include/ptc.h`
- `/tmp/rr-qemu-v2-libtinycode-build/root/share/runnable/qemu-v2-libtinycode.json`

For `runnable-lift`, stage the shared object and helpers IR next to the binary:

```bash
mkdir -p build-codex-dynamic-current/tools/runnable-lift
cp <existing>/libtinycode-x86_64.so         build-codex-dynamic-current/tools/runnable-lift/
cp <existing>/libtinycode-helpers-x86_64.ll build-codex-dynamic-current/tools/runnable-lift/
```

`early-linked-x86_64.ll` still comes from runnable's CMake build, generated
with LLVM's `clang`.

`runnable-lift --help` works without these. A real lift aborts with
`Couldn't find libtinycode and the helpers` until they are staged. The smoke
script checks this up front and prints a clearer message. Current fast smoke
evidence reaches a `real_translation=true` source library, but later lifting
still blocks at pc-divergence; do not treat that as full libcrypto success.

The legacy QEMU 2.4.50 `x86_64-libtinycode` build
(`support/components/qemu.mk`) remains available only for archaeology and
compatibility. It is not the accepted QEMU V2 migration path.

## Step 1 - install build dependencies

```bash
sudo bash runnable/scripts/host-build/install-host-deps.sh
```

This installs the Ubuntu 24.04 host package set for runnable-lift, including
`clang`, `lld`, `llvm`, `llvm-dev`, `cmake`, `ninja-build`, `pkg-config`,
`ccache`, `git`, `zlib1g-dev`, `libboost-dev`, `libglib2.0-dev`, `python3`,
`python3-pygraphviz`, and supporting build tools. `llvm-dev` provides the
default `llvm-config --cmakedir` path used by the host wrapper.

## Step 2 - build runnable-lift

```bash
bash runnable/scripts/host-build/build-runnable-lift-host.sh --verify
```

This wrapper:

1. Resolves `LLVM_DIR` from system `llvm-config --cmakedir` by default.
2. Advises whether the libtinycode artifacts are staged.
3. Delegates to `runnable/scripts/build_runnable_lift_v2.sh --no-docker`.
4. With `--verify`, runs `ldd` and `runnable-lift --help`.

The canonical artifact is the build-tree binary:

```text
build-codex-dynamic-current/tools/runnable-lift/runnable-lift
```

`cmake --install` does not install `runnable-lift`; the build-tree binary is
what the QEMU-v2 scripts use.

### Options

| Flag | Default | Purpose |
|---|---|---|
| `--build-dir DIR` | `build-codex-dynamic-current` | build directory |
| `--llvm-dir DIR` | system `llvm-config --cmakedir` | exact dir containing `LLVMConfig.cmake` |
| `--llvm-root DIR` | unset | LLVM prefix, including legacy `root/` |
| `--build-type TYPE` | `Debug` | CMake build type |
| `--jobs N` / `-j N` | `nproc` | parallel jobs |
| `--verify` | off | `ldd` plus `runnable-lift --help` after build |

Example explicit apt LLVM path:

```bash
bash runnable/scripts/host-build/build-runnable-lift-host.sh \
  --llvm-dir /usr/lib/llvm-18/lib/cmake/llvm \
  --verify
```

## Step 3 - smoke test (tiny ELF lift)

```bash
bash runnable/scripts/host-build/smoke-tiny-elf-host.sh
```

This compiles a tiny static ELF (a single `exit(0)` syscall), lifts it to LLVM
IR with the freshly built `runnable-lift`, and asserts the `.ll` is non-empty
and the lift reports `Rewrite Successful`. On success it prints:

```text
TINY_ELF_LIFT_SMOKE=pass
```

If the libtinycode runtime artifacts are missing, it fails up front with the
exact `cp` commands to run.

## Running the binary by hand

The build-tree binary needs its analysis libraries on `LD_LIBRARY_PATH`. Add
the LLVM libdir too when using a non-system LLVM:

```bash
B=build-codex-dynamic-current
LLVM_LIBDIR="$(llvm-config --libdir)"
export LD_LIBRARY_PATH="$PWD/$B/lib/StackAnalysis:$PWD/$B/lib/BasicAnalyses:$PWD/$B/lib/Support:$LLVM_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

./$B/tools/runnable-lift/runnable-lift --help
```

For legacy `root/`, replace `LLVM_LIBDIR` with `$PWD/root/lib`.

## FAQ

### `error: system llvm-config not found`

Install the host dependencies:

```bash
sudo bash runnable/scripts/host-build/install-host-deps.sh
```

Or pass an explicit LLVM:

```bash
bash runnable/scripts/host-build/build-runnable-lift-host.sh \
  --llvm-dir /usr/lib/llvm-18/lib/cmake/llvm
```

### `LLVMConfig.cmake not found`

Confirm the apt LLVM CMake directory:

```bash
llvm-config --cmakedir
test -f "$(llvm-config --cmakedir)/LLVMConfig.cmake"
```

Then pass that directory with `--llvm-dir`.

### `Cannot find the pygraphviz module`

Install the host dependencies again; `python3-pygraphviz` is required during
CMake configure to generate `ABIDataFlows.h`:

```bash
sudo bash runnable/scripts/host-build/install-host-deps.sh
```

### `boost/...: No such file or directory`

Install the host dependencies again; `libboost-dev` provides the Boost headers
used by `runnable-lift` (`boost/icl/*`, `boost/variant.hpp`):

```bash
sudo bash runnable/scripts/host-build/install-host-deps.sh
```

### I still need the old `root/` LLVM 7 tree

Stage it only for that legacy path:

```bash
rsync -a <existing>/Runnable-Rewriting/root/ ./root/
bash runnable/scripts/host-build/build-runnable-lift-host.sh --llvm-root root --verify
```

Expected legacy contents:

```text
root/bin/llvm-config
root/bin/clang
root/lib/cmake/llvm/LLVMConfig.cmake
```

### `Couldn't find libtinycode and the helpers`

`runnable-lift` runs but cannot lift: the libtinycode runtime artifacts are not
next to the binary. Stage `libtinycode-x86_64.so` and
`libtinycode-helpers-x86_64.ll` as described above. `--help` works without
them; an actual lift does not.

### `GLIBC_2.34 not found` / `GLIBCXX_3.4.32 not found` at load

This should not happen when you build and run on the same Ubuntu 24.04 host.
If you see it, you likely copied a binary built on a different distro. Rebuild
on this host with `build-runnable-lift-host.sh --verify`.

### `ld` or analysis-library errors at runtime

Confirm `LD_LIBRARY_PATH` includes all of:

```text
build-codex-dynamic-current/lib/StackAnalysis
build-codex-dynamic-current/lib/BasicAnalyses
build-codex-dynamic-current/lib/Support
$(llvm-config --libdir)
```

For legacy `root/`, use `root/lib` instead of `$(llvm-config --libdir)`.

## Script index

| Script | Purpose |
|---|---|
| `install-host-deps.sh` | apt install the Ubuntu 24.04 build packages |
| `build-runnable-lift-host.sh` | native build wrapper using apt LLVM by default |
| `smoke-tiny-elf-host.sh` | tiny static ELF lift smoke test on the host |

## See also

- `runnable/scripts/build_runnable_lift_v2.sh` - the underlying native/container
  build wrapper (`--no-docker` mode is what this guide uses).
- `docs/qemu-v2-runnable-reproduce.md` - the container-based reproduction guide
  (use this instead if your host is not Ubuntu 24.04).
