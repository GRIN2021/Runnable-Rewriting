import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "runnable" / "scripts" / "libcrypto_dynamic_parallel_lift.py"
RUNNER_PATH = REPO_ROOT / "runnable" / "scripts" / "libcrypto_parallel_shard_runner.py"


class LibcryptoDynamicParallelScriptContractTest(unittest.TestCase):
    def test_script_exists_and_targets_hdd_and_rr_image(self) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), f"missing script: {SCRIPT_PATH}")
        content = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertIn("/hdd/runnable-libcrypto-dynamic-parallel", content)
        self.assertIn("rr_bionic_exportfs:2026-04-14", content)
        self.assertIn("bin2415/x86_gt:0.1", content)
        self.assertIn("bin2415/py_gt", content)

    def test_script_uses_dynamic_parallel_and_canonical_cmp(self) -> None:
        content = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertIn("-dynamic-parallel", content)
        self.assertIn("-parallel-workers=", content)
        self.assertIn("-parallel-fragment-dir=", content)
        self.assertIn("-addr-range-min=", content)
        self.assertIn("-addr-range-max=", content)
        self.assertIn("merge_dynamic_runnable_fragments.py", content)
        self.assertIn("validate_libcrypto_ground_truth.py", content)
        self.assertIn("build_libcrypto_groundtruth.sh", content)
        self.assertIn("copying canonical Docker-built ground truth bundle into /hdd", content)
        self.assertIn("libcrypto.so.3", content)
        self.assertIn("libcrypto.gtBlock.pb", content)

    def test_script_uses_single_container_shard_execution(self) -> None:
        content = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertTrue(RUNNER_PATH.is_file(), f"missing runner: {RUNNER_PATH}")
        self.assertIn("single-container-shards", content)
        self.assertIn("docker_exec_shell", content)
        self.assertIn("start_long_lived_container", content)
        self.assertIn("libcrypto_parallel_shard_runner.py", content)
        self.assertIn("status.flag", content)
        self.assertIn("merge-state", content)
        self.assertIn("merge-progress", content)


if __name__ == "__main__":
    unittest.main()
