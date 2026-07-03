# Task 1 Report: Wrapper Contract Tests

Date: 2026-07-03

## Scope

Strengthened the red contract tests for `runnable/scripts/build_qemu_libtinycode_v2.sh` in:

- `test/test_build_qemu_libtinycode_v2.py`

No production code was modified.

## Verification

Ran:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
python3 -m pytest test/test_build_qemu_libtinycode_v2.py -q
```

Result: 3 failing tests.

Observed current failure modes:

1. `test_libtinycode_mode_rejects_missing_qemu_source_instead_of_not_implemented`
   - Fails because the wrapper still prints the explicit `libtinycode-specific QEMU V2 build is not implemented yet` diagnostic before it reaches the source-tree validation contract.

2. `test_libtinycode_mode_rejects_wrong_qemu_version_tree`
   - Fails for the same early `not implemented yet` path, before the new `VERSION=10.2.2` rejection contract can be exercised.

3. `test_libtinycode_mode_installs_live_sidecar_artifacts_from_replay_fixture`
   - Fails earlier on `error: unknown argument: --replay-payload`, which matches the current parser not supporting the replay contract yet.

## Added Contracts

- Reusable fake QEMU tree helper that can emit arbitrary `VERSION` values.
- Wrong-version QEMU tree rejection contract for `VERSION=10.2.2`.
- Legacy-poison guard that stages a fake `RUNNABLE_QEMU_LEGACY_SRC` with a marker-writing `configure` script and asserts the marker stays absent.
- Direct ABI metadata verification via `ctypes.CDLL(...).ptc_get_abi_metadata()` after the happy-path install.

## Commit

Committed as:

```bash
git add test/test_build_qemu_libtinycode_v2.py .superpowers/sdd/task-1-report.md
git commit -m "test: strengthen qemu v2 libtinycode contract"
```

## Notes

- The happy-path test now checks JSON metadata and also probes the installed `.so` for `ptc_get_abi_metadata()` once the wrapper returns success.
- The report file is included per the follow-up task request.
- Untracked workspace artifacts outside the target files were left untouched.
