import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "libcrypto_bench_paths.py"


def load_module():
    spec = importlib.util.spec_from_file_location("libcrypto_bench_paths", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class LibcryptoBenchPathsTests(unittest.TestCase):
    def test_parse_text_start_from_readelf_output(self):
        module = load_module()
        output = """
  [11] .init             PROGBITS        00000000000ce5c0 0ce5c0 00001c 00  AX  0   0  4
  [12] .plt              PROGBITS        00000000000ce5e0 0ce5e0 000990 10  AX  0   0 16
  [13] .text             PROGBITS        00000000000cef80 0cef80 2e306e 00  AX  0   0 64
"""

        self.assertEqual(module.parse_text_start_from_readelf_output(output), 0xCEF80)

    def test_parse_text_start_from_readelf_output_raises_when_missing(self):
        module = load_module()

        with self.assertRaises(RuntimeError):
            module.parse_text_start_from_readelf_output("[ 1] .data PROGBITS 00000000 000000 000000 00 WA 0 0 1")

    def test_build_parser_supports_text_start_kind(self):
        module = load_module()
        parser = module.build_parser()

        args = parser.parse_args(["text-start"])

        self.assertEqual(args.kind, "text-start")
