import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SKILL_PATH = REPO_ROOT / ".codex" / "skills" / "runnable-parallel-lift" / "SKILL.md"
PLAN_PATH = (
    REPO_ROOT
    / "docs"
    / "superpowers"
    / "plans"
    / "2026-04-29-runnable-lift-dynamic-branch-parallel.md"
)
LEGACY_HELPER = REPO_ROOT / "runnable" / "scripts" / "_merge_dynamic_fragments_lib.py"


class RunnableParallelLiftSkillTest(unittest.TestCase):
    def test_skill_exists_and_points_to_dynamic_default(self) -> None:
        self.assertTrue(SKILL_PATH.is_file(), f"missing skill: {SKILL_PATH}")

        content = SKILL_PATH.read_text(encoding="utf-8")
        self.assertIn("dynamic branch-driven", content)
        self.assertIn("-dynamic-parallel", content)
        self.assertIn("-parallel-workers", content)
        self.assertIn("-parallel-fragment-dir", content)
        self.assertIn("runnable/scripts/merge_dynamic_runnable_fragments.py", content)
        self.assertIn("worker_<pc>.ll", content)

    def test_skill_preserves_legacy_static_sharding_guardrails(self) -> None:
        content = SKILL_PATH.read_text(encoding="utf-8")
        self.assertIn("scripts/libcrypto_parallel_lift.py", content)
        self.assertIn("run_libcrypto_parallel_lift_stable.py", content)
        self.assertIn("legacy", content.lower())
        self.assertIn("shards/", content)
        self.assertIn("raw/", content)
        self.assertIn("merged_full.ll", content)
        self.assertIn("do not mix", content.lower())

    def test_dynamic_parallel_reference_plan_exists(self) -> None:
        self.assertTrue(PLAN_PATH.is_file(), f"missing plan: {PLAN_PATH}")
        content = PLAN_PATH.read_text(encoding="utf-8")
        self.assertIn("runnable-lift", content)
        self.assertIn("merge_dynamic_runnable_fragments.py", content)
        self.assertIn("worker_<pc>.ll", content)
        self.assertIn("legacy static sharding", content.lower())

    def test_legacy_helper_help_is_labeled_legacy(self) -> None:
        result = subprocess.run(
            ["python3", str(LEGACY_HELPER), "--help"],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("legacy", result.stdout.lower())
        self.assertIn("address-ranged", result.stdout)


if __name__ == "__main__":
    unittest.main()
