import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SKILL_PATH = (
    REPO_ROOT / ".codex" / "skills" / "runnable-libcrypto-canonical-eval" / "SKILL.md"
)
DOC_PATH = REPO_ROOT / "docs" / "exp" / "2026-05-10-libcrypto-canonical-eval-contract.md"


class RunnableLibcryptoCanonicalEvalSkillTest(unittest.TestCase):
    def test_skill_exists_and_points_to_branch_native_paths(self) -> None:
        self.assertTrue(SKILL_PATH.is_file(), f"missing skill: {SKILL_PATH}")
        content = SKILL_PATH.read_text(encoding="utf-8")
        self.assertIn("runnable/scripts/libcrypto_bench_paths.py", content)
        self.assertIn("runnable/scripts/validate_libcrypto_ground_truth.py", content)
        self.assertIn("blocks-pb2", content)
        self.assertIn("cmp-tool", content)
        self.assertIn("historical sidecar-union / non-canonical", content)

    def test_experiment_doc_exists_and_explains_workspace_layout(self) -> None:
        self.assertTrue(DOC_PATH.is_file(), f"missing doc: {DOC_PATH}")
        content = DOC_PATH.read_text(encoding="utf-8")
        self.assertIn("GroudTruth", content)
        self.assertIn("runnable/scripts/validate_libcrypto_ground_truth.py", content)
        self.assertIn("top-level `scripts/`, `tests/`, and `archives/...`", content)


if __name__ == "__main__":
    unittest.main()
