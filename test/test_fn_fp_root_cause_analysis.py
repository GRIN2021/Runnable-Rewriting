import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
FIXTURE_DIR = REPO_ROOT / "test" / "fixtures" / "fn_fp_root_cause"
VALIDATE_SCRIPT = REPO_ROOT / "runnable" / "scripts" / "validate_libcrypto_ground_truth.py"
ANALYZE_SCRIPT = REPO_ROOT / "runnable" / "scripts" / "analyze_fn_fp_root_causes.py"


class FnFpRootCauseAnalysisTest(unittest.TestCase):
    def test_validate_libcrypto_ground_truth_reports_expected_metrics(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            summary_path = Path(tmpdir) / "validation.json"
            subprocess.run(
                [
                    "python3",
                    str(VALIDATE_SCRIPT),
                    "--ground-truth-csv",
                    str(FIXTURE_DIR / "ground_truth.csv"),
                    "--ll",
                    str(FIXTURE_DIR / "merged.ll"),
                    "--function-symbols-csv",
                    str(FIXTURE_DIR / "function_symbols.csv"),
                    "--csv-image-base",
                    "0x1000",
                    "--rebase-base",
                    "0x50000000",
                    "--summary-out",
                    str(summary_path),
                ],
                check=True,
                cwd=str(REPO_ROOT),
                capture_output=True,
                text=True,
            )

            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertEqual(summary["tp"], 1)
            self.assertEqual(summary["fp"], 5)
            self.assertEqual(summary["fn"], 5)
            self.assertEqual(summary["tp_addresses"], ["0x50000000"])
            self.assertEqual(summary["fn_addresses"], [
                "0x50000005",
                "0x50000008",
                "0x5000000c",
                "0x50000010",
                "0x50000014",
            ])
            self.assertEqual(summary["fp_addresses"], [
                "0x50000002",
                "0x50000018",
                "0x5000001b",
                "0x50000021",
                "0x50000030",
            ])

    def test_analyze_fn_fp_root_causes_classifies_expected_reasons(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            summary_path = Path(tmpdir) / "validation.json"
            analysis_path = Path(tmpdir) / "analysis.json"
            subprocess.run(
                [
                    "python3",
                    str(VALIDATE_SCRIPT),
                    "--ground-truth-csv",
                    str(FIXTURE_DIR / "ground_truth.csv"),
                    "--ll",
                    str(FIXTURE_DIR / "merged.ll"),
                    "--function-symbols-csv",
                    str(FIXTURE_DIR / "function_symbols.csv"),
                    "--csv-image-base",
                    "0x1000",
                    "--rebase-base",
                    "0x50000000",
                    "--summary-out",
                    str(summary_path),
                ],
                check=True,
                cwd=str(REPO_ROOT),
                capture_output=True,
                text=True,
            )
            subprocess.run(
                [
                    "python3",
                    str(ANALYZE_SCRIPT),
                    "--validation-summary",
                    str(summary_path),
                    "--ground-truth-csv",
                    str(FIXTURE_DIR / "ground_truth.csv"),
                    "--function-symbols-csv",
                    str(FIXTURE_DIR / "function_symbols.csv"),
                    "--merged-ll",
                    str(FIXTURE_DIR / "merged.ll"),
                    "--shard-results-json",
                    str(FIXTURE_DIR / "shard_results.json"),
                    "--csv-image-base",
                    "0x1000",
                    "--rebase-base",
                    "0x50000000",
                    "--summary-out",
                    str(analysis_path),
                ],
                check=True,
                cwd=str(REPO_ROOT),
                capture_output=True,
                text=True,
            )

            analysis = json.loads(analysis_path.read_text(encoding="utf-8"))
            reasons = {
                finding["address"]: finding["reason"]
                for finding in analysis["findings"]
            }
            self.assertEqual(reasons["0x50000005"], "illegal_entry_suppression")
            self.assertEqual(reasons["0x50000008"], "shard_timeout")
            self.assertEqual(reasons["0x5000000c"], "merge_missing")
            self.assertEqual(reasons["0x50000010"], "shard_empty")
            self.assertEqual(reasons["0x50000014"], "shard_error")
            self.assertEqual(reasons["0x50000002"], "continuation_byte")
            self.assertEqual(reasons["0x50000018"], "ground_truth_gap")
            self.assertEqual(reasons["0x5000001b"], "extra_lifted_bytes")
            self.assertEqual(reasons["0x50000021"], "padding")
            self.assertEqual(reasons["0x50000030"], "outside_gt_coverage")


if __name__ == "__main__":
    unittest.main()
