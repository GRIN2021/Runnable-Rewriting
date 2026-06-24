#!/usr/bin/env bash
#
# Probe QEMU x86_64 linux-user TCG AVX-512 feature/state exposure.
#
# Generated C, probe binaries, logs, and optional patched QEMU builds live under
# /tmp by default. Repository inputs are read-only.
set -euo pipefail
ulimit -c 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

OUT_DIR="${RUNNABLE_QEMU_V2_AVX512_FEATURE_OUT:-/tmp/rr-qemu-v2-avx512-feature-probe}"
QEMU_BIN=""
QEMU_BUILD=""
QEMU_SRC=""
TARGET=""
WITH_QEMU_LOG=0
RUN_MIN_FEATURE_PATCH=0
JOBS="${RUNNABLE_QEMU_V2_JOBS:-3}"
VENV_DIR="${RUNNABLE_QEMU_V2_QEMU_VENV:-}"
CC_BIN="${CC:-gcc}"

SUMMARY=""
WORK_DIR=""
FEATURE_PROBE=""
EVEX_PROBE=""

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_avx512_feature_probe.sh [options] [qemu-x86_64|qemu-build-dir|qemu-src-dir]

Options:
  --qemu-x86_64 FILE       Existing qemu-x86_64 linux-user binary.
  --qemu-build DIR         Existing QEMU build dir containing qemu-x86_64.
  --qemu-src DIR           Existing QEMU source tree, used for source scans and
                           the optional patch experiment.
  --out-dir DIR            Output directory. Default:
                           /tmp/rr-qemu-v2-avx512-feature-probe
  --with-qemu-log          Run the EVEX microprobe with -d in_asm,op,int,cpu and
                           QEMU_LOG_FILENAME.
  --run-min-feature-patch  Copy --qemu-src under --out-dir, patch TCG masks to
                           expose AVX512F, VPCLMULQDQ, and AVX-512 XCR0 bits,
                           build qemu-x86_64, and rerun the probes.
  --venv DIR               Meson/Ninja venv to use for the optional patch build.
                           If omitted, a venv is created under --out-dir.
  --jobs N, -j N           Ninja jobs for the optional patch build. Default: 3
                           or RUNNABLE_QEMU_V2_JOBS.
  -h, --help               Show this help.

Runtime probes:
  qemu-x86_64 --version
  qemu-x86_64 -cpu help
  cpuid/xgetbv guest under default, -cpu max, -cpu SapphireRapids, and a forced
  -cpu max,+avx512f,+vpclmulqdq,+vaes,check=off case.
  EVEX vpxorq guest under default, -cpu max, and -cpu SapphireRapids.

Source-only mode:
  Supplying only --qemu-src records source scans. Runtime probes require an
  existing qemu-x86_64 or --run-min-feature-patch.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

abs_path() {
  local input="$1"
  if [[ "$input" = /* ]]; then
    printf '%s\n' "$input"
  else
    printf '%s/%s\n' "$PWD" "$input"
  fi
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --qemu-x86_64)
        [[ $# -ge 2 ]] || die "--qemu-x86_64 requires an argument"
        QEMU_BIN="$(abs_path "$2")"
        shift 2
        ;;
      --qemu-build)
        [[ $# -ge 2 ]] || die "--qemu-build requires an argument"
        QEMU_BUILD="$(abs_path "$2")"
        shift 2
        ;;
      --qemu-src)
        [[ $# -ge 2 ]] || die "--qemu-src requires an argument"
        QEMU_SRC="$(abs_path "$2")"
        shift 2
        ;;
      --out-dir)
        [[ $# -ge 2 ]] || die "--out-dir requires an argument"
        OUT_DIR="$(abs_path "$2")"
        shift 2
        ;;
      --with-qemu-log)
        WITH_QEMU_LOG=1
        shift
        ;;
      --run-min-feature-patch)
        RUN_MIN_FEATURE_PATCH=1
        shift
        ;;
      --venv)
        [[ $# -ge 2 ]] || die "--venv requires an argument"
        VENV_DIR="$(abs_path "$2")"
        shift 2
        ;;
      --jobs|-j)
        [[ $# -ge 2 ]] || die "$1 requires an argument"
        JOBS="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        [[ -z "$TARGET" ]] || die "multiple positional targets supplied"
        TARGET="$(abs_path "$1")"
        shift
        ;;
    esac
  done
  [[ $# -eq 0 ]] || die "unexpected trailing arguments: $*"
}

detect_target() {
  if [[ -n "$TARGET" ]]; then
    if [[ -x "$TARGET" && ! -d "$TARGET" ]]; then
      QEMU_BIN="$TARGET"
    elif [[ -d "$TARGET" && -x "$TARGET/qemu-x86_64" ]]; then
      QEMU_BUILD="$TARGET"
    elif [[ -d "$TARGET" && -x "$TARGET/build/qemu-x86_64" ]]; then
      QEMU_BUILD="$TARGET/build"
    elif [[ -d "$TARGET" && -f "$TARGET/target/i386/cpu.c" ]]; then
      QEMU_SRC="$TARGET"
    else
      die "could not classify target: $TARGET"
    fi
  fi

  if [[ -n "$QEMU_BUILD" ]]; then
    [[ -x "$QEMU_BUILD/qemu-x86_64" ]] || die "qemu-x86_64 not found in build dir: $QEMU_BUILD"
    QEMU_BIN="$QEMU_BUILD/qemu-x86_64"
  fi

  if [[ -n "$QEMU_BIN" ]]; then
    [[ -x "$QEMU_BIN" ]] || die "qemu-x86_64 is not executable: $QEMU_BIN"
  fi

  if [[ -n "$QEMU_SRC" ]]; then
    [[ -f "$QEMU_SRC/target/i386/cpu.c" ]] || die "QEMU source missing target/i386/cpu.c: $QEMU_SRC"
  fi
}

init_output() {
  mkdir -p "$OUT_DIR"
  OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"
  SUMMARY="$OUT_DIR/summary.md"
  WORK_DIR="$OUT_DIR/probes"
  mkdir -p "$WORK_DIR"

  {
    echo "# QEMU AVX-512 CPUID/XCR0 Feature Probe"
    echo
    echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
    echo "- Repository: $RR_DIR"
    echo "- Output directory: $OUT_DIR"
    echo "- QEMU binary: ${QEMU_BIN:-not provided}"
    echo "- QEMU source: ${QEMU_SRC:-not provided}"
    echo
  } >"$SUMMARY"
}

run_capture() {
  local outfile="$1"
  shift
  local cmdfile="${outfile}.cmd"
  local rcfile="${outfile}.rc"
  require_tool python3
  printf '+ ' >"$cmdfile"
  printf '%q ' "$@" >>"$cmdfile"
  printf '\n' >>"$cmdfile"
  python3 - "$outfile" "$rcfile" "$@" <<'PY'
import resource
import subprocess
import sys

outfile = sys.argv[1]
rcfile = sys.argv[2]
cmd = sys.argv[3:]
try:
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
except Exception:
    pass
with open(outfile, "wb") as out:
    result = subprocess.run(cmd, stdout=out, stderr=subprocess.STDOUT)
rc = result.returncode
if rc < 0:
    rc = 128 + (-rc)
with open(rcfile, "w", encoding="utf-8") as out:
    out.write(f"{rc}\n")
PY
  return 0
}

run_capture_env() {
  local env_kv="$1"
  local outfile="$2"
  shift 2
  local cmdfile="${outfile}.cmd"
  local rcfile="${outfile}.rc"
  require_tool python3
  printf '+ env %q ' "$env_kv" >"$cmdfile"
  printf '%q ' "$@" >>"$cmdfile"
  printf '\n' >>"$cmdfile"
  python3 - "$env_kv" "$outfile" "$rcfile" "$@" <<'PY'
import os
import resource
import subprocess
import sys

env_kv = sys.argv[1]
outfile = sys.argv[2]
rcfile = sys.argv[3]
cmd = sys.argv[4:]
env = os.environ.copy()
key, value = env_kv.split("=", 1)
env[key] = value
try:
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
except Exception:
    pass
with open(outfile, "wb") as out:
    result = subprocess.run(cmd, stdout=out, stderr=subprocess.STDOUT, env=env)
rc = result.returncode
if rc < 0:
    rc = 128 + (-rc)
with open(rcfile, "w", encoding="utf-8") as out:
    out.write(f"{rc}\n")
PY
  return 0
}

write_probe_sources() {
  cat >"$WORK_DIR/cpuid_xgetbv.c" <<'C'
#include <stdint.h>
#include <stdio.h>

static void cpuid_count(uint32_t leaf, uint32_t subleaf,
                        uint32_t *eax, uint32_t *ebx,
                        uint32_t *ecx, uint32_t *edx)
{
    __asm__ volatile(
        "cpuid"
        : "=a"(*eax), "=b"(*ebx), "=c"(*ecx), "=d"(*edx)
        : "a"(leaf), "c"(subleaf));
}

static uint64_t xgetbv0(void)
{
    uint32_t eax;
    uint32_t edx;

    __asm__ volatile(".byte 0x0f, 0x01, 0xd0"
                     : "=a"(eax), "=d"(edx)
                     : "c"(0));
    return ((uint64_t)edx << 32) | eax;
}

int main(void)
{
    uint32_t eax, ebx, ecx, edx;

    cpuid_count(1, 0, &eax, &ebx, &ecx, &edx);
    printf("cpuid.1: eax=%08x ebx=%08x ecx=%08x edx=%08x\n", eax, ebx, ecx, edx);

    cpuid_count(7, 0, &eax, &ebx, &ecx, &edx);
    printf("cpuid.7.0: eax=%08x ebx=%08x ecx=%08x edx=%08x\n", eax, ebx, ecx, edx);

    printf("xcr0=%016llx\n", (unsigned long long)xgetbv0());
    return 0;
}
C

  cat >"$WORK_DIR/vpxorq_evex.S" <<'ASM'
    .text
    .global _start
_start:
    .byte 0x62, 0xf1, 0xfd, 0x48, 0xef, 0xc0
    xor %edi, %edi
    mov $60, %eax
    syscall
ASM
}

build_probes() {
  require_tool "$CC_BIN"
  write_probe_sources
  FEATURE_PROBE="$WORK_DIR/cpuid_xgetbv"
  EVEX_PROBE="$WORK_DIR/vpxorq_evex"
  "$CC_BIN" -O2 -Wall -Wextra -o "$FEATURE_PROBE" "$WORK_DIR/cpuid_xgetbv.c"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$EVEX_PROBE" "$WORK_DIR/vpxorq_evex.S"
}

hex_field() {
  local key="$1"
  local file="$2"
  sed -n "s/.* ${key}=\\([0-9a-fA-F][0-9a-fA-F]*\\).*/\\1/p" "$file" | head -1
}

bit_yesno() {
  local hex="$1"
  local bit="$2"
  if [[ -z "$hex" ]]; then
    printf 'n/a'
    return
  fi
  local value=$((16#$hex))
  if (((value & (1 << bit)) != 0)); then
    printf 'yes'
  else
    printf 'no'
  fi
}

xcr0_avx512_yesno() {
  local hex="$1"
  if [[ -z "$hex" ]]; then
    printf 'n/a'
    return
  fi
  local value=$((16#$hex))
  local mask=$(((1 << 1) | (1 << 2) | (1 << 5) | (1 << 6) | (1 << 7)))
  if (((value & mask) == mask)); then
    printf 'yes'
  else
    printf 'no'
  fi
}

append_feature_row() {
  local prefix="$1"
  local label="$2"
  local args="$3"
  local outfile="$4"
  local rcfile="${outfile}.rc"
  local rc
  rc="$(cat "$rcfile" 2>/dev/null || printf 'n/a')"
  local ebx ecx xcr0
  ebx="$(grep '^cpuid\.7\.0:' "$outfile" 2>/dev/null | sed -n 's/.* ebx=\([0-9a-fA-F]*\).*/\1/p' | head -1)"
  ecx="$(grep '^cpuid\.7\.0:' "$outfile" 2>/dev/null | sed -n 's/.* ecx=\([0-9a-fA-F]*\).*/\1/p' | head -1)"
  xcr0="$(sed -n 's/^xcr0=\([0-9a-fA-F]*\)$/\1/p' "$outfile" 2>/dev/null | head -1)"

  printf '| %s | %s | `%s` | %s | `%s` | `%s` | `%s` | %s | %s | %s | %s | [%s](%s) |\n' \
    "$prefix" \
    "$label" \
    "${args:-default}" \
    "$rc" \
    "${ebx:-n/a}" \
    "${ecx:-n/a}" \
    "${xcr0:-n/a}" \
    "$(bit_yesno "$ebx" 16)" \
    "$(bit_yesno "$ecx" 9)" \
    "$(bit_yesno "$ecx" 10)" \
    "$(xcr0_avx512_yesno "$xcr0")" \
    "$(basename "$outfile")" \
    "$outfile" >>"$SUMMARY"
}

run_feature_matrix() {
  local prefix="$1"
  local qemu="$2"

  {
    echo
    echo "## Feature Matrix: $prefix"
    echo
    echo "| Probe | CPU args | Command args | RC | CPUID.7.0 EBX | CPUID.7.0 ECX | XCR0 | AVX512F | VAES | VPCLMULQDQ | XCR0 AVX-512 state | Output |"
    echo "|---|---|---|---:|---|---|---|---|---|---|---|---|"
  } >>"$SUMMARY"

  local names=("default" "max" "SapphireRapids" "force-min")
  local arg_texts=("" "-cpu max" "-cpu SapphireRapids" "-cpu max,+avx512f,+vpclmulqdq,+vaes,check=off")
  local i
  for i in "${!names[@]}"; do
    local outfile="$OUT_DIR/${prefix}-feature-${names[$i]}.out"
    if [[ -n "${arg_texts[$i]}" ]]; then
      read -r -a cpu_args <<<"${arg_texts[$i]}"
      run_capture "$outfile" "$qemu" "${cpu_args[@]}" "$FEATURE_PROBE"
    else
      run_capture "$outfile" "$qemu" "$FEATURE_PROBE"
    fi
    append_feature_row "$prefix" "${names[$i]}" "${arg_texts[$i]}" "$outfile"
  done
}

append_evex_row() {
  local prefix="$1"
  local label="$2"
  local args="$3"
  local outfile="$4"
  local rcfile="${outfile}.rc"
  local rc
  rc="$(cat "$rcfile" 2>/dev/null || printf 'n/a')"
  local sigill="no"
  if [[ "$rc" = "132" ]] || grep -qi 'Illegal instruction\|signal 4' "$outfile" 2>/dev/null; then
    sigill="yes"
  fi
  printf '| %s | %s | `%s` | %s | %s | [%s](%s) |\n' \
    "$prefix" \
    "$label" \
    "${args:-default}" \
    "$rc" \
    "$sigill" \
    "$(basename "$outfile")" \
    "$outfile" >>"$SUMMARY"
}

run_evex_matrix() {
  local prefix="$1"
  local qemu="$2"

  {
    echo
    echo "## EVEX Microprobe: $prefix"
    echo
    echo "Probe bytes: \`62 f1 fd 48 ef c0\` (\`vpxorq zmm0,zmm0,zmm0\`), followed by \`exit(0)\`."
    echo
    echo "| Probe | CPU args | Command args | RC | SIGILL | Output |"
    echo "|---|---|---|---:|---|---|"
  } >>"$SUMMARY"

  local names=("default" "max" "SapphireRapids")
  local arg_texts=("" "-cpu max" "-cpu SapphireRapids")
  local i
  for i in "${!names[@]}"; do
    local outfile="$OUT_DIR/${prefix}-evex-vpxorq-${names[$i]}.out"
    if [[ -n "${arg_texts[$i]}" ]]; then
      read -r -a cpu_args <<<"${arg_texts[$i]}"
      run_capture "$outfile" "$qemu" "${cpu_args[@]}" "$EVEX_PROBE"
    else
      run_capture "$outfile" "$qemu" "$EVEX_PROBE"
    fi
    append_evex_row "$prefix" "${names[$i]}" "${arg_texts[$i]}" "$outfile"
  done

  if [[ "$WITH_QEMU_LOG" -eq 1 ]]; then
    local trace_log="$OUT_DIR/${prefix}-evex-vpxorq-max.qemu.log"
    local trace_out="$OUT_DIR/${prefix}-evex-vpxorq-max.trace.out"
    run_capture_env "QEMU_LOG_FILENAME=$trace_log" \
      "$trace_out" \
      "$qemu" -d in_asm,op,int,cpu -cpu max "$EVEX_PROBE"
    {
      echo
      echo "QEMU log for ${prefix} \`-cpu max\`: [$(
        basename "$trace_log"
      )]($trace_log)"
      echo
      echo "Trace command output: [$(
        basename "$trace_out"
      )]($trace_out)"
    } >>"$SUMMARY"
  fi
}

run_qemu_basics() {
  local prefix="$1"
  local qemu="$2"
  run_capture "$OUT_DIR/${prefix}-version.out" "$qemu" --version
  run_capture "$OUT_DIR/${prefix}-cpu-help.out" "$qemu" -cpu help
  {
    echo
    echo "## QEMU Commands: $prefix"
    echo
    echo "- Version: [${prefix}-version.out]($OUT_DIR/${prefix}-version.out)"
    echo "- CPU help: [${prefix}-cpu-help.out]($OUT_DIR/${prefix}-cpu-help.out)"
  } >>"$SUMMARY"
}

source_scan() {
  [[ -n "$QEMU_SRC" ]] || return 0

  local scan="$OUT_DIR/source-scan.txt"
  {
    echo "QEMU source: $QEMU_SRC"
    echo
    echo "== CPU feature and XCR0 masks =="
    if command -v rg >/dev/null 2>&1; then
      rg -n "TCG_7_0_EBX_FEATURES|TCG_7_0_ECX_FEATURES|FEAT_XSAVE_XCR0_LO|XSTATE_OPMASK_BIT|XSTATE_ZMM_Hi256_BIT|XSTATE_Hi16_ZMM_BIT|x86_cpu_enable_xsave_components|x86_cpu_xsave_init" \
        "$QEMU_SRC/target/i386/cpu.c" \
        "$QEMU_SRC/target/i386/tcg/tcg-cpu.c" 2>/dev/null || true
    else
      grep -RInE "TCG_7_0_EBX_FEATURES|TCG_7_0_ECX_FEATURES|FEAT_XSAVE_XCR0_LO|XSTATE_OPMASK_BIT|XSTATE_ZMM_Hi256_BIT|XSTATE_Hi16_ZMM_BIT|x86_cpu_enable_xsave_components|x86_cpu_xsave_init" \
        "$QEMU_SRC/target/i386/cpu.c" \
        "$QEMU_SRC/target/i386/tcg/tcg-cpu.c" 2>/dev/null || true
    fi
    echo
    echo "== EVEX/VEX decode scan =="
    if command -v rg >/dev/null 2>&1; then
      rg -n "\\[0x62\\]|case 0x62|case 0xc5|case 0xc4|EVEX|evex|PREFIX_EVEX" \
        "$QEMU_SRC/target/i386/tcg/decode-new.c.inc" \
        "$QEMU_SRC/target/i386/tcg/translate.c" 2>/dev/null || true
    else
      grep -RInE "\\[0x62\\]|case 0x62|case 0xc5|case 0xc4|EVEX|evex|PREFIX_EVEX" \
        "$QEMU_SRC/target/i386/tcg/decode-new.c.inc" \
        "$QEMU_SRC/target/i386/tcg/translate.c" 2>/dev/null || true
    fi
  } >"$scan"

  {
    echo
    echo "## Source Scan"
    echo
    echo "- Source scan: [source-scan.txt]($scan)"
  } >>"$SUMMARY"
}

write_min_feature_patch() {
  local patch_file="$1"
  cat >"$patch_file" <<'PATCH'
Adds the minimum TCG-advertised AVX-512 feature/state bits used by this probe:
- CPUID.7.0.EBX.AVX512F
- CPUID.7.0.ECX.VPCLMULQDQ
- XCR0 bits 5/6/7 via FEAT_XSAVE_XCR0_LO.tcg_features

This patch does not add EVEX decode or AVX-512 execution semantics.
PATCH
}

apply_min_feature_patch() {
  local cpu_c="$1/target/i386/cpu.c"
  [[ -f "$cpu_c" ]] || die "missing cpu.c in patched tree: $cpu_c"

  perl -0pi -e 's/CPUID_7_0_EBX_CLWB \| CPUID_7_0_EBX_MPX \| CPUID_7_0_EBX_FSGSBASE \| \\\n/CPUID_7_0_EBX_CLWB | CPUID_7_0_EBX_MPX | CPUID_7_0_EBX_FSGSBASE | \\\n          CPUID_7_0_EBX_AVX512F | \\\n/' "$cpu_c"
  perl -0pi -e 's/CPUID_7_0_ECX_LA57 \| CPUID_7_0_ECX_PKS \| CPUID_7_0_ECX_VAES \| \\\n/CPUID_7_0_ECX_LA57 | CPUID_7_0_ECX_PKS | CPUID_7_0_ECX_VAES | \\\n          CPUID_7_0_ECX_VPCLMULQDQ | \\\n/' "$cpu_c"
  perl -0pi -e 's/(\.tcg_features = XSTATE_FP_MASK \| XSTATE_SSE_MASK \|\n            XSTATE_YMM_MASK \| XSTATE_BNDREGS_MASK \| XSTATE_BNDCSR_MASK \|\n)            XSTATE_PKRU_MASK,/${1}            XSTATE_OPMASK_MASK | XSTATE_ZMM_Hi256_MASK | XSTATE_Hi16_ZMM_MASK |\n            XSTATE_PKRU_MASK,/' "$cpu_c"

  grep -q 'CPUID_7_0_EBX_AVX512F' "$cpu_c" || die "failed to add AVX512F to TCG_7_0_EBX_FEATURES"
  grep -q 'CPUID_7_0_ECX_VPCLMULQDQ' "$cpu_c" || die "failed to add VPCLMULQDQ to TCG_7_0_ECX_FEATURES"
  sed -n '/\.tcg_features = XSTATE_FP_MASK/,/XSTATE_PKRU_MASK,/p' "$cpu_c" |
    grep -q 'XSTATE_OPMASK_MASK | XSTATE_ZMM_Hi256_MASK | XSTATE_Hi16_ZMM_MASK' ||
    die "failed to add AVX-512 XCR0 tcg_features"
}

prepare_build_venv() {
  local venv="$1"
  if [[ -n "$VENV_DIR" ]]; then
    [[ -x "$VENV_DIR/bin/meson" ]] || die "meson not found in venv: $VENV_DIR"
    [[ -x "$VENV_DIR/bin/ninja" ]] || die "ninja not found in venv: $VENV_DIR"
    printf '%s\n' "$VENV_DIR"
    return
  fi

  if command -v meson >/dev/null 2>&1 && command -v ninja >/dev/null 2>&1; then
    printf '%s\n' ""
    return
  fi

  require_tool python3
  python3 -m venv "$venv" >&2
  "$venv/bin/pip" install --upgrade pip meson ninja >&2
  printf '%s\n' "$venv"
}

run_min_feature_patch() {
  [[ "$RUN_MIN_FEATURE_PATCH" -eq 1 ]] || return 0
  [[ -n "$QEMU_SRC" ]] || die "--run-min-feature-patch requires --qemu-src"
  require_tool perl

  local patch_root="$OUT_DIR/min-feature-patch"
  local patched_src="$patch_root/qemu-src"
  local patched_build="$patch_root/build"
  local patch_file="$patch_root/min-avx512-feature-mask.patch"
  local build_venv="$patch_root/venv"
  rm -rf "$patch_root"
  mkdir -p "$patch_root" "$patched_build"

  log "Copying QEMU source for optional feature-mask patch"
  cp -a "$QEMU_SRC" "$patched_src"
  write_min_feature_patch "$patch_file"
  apply_min_feature_patch "$patched_src"
  diff -u "$QEMU_SRC/target/i386/cpu.c" "$patched_src/target/i386/cpu.c" >"$patch_file" || true

  log "Building patched qemu-x86_64 under $patch_root"
  local selected_venv
  selected_venv="$(prepare_build_venv "$build_venv")"

  local path_prefix="$PATH"
  if [[ -n "$selected_venv" ]]; then
    path_prefix="$selected_venv/bin:$PATH"
  fi

  (
    cd "$patched_build"
    PATH="$path_prefix" "$patched_src/configure" \
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
      --prefix="$patch_root/install"
  ) >"$patch_root/configure.out" 2>&1

  PATH="$path_prefix" ninja -C "$patched_build" -j "$JOBS" qemu-x86_64 \
    >"$patch_root/ninja.out" 2>&1

  local patched_qemu="$patched_build/qemu-x86_64"
  run_qemu_basics "minpatch" "$patched_qemu"
  run_feature_matrix "minpatch" "$patched_qemu"
  run_evex_matrix "minpatch" "$patched_qemu"

  {
    echo
    echo "## Optional Minimum Feature-Mask Patch"
    echo
    echo "- Patch: [min-avx512-feature-mask.patch]($patch_file)"
    echo "- Configure log: [configure.out]($patch_root/configure.out)"
    echo "- Ninja log: [ninja.out]($patch_root/ninja.out)"
    echo "- Patched QEMU: \`$patched_qemu\`"
  } >>"$SUMMARY"
}

main() {
  parse_args "$@"
  detect_target
  init_output
  source_scan

  if [[ -n "$QEMU_BIN" ]]; then
    build_probes
    run_qemu_basics "baseline" "$QEMU_BIN"
    run_feature_matrix "baseline" "$QEMU_BIN"
    run_evex_matrix "baseline" "$QEMU_BIN"
  elif [[ "$RUN_MIN_FEATURE_PATCH" -eq 0 ]]; then
    log "No qemu-x86_64 provided; runtime probes skipped"
  fi

  if [[ "$RUN_MIN_FEATURE_PATCH" -eq 1 ]]; then
    if [[ -z "$FEATURE_PROBE" || -z "$EVEX_PROBE" ]]; then
      build_probes
    fi
    run_min_feature_patch
  fi

  {
    echo
    echo "## Interpretation Hints"
    echo
    echo "- \`AVX512F=no\` with \`VAES=yes\` means TCG exposes VAES but not the required AVX-512 foundation bit."
    echo "- \`VPCLMULQDQ=no\` means the carry-less multiply extension used by the AVX-512 probe is also masked."
    echo "- \`XCR0 AVX-512 state=no\` means bits 1, 2, 5, 6, and 7 are not all set, so AVX-512 architectural state is not exposed to the guest."
    echo "- If the EVEX microprobe still SIGILLs after the optional feature-mask patch, CPUID/XCR0 exposure is only a secondary gate; EVEX decode/translation remains the primary gate."
  } >>"$SUMMARY"

  log "Wrote $SUMMARY"
}

main "$@"
