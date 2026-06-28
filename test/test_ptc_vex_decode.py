import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
QEMU_ROOT = REPO_ROOT / "archive" / "qemu-legacy-2.4.50"
HARNESS_SOURCE = REPO_ROOT / "test" / "ptc_disassemble_bytes_harness.c"
TRANSLATE_HARNESS_SOURCE = REPO_ROOT / "test" / "ptc_translate_pc_harness.c"
LL_COMMENT_RE = re.compile(r"^\s*;\s*(0x[0-9a-fA-F]+):\s+(\S+)")


def _first_existing(candidates):
    for candidate in candidates:
        if not candidate:
            continue
        path = Path(candidate)
        if path.exists():
            return path
    return None


class PTCVexDecodeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.compiler = shutil.which(os.environ.get("CC", "")) or shutil.which("cc") or shutil.which("gcc")
        cls.libtinycode = _first_existing(
            [
                os.environ.get("PTC_LIBTINYCODE"),
                REPO_ROOT / "root" / "lib" / "libtinycode-x86_64.so",
            ]
        )

    def _require_compiler(self) -> str:
        if not self.compiler:
            self.skipTest("missing C compiler")
        return self.compiler

    def _require_libtinycode(self) -> Path:
        if self.libtinycode is None:
            self.skipTest("missing libtinycode-x86_64.so; set PTC_LIBTINYCODE")
        return self.libtinycode

    def _build_harness(self, source: Path, tmpdir: Path, output_name: str) -> Path:
        compiler = self._require_compiler()
        libtinycode = self._require_libtinycode()
        binary = tmpdir / output_name
        libdir = libtinycode.parent
        subprocess.run(
            [
                compiler,
                "-D_GNU_SOURCE",
                "-std=c99",
                "-I",
                str(QEMU_ROOT),
                "-I",
                str(QEMU_ROOT / "include"),
                "-I",
                str(QEMU_ROOT / "linux-user"),
                "-I",
                str(QEMU_ROOT / "tcg"),
                str(source),
                "-L",
                str(libdir),
                f"-Wl,-rpath,{libdir}",
                "-ltinycode-x86_64",
                "-ldl",
                "-o",
                str(binary),
            ],
            cwd=str(REPO_ROOT),
            check=True,
        )
        return binary

    def _build_disassemble_harness(self, tmpdir: Path) -> Path:
        return self._build_harness(HARNESS_SOURCE, tmpdir, "ptc-disassemble-bytes")

    def _build_translate_harness(self, tmpdir: Path) -> Path:
        return self._build_harness(TRANSLATE_HARNESS_SOURCE, tmpdir, "ptc-translate-pc")

    def _run_harness(self, binary: Path, byte_string: str):
        libtinycode = self._require_libtinycode()
        env = os.environ.copy()
        env["LD_LIBRARY_PATH"] = (
            str(libtinycode.parent)
            + (f":{env['LD_LIBRARY_PATH']}" if env.get("LD_LIBRARY_PATH") else "")
        )
        result = subprocess.run(
            [str(binary), byte_string, "2"],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            env=env,
        )
        lines = [line for line in result.stdout.splitlines() if line.strip()]
        self.assertTrue(lines, result.stdout)
        count = int(lines[0].split("=", 1)[1])
        asm_line = lines[1] if len(lines) > 1 else ""
        return count, asm_line

    def _run_translate_harness(self, binary: Path, probe: Path, *, single_shot: bool = False):
        libtinycode = self._require_libtinycode()
        env = os.environ.copy()
        env["LD_LIBRARY_PATH"] = (
            str(libtinycode.parent)
            + (f":{env['LD_LIBRARY_PATH']}" if env.get("LD_LIBRARY_PATH") else "")
        )
        argv = [str(binary), str(probe)]
        if single_shot:
            argv.append("single-shot")
        result = subprocess.run(
            argv,
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            env=env,
            check=True,
        )
        pcs = []
        consumed = None
        for line in result.stdout.splitlines():
            if line.startswith("consumed="):
                consumed = int(line.split("=", 1)[1], 0)
            elif line.startswith("pc="):
                pcs.append(int(line.split("=", 1)[1], 16))
        self.assertIsNotNone(consumed, result.stdout)
        self.assertTrue(pcs, result.stdout)
        return consumed, pcs

    def _compile_probe_binary(self, tmpdir: Path, byte_strings) -> Path:
        compiler = self._require_compiler()
        asm = tmpdir / "probe.S"
        binary = tmpdir / "probe.bin"
        asm_lines = [".text", ".globl _start", "_start:"]
        for byte_string in byte_strings:
            raw_bytes = ",".join(f"0x{token}" for token in byte_string.split())
            asm_lines.append(f"  .byte {raw_bytes}")
        asm_lines.extend(
            [
                "  mov $60, %rax",
                "  xor %rdi, %rdi",
                "  syscall",
            ]
        )
        asm.write_text("\n".join(asm_lines) + "\n", encoding="utf-8")
        subprocess.run(
            [
                compiler,
                "-nostdlib",
                "-static",
                "-Wl,-e,_start",
                str(asm),
                "-o",
                str(binary),
            ],
            cwd=str(REPO_ROOT),
            check=True,
        )
        return binary

    def _parse_ll_instructions(self, ll_path: Path):
        instructions = []
        for line in ll_path.read_text(encoding="utf-8", errors="ignore").splitlines():
            match = LL_COMMENT_RE.match(line)
            if match is None:
                continue
            instructions.append((int(match.group(1), 16), match.group(2)))
        return instructions

    def test_ptc_disassemble_bytes_vex_cases(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            harness = self._build_disassemble_harness(Path(tmp))
            cases = [
                ("c5 f8 77", "vzeroupper", 3),
                ("c5 7a 6f 57 80", "vmovdqu", 5),
                ("c4 e3 71 44 c2 00", "vpclmul", 6),
                ("c4 e2 71 dc c2", "vaesenc", 5),
                ("62 f1 7d 28 ef c0", "vpxord", 6),
                ("62 f1 fd 28 6f c8", "vmovdqa64", 6),
                ("f3 0f 1e fa", "endbr64", 4),
                ("c5 f8 90 ca", "kmovw", 4),
                ("c5 f8 93 d1", "kmovw", 4),
                ("c5 f8 92 d9", "kmovw", 4),
                ("c5 79 93 f1", "kmovb", 4),
                ("c4 c1 79 92 ce", "kmovb", 5),
            ]
            for byte_string, expected_mnemonic, expected_size in cases:
                with self.subTest(byte_string=byte_string):
                    count, asm_line = self._run_harness(harness, byte_string)
                    self.assertEqual(count, expected_size, asm_line)
                    self.assertIn(expected_mnemonic, asm_line.lower(), asm_line)

    def test_ptc_translate_keeps_pc_advance_for_extended_vector_cases(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = Path(tmp)
            harness = self._build_translate_harness(tmpdir)
            cases = [
                ("f3 0f 1e fa", "endbr64", 4),
                ("c5 f8 77", "vzeroupper", 3),
                ("c5 7a 6f 57 80", "vmovdqu", 5),
                ("c4 e3 71 44 c2 00", "vpclmul", 6),
                ("c4 e2 71 dc c2", "vaesenc", 5),
                ("62 f1 7d 28 ef c0", "vpxord", 6),
                ("62 f1 fd 28 6f c8", "vmovdqa64", 6),
                ("c5 f8 90 ca", "kmovw", 4),
                ("c5 79 93 f1", "kmovb", 4),
                ("c4 c1 79 92 ce", "kmovb", 5),
            ]
            binary = self._compile_probe_binary(tmpdir, [byte_string for byte_string, _, _ in cases])
            consumed, pcs = self._run_translate_harness(harness, binary)

            expected_sizes = [expected_size for _, _, expected_size in cases]
            self.assertGreaterEqual(len(pcs), len(expected_sizes), pcs)
            self.assertGreaterEqual(consumed, sum(expected_sizes), consumed)
            self.assertEqual(
                [right - left for left, right in zip(pcs, pcs[1:len(expected_sizes)])],
                expected_sizes[:-1],
                pcs,
            )

    def test_ptc_translate_keeps_real_libcrypto_vex_sequence_in_one_tb(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = Path(tmp)
            harness = self._build_translate_harness(tmpdir)
            cases = [
                ("c5 fc 77", "vzeroall", 3),
                ("49 89 fc", "mov", 3),
                ("48 8d b9 80 00 00 00", "lea", 7),
                ("4c 8d 2d 04 4e 30 00", "lea", 7),
                ("44 8b 77 70", "mov", 4),
                ("4d 89 cf", "mov", 3),
                ("4c 89 d6", "mov", 3),
                ("c4 41 7a 6f 00", "vmovdqu", 5),
                ("49 83 ee 09", "sub", 4),
                ("41 8b 07", "mov", 3),
                ("41 8b 5f 04", "mov", 4),
                ("41 8b 4f 08", "mov", 4),
                ("41 8b 57 0c", "mov", 4),
                ("45 8b 47 10", "mov", 4),
                ("45 8b 4f 14", "mov", 4),
                ("45 8b 57 18", "mov", 4),
                ("45 8b 5f 1c", "mov", 4),
                ("c4 01 79 6f 74 f5 00", "vmovdqa", 7),
                ("c4 01 79 6f 6c f5 10", "vmovdqa", 7),
                ("c4 01 79 6f 64 f5 20", "vmovdqa", 7),
                ("c5 7a 6f 57 80", "vmovdqu", 5),
                ("c5 f9 6f 3d 88 4d 30 00", "vmovdqa", 8),
            ]
            binary = self._compile_probe_binary(tmpdir, [byte_string for byte_string, _, _ in cases])
            consumed, pcs = self._run_translate_harness(harness, binary, single_shot=True)

            expected_sizes = [expected_size for _, _, expected_size in cases]
            self.assertGreaterEqual(len(pcs), len(expected_sizes), pcs)
            self.assertGreaterEqual(consumed, sum(expected_sizes), consumed)
            self.assertEqual(
                [right - left for left, right in zip(pcs, pcs[1:len(expected_sizes)])],
                expected_sizes[:-1],
                pcs,
            )

    def test_ptc_translate_keeps_real_libcrypto_vzeroupper_sequence_in_one_tb(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = Path(tmp)
            harness = self._build_translate_harness(tmpdir)
            cases = [
                ("c5 f8 77", "vzeroupper", 3),
                ("c5 7a 6f 3e", "vmovdqu", 4),
                ("48 8d 76 78", "lea", 4),
                ("48 8d bf a0 00 00 00", "lea", 7),
                ("d1 ea", "shr", 2),
                ("31 d2", "xor", 2),
                ("8b 8f 70 ff ff ff", "mov", 6),
                ("4c 8b 87 60 ff ff ff", "mov", 7),
                ("39 d1", "cmp", 2),
            ]
            binary = self._compile_probe_binary(tmpdir, [byte_string for byte_string, _, _ in cases])
            consumed, pcs = self._run_translate_harness(harness, binary, single_shot=True)

            expected_sizes = [expected_size for _, _, expected_size in cases]
            self.assertGreaterEqual(len(pcs), len(expected_sizes), pcs)
            self.assertGreaterEqual(consumed, sum(expected_sizes), consumed)
            self.assertEqual(
                [right - left for left, right in zip(pcs, pcs[1:len(expected_sizes)])],
                expected_sizes[:-1],
                pcs,
            )

    def test_ptc_translate_keeps_real_libcrypto_avx512_evex_prefix_in_one_tb(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = Path(tmp)
            harness = self._build_translate_harness(tmpdir)
            cases = [
                ("62 f1 fd 48 ef c0", "vpxorq", 6),
                ("62 f1 fd 48 6f c8", "vmovdqa64", 6),
                ("62 f1 fe 48 7f 0d ea 0f 00 00", "vmovdqu64", 10),
                ("62 f1 fe 48 6f 15 e0 0f 00 00", "vmovdqu64", 10),
                ("62 f2 6d 48 00 da", "vpshufb", 6),
                ("62 f1 65 48 fe e2", "vpaddd", 6),
                ("62 f3 dd 48 25 eb 96", "vpternlogq", 7),
                ("62 f3 55 48 44 f4 00", "vpclmullqlqdq", 7),
                ("62 f3 55 48 44 fc 10", "vpclmullqhqdq", 7),
                ("62 73 55 48 44 c4 01", "vpclmulhqlqdq", 7),
            ]
            binary = self._compile_probe_binary(tmpdir, [byte_string for byte_string, _, _ in cases])
            consumed, pcs = self._run_translate_harness(harness, binary, single_shot=True)

            expected_sizes = [expected_size for _, _, expected_size in cases]
            self.assertGreaterEqual(len(pcs), len(expected_sizes), pcs)
            self.assertGreaterEqual(consumed, sum(expected_sizes), consumed)
            self.assertEqual(
                [right - left for left, right in zip(pcs, pcs[1:len(expected_sizes)])],
                expected_sizes[:-1],
                pcs,
            )

    def test_ptc_translate_keeps_real_libcrypto_avx512_evex_tail_in_one_tb(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = Path(tmp)
            harness = self._build_translate_harness(tmpdir)
            cases = [
                ("62 73 55 48 44 cc 11", "vpclmulhqhqdq", 7),
                ("62 52 35 48 dc d0", "vaesenc", 6),
                ("62 72 2d 48 dd df", "vaesenclast", 6),
                ("62 72 fd 48 1a 25 9b 0f 00 00", "vbroadcastf64x2", 10),
                ("62 d1 15 48 73 fc 04", "vpslldq", 7),
                ("62 d1 0d 48 73 dd 04", "vpsrldq", 7),
                ("62 53 7d 48 39 f7 01", "vextracti32x4", 7),
                ("62 33 fd 48 3b f0 01", "vextracti64x4", 7),
                ("62 71 7f 48 7f 35 75 0f 00 00", "vmovdqu8", 10),
            ]
            binary = self._compile_probe_binary(tmpdir, [byte_string for byte_string, _, _ in cases])
            consumed, pcs = self._run_translate_harness(harness, binary, single_shot=True)

            expected_sizes = [expected_size for _, _, expected_size in cases]
            self.assertGreaterEqual(len(pcs), len(expected_sizes), pcs)
            self.assertGreaterEqual(consumed, sum(expected_sizes), consumed)
            self.assertEqual(
                [right - left for left, right in zip(pcs, pcs[1:len(expected_sizes)])],
                expected_sizes[:-1],
                pcs,
            )


if __name__ == "__main__":
    unittest.main()
