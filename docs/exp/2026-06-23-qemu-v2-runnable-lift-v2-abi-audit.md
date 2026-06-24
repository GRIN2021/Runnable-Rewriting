# runnable-lift PTC v2 ABI Audit

Audit date: 2026-06-23
Scope: read-only audit of `runnable/tools/runnable-lift`

## Context

Existing PTC v2 notes identify modern QEMU 10.2.3 TCG records that cannot be
encoded safely in the legacy `PTCInstructionList` shape:

- v2 scalar opcodes: `extract_i64`, `qemu_ld2`, `qemu_st2`.
- vector schema records: `mov_vec`, `ld_vec`, `st_vec`, with vector size,
  element size, lane count, and vector temp identity.
- modern temp types such as `I128`, `V128`, and `V256` have no legacy
  `PTC_TYPE_I32` / `PTC_TYPE_I64` mapping.

This audit does not implement support. It lists the runnable-lift consumption
points that assume the old opcode, arg, and temp ABI, plus the minimum
compatibility strategy for a later code pass.

## Current PTC Consumption Path

### Library loading

`Main.cpp` owns runtime PTC loading:

- `Main.cpp:124` to `Main.cpp:170`: `findFiles()` searches only
  `libtinycode-<arch>.so`, `libtinycode-helpers-<arch>.ll`, and
  `early-linked-<arch>.ll`.
- `Main.cpp:180` to `Main.cpp:211`: `loadPTCLibrary()` calls `dlopen()`,
  resolves only `ptc_load`, and initializes the global `PTCInterface ptc`.
- `PTCInterface.h:17` to `PTCInterface.h:28`: runnable-lift includes `ptc.h`
  directly under `USE_DYNAMIC_PTC`, aliases `PTCInstructionListPtr` to a
  `unique_ptr` freed by `ptc_instruction_list_free`, and exposes one global
  `PTCInterface ptc`.

There is no ABI version negotiation after `ptc_load()`. A same-named
`libtinycode-x86_64.so` with a changed `PTCInterface`, `PTCInstruction`,
`PTCTemp`, or opcode enum layout would be consumed as legacy ABI.

### Translation entry and instruction list traversal

`CodeGenerator::translate()` is the central list consumer:

- `CodeGenerator.cpp:751` to `CodeGenerator.cpp:767`: constructs
  `VariableManager`, then reads legacy `ptc.pc` and `ptc.sp` env offsets.
- `CodeGenerator.cpp:925` to `CodeGenerator.cpp:928`: dynamic worker mode
  writes concrete GPR values through `ptc.regs`.
- `CodeGenerator.cpp:944` to `CodeGenerator.cpp:953`: creates a
  `PTCInstructionListPtr`; normal traversal calls
  `ptc.translate(VirtualAddress, 1, InstructionList.get(),
  &DynamicVirtualAddress)`, while the `haveBB` branch only calls
  `ptc_instruction_list_malloc()`.
- `CodeGenerator.cpp:984` to `CodeGenerator.cpp:993`: runs
  `InstructionTranslator::preprocess()`, optionally `dumpTranslation()`, and
  passes the list to `VariableManager::newFunction()`.
- `CodeGenerator.cpp:1000` to `CodeGenerator.cpp:1027`: assumes the list is
  non-empty and that `instructions[0]` is the first
  `PTC_INSTRUCTION_op_debug_insn_start`.
- `CodeGenerator.cpp:1030` to `CodeGenerator.cpp:1107`: iterates
  `InstructionList->instructions[j]`, switches only on `discard`,
  `debug_insn_start`, and `call`, and sends every other opcode to
  `InstructionTranslator::translate()`.

The loop directly reads `instruction_count`, `instructions[]`, and
`PTCInstruction::opc`. Empty stubs and unknown v2 opcodes currently reach
assertions or `runnable_unreachable()` paths rather than a controlled
diagnostic.

### Opcode and argument access

`InstructionTranslator.cpp` wraps legacy instruction args, but still uses old
PTC accessors and opcode names:

- `InstructionTranslator.cpp:49` to `InstructionTranslator.cpp:203`: the
  `PTC::InstructionImpl` wrapper builds ranges through
  `ptc_instruction_*_arg_count()`, `ptc_instruction_*_arg()`, and the call
  variants. `opcode()` returns raw `TheInstruction->opc`.
- `InstructionTranslator.cpp:150` to `InstructionTranslator.cpp:156`:
  `pc()` asserts `debug_insn_start` and reads PC from const args.
- `InstructionTranslator.cpp:250` to `InstructionTranslator.cpp:296`:
  `opcodeToBinaryOp()` admits only legacy scalar arithmetic opcodes.
- `InstructionTranslator.cpp:314` to `InstructionTranslator.cpp:440`:
  `getRegisterSize()` maps only legacy i32/i64 scalar opcodes and returns 0
  for control ops. New v2/vector opcodes fall into
  `runnable_unreachable("Unexpected opcode")`.
- `InstructionTranslator.cpp:789` to `InstructionTranslator.cpp:1457`:
  `translateOpcode()` is a legacy scalar switch. `qemu_ld_i32/i64` and
  `qemu_st_i32/i64` are handled, but `qemu_ld2`, `qemu_st2`,
  `extract_i64`, `mov_vec`, `ld_vec`, and `st_vec` are absent.
- `InstructionTranslator.cpp:757`: after translation, the result count is
  asserted equal to the old `OutArguments.size()` value.

For v2 memory ops, the old `qemu_ld/st` handler also assumes a single scalar
address/value shape and a memory access size no wider than 64 bits. It cannot
represent `qemu_ld2` two-output i128 loads or `qemu_st2` paired stores without
an explicit new lowering or native v2 translation path.

### Temp schema access

`VariableManager` is the main `PTCTemp` consumer:

- `VariableManager.cpp:161` to `VariableManager.cpp:257`: constructor asserts
  `ptc.initialized_env != nullptr`, infers the CPU state type from helper IR,
  and logs legacy `ptc.pc`, `ptc.sp`, and `ptc.initialized_env`.
- `VariableManager.cpp:580` to `VariableManager.cpp:607`: stores the current
  `PTCInstructionList *` and clears scalar temporary maps on new function/basic
  block boundaries.
- `VariableManager.cpp:707` to `VariableManager.cpp:765`: `getOrCreate()`
  reads `PTCTemp *Temporary = ptc_temp_get(Instructions, TemporaryId)`, then
  maps `Temporary->type == PTC_TYPE_I32` to LLVM i32 and every other type to
  LLVM i64. It uses legacy `ptc_temp_is_global()`, `fixed_reg`,
  `mem_offset`, `name`, and `temp_local` to choose env globals, other globals,
  local allocas, or transient allocas.

This is not vector-safe. `I128`, `V128`, or `V256` temps would be silently
treated as i64, allocated as scalar integer slots, and later used by scalar
loads/stores. A v2 schema needs an explicit LLVM type mapper and a temp record
that preserves modern type, base type, vector size, and element size.

### Dump and metadata rendering

`PTCDump.cpp` is used for logs and per-instruction metadata:

- `PTCDump.cpp:22` to `PTCDump.cpp:40`: `getTemporaryName()` reads
  `PTCTemp::name`, `temp_local`, and `Instructions->global_temps`.
- `PTCDump.cpp:48` to `PTCDump.cpp:52`: `dumpInstruction()` directly reads
  `Instructions->instructions[Index]`, raw `Instruction.opc`, and
  `ptc_instruction_opcode_def()`.
- `PTCDump.cpp:54` to `PTCDump.cpp:61`: `debug_insn_start` reads
  `Instruction.args[0]` directly instead of using an accessor.
- `PTCDump.cpp:62` to `PTCDump.cpp:107`: call dumping uses the legacy helper
  lookup and legacy call arg packing.
- `PTCDump.cpp:168` to `PTCDump.cpp:209`: special memory formatting only knows
  `qemu_ld_i32/i64` and `qemu_st_i32/i64`.
- `PTCDump.cpp:269` to `PTCDump.cpp:295`: `dumpTranslation()` walks
  `instruction_count` and repeats the direct `debug_insn_start` PC access.

If v2 opcode definitions are not visible through `ptc_instruction_opcode_def()`,
`Definition->name` is unsafe. If vector temps lack legacy temp fields, temp
name formatting becomes misleading or invalid.

### PTCInterface side channels outside PTCInstructionList

Several files consume old `PTCInterface` fields directly. These are not the
primary opcode/vector schema path, but they are ABI compatibility risks:

- `CodeGenerator.cpp:1135` to `CodeGenerator.cpp:1235` reads flags such as
  `isDirectJmp`, `isIndirectJmp`, `isIndirect`, `isRet`, `isIllegal`,
  `isCall`, `exception_syscall`, `syscall_next_eip`, and `regs`.
- `JumpTargetManager.cpp:1708` onward uses `ptc.is_image_addr()`, `ptc.regs`,
  dynamic execution helpers such as `exec2()`, `getBadBlockSize()`,
  `isdecodeblock()`, stack helpers, and multiple flag pointers.
- `PTCInterface.h:94` to `PTCInterface.h:128` hard-codes x86-64 register
  indices and name-like constants.

The minimal opcode/vector lift can be scoped away from these fields only if PTC
v2 preserves the old `PTCInterface` side-channel ABI. If not, these direct
reads need a separate adapter.

## Failure Points Under Empty Stub Or V2 Ops

| Scenario | Current failure mode | Evidence |
|---|---|---|
| Empty `PTCInstructionList` from a stub converter | `CodeGenerator::translate()` reads `InstructionList->instructions[0]` even when `instruction_count == 0` | `CodeGenerator.cpp:1000` to `CodeGenerator.cpp:1024` |
| First instruction is not `debug_insn_start` | `PTC::Instruction::pc()` asserts the opcode is `debug_insn_start` | `InstructionTranslator.cpp:150` to `InstructionTranslator.cpp:156` |
| Unknown scalar v2 opcode, including `extract_i64`, `qemu_ld2`, `qemu_st2` | `getRegisterSize()` or `translateOpcode()` reaches `runnable_unreachable("Unexpected opcode")` / `runnable_unreachable("Unknown opcode")` | `InstructionTranslator.cpp:314` to `InstructionTranslator.cpp:440`, `InstructionTranslator.cpp:1454` to `InstructionTranslator.cpp:1455` |
| Vector opcode `mov_vec`, `ld_vec`, `st_vec` | No register-size, LLVM type, arg schema, or translation case exists | `InstructionTranslator.cpp:789` to `InstructionTranslator.cpp:1457` |
| Vector or i128 temp | `VariableManager::getOrCreate()` maps every non-I32 type to i64 | `VariableManager.cpp:710` to `VariableManager.cpp:712` |
| Vector temp storage | temp maps store `AllocaInst *` for scalar integer slots only | `VariableManager.h:174` to `VariableManager.h:180`, `VariableManager.cpp:742` to `VariableManager.cpp:763` |
| v2 memory op with unknown memory access encoding | old `qemu_ld/st` asserts `MemoryAccess.access_type != PTC_MEMORY_ACCESS_UNKNOWN` and accepts only 8/16/32/64-bit memory types | `InstructionTranslator.cpp:834` to `InstructionTranslator.cpp:867` |
| v2 opcode dump without old opcode def | `PTCDump` dereferences `Definition->name` | `PTCDump.cpp:50` to `PTCDump.cpp:52`, `PTCDump.cpp:79`, `PTCDump.cpp:111` |
| Changed `debug_insn_start` arg layout | both translator and dump read PC from old args layout | `InstructionTranslator.cpp:150` to `InstructionTranslator.cpp:156`, `PTCDump.cpp:54` to `PTCDump.cpp:61` |

## Files And Functions To Modify For PTC v2 Support

| Area | File/function | Required change | Minimum compatible strategy |
|---|---|---|---|
| ABI boundary | `PTCInterface.h` | Isolate direct `ptc.h` dependency and expose feature/version helpers for old vs v2 op/temp schemas | Add a small compatibility facade that compiles with legacy PTC and v2 PTC; old builds report no v2 support |
| Runtime loading | `Main.cpp::loadPTCLibrary()` | Detect ABI version/features after `ptc_load()` | Fail closed with a clear message if a v2 library is loaded but runnable-lift lacks the matching schema |
| Empty list handling | `CodeGenerator::translate()` | Guard `instruction_count == 0` before `instructions[0]` | Treat empty stub as a controlled unsupported translation result, not out-of-bounds memory access |
| Instruction traversal | `CodeGenerator::translate()` | Stop assuming first item and every PC boundary are old `debug_insn_start` records | Validate list invariants before translation; emit diagnostics for malformed or v2-only blocks |
| Arg facade | `InstructionTranslator.cpp` `PTC::InstructionImpl` | Normalize legacy args, v2 scalar args, and vector-schema args behind one accessor layer | Keep current legacy behavior, add explicit v2 argument descriptors rather than reusing raw `args[]` blindly |
| Opcode admission | `InstructionTranslator.cpp::getRegisterSize()` and `translateOpcode()` | Add `extract_i64`, `qemu_ld2`, `qemu_st2`, and vector op admission | Phase in scalar v2 ops first; vector ops may initially return a controlled unsupported error until temp/schema support lands |
| Scalar v2 lowering | `InstructionTranslator.cpp::translateOpcode()` | Implement or reject reviewed semantics for `extract_i64`, `qemu_ld2`, and `qemu_st2` | `extract_i64` can lower to shift/trunc when args are validated; paired qemu ops need explicit i128/pair memory semantics review |
| Temp typing | `VariableManager::{getOrCreate,newFunction,newBasicBlock}` | Replace binary I32/I64 type mapping with a type mapper supporting I128 and LLVM vector types | Add `typeForPTCTemp()` and keep scalar maps intact; vector temps allocate vector-typed slots |
| Env/global temp schema | `VariableManager::getOrCreate()` | Avoid using only `fixed_reg == 0`, `mem_offset`, and `temp_local` for modern temps | Require reliable v2 temp metadata for env-backed globals; reject unmapped vector/I128 globals |
| Dump/log path | `PTCDump.cpp::{dumpInstruction,dumpTranslation,getTemporaryName}` | Dump v2 opcode names, vector schema, and vector temp names safely | If v2 definition/schema is absent, print a diagnostic placeholder instead of dereferencing null or scalarizing |
| Helper/module assumptions | `CodeGenerator.cpp` helper linking and `VariableManager` constructor | Confirm helpers expose CPU state shape compatible with v2 temps and memory helpers | Keep old helper behavior for legacy; reject v2 vector helper needs until helper IR and CPU state accesses are reviewed |
| Side-channel ABI | `CodeGenerator.cpp`, `JumpTargetManager.cpp`, `PTCInterface.h` | Audit `ptc.regs`, flags, and dynamic execution helpers if PTC v2 changes `PTCInterface` | Treat as separate compatibility task unless v2 preserves these fields exactly |

## Minimal Compatibility Plan

1. Add fail-closed ABI detection and empty-list guards before translating v2
   lists. This prevents stubs, unknown opcodes, and vector records from
   crashing through old assumptions.
2. Introduce a PTC instruction/temp accessor facade. Existing code should stop
   reading `Instruction.args[]`, `Instruction.opc`, and `PTCTemp::type`
   directly outside that facade.
3. Support scalar v2 opcodes separately from vector schema. Add validated
   lowering or native translation for `extract_i64`, then decide whether
   `qemu_ld2/qemu_st2` lower to paired 64-bit ops or require native i128/pair
   memory support.
4. Add explicit vector temp and vector operand schema support. `mov_vec`,
   `ld_vec`, and `st_vec` require LLVM vector types plus schema fields for
   vector size, element size, lane count, and whole-vector temp identity.
5. Update dump/metadata paths after the translator facade exists, so logs and
   `pi` metadata preserve v2 op/schema evidence instead of pretending vector
   operations are old scalar ops.
6. Add regression fixtures for empty list, unknown opcode, `extract_i64`,
   `qemu_ld2`, `qemu_st2`, `mov_vec`, `ld_vec`, and `st_vec`.

## Suggested Next Runnable-Lift Tasks

1. `runnable-lift-abi-guard`: add ABI version/feature detection, empty list
   guard, and controlled diagnostics for unsupported v2 records.
2. `runnable-lift-ptc-accessor-facade`: centralize opcode, arg, temp, and debug
   PC access; remove direct `Instruction.args[]` and raw `PTCTemp::type` reads
   from translator/dump paths.
3. `runnable-lift-scalar-v2-opcodes`: implement or explicitly reject
   `extract_i64`, `qemu_ld2`, and `qemu_st2` with tests for result arity and
   memory semantics.
4. `runnable-lift-vector-temp-schema`: add LLVM type mapping and allocation for
   I128/V128/V256 temps plus vector schema validation.
5. `runnable-lift-vector-op-translation`: implement `mov_vec`, `ld_vec`, and
   `st_vec` once vector temp/schema support is available.
6. `runnable-lift-ptc-side-channel-audit`: separately verify `ptc.regs`,
   dynamic execution flags, syscall fields, and `JumpTargetManager` helpers
   against the v2 `PTCInterface`.

## Main Findings

- The hard ABI boundary is thin: `Main.cpp` loads a same-named libtinycode and
  `PTCInterface.h` compiles directly against `ptc.h`, but runnable-lift does
  not negotiate opcode/temp schema version.
- `CodeGenerator::translate()` assumes non-empty legacy lists and a first
  `debug_insn_start`; empty converter stubs can fail before opcode translation
  begins.
- `InstructionTranslator` is scalar i32/i64 only. The required v2 scalar ops
  and all vector ops are absent from both opcode admission and translation.
- `VariableManager` is the highest-risk vector schema consumer because modern
  non-I32 temps are silently typed as i64.
- `PTCDump` and metadata generation need v2-safe dumping, otherwise debugging
  and `pi` metadata will either crash or hide vector semantics.
- `JumpTargetManager` and parts of `CodeGenerator` rely on old `PTCInterface`
  side channels. They can remain out of the opcode/vector patch only if the v2
  library preserves those fields.
