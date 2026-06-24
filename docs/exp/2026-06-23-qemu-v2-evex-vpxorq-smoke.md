# QEMU V2 EVEX VPXORQ Smoke Patch

Date: 2026-06-23
Branch: `codex/qemu-upgrade-v2`
Script: `runnable/scripts/qemu_v2_evex_vpxorq_smoke_patch.sh`
Scratch root used for validation: `/tmp/rr-qemu-v2-evex-vpxorq-smoke-dev`

## Summary

This experiment adds the smallest validated QEMU `10.2.3` linux-user TCG path
that stops rejecting the exact EVEX byte sequence
`62 f1 fd 48 ef c0` (`vpxorq zmm0,zmm0,zmm0`).

The patch does **not** add general EVEX decode, AVX-512 CPUID exposure, or
full ZMM semantics. Instead, it inserts an exact-byte check at the start of
`disas_insn` and emits a single zeroing TCG path for `zmm0`. This is enough to
turn the prior `SIGILL` into non-raising TCG for the single-instruction smoke
probe.

Validation result: **PASS**. The patched `qemu-x86_64 version 10.2.3` executed
the probe successfully with exit code `0`, and the TCG log contained vector
store ops instead of `raise_exception`.

## Exact QEMU Source File Touched

The throwaway patch created by the script touches exactly one upstream source
file under `/tmp`:

`target/i386/tcg/decode-new.c.inc`

No QEMU source or build outputs were added to the repository.

## Patch Shape

The patch adds one helper:

- `rr_try_evex_vpxorq_zmm0_smoke(DisasContext *s, CPUX86State *env)`

and one early fast path in `disas_insn`:

- if the current instruction bytes exactly match `62 f1 fd 48 ef c0`
- emit `tcg_gen_gvec_dup_imm(MO_64, offsetof(CPUX86State, xmm_regs[0]), 64, 64, 0)`
- advance `s->pc` by 6
- return without entering the normal legacy `0x62 -> BOUND` decode path

This is intentionally narrower than a real EVEX decoder. It satisfies the
minimum gate the task asked for: stop treating the leading `0x62` as `BOUND`
for the exact smoke sequence and emit measurable non-exception TCG.

## Validation Commands

Validated manually first in a throwaway tree:

```bash
cp -a /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 /tmp/rr-qemu-v2-evex-vpxorq-smoke-dev-src
patch -p1 -d /tmp/rr-qemu-v2-evex-vpxorq-smoke-dev-src < /tmp/rr-qemu-v2-evex-vpxorq-smoke-dev.patch
PATH=/tmp/rr-qemu-v2-upstream-probes/venv/bin:$PATH \
  /tmp/rr-qemu-v2-evex-vpxorq-smoke-dev-src/configure \
  --target-list=x86_64-linux-user \
  --disable-system \
  --disable-tools \
  --disable-docs \
  --disable-gtk \
  --disable-sdl \
  --disable-vnc \
  --disable-curses \
  --disable-slirp \
  --disable-capstone \
  --disable-werror \
  --prefix=/tmp/rr-qemu-v2-evex-vpxorq-smoke-dev-install
PATH=/tmp/rr-qemu-v2-upstream-probes/venv/bin:$PATH \
  ninja -C /tmp/rr-qemu-v2-evex-vpxorq-smoke-dev-build -j3 qemu-x86_64
```

Validated probe execution:

```bash
QEMU_LOG_FILENAME=/tmp/rr-qemu-v2-evex-vpxorq-smoke-dev-out/vpxorq.log \
  /tmp/rr-qemu-v2-evex-vpxorq-smoke-dev-build/qemu-x86_64 \
  -d in_asm,op,int \
  /tmp/rr-qemu-v2-upstream-probes/micro-probes/vpxorq
```

Observed result:

```text
qemu-x86_64 version 10.2.3
probe exit code: 0
```

Relevant TCG log head:

```text
IN:
0x00401000:
OBJD-T: 62f1fd48efc0b83c00000031ff0f05

OP:
...
mov_vec v256,e8,tmp8,v256$0x0
st_vec v256,e8,tmp8,env,$0x360
st_vec v256,e8,tmp8,env,$0x380
...
call syscall,$0x0,$0,env,$0x2
```

Not observed in the passing run:

```text
raise_exception
Illegal instruction
check_exception
```

## Script Behavior

`runnable/scripts/qemu_v2_evex_vpxorq_smoke_patch.sh` now:

1. Downloads and verifies QEMU `10.2.3` under `/tmp` if needed.
2. Creates a throwaway copied source tree under `/tmp`.
3. Writes the exact smoke patch to `/tmp`.
4. Applies the patch to the copied tree.
5. Builds `qemu-x86_64`.
6. Builds a single-instruction probe:

```asm
vpxorq zmm0, zmm0, zmm0
mov eax, 60
xor edi, edi
syscall
```

7. Runs the probe with `-d in_asm,op,int`.
8. Reports `PASS` only when:
   - process exit code is `0`
   - no `raise_exception`/`Illegal instruction`/`check_exception` markers appear
   - the log contains vector ops such as `st_vec` or `mov_vec`

## Limitations

- This is **not** general EVEX decode support.
- This is **not** real AVX-512 feature exposure. CPUID/XCR0 are unchanged.
- This is **not** general `vpxorq` support. Only the exact byte sequence
  `62 f1 fd 48 ef c0` is intercepted.
- This is **not** general ZMM register semantics. The path only zeroes
  `zmm0` and ignores masking, alternate registers, memory operands, and all
  other EVEX encodings.
- The fast path lives before normal decode, so it intentionally bypasses the
  legacy `0x62` opcode table only for this one smoke case.

## Next Instructions

1. Run the script directly to reproduce the experiment:

```bash
cd /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting
bash runnable/scripts/qemu_v2_evex_vpxorq_smoke_patch.sh --fresh
```

2. If this smoke gate remains useful, extend the same pattern one step at a
   time:
   - exact-byte `zmm1`/other register forms
   - register-register EVEX variants with decoded ModRM selection
   - minimal CPUID/XCR0 exposure for controlled probes
   - then migrate from exact-byte matching to a real EVEX prefix parser

3. Do not confuse this patch with an upstreamable EVEX implementation. Treat
   it only as a proof that QEMU `10.2.3` can be made to emit non-raising TCG
   for one targeted AVX-512 instruction before the larger V2 port work.
