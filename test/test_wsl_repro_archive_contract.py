import tarfile
import unittest
import hashlib
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = REPO_ROOT / "archive" / "runnable-libcrypto-wsl-repro-2026-07-14.tar.gz"
PREFIX = "runnable-libcrypto-wsl-repro-2026-07-14"
EXPECTED_LIBTINYCODE_SHA256 = "35c658bb35b838c40da4e0c6e94794d7a0ff3f9034affce755c3f17525f441ec"
EXPECTED_HELPERS_SHA256 = "5977b32dd6710d0459aa9b4fd4290350f69c9333e2aaa53005fcbb554ab27fb2"
EXPECTED_PREBUILT_RUNNABLE_LIFT_SHA256 = (
    "1addc607d7f9d6a06ba61cff01581101973e63b1b5bdc7e166f88e6e244dd839"
)


class WslReproArchiveContractTests(unittest.TestCase):
    def test_archive_contains_no_docker_full_entrypoints(self):
        with tarfile.open(ARCHIVE, "r:gz") as archive:
            names = set(archive.getnames())
            self.assertIn(f"{PREFIX}/build-libtinycode-qemuv2.sh", names)
            self.assertIn(f"{PREFIX}/run-libcrypto-full-qemuv2.sh", names)

            top_script = archive.extractfile(f"{PREFIX}/run-libcrypto-ubuntu2404.sh")
            self.assertIsNotNone(top_script)
            text = top_script.read().decode("utf-8")
            readme = archive.extractfile(f"{PREFIX}/README-WSL.md")
            self.assertIsNotNone(readme)
            readme_text = readme.read().decode("utf-8")
            orchestrator = archive.extractfile(
                f"{PREFIX}/Runnable-Rewriting/runnable/scripts/libcrypto_dynamic_parallel_lift.py"
            )
            self.assertIsNotNone(orchestrator)
            orchestrator_text = orchestrator.read().decode("utf-8")
            shard_runner = archive.extractfile(
                f"{PREFIX}/Runnable-Rewriting/runnable/scripts/libcrypto_parallel_shard_runner.py"
            )
            self.assertIsNotNone(shard_runner)
            shard_runner_text = shard_runner.read().decode("utf-8")
            main_cpp = archive.extractfile(
                f"{PREFIX}/Runnable-Rewriting/runnable/tools/runnable-lift/Main.cpp"
            )
            self.assertIsNotNone(main_cpp)
            main_cpp_text = main_cpp.read().decode("utf-8")
            libtinycode = archive.extractfile(
                f"{PREFIX}/Runnable-Rewriting/runnable/tools/runnable-lift/libtinycode-x86_64.so"
            )
            self.assertIsNotNone(libtinycode)
            libtinycode_sha256 = hashlib.sha256(libtinycode.read()).hexdigest()
            helpers = archive.extractfile(
                f"{PREFIX}/Runnable-Rewriting/runnable/tools/runnable-lift/libtinycode-helpers-x86_64.ll"
            )
            self.assertIsNotNone(helpers)
            helpers_sha256 = hashlib.sha256(helpers.read()).hexdigest()
            prebuilt_lift = archive.extractfile(
                f"{PREFIX}/prebuilt/shared-install-runnable/bin/runnable-lift"
            )
            self.assertIsNotNone(prebuilt_lift)
            prebuilt_lift_sha256 = hashlib.sha256(prebuilt_lift.read()).hexdigest()

        self.assertIn("RUNNABLE_LIBCRYPTO_NO_DOCKER", text)
        self.assertIn("run-libcrypto-full-qemuv2.sh", text)
        self.assertNotIn("error: docker is required on the host", text)
        self.assertIn("Docker is optional", readme_text)
        self.assertNotIn("Docker available from WSL", readme_text)
        self.assertIn('"host-shards"', orchestrator_text)
        self.assertIn("--range-mode", orchestrator_text)
        self.assertIn("--range-mode", shard_runner_text)
        self.assertIn(
            f"{PREFIX}/Runnable-Rewriting/runnable/tools/runnable-lift/ParallelOptions.h",
            names,
        )
        self.assertIn(
            f"{PREFIX}/Runnable-Rewriting/runnable/scripts/merge_dynamic_runnable_fragments.py",
            names,
        )
        self.assertIn(
            f"{PREFIX}/Runnable-Rewriting/runnable/scripts/_merge_dynamic_fragments_lib.py",
            names,
        )
        self.assertIn('DynamicParallel("dynamic-parallel"', main_cpp_text)
        self.assertIn("ParallelOptions", main_cpp_text)
        self.assertIn(
            f"{PREFIX}/prebuilt/shared-install-runnable/bin/runnable-lift",
            names,
        )
        self.assertIn(
            f"{PREFIX}/prebuilt/shared-install-runnable/bin/libtinycode-x86_64.so",
            names,
        )
        self.assertEqual(EXPECTED_LIBTINYCODE_SHA256, libtinycode_sha256)
        self.assertEqual(EXPECTED_HELPERS_SHA256, helpers_sha256)
        self.assertEqual(EXPECTED_PREBUILT_RUNNABLE_LIFT_SHA256, prebuilt_lift_sha256)


if __name__ == "__main__":
    unittest.main()
