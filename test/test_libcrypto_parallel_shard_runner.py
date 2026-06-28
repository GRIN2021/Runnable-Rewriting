import importlib.util
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest import mock


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1]
    / "runnable"
    / "scripts"
    / "libcrypto_parallel_shard_runner.py"
)


def load_module():
    spec = importlib.util.spec_from_file_location(
        "libcrypto_parallel_shard_runner", SCRIPT_PATH
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class LibcryptoParallelShardRunnerTests(unittest.TestCase):
    def run_seed_shell(self, coordinator_flags):
        module = load_module()
        shell_scripts = []

        def fake_run_cmd(cmd, **kwargs):
            if list(cmd)[:2] == ["bash", "-lc"]:
                shell_scripts.append(cmd[2])
            return Namespace(returncode=1)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args = Namespace(
                raw_dir=root / "raw",
                merged_dir=root / "merged",
                logs_dir=root / "logs",
                fragment_root=root / "fragments",
                runnable_base=0x50000000,
                parallel_workers=2,
                timeout_sec=1800,
                preserve_success_seed_logs=False,
                coordinator_flag=list(coordinator_flags),
                binary=root / "libcrypto.so.3",
            )
            seed = {
                "start_hex": "0x100",
                "end_exclusive_hex": "0x180",
                "name": "demo",
                "size": 0x80,
            }
            with mock.patch.object(module, "run_cmd", side_effect=fake_run_cmd):
                module.run_seed(args=args, shard_id="shard_00000", seed=seed)

        self.assertEqual(len(shell_scripts), 1)
        return shell_scripts[0]

    def test_run_seed_adds_seed_range_when_no_range_forwarded(self):
        shell_script = self.run_seed_shell(["-use-debug-symbols", "-no-link"])

        self.assertIn("-addr-range-min=0x50000100", shell_script)
        self.assertIn("-addr-range-max=0x50000180", shell_script)

    def test_run_seed_keeps_forwarded_full_text_range(self):
        shell_script = self.run_seed_shell(
            [
                "-use-debug-symbols",
                "-no-link",
                "-addr-range-min=0x500cef80",
                "-addr-range-max=0x503b1fee",
            ]
        )

        self.assertNotIn("-addr-range-min=0x50000100", shell_script)
        self.assertNotIn("-addr-range-max=0x50000180", shell_script)
        self.assertIn("-addr-range-min=0x500cef80", shell_script)
        self.assertIn("-addr-range-max=0x503b1fee", shell_script)


if __name__ == "__main__":
    unittest.main()
