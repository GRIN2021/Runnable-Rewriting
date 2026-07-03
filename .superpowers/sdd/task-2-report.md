# Task 2 Report: Helper IR Generator

## Result

- Added `runnable/scripts/qemu_v2_generate_libtinycode_helpers.py` as specified in the Task 2 brief.
- The script consumes `--model-json`, `--output`, `--qemu-src`, and `--library-path`, extracts helper names from `helper_defs`, and emits LLVM IR text with provenance comments.
- Committed as `e38f975a` with message:
  `feat: add qemu v2 libtinycode helper ir generator`

## Verification

- Focused regression:
  - `python3 -m pytest test/test_build_qemu_libtinycode_v2.py::BuildQemuLibtinycodeV2Tests::test_libtinycode_mode_installs_live_sidecar_artifacts_from_replay_fixture -q`
  - Result: failed as expected because `build_qemu_libtinycode_v2.sh` still rejects `--replay-payload` and the generator/install path is not wired yet.
- Syntax check:
  - `python3 -m py_compile runnable/scripts/qemu_v2_generate_libtinycode_helpers.py`
  - Result: exited 0.

## Notes

- No changes were made to Task 1 tests or `build_qemu_libtinycode_v2.sh`.
- The remaining failure belongs to Task 3 wiring, not the generator script.

---

## Task 2 review-fix follow-up (2026-07-03)

### Commands and results

- `python3 -m unittest discover -s test -p 'test_build_qemu_libtinycode_v2.py'`
  - Result: `FAILED (failures=4)`.
  - Notes: the new helper-generator coverage exposed the intended red collision case; three other failures are pre-existing in the current tree and come from unfinished `--libtinycode` build-script wiring outside the owned files.
- `python3 -m unittest discover -s test -p 'test_build_qemu_libtinycode_v2.py' -k helper_generator`
  - Result before generator fix: `FAILED (failures=1)` because distinct helpers `beta.gamma` and `beta-gamma` both sanitized to `@beta_gamma`.
- `python3 -m unittest discover -s test -p 'test_build_qemu_libtinycode_v2.py' -k helper_generator`
  - Result after generator fix: `OK (Ran 2 tests)`.
- `python3 -m py_compile runnable/scripts/qemu_v2_generate_libtinycode_helpers.py`
  - Result: exited 0.

### Changed files

- `test/test_build_qemu_libtinycode_v2.py`
- `runnable/scripts/qemu_v2_generate_libtinycode_helpers.py`

### Commit

- `7c121fa1` — `test: cover qemu v2 helper ir generation`

### Concerns

- The current repository state still has pre-existing `BuildQemuLibtinycodeV2Tests` failures tied to unimplemented `--libtinycode` build flow in `build_qemu_libtinycode_v2.sh`, which this task explicitly forbids changing.
