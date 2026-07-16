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
        self.assertFalse(payload["static_fallback"]["enabled"])

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

    def test_apply_static_fallback_only_fills_selected_missing_addresses(self):
        module = load_module()

        obj_instructions = {
            0x1000: "push",
            0x1001: "mov",
            0x1004: "vpxorq",
            0x2000: "ret",
        }
        ll_instructions = {
            0x1000: "push",
            0x1001: "lea",
        }

        stats = module.apply_static_fallback(
            obj_instructions,
            ll_instructions,
            [{"name": "target_avx512", "start": 0x1000, "end": 0x1008, "size": 8}],
        )

        self.assertEqual(
            stats,
            {"added": 1, "covered_obj": 3, "range_count": 1, "replaced_placeholders": 0},
        )
        self.assertEqual(
            ll_instructions,
            {
                0x1000: "push",
                0x1001: "lea",
                0x1004: "vpxorq",
            },
        )

    def test_apply_static_fallback_merges_overlapping_ranges(self):
        module = load_module()

        obj_instructions = {
            0x1000: "push",
            0x1001: "mov",
            0x1002: "add",
            0x1003: "ret",
            0x2000: "nop",
        }
        ll_instructions = {
            0x1001: "lea",
        }

        stats = module.apply_static_fallback(
            obj_instructions,
            ll_instructions,
            [
                {"name": "first", "start": 0x1000, "end": 0x1003, "size": 3},
                {"name": "overlap", "start": 0x1001, "end": 0x1004, "size": 3},
                {"name": "duplicate", "start": 0x1000, "end": 0x1003, "size": 3},
            ],
        )

        self.assertEqual(
            stats,
            {"added": 3, "covered_obj": 4, "range_count": 3, "replaced_placeholders": 0},
        )
        self.assertEqual(
            ll_instructions,
            {
                0x1000: "push",
                0x1001: "lea",
                0x1002: "add",
                0x1003: "ret",
            },
        )

    def test_apply_static_fallback_replaces_placeholder_markers(self):
        module = load_module()

        obj_instructions = {
            0x1000: "push",
            0x1001: "test",
            0x1004: "mov",
            0x1008: "ret",
        }
        ll_instructions = {
            0x1000: "bb",
            0x1001: "marker",
            0x1004: "lea",
        }

        stats = module.apply_static_fallback(
            obj_instructions,
            ll_instructions,
            [{"name": "all-text", "start": 0x1000, "end": 0x1009, "size": 9}],
        )

        self.assertEqual(
            stats,
            {"added": 1, "covered_obj": 4, "range_count": 1, "replaced_placeholders": 2},
        )
        self.assertEqual(
            ll_instructions,
            {
                0x1000: "push",
                0x1001: "test",
                0x1004: "lea",
                0x1008: "ret",
            },
        )

    def test_expand_static_fallback_profile_adds_named_regexes(self):
        module = load_module()

        expanded = module.expand_static_fallback_regexes(["avx512"], [r"custom"])

        self.assertIn(r"avx512", expanded)
        self.assertIn(r"custom", expanded)

    def test_expand_static_fallback_profile_adds_all_functions_regex(self):
        module = load_module()

        expanded = module.expand_static_fallback_regexes(["all-functions"], [])

        self.assertEqual(expanded, [r".*"])

    def test_expand_static_fallback_profile_marks_all_text_without_regex(self):
        module = load_module()

        expanded, include_all_text = module.expand_static_fallback_options(["all-text"], [])

        self.assertIn("all-text", module.static_fallback_profile_choices())
        self.assertEqual(expanded, [])
        self.assertTrue(include_all_text)

    def test_all_text_profile_uses_obj_scope_without_symbol_ranges(self):
        module = load_module()

        obj_instructions = {
            0x1000: "push",
            0x1010: "nop",
            0x2000: "ret",
        }
        ll_instructions = {
            0x1010: "lea",
        }

        def fail_parse_readelf_func_ranges(*_args, **_kwargs):
            raise AssertionError("all-text should not parse symbol ranges")

        original = module.parse_readelf_func_ranges
        try:
            module.parse_readelf_func_ranges = fail_parse_readelf_func_ranges
            symbol_regexes, include_all_text = module.expand_static_fallback_options(["all-text"], [])
            ranges = module.collect_static_fallback_ranges(
                Path("/does/not/matter"),
                obj_instructions,
                symbol_regexes,
                include_all_text,
            )
        finally:
            module.parse_readelf_func_ranges = original

        stats = module.apply_static_fallback(obj_instructions, ll_instructions, ranges)

        self.assertEqual(
            ranges,
            [{"name": "all-text", "start": 0x1000, "end": 0x2001, "size": 0x1001}],
        )
        self.assertEqual(
            stats,
            {"added": 2, "covered_obj": 3, "range_count": 1, "replaced_placeholders": 0},
        )
        self.assertEqual(
            ll_instructions,
            {
                0x1000: "push",
                0x1010: "lea",
                0x2000: "ret",
            },
        )

    def test_expand_static_fallback_profile_rejects_unknown_profile(self):
        module = load_module()

        with self.assertRaises(ValueError):
            module.expand_static_fallback_regexes(["missing"], [])


if __name__ == "__main__":
    unittest.main()
