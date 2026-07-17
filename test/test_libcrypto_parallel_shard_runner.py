import argparse
import importlib.util
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "runnable" / "scripts" / "libcrypto_parallel_shard_runner.py"


def load_module():
    spec = importlib.util.spec_from_file_location("libcrypto_parallel_shard_runner", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class LibcryptoParallelShardRunnerTests(unittest.TestCase):
    def test_run_seed_merges_worker_fragments_into_seed_output(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            args = argparse.Namespace(
                binary=root / "libcrypto.so.3",
                raw_dir=root / "raw",
                fragment_root=root / "fragments",
                merged_dir=root / "merged",
                logs_dir=root / "logs",
                runnable_base=0x50000000,
                parallel_workers=1,
                timeout_sec=30,
                range_mode="seed",
                coordinator_flag=[],
                preserve_success_seed_logs=True,
            )
            args.binary.write_text("binary", encoding="utf-8")
            seed = {
                "start_hex": "0x1d7e20",
                "end_exclusive_hex": "0x1d7edc",
                "name": "evp_get_digestbyname_ex",
                "size": 188,
            }
            calls = []

            def fake_run_cmd(cmd, *, check=True, capture_output=True):
                calls.append(list(cmd))
                if cmd[:2] == ["bash", "-lc"]:
                    raw_ll = args.raw_dir / "fn_00000000001d7e20.raw.ll"
                    raw_ll.parent.mkdir(parents=True, exist_ok=True)
                    raw_ll.write_text("@disam_0x501d7e20 = global i8 0\n", encoding="utf-8")
                    fragment_dir = args.fragment_root / "fn_00000000001d7e20"
                    fragment_dir.mkdir(parents=True, exist_ok=True)
                    (fragment_dir / "worker_501d7e3a.ll").write_text(
                        "@disam_0x501d7e3a = global i8 0\n",
                        encoding="utf-8",
                    )
                    return argparse.Namespace(returncode=0)
                if cmd and cmd[0] == "python3" and "merge_dynamic_runnable_fragments.py" in cmd[1]:
                    output = Path(cmd[cmd.index("--output") + 1])
                    summary = Path(cmd[cmd.index("--summary-out") + 1])
                    output.parent.mkdir(parents=True, exist_ok=True)
                    output.write_text("merged raw+worker\n", encoding="utf-8")
                    summary.parent.mkdir(parents=True, exist_ok=True)
                    summary.write_text('{"merged_full_status":"built"}\n', encoding="utf-8")
                    return argparse.Namespace(returncode=0)
                raise AssertionError(f"unexpected command: {cmd}")

            original_run_cmd = module.run_cmd
            module.run_cmd = fake_run_cmd
            try:
                result = module.run_seed(
                    args=args,
                    shard_id="shard_00001",
                    shard_start=0x1d7e20,
                    shard_end_exclusive=0x1d7edc,
                    seed=seed,
                )
            finally:
                module.run_cmd = original_run_cmd

            self.assertEqual("ok", result["status"])
            self.assertEqual(1, result["workers_spawned"])
            self.assertTrue(Path(result["merged_ll"]).exists())
            self.assertTrue(Path(result["merge_summary"]).exists())
            merge_calls = [
                call for call in calls
                if call and call[0] == "python3" and "merge_dynamic_runnable_fragments.py" in call[1]
            ]
            self.assertEqual(1, len(merge_calls))
            self.assertIn(str(args.fragment_root / "fn_00000000001d7e20" / "worker_501d7e3a.ll"), merge_calls[0])


if __name__ == "__main__":
    unittest.main()
