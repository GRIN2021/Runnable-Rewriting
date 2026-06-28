import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MATERIALIZER_PATH = REPO_ROOT / "runnable" / "scripts" / "qemu_v2_ptc_materialize_walker_sidecar.py"


def temp_record(
    index: int,
    name: str,
    walker_arg: str,
    *,
    is_global: bool = True,
    value: str | None = None,
) -> dict:
    return {
        "index": index,
        "name": name,
        "walker_arg": walker_arg,
        "flags": {"is_global": is_global},
        "ptc_temp_model": {
            "val_type": 0,
            "base_type": 1,
            "type": 1,
            "reg": 0,
            "mem_reg": 0,
            "mem_offset": 0,
            "val": value,
            "fixed_reg": False,
            "mem_coherent": False,
            "mem_allocated": False,
            "temp_local": False,
            "temp_allocated": False,
        },
    }


class QemuV2PTCHelperBoundaryLoweringTests(unittest.TestCase):
    def test_lookup_tb_call_goto_ptr_pair_lowers_to_explicit_exit_tb(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            model_path = root / "model.json"
            output_root = root / "out"
            model_path.write_text(
                json.dumps(
                    {
                        "instructions": [
                            {
                                "index": 0,
                                "walker": {"name": "insn_start", "canonical_name": "insn_start", "tb_pc": "0x1000"},
                                "ptc_list_model": {"opc": "debug_insn_start", "argument_count": 3, "callo": None, "calli": None},
                                "args": ["0x1000", "0x0", "0x0"],
                                "decision": {"emitted": True},
                            },
                            {
                                "index": 1,
                                "walker": {"name": "call", "canonical_name": "call", "tb_pc": "0x1000"},
                                "ptc_list_model": {"opc": "call", "argument_count": 4, "callo": None, "calli": None},
                                "args": ["ret_ptr", "env_ptr", "0x1111", "0x2222"],
                                "decision": {"emitted": True},
                            },
                            {
                                "index": 2,
                                "walker": {"name": "goto_ptr", "canonical_name": "goto_ptr", "tb_pc": "0x1000"},
                                "ptc_list_model": {"opc": None, "argument_count": 1, "callo": None, "calli": None},
                                "args": ["ret_ptr"],
                                "decision": {"emitted": False},
                            },
                        ],
                        "temps": [
                            temp_record(0, "env", "env_ptr"),
                            temp_record(1, "lookup_tb_ptr_result", "ret_ptr"),
                        ],
                    }
                ),
                encoding="utf-8",
            )

            subprocess.run(
                [
                    sys.executable,
                    str(MATERIALIZER_PATH),
                    "--model-json",
                    str(model_path),
                    "--output-root",
                    str(output_root),
                    "--captured-pc",
                    "0x1000",
                    "--canonical-pc",
                    "0x1000",
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            sidecar_model = json.loads((output_root / "sidecar" / "sidecar.model.json").read_text(encoding="utf-8"))
            payload = (output_root / "sidecar" / "sidecar.payload.txt").read_text(encoding="utf-8")
            opcodes = [inst["ptc_list_model"]["opc"] for inst in sidecar_model["instructions"]]

            self.assertEqual(opcodes, ["debug_insn_start", "exit_tb"])
            self.assertNotIn("|call|", payload)
            self.assertIn("call+goto_ptr->exit_tb boundary: dropped lookup_tb_ptr call", json.dumps(sidecar_model))
            self.assertEqual([temp["name"] for temp in sidecar_model["temps"]], ["env"])

    def test_direct_exit_tb_gets_auditable_guest_pc_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            model_path = root / "model.json"
            output_root = root / "out"
            model_path.write_text(
                json.dumps(
                    {
                        "instructions": [
                            {
                                "index": 0,
                                "walker": {"name": "insn_start", "canonical_name": "insn_start", "tb_pc": "0x1000"},
                                "ptc_list_model": {"opc": "debug_insn_start", "argument_count": 1, "callo": None, "calli": None},
                                "args": ["0x1000"],
                                "decision": {"emitted": True},
                            },
                            {
                                "index": 1,
                                "walker": {"name": "mov", "canonical_name": "mov_i64", "tb_pc": "0x1000"},
                                "ptc_list_model": {"opc": "mov_i64", "argument_count": 2, "callo": None, "calli": None},
                                "args": ["rip_ptr", "next_pc_const"],
                                "decision": {"emitted": True},
                            },
                            {
                                "index": 2,
                                "walker": {"name": "exit_tb", "canonical_name": "exit_tb", "tb_pc": "0x1000"},
                                "ptc_list_model": {"opc": "exit_tb", "argument_count": 1, "callo": None, "calli": None},
                                "args": ["0x7fff00000080"],
                                "decision": {"emitted": True},
                            },
                        ],
                        "temps": [
                            temp_record(0, "env", "env_ptr"),
                            temp_record(1, "rip", "rip_ptr"),
                            temp_record(2, "tmp_next_pc", "next_pc_const", is_global=False, value="0x2000"),
                        ],
                    }
                ),
                encoding="utf-8",
            )

            subprocess.run(
                [
                    sys.executable,
                    str(MATERIALIZER_PATH),
                    "--model-json",
                    str(model_path),
                    "--output-root",
                    str(output_root),
                    "--captured-pc",
                    "0x1000",
                    "--canonical-pc",
                    "0x1000",
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            sidecar_model = json.loads((output_root / "sidecar" / "sidecar.model.json").read_text(encoding="utf-8"))
            payload = (output_root / "sidecar" / "sidecar.payload.txt").read_text(encoding="utf-8")

            self.assertEqual(sidecar_model["instructions"][2]["args"], ["0x2000"])
            self.assertIn("|exit_tb|0|0|1|0x2000", payload)
            self.assertIn("exit_tb target annotated from pc-store 0x2000", json.dumps(sidecar_model))


if __name__ == "__main__":
    unittest.main()
