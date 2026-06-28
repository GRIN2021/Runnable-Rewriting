import importlib.util
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MATERIALIZER_PATH = REPO_ROOT / "runnable" / "scripts" / "qemu_v2_ptc_materialize_walker_sidecar.py"
CONVERTER_PATH = REPO_ROOT / "runnable" / "scripts" / "qemu_v2_ptc_convert_walker_jsonl.py"


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class QemuV2PTCSextractLoweringTests(unittest.TestCase):
    def test_converter_canonicalizes_typed_sextract(self) -> None:
        converter = load_module(CONVERTER_PATH, "qemu_v2_ptc_convert_walker_jsonl_test")

        self.assertEqual(
            converter.canonical_name("sextract", {"param1": 1}, converter.DEFAULT_TCG_TYPE_INFO),
            "sextract_i64",
        )
        self.assertEqual(
            converter.canonical_name("sextract", {"param1": 0}, converter.DEFAULT_TCG_TYPE_INFO),
            "sextract_i32",
        )

    def test_materializer_lowers_i64_offset_zero_width_32(self) -> None:
        materializer = load_module(MATERIALIZER_PATH, "qemu_v2_ptc_materialize_walker_sidecar_test")
        inst = {
            "source_index": 4,
            "walker": {
                "name": "sextract",
                "canonical_name": "sextract_i64",
                "param1_decoded": {"abi": "i64"},
            },
            "ptc_list_model": {
                "opc": "PTC_OP_SEXTRACT_I64",
                "argument_count": 4,
                "not_real_abi": True,
            },
            "args": ["7", "9", "0x0", "0x20"],
        }

        lowering = materializer.lower_to_legacy_ptc(inst)

        self.assertEqual(lowering, "sextract_i64(0,32)->ext32s_i64")
        self.assertEqual(inst["ptc_list_model"]["opc"], "ext32s_i64")
        self.assertEqual(inst["ptc_list_model"]["argument_count"], 2)
        self.assertFalse(inst["ptc_list_model"]["not_real_abi"])
        self.assertEqual(inst["args"], ["7", "9"])

    def test_materializer_lowers_extrl_i64_i32_to_mov_i32(self) -> None:
        materializer = load_module(MATERIALIZER_PATH, "qemu_v2_ptc_materialize_walker_sidecar_test_extrl")
        inst = {
            "source_index": 6,
            "walker": {
                "name": "extrl_i64_i32",
                "canonical_name": "extrl_i64_i32",
                "param1_decoded": {"abi": "i32"},
            },
            "ptc_list_model": {
                "opc": None,
                "argument_count": 2,
                "not_real_abi": True,
            },
            "args": ["dst", "src"],
        }

        lowering = materializer.lower_to_legacy_ptc(inst)

        self.assertEqual(lowering, "extrl_i64_i32->mov_i32")
        self.assertEqual(inst["ptc_list_model"]["opc"], "mov_i32")
        self.assertEqual(inst["ptc_list_model"]["argument_count"], 2)
        self.assertFalse(inst["ptc_list_model"]["not_real_abi"])
        self.assertEqual(inst["args"], ["dst", "src"])

    def test_materializer_lowers_extu_i32_i64_to_ext32u_i64(self) -> None:
        materializer = load_module(MATERIALIZER_PATH, "qemu_v2_ptc_materialize_walker_sidecar_test_extu")
        inst = {
            "source_index": 7,
            "walker": {
                "name": "extu_i32_i64",
                "canonical_name": "extu_i32_i64",
                "param1_decoded": {"abi": "i64"},
            },
            "ptc_list_model": {
                "opc": None,
                "argument_count": 2,
                "not_real_abi": True,
            },
            "args": ["dst64", "src32"],
        }

        lowering = materializer.lower_to_legacy_ptc(inst)

        self.assertEqual(lowering, "extu_i32_i64->ext32u_i64")
        self.assertEqual(inst["ptc_list_model"]["opc"], "ext32u_i64")
        self.assertEqual(inst["ptc_list_model"]["argument_count"], 2)
        self.assertFalse(inst["ptc_list_model"]["not_real_abi"])
        self.assertEqual(inst["args"], ["dst64", "src32"])

    def test_materializer_expands_extract_i64_nonzero_offset_to_shift_and_mask(self) -> None:
        materializer = load_module(MATERIALIZER_PATH, "qemu_v2_ptc_materialize_walker_sidecar_test_extract")
        selected_temps = [
            materializer.materializer_temp_record(0, "env", 1, 0, None),
            materializer.materializer_temp_record(1, "dst", 1, 0, None),
            materializer.materializer_temp_record(2, "src", 1, 0, None),
        ]
        inst = {
            "index": 4,
            "source_index": 22,
            "walker": {
                "name": "extract",
                "canonical_name": "extract_i64",
                "param1_decoded": {"abi": "i64"},
            },
            "ptc_list_model": {
                "opc": "PTC_OP_EXTRACT_I64",
                "argument_count": 4,
                "not_real_abi": True,
            },
            "args": ["1", "2", "0x1f", "0x1"],
        }

        expanded, lowering = materializer.expand_qemu_v2_extract_i64(inst, selected_temps, {})

        self.assertEqual(lowering, "extract_i64(31,1)->shr_i64/and_i64")
        self.assertEqual([item["ptc_list_model"]["opc"] for item in expanded], ["shr_i64", "and_i64"])
        self.assertEqual(expanded[0]["args"], ["4", "2", "5"])
        self.assertEqual(expanded[1]["args"], ["1", "4", "3"])
        self.assertEqual(selected_temps[3]["ptc_temp_model"]["val"], 1)
        self.assertEqual(selected_temps[4]["ptc_temp_model"]["val"], None)
        self.assertEqual(selected_temps[5]["ptc_temp_model"]["val"], 31)

    def test_materializer_rejects_nonzero_offset_until_sequence_lowering_exists(self) -> None:
        materializer = load_module(MATERIALIZER_PATH, "qemu_v2_ptc_materialize_walker_sidecar_test_reject")
        inst = {
            "source_index": 5,
            "walker": {
                "name": "sextract",
                "canonical_name": "sextract_i64",
                "param1_decoded": {"abi": "i64"},
            },
            "ptc_list_model": {
                "opc": "PTC_OP_SEXTRACT_I64",
                "argument_count": 4,
                "not_real_abi": True,
            },
            "args": ["7", "9", "0x8", "0x10"],
        }

        with self.assertRaises(SystemExit) as raised:
            materializer.lower_to_legacy_ptc(inst)

        self.assertIn("unsupported bit slice offset=0x8 length=0x10", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
