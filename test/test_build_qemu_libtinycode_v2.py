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


def make_fake_docker(root: Path) -> tuple[Path, Path]:
    docker = root / "docker"
    marker = root / "docker-invoked.marker"
    docker.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        f"printf '%s\\n' \"$*\" > '{marker}'\n"
        "exit 0\n",
        encoding="utf-8",
    )
    docker.chmod(docker.stat().st_mode | stat.S_IXUSR)
    return docker, marker


def make_fake_live_sidecar_override(root: Path, metadata_text: str) -> Path:
    script = root / "fake-live-sidecar.sh"
    script.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "scratch_root=''\n"
        "while [[ $# -gt 0 ]]; do\n"
        "  case \"$1\" in\n"
        "    --scratch-root)\n"
        "      scratch_root=\"$2\"\n"
        "      shift 2\n"
        "      ;;\n"
        "    *)\n"
        "      shift\n"
        "      ;;\n"
        "  esac\n"
        "done\n"
        "[[ -n \"$scratch_root\" ]]\n"
        "mkdir -p \"$scratch_root/sidecar\"\n"
        "cat > \"$scratch_root/libtinycode.c\" <<'EOF_C'\n"
        "#include <stddef.h>\n"
        "int ptc_load(void) { return 0; }\n"
        f"const char *ptc_get_abi_metadata(void) {{ return \"{metadata_text}\"; }}\n"
        "EOF_C\n"
        "cc -shared -fPIC \"$scratch_root/libtinycode.c\" -o \"$scratch_root/libtinycode-x86_64.so\"\n"
        "cat > \"$scratch_root/sidecar/sidecar.model.json\" <<'EOF_MODEL'\n"
        "{\"schema\":\"qemu-v2-ptc-live-sidecar-model-v1\",\"helper_defs\":[],\"instructions\":[],\"temps\":[]}\n"
        "EOF_MODEL\n"
        "cat > \"$scratch_root/sidecar/sidecar.summary.json\" <<'EOF_SUMMARY'\n"
        "{\"payload_instruction_count\":1,\"selected_instruction_count\":1,\"source_instruction_count\":1,\"rejected_instruction_count\":0}\n"
        "EOF_SUMMARY\n",
        encoding="utf-8",
    )
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    return script


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

    def test_libtinycode_host_docker_mode_rejects_wrong_qemu_version_before_docker(self) -> None:
        with tempfile.TemporaryDirectory(dir=REPO_ROOT) as qemu_tmp, tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmp:
            qemu = make_fake_qemu_source(Path(qemu_tmp), "10.2.2")
            root = Path(tmp)
            docker_dir = root / "bin"
            docker_dir.mkdir()
            _, docker_marker = make_fake_docker(docker_dir)
            build_dir = root / "build"
            install_dir = root / "install"

            result = self.run_script(
                "--libtinycode",
                "--qemu-src",
                str(qemu),
                "--build-dir",
                str(build_dir),
                "--install-dir",
                str(install_dir),
                "--skip-image-build",
                env={
                    "PATH": f"{docker_dir}:{os.environ['PATH']}",
                    "RUNNABLE_QEMU_V2_IN_CONTAINER": "0",
                },
            )

        self.assertNotEqual(result.returncode, 0)
        combined = result.stdout + result.stderr
        self.assertIn("VERSION=10.2.3", combined)
        self.assertIn("10.2.2", combined)
        self.assertFalse(docker_marker.exists(), "docker should not be invoked for wrong QEMU source")

    def test_libtinycode_host_docker_mode_rejects_missing_replay_payload_before_image_build(self) -> None:
        with tempfile.TemporaryDirectory() as qemu_tmp, tempfile.TemporaryDirectory(dir=REPO_ROOT) as repo_tmp, tempfile.TemporaryDirectory() as external_tmp:
            qemu = make_fake_qemu_10_2_3(Path(qemu_tmp))
            repo_root = Path(repo_tmp)
            docker_dir = repo_root / "bin"
            docker_dir.mkdir()
            _, docker_marker = make_fake_docker(docker_dir)
            missing_payload = Path(external_tmp) / "missing.payload.txt"

            result = self.run_script(
                "--libtinycode",
                "--qemu-src",
                str(qemu),
                "--build-dir",
                str(repo_root / "build"),
                "--install-dir",
                str(repo_root / "install"),
                "--replay-payload",
                str(missing_payload),
                env={
                    "PATH": f"{docker_dir}:{os.environ['PATH']}",
                    "RUNNABLE_QEMU_V2_IN_CONTAINER": "0",
                },
            )

        self.assertNotEqual(result.returncode, 0)
        combined = result.stdout + result.stderr
        self.assertIn("replay payload", combined)
        self.assertIn("not found", combined)
        self.assertFalse(docker_marker.exists(), "docker should not be invoked before replay path validation")

    def test_libtinycode_host_docker_mode_accepts_external_qemu_and_replay_mounts(self) -> None:
        with tempfile.TemporaryDirectory() as external_tmp, tempfile.TemporaryDirectory(dir=REPO_ROOT) as repo_tmp:
            external_root = Path(external_tmp)
            qemu = make_fake_qemu_10_2_3(external_root)
            payload, model, summary = write_replay_fixture(external_root)
            build_dir = external_root / "build"
            install_dir = external_root / "install"
            repo_root = Path(repo_tmp)
            docker_dir = repo_root / "bin"
            docker_dir.mkdir()
            _, docker_marker = make_fake_docker(docker_dir)

            result = self.run_script(
                "--libtinycode",
                "--qemu-src",
                str(qemu),
                "--build-dir",
                str(build_dir),
                "--install-dir",
                str(install_dir),
                "--replay-payload",
                str(payload),
                "--replay-model",
                str(model),
                "--replay-summary",
                str(summary),
                "--skip-image-build",
                env={
                    "PATH": f"{docker_dir}:{os.environ['PATH']}",
                    "RUNNABLE_QEMU_V2_IN_CONTAINER": "0",
                },
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            docker_argv = docker_marker.read_text(encoding="utf-8")

        self.assertIn("run --rm", docker_argv)
        self.assertIn("--libtinycode", docker_argv)
        self.assertIn("--no-docker", docker_argv)
        self.assertIn(f"-v {qemu}:/tmp/runnable-qemu-v2/qemu-src:ro", docker_argv)
        self.assertIn("--qemu-src /tmp/runnable-qemu-v2/qemu-src", docker_argv)
        self.assertIn(f"-v {build_dir}:/tmp/runnable-qemu-v2/build-dir", docker_argv)
        self.assertIn("--build-dir /tmp/runnable-qemu-v2/build-dir", docker_argv)
        self.assertIn(f"-v {install_dir}:/tmp/runnable-qemu-v2/install-dir", docker_argv)
        self.assertIn("--install-dir /tmp/runnable-qemu-v2/install-dir", docker_argv)
        self.assertIn(f"-v {payload.parent}:/tmp/runnable-qemu-v2/replay-payload:ro", docker_argv)
        self.assertIn(f"--replay-payload /tmp/runnable-qemu-v2/replay-payload/{payload.name}", docker_argv)
        self.assertIn(f"-v {model.parent}:/tmp/runnable-qemu-v2/replay-model:ro", docker_argv)
        self.assertIn(f"--replay-model /tmp/runnable-qemu-v2/replay-model/{model.name}", docker_argv)
        self.assertIn(f"-v {summary.parent}:/tmp/runnable-qemu-v2/replay-summary:ro", docker_argv)
        self.assertIn(f"--replay-summary /tmp/runnable-qemu-v2/replay-summary/{summary.name}", docker_argv)

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

    def test_libtinycode_mode_rejects_forbidden_empty_stub_metadata_marker(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            qemu = make_fake_qemu_10_2_3(root)
            fake_live_sidecar = make_fake_live_sidecar_override(
                root,
                "abi_version=2\\nreal_translation=true\\nREAL_PTC_TRANSLATION=not-migrated-empty-stub\\n",
            )
            result = self.run_script(
                "--libtinycode",
                "--no-docker",
                "--qemu-src",
                str(qemu),
                "--build-dir",
                str(root / "build"),
                "--install-dir",
                str(root / "install"),
                env={"RUNNABLE_QEMU_V2_LIVE_SIDECAR_SCRIPT_OVERRIDE": str(fake_live_sidecar)},
            )

        self.assertNotEqual(result.returncode, 0)
        combined = result.stdout + result.stderr
        self.assertIn("REAL_PTC_TRANSLATION=not-migrated-empty-stub", combined)
        self.assertNotIn("LIBTINYCODE_V2_BUILD_OK=1", combined)

    def test_libtinycode_mode_rejects_metadata_that_only_matches_abi_substring(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            qemu = make_fake_qemu_10_2_3(root)
            fake_live_sidecar = make_fake_live_sidecar_override(
                root,
                "abi_version=20\\nreal_translation=true\\n",
            )
            result = self.run_script(
                "--libtinycode",
                "--no-docker",
                "--qemu-src",
                str(qemu),
                "--build-dir",
                str(root / "build"),
                "--install-dir",
                str(root / "install"),
                env={"RUNNABLE_QEMU_V2_LIVE_SIDECAR_SCRIPT_OVERRIDE": str(fake_live_sidecar)},
            )

        self.assertNotEqual(result.returncode, 0)
        combined = result.stdout + result.stderr
        self.assertIn("abi_version", combined)
        self.assertNotIn("LIBTINYCODE_V2_BUILD_OK=1", combined)

    def test_libtinycode_mode_rejects_metadata_that_only_matches_real_translation_substring(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            qemu = make_fake_qemu_10_2_3(root)
            fake_live_sidecar = make_fake_live_sidecar_override(
                root,
                "abi_version=2\\nnot_real_translation=true\\n",
            )
            result = self.run_script(
                "--libtinycode",
                "--no-docker",
                "--qemu-src",
                str(qemu),
                "--build-dir",
                str(root / "build"),
                "--install-dir",
                str(root / "install"),
                env={"RUNNABLE_QEMU_V2_LIVE_SIDECAR_SCRIPT_OVERRIDE": str(fake_live_sidecar)},
            )

        self.assertNotEqual(result.returncode, 0)
        combined = result.stdout + result.stderr
        self.assertIn("real_translation", combined)
        self.assertNotIn("LIBTINYCODE_V2_BUILD_OK=1", combined)

    def test_libtinycode_mode_rejects_duplicate_metadata_keys(self) -> None:
        metadata_cases = (
            "abi_version=2\\nabi_version=2\\nreal_translation=true\\n",
            "abi_version=2\\nreal_translation=false\\nreal_translation=true\\n",
        )

        for metadata_text in metadata_cases:
            with self.subTest(metadata_text=metadata_text), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                qemu = make_fake_qemu_10_2_3(root)
                fake_live_sidecar = make_fake_live_sidecar_override(root, metadata_text)
                result = self.run_script(
                    "--libtinycode",
                    "--no-docker",
                    "--qemu-src",
                    str(qemu),
                    "--build-dir",
                    str(root / "build"),
                    "--install-dir",
                    str(root / "install"),
                    env={"RUNNABLE_QEMU_V2_LIVE_SIDECAR_SCRIPT_OVERRIDE": str(fake_live_sidecar)},
                )

                self.assertNotEqual(result.returncode, 0)
                combined = result.stdout + result.stderr
                self.assertIn("duplicate", combined)
                self.assertNotIn("LIBTINYCODE_V2_BUILD_OK=1", combined)

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
