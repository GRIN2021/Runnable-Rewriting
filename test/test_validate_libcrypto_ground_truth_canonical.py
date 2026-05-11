import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


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


if __name__ == "__main__":
    unittest.main()
