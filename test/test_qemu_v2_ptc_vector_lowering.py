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
    is_global: bool = False,
    val: int | None = None,
    ptc_type: int | None = 1,
) -> dict:
    return {
        "index": index,
        "name": name,
        "walker_arg": walker_arg,
        "flags": {"is_global": is_global, "is_const": val is not None},
        "ptc_temp_model": {
            "val_type": 0,
            "base_type": ptc_type,
            "type": ptc_type,
            "reg": 0,
            "mem_reg": 0,
            "mem_offset": 0,
            "val": val,
            "fixed_reg": False,
            "mem_coherent": False,
            "mem_allocated": False,
            "temp_local": False,
            "temp_allocated": False,
        },
    }


class QemuV2PTCVectorLoweringTests(unittest.TestCase):
    def test_materializer_lowers_known_zero_v128_st_vec_to_env_st_i64_pair(self) -> None:
        sidecar_model, payload = self.materialize_zero_vector_store()

        self.assertEqual(
            [inst["ptc_list_model"]["opc"] for inst in sidecar_model["instructions"]],
            ["debug_insn_start", "st_i64", "st_i64"],
        )
        self.assertEqual(sidecar_model["summary"]["instruction_count"], 3)
        self.assertEqual(sidecar_model["instructions"][1]["args"], ["3", "0", "0x360"])
        self.assertEqual(sidecar_model["instructions"][2]["args"], ["3", "0", "0x368"])
        self.assertEqual(sidecar_model["temps"][3]["ptc_temp_model"]["val"], 0)
        self.assertEqual(sidecar_model["temps"][3]["ptc_temp_model"]["val_type"], 3)
        self.assertIn("|st_i64|0|0|3|3,0,0x360", payload)
        self.assertIn("|st_i64|0|0|3|3,0,0x368", payload)
        self.assertIn("mov_vec(128)->vector half state", json.dumps(sidecar_model))
        self.assertIn("st_vec(128)->st_i64 env-store halves", json.dumps(sidecar_model))

    def test_materializer_lowers_v128_ld_mov_st_vec_to_dynamic_i64_halves(self) -> None:
        sidecar_model, payload = self.materialize_vector_load_copy_store()

        self.assertEqual(
            [inst["ptc_list_model"]["opc"] for inst in sidecar_model["instructions"]],
            ["debug_insn_start", "ld_i64", "ld_i64", "st_i64", "st_i64"],
        )
        self.assertEqual(sidecar_model["summary"]["instruction_count"], 5)
        self.assertEqual(sidecar_model["instructions"][1]["args"], ["3", "0", "0x3a0"])
        self.assertEqual(sidecar_model["instructions"][2]["args"], ["4", "0", "0x3a8"])
        self.assertEqual(sidecar_model["instructions"][3]["args"], ["3", "0", "0x3e0"])
        self.assertEqual(sidecar_model["instructions"][4]["args"], ["4", "0", "0x3e8"])
        self.assertIn("|ld_i64|0|0|3|3,0,0x3a0", payload)
        self.assertIn("|ld_i64|0|0|3|4,0,0x3a8", payload)
        self.assertIn("|st_i64|0|0|3|3,0,0x3e0", payload)
        self.assertIn("|st_i64|0|0|3|4,0,0x3e8", payload)
        self.assertIn("ld_vec(128)->ld_i64 env-load halves", json.dumps(sidecar_model))
        self.assertIn("mov_vec(128)->vector half state", json.dumps(sidecar_model))
        self.assertIn("st_vec(128)->st_i64 env-store halves", json.dumps(sidecar_model))

    def materialize_zero_vector_store(self) -> tuple[dict, str]:
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
                                    "tb_pc": "0x408a26",
                                },
                                "ptc_list_model": {
                                    "opc": "debug_insn_start",
                                    "argument_count": 1,
                                    "callo": None,
                                    "calli": None,
                                },
                                "args": ["0x408a26"],
                                "decision": {"emitted": True},
                            },
                            {
                                "index": 1,
                                "walker": {
                                    "name": "mov_vec",
                                    "canonical_name": "mov_vec",
                                    "tb_pc": "0x408a26",
                                    "param1": 4,
                                    "param1_decoded": {"bits": 128, "abi": "v128"},
                                },
                                "ptc_list_model": {
                                    "opc": "PTC_OP_MOV_VEC",
                                    "argument_count": 2,
                                    "callo": None,
                                    "calli": None,
                                    "not_real_abi": True,
                                },
                                "args": ["vec_dst_arg", "vec_zero_arg"],
                                "decision": {"emitted": True},
                            },
                            {
                                "index": 2,
                                "walker": {
                                    "name": "st_vec",
                                    "canonical_name": "st_vec",
                                    "tb_pc": "0x408a26",
                                    "param1": 4,
                                    "param1_decoded": {"bits": 128, "abi": "v128"},
                                },
                                "ptc_list_model": {
                                    "opc": "PTC_OP_ST_VEC",
                                    "argument_count": 3,
                                    "callo": None,
                                    "calli": None,
                                    "not_real_abi": True,
                                },
                                "args": ["vec_dst_arg", "env_arg", "0x360"],
                                "decision": {"emitted": True},
                            },
                        ],
                        "temps": [
                            temp_record(0, "env", "env_arg", is_global=True),
                            temp_record(1, "vec_dst", "vec_dst_arg", ptc_type=None),
                            temp_record(2, "vec_zero", "vec_zero_arg", val=0, ptc_type=None),
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
                    "0x408a26",
                    "--canonical-pc",
                    "0x408a26",
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            sidecar_model = json.loads((output_root / "sidecar" / "sidecar.model.json").read_text(encoding="utf-8"))
            payload = (output_root / "sidecar" / "sidecar.payload.txt").read_text(encoding="utf-8")
            return sidecar_model, payload

    def materialize_vector_load_copy_store(self) -> tuple[dict, str]:
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
                                    "tb_pc": "0x4022be",
                                },
                                "ptc_list_model": {
                                    "opc": "debug_insn_start",
                                    "argument_count": 1,
                                    "callo": None,
                                    "calli": None,
                                },
                                "args": ["0x4022be"],
                                "decision": {"emitted": True},
                            },
                            {
                                "index": 1,
                                "walker": {
                                    "name": "ld_vec",
                                    "canonical_name": "ld_vec",
                                    "tb_pc": "0x4022be",
                                    "param1": 4,
                                    "param1_decoded": {"bits": 128, "abi": "v128"},
                                },
                                "ptc_list_model": {
                                    "opc": "PTC_OP_LD_VEC",
                                    "argument_count": 3,
                                    "callo": None,
                                    "calli": None,
                                    "not_real_abi": True,
                                },
                                "args": ["vec_src_arg", "env_arg", "0x3a0"],
                                "decision": {"emitted": True},
                            },
                            {
                                "index": 2,
                                "walker": {
                                    "name": "mov_vec",
                                    "canonical_name": "mov_vec",
                                    "tb_pc": "0x4022be",
                                    "param1": 4,
                                    "param1_decoded": {"bits": 128, "abi": "v128"},
                                },
                                "ptc_list_model": {
                                    "opc": "PTC_OP_MOV_VEC",
                                    "argument_count": 2,
                                    "callo": None,
                                    "calli": None,
                                    "not_real_abi": True,
                                },
                                "args": ["vec_dst_arg", "vec_src_arg"],
                                "decision": {"emitted": True},
                            },
                            {
                                "index": 3,
                                "walker": {
                                    "name": "st_vec",
                                    "canonical_name": "st_vec",
                                    "tb_pc": "0x4022be",
                                    "param1": 4,
                                    "param1_decoded": {"bits": 128, "abi": "v128"},
                                },
                                "ptc_list_model": {
                                    "opc": "PTC_OP_ST_VEC",
                                    "argument_count": 3,
                                    "callo": None,
                                    "calli": None,
                                    "not_real_abi": True,
                                },
                                "args": ["vec_dst_arg", "env_arg", "0x3e0"],
                                "decision": {"emitted": True},
                            },
                        ],
                        "temps": [
                            temp_record(0, "env", "env_arg", is_global=True),
                            temp_record(1, "vec_src", "vec_src_arg", ptc_type=None),
                            temp_record(2, "vec_dst", "vec_dst_arg", ptc_type=None),
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
                    "0x4022be",
                    "--canonical-pc",
                    "0x4022be",
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            sidecar_model = json.loads((output_root / "sidecar" / "sidecar.model.json").read_text(encoding="utf-8"))
            payload = (output_root / "sidecar" / "sidecar.payload.txt").read_text(encoding="utf-8")
            return sidecar_model, payload


class QemuV2PTCScalarHelperLoweringTests(unittest.TestCase):
    def test_materializer_lowers_ctz_i64_to_helper_call_with_zero_default(self) -> None:
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
                                    "tb_pc": "0x409318",
                                },
                                "ptc_list_model": {
                                    "opc": "debug_insn_start",
                                    "argument_count": 1,
                                    "callo": None,
                                    "calli": None,
                                },
                                "args": ["0x409318"],
                                "decision": {"emitted": True},
                            },
                            {
                                "index": 1,
                                "walker": {
                                    "name": "ctz",
                                    "canonical_name": "ctz",
                                    "tb_pc": "0x409318",
                                    "param1": 1,
                                    "param1_decoded": {"bits": 64, "abi": "i64"},
                                },
                                "ptc_list_model": {
                                    "opc": None,
                                    "argument_count": 3,
                                    "callo": None,
                                    "calli": None,
                                    "not_real_abi": True,
                                },
                                "args": ["dst_arg", "src_arg", "default_arg"],
                                "decision": {"emitted": False},
                            },
                        ],
                        "temps": [
                            temp_record(0, "env", "env_arg", is_global=True),
                            temp_record(1, "dst", "dst_arg"),
                            temp_record(2, "src", "src_arg"),
                            temp_record(3, "default", "default_arg"),
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
                    "0x409318",
                    "--canonical-pc",
                    "0x409318",
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            sidecar_model = json.loads((output_root / "sidecar" / "sidecar.model.json").read_text(encoding="utf-8"))
            payload = (output_root / "sidecar" / "sidecar.payload.txt").read_text(encoding="utf-8")

        self.assertEqual(
            [inst["ptc_list_model"]["opc"] for inst in sidecar_model["instructions"]],
            ["debug_insn_start", "call", "movcond_i64"],
        )
        call_inst = sidecar_model["instructions"][1]
        movcond_inst = sidecar_model["instructions"][2]
        helper_result = int(call_inst["args"][0])
        zero_temp = int(movcond_inst["args"][2])
        self.assertEqual(call_inst["ptc_list_model"]["callo"], 1)
        self.assertEqual(call_inst["ptc_list_model"]["calli"], 1)
        self.assertEqual(call_inst["args"][1], "2")
        self.assertEqual(movcond_inst["args"], ["1", "2", str(zero_temp), str(helper_result), "3", "9"])
        self.assertEqual(sidecar_model["temps"][zero_temp]["ptc_temp_model"]["val"], 0)
        self.assertEqual(sidecar_model["helper_defs"][0]["name"], "ctz")
        self.assertIn("|call|1|1|4|", payload)
        self.assertIn("|movcond_i64|0|0|6|1,2,", payload)
        self.assertIn("|ctz|0", payload)
        self.assertIn("ctz_i64->helper_ctz+movcond_i64 zero-default", json.dumps(sidecar_model))


if __name__ == "__main__":
    unittest.main()
