import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1] / "runnable" / "scripts" / "validate_libcrypto_ground_truth.py"
)


def load_module():
    spec = importlib.util.spec_from_file_location(
        "validate_libcrypto_ground_truth", SCRIPT_PATH
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ValidateLibcryptoGroundTruthCanonicalTests(unittest.TestCase):
    def test_resolve_default_groundtruth_prefers_libcrypto_gtblock_name(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            binary = root / "libcrypto.so.3"
            binary.write_bytes(b"\x7fELF")
            expected = root / "libcrypto.gtBlock.pb"
            expected.write_bytes(b"pb")

            resolved = module.resolve_default_groundtruth_path(binary)

            self.assertEqual(resolved, expected)

    def test_assess_cmp_payload_fails_low_metrics(self):
        module = load_module()
        payload = {
            "binary": "/tmp/libcrypto.so.3",
            "ll": "/tmp/libcrypto.so.3.ll",
            "text_start": 0xCEF80,
            "runnable_base": 0x50000000,
            "obj_count": 679479,
            "ll_count": 847589,
            "hit": 24175,
            "mismatch": 112625,
            "obj_only": 542679,
            "ll_only": 710789,
            "false_negative": 655304,
            "false_positive": 823414,
            "precision": 0.028522,
            "recall": 0.035579,
        }

        verdict = module.assess_cmp_payload(
            payload,
            min_precision=0.80,
            min_recall=0.80,
        )

        self.assertFalse(verdict.ok)
        self.assertTrue(
            any("precision" in reason for reason in verdict.reasons),
            verdict.reasons,
        )
        self.assertTrue(
            any("recall" in reason for reason in verdict.reasons),
            verdict.reasons,
        )

    def test_assess_cmp_payload_accepts_strong_metrics(self):
        module = load_module()
        payload = {
            "binary": "/tmp/libcrypto.so.3",
            "ll": "/tmp/libcrypto.so.3.ll",
            "text_start": 0xCF000,
            "runnable_base": 0x50000000,
            "obj_count": 932819,
            "ll_count": 847589,
            "hit": 787556,
            "mismatch": 1420,
            "obj_only": 143843,
            "ll_only": 58613,
            "false_negative": 145263,
            "false_positive": 60033,
            "precision": 0.929172,
            "recall": 0.844275,
        }

        verdict = module.assess_cmp_payload(
            payload,
            min_precision=0.80,
            min_recall=0.80,
        )

        self.assertTrue(verdict.ok)
        self.assertEqual(verdict.reasons, [])

    def test_legacy_mode_still_works_without_subcommand(self):
        module = load_module()
        self.assertIsNone(module.maybe_run_legacy_compat(["cmp"]))

    def test_run_cmp_forwards_include_pc_file(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            binary = root / "libcrypto.so.3"
            ll_path = root / "sample.ll"
            cmp_tool = root / "run_cmp_eval.py"
            include_pc_file = root / "include-pcs.txt"
            out_dir = root / "out"

            binary.write_bytes(b"\x7fELF")
            ll_path.write_text("; 0x50001000: ret\n", encoding="utf-8")
            cmp_tool.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
            include_pc_file.write_text("0x1000\n", encoding="utf-8")

            seen_cmd = {}

            def fake_run_cmd(cmd, *, check=True):
                seen_cmd["cmd"] = list(cmd)
                out_dir.mkdir(parents=True, exist_ok=True)
                (out_dir / "cmp.json").write_text(
                    '{"binary":"x","ll":"y","text_start":4096,"runnable_base":1342177280,'
                    '"obj_count":1,"ll_count":1,"hit":1,"mismatch":0,"obj_only":0,"ll_only":0,'
                    '"false_negative":0,"false_positive":0,"precision":1.0,"recall":1.0}\n',
                    encoding="utf-8",
                )
                return mock.Mock(returncode=0, stdout="", stderr="")

            with mock.patch.object(module, "run_cmd", side_effect=fake_run_cmd):
                payload, verdict, *_ = module.run_cmp(
                    binary=binary,
                    ll_path=ll_path,
                    out_dir=out_dir,
                    run_cmp_eval=cmp_tool,
                    text_start=0x1000,
                    runnable_base=0x50000000,
                    include_pc_file=include_pc_file,
                    min_precision=0.8,
                    min_recall=0.8,
                    examples=10,
                    static_fallback_profiles=["simd-heavy", "all-functions", "all-text"],
                    static_fallback_symbol_regexes=["avx512"],
                )

            self.assertEqual(payload["precision"], 1.0)
            self.assertTrue(verdict.ok)
            self.assertIn("--include-pc-file", seen_cmd["cmd"])
            idx = seen_cmd["cmd"].index("--include-pc-file")
            self.assertEqual(seen_cmd["cmd"][idx + 1], str(include_pc_file))
            self.assertIn("--static-fallback-symbol-regex", seen_cmd["cmd"])
            fallback_idx = seen_cmd["cmd"].index("--static-fallback-symbol-regex")
            self.assertEqual(seen_cmd["cmd"][fallback_idx + 1], "avx512")
            self.assertEqual(
                [
                    seen_cmd["cmd"][idx + 1]
                    for idx, token in enumerate(seen_cmd["cmd"])
                    if token == "--static-fallback-profile"
                ],
                ["simd-heavy", "all-functions", "all-text"],
            )

    def test_cmp_parser_accepts_full_static_fallback_profiles(self):
        module = load_module()
        parser = module.build_parser()

        args = parser.parse_args(
            [
                "cmp",
                "--binary",
                "/tmp/libcrypto.so.3",
                "--groundtruth",
                "/tmp/libcrypto.gtBlock.pb",
                "--blocks-pb2",
                "/tmp/blocks_pb2.py",
                "--ll",
                "/tmp/libcrypto.ll",
                "--static-fallback-profile",
                "all-functions",
                "--static-fallback-profile",
                "all-text",
            ]
        )

        self.assertEqual(args.static_fallback_profile, ["all-functions", "all-text"])


if __name__ == "__main__":
    unittest.main()
