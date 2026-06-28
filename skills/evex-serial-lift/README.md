# EVEX Serial Lift — Reproducibility Skills

Reproduces the runnable serial lift of `libcrypto.so.3` using the EVEX libtinycode
(new QEMU v2 backend with AVX-512/AES-NI support) on a stock Ubuntu 24.04 machine.

## Baseline results (Jun-28)

| Metric     | Value    |
|------------|----------|
| Precision  | 0.986520 |
| Recall     | 0.927971 |
| Elapsed    | ~40 min  |
| LL size    | ~1.96 GB |
| rc         | 0        |

## Requirements

- Ubuntu 24.04 x86-64 (native or VM, no Docker needed)
- ~5 GB free disk space for the artifact tarball + lift output
- ~4 GB RAM (the lift uses very little memory in serial mode)

## Step 1 — Package artifacts (source machine)

On the machine that has the compiled binaries:

```bash
cd skills/evex-serial-lift
./package.sh
# Creates: runnable-evex-artifacts.tar.gz (~75 MB)

scp runnable-evex-artifacts.tar.gz user@target-host:~/
```

The tarball includes:
- `bin/runnable-lift` — 55 MB, statically linked against LLVM 18, no LLVM install needed
- `lib/libtinycode-x86_64.so` — 4.4 MB EVEX libtinycode (self-contained QEMU v2 backend)
- `lib/libtinycode-helpers-x86_64.ll` — EVEX IR helper definitions
- `lib/librunnableSupport.so` and `lib/runnable/analyses/*.so` — runnable runtime libs
- `share/runnable/*.py` — pure-stdlib Python eval scripts
- `ground-truth/libcrypto.so.3` — the target binary
- `ground-truth/libcrypto.gtBlock.pb` — ground truth for recall evaluation

## Step 2 — Setup (target Ubuntu 24.04 machine)

```bash
# Install system deps and extract artifacts
chmod +x setup.sh lift.sh eval.sh
./setup.sh runnable-evex-artifacts.tar.gz --install-dir ~/runnable-evex
```

Installed apt packages: `zlib1g libzstd1 libtinfo6 libstdc++6 python3 binutils`
(all standard; no pip/conda/venv required)

## Step 3 — Run serial lift (~40 min)

```bash
./lift.sh --install-dir ~/runnable-evex --out-dir ~/evex-lift-out
```

Expected terminal output:
```
[2026-06-28T...] START
[2026-06-28T...] END rc=0 elapsed=2384s
LL_OK size=1963583173 lines=47764776
```

## Step 4 — Evaluate recall

```bash
./eval.sh \
  --install-dir ~/runnable-evex \
  --ll ~/evex-lift-out/libcrypto.evex.serial.ll \
  --out-dir ~/evex-lift-out/cmp_eval
```

Expected output:
```
cmp_metrics=precision=0.986520 recall=0.927971 ...

=== Summary ===
  precision : 0.986520
  recall    : 0.927971
  hit       : 611753
  fn        : 47706
  fp        : 8716
```

## Architecture notes

- Entry point: `0x500cef80` = base `0x50000000` + `.text` start `0xcef80`
- `-no-link`: outputs raw LLVM IR, not a linked binary
- `-use-debug-symbols`: attaches DWARF symbol names to functions
- The lift explores the full `.text` section from the single entry, following all
  reachable code paths. AES/SIMD blocks that are unreachable from the entry are
  the main source of the 7.2% FN (covered by static fallback profiles if needed).

## Troubleshooting

**`libLLVMCore.so.7: cannot open shared object file`**
→ You're using the wrong `runnable-lift`. The artifact tarball contains the correct
  LLVM-18 statically linked binary. Don't replace it with binaries from other builds.

**`libtinycode-x86_64.so: cannot open shared object file`**
→ `LD_LIBRARY_PATH` not set. The `lift.sh` script sets this automatically.
  If running manually: `export LD_LIBRARY_PATH=~/runnable-evex/lib:~/runnable-evex/lib/runnable/analyses`

**Recall significantly lower than 0.928**
→ Check that `libtinycode-x86_64.so` is the EVEX version (4,386,744 bytes).
  A 67 KB file means you have the PTC shim, not the full EVEX backend.
