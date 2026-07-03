# QEMU V2 libtinycode Migration Design

Date: 2026-07-03

## Goal

Build a real `libtinycode-x86_64.so` and `libtinycode-helpers-x86_64.ll` from a QEMU 10.2.3 based Ubuntu 24.04 dependency chain, then make `runnable-lift` consume those artifacts without requiring the archived QEMU 2.4.50 `x86_64-libtinycode` backend.

## Non-Goals

- Do not treat the archived QEMU 2.4.50 build as a successful migration path.
- Do not ship an empty PTC shim as the final artifact.
- Do not make the libcrypto full run the first acceptance gate. It remains a later coverage gate after the tiny and scalar cases pass.
- Do not rewrite `runnable-lift`'s PTC ABI wholesale in the first migration step.

## Current State

`runnable-lift` already builds on Ubuntu 24.04 through `runnable/scripts/build_runnable_lift_v2.sh`. It still loads `libtinycode-<arch>.so`, `libtinycode-helpers-<arch>.ll`, and `early-linked-<arch>.ll` at runtime.

The current V2 wrapper has three modes:

- `--linux-user-only` builds upstream `qemu-x86_64` only.
- `--ptc-shim-stub` builds a transition stub that declares `REAL_PTC_TRANSLATION=not-migrated-empty-stub`.
- `--libtinycode` exits as not implemented.

The old QEMU 2.4.50 tree remains the only real `x86_64-libtinycode` build. Its `Makefile.target` changes the user emulator output to `libtinycode-$(TARGET_NAME).so`, emits `libtinycode-helpers-$(TARGET_NAME).ll`, and links the old `linux-user/ptc.c` implementation.

## Selected Approach

Implement a minimal real-translation QEMU V2 libtinycode backend first, then grow coverage through explicit tests and smoke targets.

The backend will be a real QEMU 10.2.3 derived shared library, not a legacy artifact and not an empty stub. It will export the PTC ABI expected by `runnable-lift`, including:

- `ptc_load`
- `ptc_translate`
- `ptc_get_abi_metadata`
- allocation and cleanup for `PTCInstructionList`
- metadata that reports ABI version 2 and `real_translation=true`

The first implementation can reuse the existing QEMU V2 walker/materializer logic from the current smoke scripts, but the delivered artifact must be produced by the V2 build wrapper and must fail closed when translation cannot be materialized.

## Architecture

### Build Wrapper

`runnable/scripts/build_qemu_libtinycode_v2.sh --libtinycode` becomes a working mode.

Inputs:

- QEMU 10.2.3 source tree through `--qemu-src` or `RUNNABLE_QEMU_V2_UPSTREAM_SRC`.
- Build directory through `--build-dir`.
- Install prefix through `--install-dir`.
- Ubuntu 24.04 runtime image or `--no-docker` host execution.

Outputs:

- `<install-dir>/lib/libtinycode-x86_64.so`
- `<install-dir>/lib/libtinycode-helpers-x86_64.ll`
- `<install-dir>/include/ptc.h`
- a small metadata file documenting QEMU source path, build mode, ABI version, and smoke result.

The wrapper must not silently fall back to archived QEMU 2.4.50. If the QEMU 10.2.3 source is missing or unsupported, it must fail with a direct diagnostic.

### V2 Backend Source

The V2 backend should live under the repository's QEMU V2 migration scripts until a vendored or external QEMU patch tree is finalized. The first target is a generated or staged source tree under the selected build directory, with the generated files recorded in the build log.

The backend boundary should be narrow:

- Load or initialize enough QEMU 10.2.3 linux-user translation state to translate one x86_64 basic block.
- Convert QEMU V2 TCG operation data into the existing PTC instruction model.
- Populate the legacy-compatible `PTCInterface` consumed by `runnable-lift`.
- Return a non-empty `PTCInstructionList` for supported scalar blocks.
- Reject unsupported operations with metadata and an error, instead of returning empty success.

### Helper IR

The migration must produce `libtinycode-helpers-x86_64.ll` from the V2 path. Initially this may be an adapted helper bundle if it is explicitly generated or staged by the V2 wrapper and validated with `runnable-lift`. It must not be copied from an unlabelled legacy location without provenance.

### Runtime Staging

Existing `runnable-lift` staging remains:

- `runnable-lift` searches next to the binary, install `lib`, install `share/runnable`, and `QEMU_INSTALL_PATH/lib`.
- libcrypto orchestration can stage explicit overrides via `--libtinycode-path` and `--libtinycode-helpers-path`.

The new build wrapper should print exact paths so downstream scripts can stage V2 artifacts deterministically.

## Error Handling

- Missing QEMU 10.2.3 source: fail before build.
- Empty-stub metadata: fail acceptance tests.
- `real_translation=false`: `runnable-lift` already refuses the library.
- Unsupported TCG op: `ptc_translate` returns failure and records the op name in diagnostics.
- Missing helper IR: wrapper fails before install success.
- Legacy artifact detected as output source: wrapper fails or labels it explicitly as non-accepted compatibility input.

## Testing Strategy

Testing proceeds in gates:

1. Unit tests for the build wrapper contract:
   - `--libtinycode` no longer exits as not implemented.
   - generated install prefix contains `.so`, helpers, and metadata.
   - wrapper rejects missing QEMU 10.2.3 source.
   - wrapper output does not report `REAL_PTC_TRANSLATION=not-migrated-empty-stub`.

2. Unit tests for V2 materialization:
   - scalar operations produce non-empty PTC lists.
   - unsupported operations fail closed.
   - metadata reports ABI version 2 and `real_translation=true`.

3. Smoke tests:
   - `dlopen(libtinycode-x86_64.so)` resolves `ptc_load`.
   - tiny x86_64 ELF lifts with V2 artifacts staged next to `runnable-lift`.
   - existing scalar QEMU V2 smoke path passes through the built artifact.

4. Integration gates:
   - bzip2 or a comparable small real binary lifts with the V2 artifact.
   - libcrypto subset runs with explicit `--libtinycode-path` and `--libtinycode-helpers-path`.

The full libcrypto canonical run is not required for the first accepted migration commit, but the implementation must move toward it and document remaining unsupported operations.

## Acceptance Criteria

- `bash runnable/scripts/build_qemu_libtinycode_v2.sh --libtinycode --qemu-src <qemu-10.2.3> --build-dir <dir> --install-dir <prefix>` exits 0 on Ubuntu 24.04.
- The install prefix contains `lib/libtinycode-x86_64.so`, `lib/libtinycode-helpers-x86_64.ll`, and `include/ptc.h`.
- The built library exports `ptc_load` and `ptc_get_abi_metadata`.
- Metadata reports `abi_version=2` and `real_translation=true`.
- A smoke lift using the generated artifacts reaches `runnable-lift` translation without the "empty-stub" refusal and without the "Couldn't find libtinycode and the helpers" failure.
- Tests prove the wrapper does not rely on `archive/qemu-legacy-2.4.50` as the implementation source.

## Implementation Notes

- Prefer extending the existing QEMU V2 smoke/materializer scripts over adding a second unrelated translator.
- Keep the `runnable-lift` ABI stable unless a test proves an ABI change is required.
- Use explicit artifact paths in scripts and tests; do not depend on whichever `libtinycode-x86_64.so` happens to be in the source tree.
- Keep legacy compatibility paths available for archaeology, but make them opt-in and visibly non-accepted for this migration.
