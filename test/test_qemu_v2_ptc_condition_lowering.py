import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MATERIALIZER_PATH = REPO_ROOT / "runnable" / "scripts" / "qemu_v2_ptc_materialize_walker_sidecar.py"
LIVE_SIDECAR_SMOKE_PATH = REPO_ROOT / "runnable" / "scripts" / "qemu_v2_ptc_live_sidecar_translate_smoke.sh"


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def condition_inst(opcode: str, args: list[str]) -> dict:
    return {
        "source_index": 11,
        "walker": {"name": opcode, "canonical_name": opcode},
        "ptc_list_model": {
            "opc": opcode,
            "argument_count": len(args),
            "not_real_abi": True,
        },
        "args": args,
    }


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


class QemuV2PTCConditionLoweringTests(unittest.TestCase):
    def test_every_modern_condition_is_remapped_or_rejected(self) -> None:
        materializer = load_module(MATERIALIZER_PATH, "qemu_v2_ptc_condition_all_test")
        expected = {
            0x0: 0x0,
            0x1: 0x1,
            0x2: 0x2,
            0x3: 0x3,
            0x6: 0xb,
            0x7: 0xa,
            0x8: 0x8,
            0x9: 0x9,
            0xa: 0x4,
            0xb: 0x5,
            0xe: 0xd,
            0xf: 0xc,
        }
        rejected = {0x4, 0x5}

        for modern_condition in range(16):
            if modern_condition in {0xc, 0xd}:
                continue
            inst = condition_inst("setcond_i32", ["dst", "lhs", "rhs", hex(modern_condition)])
            if modern_condition in expected:
                materializer.lower_to_legacy_ptc(inst)
                self.assertEqual(inst["args"][3], str(expected[modern_condition]))
                self.assertEqual(inst["ptc_list_model"]["opc"], "setcond_i32")
                self.assertFalse(inst["ptc_list_model"]["not_real_abi"])
                self.assertEqual(
                    inst["materializer"]["condition_lowering"]["legacy_condition"],
                    expected[modern_condition],
                )
            else:
                self.assertIn(modern_condition, rejected)
                with self.assertRaises(SystemExit):
                    materializer.lower_to_legacy_ptc(inst)

    def test_brcond_condition_is_second_constant_before_label(self) -> None:
        materializer = load_module(MATERIALIZER_PATH, "qemu_v2_ptc_condition_brcond_test")
        inst = condition_inst("brcond_i64", ["lhs", "rhs", "0xe", "0x400"])

        lowering = materializer.lower_to_legacy_ptc(inst)

        self.assertEqual(lowering, "brcond_i64 condition 0xe->0xd")
        self.assertEqual(inst["args"], ["lhs", "rhs", "13", "0x400"])
        self.assertEqual(inst["materializer"]["condition_lowering"]["arg_index"], 2)

    def test_setcond_condition_is_final_arg(self) -> None:
        materializer = load_module(MATERIALIZER_PATH, "qemu_v2_ptc_condition_setcond_test")
        inst = condition_inst("setcond_i64", ["dst", "lhs", "rhs", "0x7"])

        lowering = materializer.lower_to_legacy_ptc(inst)

        self.assertEqual(lowering, "setcond_i64 condition 0x7->0xa")
        self.assertEqual(inst["args"], ["dst", "lhs", "rhs", "10"])
        self.assertEqual(inst["materializer"]["condition_lowering"]["arg_index"], 3)

    def test_movcond_condition_is_final_arg_after_four_inputs(self) -> None:
        materializer = load_module(MATERIALIZER_PATH, "qemu_v2_ptc_condition_movcond_test")
        inst = condition_inst("movcond_i32", ["dst", "lhs", "rhs", "iftrue", "iffalse", "0xf"])

        lowering = materializer.lower_to_legacy_ptc(inst)

        self.assertEqual(lowering, "movcond_i32 condition 0xf->0xc")
        self.assertEqual(inst["args"], ["dst", "lhs", "rhs", "iftrue", "iffalse", "12"])
        self.assertEqual(inst["materializer"]["condition_lowering"]["arg_index"], 5)

    def test_ptc_op_condition_opcode_alias_is_normalized(self) -> None:
        materializer = load_module(MATERIALIZER_PATH, "qemu_v2_ptc_condition_ptc_op_test")
        inst = condition_inst("PTC_OP_SETCOND_I32", ["dst", "lhs", "rhs", "0xa"])

        lowering = materializer.lower_to_legacy_ptc(inst)

        self.assertEqual(lowering, "setcond_i32 condition 0xa->0x4")
        self.assertEqual(inst["ptc_list_model"]["opc"], "setcond_i32")
        self.assertEqual(inst["args"][3], "4")

        unchanged_condition = condition_inst("PTC_OP_SETCOND_I32", ["dst", "lhs", "rhs", "8"])
        lowering = materializer.lower_to_legacy_ptc(unchanged_condition)

        self.assertEqual(lowering, "setcond_i32 condition 0x8->0x8")
        self.assertEqual(unchanged_condition["ptc_list_model"]["opc"], "setcond_i32")
        self.assertEqual(unchanged_condition["args"][3], "8")

    def test_brcond_i64_tsteq_materializes_and_compare_to_zero(self) -> None:
        sidecar_model, payload = self.materialize_brcond_i64("0xc")

        self.assertEqual(sidecar_model["summary"]["instruction_count"], 3)
        self.assertEqual(sidecar_model["summary"]["temp_count"], 5)
        self.assertEqual(sidecar_model["summary"]["total_temps"], 5)
        self.assertIn("temp_count=5", payload)
        self.assertIn("total_temps=5", payload)

        and_inst = sidecar_model["instructions"][1]
        brcond_inst = sidecar_model["instructions"][2]
        self.assertEqual(and_inst["ptc_list_model"]["opc"], "and_i64")
        self.assertEqual(and_inst["args"], ["3", "1", "2"])
        self.assertEqual(brcond_inst["ptc_list_model"]["opc"], "brcond_i64")
        self.assertEqual(brcond_inst["args"], ["3", "4", "8", "0x400"])

        tmp_temp = sidecar_model["temps"][3]
        self.assertTrue(tmp_temp["ptc_temp_model"]["temp_allocated"])
        zero_temp = sidecar_model["temps"][4]
        self.assertEqual(zero_temp["ptc_temp_model"]["val_type"], 3)
        self.assertEqual(zero_temp["ptc_temp_model"]["base_type"], 1)
        self.assertEqual(zero_temp["ptc_temp_model"]["type"], 1)
        self.assertEqual(zero_temp["ptc_temp_model"]["val"], 0)
        self.assertTrue(zero_temp["ptc_temp_model"]["temp_allocated"])
        self.assertIn("|and_i64|0|0|3|3,1,2", payload)
        self.assertIn("|brcond_i64|0|0|4|3,4,8,0x400", payload)

    def test_brcond_i64_tstne_materializes_ne_compare_to_zero(self) -> None:
        sidecar_model, payload = self.materialize_brcond_i64("0xd")

        self.assertEqual(sidecar_model["instructions"][1]["ptc_list_model"]["opc"], "and_i64")
        self.assertEqual(sidecar_model["instructions"][2]["args"], ["3", "4", "9", "0x400"])
        self.assertIn("|brcond_i64|0|0|4|3,4,9,0x400", payload)

    def test_setcond_i64_tsteq_materializes_and_compare_to_zero(self) -> None:
        sidecar_model, payload = self.materialize_setcond_i64("0xc")

        self.assertEqual(sidecar_model["summary"]["instruction_count"], 3)
        self.assertEqual(sidecar_model["summary"]["temp_count"], 6)
        self.assertEqual(sidecar_model["summary"]["total_temps"], 6)

        and_inst = sidecar_model["instructions"][1]
        setcond_inst = sidecar_model["instructions"][2]
        self.assertEqual(and_inst["ptc_list_model"]["opc"], "and_i64")
        self.assertEqual(and_inst["args"], ["4", "2", "3"])
        self.assertEqual(setcond_inst["ptc_list_model"]["opc"], "setcond_i64")
        self.assertEqual(setcond_inst["args"], ["1", "4", "5", "8"])

        tmp_temp = sidecar_model["temps"][4]
        zero_temp = sidecar_model["temps"][5]
        self.assertTrue(tmp_temp["ptc_temp_model"]["temp_allocated"])
        self.assertTrue(zero_temp["ptc_temp_model"]["temp_allocated"])
        self.assertEqual(zero_temp["ptc_temp_model"]["val_type"], 3)
        self.assertEqual(zero_temp["ptc_temp_model"]["val"], 0)
        self.assertIn("|and_i64|0|0|3|4,2,3", payload)
        self.assertIn("|setcond_i64|0|0|4|1,4,5,8", payload)

    def test_setcond_i64_tstne_materializes_ne_compare_to_zero(self) -> None:
        sidecar_model, payload = self.materialize_setcond_i64("0xd")

        self.assertEqual(sidecar_model["instructions"][1]["ptc_list_model"]["opc"], "and_i64")
        self.assertEqual(sidecar_model["instructions"][2]["args"], ["1", "4", "5", "9"])
        self.assertIn("|setcond_i64|0|0|4|1,4,5,9", payload)

    def test_movcond_i64_tsteq_materializes_and_compare_to_zero(self) -> None:
        sidecar_model, payload = self.materialize_movcond_i64("0xc")

        self.assertEqual(sidecar_model["summary"]["instruction_count"], 3)
        self.assertEqual(sidecar_model["summary"]["temp_count"], 8)
        self.assertEqual(sidecar_model["summary"]["total_temps"], 8)

        and_inst = sidecar_model["instructions"][1]
        movcond_inst = sidecar_model["instructions"][2]
        self.assertEqual(and_inst["ptc_list_model"]["opc"], "and_i64")
        self.assertEqual(and_inst["args"], ["6", "2", "3"])
        self.assertEqual(movcond_inst["ptc_list_model"]["opc"], "movcond_i64")
        self.assertEqual(movcond_inst["args"], ["1", "6", "7", "4", "5", "8"])

        tmp_temp = sidecar_model["temps"][6]
        zero_temp = sidecar_model["temps"][7]
        self.assertTrue(tmp_temp["ptc_temp_model"]["temp_allocated"])
        self.assertTrue(zero_temp["ptc_temp_model"]["temp_allocated"])
        self.assertEqual(zero_temp["ptc_temp_model"]["val_type"], 3)
        self.assertEqual(zero_temp["ptc_temp_model"]["val"], 0)
        self.assertIn("|and_i64|0|0|3|6,2,3", payload)
        self.assertIn("|movcond_i64|0|0|6|1,6,7,4,5,8", payload)

    def test_movcond_i64_tstne_materializes_ne_compare_to_zero(self) -> None:
        sidecar_model, payload = self.materialize_movcond_i64("0xd")

        self.assertEqual(sidecar_model["instructions"][1]["ptc_list_model"]["opc"], "and_i64")
        self.assertEqual(sidecar_model["instructions"][2]["args"], ["1", "6", "7", "4", "5", "9"])
        self.assertIn("|movcond_i64|0|0|6|1,6,7,4,5,9", payload)

    def test_qemu_v2_call_param1_param2_materializes_legacy_callo_calli(self) -> None:
        sidecar_model, payload = self.materialize_bzip_shaped_call()

        call_inst = sidecar_model["instructions"][1]
        self.assertEqual(call_inst["ptc_list_model"]["opc"], "call")
        self.assertEqual(call_inst["ptc_list_model"]["callo"], 1)
        self.assertEqual(call_inst["ptc_list_model"]["calli"], 4)
        self.assertEqual(call_inst["ptc_list_model"]["argument_count"], 7)
        self.assertFalse(call_inst["ptc_list_model"]["not_real_abi"])
        self.assertEqual(
            call_inst["args"],
            ["1", "2", "3", "4", "5", "0x57eee9f8a0b0", "0x57eeea143ac0"],
        )
        self.assertEqual(call_inst["materializer"]["call_lowering"]["func_arg_index"], 5)
        self.assertEqual(call_inst["materializer"]["call_lowering"]["info_arg_index"], 6)
        self.assertEqual(
            call_inst["materializer"]["helper_def"],
            {"func": "0x57eee9f8a0b0", "name": "cc_compute_all", "flags": 3},
        )
        self.assertEqual(
            sidecar_model["helper_defs"],
            [
                {
                    "flags": 3,
                    "func": "0x57eee9f8a0b0",
                    "info": "0x57eeea143ac0",
                    "name": "cc_compute_all",
                    "source_index": 1,
                    "source_instruction_index": 1,
                }
            ],
        )

        expected = "instruction|1|call|1|4|7|1,2,3,4,5,0x57eee9f8a0b0,0x57eeea143ac0"
        self.assertIn(expected, payload)
        self.assertIn("helper|0x57eee9f8a0b0|cc_compute_all|3", payload)
        self.assertNotIn("call|0|0|7|1,2,3,4,5,0x57eee9f8a0b0,0x57eeea143ac0", payload)

    def test_live_sidecar_c_helper_defs_use_sidecar_model_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            model_path = self.write_bzip_shaped_call_model(root)
            materialized_root = root / "materialized"
            subprocess.run(
                [
                    sys.executable,
                    str(MATERIALIZER_PATH),
                    "--model-json",
                    str(model_path),
                    "--output-root",
                    str(materialized_root),
                    "--captured-pc",
                    "0x408764",
                    "--canonical-pc",
                    "0x408764",
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            fake_qemu = root / "fake-qemu"
            fake_qemu.mkdir()
            (fake_qemu / "meson.build").write_text("# fake for unit test\n", encoding="utf-8")
            (fake_qemu / "VERSION").write_text("10.2.3\n", encoding="utf-8")
            configure = fake_qemu / "configure"
            configure.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            configure.chmod(0o755)

            smoke_root = root / "smoke"
            subprocess.run(
                [
                    "bash",
                    str(LIVE_SIDECAR_SMOKE_PATH),
                    "--scratch-root",
                    str(smoke_root),
                    "--qemu-src",
                    str(fake_qemu),
                    "--payload-source",
                    str(materialized_root / "sidecar" / "sidecar.payload.txt"),
                    "--model-source",
                    str(materialized_root / "sidecar" / "sidecar.model.json"),
                    "--summary-source",
                    str(materialized_root / "sidecar" / "sidecar.summary.json"),
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=60,
            )

            lib_c = (smoke_root / "qemu_v2_ptc_live_sidecar_translate_lib.c").read_text(encoding="utf-8")
            self.assertIn('(void *)(uintptr_t)UINT64_C(0x57eee9f8a0b0), "cc_compute_all", 3u', lib_c)
            self.assertIn("#define PTC_LIVE_SIDECAR_HELPER_CAPACITY 256u", lib_c)
            self.assertIn("ptc_register_payload_helper", lib_c)
            self.assertIn("result.helper_defs_size = PTC_LIVE_SIDECAR_HELPER_CAPACITY;", lib_c)
            self.assertNotIn('{ NULL, "ptc_live_sidecar_helper_table", 0u }', lib_c)

    def test_negsetcond_i64_materializes_setcond_then_neg(self) -> None:
        materializer = load_module(MATERIALIZER_PATH, "qemu_v2_ptc_negsetcond_test")
        selected_temps = [
            materializer.materializer_temp_record(0, "env", 1, 0, None),
            materializer.materializer_temp_record(1, "dst", 1, 0, None),
            materializer.materializer_temp_record(2, "lhs", 1, 0, None),
            materializer.materializer_temp_record(3, "rhs", 1, 0, None),
        ]
        inst = {
            "index": 8,
            "source_index": 20,
            "walker": {
                "name": "negsetcond",
                "canonical_name": "negsetcond",
                "param1_decoded": {"abi": "i64"},
            },
            "ptc_list_model": {
                "opc": None,
                "argument_count": 4,
                "not_real_abi": True,
            },
            "args": ["1", "2", "3", "0xa"],
        }

        expanded, lowering = materializer.expand_qemu_v2_negsetcond(inst, selected_temps)

        self.assertEqual(lowering, "negsetcond_i64->setcond_i64+neg_i64")
        self.assertEqual([item["ptc_list_model"]["opc"] for item in expanded], ["setcond_i64", "neg_i64"])
        self.assertEqual(expanded[0]["args"], ["4", "2", "3", "4"])
        self.assertEqual(expanded[1]["args"], ["1", "4"])

    def materialize_brcond_i64(self, condition: str) -> tuple[dict, str]:
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
                                    "tb_pc": "0x1000",
                                },
                                "ptc_list_model": {
                                    "opc": "debug_insn_start",
                                    "argument_count": 1,
                                    "callo": None,
                                    "calli": None,
                                },
                                "args": ["0x1000"],
                                "decision": {"emitted": True},
                            },
                            {
                                "index": 1,
                                "walker": {
                                    "name": "brcond_i64",
                                    "canonical_name": "brcond_i64",
                                    "tb_pc": "0x1000",
                                },
                                "ptc_list_model": {
                                    "opc": "brcond_i64",
                                    "argument_count": 4,
                                    "callo": None,
                                    "calli": None,
                                },
                                "args": ["lhs_arg", "rhs_arg", condition, "0x400"],
                                "decision": {"emitted": True},
                            },
                        ],
                        "temps": [
                            temp_record(0, "env", "env_arg", is_global=True),
                            temp_record(1, "lhs", "lhs_arg"),
                            temp_record(2, "rhs", "rhs_arg"),
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
            return sidecar_model, payload

    def materialize_bzip_shaped_call(self) -> tuple[dict, str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            model_path = self.write_bzip_shaped_call_model(root)
            output_root = root / "out"

            subprocess.run(
                [
                    sys.executable,
                    str(MATERIALIZER_PATH),
                    "--model-json",
                    str(model_path),
                    "--output-root",
                    str(output_root),
                    "--captured-pc",
                    "0x408764",
                    "--canonical-pc",
                    "0x408764",
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            sidecar_model = json.loads((output_root / "sidecar" / "sidecar.model.json").read_text(encoding="utf-8"))
            payload = (output_root / "sidecar" / "sidecar.payload.txt").read_text(encoding="utf-8")
            return sidecar_model, payload

    def materialize_movcond_i64(self, condition: str) -> tuple[dict, str]:
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
                                    "tb_pc": "0x2000",
                                },
                                "ptc_list_model": {
                                    "opc": "debug_insn_start",
                                    "argument_count": 1,
                                    "callo": None,
                                    "calli": None,
                                },
                                "args": ["0x2000"],
                                "decision": {"emitted": True},
                            },
                            {
                                "index": 1,
                                "walker": {
                                    "name": "movcond_i64",
                                    "canonical_name": "movcond_i64",
                                    "tb_pc": "0x2000",
                                },
                                "ptc_list_model": {
                                    "opc": "movcond_i64",
                                    "argument_count": 6,
                                    "callo": None,
                                    "calli": None,
                                },
                                "args": ["dst_arg", "lhs_arg", "rhs_arg", "iftrue_arg", "iffalse_arg", condition],
                                "decision": {"emitted": True},
                            },
                        ],
                        "temps": [
                            temp_record(0, "env", "env_arg", is_global=True),
                            temp_record(1, "dst", "dst_arg"),
                            temp_record(2, "lhs", "lhs_arg"),
                            temp_record(3, "rhs", "rhs_arg"),
                            temp_record(4, "iftrue", "iftrue_arg"),
                            temp_record(5, "iffalse", "iffalse_arg"),
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
                    "0x2000",
                    "--canonical-pc",
                    "0x2000",
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            sidecar_model = json.loads((output_root / "sidecar" / "sidecar.model.json").read_text(encoding="utf-8"))
            payload = (output_root / "sidecar" / "sidecar.payload.txt").read_text(encoding="utf-8")
            return sidecar_model, payload

    def materialize_setcond_i64(self, condition: str) -> tuple[dict, str]:
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
                                    "tb_pc": "0x3000",
                                },
                                "ptc_list_model": {
                                    "opc": "debug_insn_start",
                                    "argument_count": 1,
                                    "callo": None,
                                    "calli": None,
                                },
                                "args": ["0x3000"],
                                "decision": {"emitted": True},
                            },
                            {
                                "index": 1,
                                "walker": {
                                    "name": "setcond_i64",
                                    "canonical_name": "setcond_i64",
                                    "tb_pc": "0x3000",
                                },
                                "ptc_list_model": {
                                    "opc": "setcond_i64",
                                    "argument_count": 4,
                                    "callo": None,
                                    "calli": None,
                                },
                                "args": ["dst_arg", "lhs_arg", "rhs_arg", condition],
                                "decision": {"emitted": True},
                            },
                        ],
                        "temps": [
                            temp_record(0, "env", "env_arg", is_global=True),
                            temp_record(1, "dst", "dst_arg"),
                            temp_record(2, "lhs", "lhs_arg"),
                            temp_record(3, "rhs", "rhs_arg"),
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
                    "0x3000",
                    "--canonical-pc",
                    "0x3000",
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            sidecar_model = json.loads((output_root / "sidecar" / "sidecar.model.json").read_text(encoding="utf-8"))
            payload = (output_root / "sidecar" / "sidecar.payload.txt").read_text(encoding="utf-8")
            return sidecar_model, payload

    def write_bzip_shaped_call_model(self, root: Path) -> Path:
        model_path = root / "model.json"
        model_path.write_text(
            json.dumps(
                {
                    "instructions": [
                        {
                            "index": 0,
                            "walker": {
                                "name": "insn_start",
                                "canonical_name": "insn_start",
                                "tb_pc": "0x408764",
                            },
                            "ptc_list_model": {
                                "opc": "debug_insn_start",
                                "argument_count": 1,
                                "callo": None,
                                "calli": None,
                            },
                            "args": ["0x408764"],
                            "decision": {"emitted": True},
                        },
                        {
                            "index": 1,
                            "walker": {
                                "name": "call",
                                "canonical_name": "call",
                                "tb_pc": "0x408764",
                                "param1": 4,
                                "param2": 1,
                                "call_helper": {
                                    "func": "0x57eee9f8a0b0",
                                    "info": "0x57eeea143ac0",
                                    "name": "cc_compute_all",
                                    "flags": 3,
                                },
                            },
                            "ptc_list_model": {
                                "opc": "call",
                                "argument_count": 7,
                                "callo": 0,
                                "calli": 0,
                                "not_real_abi": True,
                            },
                            "args": [
                                "ret_arg",
                                "cc_dst_arg",
                                "cc_src_arg",
                                "cc_src2_arg",
                                "cc_op_arg",
                                "0x57eee9f8a0b0",
                                "0x57eeea143ac0",
                            ],
                            "decision": {"emitted": True},
                        },
                    ],
                    "temps": [
                        temp_record(0, "env", "env_arg", is_global=True),
                        temp_record(1, "ret", "ret_arg"),
                        temp_record(2, "cc_dst", "cc_dst_arg"),
                        temp_record(3, "cc_src", "cc_src_arg"),
                        temp_record(4, "cc_src2", "cc_src2_arg"),
                        temp_record(5, "cc_op", "cc_op_arg"),
                    ],
                }
            ),
            encoding="utf-8",
        )
        return model_path


if __name__ == "__main__":
    unittest.main()
