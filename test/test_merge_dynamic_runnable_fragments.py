import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MERGE_SCRIPT = REPO_ROOT / "runnable" / "scripts" / "merge_dynamic_runnable_fragments.py"
CODEGENERATOR = REPO_ROOT / "runnable" / "tools" / "runnable-lift" / "CodeGenerator.cpp"


def build_module(entry_pc: int, block_pc: int) -> str:
    return f"""\
; ModuleID = 'top'
source_filename = "top"

%22 = type {{ [8 x i64], i32 }}

@pc = global i64 0
@saved_registers = global i64* null
@jmp_buffer = external global [1 x %22]

define void @root(i64) {{
entrypoint:

  ; prelude comment before allocas
  %1 = alloca i64
  store i64 {block_pc + 1}, i64* %1
  store i64 {entry_pc}, i64* @pc
  switch i8 0, label %dispatcher.entry [
    i8 1, label %anypc
    i8 2, label %unexpectedpc
  ]

dispatcher.entry:
  %2 = load i64, i64* @pc
  switch i64 %2, label %dispatcher.external [
    i64 {block_pc}, label %bb.0x{block_pc:x}
  ], !dbg !1

dispatcher.default:
  call void @unknownPC()
  unreachable

anypc:
  br label %dispatcher.entry

unexpectedpc:
  br label %dispatcher.entry

bb.0x{block_pc:x}:
  ; 0x{block_pc:016x}: nop
  %3 = load i64, i64* %1
  store i64 %3, i64* @pc
  br label %dispatcher.entry

serialize_and_jump_out:
  call void asm sideeffect "movq $0, %r11; jmpq *%r11", "*m,~{{dirflag}},~{{fpsr}},~{{flags}}"(i64* @pc)
  unreachable

return_from_external:
  br label %dispatcher.entry

setjmp:
  %4 = call i32 @setjmp(%22* getelementptr inbounds ([1 x %22], [1 x %22]* @jmp_buffer, i32 0, i32 0))
  br label %serialize_and_jump_out

dispatcher.external:
  br label %dispatcher.default
}}

declare void @unknownPC()
declare i32 @setjmp(%22*)
"""


class MergeDynamicRunnableFragmentsTest(unittest.TestCase):
    def test_codegenerator_looks_for_repo_local_merge_helper(self) -> None:
        source = CODEGENERATOR.read_text(encoding="utf-8")
        self.assertIn(
            "runnable/scripts/merge_dynamic_runnable_fragments.py",
            source,
        )
        self.assertIn("/proc/self/exe", source)

    def test_merge_helper_merges_dispatch_cases_from_multiple_modules(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            main_ll = tmp / "main.ll"
            worker_ll = tmp / "worker_401010.ll"
            output_ll = tmp / "merged.ll"
            main_ll.write_text(build_module(0x401000, 0x401000), encoding="utf-8")
            worker_ll.write_text(build_module(0x401000, 0x401010), encoding="utf-8")

            subprocess.run(
                [
                    "python3",
                    str(MERGE_SCRIPT),
                    "--output",
                    str(output_ll),
                    "--entry-pc",
                    "0x401000",
                    str(main_ll),
                    str(worker_ll),
                ],
                check=True,
                cwd=str(REPO_ROOT),
                capture_output=True,
                text=True,
            )

            merged = output_ll.read_text(encoding="utf-8")
            self.assertIn("i64 4198400, label %bb.0x401000", merged)
            self.assertIn("i64 4198416, label %bb.0x401010", merged)
            self.assertIn("bb.0x401000:", merged)
            self.assertIn("bb.0x401010:", merged)
            self.assertIn("%worker_0000000000401010_1_1 = alloca i64", merged)
            self.assertIn("store i64 4198417, i64* %worker_0000000000401010_1_1", merged)
            self.assertIn("@setjmp(%22* getelementptr inbounds ([1 x %22], [1 x %22]* @jmp_buffer", merged)
            self.assertNotIn("@setjmp(%root_22*", merged)


if __name__ == "__main__":
    unittest.main()
