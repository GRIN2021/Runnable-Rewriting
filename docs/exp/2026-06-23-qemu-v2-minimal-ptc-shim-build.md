# 2026-06-23 QEMU V2 Minimal PTC Shim Build Stub

Branch: `codex/qemu-upgrade-v2`

## Purpose

Advance the generated minimal PTC shim from an overlay-only skeleton to a
buildable standalone stub shared object for load-smoke validation.

This milestone is intentionally narrow:

- build `libtinycode-x86_64.so` under `/tmp`,
- export `ptc_load` and `ptc_translate`,
- export optional ABI metadata for future runnable-lift capability discovery,
- return a stable `PTCInterface` with safe placeholders,
- keep translation disabled until the modern QEMU path exists.

It is not a runnable translation backend yet, and it does not modify
`runnable-lift`.

## Generator Output

Use:

```bash
runnable/scripts/qemu_v2_make_ptc_shim_tree.sh \
  --qemu-src /path/to/qemu-10.2.3 \
  --out-dir /tmp/qemu-v2-ptc-shim \
  --force
```

The generated `/tmp` tree now contains:

- `include/ptc.h`: copied legacy ABI header.
- `include/tcg-opc.h`: copied legacy opcode list used to populate
  `opcode_defs`.
- `include/ptc_standalone_prefix.h`: standalone compile-time feature macros so
  the copied legacy header can compile outside old QEMU.
- `include/ptc_standalone.h`: safe wrapper include for the copied ABI header.
- `src/ptc_load_stub.c`: `ptc_load`, optional ABI metadata symbols, static
  state, and safe stubs.
- `src/ptc_translate_stub.c`: `ptc_translate` returning size `0` with an empty
  `PTCInstructionList`.
- `src/dump_tinycode_stub.c`: future hook for modern TCG op dumping.
- `tests/ptc_load_smoke.c`: `dlopen`/`dlsym`/`ptc_load` smoke harness.
- `Makefile`: builds `build/libtinycode-x86_64.so` and the smoke harness.

## Build Commands

From the generated `/tmp` tree:

```bash
make
make smoke
```

The smoke target builds and runs:

- `build/libtinycode-x86_64.so`
- `build/ptc_load_smoke`

The smoke harness checks:

- `dlopen` succeeds,
- `dlsym("ptc_load")` succeeds,
- `ptc_load` returns success,
- required `PTCInterface` pointers are non-null,
- `opcode_defs[PTC_INSTRUCTION_op_call].name` is present,
- `ptc_translate` returns `0`,
- `ptc_translate` keeps `dymvirtual_address == virtual_address`,
- the returned `PTCInstructionList` is empty and freeable.
- `dlsym("ptc_abi_metadata")` succeeds,
- `dlsym("ptc_get_abi_metadata")` succeeds,
- metadata contains `abi_version=2`, `stub_kind=empty_stub`,
  `real_translation=false`, and `vector_schema=false`.

The metadata checks are intentionally separate from the old ABI path:
`ptc_load`/`ptc_translate` remain usable without any loader dependency on the
new symbols.

## Optional ABI Metadata

The stub now exports two additive discovery hooks:

- `const char ptc_abi_metadata[]`
- `const char *ptc_get_abi_metadata(void)`

Current content:

```text
abi_version=2
stub_kind=empty_stub
real_translation=false
vector_schema=false
```

This is a forward-compatible addition for future runnable-lift negotiation. It
does not modify `PTCInterface`, does not break older loaders, and does not
claim that real translation or the v2 vector schema has been migrated.

## ABI Fields Filled

The stub fills these parts of `PTCInterface` with stable storage:

- Function pointers:
  `get_condition_name`, `get_load_store_name`, `parse_load_store_arg`,
  `get_arg_label_id`, `mmap`, `unmmap`, `cleanLowAddr`, `translate`, `exec`,
  `exec1`, `exec2`, `isdecodeblock`, `getBadBlockSize`, `run_library`,
  `data_start`, `disassemble`, `do_syscall2`, queue helpers, stack helpers, and
  address predicates.
- Metadata pointers:
  `opcode_defs` is populated from the copied legacy `tcg-opc.h`;
  `helper_defs` is non-null and points at static storage, while
  `helper_defs_size` remains `0`.
- Environment pointers:
  `initialized_env` points at a fake `PTCShimEnv`,
  `regs` points at `PTCShimEnv.regs`,
  `pc`, `sp`, and `exception_index` are filled with `offsetof(...)` values
  inside that fake env.
- Status pointers:
  `exception_syscall`, `syscall_next_eip`, `isIndirect`, `isCall`,
  `isDirectcall`, `CallNext`, `isIndirectJmp`, `isDirectJmp`, `isRet`,
  `ElfStartStack`, `illegalAccessAddr`, `CFIAddr`, `isSyscall`, `BlockSize`,
  `iCount`, `isIllegal`, and `isAdd` all point at static storage.

The fake env also seeds:

- `regs[R_ESP]` and `regs[R_EBP]` with a local stub stack address,
- `ElfStartStack` with the top of that local stub stack.

## ABI Fields Still Stubbed

These remain placeholders by design:

- `ptc_load` does not initialize modern QEMU linux-user state.
- `ptc_translate` does not build a TB and does not dump TCG ops.
- ABI metadata reports `real_translation=false` and `vector_schema=false`.
- `dump_tinycode` always returns an empty `PTCInstructionList`.
- `helper_defs_size` stays `0`; helper metadata is not wired to modern QEMU.
- `parse_load_store_arg` preserves only legacy size/sign bits and does not
  decode modern `MemOpIdx`.
- `get_arg_label_id` is a passthrough placeholder.
- `exec`, `exec1`, `exec2`, `run_library`, and `do_syscall2` are safe failure
  stubs.
- image/executable address checks only reflect explicit `ptc_mmap`/`ptc_unmmap`
  calls into the stub bookkeeping, not real linux-user mappings.

## Next Required Work

1. Replace the fake env layout with real QEMU 10.2.3 `CPUX86State` and
   `CPUState` offsets in `ptc_load`.
2. Replace the placeholder init path in `ptc_load` with real modern linux-user
   initialization and image mapping state.
3. Replace the empty `ptc_translate` path with a translate-only
   `tb_gen_code`-based flow or an in-tree wrapper.
4. Reimplement `dump_tinycode` as a modern `TCGContext->ops` walker and build a
   compatibility mapping back to the legacy `PTCInstructionList` contract.
5. Populate helper metadata from modern QEMU and implement real
   `parse_load_store_arg` decoding before trusting any lift output.

## Validation Notes

Validation is feasible without touching repo sources beyond the generator:

```bash
runnable/scripts/qemu_v2_make_ptc_shim_tree.sh \
  --qemu-src /path/to/qemu-10.2.3 \
  --out-dir /tmp/qemu-v2-ptc-shim \
  --force
cd /tmp/qemu-v2-ptc-shim
make
make smoke
```

The expected success condition for this milestone is only:

- the stub shared object builds,
- `ptc_load` can be resolved and called,
- `ptc_translate` returns a freeable empty result.
- optional ABI metadata symbols can be resolved and report the empty-stub
  capability state.

Anything beyond that still requires the real modern QEMU port.
