import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MATERIALIZER_PATH = REPO_ROOT / "runnable" / "scripts" / "qemu_v2_ptc_materialize_walker_sidecar.py"


def temp_record(index: int, name: str, walker_arg: str, *, is_global: bool = False) -> dict:
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
            "val": None,
            "fixed_reg": False,
            "mem_coherent": False,
            "mem_allocated": False,
            "temp_local": False,
            "temp_allocated": False,
        },
    }


class QemuV2PTCQemuSt2LoweringTests(unittest.TestCase):
    def test_materializer_lowers_qemu_st2_to_two_qemu_st_i64_stores(self) -> None:
        sidecar_model, payload = self.materialize_qemu_st2("0x15082")

        self.assertEqual(
            [inst["ptc_list_model"]["opc"] for inst in sidecar_model["instructions"]],
            ["debug_insn_start", "qemu_st_i64", "add_i64", "qemu_st_i64"],
        )
        self.assertEqual(sidecar_model["summary"]["instruction_count"], 4)
        self.assertEqual(sidecar_model["summary"]["temp_count"], 6)
        self.assertEqual(sidecar_model["instructions"][1]["args"], ["1", "3", "0x15062"])
        self.assertEqual(sidecar_model["instructions"][2]["args"], ["5", "3", "4"])
        self.assertEqual(sidecar_model["instructions"][3]["args"], ["2", "5", "0x15062"])
        self.assertEqual(sidecar_model["temps"][4]["ptc_temp_model"]["val_type"], 3)
        self.assertEqual(sidecar_model["temps"][4]["ptc_temp_model"]["val"], 8)
        self.assertTrue(sidecar_model["temps"][5]["ptc_temp_model"]["temp_allocated"])
        self.assertIn("|qemu_st_i64|0|0|3|1,3,0x15062", payload)
        self.assertIn("|add_i64|0|0|3|5,3,4", payload)
        self.assertIn("|qemu_st_i64|0|0|3|2,5,0x15062", payload)
        self.assertIn("qemu_st2->qemu_st_i64 pair", json.dumps(sidecar_model))

    def test_materializer_lowers_qemu_st2_bswap_with_swapped_halves(self) -> None:
        sidecar_model, _payload = self.materialize_qemu_st2("0x15282")

        self.assertEqual(sidecar_model["instructions"][1]["args"], ["2", "3", "0x15262"])
        self.assertEqual(sidecar_model["instructions"][3]["args"], ["1", "5", "0x15262"])
        self.assertIn("128-bit byteswap half order", json.dumps(sidecar_model))

    def materialize_qemu_st2(self, memop_idx: str) -> tuple[dict, str]:
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
                                "walker": {
                                    "name": "insn_start",
                                    "canonical_name": "insn_start",
                                    "tb_pc": "0x409fff",
                                },
                                "ptc_list_model": {
                                    "opc": "debug_insn_start",
                                    "argument_count": 1,
                                    "callo": None,
                                    "calli": None,
                                },
                                "args": ["0x409fff"],
                                "decision": {"emitted": True},
                            },
                            {
                                "index": 1,
                                "walker": {
                                    "name": "qemu_st2",
                                    "canonical_name": "qemu_st2",
                                    "tb_pc": "0x409fff",
                                },
                                "ptc_list_model": {
                                    "opc": "PTC_OP_QEMU_ST2",
                                    "argument_count": 4,
                                    "callo": None,
                                    "calli": None,
                                    "not_real_abi": True,
                                },
                                "args": ["src_lo_arg", "src_hi_arg", "addr_arg", memop_idx],
                                "decision": {"emitted": True},
                            },
                        ],
                        "temps": [
                            temp_record(0, "env", "env_arg", is_global=True),
                            temp_record(1, "src_lo", "src_lo_arg"),
                            temp_record(2, "src_hi", "src_hi_arg"),
                            temp_record(3, "addr", "addr_arg"),
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
                    "0x409fff",
                    "--canonical-pc",
                    "0x409fff",
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            sidecar_model = json.loads((output_root / "sidecar" / "sidecar.model.json").read_text(encoding="utf-8"))
            payload = (output_root / "sidecar" / "sidecar.payload.txt").read_text(encoding="utf-8")
            return sidecar_model, payload


if __name__ == "__main__":
    unittest.main()
