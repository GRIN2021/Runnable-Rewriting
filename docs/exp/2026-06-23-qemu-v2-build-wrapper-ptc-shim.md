# 2026-06-23 QEMU V2 Build Wrapper PTC Shim Stub

Branch: `codex/qemu-upgrade-v2`

## Purpose

Add an explicit transition mode to `runnable/scripts/build_qemu_libtinycode_v2.sh`
for building the current minimal PTC shim stub:

```bash
runnable/scripts/build_qemu_libtinycode_v2.sh \
  --ptc-shim-stub \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3
```

This mode is not the final QEMU V2 `libtinycode` migration. It produces a
repeatable `/tmp` artifact for the current empty-translation shim only.

Required marker:

```text
REAL_PTC_TRANSLATION=not-migrated-empty-stub
```

## Wrapper Behavior

The wrapper now has three explicit modes:

- `--linux-user-only`: unchanged upstream QEMU linux-user configure/build/install path.
- `--ptc-shim-stub`: generate a standalone shim tree under `/tmp`, run `make`,
  then run `make smoke`.
- `--libtinycode`: still exits as not implemented for the real migrated
  libtinycode path.

`--ptc-shim-stub` accepts:

- `--qemu-src DIR`: QEMU `10.2.3` source tree. If omitted, the wrapper tries
  `$QEMU_V2_SRC`, `/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3`, and nearby
  `/tmp`/repo-adjacent candidates.
- `--ptc-shim-out-dir DIR`: generated shim project directory. Relative values
  are placed under `/tmp`; absolute values must resolve below `/tmp`.
- `--jobs N`: parallel build jobs for the stub `make` step.

The wrapper prints the generated tree and artifact path before building. The
shared object remains outside the repository:

```text
artifact=/tmp/qemu-v2-ptc-shim-build-wrapper-ag/build/libtinycode-x86_64.so
```

## Validation

Syntax check:

```bash
bash -n runnable/scripts/build_qemu_libtinycode_v2.sh
```

Result: passed.

Stub build and smoke:

```bash
runnable/scripts/build_qemu_libtinycode_v2.sh \
  --ptc-shim-stub \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  --ptc-shim-out-dir /tmp/qemu-v2-ptc-shim-build-wrapper-ag \
  --jobs 2
```

Result: passed.

Key output:

```text
mode            : ptc-shim-stub
qemu src        : /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3
shim tree       : /tmp/qemu-v2-ptc-shim-build-wrapper-ag
artifact        : /tmp/qemu-v2-ptc-shim-build-wrapper-ag/build/libtinycode-x86_64.so
REAL_PTC_TRANSLATION=not-migrated-empty-stub
smoke ok: pc=128 sp=32 exception_index=136 helper_defs_size=0 ...
stub shim build ok
artifact=/tmp/qemu-v2-ptc-shim-build-wrapper-ag/build/libtinycode-x86_64.so
REAL_PTC_TRANSLATION=not-migrated-empty-stub
```

Artifact check:

```text
/tmp/qemu-v2-ptc-shim-build-wrapper-ag/build/libtinycode-x86_64.so:
ELF 64-bit LSB shared object, x86-64
```

## Interpretation

This wrapper mode only makes the current minimal shim reproducible through the
QEMU V2 build entry point. It does not wire modern QEMU translation, does not
emit real `PTCInstructionList` contents, and does not move
`libtinycode-x86_64.so` into the repository.

The real migration still requires modern QEMU linux-user initialization,
translate-only TB generation or equivalent integration, a modern TCG op walker,
helper metadata, and non-empty PTC output.
