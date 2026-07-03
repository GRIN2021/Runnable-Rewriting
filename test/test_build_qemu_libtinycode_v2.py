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
