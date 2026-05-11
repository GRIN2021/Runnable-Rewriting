import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "runnable" / "scripts" / "run_cmp_eval.py"


def load_module():
    spec = importlib.util.spec_from_file_location("run_cmp_eval", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class RunCmpEvalTests(unittest.TestCase):
    def test_build_payload_uses_compare_fields(self):
        module = load_module()
        payload = module.build_payload(
            None,
            Path("/tmp/libcrypto.so.3"),
            Path("/tmp/libcrypto.ll"),
            0xCEF80,
            0x50000000,
            10,
            {
                "obj_count": 10,
                "ll_count": 11,
                "hit": 9,
                "mismatch": 1,
                "obj_only": 0,
                "ll_only": 1,
                "false_negative": 1,
                "false_positive": 2,
                "precision": 9 / 11.0,
                "recall": 0.9,
                "mismatch_examples": [(0x50000000, "mov", "lea")],
                "obj_only_examples": [(0x50000001, "ret")],
                "ll_only_examples": [(0x50000002, "jmp")],
            },
        )

        self.assertEqual(payload["text_start"], 0xCEF80)
        self.assertEqual(payload["runnable_base"], 0x50000000)
        self.assertEqual(payload["mismatch_examples"][0]["address"], "0x50000000")
        self.assertEqual(payload["obj_only_examples"][0]["instruction"], "ret")
        self.assertEqual(payload["ll_only_examples"][0]["instruction"], "jmp")


if __name__ == "__main__":
    unittest.main()
