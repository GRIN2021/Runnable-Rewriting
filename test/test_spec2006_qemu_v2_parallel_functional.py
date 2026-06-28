import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1]
    / "runnable"
    / "scripts"
    / "spec2006_qemu_v2_parallel_functional.py"
)


def load_module():
    spec = importlib.util.spec_from_file_location(
        "spec2006_qemu_v2_parallel_functional", SCRIPT_PATH
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def write_sidecar(root: Path, *, payload_count: int, source_count: int) -> tuple[Path, Path]:
    summary = root / "sidecar.summary.json"
    payload = root / "sidecar.payload.txt"
    summary.write_text(
        json.dumps(
            {
                "canonical_requested_pc": "0x400331",
                "captured_actual_pc": "0x400331",
                "first_debug_insn_start_pc": "0x400331",
                "payload_instruction_count": payload_count,
                "selected_instruction_count": payload_count,
                "source_instruction_count": source_count,
                "rejected_instruction": None,
                "rejected_instruction_count": 0,
            }
        ),
        encoding="utf-8",
    )
    payload.write_text(
        "\n".join(
            [
                "PTC_LIVE_SIDECAR v1",
                f"instruction_count={payload_count}",
                "argument_count=16",
                "temp_count=10",
                "instruction|0|debug_insn_start|0|0|3|0x400331,0x38,0x0",
                "",
            ]
        ),
        encoding="utf-8",
    )
    return summary, payload


class Spec2006QemuV2ParallelFunctionalTests(unittest.TestCase):
    def test_rejects_short_sidecar_and_truncated_entry_unreachable(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stderr = root / "lift.stderr.log"
            stderr.write_text("runnable-lift: PTC ABI metadata detected\n", encoding="utf-8")
            ll = root / "bad.ll"
            ll.write_text(
                """
define void @root(i64) {
entrypoint:
  br label %bb.0x400331

bb.0x400331:
  call void (i64, i64, i32, i8*, ...) @newpc(i64 4195121, i64 9, i32 1, i8* null)
  store i64 0, i64* @rbp
  store i64 68, i64* @cc_src
  unreachable

serialize_and_jump_out:
  ret void
}
""",
                encoding="utf-8",
            )
            summary, payload = write_sidecar(root, payload_count=9, source_count=39)

            checks = module.qemu_v2_artifact_checks(
                stderr_path=stderr,
                ll_path=ll,
                sidecar_summary_path=summary,
                sidecar_payload_path=payload,
            )

            self.assertEqual(checks["status"], "failed")
            self.assertIn("sidecar:sidecar_short_payload_vs_source", checks["reasons"])
            self.assertIn("ll:ll_entry_block_truncated_unreachable", checks["reasons"])
            self.assertEqual(
                module.classify_lift(0, False, stderr, module.ll_stats(ll), checks),
                "failed_qemu_v2_artifact_checks",
            )

    def test_rejects_forbidden_stderr_even_with_successful_returncode(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stderr = root / "lift.stderr.log"
            stderr.write_text(
                "\n".join(
                    [
                        "warning: native fallback after unsupported opcode",
                        "runnable-lift: warning: skipping unresolved QEMU v2 PTC helper helper=unknown_0x1e",
                        "runnable-lift: warning: materializing empty jump target pc=0x4086e5 block=bb.0x4086e5",
                        "",
                    ]
                ),
                encoding="utf-8",
            )
            ll = root / "ok.ll"
            ll.write_text(
                """
define void @root(i64) {
bb.0x400331:
  store i64 0, i64* @rbp
  br label %serialize_and_jump_out

serialize_and_jump_out:
  ret void
}
""",
                encoding="utf-8",
            )
            summary, payload = write_sidecar(root, payload_count=35, source_count=39)

            checks = module.qemu_v2_artifact_checks(
                stderr_path=stderr,
                ll_path=ll,
                sidecar_summary_path=summary,
                sidecar_payload_path=payload,
            )

            self.assertEqual(checks["status"], "failed")
            self.assertIn("stderr:native_fallback", checks["reasons"])
            self.assertIn("stderr:unsupported_opcode", checks["reasons"])
            self.assertIn("stderr:unresolved_qemu_v2_helper", checks["reasons"])
            self.assertIn("stderr:empty_jump_target", checks["reasons"])
            self.assertEqual(
                module.classify_lift(0, False, stderr, module.ll_stats(ll), checks),
                "failed_qemu_v2_artifact_checks",
            )

    def test_rejects_returned_pc_divergence_trampoline_and_mismatched_tb(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stderr = root / "lift.stderr.log"
            stderr.write_text(
                "\n".join(
                    [
                        "runnable-lift: handled QEMU v2 PTC returned-pc divergence requested_pc=0x400331 first_debug_pc=0x401000",
                        "runnable-lift: handled PTC returned block pc divergence requested=0x400331 returned=0x401000",
                        "runnable-lift: synthesized x86_64 _start trampoline start_pc=0x400331 target_pc=0x400347",
                        "runnable-lift: translating mismatched returned PTC TB under requested block",
                        "",
                    ]
                ),
                encoding="utf-8",
            )
            ll = root / "ok.ll"
            ll.write_text(
                """
define void @root(i64) {
bb.0x400331:
  store i64 0, i64* @rbp
  br label %serialize_and_jump_out

serialize_and_jump_out:
  ret void
}
""",
                encoding="utf-8",
            )
            summary, payload = write_sidecar(root, payload_count=35, source_count=39)

            checks = module.qemu_v2_artifact_checks(
                stderr_path=stderr,
                ll_path=ll,
                sidecar_summary_path=summary,
                sidecar_payload_path=payload,
            )

            self.assertEqual(checks["status"], "failed")
            self.assertIn("stderr:returned_pc_divergence", checks["reasons"])
            self.assertIn("stderr:returned_block_pc_divergence", checks["reasons"])
            self.assertIn("stderr:block_pc_divergence", checks["reasons"])
            self.assertIn("stderr:start_trampoline", checks["reasons"])
            self.assertIn("stderr:mismatched_returned_ptc_tb", checks["reasons"])
            self.assertEqual(
                module.classify_lift(0, False, stderr, module.ll_stats(ll), checks),
                "failed_qemu_v2_artifact_checks",
            )

    def test_allows_full_sidecar_and_branching_entry_block(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stderr = root / "lift.stderr.log"
            stderr.write_text("runnable-lift: PTC ABI metadata detected\n", encoding="utf-8")
            ll = root / "ok.ll"
            ll.write_text(
                """
define void @root(i64) {
bb.0x400331:
  call void (i64, i64, i32, i8*, ...) @newpc(i64 4195121, i64 35, i32 1, i8* null)
  store i64 0, i64* @rbp
  br label %serialize_and_jump_out

serialize_and_jump_out:
  ret void
}
""",
                encoding="utf-8",
            )
            summary, payload = write_sidecar(root, payload_count=35, source_count=39)

            checks = module.qemu_v2_artifact_checks(
                stderr_path=stderr,
                ll_path=ll,
                sidecar_summary_path=summary,
                sidecar_payload_path=payload,
            )

            self.assertEqual(checks["status"], "passed")
            self.assertEqual(
                module.classify_lift(0, False, stderr, module.ll_stats(ll), checks),
                "passed",
            )

    def test_real_qemu_v2_metadata_requirement_remains(self) -> None:
        module = load_module()

        module.require_real_qemu_v2(
            {"fields": {"abi_version": "2", "real_translation": "true"}}
        )
        with self.assertRaises(RuntimeError):
            module.require_real_qemu_v2(
                {"fields": {"abi_version": "1", "real_translation": "true"}}
            )
        with self.assertRaises(RuntimeError):
            module.require_real_qemu_v2(
                {"fields": {"abi_version": "2", "real_translation": "false"}}
            )


if __name__ == "__main__":
    unittest.main()
