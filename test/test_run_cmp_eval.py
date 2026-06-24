import importlib.util
import sys
import tempfile
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
            0xCF000,
            0x50000000,
            {0xCEF80, 0xCEFA0},
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
        self.assertEqual(payload["text_end"], 0xCF000)
        self.assertEqual(payload["runnable_base"], 0x50000000)
        self.assertEqual(payload["scope_kind"], "pc_whitelist")
        self.assertEqual(payload["include_pc_count"], 2)
        self.assertEqual(payload["mismatch_examples"][0]["address"], "0x50000000")
        self.assertEqual(payload["obj_only_examples"][0]["instruction"], "ret")
        self.assertEqual(payload["ll_only_examples"][0]["instruction"], "jmp")

    def test_load_include_pcs_supports_comments_and_blank_lines(self):
        module = load_module()

        with tempfile.TemporaryDirectory() as tmpdir:
            pc_path = Path(tmpdir) / "pcs.txt"
            pc_path.write_text(
                "\n".join(
                    [
                        "# sidecar slice",
                        "0xcef80",
                        "",
                        "848800 # decimal is also allowed",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            pcs = module.load_include_pcs(pc_path)

        self.assertEqual(pcs, {0xCEF80, 848800})

    def test_comparator_scope_filters_obj_and_ll_addresses(self):
        module = load_module()

        raw_ll = {
            0x50001000: "mov",
            0x50001004: "add",
            0x50001008: "ret",
        }

        normalized = module.compare_text.normalize_ll_addresses(
            raw_ll,
            text_start=0x1000,
            base=0x50000000,
            text_end=0x1008,
            include_pcs={0x1000, 0x1004, 0x1008},
        )

        self.assertEqual(normalized, {0x1000: "mov", 0x1004: "add"})
        self.assertTrue(
            module.compare_text.should_include_address(
                0x1004,
                0x1000,
                text_end=0x1008,
                include_pcs={0x1004},
            )
        )
        self.assertFalse(
            module.compare_text.should_include_address(
                0x1008,
                0x1000,
                text_end=0x1008,
                include_pcs={0x1008},
            )
        )

    def test_parse_ll_raw_falls_back_to_bb_labels(self):
        module = load_module()

        with tempfile.TemporaryDirectory() as tmpdir:
            ll_path = Path(tmpdir) / "sample.ll"
            ll_path.write_text(
                "\n".join(
                    [
                        "define void @root(i64 %pc) {",
                        "entrypoint:",
                        "  br label %bb.0x50000000",
                        "",
                        "bb.0x50000000:",
                        "  call void @abort()",
                        "  unreachable",
                        "",
                        "bb.0x50000010:",
                        "  ret void",
                        "}",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            lifted = module.compare_text.parse_ll_raw(ll_path)

        self.assertEqual(lifted, {0x50000000: "bb", 0x50000010: "bb"})

    def test_parse_ll_raw_skips_blank_marker_comments(self):
        module = load_module()

        with tempfile.TemporaryDirectory() as tmpdir:
            ll_path = Path(tmpdir) / "sample.ll"
            ll_path.write_text(
                "\n".join(
                    [
                        "define void @root(i64 %pc) {",
                        "entrypoint:",
                        "  ; 0x50304F30:",
                        "  ; 0x50304F31:  mov    eax, ebx",
                        "  ; 0x50304F32:",
                        "  ; 0x50304F33:  ret",
                        "}",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            lifted = module.compare_text.parse_ll_raw(ll_path)

        self.assertEqual(lifted, {0x50304F31: "mov", 0x50304F33: "ret"})

    def test_parse_ll_raw_ignores_diagnostic_marker_comments(self):
        module = load_module()

        with tempfile.TemporaryDirectory() as tmpdir:
            ll_path = Path(tmpdir) / "sample.ll"
            ll_path.write_text(
                "\n".join(
                    [
                        "define void @root(i64 %pc) {",
                        "entrypoint:",
                        "  ; 0x50304F30: <disassemble unavailable>",
                        "  ; 0x50304F31: ???",
                        "  ; 0x50304F32: => helper trace",
                        "  ; 0x50304F33: ret",
                        "}",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            lifted = module.compare_text.parse_ll_raw(ll_path)

        self.assertEqual(lifted, {0x50304F33: "ret"})

    def test_parse_ll_raw_scoped_mode_keeps_bb_for_marker_only_addresses(self):
        module = load_module()

        with tempfile.TemporaryDirectory() as tmpdir:
            ll_path = Path(tmpdir) / "sample.ll"
            ll_path.write_text(
                "\n".join(
                    [
                        "define void @root(i64 %pc) {",
                        "entrypoint:",
                        "  ; 0x50304F30:",
                        "  ; 0x50304F30: <disassemble unavailable>",
                        "  br label %bb.0x50304F30",
                        "",
                        "bb.0x50304F30:",
                        "  call void @abort()",
                        "  unreachable",
                        "}",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            default_lifted = module.compare_text.parse_ll_raw(ll_path)
            scoped_lifted = module.compare_text.parse_ll_raw(
                ll_path,
                include_address_markers=True,
            )

        self.assertEqual(default_lifted, {})
        self.assertEqual(scoped_lifted, {0x50304F30: "bb"})


if __name__ == "__main__":
    unittest.main()
