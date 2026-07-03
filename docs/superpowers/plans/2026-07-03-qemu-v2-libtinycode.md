# QEMU V2 libtinycode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `runnable/scripts/build_qemu_libtinycode_v2.sh --libtinycode` build and install a QEMU 10.2.3 / Ubuntu 24.04 V2 `libtinycode-x86_64.so` artifact with `real_translation=true`, without using the archived QEMU 2.4.50 build as the implementation path.

**Architecture:** Promote the existing live-sidecar real-translation smoke path into the formal `--libtinycode` build/install mode. The wrapper validates QEMU 10.2.3 input, invokes `qemu_v2_ptc_live_sidecar_translate_smoke.sh`, installs the generated shared object, generates a provenance-labelled helper IR module, installs `ptc.h`, writes metadata, and verifies exported ABI metadata.

**Tech Stack:** Bash, Python 3, pytest/unittest, C `dlopen` smoke harnesses, existing QEMU V2 live-sidecar materializer scripts, Ubuntu 24.04 runtime image.

## Global Constraints

- The success path must not invoke `archive/qemu-legacy-2.4.50/configure` or the classic `x86_64-libtinycode` build.
- The installed shared object must report `abi_version=2` and `real_translation=true` through `ptc_get_abi_metadata`.
- The installed shared object must not report `REAL_PTC_TRANSLATION=not-migrated-empty-stub`.
- The wrapper must fail directly for missing or non-10.2.3 QEMU sources.
- The first accepted gate is tiny/scalar real translation; full libcrypto remains a later coverage gate.
- Existing `runnable-lift` PTC ABI must remain stable unless a failing test proves a required ABI change.

---

## File Structure

- Modify `runnable/scripts/build_qemu_libtinycode_v2.sh`: implement the `--libtinycode` mode, add replay/test inputs, install artifacts, generate metadata, and keep Docker handoff correct.
- Create `runnable/scripts/qemu_v2_generate_libtinycode_helpers.py`: generate a provenance-labelled `libtinycode-helpers-x86_64.ll` from live-sidecar model/helper metadata or a no-helper scalar module.
- Create `test/test_build_qemu_libtinycode_v2.py`: fast contract tests using temporary fake QEMU 10.2.3 trees and replay payload/model fixtures.
- Modify `runnable/scripts/host-build/BUILD-HOST-UBUNTU-24.04.md`: document how to build/stage V2 libtinycode artifacts on Ubuntu 24.04.

## Task 1: Wrapper Contract Tests

**Files:**
- Create: `test/test_build_qemu_libtinycode_v2.py`
- Modify: none
- Test: `test/test_build_qemu_libtinycode_v2.py`

**Interfaces:**
- Consumes: existing `runnable/scripts/build_qemu_libtinycode_v2.sh`
- Produces: test helpers `make_fake_qemu_10_2_3`, `write_replay_fixture`, and tests that later implementation must satisfy.

- [ ] **Step 1: Write the failing test file**

Create `test/test_build_qemu_libtinycode_v2.py` with:

```python
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "runnable" / "scripts" / "build_qemu_libtinycode_v2.sh"


def make_fake_qemu_10_2_3(root: Path) -> Path:
    qemu = root / "qemu-10.2.3"
    qemu.mkdir()
    (qemu / "meson.build").write_text("project('qemu', 'c')\n", encoding="utf-8")
    configure = qemu / "configure"
    configure.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    configure.chmod(configure.stat().st_mode | stat.S_IXUSR)
    (qemu / "VERSION").write_text("10.2.3\n", encoding="utf-8")
    return qemu


def write_replay_fixture(root: Path) -> tuple[Path, Path, Path]:
    fixture = root / "fixture"
    fixture.mkdir()
    payload = fixture / "sidecar.payload.txt"
    model = fixture / "sidecar.model.json"
    summary = fixture / "sidecar.summary.json"

    payload.write_text(
        "\n".join(
            [
                "PTC_LIVE_SIDECAR v1",
                "instruction_count=1",
                "argument_count=3",
                "temp_count=1",
                "global_temps=1",
                "total_temps=1",
                "dynamic_pc=0x401001",
                "instruction|0|debug_insn_start|0|0|3|0x401000,0,0",
                "temp|0|env|0|1|1|0|0|0|0|0|0|0|0|0",
                "",
            ]
        ),
        encoding="utf-8",
    )
    model.write_text(
        json.dumps(
            {
                "schema": "qemu-v2-ptc-live-sidecar-model-v1",
                "helper_defs": [],
                "instructions": [],
                "temps": [],
            }
        ),
        encoding="utf-8",
    )
    summary.write_text(
        json.dumps(
            {
                "payload_instruction_count": 1,
                "selected_instruction_count": 1,
                "source_instruction_count": 1,
                "rejected_instruction_count": 0,
            }
        ),
        encoding="utf-8",
    )
    return payload, model, summary


class BuildQemuLibtinycodeV2Tests(unittest.TestCase):
    def run_script(self, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        merged_env = os.environ.copy()
        if env:
            merged_env.update(env)
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            cwd=REPO_ROOT,
            env=merged_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

    def test_libtinycode_mode_rejects_missing_qemu_source_instead_of_not_implemented(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result = self.run_script(
                "--libtinycode",
                "--no-docker",
                "--qemu-src",
                str(root / "missing-qemu"),
                "--build-dir",
                str(root / "build"),
                "--install-dir",
                str(root / "install"),
            )

        self.assertNotEqual(result.returncode, 0)
        combined = result.stdout + result.stderr
        self.assertIn("QEMU 10.2.3 source tree", combined)
        self.assertNotIn("not implemented yet", combined)

    def test_libtinycode_mode_installs_live_sidecar_artifacts_from_replay_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            qemu = make_fake_qemu_10_2_3(root)
            payload, model, summary = write_replay_fixture(root)
            build_dir = root / "build"
            install_dir = root / "install"

            result = self.run_script(
                "--libtinycode",
                "--no-docker",
                "--qemu-src",
                str(qemu),
                "--build-dir",
                str(build_dir),
                "--install-dir",
                str(install_dir),
                "--jobs",
                "1",
                "--replay-payload",
                str(payload),
                "--replay-model",
                str(model),
                "--replay-summary",
                str(summary),
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            combined = result.stdout + result.stderr
            self.assertIn("LIBTINYCODE_V2_BUILD_OK=1", combined)
            self.assertIn("real_translation=true", combined)
            self.assertNotIn("REAL_PTC_TRANSLATION=not-migrated-empty-stub", combined)

            libtinycode = install_dir / "lib" / "libtinycode-x86_64.so"
            helpers = install_dir / "lib" / "libtinycode-helpers-x86_64.ll"
            header = install_dir / "include" / "ptc.h"
            metadata = install_dir / "share" / "runnable" / "qemu-v2-libtinycode.json"

            self.assertTrue(libtinycode.is_file())
            self.assertTrue(helpers.is_file())
            self.assertTrue(header.is_file())
            self.assertTrue(metadata.is_file())
            self.assertIn("qemu-v2-libtinycode-helpers", helpers.read_text(encoding="utf-8"))
            data = json.loads(metadata.read_text(encoding="utf-8"))
            self.assertEqual(data["schema"], "qemu-v2-libtinycode-build-v1")
            self.assertEqual(data["qemu_version"], "10.2.3")
            self.assertEqual(data["abi_version"], "2")
            self.assertEqual(data["real_translation"], "true")
            self.assertNotIn("archive/qemu-legacy-2.4.50", data["implementation_source"])
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
python3 -m pytest test/test_build_qemu_libtinycode_v2.py -q
```

Expected: both tests fail before implementation. The first failure shows the current "not implemented yet" message. The second failure exits before creating artifacts because `--libtinycode` is not implemented and replay options are unknown.

- [ ] **Step 3: Commit the red tests**

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
git add test/test_build_qemu_libtinycode_v2.py
git commit -m "test: capture qemu v2 libtinycode build contract"
```

## Task 2: Helper IR Generator

**Files:**
- Create: `runnable/scripts/qemu_v2_generate_libtinycode_helpers.py`
- Test: `test/test_build_qemu_libtinycode_v2.py`

**Interfaces:**
- Consumes: optional live-sidecar model JSON with `helper_defs`.
- Produces: CLI `qemu_v2_generate_libtinycode_helpers.py --model-json PATH --output PATH --qemu-src PATH --library-path PATH` that writes LLVM IR text.

- [ ] **Step 1: Write the generator implementation**

Create `runnable/scripts/qemu_v2_generate_libtinycode_helpers.py` with:

```python
#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--qemu-src", type=Path, required=True)
    parser.add_argument("--library-path", type=Path, required=True)
    return parser.parse_args()


def load_helper_names(model_json: Path) -> list[str]:
    model = json.loads(model_json.read_text(encoding="utf-8"))
    helpers = model.get("helper_defs")
    if not isinstance(helpers, list):
        return []
    names: list[str] = []
    for helper in helpers:
        if not isinstance(helper, dict):
            continue
        raw_name = helper.get("name")
        if not isinstance(raw_name, str) or not raw_name:
            continue
        name = raw_name.removeprefix("helper_")
        if name and name not in names:
            names.append(name)
    return names


def render_helpers(helper_names: list[str], *, qemu_src: Path, library_path: Path) -> str:
    lines = [
        "; ModuleID = 'qemu-v2-libtinycode-helpers'",
        "source_filename = \"qemu-v2-libtinycode-helpers\"",
        f"; qemu_src = {qemu_src}",
        f"; library_path = {library_path}",
        "; provenance = generated-by-qemu_v2_generate_libtinycode_helpers.py",
        "",
    ]
    if not helper_names:
        lines.extend(
            [
                "; No helper definitions were required by the captured scalar payload.",
                "define void @__qemu_v2_libtinycode_no_helpers_required() {",
                "entry:",
                "  ret void",
                "}",
                "",
            ]
        )
        return "\n".join(lines)
    for name in helper_names:
        safe = "".join(ch if ch.isalnum() or ch == "_" else "_" for ch in name)
        lines.extend(
            [
                f"; helper = {name}",
                f"declare void @{safe}()",
                "",
            ]
        )
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    helper_names = load_helper_names(args.model_json)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        render_helpers(helper_names, qemu_src=args.qemu_src, library_path=args.library_path),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: Run focused test**

Run:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
python3 -m pytest test/test_build_qemu_libtinycode_v2.py::BuildQemuLibtinycodeV2Tests::test_libtinycode_mode_installs_live_sidecar_artifacts_from_replay_fixture -q
```

Expected: still fails because the build wrapper has not wired the generator or install path yet.

- [ ] **Step 3: Commit helper generator**

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
git add runnable/scripts/qemu_v2_generate_libtinycode_helpers.py
git commit -m "feat: add qemu v2 libtinycode helper ir generator"
```

## Task 3: Implement `--libtinycode` Build/Install Mode

**Files:**
- Modify: `runnable/scripts/build_qemu_libtinycode_v2.sh`
- Test: `test/test_build_qemu_libtinycode_v2.py`

**Interfaces:**
- Consumes: `qemu_v2_ptc_live_sidecar_translate_smoke.sh`, `qemu_v2_generate_libtinycode_helpers.py`
- Produces: installed V2 artifacts under `<install-dir>/lib`, `<install-dir>/include`, and `<install-dir>/share/runnable/qemu-v2-libtinycode.json`.

- [ ] **Step 1: Add replay options and libtinycode variables**

In `runnable/scripts/build_qemu_libtinycode_v2.sh`, add variables near the existing mode variables:

```bash
REPLAY_PAYLOAD=""
REPLAY_MODEL=""
REPLAY_SUMMARY=""
```

Extend usage options:

```text
  --replay-payload PATH   Test/developer replay payload for --libtinycode.
  --replay-model PATH     Test/developer replay model JSON for --libtinycode.
  --replay-summary PATH   Test/developer replay summary JSON for --libtinycode.
```

Add parser cases:

```bash
    --replay-payload)
      REPLAY_PAYLOAD="${2:?missing value for --replay-payload}"
      shift 2
      ;;
    --replay-model)
      REPLAY_MODEL="${2:?missing value for --replay-model}"
      shift 2
      ;;
    --replay-summary)
      REPLAY_SUMMARY="${2:?missing value for --replay-summary}"
      shift 2
      ;;
```

- [ ] **Step 2: Replace `not_implemented_libtinycode` with a real function**

Add this function above the argument parser:

```bash
build_libtinycode_v2() {
  local qemu_src_abs build_dir_abs install_dir_abs scratch_root lib_so helper_ir metadata_json
  local live_script helper_generator sidecar_model sidecar_summary qemu_version
  local -a live_args metadata_args

  live_script="$SCRIPT_DIR/qemu_v2_ptc_live_sidecar_translate_smoke.sh"
  helper_generator="$SCRIPT_DIR/qemu_v2_generate_libtinycode_helpers.py"
  [[ -f "$live_script" ]] || die "live-sidecar builder not found: $live_script"
  [[ -f "$helper_generator" ]] || die "helper IR generator not found: $helper_generator"

  qemu_src_abs="$(resolve_existing_dir "$QEMU_SRC" "QEMU 10.2.3 source tree")"
  is_qemu_10_2_3_tree "$qemu_src_abs" || \
    die "expected QEMU 10.2.3 source with meson.build, executable configure, and VERSION=10.2.3: $qemu_src_abs"
  build_dir_abs="$(resolve_output_dir "$BUILD_DIR")"
  install_dir_abs="$(resolve_output_dir "$INSTALL_DIR")"
  qemu_version="$(tr -d '[:space:]' < "$qemu_src_abs/VERSION")"

  scratch_root="$build_dir_abs/libtinycode-live-sidecar"
  lib_so="$scratch_root/libtinycode-x86_64.so"
  sidecar_model="$scratch_root/sidecar/sidecar.model.json"
  sidecar_summary="$scratch_root/sidecar/sidecar.summary.json"
  helper_ir="$install_dir_abs/lib/libtinycode-helpers-x86_64.ll"
  metadata_json="$install_dir_abs/share/runnable/qemu-v2-libtinycode.json"

  live_args=(
    --scratch-root "$scratch_root"
    --qemu-src "$qemu_src_abs"
    --jobs "$JOBS"
    --fresh
  )
  if [[ -n "$REPLAY_PAYLOAD" ]]; then
    live_args+=(--payload-source "$(input_to_path "$REPLAY_PAYLOAD")")
  fi
  if [[ -n "$REPLAY_MODEL" ]]; then
    live_args+=(--model-source "$(input_to_path "$REPLAY_MODEL")")
  fi
  if [[ -n "$REPLAY_SUMMARY" ]]; then
    live_args+=(--summary-source "$(input_to_path "$REPLAY_SUMMARY")")
  fi

  echo "repo root       : $RR_DIR"
  echo "runtime image   : $IMAGE"
  echo "mode            : $MODE"
  echo "qemu src        : $qemu_src_abs"
  echo "build dir       : $build_dir_abs"
  echo "install dir     : $install_dir_abs"
  echo "scratch root    : $scratch_root"
  echo "parallel jobs   : $JOBS"

  bash "$live_script" "${live_args[@]}"
  [[ -f "$lib_so" ]] || die "live-sidecar libtinycode was not produced: $lib_so"
  [[ -f "$sidecar_model" ]] || die "live-sidecar model was not produced: $sidecar_model"
  [[ -f "$sidecar_summary" ]] || die "live-sidecar summary was not produced: $sidecar_summary"

  mkdir -p "$install_dir_abs/lib" "$install_dir_abs/include" "$install_dir_abs/share/runnable"
  cp "$lib_so" "$install_dir_abs/lib/libtinycode-x86_64.so"
  cp "$LEGACY_QEMU_DIR/linux-user/ptc.h" "$install_dir_abs/include/ptc.h"

  python3 "$helper_generator" \
    --model-json "$sidecar_model" \
    --output "$helper_ir" \
    --qemu-src "$qemu_src_abs" \
    --library-path "$install_dir_abs/lib/libtinycode-x86_64.so"

  python3 - "$metadata_json" "$qemu_src_abs" "$qemu_version" "$scratch_root" "$install_dir_abs/lib/libtinycode-x86_64.so" "$helper_ir" <<'PY'
import json
import sys
from pathlib import Path

metadata_path = Path(sys.argv[1])
data = {
    "schema": "qemu-v2-libtinycode-build-v1",
    "qemu_src": sys.argv[2],
    "qemu_version": sys.argv[3],
    "implementation_source": "qemu-v2-live-sidecar",
    "abi_version": "2",
    "real_translation": "true",
    "scratch_root": sys.argv[4],
    "library_path": sys.argv[5],
    "helpers_path": sys.argv[6],
}
metadata_path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

  if command -v nm >/dev/null 2>&1; then
    nm -D "$install_dir_abs/lib/libtinycode-x86_64.so" | grep -q ' ptc_load$' || die "installed library does not export ptc_load"
    nm -D "$install_dir_abs/lib/libtinycode-x86_64.so" | grep -q ' ptc_get_abi_metadata$' || die "installed library does not export ptc_get_abi_metadata"
  fi

  python3 - "$install_dir_abs/lib/libtinycode-x86_64.so" <<'PY'
import ctypes
import sys

lib = ctypes.CDLL(sys.argv[1])
lib.ptc_get_abi_metadata.restype = ctypes.c_char_p
metadata = lib.ptc_get_abi_metadata()
if metadata is None:
    raise SystemExit("ptc_get_abi_metadata returned NULL")
text = metadata.decode("utf-8", errors="replace")
required = ["abi_version=2", "real_translation=true"]
missing = [field for field in required if field not in text]
if missing:
    raise SystemExit(f"metadata missing {missing}: {text}")
print(text, end="" if text.endswith("\n") else "\n")
PY

  echo "LIBTINYCODE_V2_BUILD_OK=1"
  echo "LIBTINYCODE=$install_dir_abs/lib/libtinycode-x86_64.so"
  echo "LIBTINYCODE_HELPERS=$helper_ir"
  echo "LIBTINYCODE_METADATA=$metadata_json"
}
```

- [ ] **Step 3: Call the new function for libtinycode mode**

Replace:

```bash
if [[ "$MODE" == "libtinycode" ]]; then
  not_implemented_libtinycode
fi
```

with:

```bash
if [[ "$MODE" == "libtinycode" ]]; then
  if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [[ "$JOBS" -lt 1 ]]; then
    die "--jobs must be a positive integer: $JOBS"
  fi
  build_libtinycode_v2
  exit 0
fi
```

In the host-side Docker handoff, preserve the selected mode instead of hard-coding `--linux-user-only`. The command inside `docker run` should pass:

```bash
bash runnable/scripts/build_qemu_libtinycode_v2.sh \
  "--$MODE" \
  --qemu-src "$QEMU_SRC_CONTAINER" \
  --build-dir "$BUILD_DIR_CONTAINER" \
  --install-dir "$INSTALL_DIR_CONTAINER" \
  --jobs "$JOBS" \
  --no-docker
```

- [ ] **Step 4: Run the red tests again and make them pass**

Run:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
python3 -m pytest test/test_build_qemu_libtinycode_v2.py -q
```

Expected: both tests pass. The second test compiles a small live-sidecar shared object from replay fixtures, installs it, verifies metadata, and verifies no empty-stub marker is printed.

- [ ] **Step 5: Run shell syntax checks**

Run:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
bash -n runnable/scripts/build_qemu_libtinycode_v2.sh
python3 -m py_compile runnable/scripts/qemu_v2_generate_libtinycode_helpers.py
```

Expected: both commands exit 0.

- [ ] **Step 6: Commit wrapper implementation**

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
git add runnable/scripts/build_qemu_libtinycode_v2.sh runnable/scripts/qemu_v2_generate_libtinycode_helpers.py test/test_build_qemu_libtinycode_v2.py
git commit -m "feat: install qemu v2 live-sidecar libtinycode"
```

## Task 4: Real QEMU 10.2.3 Smoke Build

**Files:**
- Modify: none unless test evidence exposes a bug.
- Test: wrapper, installed artifact, metadata.

**Interfaces:**
- Consumes: `/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3` or another real QEMU 10.2.3 source tree.
- Produces: `/tmp/rr-qemu-v2-libtinycode-build/root/lib/libtinycode-x86_64.so` and helper IR.

- [ ] **Step 1: Run real-source build with bounded jobs**

Run:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
bash runnable/scripts/build_qemu_libtinycode_v2.sh \
  --libtinycode \
  --no-docker \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  --build-dir /tmp/rr-qemu-v2-libtinycode-build/build \
  --install-dir /tmp/rr-qemu-v2-libtinycode-build/root \
  --jobs 3
```

Expected: exits 0, prints `LIBTINYCODE_V2_BUILD_OK=1`, prints metadata containing `real_translation=true`, and installs `lib/libtinycode-x86_64.so`, `lib/libtinycode-helpers-x86_64.ll`, `include/ptc.h`, and `share/runnable/qemu-v2-libtinycode.json`.

- [ ] **Step 2: Inspect installed artifact exports**

Run:

```bash
nm -D /tmp/rr-qemu-v2-libtinycode-build/root/lib/libtinycode-x86_64.so | rg 'ptc_load|ptc_get_abi_metadata'
python3 - <<'PY'
import ctypes
lib = ctypes.CDLL('/tmp/rr-qemu-v2-libtinycode-build/root/lib/libtinycode-x86_64.so')
lib.ptc_get_abi_metadata.restype = ctypes.c_char_p
print(lib.ptc_get_abi_metadata().decode())
PY
```

Expected: both symbols are present; metadata contains `abi_version=2` and `real_translation=true`.

- [ ] **Step 3: Run the existing live-sidecar fast smoke against the installed artifact**

Run:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
RUNNABLE_QEMU_V2_PTC_LIVE_SIDECAR_LIBRARY=/tmp/rr-qemu-v2-libtinycode-build/root/lib/libtinycode-x86_64.so \
bash runnable/scripts/qemu_v2_ptc_live_sidecar_runnable_lift_fast_smoke.sh
```

Expected: does not report `source library metadata is not real_translation=true`. If this smoke cannot complete because local tiny test prerequisites are missing, capture the exact missing prerequisite and continue with the direct `dlopen`/metadata evidence from Step 2.

## Task 5: Documentation Update

**Files:**
- Modify: `runnable/scripts/host-build/BUILD-HOST-UBUNTU-24.04.md`

**Interfaces:**
- Consumes: implemented wrapper commands.
- Produces: host-build instructions for V2 libtinycode artifact generation and staging.

- [ ] **Step 1: Update host-build guide**

In `runnable/scripts/host-build/BUILD-HOST-UBUNTU-24.04.md`, replace the statement that `libtinycode-x86_64.so` is produced only by classic QEMU with a section that distinguishes current V2 and legacy paths:

```markdown
## QEMU V2 libtinycode artifacts

The preferred Ubuntu 24.04 path is:

```bash
bash runnable/scripts/build_qemu_libtinycode_v2.sh \
  --libtinycode \
  --qemu-src /path/to/qemu-10.2.3 \
  --build-dir /tmp/rr-qemu-v2-libtinycode-build/build \
  --install-dir /tmp/rr-qemu-v2-libtinycode-build/root
```

The command installs:

- `/tmp/rr-qemu-v2-libtinycode-build/root/lib/libtinycode-x86_64.so`
- `/tmp/rr-qemu-v2-libtinycode-build/root/lib/libtinycode-helpers-x86_64.ll`
- `/tmp/rr-qemu-v2-libtinycode-build/root/include/ptc.h`

The legacy QEMU 2.4.50 `x86_64-libtinycode` build remains available only for archaeology and must not be treated as the successful V2 migration path.
```

- [ ] **Step 2: Run doc grep checks**

Run:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
rg -n "classic QEMU build|QEMU V2 libtinycode|build_qemu_libtinycode_v2.sh" runnable/scripts/host-build/BUILD-HOST-UBUNTU-24.04.md
```

Expected: the guide documents the V2 preferred path and labels classic QEMU as legacy/archaeology only.

- [ ] **Step 3: Commit docs**

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
git add runnable/scripts/host-build/BUILD-HOST-UBUNTU-24.04.md
git commit -m "docs: document qemu v2 libtinycode build"
```

## Task 6: Final Verification

**Files:**
- No planned edits.
- Test: all touched-unit tests plus build wrapper smoke.

**Interfaces:**
- Consumes: Tasks 1-5.
- Produces: verification evidence for final report.

- [ ] **Step 1: Run focused Python tests**

Run:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
python3 -m pytest \
  test/test_build_qemu_libtinycode_v2.py \
  test/test_qemu_v2_live_sidecar_walker_reuse.py \
  test/test_qemu_v2_ptc_vector_lowering.py \
  test/test_spec2006_qemu_v2_parallel_functional.py \
  -q
```

Expected: all selected tests pass.

- [ ] **Step 2: Run shell/script validation**

Run:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
bash -n runnable/scripts/build_qemu_libtinycode_v2.sh
bash -n runnable/scripts/qemu_v2_ptc_live_sidecar_translate_smoke.sh
python3 -m py_compile runnable/scripts/qemu_v2_generate_libtinycode_helpers.py
```

Expected: all commands exit 0.

- [ ] **Step 3: Confirm no unrelated files were staged**

Run:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
git status --short --untracked-files=all
```

Expected: commits contain only files from this plan; pre-existing untracked runtime artifacts may remain but must not be staged.
