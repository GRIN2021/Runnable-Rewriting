import ctypes
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

from runnable.scripts.qemu_v2_generate_libtinycode_helpers import load_helper_names, render_helpers


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "runnable" / "scripts" / "build_qemu_libtinycode_v2.sh"
LEGACY_QEMU_ROOT = REPO_ROOT / "archive" / "qemu-legacy-2.4.50"


def make_fake_qemu_source(root: Path, version: str) -> Path:
    qemu = root / f"qemu-{version}"
    qemu.mkdir()
    (qemu / "meson.build").write_text("project('qemu', 'c')\n", encoding="utf-8")
    configure = qemu / "configure"
    configure.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    configure.chmod(configure.stat().st_mode | stat.S_IXUSR)
    (qemu / "VERSION").write_text(f"{version}\n", encoding="utf-8")
    return qemu


def make_fake_qemu_10_2_3(root: Path) -> Path:
    return make_fake_qemu_source(root, "10.2.3")


def make_legacy_poison_qemu_src(root: Path) -> tuple[Path, Path]:
    poison_root = root / "legacy-poison"
    (poison_root / "linux-user").mkdir(parents=True)
    (poison_root / "tcg").mkdir(parents=True)
    shutil.copy2(LEGACY_QEMU_ROOT / "linux-user" / "ptc.h", poison_root / "linux-user" / "ptc.h")
    shutil.copy2(LEGACY_QEMU_ROOT / "tcg" / "tcg-opc.h", poison_root / "tcg" / "tcg-opc.h")

    configure = poison_root / "configure"
    marker = poison_root / "configure-invoked.marker"
    configure.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        f"printf 'legacy configure invoked\\n' > '{marker}'\n"
        "exit 99\n",
        encoding="utf-8",
    )
    configure.chmod(configure.stat().st_mode | stat.S_IXUSR)
    (poison_root / "meson.build").write_text("project('qemu', 'c')\n", encoding="utf-8")
    (poison_root / "VERSION").write_text("10.2.3\n", encoding="utf-8")
    return poison_root, marker


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

    def test_libtinycode_mode_rejects_wrong_qemu_version_tree(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            qemu = make_fake_qemu_source(root, "10.2.2")
            result = self.run_script(
                "--libtinycode",
                "--no-docker",
                "--qemu-src",
                str(qemu),
                "--build-dir",
                str(root / "build"),
                "--install-dir",
                str(root / "install"),
            )

        self.assertNotEqual(result.returncode, 0)
        combined = result.stdout + result.stderr
        self.assertIn("QEMU 10.2.3 source tree", combined)
        self.assertIn("10.2.2", combined)
        self.assertNotIn("not implemented yet", combined)

    def test_libtinycode_mode_installs_live_sidecar_artifacts_from_replay_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            qemu = make_fake_qemu_10_2_3(root)
            payload, model, summary = write_replay_fixture(root)
            legacy_src, legacy_marker = make_legacy_poison_qemu_src(root)
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
                env={"RUNNABLE_QEMU_LEGACY_SRC": str(legacy_src)},
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            combined = result.stdout + result.stderr
            self.assertIn("LIBTINYCODE_V2_BUILD_OK=1", combined)
            self.assertIn("real_translation=true", combined)
            self.assertNotIn("REAL_PTC_TRANSLATION=not-migrated-empty-stub", combined)
            self.assertFalse(legacy_marker.exists(), "legacy configure path was invoked")

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

            lib = ctypes.CDLL(str(libtinycode))
            lib.ptc_get_abi_metadata.restype = ctypes.c_char_p
            raw_metadata = lib.ptc_get_abi_metadata()
            self.assertIsNotNone(raw_metadata)
            metadata_text = raw_metadata.decode("utf-8")
            self.assertIn("abi_version=2", metadata_text)
            self.assertIn("real_translation=true", metadata_text)

    def test_helper_generator_emits_sentinel_when_helper_defs_missing_or_empty(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            missing_model = root / "missing.model.json"
            empty_model = root / "empty.model.json"
            missing_model.write_text(json.dumps({"schema": "qemu-v2"}), encoding="utf-8")
            empty_model.write_text(json.dumps({"schema": "qemu-v2", "helper_defs": []}), encoding="utf-8")

            for model_path in (missing_model, empty_model):
                helper_names = load_helper_names(model_path)
                self.assertEqual(helper_names, [])

                rendered = render_helpers(
                    helper_names,
                    qemu_src=Path("/tmp/qemu-10.2.3"),
                    library_path=Path("/tmp/libtinycode-x86_64.so"),
                )
                self.assertIn("; ModuleID = 'qemu-v2-libtinycode-helpers'", rendered)
                self.assertIn("; provenance = generated-by-qemu_v2_generate_libtinycode_helpers.py", rendered)
                self.assertIn("define void @__qemu_v2_libtinycode_no_helpers_required()", rendered)
                self.assertIn("; No helper definitions were required by the captured scalar payload.", rendered)

    def test_helper_generator_strips_prefix_deduplicates_and_sanitizes_symbols(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            model_path = Path(tmp) / "helpers.model.json"
            model_path.write_text(
                json.dumps(
                    {
                        "helper_defs": [
                            {"name": "helper_alpha"},
                            {"name": "helper_alpha"},
                            {"name": "helper_beta.gamma"},
                            {"name": "helper_beta-gamma"},
                            {"name": "literal_helper_name"},
                        ]
                    }
                ),
                encoding="utf-8",
            )

            helper_names = load_helper_names(model_path)
            self.assertEqual(helper_names, ["alpha", "beta.gamma", "beta-gamma", "literal_helper_name"])

            rendered = render_helpers(
                helper_names,
                qemu_src=Path("/tmp/qemu-10.2.3"),
                library_path=Path("/tmp/libtinycode-x86_64.so"),
            )

            self.assertIn("; helper = alpha", rendered)
            self.assertEqual(rendered.count("declare void @alpha()"), 1)
            self.assertIn("; helper = beta.gamma", rendered)
            self.assertIn("declare void @beta_gamma()", rendered)
            self.assertIn("; helper = beta-gamma", rendered)
            self.assertIn("declare void @beta_gamma_2()", rendered)
            self.assertIn("; helper = literal_helper_name", rendered)
            self.assertIn("declare void @literal_helper_name()", rendered)
