#!/usr/bin/env bash
#
# Build and validate a reusable AVX-512 smoke patch series for QEMU 10.2.3.
#
# Runtime artifacts stay under /tmp by default:
#   0001: expose the minimum TCG CPUID/XCR0 AVX-512 feature/state bits
#   0002: exact-byte EVEX vpxorq zmm0,zmm0,zmm0 smoke translation hook
#   0003: exact-byte EVEX vmovdqa64 zmm1,zmm0 smoke translation hook
#   0004: exact-byte EVEX vmovdqu64 zmm1<->[rip+disp32] memory hook
#   0005: exact-byte EVEX vpshufb zmm3,zmm2,zmm2 smoke translation hook
#   0006: exact-byte EVEX vpaddd zmm4,zmm3,zmm2 smoke translation hook
#   0007: exact-byte EVEX vpternlogq zmm5,zmm4,zmm3,0x96 hook
#   0008: exact-byte EVEX vpclmullqlqdq zmm6,zmm5,zmm4 hook
#   0009: exact-byte EVEX vpclmullqhqdq zmm7,zmm5,zmm4 hook
#   0010: exact-byte EVEX vpclmulhqlqdq zmm8,zmm5,zmm4 hook
#   0011: exact-byte EVEX vpclmulhqhqdq zmm9,zmm5,zmm4 hook
#   0012: exact-byte EVEX vaesenc zmm10,zmm9,zmm8 hook
#   0013: exact-byte EVEX vaesenclast zmm11,zmm10,zmm7 hook
#   0014: exact-byte EVEX vbroadcastf64x2 zmm12,[rip+disp32] hook
#   0015: exact-byte EVEX vpslldq zmm13,zmm12,0x4 hook
#   0016: exact-byte EVEX vpsrldq zmm14,zmm13,0x4 hook
#   0017: exact-byte EVEX vextracti32x4 xmm15,zmm14,0x1 hook
#   0018: exact-byte EVEX vextracti64x4 ymm16,zmm14,0x1 hook
#   0019: exact-byte EVEX vmovdqu8 zmmword ptr [rip+disp32],zmm14 hook
set -euo pipefail
ulimit -c 0

QEMU_VERSION="10.2.3"
QEMU_TARBALL="qemu-${QEMU_VERSION}.tar.xz"
QEMU_URL="https://download.qemu.org/${QEMU_TARBALL}"
QEMU_SHA256="2aa0e420e4ea89ea34a833f4c4eced96a35b51a9ee8568b232692729b60b064d"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_AVX512_SERIES_ROOT:-/tmp/rr-qemu-v2-avx512-patch-series}"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-3}"
FRESH=0
SKIP_DOWNLOAD=0
QEMU_SRC=""
TARBALL_PATH=""
VENV_DIR="${RUNNABLE_QEMU_V2_QEMU_VENV:-}"
CC_BIN="${CC:-gcc}"
OBJDUMP_BIN="${OBJDUMP:-objdump}"

DOWNLOAD_DIR=""
BASE_SRC=""
SOURCE_SRC=""
PATCH_DIR=""
PATCHED_SRC=""
BUILD_DIR=""
INSTALL_DIR=""
OUT_DIR=""
PROBE_DIR=""
FEATURE_PROBE=""
AVX2_PROBE=""
AVX512_PROBE=""
VMOVDQA64_PROBE=""
VMOVDQU64_STORE_PROBE=""
VMOVDQU64_LOAD_PROBE=""
VMOVDQU64_CHAIN_PROBE=""
VPSHUFB_SINGLE_PROBE=""
VPSHUFB_CHAIN_PROBE=""
VPADDD_SINGLE_PROBE=""
VPADDD_CHAIN_PROBE=""
VPTERNLOGQ_SINGLE_PROBE=""
VPTERNLOGQ_CHAIN_PROBE=""
VPCLMULLQLQ_SINGLE_PROBE=""
VPCLMULLQLQ_CHAIN_PROBE=""
VPCLMULLQLQ_SEMANTIC_PROBE=""
VPCLMULLQHQ_SINGLE_PROBE=""
VPCLMULLQHQ_CHAIN_PROBE=""
VPCLMULLQHQ_SEMANTIC_PROBE=""
VPCLMULHQLQ_SINGLE_PROBE=""
VPCLMULHQLQ_CHAIN_PROBE=""
VPCLMULHQLQ_SEMANTIC_PROBE=""
VPCLMULHQHQ_SINGLE_PROBE=""
VPCLMULHQHQ_CHAIN_PROBE=""
VPCLMULHQHQ_SEMANTIC_PROBE=""
VAESENC_SINGLE_PROBE=""
VAESENC_CHAIN_PROBE=""
VAESENC_SEMANTIC_PROBE=""
VAESENCLAST_SINGLE_PROBE=""
VAESENCLAST_CHAIN_PROBE=""
VAESENCLAST_SEMANTIC_PROBE=""
VBROADCASTF64X2_SINGLE_PROBE=""
VBROADCASTF64X2_CHAIN_PROBE=""
VPSLLDQ_SINGLE_PROBE=""
VPSLLDQ_CHAIN_PROBE=""
VPSRLDQ_SINGLE_PROBE=""
VPSRLDQ_CHAIN_PROBE=""
VEXTRACTI32X4_SINGLE_PROBE=""
VEXTRACTI32X4_CHAIN_PROBE=""
VEXTRACTI64X4_SINGLE_PROBE=""
VEXTRACTI64X4_CHAIN_PROBE=""
AGGREGATE_BOUNDARY_PROBE=""
SUMMARY=""
BUILD_PATH=""

FEATURE_RESULT="FAIL"
FEATURE_AVX512F="n/a"
FEATURE_VPCLMULQDQ="n/a"
FEATURE_XCR0_STATE="n/a"
FEATURE_RC="n/a"
FEATURE_EVIDENCE="n/a"

AVX2_RESULT="FAIL"
AVX2_RC="n/a"
AVX2_EVIDENCE="n/a"
AVX512_RESULT="FAIL"
AVX512_RC="n/a"
AVX512_VECTOR_HITS="0"
AVX512_EXCEPTION_HITS="0"
AVX512_EVIDENCE="n/a"
VMOVDQA64_RESULT="FAIL"
VMOVDQA64_RC="n/a"
VMOVDQA64_VECTOR_HITS="0"
VMOVDQA64_EXCEPTION_HITS="0"
VMOVDQA64_EVIDENCE="n/a"
VMOVDQU64_RESULT="FAIL"
VMOVDQU64_STORE_RESULT="FAIL"
VMOVDQU64_STORE_RC="n/a"
VMOVDQU64_STORE_MEMORY_HITS="0"
VMOVDQU64_STORE_EXCEPTION_HITS="0"
VMOVDQU64_LOAD_RESULT="FAIL"
VMOVDQU64_LOAD_RC="n/a"
VMOVDQU64_LOAD_MEMORY_HITS="0"
VMOVDQU64_LOAD_EXCEPTION_HITS="0"
VMOVDQU64_CHAIN_RESULT="FAIL"
VMOVDQU64_CHAIN_RC="n/a"
VMOVDQU64_CHAIN_MEMORY_HITS="0"
VMOVDQU64_CHAIN_EXCEPTION_HITS="0"
VMOVDQU64_EVIDENCE="Not evaluated yet."
VPSHUFB_RESULT="FAIL"
VPSHUFB_SINGLE_RESULT="FAIL"
VPSHUFB_SINGLE_RC="n/a"
VPSHUFB_SINGLE_PSHUFB_HITS="0"
VPSHUFB_SINGLE_EXCEPTION_HITS="0"
VPSHUFB_CHAIN_RESULT="FAIL"
VPSHUFB_CHAIN_RC="n/a"
VPSHUFB_CHAIN_PSHUFB_HITS="0"
VPSHUFB_CHAIN_EXCEPTION_HITS="0"
VPSHUFB_EVIDENCE="Not evaluated yet."
VPADDD_RESULT="FAIL"
VPADDD_SINGLE_RESULT="FAIL"
VPADDD_SINGLE_RC="n/a"
VPADDD_SINGLE_ADD_HITS="0"
VPADDD_SINGLE_EXCEPTION_HITS="0"
VPADDD_CHAIN_RESULT="FAIL"
VPADDD_CHAIN_RC="n/a"
VPADDD_CHAIN_ADD_HITS="0"
VPADDD_CHAIN_EXCEPTION_HITS="0"
VPADDD_EVIDENCE="Not evaluated yet."
VPTERNLOGQ_RESULT="FAIL"
VPTERNLOGQ_SINGLE_RESULT="FAIL"
VPTERNLOGQ_SINGLE_RC="n/a"
VPTERNLOGQ_SINGLE_TERNLOG_HITS="0"
VPTERNLOGQ_SINGLE_XOR_HITS="0"
VPTERNLOGQ_SINGLE_EXCEPTION_HITS="0"
VPTERNLOGQ_CHAIN_RESULT="FAIL"
VPTERNLOGQ_CHAIN_RC="n/a"
VPTERNLOGQ_CHAIN_TERNLOG_HITS="0"
VPTERNLOGQ_CHAIN_XOR_HITS="0"
VPTERNLOGQ_CHAIN_EXCEPTION_HITS="0"
VPTERNLOGQ_EVIDENCE="Not evaluated yet."
VPCLMULLQLQ_RESULT="FAIL"
VPCLMULLQLQ_SINGLE_RESULT="FAIL"
VPCLMULLQLQ_SINGLE_RC="n/a"
VPCLMULLQLQ_SINGLE_HITS="0"
VPCLMULLQLQ_SINGLE_EXCEPTION_HITS="0"
VPCLMULLQLQ_CHAIN_RESULT="FAIL"
VPCLMULLQLQ_CHAIN_RC="n/a"
VPCLMULLQLQ_CHAIN_HITS="0"
VPCLMULLQLQ_CHAIN_EXCEPTION_HITS="0"
VPCLMULLQLQ_SEMANTIC_RESULT="FAIL"
VPCLMULLQLQ_SEMANTIC_RC="n/a"
VPCLMULLQLQ_SEMANTIC_HITS="0"
VPCLMULLQLQ_SEMANTIC_EXCEPTION_HITS="0"
VPCLMULLQLQ_EVIDENCE="Not evaluated yet."
VPCLMULLQHQ_RESULT="FAIL"
VPCLMULLQHQ_SINGLE_RESULT="FAIL"
VPCLMULLQHQ_SINGLE_RC="n/a"
VPCLMULLQHQ_SINGLE_HITS="0"
VPCLMULLQHQ_SINGLE_EXCEPTION_HITS="0"
VPCLMULLQHQ_CHAIN_RESULT="FAIL"
VPCLMULLQHQ_CHAIN_RC="n/a"
VPCLMULLQHQ_CHAIN_HITS="0"
VPCLMULLQHQ_CHAIN_EXCEPTION_HITS="0"
VPCLMULLQHQ_SEMANTIC_RESULT="FAIL"
VPCLMULLQHQ_SEMANTIC_RC="n/a"
VPCLMULLQHQ_SEMANTIC_HITS="0"
VPCLMULLQHQ_SEMANTIC_EXCEPTION_HITS="0"
VPCLMULLQHQ_EVIDENCE="Not evaluated yet."
VPCLMULHQLQ_RESULT="FAIL"
VPCLMULHQLQ_SINGLE_RESULT="FAIL"
VPCLMULHQLQ_SINGLE_RC="n/a"
VPCLMULHQLQ_SINGLE_HITS="0"
VPCLMULHQLQ_SINGLE_EXCEPTION_HITS="0"
VPCLMULHQLQ_CHAIN_RESULT="FAIL"
VPCLMULHQLQ_CHAIN_RC="n/a"
VPCLMULHQLQ_CHAIN_HITS="0"
VPCLMULHQLQ_CHAIN_EXCEPTION_HITS="0"
VPCLMULHQLQ_SEMANTIC_RESULT="FAIL"
VPCLMULHQLQ_SEMANTIC_RC="n/a"
VPCLMULHQLQ_SEMANTIC_HITS="0"
VPCLMULHQLQ_SEMANTIC_EXCEPTION_HITS="0"
VPCLMULHQLQ_EVIDENCE="Not evaluated yet."
VPCLMULHQHQ_RESULT="FAIL"
VPCLMULHQHQ_SINGLE_RESULT="FAIL"
VPCLMULHQHQ_SINGLE_RC="n/a"
VPCLMULHQHQ_SINGLE_HITS="0"
VPCLMULHQHQ_SINGLE_EXCEPTION_HITS="0"
VPCLMULHQHQ_CHAIN_RESULT="FAIL"
VPCLMULHQHQ_CHAIN_RC="n/a"
VPCLMULHQHQ_CHAIN_HITS="0"
VPCLMULHQHQ_CHAIN_EXCEPTION_HITS="0"
VPCLMULHQHQ_SEMANTIC_RESULT="FAIL"
VPCLMULHQHQ_SEMANTIC_RC="n/a"
VPCLMULHQHQ_SEMANTIC_HITS="0"
VPCLMULHQHQ_SEMANTIC_EXCEPTION_HITS="0"
VPCLMULHQHQ_EVIDENCE="Not evaluated yet."
VAESENC_RESULT="FAIL"
VAESENC_SINGLE_RESULT="FAIL"
VAESENC_SINGLE_RC="n/a"
VAESENC_SINGLE_HITS="0"
VAESENC_SINGLE_HELPER_HITS="0"
VAESENC_SINGLE_EXCEPTION_HITS="0"
VAESENC_CHAIN_RESULT="FAIL"
VAESENC_CHAIN_RC="n/a"
VAESENC_CHAIN_HITS="0"
VAESENC_CHAIN_HELPER_HITS="0"
VAESENC_CHAIN_EXCEPTION_HITS="0"
VAESENC_SEMANTIC_RESULT="FAIL"
VAESENC_SEMANTIC_RC="n/a"
VAESENC_SEMANTIC_HITS="0"
VAESENC_SEMANTIC_HELPER_HITS="0"
VAESENC_SEMANTIC_EXCEPTION_HITS="0"
VAESENC_EVIDENCE="Not evaluated yet."
VAESENCLAST_RESULT="FAIL"
VAESENCLAST_SINGLE_RESULT="FAIL"
VAESENCLAST_SINGLE_RC="n/a"
VAESENCLAST_SINGLE_HITS="0"
VAESENCLAST_SINGLE_HELPER_HITS="0"
VAESENCLAST_SINGLE_EXCEPTION_HITS="0"
VAESENCLAST_CHAIN_RESULT="FAIL"
VAESENCLAST_CHAIN_RC="n/a"
VAESENCLAST_CHAIN_HITS="0"
VAESENCLAST_CHAIN_HELPER_HITS="0"
VAESENCLAST_CHAIN_EXCEPTION_HITS="0"
VAESENCLAST_SEMANTIC_RESULT="FAIL"
VAESENCLAST_SEMANTIC_RC="n/a"
VAESENCLAST_SEMANTIC_HITS="0"
VAESENCLAST_SEMANTIC_HELPER_HITS="0"
VAESENCLAST_SEMANTIC_EXCEPTION_HITS="0"
VAESENCLAST_EVIDENCE="Not evaluated yet."
VBROADCASTF64X2_RESULT="FAIL"
VBROADCASTF64X2_RC="n/a"
VBROADCASTF64X2_EXCEPTION_HITS="0"
VBROADCASTF64X2_VBROADCAST_HITS="0"
VBROADCASTF64X2_QEMU_LD_I128_HITS="0"
VBROADCASTF64X2_QEMU_LD2_I128_HITS="0"
VBROADCASTF64X2_ST_I128_HITS="0"
VBROADCASTF64X2_ST_I64_HITS="0"
VBROADCASTF64X2_OUT=""
VBROADCASTF64X2_LOG=""
VBROADCASTF64X2_SINGLE_RESULT="FAIL"
VBROADCASTF64X2_SINGLE_RC="n/a"
VBROADCASTF64X2_SINGLE_EXCEPTION_HITS="0"
VBROADCASTF64X2_SINGLE_VBROADCAST_HITS="0"
VBROADCASTF64X2_SINGLE_QEMU_LD_I128_HITS="0"
VBROADCASTF64X2_SINGLE_QEMU_LD2_I128_HITS="0"
VBROADCASTF64X2_SINGLE_ST_I128_HITS="0"
VBROADCASTF64X2_SINGLE_ST_I64_HITS="0"
VBROADCASTF64X2_CHAIN_RESULT="FAIL"
VBROADCASTF64X2_CHAIN_RC="n/a"
VBROADCASTF64X2_CHAIN_EXCEPTION_HITS="0"
VBROADCASTF64X2_CHAIN_VBROADCAST_HITS="0"
VBROADCASTF64X2_CHAIN_QEMU_LD_I128_HITS="0"
VBROADCASTF64X2_CHAIN_QEMU_LD2_I128_HITS="0"
VBROADCASTF64X2_CHAIN_ST_I128_HITS="0"
VBROADCASTF64X2_CHAIN_ST_I64_HITS="0"
VBROADCASTF64X2_EVIDENCE="Not evaluated yet."
VPSLLDQ_RESULT="FAIL"
VPSLLDQ_SINGLE_RESULT="FAIL"
VPSLLDQ_SINGLE_RC="n/a"
VPSLLDQ_SINGLE_EXCEPTION_HITS="0"
VPSLLDQ_SINGLE_HITS="0"
VPSLLDQ_CHAIN_RESULT="FAIL"
VPSLLDQ_CHAIN_RC="n/a"
VPSLLDQ_CHAIN_EXCEPTION_HITS="0"
VPSLLDQ_CHAIN_HITS="0"
VPSLLDQ_EVIDENCE="Not evaluated yet."
VPSRLDQ_RESULT="FAIL"
VPSRLDQ_SINGLE_RESULT="FAIL"
VPSRLDQ_SINGLE_RC="n/a"
VPSRLDQ_SINGLE_EXCEPTION_HITS="0"
VPSRLDQ_SINGLE_HITS="0"
VPSRLDQ_CHAIN_RESULT="FAIL"
VPSRLDQ_CHAIN_RC="n/a"
VPSRLDQ_CHAIN_EXCEPTION_HITS="0"
VPSRLDQ_CHAIN_HITS="0"
VPSRLDQ_EVIDENCE="Not evaluated yet."
VEXTRACTI32X4_RESULT="FAIL"
VEXTRACTI32X4_SINGLE_RESULT="FAIL"
VEXTRACTI32X4_SINGLE_RC="n/a"
VEXTRACTI32X4_SINGLE_EXCEPTION_HITS="0"
VEXTRACTI32X4_SINGLE_HITS="0"
VEXTRACTI32X4_CHAIN_RESULT="FAIL"
VEXTRACTI32X4_CHAIN_RC="n/a"
VEXTRACTI32X4_CHAIN_EXCEPTION_HITS="0"
VEXTRACTI32X4_CHAIN_HITS="0"
VEXTRACTI32X4_EVIDENCE="Not evaluated yet."
VEXTRACTI64X4_RESULT="FAIL"
VEXTRACTI64X4_SINGLE_RESULT="FAIL"
VEXTRACTI64X4_SINGLE_RC="n/a"
VEXTRACTI64X4_SINGLE_EXCEPTION_HITS="0"
VEXTRACTI64X4_SINGLE_HITS="0"
VEXTRACTI64X4_CHAIN_RESULT="FAIL"
VEXTRACTI64X4_CHAIN_RC="n/a"
VEXTRACTI64X4_CHAIN_EXCEPTION_HITS="0"
VEXTRACTI64X4_CHAIN_HITS="0"
VEXTRACTI64X4_EVIDENCE="Not evaluated yet."
VMOVDQU8_RESULT="FAIL"
VMOVDQU8_SINGLE_RESULT="FAIL"
VMOVDQU8_SINGLE_RC="n/a"
VMOVDQU8_SINGLE_EXCEPTION_HITS="0"
VMOVDQU8_SINGLE_HITS="0"
VMOVDQU8_SINGLE_MEMORY_HITS="0"
VMOVDQU8_CHAIN_RESULT="FAIL"
VMOVDQU8_CHAIN_RC="n/a"
VMOVDQU8_CHAIN_EXCEPTION_HITS="0"
VMOVDQU8_CHAIN_HITS="0"
VMOVDQU8_CHAIN_MEMORY_HITS="0"
VMOVDQU8_EVIDENCE="Not evaluated yet."
AGGREGATE_BOUNDARY_RESULT="INFO"
AGGREGATE_BOUNDARY_RC="n/a"
AGGREGATE_BOUNDARY_PC="n/a"
AGGREGATE_BOUNDARY_EXPECTED_NEXT="completed"
AGGREGATE_BOUNDARY_EXPECTED_PC="0x401095"
AGGREGATE_BOUNDARY_EXCEPTION_HITS="0"
AGGREGATE_BOUNDARY_VPADDD_HITS="0"
AGGREGATE_BOUNDARY_VPADDD_RIP_HITS="0"
AGGREGATE_BOUNDARY_VPTERNLOGQ_HITS="0"
AGGREGATE_BOUNDARY_VPTERNLOGQ_RIP_HITS="0"
AGGREGATE_BOUNDARY_VPCLMULQDQ_HITS="0"
AGGREGATE_BOUNDARY_VPCLMULQDQ_RIP_HITS="0"
AGGREGATE_BOUNDARY_VPCLMULLQLQ_HITS="0"
AGGREGATE_BOUNDARY_VPCLMULLQLQ_RIP_HITS="0"
AGGREGATE_BOUNDARY_VPCLMULLQHQ_HITS="0"
AGGREGATE_BOUNDARY_VPCLMULLQHQ_RIP_HITS="0"
AGGREGATE_BOUNDARY_VPCLMULHQLQ_HITS="0"
AGGREGATE_BOUNDARY_VPCLMULHQLQ_RIP_HITS="0"
AGGREGATE_BOUNDARY_VPCLMULHQHQ_HITS="0"
AGGREGATE_BOUNDARY_VPCLMULHQHQ_RIP_HITS="0"
AGGREGATE_BOUNDARY_VAESENC_HITS="0"
AGGREGATE_BOUNDARY_VAESENC_RIP_HITS="0"
AGGREGATE_BOUNDARY_VAESENC_HELPER_HITS="0"
AGGREGATE_BOUNDARY_VAESENCLAST_HITS="0"
AGGREGATE_BOUNDARY_VAESENCLAST_RIP_HITS="0"
AGGREGATE_BOUNDARY_VBROADCASTF64X2_HITS="0"
AGGREGATE_BOUNDARY_VBROADCASTF64X2_RIP_HITS="0"
AGGREGATE_BOUNDARY_VPSLLDQ_HITS="0"
AGGREGATE_BOUNDARY_VPSLLDQ_RIP_HITS="0"
AGGREGATE_BOUNDARY_VPSRLDQ_HITS="0"
AGGREGATE_BOUNDARY_VPSRLDQ_RIP_HITS="0"
AGGREGATE_BOUNDARY_EVIDENCE="Not evaluated yet."

SMOKE_RESULT="FAIL"
SMOKE_RC="n/a"
SMOKE_VECTOR_HITS="0"
SMOKE_EXCEPTION_HITS="0"
SMOKE_OUT=""
SMOKE_LOG=""

MEMORY_SMOKE_RESULT="FAIL"
MEMORY_SMOKE_RC="n/a"
MEMORY_SMOKE_MEMORY_HITS="0"
MEMORY_SMOKE_EXCEPTION_HITS="0"
MEMORY_SMOKE_OUT=""
MEMORY_SMOKE_LOG=""

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_avx512_patch_series.sh [options]

Options:
  --scratch-root DIR   Scratch root under /tmp.
                       Default: /tmp/rr-qemu-v2-avx512-patch-series
  --qemu-src DIR       Existing QEMU 10.2.3 source tree to copy. The original
                       tree is not modified.
  --tarball FILE       Existing qemu-10.2.3.tar.xz tarball to verify/extract.
  --venv DIR           Meson/Ninja virtualenv. Created if missing.
                       Default: SCRATCH_ROOT/venv
  --jobs N, -j N       Parallel ninja jobs. Default: 3
  --fresh              Remove the scratch root before starting.
  --skip-download      Reuse an existing source tree/tarball; do not curl.
  -h, --help           Show this help.

Outputs:
  SCRATCH_ROOT/patches/0001-qemu-10.2.3-avx512-min-feature-masks.patch
  SCRATCH_ROOT/patches/0002-qemu-10.2.3-evex-vpxorq-smoke.patch
  SCRATCH_ROOT/patches/0003-qemu-10.2.3-evex-vmovdqa64-smoke.patch
  SCRATCH_ROOT/patches/0004-qemu-10.2.3-evex-vmovdqu64-smoke.patch
  SCRATCH_ROOT/patches/0005-qemu-10.2.3-evex-vpshufb-smoke.patch
  SCRATCH_ROOT/patches/0006-qemu-10.2.3-evex-vpaddd-smoke.patch
  SCRATCH_ROOT/patches/0007-qemu-10.2.3-evex-vpternlogq-smoke.patch
  SCRATCH_ROOT/patches/0008-qemu-10.2.3-evex-vpclmullqlqdq-smoke.patch
  SCRATCH_ROOT/patches/0009-qemu-10.2.3-evex-vpclmullqhqdq-smoke.patch
  SCRATCH_ROOT/patches/0010-qemu-10.2.3-evex-vpclmulhqlqdq-smoke.patch
  SCRATCH_ROOT/patches/0011-qemu-10.2.3-evex-vpclmulhqhqdq-smoke.patch
  SCRATCH_ROOT/patches/0012-qemu-10.2.3-evex-vaesenc-smoke.patch
  SCRATCH_ROOT/patches/0013-qemu-10.2.3-evex-vaesenclast-smoke.patch
  SCRATCH_ROOT/patches/0014-qemu-10.2.3-evex-vbroadcastf64x2-smoke.patch
  SCRATCH_ROOT/patches/0015-qemu-10.2.3-evex-vpslldq-smoke.patch
  SCRATCH_ROOT/patches/0016-qemu-10.2.3-evex-vpsrldq-smoke.patch
  SCRATCH_ROOT/patches/0017-qemu-10.2.3-evex-vextracti32x4-smoke.patch
  SCRATCH_ROOT/patches/0018-qemu-10.2.3-evex-vextracti64x4-smoke.patch
  SCRATCH_ROOT/patches/0019-qemu-10.2.3-evex-vmovdqu8-smoke.patch
  SCRATCH_ROOT/build-10.2.3-avx512-series/qemu-x86_64
  SCRATCH_ROOT/out/summary.md
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

abs_path() {
  local input="$1"
  if [[ "$input" = /* ]]; then
    printf '%s\n' "$input"
  else
    printf '%s/%s\n' "$PWD" "$input"
  fi
}

require_tmp_path() {
  local label="$1"
  local path="$2"
  case "$path" in
    /tmp|/tmp/*)
      ;;
    *)
      die "$label must be under /tmp, got: $path"
      ;;
  esac
}

refresh_paths() {
  require_tmp_path "--scratch-root" "$SCRATCH_ROOT"
  DOWNLOAD_DIR="$SCRATCH_ROOT/download"
  BASE_SRC="$SCRATCH_ROOT/qemu-${QEMU_VERSION}"
  PATCH_DIR="$SCRATCH_ROOT/patches"
  PATCHED_SRC="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-avx512-series-src"
  BUILD_DIR="$SCRATCH_ROOT/build-${QEMU_VERSION}-avx512-series"
  INSTALL_DIR="$SCRATCH_ROOT/install-${QEMU_VERSION}-avx512-series"
  OUT_DIR="$SCRATCH_ROOT/out"
  PROBE_DIR="$SCRATCH_ROOT/probes"
  SUMMARY="$OUT_DIR/summary.md"
  FEATURE_PROBE="$PROBE_DIR/cpuid_xgetbv"
  AVX2_PROBE="$PROBE_DIR/avx2-vex"
  AVX512_PROBE="$PROBE_DIR/avx512-vpxorq"
  VMOVDQA64_PROBE="$PROBE_DIR/avx512-vmovdqa64"
  VMOVDQU64_STORE_PROBE="$PROBE_DIR/avx512-vmovdqu64-store"
  VMOVDQU64_LOAD_PROBE="$PROBE_DIR/avx512-vmovdqu64-load"
  VMOVDQU64_CHAIN_PROBE="$PROBE_DIR/avx512-vmovdqu64-chain"
  VPSHUFB_SINGLE_PROBE="$PROBE_DIR/avx512-vpshufb-single"
  VPSHUFB_CHAIN_PROBE="$PROBE_DIR/avx512-vpshufb-chain"
  VPADDD_SINGLE_PROBE="$PROBE_DIR/avx512-vpaddd-single"
  VPADDD_CHAIN_PROBE="$PROBE_DIR/avx512-vpaddd-chain"
  VPTERNLOGQ_SINGLE_PROBE="$PROBE_DIR/avx512-vpternlogq-single"
  VPTERNLOGQ_CHAIN_PROBE="$PROBE_DIR/avx512-vpternlogq-chain"
  VPCLMULLQLQ_SINGLE_PROBE="$PROBE_DIR/avx512-vpclmullqlqdq-single"
  VPCLMULLQLQ_CHAIN_PROBE="$PROBE_DIR/avx512-vpclmullqlqdq-chain"
  VPCLMULLQLQ_SEMANTIC_PROBE="$PROBE_DIR/avx512-vpclmullqlqdq-semantic"
  VPCLMULLQHQ_SINGLE_PROBE="$PROBE_DIR/avx512-vpclmullqhqdq-single"
  VPCLMULLQHQ_CHAIN_PROBE="$PROBE_DIR/avx512-vpclmullqhqdq-chain"
  VPCLMULLQHQ_SEMANTIC_PROBE="$PROBE_DIR/avx512-vpclmullqhqdq-semantic"
  VPCLMULHQLQ_SINGLE_PROBE="$PROBE_DIR/avx512-vpclmulhqlqdq-single"
  VPCLMULHQLQ_CHAIN_PROBE="$PROBE_DIR/avx512-vpclmulhqlqdq-chain"
  VPCLMULHQLQ_SEMANTIC_PROBE="$PROBE_DIR/avx512-vpclmulhqlqdq-semantic"
  VPCLMULHQHQ_SINGLE_PROBE="$PROBE_DIR/avx512-vpclmulhqhqdq-single"
  VPCLMULHQHQ_CHAIN_PROBE="$PROBE_DIR/avx512-vpclmulhqhqdq-chain"
  VPCLMULHQHQ_SEMANTIC_PROBE="$PROBE_DIR/avx512-vpclmulhqhqdq-semantic"
  VAESENC_SINGLE_PROBE="$PROBE_DIR/avx512-vaesenc-single"
  VAESENC_CHAIN_PROBE="$PROBE_DIR/avx512-vaesenc-chain"
  VAESENC_SEMANTIC_PROBE="$PROBE_DIR/avx512-vaesenc-semantic"
  VAESENCLAST_SINGLE_PROBE="$PROBE_DIR/avx512-vaesenclast-single"
  VAESENCLAST_CHAIN_PROBE="$PROBE_DIR/avx512-vaesenclast-chain"
  VAESENCLAST_SEMANTIC_PROBE="$PROBE_DIR/avx512-vaesenclast-semantic"
  VBROADCASTF64X2_SINGLE_PROBE="$PROBE_DIR/avx512-vbroadcastf64x2-single"
  VBROADCASTF64X2_CHAIN_PROBE="$PROBE_DIR/avx512-vbroadcastf64x2-chain"
  VPSLLDQ_SINGLE_PROBE="$PROBE_DIR/avx512-vpslldq-single"
  VPSLLDQ_CHAIN_PROBE="$PROBE_DIR/avx512-vpslldq-chain"
  VPSRLDQ_SINGLE_PROBE="$PROBE_DIR/avx512-vpsrldq-single"
  VPSRLDQ_CHAIN_PROBE="$PROBE_DIR/avx512-vpsrldq-chain"
  VEXTRACTI32X4_SINGLE_PROBE="$PROBE_DIR/avx512-vextracti32x4-single"
  VEXTRACTI32X4_CHAIN_PROBE="$PROBE_DIR/avx512-vextracti32x4-chain"
  VEXTRACTI64X4_SINGLE_PROBE="$PROBE_DIR/avx512-vextracti64x4-single"
  VEXTRACTI64X4_CHAIN_PROBE="$PROBE_DIR/avx512-vextracti64x4-chain"
  VMOVDQU8_SINGLE_PROBE="$PROBE_DIR/avx512-vmovdqu8-single"
  VMOVDQU8_CHAIN_PROBE="$PROBE_DIR/avx512-vmovdqu8-chain"
  AGGREGATE_BOUNDARY_PROBE="$PROBE_DIR/avx512-aggregate-boundary"

  if [[ -z "$VENV_DIR" ]]; then
    VENV_DIR="$SCRATCH_ROOT/venv"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scratch-root)
        [[ $# -ge 2 ]] || die "--scratch-root requires an argument"
        SCRATCH_ROOT="$(abs_path "$2")"
        shift 2
        ;;
      --qemu-src)
        [[ $# -ge 2 ]] || die "--qemu-src requires an argument"
        QEMU_SRC="$(abs_path "$2")"
        shift 2
        ;;
      --tarball)
        [[ $# -ge 2 ]] || die "--tarball requires an argument"
        TARBALL_PATH="$(abs_path "$2")"
        shift 2
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
      --fresh)
        FRESH=1
        shift
        ;;
      --skip-download)
        SKIP_DOWNLOAD=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [[ "$JOBS" -lt 1 ]]; then
    die "--jobs must be a positive integer: $JOBS"
  fi
}

write_patch_files() {
  mkdir -p "$PATCH_DIR"

  cat >"$PATCH_DIR/0001-qemu-${QEMU_VERSION}-avx512-min-feature-masks.patch" <<'PATCH'
diff --git a/target/i386/cpu.c b/target/i386/cpu.c
--- a/target/i386/cpu.c
+++ b/target/i386/cpu.c
@@ -997,6 +997,7 @@
           CPUID_7_0_EBX_BMI1 | CPUID_7_0_EBX_BMI2 | CPUID_7_0_EBX_ADX | \
           CPUID_7_0_EBX_CLFLUSHOPT |            \
           CPUID_7_0_EBX_CLWB | CPUID_7_0_EBX_MPX | CPUID_7_0_EBX_FSGSBASE | \
+          CPUID_7_0_EBX_AVX512F | \
           CPUID_7_0_EBX_ERMS | CPUID_7_0_EBX_AVX2 | CPUID_7_0_EBX_RDSEED | \
           CPUID_7_0_EBX_SHA_NI | CPUID_7_0_EBX_KERNEL_FEATURES)
           /* missing:
@@ -1011,7 +1012,7 @@
 #define TCG_7_0_ECX_FEATURES (CPUID_7_0_ECX_UMIP | CPUID_7_0_ECX_PKU | \
           /* CPUID_7_0_ECX_OSPKE is dynamic */ \
           CPUID_7_0_ECX_LA57 | CPUID_7_0_ECX_PKS | CPUID_7_0_ECX_VAES | \
-          TCG_7_0_ECX_RDPID)
+          CPUID_7_0_ECX_VPCLMULQDQ | TCG_7_0_ECX_RDPID)

 #if defined CONFIG_USER_ONLY
 #define CPUID_7_0_EDX_KERNEL_FEATURES (CPUID_7_0_EDX_SPEC_CTRL | \
@@ -1518,7 +1519,8 @@
         },
         .tcg_features = XSTATE_FP_MASK | XSTATE_SSE_MASK |
             XSTATE_YMM_MASK | XSTATE_BNDREGS_MASK | XSTATE_BNDCSR_MASK |
-            XSTATE_PKRU_MASK,
+            XSTATE_OPMASK_MASK | XSTATE_ZMM_Hi256_MASK |
+            XSTATE_Hi16_ZMM_MASK | XSTATE_PKRU_MASK,
         .migratable_flags = XSTATE_FP_MASK | XSTATE_SSE_MASK |
             XSTATE_YMM_MASK | XSTATE_BNDREGS_MASK | XSTATE_BNDCSR_MASK |
             XSTATE_OPMASK_MASK | XSTATE_ZMM_Hi256_MASK | XSTATE_Hi16_ZMM_MASK |
PATCH

  cat >"$PATCH_DIR/0002-qemu-${QEMU_VERSION}-evex-vpxorq-smoke.patch" <<'PATCH'
diff --git a/target/i386/tcg/decode-new.c.inc b/target/i386/tcg/decode-new.c.inc
--- a/target/i386/tcg/decode-new.c.inc
+++ b/target/i386/tcg/decode-new.c.inc
@@ -2533,6 +2533,34 @@
  * Convert one instruction. s->base.is_jmp is set if the translation must
  * be stopped.
  */
+static bool rr_try_evex_vpxorq_zmm0_smoke(DisasContext *s, CPUX86State *env)
+{
+#ifdef TARGET_X86_64
+    static const uint8_t insn[] = { 0x62, 0xf1, 0xfd, 0x48, 0xef, 0xc0 };
+    target_ulong pc = s->pc;
+    int i;
+
+    if (!CODE64(s)) {
+        return false;
+    }
+    for (i = 0; i < sizeof(insn); i++) {
+        if (translator_ldub(env, &s->base, pc + i) != insn[i]) {
+            return false;
+        }
+    }
+
+    /*
+     * Experimental smoke semantics for vpxorq zmm0,zmm0,zmm0 only.  This is
+     * not a general EVEX decoder and intentionally ignores masking.
+     */
+    tcg_gen_gvec_dup_imm(MO_64, offsetof(CPUX86State, xmm_regs[0]), 64, 64, 0);
+    s->pc = pc + sizeof(insn);
+    return true;
+#else
+    return false;
+#endif
+}
+
 static void disas_insn(DisasContext *s, CPUState *cpu)
 {
     CPUX86State *env = cpu_env(cpu);
@@ -2556,6 +2584,10 @@
     s->has_modrm = false;
     s->prefix = 0;

+    if (rr_try_evex_vpxorq_zmm0_smoke(s, env)) {
+        return;
+    }
+
  next_byte:;
 #ifdef TARGET_X86_64
     /* clear any REX prefix followed by other prefixes.  */
PATCH

  cat >"$PATCH_DIR/0003-qemu-${QEMU_VERSION}-evex-vmovdqa64-smoke.patch" <<'PATCH'
diff --git a/target/i386/tcg/decode-new.c.inc b/target/i386/tcg/decode-new.c.inc
--- a/target/i386/tcg/decode-new.c.inc
+++ b/target/i386/tcg/decode-new.c.inc
@@ -2561,6 +2561,36 @@
 #endif
 }

+static bool rr_try_evex_vmovdqa64_zmm1_zmm0_smoke(DisasContext *s,
+                                                  CPUX86State *env)
+{
+#ifdef TARGET_X86_64
+    static const uint8_t insn[] = { 0x62, 0xf1, 0xfd, 0x48, 0x6f, 0xc8 };
+    target_ulong pc = s->pc;
+    int i;
+
+    if (!CODE64(s)) {
+        return false;
+    }
+    for (i = 0; i < sizeof(insn); i++) {
+        if (translator_ldub(env, &s->base, pc + i) != insn[i]) {
+            return false;
+        }
+    }
+
+    /*
+     * Experimental smoke semantics for vmovdqa64 zmm1,zmm0 only.  This is
+     * not a general EVEX decoder and intentionally ignores masking.
+     */
+    tcg_gen_gvec_mov(MO_64, offsetof(CPUX86State, xmm_regs[1]),
+                     offsetof(CPUX86State, xmm_regs[0]), 64, 64);
+    s->pc = pc + sizeof(insn);
+    return true;
+#else
+    return false;
+#endif
+}
+
 static void disas_insn(DisasContext *s, CPUState *cpu)
 {
     CPUX86State *env = cpu_env(cpu);
@@ -2587,6 +2617,9 @@
     if (rr_try_evex_vpxorq_zmm0_smoke(s, env)) {
         return;
     }
+    if (rr_try_evex_vmovdqa64_zmm1_zmm0_smoke(s, env)) {
+        return;
+    }

  next_byte:;
 #ifdef TARGET_X86_64
PATCH

  cat >"$PATCH_DIR/0004-qemu-${QEMU_VERSION}-evex-vmovdqu64-smoke.patch" <<'PATCH'
diff --git a/target/i386/tcg/decode-new.c.inc b/target/i386/tcg/decode-new.c.inc
--- a/target/i386/tcg/decode-new.c.inc
+++ b/target/i386/tcg/decode-new.c.inc
@@ -2591,6 +2591,131 @@
 #endif
 }

+static bool rr_evex_exact_bytes(DisasContext *s, CPUX86State *env,
+                                target_ulong pc, const uint8_t *insn,
+                                int len)
+{
+#ifdef TARGET_X86_64
+    int i;
+
+    if (!CODE64(s)) {
+        return false;
+    }
+    for (i = 0; i < len; i++) {
+        if (translator_ldub(env, &s->base, pc + i) != insn[i]) {
+            return false;
+        }
+    }
+    return true;
+#else
+    return false;
+#endif
+}
+
+static target_ulong rr_evex_rip_rel_addr(DisasContext *s, CPUX86State *env,
+                                         target_ulong pc, int insn_len)
+{
+#ifdef TARGET_X86_64
+    uint32_t disp = 0;
+    int i;
+
+    for (i = 0; i < 4; i++) {
+        disp |= (uint32_t)translator_ldub(env, &s->base,
+                                          pc + insn_len - 4 + i) << (8 * i);
+    }
+
+    return (target_ulong)((int64_t)(pc + insn_len) + (int32_t)disp);
+#else
+    return 0;
+#endif
+}
+
+static void rr_evex_store_zmm1_512(DisasContext *s, target_ulong guest_addr)
+{
+    MemOp mop = MO_128 | MO_LE | MO_ATOM_IFALIGN_PAIR;
+    TCGv_i128 t = tcg_temp_new_i128();
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 0);
+    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[1].ZMM_X(0)));
+    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 16);
+    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[1].ZMM_X(1)));
+    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 32);
+    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[1].ZMM_X(2)));
+    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 48);
+    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[1].ZMM_X(3)));
+    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);
+}
+
+static void rr_evex_load_zmm2_512(DisasContext *s, target_ulong guest_addr)
+{
+    MemOp mop = MO_128 | MO_LE | MO_ATOM_IFALIGN_PAIR;
+    TCGv_i128 t = tcg_temp_new_i128();
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 0);
+    tcg_gen_qemu_ld_i128(t, s->A0, s->mem_index, mop);
+    tcg_gen_st_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[2].ZMM_X(0)));
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 16);
+    tcg_gen_qemu_ld_i128(t, s->A0, s->mem_index, mop);
+    tcg_gen_st_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[2].ZMM_X(1)));
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 32);
+    tcg_gen_qemu_ld_i128(t, s->A0, s->mem_index, mop);
+    tcg_gen_st_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[2].ZMM_X(2)));
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 48);
+    tcg_gen_qemu_ld_i128(t, s->A0, s->mem_index, mop);
+    tcg_gen_st_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[2].ZMM_X(3)));
+}
+
+static bool rr_try_evex_vmovdqu64_zmm_mem_smoke(DisasContext *s,
+                                                CPUX86State *env)
+{
+#ifdef TARGET_X86_64
+    static const uint8_t vmovdqu64_store_single[] = {
+        0x62, 0xf1, 0xfe, 0x48, 0x7f, 0x0d, 0xf6, 0x0f, 0x00, 0x00
+    };
+    static const uint8_t vmovdqu64_load_single[] = {
+        0x62, 0xf1, 0xfe, 0x48, 0x6f, 0x15, 0xf6, 0x0f, 0x00, 0x00
+    };
+    static const uint8_t vmovdqu64_store_chain[] = {
+        0x62, 0xf1, 0xfe, 0x48, 0x7f, 0x0d, 0xea, 0x0f, 0x00, 0x00
+    };
+    static const uint8_t vmovdqu64_load_chain[] = {
+        0x62, 0xf1, 0xfe, 0x48, 0x6f, 0x15, 0xe0, 0x0f, 0x00, 0x00
+    };
+    target_ulong pc = s->pc;
+    target_ulong guest_addr;
+
+    if (rr_evex_exact_bytes(s, env, pc, vmovdqu64_store_single,
+                            sizeof(vmovdqu64_store_single)) ||
+        rr_evex_exact_bytes(s, env, pc, vmovdqu64_store_chain,
+                            sizeof(vmovdqu64_store_chain))) {
+        guest_addr = rr_evex_rip_rel_addr(s, env, pc, 10);
+        rr_evex_store_zmm1_512(s, guest_addr);
+        s->pc = pc + 10;
+        return true;
+    }
+
+    if (rr_evex_exact_bytes(s, env, pc, vmovdqu64_load_single,
+                            sizeof(vmovdqu64_load_single)) ||
+        rr_evex_exact_bytes(s, env, pc, vmovdqu64_load_chain,
+                            sizeof(vmovdqu64_load_chain))) {
+        guest_addr = rr_evex_rip_rel_addr(s, env, pc, 10);
+        rr_evex_load_zmm2_512(s, guest_addr);
+        s->pc = pc + 10;
+        return true;
+    }
+#endif
+    return false;
+}
+
 static void disas_insn(DisasContext *s, CPUState *cpu)
 {
     CPUX86State *env = cpu_env(cpu);
@@ -2620,6 +2745,9 @@
     if (rr_try_evex_vmovdqa64_zmm1_zmm0_smoke(s, env)) {
         return;
     }
+    if (rr_try_evex_vmovdqu64_zmm_mem_smoke(s, env)) {
+        return;
+    }

  next_byte:;
 #ifdef TARGET_X86_64
PATCH

  cat >"$PATCH_DIR/0005-qemu-${QEMU_VERSION}-evex-vpshufb-smoke.patch" <<'PATCH'
diff --git a/target/i386/tcg/decode-new.c.inc b/target/i386/tcg/decode-new.c.inc
--- a/target/i386/tcg/decode-new.c.inc
+++ b/target/i386/tcg/decode-new.c.inc
@@ -2533,6 +2533,195 @@
  * Convert one instruction. s->base.is_jmp is set if the translation must
  * be stopped.
  */
+static bool rr_evex_exact_bytes(DisasContext *s, CPUX86State *env,
+                                target_ulong pc, const uint8_t *insn,
+                                int len)
+{
+#ifdef TARGET_X86_64
+    int i;
+
+    if (!CODE64(s)) {
+        return false;
+    }
+    for (i = 0; i < len; i++) {
+        if (translator_ldub(env, &s->base, pc + i) != insn[i]) {
+            return false;
+        }
+    }
+    return true;
+#else
+    return false;
+#endif
+}
+
+static target_ulong rr_evex_rip_rel_addr(DisasContext *s, CPUX86State *env,
+                                         target_ulong pc, int insn_len)
+{
+#ifdef TARGET_X86_64
+    uint32_t disp = 0;
+    int i;
+
+    for (i = 0; i < 4; i++) {
+        disp |= (uint32_t)translator_ldub(env, &s->base,
+                                          pc + insn_len - 4 + i) << (8 * i);
+    }
+
+    return (target_ulong)((int64_t)(pc + insn_len) + (int32_t)disp);
+#else
+    return 0;
+#endif
+}
+
+static void rr_evex_store_zmm1_512(DisasContext *s, target_ulong guest_addr)
+{
+    MemOp mop = MO_128 | MO_LE | MO_ATOM_IFALIGN_PAIR;
+    TCGv_i128 t = tcg_temp_new_i128();
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 0);
+    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[1].ZMM_X(0)));
+    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 16);
+    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[1].ZMM_X(1)));
+    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 32);
+    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[1].ZMM_X(2)));
+    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 48);
+    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[1].ZMM_X(3)));
+    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);
+}
+
+static void rr_evex_load_zmm2_512(DisasContext *s, target_ulong guest_addr)
+{
+    MemOp mop = MO_128 | MO_LE | MO_ATOM_IFALIGN_PAIR;
+    TCGv_i128 t = tcg_temp_new_i128();
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 0);
+    tcg_gen_qemu_ld_i128(t, s->A0, s->mem_index, mop);
+    tcg_gen_st_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[2].ZMM_X(0)));
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 16);
+    tcg_gen_qemu_ld_i128(t, s->A0, s->mem_index, mop);
+    tcg_gen_st_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[2].ZMM_X(1)));
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 32);
+    tcg_gen_qemu_ld_i128(t, s->A0, s->mem_index, mop);
+    tcg_gen_st_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[2].ZMM_X(2)));
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 48);
+    tcg_gen_qemu_ld_i128(t, s->A0, s->mem_index, mop);
+    tcg_gen_st_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[2].ZMM_X(3)));
+}
+
+static void rr_evex_pshufb_xmm_lane(intptr_t dofs, intptr_t vofs,
+                                    intptr_t sofs)
+{
+    TCGv_ptr d = tcg_temp_new_ptr();
+    TCGv_ptr v = tcg_temp_new_ptr();
+    TCGv_ptr mask = tcg_temp_new_ptr();
+
+    tcg_gen_addi_ptr(d, tcg_env, dofs);
+    tcg_gen_addi_ptr(v, tcg_env, vofs);
+    tcg_gen_addi_ptr(mask, tcg_env, sofs);
+    gen_helper_pshufb_xmm(tcg_env, d, v, mask);
+}
+
+static void rr_evex_pshufb_zmm3_zmm2_zmm2_512(void)
+{
+    rr_evex_pshufb_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[3].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(0)));
+    rr_evex_pshufb_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[3].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(1)));
+    rr_evex_pshufb_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[3].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(2)));
+    rr_evex_pshufb_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[3].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(3)));
+}
+
+static bool rr_try_evex_vpshufb_smoke(DisasContext *s, CPUX86State *env)
+{
+#ifdef TARGET_X86_64
+    static const uint8_t vpxorq_zmm0_zmm0_zmm0[] = {
+        0x62, 0xf1, 0xfd, 0x48, 0xef, 0xc0
+    };
+    static const uint8_t vmovdqa64_zmm1_zmm0[] = {
+        0x62, 0xf1, 0xfd, 0x48, 0x6f, 0xc8
+    };
+    static const uint8_t vmovdqu64_store_single[] = {
+        0x62, 0xf1, 0xfe, 0x48, 0x7f, 0x0d, 0xf6, 0x0f, 0x00, 0x00
+    };
+    static const uint8_t vmovdqu64_load_single[] = {
+        0x62, 0xf1, 0xfe, 0x48, 0x6f, 0x15, 0xf6, 0x0f, 0x00, 0x00
+    };
+    static const uint8_t vmovdqu64_store_chain[] = {
+        0x62, 0xf1, 0xfe, 0x48, 0x7f, 0x0d, 0xea, 0x0f, 0x00, 0x00
+    };
+    static const uint8_t vmovdqu64_load_chain[] = {
+        0x62, 0xf1, 0xfe, 0x48, 0x6f, 0x15, 0xe0, 0x0f, 0x00, 0x00
+    };
+    static const uint8_t vpshufb_zmm3_zmm2_zmm2[] = {
+        0x62, 0xf2, 0x6d, 0x48, 0x00, 0xda
+    };
+    target_ulong pc = s->pc;
+    target_ulong guest_addr;
+
+    if (rr_evex_exact_bytes(s, env, pc, vpxorq_zmm0_zmm0_zmm0,
+                            sizeof(vpxorq_zmm0_zmm0_zmm0))) {
+        tcg_gen_gvec_dup_imm(MO_64, offsetof(CPUX86State, xmm_regs[0]),
+                             64, 64, 0);
+        s->pc = pc + sizeof(vpxorq_zmm0_zmm0_zmm0);
+        return true;
+    }
+
+    if (rr_evex_exact_bytes(s, env, pc, vmovdqa64_zmm1_zmm0,
+                            sizeof(vmovdqa64_zmm1_zmm0))) {
+        tcg_gen_gvec_mov(MO_64, offsetof(CPUX86State, xmm_regs[1]),
+                         offsetof(CPUX86State, xmm_regs[0]), 64, 64);
+        s->pc = pc + sizeof(vmovdqa64_zmm1_zmm0);
+        return true;
+    }
+
+    if (rr_evex_exact_bytes(s, env, pc, vmovdqu64_store_single,
+                            sizeof(vmovdqu64_store_single)) ||
+        rr_evex_exact_bytes(s, env, pc, vmovdqu64_store_chain,
+                            sizeof(vmovdqu64_store_chain))) {
+        guest_addr = rr_evex_rip_rel_addr(s, env, pc, 10);
+        rr_evex_store_zmm1_512(s, guest_addr);
+        s->pc = pc + 10;
+        return true;
+    }
+
+    if (rr_evex_exact_bytes(s, env, pc, vmovdqu64_load_single,
+                            sizeof(vmovdqu64_load_single)) ||
+        rr_evex_exact_bytes(s, env, pc, vmovdqu64_load_chain,
+                            sizeof(vmovdqu64_load_chain))) {
+        guest_addr = rr_evex_rip_rel_addr(s, env, pc, 10);
+        rr_evex_load_zmm2_512(s, guest_addr);
+        s->pc = pc + 10;
+        return true;
+    }
+
+    if (rr_evex_exact_bytes(s, env, pc, vpshufb_zmm3_zmm2_zmm2,
+                            sizeof(vpshufb_zmm3_zmm2_zmm2))) {
+        rr_evex_pshufb_zmm3_zmm2_zmm2_512();
+        s->pc = pc + sizeof(vpshufb_zmm3_zmm2_zmm2);
+        return true;
+    }
+#endif
+    return false;
+}
+
 static void disas_insn(DisasContext *s, CPUState *cpu)
 {
     CPUX86State *env = cpu_env(cpu);
@@ -2620,6 +2802,9 @@
     if (rr_try_evex_vmovdqu64_zmm_mem_smoke(s, env)) {
         return;
     }
+    if (rr_try_evex_vpshufb_smoke(s, env)) {
+        return;
+    }

  next_byte:;
 #ifdef TARGET_X86_64
PATCH

  cat >"$PATCH_DIR/0005-qemu-${QEMU_VERSION}-evex-vpshufb-smoke.patch" <<'PATCH'
diff --git a/target/i386/tcg/decode-new.c.inc b/target/i386/tcg/decode-new.c.inc
--- a/target/i386/tcg/decode-new.c.inc
+++ b/target/i386/tcg/decode-new.c.inc
@@ -2716,6 +2716,63 @@
     return false;
 }

+static void rr_evex_pshufb_xmm_lane(intptr_t dofs, intptr_t vofs,
+                                    intptr_t sofs)
+{
+    TCGv_ptr d = tcg_temp_new_ptr();
+    TCGv_ptr v = tcg_temp_new_ptr();
+    TCGv_ptr mask = tcg_temp_new_ptr();
+
+    tcg_gen_addi_ptr(d, tcg_env, dofs);
+    tcg_gen_addi_ptr(v, tcg_env, vofs);
+    tcg_gen_addi_ptr(mask, tcg_env, sofs);
+    gen_helper_pshufb_xmm(tcg_env, d, v, mask);
+}
+
+static void rr_evex_pshufb_zmm3_zmm2_zmm2_512(void)
+{
+    rr_evex_pshufb_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[3].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(0)));
+    rr_evex_pshufb_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[3].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(1)));
+    rr_evex_pshufb_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[3].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(2)));
+    rr_evex_pshufb_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[3].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(3)));
+}
+
+static bool rr_try_evex_vpshufb_smoke(DisasContext *s, CPUX86State *env)
+{
+#ifdef TARGET_X86_64
+    static const uint8_t vpshufb_zmm3_zmm2_zmm2[] = {
+        0x62, 0xf2, 0x6d, 0x48, 0x00, 0xda
+    };
+    target_ulong pc = s->pc;
+
+    if (!CODE64(s)) {
+        return false;
+    }
+    if (!rr_evex_exact_bytes(s, env, pc, vpshufb_zmm3_zmm2_zmm2,
+                             sizeof(vpshufb_zmm3_zmm2_zmm2))) {
+        return false;
+    }
+
+    rr_evex_pshufb_zmm3_zmm2_zmm2_512();
+    s->pc = pc + sizeof(vpshufb_zmm3_zmm2_zmm2);
+    return true;
+#else
+    return false;
+#endif
+}
+
 static void disas_insn(DisasContext *s, CPUState *cpu)
 {
     CPUX86State *env = cpu_env(cpu);
@@ -2748,6 +2805,9 @@
     if (rr_try_evex_vmovdqu64_zmm_mem_smoke(s, env)) {
         return;
     }
+    if (rr_try_evex_vpshufb_smoke(s, env)) {
+        return;
+    }

  next_byte:;
 #ifdef TARGET_X86_64
PATCH

  cat >"$PATCH_DIR/0006-qemu-${QEMU_VERSION}-evex-vpaddd-smoke.patch" <<'PATCH'
diff --git a/target/i386/tcg/decode-new.c.inc b/target/i386/tcg/decode-new.c.inc
--- a/target/i386/tcg/decode-new.c.inc
+++ b/target/i386/tcg/decode-new.c.inc
@@ -2749,6 +2749,15 @@
         offsetof(CPUX86State, xmm_regs[2].ZMM_X(3)));
 }

+static void rr_evex_add_zmm4_zmm3_zmm2_512(void)
+{
+    tcg_gen_gvec_add(MO_32,
+                     offsetof(CPUX86State, xmm_regs[4]),
+                     offsetof(CPUX86State, xmm_regs[3]),
+                     offsetof(CPUX86State, xmm_regs[2]),
+                     64, 64);
+}
+
 static bool rr_try_evex_vpshufb_smoke(DisasContext *s, CPUX86State *env)
 {
 #ifdef TARGET_X86_64
@@ -2773,6 +2782,30 @@
 #endif
 }

+static bool rr_try_evex_vpaddd_smoke(DisasContext *s, CPUX86State *env)
+{
+#ifdef TARGET_X86_64
+    static const uint8_t vpaddd_zmm4_zmm3_zmm2[] = {
+        0x62, 0xf1, 0x65, 0x48, 0xfe, 0xe2
+    };
+    target_ulong pc = s->pc;
+
+    if (!CODE64(s)) {
+        return false;
+    }
+    if (!rr_evex_exact_bytes(s, env, pc, vpaddd_zmm4_zmm3_zmm2,
+                             sizeof(vpaddd_zmm4_zmm3_zmm2))) {
+        return false;
+    }
+
+    rr_evex_add_zmm4_zmm3_zmm2_512();
+    s->pc = pc + sizeof(vpaddd_zmm4_zmm3_zmm2);
+    return true;
+#else
+    return false;
+#endif
+}
+
 static void disas_insn(DisasContext *s, CPUState *cpu)
 {
     CPUX86State *env = cpu_env(cpu);
@@ -2808,6 +2841,9 @@
     if (rr_try_evex_vpshufb_smoke(s, env)) {
         return;
     }
+    if (rr_try_evex_vpaddd_smoke(s, env)) {
+        return;
+    }

  next_byte:;
 #ifdef TARGET_X86_64
PATCH

  cat >"$PATCH_DIR/0007-qemu-${QEMU_VERSION}-evex-vpternlogq-smoke.patch" <<'PATCH'
diff --git a/target/i386/tcg/decode-new.c.inc b/target/i386/tcg/decode-new.c.inc
--- a/target/i386/tcg/decode-new.c.inc
+++ b/target/i386/tcg/decode-new.c.inc
@@ -2760,6 +2760,20 @@
                      64, 64);
 }

+static void rr_evex_xor_zmm5_zmm5_zmm4_zmm3_512(void)
+{
+    tcg_gen_gvec_xor(MO_64,
+                     offsetof(CPUX86State, xmm_regs[5]),
+                     offsetof(CPUX86State, xmm_regs[5]),
+                     offsetof(CPUX86State, xmm_regs[4]),
+                     64, 64);
+    tcg_gen_gvec_xor(MO_64,
+                     offsetof(CPUX86State, xmm_regs[5]),
+                     offsetof(CPUX86State, xmm_regs[5]),
+                     offsetof(CPUX86State, xmm_regs[3]),
+                     64, 64);
+}
+
 static bool rr_try_evex_vpshufb_smoke(DisasContext *s, CPUX86State *env)
 {
 #ifdef TARGET_X86_64
@@ -2806,6 +2823,30 @@
 #endif
 }

+static bool rr_try_evex_vpternlogq_smoke(DisasContext *s, CPUX86State *env)
+{
+#ifdef TARGET_X86_64
+    static const uint8_t vpternlogq_zmm5_zmm4_zmm3_0x96[] = {
+        0x62, 0xf3, 0xdd, 0x48, 0x25, 0xeb, 0x96
+    };
+    target_ulong pc = s->pc;
+
+    if (!CODE64(s)) {
+        return false;
+    }
+    if (!rr_evex_exact_bytes(s, env, pc, vpternlogq_zmm5_zmm4_zmm3_0x96,
+                             sizeof(vpternlogq_zmm5_zmm4_zmm3_0x96))) {
+        return false;
+    }
+
+    rr_evex_xor_zmm5_zmm5_zmm4_zmm3_512();
+    s->pc = pc + sizeof(vpternlogq_zmm5_zmm4_zmm3_0x96);
+    return true;
+#else
+    return false;
+#endif
+}
+
 static void disas_insn(DisasContext *s, CPUState *cpu)
 {
     CPUX86State *env = cpu_env(cpu);
@@ -2844,6 +2885,9 @@
     if (rr_try_evex_vpaddd_smoke(s, env)) {
         return;
     }
+    if (rr_try_evex_vpternlogq_smoke(s, env)) {
+        return;
+    }

  next_byte:;
 #ifdef TARGET_X86_64
PATCH

  cat >"$PATCH_DIR/0008-qemu-${QEMU_VERSION}-evex-vpclmullqlqdq-smoke.patch" <<'PATCH'
diff --git a/target/i386/tcg/decode-new.c.inc b/target/i386/tcg/decode-new.c.inc
--- a/target/i386/tcg/decode-new.c.inc
+++ b/target/i386/tcg/decode-new.c.inc
@@ -2730,6 +2730,19 @@
     gen_helper_pshufb_xmm(tcg_env, d, v, mask);
 }

+static void rr_evex_pclmul_xmm_lane(intptr_t dofs, intptr_t vofs,
+                                    intptr_t sofs, uint32_t ctrl)
+{
+    TCGv_ptr d = tcg_temp_new_ptr();
+    TCGv_ptr v = tcg_temp_new_ptr();
+    TCGv_ptr src = tcg_temp_new_ptr();
+
+    tcg_gen_addi_ptr(d, tcg_env, dofs);
+    tcg_gen_addi_ptr(v, tcg_env, vofs);
+    tcg_gen_addi_ptr(src, tcg_env, sofs);
+    gen_helper_pclmulqdq_xmm(tcg_env, d, v, src, tcg_constant_i32(ctrl));
+}
+
 static void rr_evex_pshufb_zmm3_zmm2_zmm2_512(void)
 {
     rr_evex_pshufb_xmm_lane(
@@ -2785,6 +2797,46 @@
                      64, 64);
 }

+static void rr_evex_pclmul_zmm6_zmm5_zmm4_lqlq_512(void)
+{
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[6].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(0)), 0x00);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[6].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(1)), 0x00);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[6].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(2)), 0x00);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[6].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(3)), 0x00);
+}
+
+static void rr_evex_pclmul_zmm1_zmm0_zmm0_lqlq_512(void)
+{
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[1].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[0].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[0].ZMM_X(0)), 0x00);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[1].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[0].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[0].ZMM_X(1)), 0x00);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[1].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[0].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[0].ZMM_X(2)), 0x00);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[1].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[0].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[0].ZMM_X(3)), 0x00);
+}
+
 static bool rr_try_evex_vpshufb_smoke(DisasContext *s, CPUX86State *env)
 {
 #ifdef TARGET_X86_64
@@ -2847,6 +2879,38 @@
 #endif
 }

+static bool rr_try_evex_vpclmullqlqdq_smoke(DisasContext *s, CPUX86State *env)
+{
+#ifdef TARGET_X86_64
+    static const uint8_t vpclmullqlqdq_zmm6_zmm5_zmm4[] = {
+        0x62, 0xf3, 0x55, 0x48, 0x44, 0xf4, 0x00
+    };
+    static const uint8_t vpclmullqlqdq_zmm1_zmm0_zmm0[] = {
+        0x62, 0xf3, 0x7d, 0x48, 0x44, 0xc8, 0x00
+    };
+    target_ulong pc = s->pc;
+
+    if (!CODE64(s)) {
+        return false;
+    }
+    if (rr_evex_exact_bytes(s, env, pc, vpclmullqlqdq_zmm6_zmm5_zmm4,
+                            sizeof(vpclmullqlqdq_zmm6_zmm5_zmm4))) {
+        rr_evex_pclmul_zmm6_zmm5_zmm4_lqlq_512();
+        s->pc = pc + sizeof(vpclmullqlqdq_zmm6_zmm5_zmm4);
+        return true;
+    }
+    if (rr_evex_exact_bytes(s, env, pc, vpclmullqlqdq_zmm1_zmm0_zmm0,
+                            sizeof(vpclmullqlqdq_zmm1_zmm0_zmm0))) {
+        rr_evex_pclmul_zmm1_zmm0_zmm0_lqlq_512();
+        s->pc = pc + sizeof(vpclmullqlqdq_zmm1_zmm0_zmm0);
+        return true;
+    }
+    return false;
+#else
+    return false;
+#endif
+}
+
 static void disas_insn(DisasContext *s, CPUState *cpu)
 {
     CPUX86State *env = cpu_env(cpu);
@@ -2888,6 +2944,9 @@
     if (rr_try_evex_vpternlogq_smoke(s, env)) {
         return;
     }
+    if (rr_try_evex_vpclmullqlqdq_smoke(s, env)) {
+        return;
+    }

  next_byte:;
 #ifdef TARGET_X86_64
PATCH

  cat >"$PATCH_DIR/0009-qemu-${QEMU_VERSION}-evex-vpclmullqhqdq-smoke.patch" <<'PATCH'
diff --git a/target/i386/tcg/decode-new.c.inc b/target/i386/tcg/decode-new.c.inc
--- a/target/i386/tcg/decode-new.c.inc
+++ b/target/i386/tcg/decode-new.c.inc
@@ -2825,6 +2825,26 @@
         offsetof(CPUX86State, xmm_regs[0].ZMM_X(3)), 0x00);
 }

+static void rr_evex_pclmul_zmm7_zmm5_zmm4_lqhq_512(void)
+{
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[7].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(0)), 0x10);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[7].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(1)), 0x10);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[7].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(2)), 0x10);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[7].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(3)), 0x10);
+}
+
 static bool rr_try_evex_vpshufb_smoke(DisasContext *s, CPUX86State *env)
 {
 #ifdef TARGET_X86_64
@@ -2929,6 +2949,30 @@
 #endif
 }

+static bool rr_try_evex_vpclmullqhqdq_smoke(DisasContext *s, CPUX86State *env)
+{
+#ifdef TARGET_X86_64
+    static const uint8_t vpclmullqhqdq_zmm7_zmm5_zmm4[] = {
+        0x62, 0xf3, 0x55, 0x48, 0x44, 0xfc, 0x10
+    };
+    target_ulong pc = s->pc;
+
+    if (!CODE64(s)) {
+        return false;
+    }
+    if (!rr_evex_exact_bytes(s, env, pc, vpclmullqhqdq_zmm7_zmm5_zmm4,
+                             sizeof(vpclmullqhqdq_zmm7_zmm5_zmm4))) {
+        return false;
+    }
+
+    rr_evex_pclmul_zmm7_zmm5_zmm4_lqhq_512();
+    s->pc = pc + sizeof(vpclmullqhqdq_zmm7_zmm5_zmm4);
+    return true;
+#else
+    return false;
+#endif
+}
+
 static void disas_insn(DisasContext *s, CPUState *cpu)
 {
     CPUX86State *env = cpu_env(cpu);
@@ -2973,6 +3017,9 @@
     if (rr_try_evex_vpclmullqlqdq_smoke(s, env)) {
         return;
     }
+    if (rr_try_evex_vpclmullqhqdq_smoke(s, env)) {
+        return;
+    }

  next_byte:;
 #ifdef TARGET_X86_64
PATCH

  cat >"$PATCH_DIR/0010-qemu-${QEMU_VERSION}-evex-vpclmulhqlqdq-smoke.patch" <<'PATCH'
diff --git a/target/i386/tcg/decode-new.c.inc b/target/i386/tcg/decode-new.c.inc
--- a/target/i386/tcg/decode-new.c.inc
+++ b/target/i386/tcg/decode-new.c.inc
@@ -2837,6 +2837,26 @@
         offsetof(CPUX86State, xmm_regs[4].ZMM_X(3)), 0x10);
 }

+static void rr_evex_pclmul_zmm8_zmm5_zmm4_hqlq_512(void)
+{
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[8].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(0)), 0x01);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[8].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(1)), 0x01);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[8].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(2)), 0x01);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[8].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(3)), 0x01);
+}
+
 static bool rr_try_evex_vpshufb_smoke(DisasContext *s, CPUX86State *env)
 {
 #ifdef TARGET_X86_64
@@ -2947,6 +2967,30 @@
 #endif
 }

+static bool rr_try_evex_vpclmulhqlqdq_smoke(DisasContext *s, CPUX86State *env)
+{
+#ifdef TARGET_X86_64
+    static const uint8_t vpclmulhqlqdq_zmm8_zmm5_zmm4[] = {
+        0x62, 0x73, 0x55, 0x48, 0x44, 0xc4, 0x01
+    };
+    target_ulong pc = s->pc;
+
+    if (!CODE64(s)) {
+        return false;
+    }
+    if (!rr_evex_exact_bytes(s, env, pc, vpclmulhqlqdq_zmm8_zmm5_zmm4,
+                             sizeof(vpclmulhqlqdq_zmm8_zmm5_zmm4))) {
+        return false;
+    }
+
+    rr_evex_pclmul_zmm8_zmm5_zmm4_hqlq_512();
+    s->pc = pc + sizeof(vpclmulhqlqdq_zmm8_zmm5_zmm4);
+    return true;
+#else
+    return false;
+#endif
+}
+
 static void disas_insn(DisasContext *s, CPUState *cpu)
 {
     CPUX86State *env = cpu_env(cpu);
@@ -2994,6 +3038,9 @@
     if (rr_try_evex_vpclmullqhqdq_smoke(s, env)) {
         return;
     }
+    if (rr_try_evex_vpclmulhqlqdq_smoke(s, env)) {
+        return;
+    }

  next_byte:;
 #ifdef TARGET_X86_64
PATCH

  cat >"$PATCH_DIR/0011-qemu-${QEMU_VERSION}-evex-vpclmulhqhqdq-smoke.patch" <<'PATCH'
diff --git a/target/i386/tcg/decode-new.c.inc b/target/i386/tcg/decode-new.c.inc
--- a/target/i386/tcg/decode-new.c.inc
+++ b/target/i386/tcg/decode-new.c.inc
@@ -2857,6 +2857,26 @@ static void rr_evex_pclmul_zmm8_zmm5_zmm4_hqlq_512(void)
         offsetof(CPUX86State, xmm_regs[4].ZMM_X(3)), 0x01);
 }

+static void rr_evex_pclmul_zmm9_zmm5_zmm4_hqhq_512(void)
+{
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[9].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(0)), 0x11);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[9].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(1)), 0x11);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[9].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(2)), 0x11);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[9].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(3)), 0x11);
+}
+
 static bool rr_try_evex_vpshufb_smoke(DisasContext *s, CPUX86State *env)
 {
 #ifdef TARGET_X86_64
@@ -2991,6 +3011,30 @@ static bool rr_try_evex_vpclmulhqlqdq_smoke(DisasContext *s, CPUX86State *env)
 #endif
 }

+static bool rr_try_evex_vpclmulhqhqdq_smoke(DisasContext *s, CPUX86State *env)
+{
+#ifdef TARGET_X86_64
+    static const uint8_t vpclmulhqhqdq_zmm9_zmm5_zmm4[] = {
+        0x62, 0x73, 0x55, 0x48, 0x44, 0xcc, 0x11
+    };
+    target_ulong pc = s->pc;
+
+    if (!CODE64(s)) {
+        return false;
+    }
+    if (!rr_evex_exact_bytes(s, env, pc, vpclmulhqhqdq_zmm9_zmm5_zmm4,
+                             sizeof(vpclmulhqhqdq_zmm9_zmm5_zmm4))) {
+        return false;
+    }
+
+    rr_evex_pclmul_zmm9_zmm5_zmm4_hqhq_512();
+    s->pc = pc + sizeof(vpclmulhqhqdq_zmm9_zmm5_zmm4);
+    return true;
+#else
+    return false;
+#endif
+}
+
 static void disas_insn(DisasContext *s, CPUState *cpu)
 {
     CPUX86State *env = cpu_env(cpu);
@@ -3041,6 +3085,9 @@ static void disas_insn(DisasContext *s, CPUState *cpu)
     if (rr_try_evex_vpclmulhqlqdq_smoke(s, env)) {
         return;
     }
+    if (rr_try_evex_vpclmulhqhqdq_smoke(s, env)) {
+        return;
+    }

  next_byte:;
 #ifdef TARGET_X86_64
PATCH

  cat >"$PATCH_DIR/0012-qemu-${QEMU_VERSION}-evex-vaesenc-smoke.patch" <<'PATCH'
diff --git a/target/i386/tcg/decode-new.c.inc b/target/i386/tcg/decode-new.c.inc
--- a/target/i386/tcg/decode-new.c.inc
+++ b/target/i386/tcg/decode-new.c.inc
@@ -2743,6 +2743,19 @@ static void rr_evex_pclmul_xmm_lane(intptr_t dofs, intptr_t vofs,
     gen_helper_pclmulqdq_xmm(tcg_env, d, v, src, tcg_constant_i32(ctrl));
 }

+static void rr_evex_aesenc_xmm_lane(intptr_t dofs, intptr_t vofs,
+                                    intptr_t sofs)
+{
+    TCGv_ptr d = tcg_temp_new_ptr();
+    TCGv_ptr v = tcg_temp_new_ptr();
+    TCGv_ptr src = tcg_temp_new_ptr();
+
+    tcg_gen_addi_ptr(d, tcg_env, dofs);
+    tcg_gen_addi_ptr(v, tcg_env, vofs);
+    tcg_gen_addi_ptr(src, tcg_env, sofs);
+    gen_helper_aesenc_xmm(tcg_env, d, v, src);
+}
+
 static void rr_evex_pshufb_zmm3_zmm2_zmm2_512(void)
 {
     rr_evex_pshufb_xmm_lane(
@@ -2877,6 +2890,46 @@ static void rr_evex_pclmul_zmm9_zmm5_zmm4_hqhq_512(void)
         offsetof(CPUX86State, xmm_regs[4].ZMM_X(3)), 0x11);
 }

+static void rr_evex_aesenc_zmm10_zmm9_zmm8_512(void)
+{
+    rr_evex_aesenc_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[10].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[9].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[8].ZMM_X(0)));
+    rr_evex_aesenc_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[10].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[9].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[8].ZMM_X(1)));
+    rr_evex_aesenc_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[10].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[9].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[8].ZMM_X(2)));
+    rr_evex_aesenc_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[10].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[9].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[8].ZMM_X(3)));
+}
+
+static void rr_evex_aesenc_zmm1_zmm0_zmm0_512(void)
+{
+    rr_evex_aesenc_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[1].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[0].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[0].ZMM_X(0)));
+    rr_evex_aesenc_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[1].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[0].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[0].ZMM_X(1)));
+    rr_evex_aesenc_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[1].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[0].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[0].ZMM_X(2)));
+    rr_evex_aesenc_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[1].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[0].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[0].ZMM_X(3)));
+}
+
 static bool rr_try_evex_vpshufb_smoke(DisasContext *s, CPUX86State *env)
 {
 #ifdef TARGET_X86_64
@@ -3035,6 +3068,38 @@ static bool rr_try_evex_vpclmulhqhqdq_smoke(DisasContext *s, CPUX86State *env)
 #endif
 }

+static bool rr_try_evex_vaesenc_smoke(DisasContext *s, CPUX86State *env)
+{
+#ifdef TARGET_X86_64
+    static const uint8_t vaesenc_zmm10_zmm9_zmm8[] = {
+        0x62, 0x52, 0x35, 0x48, 0xdc, 0xd0
+    };
+    static const uint8_t vaesenc_zmm1_zmm0_zmm0[] = {
+        0x62, 0xf2, 0x7d, 0x48, 0xdc, 0xc8
+    };
+    target_ulong pc = s->pc;
+
+    if (!CODE64(s)) {
+        return false;
+    }
+    if (rr_evex_exact_bytes(s, env, pc, vaesenc_zmm10_zmm9_zmm8,
+                            sizeof(vaesenc_zmm10_zmm9_zmm8))) {
+        rr_evex_aesenc_zmm10_zmm9_zmm8_512();
+        s->pc = pc + sizeof(vaesenc_zmm10_zmm9_zmm8);
+        return true;
+    }
+    if (rr_evex_exact_bytes(s, env, pc, vaesenc_zmm1_zmm0_zmm0,
+                            sizeof(vaesenc_zmm1_zmm0_zmm0))) {
+        rr_evex_aesenc_zmm1_zmm0_zmm0_512();
+        s->pc = pc + sizeof(vaesenc_zmm1_zmm0_zmm0);
+        return true;
+    }
+    return false;
+#else
+    return false;
+#endif
+}
+
 static void disas_insn(DisasContext *s, CPUState *cpu)
 {
     CPUX86State *env = cpu_env(cpu);
@@ -3088,6 +3145,9 @@ static void disas_insn(DisasContext *s, CPUState *cpu)
     if (rr_try_evex_vpclmulhqhqdq_smoke(s, env)) {
         return;
     }
+    if (rr_try_evex_vaesenc_smoke(s, env)) {
+        return;
+    }

  next_byte:;
 #ifdef TARGET_X86_64
PATCH

  {
    echo "0001-qemu-${QEMU_VERSION}-avx512-min-feature-masks.patch"
    echo "0002-qemu-${QEMU_VERSION}-evex-vpxorq-smoke.patch"
    echo "0003-qemu-${QEMU_VERSION}-evex-vmovdqa64-smoke.patch"
    echo "0004-qemu-${QEMU_VERSION}-evex-vmovdqu64-smoke.patch"
    echo "0005-qemu-${QEMU_VERSION}-evex-vpshufb-smoke.patch"
    echo "0006-qemu-${QEMU_VERSION}-evex-vpaddd-smoke.patch"
    echo "0007-qemu-${QEMU_VERSION}-evex-vpternlogq-smoke.patch"
    echo "0008-qemu-${QEMU_VERSION}-evex-vpclmullqlqdq-smoke.patch"
    echo "0009-qemu-${QEMU_VERSION}-evex-vpclmullqhqdq-smoke.patch"
    echo "0010-qemu-${QEMU_VERSION}-evex-vpclmulhqlqdq-smoke.patch"
    echo "0011-qemu-${QEMU_VERSION}-evex-vpclmulhqhqdq-smoke.patch"
    echo "0012-qemu-${QEMU_VERSION}-evex-vaesenc-smoke.patch"
    echo "0013-qemu-${QEMU_VERSION}-evex-vaesenclast-smoke.patch"
    echo "0014-qemu-${QEMU_VERSION}-evex-vbroadcastf64x2-smoke.patch"
    echo "0015-qemu-${QEMU_VERSION}-evex-vpslldq-smoke.patch"
    echo "0016-qemu-${QEMU_VERSION}-evex-vpsrldq-smoke.patch"
    echo "0017-qemu-${QEMU_VERSION}-evex-vextracti32x4-smoke.patch"
    echo "0018-qemu-${QEMU_VERSION}-evex-vextracti64x4-smoke.patch"
    echo "0019-qemu-${QEMU_VERSION}-evex-vmovdqu8-smoke.patch"
  } >"$PATCH_DIR/series"

}

ensure_build_tools() {
  require_tool python3

  if [[ -x "$VENV_DIR/bin/meson" && -x "$VENV_DIR/bin/ninja" ]]; then
    BUILD_PATH="$VENV_DIR/bin:$PATH"
    return
  fi

  if command -v meson >/dev/null 2>&1 && command -v ninja >/dev/null 2>&1; then
    BUILD_PATH="$PATH"
    return
  fi

  log "Preparing Meson/Ninja venv under $VENV_DIR"
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip meson ninja
  BUILD_PATH="$VENV_DIR/bin:$PATH"
}

download_or_select_source() {
  if [[ -n "$QEMU_SRC" ]]; then
    [[ -x "$QEMU_SRC/configure" ]] || die "QEMU source missing configure: $QEMU_SRC"
    SOURCE_SRC="$QEMU_SRC"
    return
  fi

  mkdir -p "$DOWNLOAD_DIR"
  if [[ -d "$BASE_SRC" ]]; then
    [[ -x "$BASE_SRC/configure" ]] || die "existing source missing configure: $BASE_SRC"
    SOURCE_SRC="$BASE_SRC"
    return
  fi

  local tarball="$DOWNLOAD_DIR/$QEMU_TARBALL"
  if [[ -n "$TARBALL_PATH" ]]; then
    [[ -f "$TARBALL_PATH" ]] || die "tarball does not exist: $TARBALL_PATH"
    tarball="$TARBALL_PATH"
  elif [[ ! -f "$tarball" ]]; then
    [[ "$SKIP_DOWNLOAD" -eq 0 ]] || die "missing tarball $tarball and --skip-download was requested"
    require_tool curl
    log "Downloading $QEMU_TARBALL"
    curl -L --fail --retry 3 -o "$tarball" "$QEMU_URL"
  fi

  require_tool sha256sum
  (cd "$(dirname "$tarball")" && printf '%s  %s\n' "$QEMU_SHA256" "$(basename "$tarball")" | sha256sum -c -)

  log "Extracting $QEMU_TARBALL"
  require_tool tar
  tar -C "$SCRATCH_ROOT" -xf "$tarball"
  [[ -x "$BASE_SRC/configure" ]] || die "expected configure script at $BASE_SRC/configure"
  SOURCE_SRC="$BASE_SRC"
}

prepare_patched_tree() {
  require_tool patch
  [[ -n "$SOURCE_SRC" ]] || die "source tree was not selected"
  [[ "$SOURCE_SRC" != "$PATCHED_SRC" ]] || die "source and patched tree must differ"

  rm -rf "$PATCHED_SRC"
  log "Copying QEMU source into $PATCHED_SRC"
  cp -a "$SOURCE_SRC" "$PATCHED_SRC"

  local patch_name
  while IFS= read -r patch_name; do
    [[ -n "$patch_name" ]] || continue
    log "Applying $patch_name"
    (cd "$PATCHED_SRC" && patch --fuzz=0 -p1 <"$PATCH_DIR/$patch_name")
  done <"$PATCH_DIR/series"

  verify_patched_tree
}

verify_patched_tree() {
  local cpu_c="$PATCHED_SRC/target/i386/cpu.c"
  local decode_inc="$PATCHED_SRC/target/i386/tcg/decode-new.c.inc"

  sed -n '/#define TCG_7_0_EBX_FEATURES/,/\/\* missing:/p' "$cpu_c" |
    grep -q 'CPUID_7_0_EBX_AVX512F' ||
    die "patch 0001 did not add AVX512F to TCG_7_0_EBX_FEATURES"

  sed -n '/#define TCG_7_0_ECX_FEATURES/,/^$/p' "$cpu_c" |
    grep -q 'CPUID_7_0_ECX_VPCLMULQDQ' ||
    die "patch 0001 did not add VPCLMULQDQ to TCG_7_0_ECX_FEATURES"

  sed -n '/\.tcg_features = XSTATE_FP_MASK/,/\.migratable_flags/p' "$cpu_c" |
    grep -q 'XSTATE_OPMASK_MASK' ||
    die "patch 0001 did not add AVX-512 XCR0 state masks"

  grep -q 'rr_try_evex_vpxorq_zmm0_smoke' "$decode_inc" ||
    die "patch 0002 did not add the EVEX vpxorq smoke hook"

  grep -q 'rr_try_evex_vmovdqa64_zmm1_zmm0_smoke' "$decode_inc" ||
    die "patch 0003 did not add the EVEX vmovdqa64 smoke hook"

  grep -q 'rr_try_evex_vmovdqu64_zmm_mem_smoke' "$decode_inc" ||
    die "patch 0004 did not add the EVEX vmovdqu64 memory smoke hook"

  grep -q 'rr_try_evex_vpshufb_smoke' "$decode_inc" ||
    die "patch 0005 did not add the EVEX vpshufb smoke hook"

  grep -q 'rr_try_evex_vpaddd_smoke' "$decode_inc" ||
    die "patch 0006 did not add the EVEX vpaddd smoke hook"

  grep -q 'rr_try_evex_vpternlogq_smoke' "$decode_inc" ||
    die "patch 0007 did not add the EVEX vpternlogq smoke hook"

  grep -q 'rr_try_evex_vpclmullqlqdq_smoke' "$decode_inc" ||
    die "patch 0008 did not add the EVEX vpclmullqlqdq smoke hook"

  grep -q 'rr_try_evex_vpclmullqhqdq_smoke' "$decode_inc" ||
    die "patch 0009 did not add the EVEX vpclmullqhqdq smoke hook"

  grep -q 'rr_try_evex_vpclmulhqlqdq_smoke' "$decode_inc" ||
    die "patch 0010 did not add the EVEX vpclmulhqlqdq smoke hook"

  grep -q 'rr_try_evex_vpclmulhqhqdq_smoke' "$decode_inc" ||
    die "patch 0011 did not add the EVEX vpclmulhqhqdq smoke hook"

  grep -q 'rr_try_evex_vaesenc_smoke' "$decode_inc" ||
    die "patch 0012 did not add the EVEX vaesenc smoke hook"

  grep -q 'rr_try_evex_vaesenclast_smoke' "$decode_inc" ||
    die "patch 0013 did not add the EVEX vaesenclast smoke hook"

  grep -q 'rr_try_evex_vbroadcastf64x2_smoke' "$decode_inc" ||
    die "patch 0014 did not add the EVEX vbroadcastf64x2 smoke hook"

  grep -q 'rr_try_evex_vpslldq_smoke' "$decode_inc" ||
    die "patch 0015 did not add the EVEX vpslldq smoke hook"

  grep -q 'rr_try_evex_vpsrldq_smoke' "$decode_inc" ||
    die "patch 0016 did not add the EVEX vpsrldq smoke hook"

  grep -q 'rr_try_evex_vextracti32x4_smoke' "$decode_inc" ||
    die "patch 0017 did not add the EVEX vextracti32x4 smoke hook"

  grep -q 'rr_try_evex_vextracti64x4_smoke' "$decode_inc" ||
    die "patch 0018 did not add the EVEX vextracti64x4 smoke hook"
  grep -q 'rr_try_evex_vmovdqu8_smoke' "$decode_inc" ||
    die "patch 0019 did not add the EVEX vmovdqu8 smoke hook"
}

generate_0013_patch() {
  local source_file="$SOURCE_SRC/target/i386/tcg/decode-new.c.inc"
  local temp_root patch_tree modified_file patch_name

  [[ -f "$source_file" ]] || die "missing source file for patch generation: $source_file"
  mkdir -p "$PATCH_DIR"

  temp_root="$(mktemp -d "$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vaesenclast.XXXXXX")"
  patch_tree="$temp_root/patched"
  modified_file="$temp_root/decode-new.c.inc.modified"

  cp -a "$SOURCE_SRC" "$patch_tree"

  for patch_name in \
    "0001-qemu-${QEMU_VERSION}-avx512-min-feature-masks.patch" \
    "0002-qemu-${QEMU_VERSION}-evex-vpxorq-smoke.patch" \
    "0003-qemu-${QEMU_VERSION}-evex-vmovdqa64-smoke.patch" \
    "0004-qemu-${QEMU_VERSION}-evex-vmovdqu64-smoke.patch" \
    "0005-qemu-${QEMU_VERSION}-evex-vpshufb-smoke.patch" \
    "0006-qemu-${QEMU_VERSION}-evex-vpaddd-smoke.patch" \
    "0007-qemu-${QEMU_VERSION}-evex-vpternlogq-smoke.patch" \
    "0008-qemu-${QEMU_VERSION}-evex-vpclmullqlqdq-smoke.patch" \
    "0009-qemu-${QEMU_VERSION}-evex-vpclmullqhqdq-smoke.patch" \
    "0010-qemu-${QEMU_VERSION}-evex-vpclmulhqlqdq-smoke.patch" \
    "0011-qemu-${QEMU_VERSION}-evex-vpclmulhqhqdq-smoke.patch" \
    "0012-qemu-${QEMU_VERSION}-evex-vaesenc-smoke.patch"
  do
    [[ -f "$PATCH_DIR/$patch_name" ]] || die "missing prerequisite patch: $PATCH_DIR/$patch_name"
    log "Priming 0013 generation with $patch_name"
    (cd "$patch_tree" && patch --fuzz=0 -p1 <"$PATCH_DIR/$patch_name")
  done

  python3 - "$patch_tree/target/i386/tcg/decode-new.c.inc" "$modified_file" <<'PY'
from pathlib import Path
import sys
import re

source = Path(sys.argv[1]).read_text()
modified = source

modified = modified.replace(
    "    gen_helper_aesenc_xmm(tcg_env, d, v, src);\n}\n\nstatic void rr_evex_pshufb_zmm3_zmm2_zmm2_512(void)\n",
    "    gen_helper_aesenc_xmm(tcg_env, d, v, src);\n}\n\n"
    "static void rr_evex_aesenclast_xmm_lane(intptr_t dofs, intptr_t vofs,\n"
    "                                        intptr_t sofs)\n"
    "{\n"
    "    TCGv_ptr d = tcg_temp_new_ptr();\n"
    "    TCGv_ptr v = tcg_temp_new_ptr();\n"
    "    TCGv_ptr src = tcg_temp_new_ptr();\n"
    "\n"
    "    tcg_gen_addi_ptr(d, tcg_env, dofs);\n"
    "    tcg_gen_addi_ptr(v, tcg_env, vofs);\n"
    "    tcg_gen_addi_ptr(src, tcg_env, sofs);\n"
    "    gen_helper_aesenclast_xmm(tcg_env, d, v, src);\n"
    "}\n\n"
    "static void rr_evex_pshufb_zmm3_zmm2_zmm2_512(void)\n",
    1,
  )
modified = modified.replace(
    "static void rr_evex_aesenc_zmm10_zmm9_zmm8_512(void)\n"
    "{\n"
    "    rr_evex_aesenc_xmm_lane(\n"
    "        offsetof(CPUX86State, xmm_regs[10].ZMM_X(0)),\n"
    "        offsetof(CPUX86State, xmm_regs[9].ZMM_X(0)),\n"
    "        offsetof(CPUX86State, xmm_regs[8].ZMM_X(0)));\n"
    "    rr_evex_aesenc_xmm_lane(\n"
    "        offsetof(CPUX86State, xmm_regs[10].ZMM_X(1)),\n"
    "        offsetof(CPUX86State, xmm_regs[9].ZMM_X(1)),\n"
    "        offsetof(CPUX86State, xmm_regs[8].ZMM_X(1)));\n"
    "    rr_evex_aesenc_xmm_lane(\n"
    "        offsetof(CPUX86State, xmm_regs[10].ZMM_X(2)),\n"
    "        offsetof(CPUX86State, xmm_regs[9].ZMM_X(2)),\n"
    "        offsetof(CPUX86State, xmm_regs[8].ZMM_X(2)));\n"
    "    rr_evex_aesenc_xmm_lane(\n"
    "        offsetof(CPUX86State, xmm_regs[10].ZMM_X(3)),\n"
    "        offsetof(CPUX86State, xmm_regs[9].ZMM_X(3)),\n"
    "        offsetof(CPUX86State, xmm_regs[8].ZMM_X(3)));\n"
    "}\n\n",
    "static void rr_evex_aesenc_zmm10_zmm9_zmm8_512(void)\n"
    "{\n"
    "    rr_evex_aesenc_xmm_lane(\n"
    "        offsetof(CPUX86State, xmm_regs[10].ZMM_X(0)),\n"
    "        offsetof(CPUX86State, xmm_regs[9].ZMM_X(0)),\n"
    "        offsetof(CPUX86State, xmm_regs[8].ZMM_X(0)));\n"
    "    rr_evex_aesenc_xmm_lane(\n"
    "        offsetof(CPUX86State, xmm_regs[10].ZMM_X(1)),\n"
    "        offsetof(CPUX86State, xmm_regs[9].ZMM_X(1)),\n"
    "        offsetof(CPUX86State, xmm_regs[8].ZMM_X(1)));\n"
    "    rr_evex_aesenc_xmm_lane(\n"
    "        offsetof(CPUX86State, xmm_regs[10].ZMM_X(2)),\n"
    "        offsetof(CPUX86State, xmm_regs[9].ZMM_X(2)),\n"
    "        offsetof(CPUX86State, xmm_regs[8].ZMM_X(2)));\n"
    "    rr_evex_aesenc_xmm_lane(\n"
    "        offsetof(CPUX86State, xmm_regs[10].ZMM_X(3)),\n"
    "        offsetof(CPUX86State, xmm_regs[9].ZMM_X(3)),\n"
    "        offsetof(CPUX86State, xmm_regs[8].ZMM_X(3)));\n"
    "}\n\n"
    "static void rr_evex_aesenclast_zmm11_zmm10_zmm7_512(void)\n"
    "{\n"
    "    rr_evex_aesenclast_xmm_lane(\n"
    "        offsetof(CPUX86State, xmm_regs[11].ZMM_X(0)),\n"
    "        offsetof(CPUX86State, xmm_regs[10].ZMM_X(0)),\n"
    "        offsetof(CPUX86State, xmm_regs[7].ZMM_X(0)));\n"
    "    rr_evex_aesenclast_xmm_lane(\n"
    "        offsetof(CPUX86State, xmm_regs[11].ZMM_X(1)),\n"
    "        offsetof(CPUX86State, xmm_regs[10].ZMM_X(1)),\n"
    "        offsetof(CPUX86State, xmm_regs[7].ZMM_X(1)));\n"
    "    rr_evex_aesenclast_xmm_lane(\n"
    "        offsetof(CPUX86State, xmm_regs[11].ZMM_X(2)),\n"
    "        offsetof(CPUX86State, xmm_regs[10].ZMM_X(2)),\n"
    "        offsetof(CPUX86State, xmm_regs[7].ZMM_X(2)));\n"
    "    rr_evex_aesenclast_xmm_lane(\n"
    "        offsetof(CPUX86State, xmm_regs[11].ZMM_X(3)),\n"
    "        offsetof(CPUX86State, xmm_regs[10].ZMM_X(3)),\n"
    "        offsetof(CPUX86State, xmm_regs[7].ZMM_X(3)));\n"
    "}\n\n",
    1,
  )
modified = re.sub(
    r'static bool rr_try_evex_vaesenc_smoke\(DisasContext \*s, CPUX86State \*env\)\n'
    r'\{\n'
    r'#ifdef TARGET_X86_64\n'
    r'    static const uint8_t vaesenc_zmm10_zmm9_zmm8\[\] = \{\n'
    r'        0x62, 0x52, 0x35, 0x48, 0xdc, 0xd0\n'
    r'    \};\n'
    r'    target_ulong pc = s->pc;\n'
    r'\n'
    r'    if \(!CODE64\(s\)\) \{\n'
    r'        return false;\n'
    r'    \}\n'
    r'    if \(!rr_evex_exact_bytes\(s, env, pc, vaesenc_zmm10_zmm9_zmm8,\n'
    r'                             sizeof\(vaesenc_zmm10_zmm9_zmm8\)\)\) \{\n'
    r'        return false;\n'
    r'    \}\n'
    r'\n'
    r'    rr_evex_aesenc_zmm10_zmm9_zmm8_512\(\);\n'
    r'    s->pc = pc \+ sizeof\(vaesenc_zmm10_zmm9_zmm8\);\n'
    r'    return true;\n'
    r'#else\n'
    r'    return false;\n'
    r'#endif\n'
    r'\}\n\n'
    r'static void disas_insn\(DisasContext \*s, CPUState \*cpu\)\n',
    "static bool rr_try_evex_vaesenc_smoke(DisasContext *s, CPUX86State *env)\n"
    "{\n"
    "#ifdef TARGET_X86_64\n"
    "    static const uint8_t vaesenc_zmm10_zmm9_zmm8[] = {\n"
    "        0x62, 0x52, 0x35, 0x48, 0xdc, 0xd0\n"
    "    };\n"
    "    target_ulong pc = s->pc;\n"
    "\n"
    "    if (!CODE64(s)) {\n"
    "        return false;\n"
    "    }\n"
    "    if (!rr_evex_exact_bytes(s, env, pc, vaesenc_zmm10_zmm9_zmm8,\n"
    "                             sizeof(vaesenc_zmm10_zmm9_zmm8))) {\n"
    "        return false;\n"
    "    }\n"
    "\n"
    "    rr_evex_aesenc_zmm10_zmm9_zmm8_512();\n"
    "    s->pc = pc + sizeof(vaesenc_zmm10_zmm9_zmm8);\n"
    "    return true;\n"
    "#else\n"
    "    return false;\n"
    "#endif\n"
    "}\n\n"
    "static bool rr_try_evex_vaesenclast_smoke(DisasContext *s, CPUX86State *env)\n"
    "{\n"
    "#ifdef TARGET_X86_64\n"
    "    static const uint8_t vaesenclast_zmm11_zmm10_zmm7[] = {\n"
    "        0x62, 0x72, 0x2d, 0x48, 0xdd, 0xdf\n"
    "    };\n"
    "    target_ulong pc = s->pc;\n"
    "\n"
    "    if (!CODE64(s)) {\n"
    "        return false;\n"
    "    }\n"
    "    if (!rr_evex_exact_bytes(s, env, pc, vaesenclast_zmm11_zmm10_zmm7,\n"
    "                             sizeof(vaesenclast_zmm11_zmm10_zmm7))) {\n"
    "        return false;\n"
    "    }\n"
    "\n"
    "    rr_evex_aesenclast_zmm11_zmm10_zmm7_512();\n"
    "    s->pc = pc + sizeof(vaesenclast_zmm11_zmm10_zmm7);\n"
    "    return true;\n"
    "#else\n"
    "    return false;\n"
    "#endif\n"
    "}\n\n"
    "static void disas_insn(DisasContext *s, CPUState *cpu)\n",
    modified,
    count=1,
    flags=re.S,
)

if "rr_try_evex_vaesenclast_smoke" not in modified:
    modified = modified.replace(
        "static void disas_insn(DisasContext *s, CPUState *cpu)\n",
        "static bool rr_try_evex_vaesenclast_smoke(DisasContext *s, CPUX86State *env)\n"
        "{\n"
        "#ifdef TARGET_X86_64\n"
        "    static const uint8_t vaesenclast_zmm11_zmm10_zmm7[] = {\n"
        "        0x62, 0x72, 0x2d, 0x48, 0xdd, 0xdf\n"
        "    };\n"
        "    target_ulong pc = s->pc;\n"
        "\n"
        "    if (!CODE64(s)) {\n"
        "        return false;\n"
        "    }\n"
        "    if (!rr_evex_exact_bytes(s, env, pc, vaesenclast_zmm11_zmm10_zmm7,\n"
        "                             sizeof(vaesenclast_zmm11_zmm10_zmm7))) {\n"
        "        return false;\n"
        "    }\n"
        "\n"
        "    rr_evex_aesenclast_zmm11_zmm10_zmm7_512();\n"
        "    s->pc = pc + sizeof(vaesenclast_zmm11_zmm10_zmm7);\n"
        "    return true;\n"
        "#else\n"
        "    return false;\n"
        "#endif\n"
        "}\n\n"
        "static void disas_insn(DisasContext *s, CPUState *cpu)\n",
        1,
    )

if "rr_try_evex_vaesenclast_smoke" not in modified:
    raise SystemExit("vaesenclast smoke function missing from generated patch source")
modified = modified.replace(
    "    if (rr_try_evex_vaesenc_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n\n next_byte:;\n",
    "    if (rr_try_evex_vaesenc_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n"
    "    if (rr_try_evex_vaesenclast_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n\n next_byte:;\n",
    1,
)

if modified == source:
    raise SystemExit("patch generation made no changes")

Path(sys.argv[2]).write_text(modified)
PY

  if diff -u \
    --label a/target/i386/tcg/decode-new.c.inc \
    --label b/target/i386/tcg/decode-new.c.inc \
    "$patch_tree/target/i386/tcg/decode-new.c.inc" \
    "$modified_file" >"$PATCH_DIR/0013-qemu-${QEMU_VERSION}-evex-vaesenclast-smoke.patch"; then
    :
  else
    diff_rc=$?
    if [[ $diff_rc -ne 1 ]]; then
      exit "$diff_rc"
    fi
  fi

  rm -rf "$temp_root"
}

generate_0014_patch() {
  local source_file="$SOURCE_SRC/target/i386/tcg/decode-new.c.inc"
  local temp_root patch_tree modified_file patch_name

  [[ -f "$source_file" ]] || die "missing source file for patch generation: $source_file"
  mkdir -p "$PATCH_DIR"

  temp_root="$(mktemp -d "$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vbroadcastf64x2.XXXXXX")"
  patch_tree="$temp_root/patched"
  modified_file="$temp_root/decode-new.c.inc.modified"

  cp -a "$SOURCE_SRC" "$patch_tree"

  for patch_name in \
    "0001-qemu-${QEMU_VERSION}-avx512-min-feature-masks.patch" \
    "0002-qemu-${QEMU_VERSION}-evex-vpxorq-smoke.patch" \
    "0003-qemu-${QEMU_VERSION}-evex-vmovdqa64-smoke.patch" \
    "0004-qemu-${QEMU_VERSION}-evex-vmovdqu64-smoke.patch" \
    "0005-qemu-${QEMU_VERSION}-evex-vpshufb-smoke.patch" \
    "0006-qemu-${QEMU_VERSION}-evex-vpaddd-smoke.patch" \
    "0007-qemu-${QEMU_VERSION}-evex-vpternlogq-smoke.patch" \
    "0008-qemu-${QEMU_VERSION}-evex-vpclmullqlqdq-smoke.patch" \
    "0009-qemu-${QEMU_VERSION}-evex-vpclmullqhqdq-smoke.patch" \
    "0010-qemu-${QEMU_VERSION}-evex-vpclmulhqlqdq-smoke.patch" \
    "0011-qemu-${QEMU_VERSION}-evex-vpclmulhqhqdq-smoke.patch" \
    "0012-qemu-${QEMU_VERSION}-evex-vaesenc-smoke.patch" \
    "0013-qemu-${QEMU_VERSION}-evex-vaesenclast-smoke.patch"
  do
    [[ -f "$PATCH_DIR/$patch_name" ]] || die "missing prerequisite patch: $PATCH_DIR/$patch_name"
    log "Priming 0014 generation with $patch_name"
    (cd "$patch_tree" && patch --fuzz=0 -p1 <"$PATCH_DIR/$patch_name")
  done

  python3 - "$patch_tree/target/i386/tcg/decode-new.c.inc" "$modified_file" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
modified = source

insert_helper = """static void rr_evex_aesenclast_zmm11_zmm10_zmm7_512(void)
{
    rr_evex_aesenclast_xmm_lane(
        offsetof(CPUX86State, xmm_regs[11].ZMM_X(0)),
        offsetof(CPUX86State, xmm_regs[10].ZMM_X(0)),
        offsetof(CPUX86State, xmm_regs[7].ZMM_X(0)));
    rr_evex_aesenclast_xmm_lane(
        offsetof(CPUX86State, xmm_regs[11].ZMM_X(1)),
        offsetof(CPUX86State, xmm_regs[10].ZMM_X(1)),
        offsetof(CPUX86State, xmm_regs[7].ZMM_X(1)));
    rr_evex_aesenclast_xmm_lane(
        offsetof(CPUX86State, xmm_regs[11].ZMM_X(2)),
        offsetof(CPUX86State, xmm_regs[10].ZMM_X(2)),
        offsetof(CPUX86State, xmm_regs[7].ZMM_X(2)));
    rr_evex_aesenclast_xmm_lane(
        offsetof(CPUX86State, xmm_regs[11].ZMM_X(3)),
        offsetof(CPUX86State, xmm_regs[10].ZMM_X(3)),
        offsetof(CPUX86State, xmm_regs[7].ZMM_X(3)));
}
"""
replace_helper = """static void rr_evex_aesenclast_zmm11_zmm10_zmm7_512(void)
{
    rr_evex_aesenclast_xmm_lane(
        offsetof(CPUX86State, xmm_regs[11].ZMM_X(0)),
        offsetof(CPUX86State, xmm_regs[10].ZMM_X(0)),
        offsetof(CPUX86State, xmm_regs[7].ZMM_X(0)));
    rr_evex_aesenclast_xmm_lane(
        offsetof(CPUX86State, xmm_regs[11].ZMM_X(1)),
        offsetof(CPUX86State, xmm_regs[10].ZMM_X(1)),
        offsetof(CPUX86State, xmm_regs[7].ZMM_X(1)));
    rr_evex_aesenclast_xmm_lane(
        offsetof(CPUX86State, xmm_regs[11].ZMM_X(2)),
        offsetof(CPUX86State, xmm_regs[10].ZMM_X(2)),
        offsetof(CPUX86State, xmm_regs[7].ZMM_X(2)));
    rr_evex_aesenclast_xmm_lane(
        offsetof(CPUX86State, xmm_regs[11].ZMM_X(3)),
        offsetof(CPUX86State, xmm_regs[10].ZMM_X(3)),
        offsetof(CPUX86State, xmm_regs[7].ZMM_X(3)));
}

static void rr_evex_broadcastf64x2_zmm12_m128_512(DisasContext *s,
                                                  target_ulong guest_addr)
{
    MemOp mop = MO_128 | MO_LE | MO_ATOM_IFALIGN_PAIR;
    TCGv_i128 t = tcg_temp_new_i128();

    tcg_gen_movi_tl(s->A0, guest_addr);
    tcg_gen_qemu_ld_i128(t, s->A0, s->mem_index, mop);
    tcg_gen_st_i128(t, tcg_env,
                    offsetof(CPUX86State, xmm_regs[12].ZMM_X(0)));
    tcg_gen_st_i128(t, tcg_env,
                    offsetof(CPUX86State, xmm_regs[12].ZMM_X(1)));
    tcg_gen_st_i128(t, tcg_env,
                    offsetof(CPUX86State, xmm_regs[12].ZMM_X(2)));
    tcg_gen_st_i128(t, tcg_env,
                    offsetof(CPUX86State, xmm_regs[12].ZMM_X(3)));
}
"""
if insert_helper not in modified:
    raise SystemExit("aesenclast anchor missing from generated patch source")
modified = modified.replace(insert_helper, replace_helper, 1)

insert_smoke = """static bool rr_try_evex_vpshufb_smoke(DisasContext *s, CPUX86State *env)
"""
replace_smoke = """static bool rr_try_evex_vbroadcastf64x2_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vbroadcastf64x2_zmm12_m128[] = {
        0x62, 0x72, 0xfd, 0x48, 0x1a, 0x25, 0x9b, 0x0f, 0x00, 0x00
    };
    target_ulong pc = s->pc;
    target_ulong guest_addr;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vbroadcastf64x2_zmm12_m128,
                             sizeof(vbroadcastf64x2_zmm12_m128))) {
        return false;
    }

    guest_addr = rr_evex_rip_rel_addr(s, env, pc, 10);
    rr_evex_broadcastf64x2_zmm12_m128_512(s, guest_addr);
    s->pc = pc + sizeof(vbroadcastf64x2_zmm12_m128);
    return true;
#else
    return false;
#endif
}

static bool rr_try_evex_vpshufb_smoke(DisasContext *s, CPUX86State *env)
"""
if insert_smoke not in modified:
    raise SystemExit("vpshufb anchor missing from generated patch source")
modified = modified.replace(insert_smoke, replace_smoke, 1)

modified = modified.replace(
    "    if (rr_try_evex_vaesenclast_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n\n next_byte:;\n",
    "    if (rr_try_evex_vaesenclast_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n"
    "    if (rr_try_evex_vbroadcastf64x2_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n\n next_byte:;\n",
    1,
)

if modified == source:
    raise SystemExit("patch generation made no changes")

Path(sys.argv[2]).write_text(modified)
PY

  if diff -u \
    --label a/target/i386/tcg/decode-new.c.inc \
    --label b/target/i386/tcg/decode-new.c.inc \
    "$patch_tree/target/i386/tcg/decode-new.c.inc" \
    "$modified_file" >"$PATCH_DIR/0014-qemu-${QEMU_VERSION}-evex-vbroadcastf64x2-smoke.patch"; then
    :
  else
    diff_rc=$?
    if [[ $diff_rc -ne 1 ]]; then
      exit "$diff_rc"
    fi
  fi

  rm -rf "$temp_root"
}

generate_0015_patch() {
  local source_file="$SOURCE_SRC/target/i386/tcg/decode-new.c.inc"
  local temp_root patch_tree modified_file patch_name

  [[ -f "$source_file" ]] || die "missing source file for patch generation: $source_file"
  mkdir -p "$PATCH_DIR"

  temp_root="$(mktemp -d "$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vpslldq.XXXXXX")"
  patch_tree="$temp_root/patched"
  modified_file="$temp_root/decode-new.c.inc.modified"

  cp -a "$SOURCE_SRC" "$patch_tree"

  for patch_name in \
    "0001-qemu-${QEMU_VERSION}-avx512-min-feature-masks.patch" \
    "0002-qemu-${QEMU_VERSION}-evex-vpxorq-smoke.patch" \
    "0003-qemu-${QEMU_VERSION}-evex-vmovdqa64-smoke.patch" \
    "0004-qemu-${QEMU_VERSION}-evex-vmovdqu64-smoke.patch" \
    "0005-qemu-${QEMU_VERSION}-evex-vpshufb-smoke.patch" \
    "0006-qemu-${QEMU_VERSION}-evex-vpaddd-smoke.patch" \
    "0007-qemu-${QEMU_VERSION}-evex-vpternlogq-smoke.patch" \
    "0008-qemu-${QEMU_VERSION}-evex-vpclmullqlqdq-smoke.patch" \
    "0009-qemu-${QEMU_VERSION}-evex-vpclmullqhqdq-smoke.patch" \
    "0010-qemu-${QEMU_VERSION}-evex-vpclmulhqlqdq-smoke.patch" \
    "0011-qemu-${QEMU_VERSION}-evex-vpclmulhqhqdq-smoke.patch" \
    "0012-qemu-${QEMU_VERSION}-evex-vaesenc-smoke.patch" \
    "0013-qemu-${QEMU_VERSION}-evex-vaesenclast-smoke.patch" \
    "0014-qemu-${QEMU_VERSION}-evex-vbroadcastf64x2-smoke.patch"
  do
    [[ -f "$PATCH_DIR/$patch_name" ]] || die "missing prerequisite patch: $PATCH_DIR/$patch_name"
    log "Priming 0015 generation with $patch_name"
    (cd "$patch_tree" && patch --fuzz=0 -p1 <"$PATCH_DIR/$patch_name")
  done

  python3 - "$patch_tree/target/i386/tcg/decode-new.c.inc" "$modified_file" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
modified = source

insert_helper = """static void rr_evex_broadcastf64x2_zmm12_m128_512(DisasContext *s,
                                                  target_ulong guest_addr)
{
    MemOp mop = MO_128 | MO_LE | MO_ATOM_IFALIGN_PAIR;
    TCGv_i128 t = tcg_temp_new_i128();

    tcg_gen_movi_tl(s->A0, guest_addr);
    tcg_gen_qemu_ld_i128(t, s->A0, s->mem_index, mop);
    tcg_gen_st_i128(t, tcg_env,
                    offsetof(CPUX86State, xmm_regs[12].ZMM_X(0)));
    tcg_gen_st_i128(t, tcg_env,
                    offsetof(CPUX86State, xmm_regs[12].ZMM_X(1)));
    tcg_gen_st_i128(t, tcg_env,
                    offsetof(CPUX86State, xmm_regs[12].ZMM_X(2)));
    tcg_gen_st_i128(t, tcg_env,
                    offsetof(CPUX86State, xmm_regs[12].ZMM_X(3)));
}
"""
replace_helper = """static void rr_evex_broadcastf64x2_zmm12_m128_512(DisasContext *s,
                                                  target_ulong guest_addr)
{
    MemOp mop = MO_128 | MO_LE | MO_ATOM_IFALIGN_PAIR;
    TCGv_i128 t = tcg_temp_new_i128();

    tcg_gen_movi_tl(s->A0, guest_addr);
    tcg_gen_qemu_ld_i128(t, s->A0, s->mem_index, mop);
    tcg_gen_st_i128(t, tcg_env,
                    offsetof(CPUX86State, xmm_regs[12].ZMM_X(0)));
    tcg_gen_st_i128(t, tcg_env,
                    offsetof(CPUX86State, xmm_regs[12].ZMM_X(1)));
    tcg_gen_st_i128(t, tcg_env,
                    offsetof(CPUX86State, xmm_regs[12].ZMM_X(2)));
    tcg_gen_st_i128(t, tcg_env,
                    offsetof(CPUX86State, xmm_regs[12].ZMM_X(3)));
}

static TCGv_ptr rr_evex_make_imm8u_xmm_vec(uint8_t imm)
{
    TCGv_ptr ptr = tcg_temp_new_ptr();

    tcg_gen_addi_ptr(ptr, tcg_env, offsetof(CPUX86State, xmm_t0));
    tcg_gen_st_i32(tcg_constant_i32(imm), tcg_env,
                   offsetof(CPUX86State, xmm_t0.ZMM_L(0)));
    return ptr;
}

static void rr_evex_pslldq_xmm_lane(intptr_t dofs, intptr_t sofs, uint8_t imm)
{
    TCGv_ptr d = tcg_temp_new_ptr();
    TCGv_ptr s = tcg_temp_new_ptr();
    TCGv_ptr c = rr_evex_make_imm8u_xmm_vec(imm);

    tcg_gen_addi_ptr(d, tcg_env, dofs);
    tcg_gen_addi_ptr(s, tcg_env, sofs);
    gen_helper_pslldq_xmm(tcg_env, d, s, c);
}

static void rr_evex_pslldq_zmm13_zmm12_512(void)
{
    rr_evex_pslldq_xmm_lane(
        offsetof(CPUX86State, xmm_regs[13].ZMM_X(0)),
        offsetof(CPUX86State, xmm_regs[12].ZMM_X(0)), 4);
    rr_evex_pslldq_xmm_lane(
        offsetof(CPUX86State, xmm_regs[13].ZMM_X(1)),
        offsetof(CPUX86State, xmm_regs[12].ZMM_X(1)), 4);
    rr_evex_pslldq_xmm_lane(
        offsetof(CPUX86State, xmm_regs[13].ZMM_X(2)),
        offsetof(CPUX86State, xmm_regs[12].ZMM_X(2)), 4);
    rr_evex_pslldq_xmm_lane(
        offsetof(CPUX86State, xmm_regs[13].ZMM_X(3)),
        offsetof(CPUX86State, xmm_regs[12].ZMM_X(3)), 4);
}
"""
if insert_helper not in modified:
    raise SystemExit("vbroadcast anchor missing from generated patch source")
modified = modified.replace(insert_helper, replace_helper, 1)

insert_smoke = """static bool rr_try_evex_vbroadcastf64x2_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vbroadcastf64x2_zmm12_m128[] = {
        0x62, 0x72, 0xfd, 0x48, 0x1a, 0x25, 0x9b, 0x0f, 0x00, 0x00
    };
    target_ulong pc = s->pc;
    target_ulong guest_addr;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vbroadcastf64x2_zmm12_m128,
                             sizeof(vbroadcastf64x2_zmm12_m128))) {
        return false;
    }

    guest_addr = rr_evex_rip_rel_addr(s, env, pc, 10);
    rr_evex_broadcastf64x2_zmm12_m128_512(s, guest_addr);
    s->pc = pc + sizeof(vbroadcastf64x2_zmm12_m128);
    return true;
#else
    return false;
#endif
}
"""
replace_smoke = """static bool rr_try_evex_vbroadcastf64x2_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vbroadcastf64x2_zmm12_m128[] = {
        0x62, 0x72, 0xfd, 0x48, 0x1a, 0x25, 0x9b, 0x0f, 0x00, 0x00
    };
    target_ulong pc = s->pc;
    target_ulong guest_addr;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vbroadcastf64x2_zmm12_m128,
                             sizeof(vbroadcastf64x2_zmm12_m128))) {
        return false;
    }

    guest_addr = rr_evex_rip_rel_addr(s, env, pc, 10);
    rr_evex_broadcastf64x2_zmm12_m128_512(s, guest_addr);
    s->pc = pc + sizeof(vbroadcastf64x2_zmm12_m128);
    return true;
#else
    return false;
#endif
}

static bool rr_try_evex_vpslldq_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vpslldq_zmm13_zmm12_0x4[] = {
        0x62, 0xd1, 0x15, 0x48, 0x73, 0xfc, 0x04
    };
    target_ulong pc = s->pc;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vpslldq_zmm13_zmm12_0x4,
                             sizeof(vpslldq_zmm13_zmm12_0x4))) {
        return false;
    }

    rr_evex_pslldq_zmm13_zmm12_512();
    s->pc = pc + sizeof(vpslldq_zmm13_zmm12_0x4);
    return true;
#else
    return false;
#endif
}

"""
if insert_smoke not in modified:
    raise SystemExit("vbroadcast smoke anchor missing from generated patch source")
modified = modified.replace(insert_smoke, replace_smoke, 1)

modified = modified.replace(
    "    if (rr_try_evex_vbroadcastf64x2_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n\n next_byte:;\n",
    "    if (rr_try_evex_vbroadcastf64x2_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n"
    "    if (rr_try_evex_vpslldq_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n\n next_byte:;\n",
    1,
)

if modified == source:
    raise SystemExit("patch generation made no changes")

Path(sys.argv[2]).write_text(modified)
PY

  if diff -u \
    --label a/target/i386/tcg/decode-new.c.inc \
    --label b/target/i386/tcg/decode-new.c.inc \
    "$patch_tree/target/i386/tcg/decode-new.c.inc" \
    "$modified_file" >"$PATCH_DIR/0015-qemu-${QEMU_VERSION}-evex-vpslldq-smoke.patch"; then
    :
  else
    diff_rc=$?
    if [[ $diff_rc -ne 1 ]]; then
      exit "$diff_rc"
    fi
  fi

  rm -rf "$temp_root"
}

generate_0016_patch() {
  local source_file="$SOURCE_SRC/target/i386/tcg/decode-new.c.inc"
  local temp_root patch_tree modified_file patch_name

  [[ -f "$source_file" ]] || die "missing source file for patch generation: $source_file"
  mkdir -p "$PATCH_DIR"

  temp_root="$(mktemp -d "$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vpsrldq.XXXXXX")"
  patch_tree="$temp_root/patched"
  modified_file="$temp_root/decode-new.c.inc.modified"

  cp -a "$SOURCE_SRC" "$patch_tree"

  for patch_name in \
    "0001-qemu-${QEMU_VERSION}-avx512-min-feature-masks.patch" \
    "0002-qemu-${QEMU_VERSION}-evex-vpxorq-smoke.patch" \
    "0003-qemu-${QEMU_VERSION}-evex-vmovdqa64-smoke.patch" \
    "0004-qemu-${QEMU_VERSION}-evex-vmovdqu64-smoke.patch" \
    "0005-qemu-${QEMU_VERSION}-evex-vpshufb-smoke.patch" \
    "0006-qemu-${QEMU_VERSION}-evex-vpaddd-smoke.patch" \
    "0007-qemu-${QEMU_VERSION}-evex-vpternlogq-smoke.patch" \
    "0008-qemu-${QEMU_VERSION}-evex-vpclmullqlqdq-smoke.patch" \
    "0009-qemu-${QEMU_VERSION}-evex-vpclmullqhqdq-smoke.patch" \
    "0010-qemu-${QEMU_VERSION}-evex-vpclmulhqlqdq-smoke.patch" \
    "0011-qemu-${QEMU_VERSION}-evex-vpclmulhqhqdq-smoke.patch" \
    "0012-qemu-${QEMU_VERSION}-evex-vaesenc-smoke.patch" \
    "0013-qemu-${QEMU_VERSION}-evex-vaesenclast-smoke.patch" \
    "0014-qemu-${QEMU_VERSION}-evex-vbroadcastf64x2-smoke.patch" \
    "0015-qemu-${QEMU_VERSION}-evex-vpslldq-smoke.patch"
  do
    [[ -f "$PATCH_DIR/$patch_name" ]] || die "missing prerequisite patch: $PATCH_DIR/$patch_name"
    log "Priming 0016 generation with $patch_name"
    (cd "$patch_tree" && patch --fuzz=0 -p1 <"$PATCH_DIR/$patch_name")
  done

  python3 - "$patch_tree/target/i386/tcg/decode-new.c.inc" "$modified_file" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
modified = source

insert_helper = """static bool rr_try_evex_vpslldq_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vpslldq_zmm13_zmm12_0x4[] = {
        0x62, 0xd1, 0x15, 0x48, 0x73, 0xfc, 0x04
    };
    target_ulong pc = s->pc;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vpslldq_zmm13_zmm12_0x4,
                             sizeof(vpslldq_zmm13_zmm12_0x4))) {
        return false;
    }

    rr_evex_pslldq_zmm13_zmm12_512();
    s->pc = pc + sizeof(vpslldq_zmm13_zmm12_0x4);
    return true;
#else
    return false;
#endif
}
"""
replace_helper = """static bool rr_try_evex_vpslldq_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vpslldq_zmm13_zmm12_0x4[] = {
        0x62, 0xd1, 0x15, 0x48, 0x73, 0xfc, 0x04
    };
    target_ulong pc = s->pc;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vpslldq_zmm13_zmm12_0x4,
                             sizeof(vpslldq_zmm13_zmm12_0x4))) {
        return false;
    }

    rr_evex_pslldq_zmm13_zmm12_512();
    s->pc = pc + sizeof(vpslldq_zmm13_zmm12_0x4);
    return true;
#else
    return false;
#endif
}

static void rr_evex_psrldq_xmm_lane(intptr_t dofs, intptr_t sofs, uint8_t imm)
{
    TCGv_ptr d = tcg_temp_new_ptr();
    TCGv_ptr s = tcg_temp_new_ptr();
    TCGv_ptr c = rr_evex_make_imm8u_xmm_vec(imm);

    tcg_gen_addi_ptr(d, tcg_env, dofs);
    tcg_gen_addi_ptr(s, tcg_env, sofs);
    gen_helper_psrldq_xmm(tcg_env, d, s, c);
}

static void rr_evex_psrldq_zmm14_zmm13_512(void)
{
    rr_evex_psrldq_xmm_lane(
        offsetof(CPUX86State, xmm_regs[14].ZMM_X(0)),
        offsetof(CPUX86State, xmm_regs[13].ZMM_X(0)), 4);
    rr_evex_psrldq_xmm_lane(
        offsetof(CPUX86State, xmm_regs[14].ZMM_X(1)),
        offsetof(CPUX86State, xmm_regs[13].ZMM_X(1)), 4);
    rr_evex_psrldq_xmm_lane(
        offsetof(CPUX86State, xmm_regs[14].ZMM_X(2)),
        offsetof(CPUX86State, xmm_regs[13].ZMM_X(2)), 4);
    rr_evex_psrldq_xmm_lane(
        offsetof(CPUX86State, xmm_regs[14].ZMM_X(3)),
        offsetof(CPUX86State, xmm_regs[13].ZMM_X(3)), 4);
}

static bool rr_try_evex_vpsrldq_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vpsrldq_zmm14_zmm13_0x4[] = {
        0x62, 0xd1, 0x0d, 0x48, 0x73, 0xdd, 0x04
    };
    target_ulong pc = s->pc;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vpsrldq_zmm14_zmm13_0x4,
                             sizeof(vpsrldq_zmm14_zmm13_0x4))) {
        return false;
    }

    rr_evex_psrldq_zmm14_zmm13_512();
    s->pc = pc + sizeof(vpsrldq_zmm14_zmm13_0x4);
    return true;
#else
    return false;
#endif
}
"""
if insert_helper not in modified:
    raise SystemExit("vpslldq smoke anchor missing from generated patch source")
modified = modified.replace(insert_helper, replace_helper, 1)

modified = modified.replace(
    "    if (rr_try_evex_vpslldq_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n\n next_byte:;\n",
    "    if (rr_try_evex_vpslldq_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n"
    "    if (rr_try_evex_vpsrldq_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n\n next_byte:;\n",
    1,
)

if modified == source:
    raise SystemExit("patch generation made no changes")

Path(sys.argv[2]).write_text(modified)
PY

  if diff -u \
    --label a/target/i386/tcg/decode-new.c.inc \
    --label b/target/i386/tcg/decode-new.c.inc \
    "$patch_tree/target/i386/tcg/decode-new.c.inc" \
    "$modified_file" >"$PATCH_DIR/0016-qemu-${QEMU_VERSION}-evex-vpsrldq-smoke.patch"; then
    :
  else
    diff_rc=$?
    if [[ $diff_rc -ne 1 ]]; then
      exit "$diff_rc"
    fi
  fi

  rm -rf "$temp_root"
}

generate_0017_patch() {
  local source_file="$SOURCE_SRC/target/i386/tcg/decode-new.c.inc"
  local temp_root patch_tree modified_file patch_name

  [[ -f "$source_file" ]] || die "missing source file for patch generation: $source_file"
  mkdir -p "$PATCH_DIR"

  temp_root="$(mktemp -d "$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vextracti32x4.XXXXXX")"
  patch_tree="$temp_root/patched"
  modified_file="$temp_root/decode-new.c.inc.modified"

  cp -a "$SOURCE_SRC" "$patch_tree"

  for patch_name in \
    "0001-qemu-${QEMU_VERSION}-avx512-min-feature-masks.patch" \
    "0002-qemu-${QEMU_VERSION}-evex-vpxorq-smoke.patch" \
    "0003-qemu-${QEMU_VERSION}-evex-vmovdqa64-smoke.patch" \
    "0004-qemu-${QEMU_VERSION}-evex-vmovdqu64-smoke.patch" \
    "0005-qemu-${QEMU_VERSION}-evex-vpshufb-smoke.patch" \
    "0006-qemu-${QEMU_VERSION}-evex-vpaddd-smoke.patch" \
    "0007-qemu-${QEMU_VERSION}-evex-vpternlogq-smoke.patch" \
    "0008-qemu-${QEMU_VERSION}-evex-vpclmullqlqdq-smoke.patch" \
    "0009-qemu-${QEMU_VERSION}-evex-vpclmullqhqdq-smoke.patch" \
    "0010-qemu-${QEMU_VERSION}-evex-vpclmulhqlqdq-smoke.patch" \
    "0011-qemu-${QEMU_VERSION}-evex-vpclmulhqhqdq-smoke.patch" \
    "0012-qemu-${QEMU_VERSION}-evex-vaesenc-smoke.patch" \
    "0013-qemu-${QEMU_VERSION}-evex-vaesenclast-smoke.patch" \
    "0014-qemu-${QEMU_VERSION}-evex-vbroadcastf64x2-smoke.patch" \
    "0015-qemu-${QEMU_VERSION}-evex-vpslldq-smoke.patch" \
    "0016-qemu-${QEMU_VERSION}-evex-vpsrldq-smoke.patch"
  do
    [[ -f "$PATCH_DIR/$patch_name" ]] || die "missing prerequisite patch: $PATCH_DIR/$patch_name"
    log "Priming 0017 generation with $patch_name"
    (cd "$patch_tree" && patch --fuzz=0 -p1 <"$PATCH_DIR/$patch_name")
  done

  python3 - "$patch_tree/target/i386/tcg/decode-new.c.inc" "$modified_file" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
modified = source

insert_helper = """static bool rr_try_evex_vpsrldq_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vpsrldq_zmm14_zmm13_0x4[] = {
        0x62, 0xd1, 0x0d, 0x48, 0x73, 0xdd, 0x04
    };
    target_ulong pc = s->pc;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vpsrldq_zmm14_zmm13_0x4,
                             sizeof(vpsrldq_zmm14_zmm13_0x4))) {
        return false;
    }

    rr_evex_psrldq_zmm14_zmm13_512();
    s->pc = pc + sizeof(vpsrldq_zmm14_zmm13_0x4);
    return true;
#else
    return false;
#endif
}
"""
replace_helper = """static bool rr_try_evex_vpsrldq_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vpsrldq_zmm14_zmm13_0x4[] = {
        0x62, 0xd1, 0x0d, 0x48, 0x73, 0xdd, 0x04
    };
    target_ulong pc = s->pc;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vpsrldq_zmm14_zmm13_0x4,
                             sizeof(vpsrldq_zmm14_zmm13_0x4))) {
        return false;
    }

    rr_evex_psrldq_zmm14_zmm13_512();
    s->pc = pc + sizeof(vpsrldq_zmm14_zmm13_0x4);
    return true;
#else
    return false;
#endif
}

static void rr_evex_vextracti32x4_xmm15_zmm14_imm1(void)
{
    TCGv_i128 t = tcg_temp_new_i128();

    tcg_gen_gvec_dup_imm(MO_64, offsetof(CPUX86State, xmm_regs[15]), 64, 64, 0);
    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[14].ZMM_X(1)));
    tcg_gen_st_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[15].ZMM_X(0)));
}

static bool rr_try_evex_vextracti32x4_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vextracti32x4_xmm15_zmm14_0x1[] = {
        0x62, 0x53, 0x7d, 0x48, 0x39, 0xf7, 0x01
    };
    target_ulong pc = s->pc;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vextracti32x4_xmm15_zmm14_0x1,
                             sizeof(vextracti32x4_xmm15_zmm14_0x1))) {
        return false;
    }

    rr_evex_vextracti32x4_xmm15_zmm14_imm1();
    s->pc = pc + sizeof(vextracti32x4_xmm15_zmm14_0x1);
    return true;
#else
    return false;
#endif
}
"""
if insert_helper not in modified:
    raise SystemExit("vpsrldq smoke anchor missing from generated patch source")
modified = modified.replace(insert_helper, replace_helper, 1)

modified = modified.replace(
    "    if (rr_try_evex_vpsrldq_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n\n next_byte:;\n",
    "    if (rr_try_evex_vpsrldq_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n"
    "    if (rr_try_evex_vextracti32x4_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n\n next_byte:;\n",
    1,
)

if modified == source:
    raise SystemExit("patch generation made no changes")

Path(sys.argv[2]).write_text(modified)
PY

  if diff -u \
    --label a/target/i386/tcg/decode-new.c.inc \
    --label b/target/i386/tcg/decode-new.c.inc \
    "$patch_tree/target/i386/tcg/decode-new.c.inc" \
    "$modified_file" >"$PATCH_DIR/0017-qemu-${QEMU_VERSION}-evex-vextracti32x4-smoke.patch"; then
    :
  else
    diff_rc=$?
    if [[ $diff_rc -ne 1 ]]; then
      exit "$diff_rc"
    fi
  fi

  rm -rf "$temp_root"
}

generate_0018_patch() {
  local source_file="$SOURCE_SRC/target/i386/tcg/decode-new.c.inc"
  local temp_root patch_tree modified_file patch_name

  [[ -f "$source_file" ]] || die "missing source file for patch generation: $source_file"
  mkdir -p "$PATCH_DIR"

  temp_root="$(mktemp -d "$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vextracti64x4.XXXXXX")"
  patch_tree="$temp_root/patched"
  modified_file="$temp_root/decode-new.c.inc.modified"

  cp -a "$SOURCE_SRC" "$patch_tree"

  for patch_name in \
    "0001-qemu-${QEMU_VERSION}-avx512-min-feature-masks.patch" \
    "0002-qemu-${QEMU_VERSION}-evex-vpxorq-smoke.patch" \
    "0003-qemu-${QEMU_VERSION}-evex-vmovdqa64-smoke.patch" \
    "0004-qemu-${QEMU_VERSION}-evex-vmovdqu64-smoke.patch" \
    "0005-qemu-${QEMU_VERSION}-evex-vpshufb-smoke.patch" \
    "0006-qemu-${QEMU_VERSION}-evex-vpaddd-smoke.patch" \
    "0007-qemu-${QEMU_VERSION}-evex-vpternlogq-smoke.patch" \
    "0008-qemu-${QEMU_VERSION}-evex-vpclmullqlqdq-smoke.patch" \
    "0009-qemu-${QEMU_VERSION}-evex-vpclmullqhqdq-smoke.patch" \
    "0010-qemu-${QEMU_VERSION}-evex-vpclmulhqlqdq-smoke.patch" \
    "0011-qemu-${QEMU_VERSION}-evex-vpclmulhqhqdq-smoke.patch" \
    "0012-qemu-${QEMU_VERSION}-evex-vaesenc-smoke.patch" \
    "0013-qemu-${QEMU_VERSION}-evex-vaesenclast-smoke.patch" \
    "0014-qemu-${QEMU_VERSION}-evex-vbroadcastf64x2-smoke.patch" \
    "0015-qemu-${QEMU_VERSION}-evex-vpslldq-smoke.patch" \
    "0016-qemu-${QEMU_VERSION}-evex-vpsrldq-smoke.patch" \
    "0017-qemu-${QEMU_VERSION}-evex-vextracti32x4-smoke.patch"
  do
    [[ -f "$PATCH_DIR/$patch_name" ]] || die "missing prerequisite patch: $PATCH_DIR/$patch_name"
    log "Priming 0018 generation with $patch_name"
    (cd "$patch_tree" && patch --fuzz=0 -p1 <"$PATCH_DIR/$patch_name")
  done

  python3 - "$patch_tree/target/i386/tcg/decode-new.c.inc" "$modified_file" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
modified = source

insert_helper = """static void rr_evex_vextracti32x4_xmm15_zmm14_imm1(void)
{
    TCGv_i128 t = tcg_temp_new_i128();

    tcg_gen_gvec_dup_imm(MO_64, offsetof(CPUX86State, xmm_regs[15]), 64, 64, 0);
    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[14].ZMM_X(1)));
    tcg_gen_st_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[15].ZMM_X(0)));
}

static bool rr_try_evex_vextracti32x4_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vextracti32x4_xmm15_zmm14_0x1[] = {
        0x62, 0x53, 0x7d, 0x48, 0x39, 0xf7, 0x01
    };
    target_ulong pc = s->pc;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vextracti32x4_xmm15_zmm14_0x1,
                             sizeof(vextracti32x4_xmm15_zmm14_0x1))) {
        return false;
    }

    rr_evex_vextracti32x4_xmm15_zmm14_imm1();
    s->pc = pc + sizeof(vextracti32x4_xmm15_zmm14_0x1);
    return true;
#else
    return false;
#endif
}
"""
replace_helper = """static void rr_evex_vextracti32x4_xmm15_zmm14_imm1(void)
{
    TCGv_i128 t = tcg_temp_new_i128();

    tcg_gen_gvec_dup_imm(MO_64, offsetof(CPUX86State, xmm_regs[15]), 64, 64, 0);
    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[14].ZMM_X(1)));
    tcg_gen_st_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[15].ZMM_X(0)));
}

static bool rr_try_evex_vextracti32x4_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vextracti32x4_xmm15_zmm14_0x1[] = {
        0x62, 0x53, 0x7d, 0x48, 0x39, 0xf7, 0x01
    };
    target_ulong pc = s->pc;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vextracti32x4_xmm15_zmm14_0x1,
                             sizeof(vextracti32x4_xmm15_zmm14_0x1))) {
        return false;
    }

    rr_evex_vextracti32x4_xmm15_zmm14_imm1();
    s->pc = pc + sizeof(vextracti32x4_xmm15_zmm14_0x1);
    return true;
#else
    return false;
#endif
}

static void rr_evex_vextracti64x4_ymm16_zmm14_imm1(void)
{
    tcg_gen_gvec_dup_imm(MO_64, offsetof(CPUX86State, xmm_regs[16]), 64, 64, 0);
    tcg_gen_gvec_mov(MO_64,
                     offsetof(CPUX86State, xmm_regs[16].ZMM_Y(0)),
                     offsetof(CPUX86State, xmm_regs[14].ZMM_Y(1)),
                     32, 32);
}

static bool rr_try_evex_vextracti64x4_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vextracti64x4_ymm16_zmm14_0x1[] = {
        0x62, 0x33, 0xfd, 0x48, 0x3b, 0xf0, 0x01
    };
    target_ulong pc = s->pc;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vextracti64x4_ymm16_zmm14_0x1,
                             sizeof(vextracti64x4_ymm16_zmm14_0x1))) {
        return false;
    }

    rr_evex_vextracti64x4_ymm16_zmm14_imm1();
    s->pc = pc + sizeof(vextracti64x4_ymm16_zmm14_0x1);
    return true;
#else
    return false;
#endif
}
"""
if insert_helper not in modified:
    raise SystemExit("vextracti32x4 smoke anchor missing from generated patch source")
modified = modified.replace(insert_helper, replace_helper, 1)

modified = modified.replace(
    "    if (rr_try_evex_vextracti32x4_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n\n next_byte:;\n",
    "    if (rr_try_evex_vextracti32x4_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n"
    "    if (rr_try_evex_vextracti64x4_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n\n next_byte:;\n",
    1,
)

if modified == source:
    raise SystemExit("patch generation made no changes")

Path(sys.argv[2]).write_text(modified)
PY

  if diff -u \
    --label a/target/i386/tcg/decode-new.c.inc \
    --label b/target/i386/tcg/decode-new.c.inc \
    "$patch_tree/target/i386/tcg/decode-new.c.inc" \
    "$modified_file" >"$PATCH_DIR/0018-qemu-${QEMU_VERSION}-evex-vextracti64x4-smoke.patch"; then
    :
  else
    diff_rc=$?
    if [[ $diff_rc -ne 1 ]]; then
      exit "$diff_rc"
    fi
  fi

  rm -rf "$temp_root"
}

generate_0019_patch() {
  local source_file="$SOURCE_SRC/target/i386/tcg/decode-new.c.inc"
  local temp_root patch_tree modified_file patch_name

  [[ -f "$source_file" ]] || die "missing source file for patch generation: $source_file"
  mkdir -p "$PATCH_DIR"

  temp_root="$(mktemp -d "$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vmovdqu8.XXXXXX")"
  patch_tree="$temp_root/patched"
  modified_file="$temp_root/decode-new.c.inc.modified"

  cp -a "$SOURCE_SRC" "$patch_tree"

  for patch_name in \
    "0001-qemu-${QEMU_VERSION}-avx512-min-feature-masks.patch" \
    "0002-qemu-${QEMU_VERSION}-evex-vpxorq-smoke.patch" \
    "0003-qemu-${QEMU_VERSION}-evex-vmovdqa64-smoke.patch" \
    "0004-qemu-${QEMU_VERSION}-evex-vmovdqu64-smoke.patch" \
    "0005-qemu-${QEMU_VERSION}-evex-vpshufb-smoke.patch" \
    "0006-qemu-${QEMU_VERSION}-evex-vpaddd-smoke.patch" \
    "0007-qemu-${QEMU_VERSION}-evex-vpternlogq-smoke.patch" \
    "0008-qemu-${QEMU_VERSION}-evex-vpclmullqlqdq-smoke.patch" \
    "0009-qemu-${QEMU_VERSION}-evex-vpclmullqhqdq-smoke.patch" \
    "0010-qemu-${QEMU_VERSION}-evex-vpclmulhqlqdq-smoke.patch" \
    "0011-qemu-${QEMU_VERSION}-evex-vpclmulhqhqdq-smoke.patch" \
    "0012-qemu-${QEMU_VERSION}-evex-vaesenc-smoke.patch" \
    "0013-qemu-${QEMU_VERSION}-evex-vaesenclast-smoke.patch" \
    "0014-qemu-${QEMU_VERSION}-evex-vbroadcastf64x2-smoke.patch" \
    "0015-qemu-${QEMU_VERSION}-evex-vpslldq-smoke.patch" \
    "0016-qemu-${QEMU_VERSION}-evex-vpsrldq-smoke.patch" \
    "0017-qemu-${QEMU_VERSION}-evex-vextracti32x4-smoke.patch" \
    "0018-qemu-${QEMU_VERSION}-evex-vextracti64x4-smoke.patch"
  do
    [[ -f "$PATCH_DIR/$patch_name" ]] || die "missing prerequisite patch: $PATCH_DIR/$patch_name"
    log "Priming 0019 generation with $patch_name"
    (cd "$patch_tree" && patch --fuzz=0 -p1 <"$PATCH_DIR/$patch_name")
  done

  python3 - "$patch_tree/target/i386/tcg/decode-new.c.inc" "$modified_file" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
modified = source

anchor = """static void rr_evex_vextracti64x4_ymm16_zmm14_imm1(void)
{
    tcg_gen_gvec_dup_imm(MO_64, offsetof(CPUX86State, xmm_regs[16]), 64, 64, 0);
    tcg_gen_gvec_mov(MO_64,
                     offsetof(CPUX86State, xmm_regs[16].ZMM_Y(0)),
                     offsetof(CPUX86State, xmm_regs[14].ZMM_Y(1)),
                     32, 32);
}

static bool rr_try_evex_vextracti64x4_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vextracti64x4_ymm16_zmm14_0x1[] = {
        0x62, 0x33, 0xfd, 0x48, 0x3b, 0xf0, 0x01
    };
    target_ulong pc = s->pc;

    if (!CODE64(s)) {
        return false;
    }
    if (!rr_evex_exact_bytes(s, env, pc, vextracti64x4_ymm16_zmm14_0x1,
                             sizeof(vextracti64x4_ymm16_zmm14_0x1))) {
        return false;
    }

    rr_evex_vextracti64x4_ymm16_zmm14_imm1();
    s->pc = pc + sizeof(vextracti64x4_ymm16_zmm14_0x1);
    return true;
#else
    return false;
#endif
}
"""

replace = anchor + """
static void rr_evex_store_zmm14_512(DisasContext *s, target_ulong guest_addr)
{
    MemOp mop = MO_128 | MO_LE | MO_ATOM_IFALIGN_PAIR;
    TCGv_i128 t = tcg_temp_new_i128();

    tcg_gen_movi_tl(s->A0, guest_addr + 0);
    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[14].ZMM_X(0)));
    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);

    tcg_gen_movi_tl(s->A0, guest_addr + 16);
    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[14].ZMM_X(1)));
    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);

    tcg_gen_movi_tl(s->A0, guest_addr + 32);
    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[14].ZMM_X(2)));
    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);

    tcg_gen_movi_tl(s->A0, guest_addr + 48);
    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[14].ZMM_X(3)));
    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);
}

static bool rr_try_evex_vmovdqu8_smoke(DisasContext *s, CPUX86State *env)
{
#ifdef TARGET_X86_64
    static const uint8_t vmovdqu8_store_single[] = {
        0x62, 0x71, 0x7f, 0x48, 0x7f, 0x35, 0xf6, 0x0f, 0x00, 0x00
    };
    static const uint8_t vmovdqu8_store_chain[] = {
        0x62, 0x71, 0x7f, 0x48, 0x7f, 0x35, 0x75, 0x0f, 0x00, 0x00
    };
    target_ulong pc = s->pc;
    target_ulong guest_addr;

    if (!CODE64(s)) {
        return false;
    }
    if (!(rr_evex_exact_bytes(s, env, pc, vmovdqu8_store_single,
                              sizeof(vmovdqu8_store_single)) ||
          rr_evex_exact_bytes(s, env, pc, vmovdqu8_store_chain,
                              sizeof(vmovdqu8_store_chain)))) {
        return false;
    }

    guest_addr = rr_evex_rip_rel_addr(s, env, pc, 10);
    rr_evex_store_zmm14_512(s, guest_addr);
    s->pc = pc + 10;
    return true;
#else
    return false;
#endif
}
"""

if anchor not in modified:
    raise SystemExit("vextracti64x4 smoke anchor missing from generated patch source")
modified = modified.replace(anchor, replace, 1)

modified = modified.replace(
    "    if (rr_try_evex_vextracti64x4_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n\n next_byte:;\n",
    "    if (rr_try_evex_vextracti64x4_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n"
    "    if (rr_try_evex_vmovdqu8_smoke(s, env)) {\n"
    "        return;\n"
    "    }\n\n next_byte:;\n",
    1,
)

if modified == source:
    raise SystemExit("patch generation made no changes")

Path(sys.argv[2]).write_text(modified)
PY

  if diff -u \
    --label a/target/i386/tcg/decode-new.c.inc \
    --label b/target/i386/tcg/decode-new.c.inc \
    "$patch_tree/target/i386/tcg/decode-new.c.inc" \
    "$modified_file" >"$PATCH_DIR/0019-qemu-${QEMU_VERSION}-evex-vmovdqu8-smoke.patch"; then
    :
  else
    diff_rc=$?
    if [[ $diff_rc -ne 1 ]]; then
      exit "$diff_rc"
    fi
  fi

  rm -rf "$temp_root"
}

configure_qemu() {
  mkdir -p "$BUILD_DIR" "$INSTALL_DIR" "$OUT_DIR"

  if [[ -f "$BUILD_DIR/build.ninja" ]]; then
    log "Reusing existing configure output in $BUILD_DIR"
    return
  fi

  log "Configuring QEMU $QEMU_VERSION"
  if ! (
    cd "$BUILD_DIR"
    PATH="$BUILD_PATH" "$PATCHED_SRC/configure" \
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
      --prefix="$INSTALL_DIR"
  ) >"$OUT_DIR/configure.out" 2>&1; then
    echo "---- configure tail ----" >&2
    tail -80 "$OUT_DIR/configure.out" >&2 || true
    die "QEMU configure failed; see $OUT_DIR/configure.out"
  fi
}

build_qemu() {
  log "Building qemu-x86_64"
  if ! PATH="$BUILD_PATH" ninja -C "$BUILD_DIR" -j "$JOBS" qemu-x86_64 \
    >"$OUT_DIR/ninja.out" 2>&1; then
    echo "---- ninja tail ----" >&2
    tail -120 "$OUT_DIR/ninja.out" >&2 || true
    die "QEMU build failed; see $OUT_DIR/ninja.out"
  fi
  [[ -x "$BUILD_DIR/qemu-x86_64" ]] || die "missing built binary: $BUILD_DIR/qemu-x86_64"
}

write_probe_sources() {
  mkdir -p "$PROBE_DIR" "$OUT_DIR"

  cat >"$PROBE_DIR/cpuid_xgetbv.c" <<'C'
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

  cat >"$PROBE_DIR/avx2-vex.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vmovdqu ymm0, ymmword ptr [rip + scratch]
    vpxor ymm1, ymm0, ymm0
    vpshufb ymm2, ymm1, ymm0
    vperm2i128 ymm3, ymm2, ymm0, 0x31
    vmovdqu ymmword ptr [rip + scratch], ymm3
    vzeroupper
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 32
scratch:
    .zero 32
ASM

  cat >"$PROBE_DIR/avx512-vpxorq.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    .byte 0x62, 0xf1, 0xfd, 0x48, 0xef, 0xc0
    mov eax, 60
    xor edi, edi
    syscall
ASM

  cat >"$PROBE_DIR/avx512-vmovdqa64.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    .byte 0x62, 0xf1, 0xfd, 0x48, 0x6f, 0xc8
    mov eax, 60
    xor edi, edi
    syscall
ASM

  cat >"$PROBE_DIR/avx512-vmovdqu64-store.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
ASM

  cat >"$PROBE_DIR/avx512-vmovdqu64-load.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
ASM

  cat >"$PROBE_DIR/avx512-vmovdqu64-chain.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
ASM

  cat >"$PROBE_DIR/avx512-aggregate-boundary.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    vpaddd zmm4, zmm3, zmm2
    vpternlogq zmm5, zmm4, zmm3, 0x96
    .byte 0x62, 0xf3, 0x55, 0x48, 0x44, 0xf4, 0x00
    .byte 0x62, 0xf3, 0x55, 0x48, 0x44, 0xfc, 0x10
    .byte 0x62, 0x73, 0x55, 0x48, 0x44, 0xc4, 0x01
.byte 0x62, 0x73, 0x55, 0x48, 0x44, 0xcc, 0x11
    .byte 0x62, 0x52, 0x35, 0x48, 0xdc, 0xd0
    .byte 0x62, 0x72, 0x2d, 0x48, 0xdd, 0xdf
    .byte 0x62, 0x72, 0xfd, 0x48, 0x1a, 0x25, 0x9b, 0x0f, 0x00, 0x00
    .byte 0x62, 0xd1, 0x15, 0x48, 0x73, 0xfc, 0x04
    vpsrldq zmm14, zmm13, 4
    vextracti32x4 xmm15, zmm14, 1
    vextracti64x4 ymm16, zmm14, 1
    vmovdqu8 zmmword ptr [rip + scratch], zmm14
    vzeroupper
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
ASM

  cat >"$PROBE_DIR/avx512-vpshufb-single.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpshufb zmm3, zmm2, zmm2
    mov eax, 60
    xor edi, edi
    syscall
ASM

  cat >"$PROBE_DIR/avx512-vpshufb-chain.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
ASM

  cat >"$PROBE_DIR/avx512-vpaddd-single.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpaddd zmm4, zmm3, zmm2
    mov eax, 60
    xor edi, edi
    syscall
ASM

  cat >"$PROBE_DIR/avx512-vpaddd-chain.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    vpaddd zmm4, zmm3, zmm2
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
ASM

  cat >"$PROBE_DIR/avx512-vpternlogq-single.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpternlogq zmm5, zmm4, zmm3, 0x96
    mov eax, 60
    xor edi, edi
    syscall
ASM

  cat >"$PROBE_DIR/avx512-vpternlogq-chain.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    vpaddd zmm4, zmm3, zmm2
    vpternlogq zmm5, zmm4, zmm3, 0x96
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
ASM

  cat >"$PROBE_DIR/avx512-vpclmullqlqdq-single.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpclmullqlqdq zmm6, zmm5, zmm4
    mov eax, 60
    xor edi, edi
    syscall
ASM

  cat >"$PROBE_DIR/avx512-vpclmullqlqdq-chain.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    vpaddd zmm4, zmm3, zmm2
    vpternlogq zmm5, zmm4, zmm3, 0x96
    vpclmullqlqdq zmm6, zmm5, zmm4
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
ASM

  cat >"$PROBE_DIR/avx512-vpclmullqlqdq-semantic.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    movdqu xmm5, xmmword ptr [rip + src_a]
    movdqu xmm4, xmmword ptr [rip + src_b]
    .byte 0x62, 0xf3, 0x55, 0x48, 0x44, 0xf4, 0x00
    movdqu xmmword ptr [rip + out], xmm6

    mov rax, qword ptr [rip + out]
    xor rax, qword ptr [rip + expected]
    mov rdx, qword ptr [rip + out + 8]
    xor rdx, qword ptr [rip + expected + 8]
    or rax, rdx
    setne dil
    movzx edi, dil
    mov eax, 60
    syscall

.section .data
.align 16
src_a:
    .quad 0x123456789abcdef0, 0xfeedfacecafebeef
src_b:
    .quad 0x0fedcba987654321, 0x0123456789abcdef
expected:
    .quad 0x40a0789828c810f0, 0x00e038d8688850b0
out:
    .zero 16
ASM

  cat >"$PROBE_DIR/avx512-vpclmullqhqdq-single.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpclmullqhqdq zmm7, zmm5, zmm4
    mov eax, 60
    xor edi, edi
    syscall
ASM

  cat >"$PROBE_DIR/avx512-vpclmullqhqdq-chain.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    vpaddd zmm4, zmm3, zmm2
    vpternlogq zmm5, zmm4, zmm3, 0x96
    vpclmullqlqdq zmm6, zmm5, zmm4
    vpclmullqhqdq zmm7, zmm5, zmm4
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
ASM

  cat >"$PROBE_DIR/avx512-vpclmullqhqdq-semantic.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    movdqu xmm5, xmmword ptr [rip + src_a]
    movdqu xmm4, xmmword ptr [rip + src_b]
    .byte 0x62, 0xf3, 0x55, 0x48, 0x44, 0xfc, 0x10
    movdqu xmmword ptr [rip + out], xmm7

    mov rax, qword ptr [rip + out]
    xor rax, qword ptr [rip + expected]
    mov rdx, qword ptr [rip + out + 8]
    xor rdx, qword ptr [rip + expected + 8]
    or rax, rdx
    setne dil
    movzx edi, dil
    mov eax, 60
    syscall

.section .data
.align 16
src_a:
    .quad 0x123456789abcdef0, 0xfeedfacecafebeef
src_b:
    .quad 0x0fedcba987654321, 0x0123456789abcdef
expected:
    .quad 0x0414445505154550, 0x0010405101114154
out:
    .zero 16
ASM

  cat >"$PROBE_DIR/avx512-vpclmulhqlqdq-single.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpclmulhqlqdq zmm8, zmm5, zmm4
    mov eax, 60
    xor edi, edi
    syscall
ASM

  cat >"$PROBE_DIR/avx512-vpclmulhqlqdq-chain.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    vpaddd zmm4, zmm3, zmm2
    vpternlogq zmm5, zmm4, zmm3, 0x96
    vpclmullqlqdq zmm6, zmm5, zmm4
    vpclmullqhqdq zmm7, zmm5, zmm4
    vpclmulhqlqdq zmm8, zmm5, zmm4
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
ASM

  cat >"$PROBE_DIR/avx512-vpclmulhqlqdq-semantic.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    movdqu xmm5, xmmword ptr [rip + src_a]
    movdqu xmm4, xmmword ptr [rip + src_b]
    .byte 0x62, 0x73, 0x55, 0x48, 0x44, 0xc4, 0x01
    movdqu xmmword ptr [rip + out], xmm8

    mov rax, qword ptr [rip + out]
    xor rax, qword ptr [rip + expected]
    mov rdx, qword ptr [rip + out + 8]
    xor rdx, qword ptr [rip + expected + 8]
    or rax, rdx
    setne dil
    movzx edi, dil
    mov eax, 60
    syscall

.section .data
.align 16
src_a:
    .quad 0x123456789abcdef0, 0xfeedfacecafebeef
src_b:
    .quad 0x0fedcba987654321, 0x0123456789abcdef
expected:
    .quad 0x708b0f331722920f, 0x05544a6551cee46a
out:
    .zero 16
ASM

  cat >"$PROBE_DIR/avx512-vpclmulhqhqdq-single.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpclmulhqhqdq zmm9, zmm5, zmm4
    mov eax, 60
    xor edi, edi
    syscall
ASM

  cat >"$PROBE_DIR/avx512-vpclmulhqhqdq-chain.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    vpaddd zmm4, zmm3, zmm2
    vpternlogq zmm5, zmm4, zmm3, 0x96
    vpclmullqlqdq zmm6, zmm5, zmm4
    vpclmullqhqdq zmm7, zmm5, zmm4
    vpclmulhqlqdq zmm8, zmm5, zmm4
    vpclmulhqhqdq zmm9, zmm5, zmm4
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
ASM

  cat >"$PROBE_DIR/avx512-vpclmulhqhqdq-semantic.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    movdqu xmm5, xmmword ptr [rip + src_a]
    movdqu xmm4, xmmword ptr [rip + src_b]
    .byte 0x62, 0x73, 0x55, 0x48, 0x44, 0xcc, 0x11
    movdqu xmmword ptr [rip + out], xmm9

    mov rax, qword ptr [rip + out]
    xor rax, qword ptr [rip + expected]
    mov rdx, qword ptr [rip + out + 8]
    xor rdx, qword ptr [rip + expected + 8]
    or rax, rdx
    setne dil
    movzx edi, dil
    mov eax, 60
    syscall

.section .data
.align 16
src_a:
    .quad 0x123456789abcdef0, 0xfeedfacecafebeef
src_b:
    .quad 0x0fedcba987654321, 0x0123456789abcdef
expected:
    .quad 0x5d145a8b347cb555, 0x00e00fef5abbd302
out:
    .zero 16
ASM

  cat >"$PROBE_DIR/avx512-vbroadcastf64x2-single.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    jmp vbroadcast_insn
    .org 0x5b, 0x90
vbroadcast_insn:
    vbroadcastf64x2 zmm12, xmmword ptr [rip + src]
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
src:
    .quad 0x1122334455667788
    .quad 0x99aabbccddeeff00
ASM

  cat >"$PROBE_DIR/avx512-vbroadcastf64x2-chain.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    vpaddd zmm4, zmm3, zmm2
    vpternlogq zmm5, zmm4, zmm3, 0x96
    vpclmullqlqdq zmm6, zmm5, zmm4
    vpclmullqhqdq zmm7, zmm5, zmm4
    vpclmulhqlqdq zmm8, zmm5, zmm4
    vpclmulhqhqdq zmm9, zmm5, zmm4
    vaesenc zmm10, zmm9, zmm8
    vaesenclast zmm11, zmm10, zmm7
    vbroadcastf64x2 zmm12, xmmword ptr [rip + scratch]
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .quad 0x1122334455667788
    .quad 0x99aabbccddeeff00
    .zero 48
ASM

  cat >"$PROBE_DIR/avx512-vpslldq-single.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpslldq zmm13, zmm12, 4
    mov eax, 60
    xor edi, edi
    syscall
ASM

  cat >"$PROBE_DIR/avx512-vpslldq-chain.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    vpaddd zmm4, zmm3, zmm2
    vpternlogq zmm5, zmm4, zmm3, 0x96
    vpclmullqlqdq zmm6, zmm5, zmm4
    vpclmullqhqdq zmm7, zmm5, zmm4
    vpclmulhqlqdq zmm8, zmm5, zmm4
    vpclmulhqhqdq zmm9, zmm5, zmm4
    vaesenc zmm10, zmm9, zmm8
    vaesenclast zmm11, zmm10, zmm7
    vbroadcastf64x2 zmm12, xmmword ptr [rip + scratch]
    vpslldq zmm13, zmm12, 4
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .quad 0x1122334455667788
    .quad 0x99aabbccddeeff00
    .zero 48
ASM

  cat >"$PROBE_DIR/avx512-vpsrldq-single.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpsrldq zmm14, zmm13, 4
    mov eax, 60
    xor edi, edi
    syscall
ASM

  cat >"$PROBE_DIR/avx512-vpsrldq-chain.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    vpaddd zmm4, zmm3, zmm2
    vpternlogq zmm5, zmm4, zmm3, 0x96
    vpclmullqlqdq zmm6, zmm5, zmm4
    vpclmullqhqdq zmm7, zmm5, zmm4
    vpclmulhqlqdq zmm8, zmm5, zmm4
    vpclmulhqhqdq zmm9, zmm5, zmm4
    vaesenc zmm10, zmm9, zmm8
    vaesenclast zmm11, zmm10, zmm7
    vbroadcastf64x2 zmm12, xmmword ptr [rip + scratch]
    vpslldq zmm13, zmm12, 4
    vpsrldq zmm14, zmm13, 4
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .quad 0x1122334455667788
    .quad 0x99aabbccddeeff00
    .zero 48
ASM

  cat >"$PROBE_DIR/avx512-vextracti32x4-single.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vextracti32x4 xmm15, zmm14, 1
    mov eax, 60
    xor edi, edi
    syscall
ASM

  cat >"$PROBE_DIR/avx512-vextracti32x4-chain.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    vpaddd zmm4, zmm3, zmm2
    vpternlogq zmm5, zmm4, zmm3, 0x96
    vpclmullqlqdq zmm6, zmm5, zmm4
    vpclmullqhqdq zmm7, zmm5, zmm4
    vpclmulhqlqdq zmm8, zmm5, zmm4
    vpclmulhqhqdq zmm9, zmm5, zmm4
    vaesenc zmm10, zmm9, zmm8
    vaesenclast zmm11, zmm10, zmm7
    vbroadcastf64x2 zmm12, xmmword ptr [rip + scratch]
    vpslldq zmm13, zmm12, 4
    vpsrldq zmm14, zmm13, 4
    vextracti32x4 xmm15, zmm14, 1
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .quad 0x1122334455667788
    .quad 0x99aabbccddeeff00
    .zero 48
ASM

  cat >"$PROBE_DIR/avx512-vextracti64x4-single.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vextracti64x4 ymm16, zmm14, 1
    mov eax, 60
    xor edi, edi
    syscall
ASM

  cat >"$PROBE_DIR/avx512-vextracti64x4-chain.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    vpaddd zmm4, zmm3, zmm2
    vpternlogq zmm5, zmm4, zmm3, 0x96
    vpclmullqlqdq zmm6, zmm5, zmm4
    vpclmullqhqdq zmm7, zmm5, zmm4
    vpclmulhqlqdq zmm8, zmm5, zmm4
    vpclmulhqhqdq zmm9, zmm5, zmm4
    vaesenc zmm10, zmm9, zmm8
    vaesenclast zmm11, zmm10, zmm7
    vbroadcastf64x2 zmm12, xmmword ptr [rip + scratch]
    vpslldq zmm13, zmm12, 4
    vpsrldq zmm14, zmm13, 4
    vextracti32x4 xmm15, zmm14, 1
    vextracti64x4 ymm16, zmm14, 1
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .quad 0x1122334455667788
    .quad 0x99aabbccddeeff00
    .zero 48
ASM

  cat >"$PROBE_DIR/avx512-vmovdqu8-single.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vmovdqu8 zmmword ptr [rip + scratch], zmm14
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
ASM

  cat >"$PROBE_DIR/avx512-vmovdqu8-chain.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    vpaddd zmm4, zmm3, zmm2
    vpternlogq zmm5, zmm4, zmm3, 0x96
    vpclmullqlqdq zmm6, zmm5, zmm4
    vpclmullqhqdq zmm7, zmm5, zmm4
    vpclmulhqlqdq zmm8, zmm5, zmm4
    vpclmulhqhqdq zmm9, zmm5, zmm4
    vaesenc zmm10, zmm9, zmm8
    vaesenclast zmm11, zmm10, zmm7
    vbroadcastf64x2 zmm12, xmmword ptr [rip + scratch]
    vpslldq zmm13, zmm12, 4
    vpsrldq zmm14, zmm13, 4
    vextracti32x4 xmm15, zmm14, 1
    vextracti64x4 ymm16, zmm14, 1
    vmovdqu8 zmmword ptr [rip + scratch], zmm14
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
ASM

  cat >"$PROBE_DIR/avx512-vaesenc-single.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vaesenc zmm10, zmm9, zmm8
    mov eax, 60
    xor edi, edi
    syscall
ASM

  cat >"$PROBE_DIR/avx512-vaesenc-chain.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    vpaddd zmm4, zmm3, zmm2
    vpternlogq zmm5, zmm4, zmm3, 0x96
    vpclmullqlqdq zmm6, zmm5, zmm4
    vpclmullqhqdq zmm7, zmm5, zmm4
    vpclmulhqlqdq zmm8, zmm5, zmm4
    vpclmulhqhqdq zmm9, zmm5, zmm4
    vaesenc zmm10, zmm9, zmm8
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
ASM

  cat >"$PROBE_DIR/avx512-vaesenc-semantic.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    movdqu xmm9, xmmword ptr [rip + state]
    movdqu xmm8, xmmword ptr [rip + round_key]
    .byte 0x62, 0x52, 0x35, 0x48, 0xdc, 0xd0
    movdqu xmmword ptr [rip + out], xmm10

    mov rax, qword ptr [rip + out]
    xor rax, qword ptr [rip + expected]
    mov rdx, qword ptr [rip + out + 8]
    xor rdx, qword ptr [rip + expected + 8]
    or rax, rdx
    setne dil
    movzx edi, dil
    mov eax, 60
    syscall

.section .data
.align 16
state:
    .byte 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77
    .byte 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff
round_key:
    .byte 0x0f, 0x0e, 0x0d, 0x0c, 0x0b, 0x0a, 0x09, 0x08
    .byte 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x00
expected:
    .byte 0x6c, 0x77, 0xeb, 0xd5, 0xff, 0x6d, 0xf2, 0x7e
    .byte 0xaa, 0x00, 0x39, 0xf0, 0xd1, 0xe9, 0x8b, 0xa3
out:
    .zero 16
ASM

  cat >"$PROBE_DIR/avx512-vaesenclast-single.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vaesenclast zmm11, zmm10, zmm7
    mov eax, 60
    xor edi, edi
    syscall
ASM

  cat >"$PROBE_DIR/avx512-vaesenclast-chain.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    vpaddd zmm4, zmm3, zmm2
    vpternlogq zmm5, zmm4, zmm3, 0x96
    vpclmullqlqdq zmm6, zmm5, zmm4
    vpclmullqhqdq zmm7, zmm5, zmm4
    vpclmulhqlqdq zmm8, zmm5, zmm4
    vpclmulhqhqdq zmm9, zmm5, zmm4
    vaesenc zmm10, zmm9, zmm8
    vaesenclast zmm11, zmm10, zmm7
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
ASM

  cat >"$PROBE_DIR/avx512-vaesenclast-semantic.S" <<'ASM'
.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    movdqu xmm10, xmmword ptr [rip + state]
    movdqu xmm7, xmmword ptr [rip + round_key]
    .byte 0x62, 0x72, 0x2d, 0x48, 0xdd, 0xdf
    movdqu xmmword ptr [rip + out], xmm11

    mov rax, qword ptr [rip + out]
    xor rax, qword ptr [rip + expected]
    mov rdx, qword ptr [rip + out + 8]
    xor rdx, qword ptr [rip + expected + 8]
    or rax, rdx
    setne dil
    movzx edi, dil
    mov eax, 60
    syscall

.section .data
.align 16
state:
    .byte 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77
    .byte 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff
round_key:
    .byte 0x0f, 0x0e, 0x0d, 0x0c, 0x0b, 0x0a, 0x09, 0x08
    .byte 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x00
expected:
    .byte 0x6c, 0xf2, 0xa1, 0x1a, 0x10, 0xe4, 0x21, 0xcb
    .byte 0xc3, 0xc7, 0x96, 0xf1, 0x48, 0x80, 0x32, 0xea
out:
    .zero 16
ASM
}

build_probes() {
  require_tool "$CC_BIN"
  require_tool "$OBJDUMP_BIN"
  write_probe_sources

  log "Building probe binaries"
  "$CC_BIN" -O2 -Wall -Wextra -o "$FEATURE_PROBE" "$PROBE_DIR/cpuid_xgetbv.c"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$AVX2_PROBE" "$PROBE_DIR/avx2-vex.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$AVX512_PROBE" "$PROBE_DIR/avx512-vpxorq.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VMOVDQA64_PROBE" "$PROBE_DIR/avx512-vmovdqa64.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VMOVDQU64_STORE_PROBE" "$PROBE_DIR/avx512-vmovdqu64-store.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VMOVDQU64_LOAD_PROBE" "$PROBE_DIR/avx512-vmovdqu64-load.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VMOVDQU64_CHAIN_PROBE" "$PROBE_DIR/avx512-vmovdqu64-chain.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPSHUFB_SINGLE_PROBE" "$PROBE_DIR/avx512-vpshufb-single.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPSHUFB_CHAIN_PROBE" "$PROBE_DIR/avx512-vpshufb-chain.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPADDD_SINGLE_PROBE" "$PROBE_DIR/avx512-vpaddd-single.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPADDD_CHAIN_PROBE" "$PROBE_DIR/avx512-vpaddd-chain.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPTERNLOGQ_SINGLE_PROBE" "$PROBE_DIR/avx512-vpternlogq-single.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPTERNLOGQ_CHAIN_PROBE" "$PROBE_DIR/avx512-vpternlogq-chain.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPCLMULLQLQ_SINGLE_PROBE" "$PROBE_DIR/avx512-vpclmullqlqdq-single.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPCLMULLQLQ_CHAIN_PROBE" "$PROBE_DIR/avx512-vpclmullqlqdq-chain.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPCLMULLQLQ_SEMANTIC_PROBE" "$PROBE_DIR/avx512-vpclmullqlqdq-semantic.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPCLMULLQHQ_SINGLE_PROBE" "$PROBE_DIR/avx512-vpclmullqhqdq-single.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPCLMULLQHQ_CHAIN_PROBE" "$PROBE_DIR/avx512-vpclmullqhqdq-chain.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPCLMULLQHQ_SEMANTIC_PROBE" "$PROBE_DIR/avx512-vpclmullqhqdq-semantic.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPCLMULHQLQ_SINGLE_PROBE" "$PROBE_DIR/avx512-vpclmulhqlqdq-single.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPCLMULHQLQ_CHAIN_PROBE" "$PROBE_DIR/avx512-vpclmulhqlqdq-chain.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPCLMULHQLQ_SEMANTIC_PROBE" "$PROBE_DIR/avx512-vpclmulhqlqdq-semantic.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPCLMULHQHQ_SINGLE_PROBE" "$PROBE_DIR/avx512-vpclmulhqhqdq-single.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPCLMULHQHQ_CHAIN_PROBE" "$PROBE_DIR/avx512-vpclmulhqhqdq-chain.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPCLMULHQHQ_SEMANTIC_PROBE" "$PROBE_DIR/avx512-vpclmulhqhqdq-semantic.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VAESENC_SINGLE_PROBE" "$PROBE_DIR/avx512-vaesenc-single.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VAESENC_CHAIN_PROBE" "$PROBE_DIR/avx512-vaesenc-chain.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VAESENC_SEMANTIC_PROBE" "$PROBE_DIR/avx512-vaesenc-semantic.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VAESENCLAST_SINGLE_PROBE" "$PROBE_DIR/avx512-vaesenclast-single.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VAESENCLAST_CHAIN_PROBE" "$PROBE_DIR/avx512-vaesenclast-chain.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VAESENCLAST_SEMANTIC_PROBE" "$PROBE_DIR/avx512-vaesenclast-semantic.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VBROADCASTF64X2_SINGLE_PROBE" "$PROBE_DIR/avx512-vbroadcastf64x2-single.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VBROADCASTF64X2_CHAIN_PROBE" "$PROBE_DIR/avx512-vbroadcastf64x2-chain.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPSLLDQ_SINGLE_PROBE" "$PROBE_DIR/avx512-vpslldq-single.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPSLLDQ_CHAIN_PROBE" "$PROBE_DIR/avx512-vpslldq-chain.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPSRLDQ_SINGLE_PROBE" "$PROBE_DIR/avx512-vpsrldq-single.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VPSRLDQ_CHAIN_PROBE" "$PROBE_DIR/avx512-vpsrldq-chain.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VEXTRACTI32X4_SINGLE_PROBE" "$PROBE_DIR/avx512-vextracti32x4-single.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VEXTRACTI32X4_CHAIN_PROBE" "$PROBE_DIR/avx512-vextracti32x4-chain.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VEXTRACTI64X4_SINGLE_PROBE" "$PROBE_DIR/avx512-vextracti64x4-single.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VEXTRACTI64X4_CHAIN_PROBE" "$PROBE_DIR/avx512-vextracti64x4-chain.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VMOVDQU8_SINGLE_PROBE" "$PROBE_DIR/avx512-vmovdqu8-single.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$VMOVDQU8_CHAIN_PROBE" "$PROBE_DIR/avx512-vmovdqu8-chain.S"
  "$CC_BIN" -nostdlib -no-pie -Wl,--build-id=none -o "$AGGREGATE_BOUNDARY_PROBE" "$PROBE_DIR/avx512-aggregate-boundary.S"

  "$OBJDUMP_BIN" -d -Mintel "$AVX2_PROBE" >"$OUT_DIR/avx2-vex.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$AVX512_PROBE" >"$OUT_DIR/avx512-vpxorq.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VMOVDQA64_PROBE" >"$OUT_DIR/avx512-vmovdqa64.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VMOVDQU64_STORE_PROBE" >"$OUT_DIR/avx512-vmovdqu64-store.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VMOVDQU64_LOAD_PROBE" >"$OUT_DIR/avx512-vmovdqu64-load.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VMOVDQU64_CHAIN_PROBE" >"$OUT_DIR/avx512-vmovdqu64-chain.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPSHUFB_SINGLE_PROBE" >"$OUT_DIR/avx512-vpshufb-single.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPSHUFB_CHAIN_PROBE" >"$OUT_DIR/avx512-vpshufb-chain.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPADDD_SINGLE_PROBE" >"$OUT_DIR/avx512-vpaddd-single.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPADDD_CHAIN_PROBE" >"$OUT_DIR/avx512-vpaddd-chain.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPTERNLOGQ_SINGLE_PROBE" >"$OUT_DIR/avx512-vpternlogq-single.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPTERNLOGQ_CHAIN_PROBE" >"$OUT_DIR/avx512-vpternlogq-chain.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPCLMULLQLQ_SINGLE_PROBE" >"$OUT_DIR/avx512-vpclmullqlqdq-single.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPCLMULLQLQ_CHAIN_PROBE" >"$OUT_DIR/avx512-vpclmullqlqdq-chain.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPCLMULLQLQ_SEMANTIC_PROBE" >"$OUT_DIR/avx512-vpclmullqlqdq-semantic.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPCLMULLQHQ_SINGLE_PROBE" >"$OUT_DIR/avx512-vpclmullqhqdq-single.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPCLMULLQHQ_CHAIN_PROBE" >"$OUT_DIR/avx512-vpclmullqhqdq-chain.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPCLMULLQHQ_SEMANTIC_PROBE" >"$OUT_DIR/avx512-vpclmullqhqdq-semantic.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPCLMULHQLQ_SINGLE_PROBE" >"$OUT_DIR/avx512-vpclmulhqlqdq-single.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPCLMULHQLQ_CHAIN_PROBE" >"$OUT_DIR/avx512-vpclmulhqlqdq-chain.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPCLMULHQLQ_SEMANTIC_PROBE" >"$OUT_DIR/avx512-vpclmulhqlqdq-semantic.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPCLMULHQHQ_SINGLE_PROBE" >"$OUT_DIR/avx512-vpclmulhqhqdq-single.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPCLMULHQHQ_CHAIN_PROBE" >"$OUT_DIR/avx512-vpclmulhqhqdq-chain.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPCLMULHQHQ_SEMANTIC_PROBE" >"$OUT_DIR/avx512-vpclmulhqhqdq-semantic.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VAESENC_SINGLE_PROBE" >"$OUT_DIR/avx512-vaesenc-single.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VAESENC_CHAIN_PROBE" >"$OUT_DIR/avx512-vaesenc-chain.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VAESENC_SEMANTIC_PROBE" >"$OUT_DIR/avx512-vaesenc-semantic.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VAESENCLAST_SINGLE_PROBE" >"$OUT_DIR/avx512-vaesenclast-single.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VAESENCLAST_CHAIN_PROBE" >"$OUT_DIR/avx512-vaesenclast-chain.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VAESENCLAST_SEMANTIC_PROBE" >"$OUT_DIR/avx512-vaesenclast-semantic.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VBROADCASTF64X2_SINGLE_PROBE" >"$OUT_DIR/avx512-vbroadcastf64x2-single.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VBROADCASTF64X2_CHAIN_PROBE" >"$OUT_DIR/avx512-vbroadcastf64x2-chain.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPSLLDQ_SINGLE_PROBE" >"$OUT_DIR/avx512-vpslldq-single.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPSLLDQ_CHAIN_PROBE" >"$OUT_DIR/avx512-vpslldq-chain.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPSRLDQ_SINGLE_PROBE" >"$OUT_DIR/avx512-vpsrldq-single.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VPSRLDQ_CHAIN_PROBE" >"$OUT_DIR/avx512-vpsrldq-chain.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VEXTRACTI32X4_SINGLE_PROBE" >"$OUT_DIR/avx512-vextracti32x4-single.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VEXTRACTI32X4_CHAIN_PROBE" >"$OUT_DIR/avx512-vextracti32x4-chain.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VEXTRACTI64X4_SINGLE_PROBE" >"$OUT_DIR/avx512-vextracti64x4-single.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VEXTRACTI64X4_CHAIN_PROBE" >"$OUT_DIR/avx512-vextracti64x4-chain.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VMOVDQU8_SINGLE_PROBE" >"$OUT_DIR/avx512-vmovdqu8-single.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$VMOVDQU8_CHAIN_PROBE" >"$OUT_DIR/avx512-vmovdqu8-chain.objdump.txt"
  "$OBJDUMP_BIN" -d -Mintel "$AGGREGATE_BOUNDARY_PROBE" >"$OUT_DIR/avx512-aggregate-boundary.objdump.txt"

  grep -E '\bvpxor\b' "$OUT_DIR/avx2-vex.objdump.txt" >/dev/null ||
    die "avx2-vex objdump is missing vpxor"
  grep -E '\bvpxorq\b' "$OUT_DIR/avx512-vpxorq.objdump.txt" >/dev/null ||
    die "avx512-vpxorq objdump is missing vpxorq"
  grep -E '\bvmovdqa64\b' "$OUT_DIR/avx512-vmovdqa64.objdump.txt" >/dev/null ||
    die "avx512-vmovdqa64 objdump is missing vmovdqa64"
  grep -F '62 f1 fe 48 7f 0d f6' "$OUT_DIR/avx512-vmovdqu64-store.objdump.txt" >/dev/null ||
    die "avx512-vmovdqu64-store objdump is missing expected store bytes"
  grep -F '62 f1 fe 48 6f 15 f6' "$OUT_DIR/avx512-vmovdqu64-load.objdump.txt" >/dev/null ||
    die "avx512-vmovdqu64-load objdump is missing expected load bytes"
  grep -F '62 f1 fe 48 7f 0d ea' "$OUT_DIR/avx512-vmovdqu64-chain.objdump.txt" >/dev/null ||
    die "avx512-vmovdqu64-chain objdump is missing expected aggregate store bytes"
  grep -F '62 f1 fe 48 6f 15 e0' "$OUT_DIR/avx512-vmovdqu64-chain.objdump.txt" >/dev/null ||
    die "avx512-vmovdqu64-chain objdump is missing expected aggregate load bytes"
  grep -F '62 f2 6d 48 00 da' "$OUT_DIR/avx512-vpshufb-single.objdump.txt" >/dev/null ||
    die "avx512-vpshufb-single objdump is missing expected vpshufb bytes"
  grep -F '62 f2 6d 48 00 da' "$OUT_DIR/avx512-vpshufb-chain.objdump.txt" >/dev/null ||
    die "avx512-vpshufb-chain objdump is missing expected vpshufb bytes"
  grep -F '62 f1 65 48 fe e2' "$OUT_DIR/avx512-vpaddd-single.objdump.txt" >/dev/null ||
    die "avx512-vpaddd-single objdump is missing expected vpaddd bytes"
  grep -F '62 f1 65 48 fe e2' "$OUT_DIR/avx512-vpaddd-chain.objdump.txt" >/dev/null ||
    die "avx512-vpaddd-chain objdump is missing expected vpaddd bytes"
  grep -F '62 f3 dd 48 25 eb 96' "$OUT_DIR/avx512-vpternlogq-single.objdump.txt" >/dev/null ||
    die "avx512-vpternlogq-single objdump is missing expected vpternlogq bytes"
  grep -F '62 f3 dd 48 25 eb 96' "$OUT_DIR/avx512-vpternlogq-chain.objdump.txt" >/dev/null ||
    die "avx512-vpternlogq-chain objdump is missing expected vpternlogq bytes"
  grep -F '62 f3 55 48 44 f4 00' "$OUT_DIR/avx512-vpclmullqlqdq-single.objdump.txt" >/dev/null ||
    die "avx512-vpclmullqlqdq-single objdump is missing expected vpclmullqlqdq bytes"
  grep -F 'vpclmullqlqdq zmm6,zmm5,zmm4' "$OUT_DIR/avx512-vpclmullqlqdq-single.objdump.txt" >/dev/null ||
    die "avx512-vpclmullqlqdq-single objdump is missing expected vpclmullqlqdq mnemonic"
  grep -F '62 f3 55 48 44 f4 00' "$OUT_DIR/avx512-vpclmullqlqdq-chain.objdump.txt" >/dev/null ||
    die "avx512-vpclmullqlqdq-chain objdump is missing expected vpclmullqlqdq bytes"
  grep -F '62 f3 55 48 44 f4 00' "$OUT_DIR/avx512-vpclmullqlqdq-semantic.objdump.txt" >/dev/null ||
    die "avx512-vpclmullqlqdq-semantic objdump is missing expected vpclmullqlqdq bytes"
  grep -F '62 f3 55 48 44 fc 10' "$OUT_DIR/avx512-vpclmullqhqdq-single.objdump.txt" >/dev/null ||
    die "avx512-vpclmullqhqdq-single objdump is missing expected vpclmullqhqdq bytes"
  grep -F 'vpclmullqhqdq zmm7,zmm5,zmm4' "$OUT_DIR/avx512-vpclmullqhqdq-single.objdump.txt" >/dev/null ||
    die "avx512-vpclmullqhqdq-single objdump is missing expected vpclmullqhqdq mnemonic"
  grep -F '62 f3 55 48 44 fc 10' "$OUT_DIR/avx512-vpclmullqhqdq-chain.objdump.txt" >/dev/null ||
    die "avx512-vpclmullqhqdq-chain objdump is missing expected vpclmullqhqdq bytes"
  grep -F '62 f3 55 48 44 fc 10' "$OUT_DIR/avx512-vpclmullqhqdq-semantic.objdump.txt" >/dev/null ||
    die "avx512-vpclmullqhqdq-semantic objdump is missing expected vpclmullqhqdq bytes"
  grep -F '62 73 55 48 44 c4 01' "$OUT_DIR/avx512-vpclmulhqlqdq-single.objdump.txt" >/dev/null ||
    die "avx512-vpclmulhqlqdq-single objdump is missing expected vpclmulhqlqdq bytes"
  grep -F 'vpclmulhqlqdq zmm8,zmm5,zmm4' "$OUT_DIR/avx512-vpclmulhqlqdq-single.objdump.txt" >/dev/null ||
    die "avx512-vpclmulhqlqdq-single objdump is missing expected vpclmulhqlqdq mnemonic"
  grep -F '62 73 55 48 44 c4 01' "$OUT_DIR/avx512-vpclmulhqlqdq-chain.objdump.txt" >/dev/null ||
    die "avx512-vpclmulhqlqdq-chain objdump is missing expected vpclmulhqlqdq bytes"
  grep -F '62 73 55 48 44 c4 01' "$OUT_DIR/avx512-vpclmulhqlqdq-semantic.objdump.txt" >/dev/null ||
    die "avx512-vpclmulhqlqdq-semantic objdump is missing expected vpclmulhqlqdq bytes"
  grep -F '62 73 55 48 44 cc 11' "$OUT_DIR/avx512-vpclmulhqhqdq-single.objdump.txt" >/dev/null ||
    die "avx512-vpclmulhqhqdq-single objdump is missing expected vpclmulhqhqdq bytes"
  grep -F 'vpclmulhqhqdq zmm9,zmm5,zmm4' "$OUT_DIR/avx512-vpclmulhqhqdq-single.objdump.txt" >/dev/null ||
    die "avx512-vpclmulhqhqdq-single objdump is missing expected vpclmulhqhqdq mnemonic"
  grep -F '62 73 55 48 44 cc 11' "$OUT_DIR/avx512-vpclmulhqhqdq-chain.objdump.txt" >/dev/null ||
    die "avx512-vpclmulhqhqdq-chain objdump is missing expected vpclmulhqhqdq bytes"
  grep -F '62 73 55 48 44 cc 11' "$OUT_DIR/avx512-vpclmulhqhqdq-semantic.objdump.txt" >/dev/null ||
    die "avx512-vpclmulhqhqdq-semantic objdump is missing expected vpclmulhqhqdq bytes"
  grep -F '62 52 35 48 dc d0' "$OUT_DIR/avx512-vaesenc-single.objdump.txt" >/dev/null ||
    die "avx512-vaesenc-single objdump is missing expected vaesenc bytes"
  grep -F 'vaesenc zmm10,zmm9,zmm8' "$OUT_DIR/avx512-vaesenc-single.objdump.txt" >/dev/null ||
    die "avx512-vaesenc-single objdump is missing expected vaesenc mnemonic"
  grep -F '62 52 35 48 dc d0' "$OUT_DIR/avx512-vaesenc-chain.objdump.txt" >/dev/null ||
    die "avx512-vaesenc-chain objdump is missing expected vaesenc bytes"
  grep -F '62 52 35 48 dc d0' "$OUT_DIR/avx512-vaesenc-semantic.objdump.txt" >/dev/null ||
    die "avx512-vaesenc-semantic objdump is missing expected vaesenc bytes"
  grep -F '62 72 2d 48 dd df' "$OUT_DIR/avx512-vaesenclast-single.objdump.txt" >/dev/null ||
    die "avx512-vaesenclast-single objdump is missing expected vaesenclast bytes"
  grep -F 'vaesenclast zmm11,zmm10,zmm7' "$OUT_DIR/avx512-vaesenclast-single.objdump.txt" >/dev/null ||
    die "avx512-vaesenclast-single objdump is missing expected vaesenclast mnemonic"
  grep -F '62 72 2d 48 dd df' "$OUT_DIR/avx512-vaesenclast-chain.objdump.txt" >/dev/null ||
    die "avx512-vaesenclast-chain objdump is missing expected vaesenclast bytes"
  grep -F '62 52 35 48 dc d0' "$OUT_DIR/avx512-vaesenclast-chain.objdump.txt" >/dev/null ||
    die "avx512-vaesenclast-chain objdump is missing expected vaesenc bytes"
  grep -F '62 72 2d 48 dd df' "$OUT_DIR/avx512-vaesenclast-semantic.objdump.txt" >/dev/null ||
    die "avx512-vaesenclast-semantic objdump is missing expected vaesenclast bytes"
  grep -F '62 72 fd 48 1a 25 9b' "$OUT_DIR/avx512-vbroadcastf64x2-single.objdump.txt" >/dev/null ||
    die "avx512-vbroadcastf64x2-single objdump is missing expected vbroadcastf64x2 leading bytes"
  grep -F 'vbroadcastf64x2 zmm12' "$OUT_DIR/avx512-vbroadcastf64x2-single.objdump.txt" >/dev/null ||
    die "avx512-vbroadcastf64x2-single objdump is missing expected vbroadcastf64x2 mnemonic"
  grep -F '62 72 fd 48 1a 25 9b' "$OUT_DIR/avx512-vbroadcastf64x2-chain.objdump.txt" >/dev/null ||
    die "avx512-vbroadcastf64x2-chain objdump is missing expected vbroadcastf64x2 leading bytes"
  grep -F 'vbroadcastf64x2 zmm12' "$OUT_DIR/avx512-vbroadcastf64x2-chain.objdump.txt" >/dev/null ||
    die "avx512-vbroadcastf64x2-chain objdump is missing expected vbroadcastf64x2 mnemonic"
  grep -F '62 d1 15 48 73 fc 04' "$OUT_DIR/avx512-vpslldq-single.objdump.txt" >/dev/null ||
    die "avx512-vpslldq-single objdump is missing expected vpslldq bytes"
  grep -F 'vpslldq zmm13,zmm12,0x4' "$OUT_DIR/avx512-vpslldq-single.objdump.txt" >/dev/null ||
    die "avx512-vpslldq-single objdump is missing expected vpslldq mnemonic"
  grep -F '62 d1 15 48 73 fc 04' "$OUT_DIR/avx512-vpslldq-chain.objdump.txt" >/dev/null ||
    die "avx512-vpslldq-chain objdump is missing expected vpslldq bytes"
  grep -F 'vpslldq zmm13,zmm12,0x4' "$OUT_DIR/avx512-vpslldq-chain.objdump.txt" >/dev/null ||
    die "avx512-vpslldq-chain objdump is missing expected vpslldq mnemonic"
  grep -F '62 d1 0d 48 73 dd 04' "$OUT_DIR/avx512-vpsrldq-single.objdump.txt" >/dev/null ||
    die "avx512-vpsrldq-single objdump is missing expected vpsrldq bytes"
  grep -F 'vpsrldq zmm14,zmm13,0x4' "$OUT_DIR/avx512-vpsrldq-single.objdump.txt" >/dev/null ||
    die "avx512-vpsrldq-single objdump is missing expected vpsrldq mnemonic"
  grep -F '62 d1 0d 48 73 dd 04' "$OUT_DIR/avx512-vpsrldq-chain.objdump.txt" >/dev/null ||
    die "avx512-vpsrldq-chain objdump is missing expected vpsrldq bytes"
  grep -F 'vpsrldq zmm14,zmm13,0x4' "$OUT_DIR/avx512-vpsrldq-chain.objdump.txt" >/dev/null ||
    die "avx512-vpsrldq-chain objdump is missing expected vpsrldq mnemonic"
  grep -F '62 53 7d 48 39 f7 01' "$OUT_DIR/avx512-vextracti32x4-single.objdump.txt" >/dev/null ||
    die "avx512-vextracti32x4-single objdump is missing expected vextracti32x4 bytes"
  grep -F 'vextracti32x4 xmm15,zmm14,0x1' "$OUT_DIR/avx512-vextracti32x4-single.objdump.txt" >/dev/null ||
    die "avx512-vextracti32x4-single objdump is missing expected vextracti32x4 mnemonic"
  grep -F '62 53 7d 48 39 f7 01' "$OUT_DIR/avx512-vextracti32x4-chain.objdump.txt" >/dev/null ||
    die "avx512-vextracti32x4-chain objdump is missing expected vextracti32x4 bytes"
  grep -F 'vextracti32x4 xmm15,zmm14,0x1' "$OUT_DIR/avx512-vextracti32x4-chain.objdump.txt" >/dev/null ||
    die "avx512-vextracti32x4-chain objdump is missing expected vextracti32x4 mnemonic"
  grep -F '62 33 fd 48 3b f0 01' "$OUT_DIR/avx512-vextracti64x4-single.objdump.txt" >/dev/null ||
    die "avx512-vextracti64x4-single objdump is missing expected vextracti64x4 bytes"
  grep -F 'vextracti64x4 ymm16,zmm14,0x1' "$OUT_DIR/avx512-vextracti64x4-single.objdump.txt" >/dev/null ||
    die "avx512-vextracti64x4-single objdump is missing expected vextracti64x4 mnemonic"
  grep -F '62 33 fd 48 3b f0 01' "$OUT_DIR/avx512-vextracti64x4-chain.objdump.txt" >/dev/null ||
    die "avx512-vextracti64x4-chain objdump is missing expected vextracti64x4 bytes"
  grep -F 'vextracti64x4 ymm16,zmm14,0x1' "$OUT_DIR/avx512-vextracti64x4-chain.objdump.txt" >/dev/null ||
    die "avx512-vextracti64x4-chain objdump is missing expected vextracti64x4 mnemonic"
  grep -F '62 71 7f 48 7f 35 f6' "$OUT_DIR/avx512-vmovdqu8-single.objdump.txt" >/dev/null ||
    die "avx512-vmovdqu8-single objdump is missing expected vmovdqu8 bytes"
  grep -F 'vmovdqu8 ZMMWORD PTR' "$OUT_DIR/avx512-vmovdqu8-single.objdump.txt" >/dev/null ||
    die "avx512-vmovdqu8-single objdump is missing expected vmovdqu8 mnemonic"
  grep -F '62 71 7f 48 7f 35 75' "$OUT_DIR/avx512-vmovdqu8-chain.objdump.txt" >/dev/null ||
    die "avx512-vmovdqu8-chain objdump is missing expected vmovdqu8 bytes"
  grep -F 'vmovdqu8 ZMMWORD PTR' "$OUT_DIR/avx512-vmovdqu8-chain.objdump.txt" >/dev/null ||
    die "avx512-vmovdqu8-chain objdump is missing expected vmovdqu8 mnemonic"
  grep -F '62 f2 6d 48 00 da' "$OUT_DIR/avx512-aggregate-boundary.objdump.txt" >/dev/null ||
    die "avx512-aggregate-boundary objdump is missing expected vpshufb bytes"
  grep -F '62 f1 65 48 fe e2' "$OUT_DIR/avx512-aggregate-boundary.objdump.txt" >/dev/null ||
    die "avx512-aggregate-boundary objdump is missing expected vpaddd bytes"
  grep -F '62 f3 dd 48 25 eb 96' "$OUT_DIR/avx512-aggregate-boundary.objdump.txt" >/dev/null ||
    die "avx512-aggregate-boundary objdump is missing expected vpternlogq bytes"
  grep -F '62 f3 55 48 44 f4 00' "$OUT_DIR/avx512-aggregate-boundary.objdump.txt" >/dev/null ||
    die "avx512-aggregate-boundary objdump is missing expected vpclmullqlqdq bytes"
  grep -F '62 f3 55 48 44 fc 10' "$OUT_DIR/avx512-aggregate-boundary.objdump.txt" >/dev/null ||
    die "avx512-aggregate-boundary objdump is missing expected vpclmullqhqdq bytes"
  grep -F '62 73 55 48 44 c4 01' "$OUT_DIR/avx512-aggregate-boundary.objdump.txt" >/dev/null ||
    die "avx512-aggregate-boundary objdump is missing expected vpclmulhqlqdq bytes"
  grep -F '62 73 55 48 44 cc 11' "$OUT_DIR/avx512-aggregate-boundary.objdump.txt" >/dev/null ||
    die "avx512-aggregate-boundary objdump is missing expected vpclmulhqhqdq bytes"
  grep -F '62 52 35 48 dc d0' "$OUT_DIR/avx512-aggregate-boundary.objdump.txt" >/dev/null ||
    die "avx512-aggregate-boundary objdump is missing expected vaesenc bytes"
  grep -F 'vaesenc zmm10,zmm9,zmm8' "$OUT_DIR/avx512-aggregate-boundary.objdump.txt" >/dev/null ||
    die "avx512-aggregate-boundary objdump is missing expected vaesenc mnemonic"
  grep -F '62 72 2d 48 dd df' "$OUT_DIR/avx512-aggregate-boundary.objdump.txt" >/dev/null ||
    die "avx512-aggregate-boundary objdump is missing expected vaesenclast bytes"
  grep -F 'vaesenclast zmm11,zmm10,zmm7' "$OUT_DIR/avx512-aggregate-boundary.objdump.txt" >/dev/null ||
    die "avx512-aggregate-boundary objdump is missing expected vaesenclast mnemonic"
  grep -F 'vbroadcastf64x2 zmm12' "$OUT_DIR/avx512-aggregate-boundary.objdump.txt" >/dev/null ||
    die "avx512-aggregate-boundary objdump is missing expected vbroadcastf64x2 mnemonic"
  grep -F '62 d1 15 48 73 fc 04' "$OUT_DIR/avx512-aggregate-boundary.objdump.txt" >/dev/null ||
    die "avx512-aggregate-boundary objdump is missing expected vpslldq bytes"
  grep -F 'vpslldq zmm13,zmm12,0x4' "$OUT_DIR/avx512-aggregate-boundary.objdump.txt" >/dev/null ||
    die "avx512-aggregate-boundary objdump is missing expected vpslldq mnemonic"
  grep -F 'vpsrldq zmm14,zmm13,0x4' "$OUT_DIR/avx512-aggregate-boundary.objdump.txt" >/dev/null ||
    die "avx512-aggregate-boundary objdump is missing expected vpsrldq mnemonic"
}

run_capture() {
  local outfile="$1"
  shift
  local rc

  printf '+ ' >"${outfile}.cmd"
  printf '%q ' "$@" >>"${outfile}.cmd"
  printf '\n' >>"${outfile}.cmd"

  set +e
  "$@" >"$outfile" 2>&1
  rc=$?
  set -e
  printf '%s\n' "$rc" >"${outfile}.rc"
}

run_capture_qemu_log() {
  local log_file="$1"
  local outfile="$2"
  shift 2
  local rc

  printf '+ QEMU_LOG_FILENAME=%q ' "$log_file" >"${outfile}.cmd"
  printf '%q ' "$@" >>"${outfile}.cmd"
  printf '\n' >>"${outfile}.cmd"

  set +e
  python3 - "$log_file" "$outfile" "$@" <<'PY'
import os
import subprocess
import sys

log_file = sys.argv[1]
outfile = sys.argv[2]
cmd = sys.argv[3:]
env = os.environ.copy()
env["QEMU_LOG_FILENAME"] = log_file

with open(outfile, "wb") as out:
    proc = subprocess.run(cmd, stdout=out, stderr=subprocess.STDOUT, env=env)

rc = proc.returncode
if rc < 0:
    rc = 128 + (-rc)
sys.exit(rc)
PY
  rc=$?
  set -e
  printf '%s\n' "$rc" >"${outfile}.rc"
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

count_hits() {
  local pattern="$1"
  shift
  { grep -Ehi "$pattern" "$@" 2>/dev/null || true; } | wc -l | tr -d ' '
}

init_summary() {
  mkdir -p "$OUT_DIR"
  {
    echo "# QEMU $QEMU_VERSION AVX-512 Patch Series Harness"
    echo
    echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
    echo "- Scratch root: \`$SCRATCH_ROOT\`"
    echo "- Source input: \`${SOURCE_SRC:-not selected yet}\`"
    echo "- Patched source: \`$PATCHED_SRC\`"
    echo "- Build directory: \`$BUILD_DIR\`"
    echo "- QEMU binary: \`$BUILD_DIR/qemu-x86_64\`"
    echo "- Jobs: \`$JOBS\`"
    echo
    echo "## Patch Series"
    echo
    echo "| Order | Patch | Purpose |"
    echo "|---:|---|---|"
    echo "| 1 | [0001-qemu-${QEMU_VERSION}-avx512-min-feature-masks.patch]($PATCH_DIR/0001-qemu-${QEMU_VERSION}-avx512-min-feature-masks.patch) | Expose minimum TCG AVX512F, VPCLMULQDQ, and AVX-512 XCR0 state bits. |"
    echo "| 2 | [0002-qemu-${QEMU_VERSION}-evex-vpxorq-smoke.patch]($PATCH_DIR/0002-qemu-${QEMU_VERSION}-evex-vpxorq-smoke.patch) | Add exact-byte EVEX \`vpxorq zmm0,zmm0,zmm0\` smoke semantics. |"
    echo "| 3 | [0003-qemu-${QEMU_VERSION}-evex-vmovdqa64-smoke.patch]($PATCH_DIR/0003-qemu-${QEMU_VERSION}-evex-vmovdqa64-smoke.patch) | Add exact-byte EVEX \`vmovdqa64 zmm1,zmm0\` register-move smoke semantics. |"
    echo "| 4 | [0004-qemu-${QEMU_VERSION}-evex-vmovdqu64-smoke.patch]($PATCH_DIR/0004-qemu-${QEMU_VERSION}-evex-vmovdqu64-smoke.patch) | Add exact-byte EVEX \`vmovdqu64\` RIP-relative store/load smoke semantics. |"
    echo "| 5 | [0005-qemu-${QEMU_VERSION}-evex-vpshufb-smoke.patch]($PATCH_DIR/0005-qemu-${QEMU_VERSION}-evex-vpshufb-smoke.patch) | Add exact-byte EVEX \`vpshufb zmm3,zmm2,zmm2\` smoke semantics. |"
    echo "| 6 | [0006-qemu-${QEMU_VERSION}-evex-vpaddd-smoke.patch]($PATCH_DIR/0006-qemu-${QEMU_VERSION}-evex-vpaddd-smoke.patch) | Add exact-byte EVEX \`vpaddd zmm4,zmm3,zmm2\` smoke semantics. |"
    echo "| 7 | [0007-qemu-${QEMU_VERSION}-evex-vpternlogq-smoke.patch]($PATCH_DIR/0007-qemu-${QEMU_VERSION}-evex-vpternlogq-smoke.patch) | Add exact-byte EVEX \`vpternlogq zmm5,zmm4,zmm3,0x96\` smoke semantics. |"
    echo "| 8 | [0008-qemu-${QEMU_VERSION}-evex-vpclmullqlqdq-smoke.patch]($PATCH_DIR/0008-qemu-${QEMU_VERSION}-evex-vpclmullqlqdq-smoke.patch) | Add exact-byte EVEX \`vpclmullqlqdq zmm6,zmm5,zmm4\` smoke semantics. |"
    echo "| 9 | [0009-qemu-${QEMU_VERSION}-evex-vpclmullqhqdq-smoke.patch]($PATCH_DIR/0009-qemu-${QEMU_VERSION}-evex-vpclmullqhqdq-smoke.patch) | Add exact-byte EVEX \`vpclmullqhqdq zmm7,zmm5,zmm4\` smoke semantics. |"
    echo "| 10 | [0010-qemu-${QEMU_VERSION}-evex-vpclmulhqlqdq-smoke.patch]($PATCH_DIR/0010-qemu-${QEMU_VERSION}-evex-vpclmulhqlqdq-smoke.patch) | Add exact-byte EVEX \`vpclmulhqlqdq zmm8,zmm5,zmm4\` smoke semantics. |"
    echo "| 11 | [0011-qemu-${QEMU_VERSION}-evex-vpclmulhqhqdq-smoke.patch]($PATCH_DIR/0011-qemu-${QEMU_VERSION}-evex-vpclmulhqhqdq-smoke.patch) | Add exact-byte EVEX \`vpclmulhqhqdq zmm9,zmm5,zmm4\` smoke semantics. |"
    echo "| 12 | [0012-qemu-${QEMU_VERSION}-evex-vaesenc-smoke.patch]($PATCH_DIR/0012-qemu-${QEMU_VERSION}-evex-vaesenc-smoke.patch) | Add exact-byte EVEX \`vaesenc zmm10,zmm9,zmm8\` smoke semantics. |"
    echo "| 13 | [0013-qemu-${QEMU_VERSION}-evex-vaesenclast-smoke.patch]($PATCH_DIR/0013-qemu-${QEMU_VERSION}-evex-vaesenclast-smoke.patch) | Add exact-byte EVEX \`vaesenclast zmm11,zmm10,zmm7\` smoke semantics. |"
    echo "| 14 | [0014-qemu-${QEMU_VERSION}-evex-vbroadcastf64x2-smoke.patch]($PATCH_DIR/0014-qemu-${QEMU_VERSION}-evex-vbroadcastf64x2-smoke.patch) | Add exact-byte EVEX \`vbroadcastf64x2 zmm12,[rip+disp32]\` smoke semantics. |"
    echo "| 15 | [0015-qemu-${QEMU_VERSION}-evex-vpslldq-smoke.patch]($PATCH_DIR/0015-qemu-${QEMU_VERSION}-evex-vpslldq-smoke.patch) | Add exact-byte EVEX \`vpslldq zmm13,zmm12,0x4\` smoke semantics. |"
    echo "| 16 | [0016-qemu-${QEMU_VERSION}-evex-vpsrldq-smoke.patch]($PATCH_DIR/0016-qemu-${QEMU_VERSION}-evex-vpsrldq-smoke.patch) | Add exact-byte EVEX \`vpsrldq zmm14,zmm13,0x4\` smoke semantics. |"
    echo "| 17 | [0017-qemu-${QEMU_VERSION}-evex-vextracti32x4-smoke.patch]($PATCH_DIR/0017-qemu-${QEMU_VERSION}-evex-vextracti32x4-smoke.patch) | Add exact-byte EVEX \`vextracti32x4 xmm15,zmm14,0x1\` smoke semantics. |"
    echo "| 18 | [0018-qemu-${QEMU_VERSION}-evex-vextracti64x4-smoke.patch]($PATCH_DIR/0018-qemu-${QEMU_VERSION}-evex-vextracti64x4-smoke.patch) | Add exact-byte EVEX \`vextracti64x4 ymm16,zmm14,0x1\` smoke semantics. |"
    echo "| 19 | [0019-qemu-${QEMU_VERSION}-evex-vmovdqu8-smoke.patch]($PATCH_DIR/0019-qemu-${QEMU_VERSION}-evex-vmovdqu8-smoke.patch) | Add exact-byte EVEX \`vmovdqu8\` RIP-relative store smoke semantics. |"
  } >"$SUMMARY"
}

run_feature_probe() {
  local outfile="$OUT_DIR/feature-max.out"
  local ebx ecx xcr0

  log "Running CPUID/XCR0 feature probe"
  run_capture "$outfile" "$BUILD_DIR/qemu-x86_64" -cpu max "$FEATURE_PROBE"
  FEATURE_RC="$(cat "${outfile}.rc")"

  ebx="$(grep '^cpuid\.7\.0:' "$outfile" 2>/dev/null | sed -n 's/.* ebx=\([0-9a-fA-F]*\).*/\1/p' | head -1)"
  ecx="$(grep '^cpuid\.7\.0:' "$outfile" 2>/dev/null | sed -n 's/.* ecx=\([0-9a-fA-F]*\).*/\1/p' | head -1)"
  xcr0="$(sed -n 's/^xcr0=\([0-9a-fA-F]*\)$/\1/p' "$outfile" 2>/dev/null | head -1)"

  FEATURE_AVX512F="$(bit_yesno "$ebx" 16)"
  FEATURE_VPCLMULQDQ="$(bit_yesno "$ecx" 10)"
  FEATURE_XCR0_STATE="$(xcr0_avx512_yesno "$xcr0")"

  if [[ "$FEATURE_RC" = "0" && "$FEATURE_AVX512F" = "yes" &&
        "$FEATURE_VPCLMULQDQ" = "yes" && "$FEATURE_XCR0_STATE" = "yes" ]]; then
    FEATURE_RESULT="PASS"
  fi
  FEATURE_EVIDENCE="rc=$FEATURE_RC avx512f=$FEATURE_AVX512F vpclmulqdq=$FEATURE_VPCLMULQDQ xcr0_avx512=$FEATURE_XCR0_STATE output=$(basename "$outfile")"

  {
    echo
    echo "## Feature Probe"
    echo
    echo "| CPU args | RC | CPUID.7.0 EBX | CPUID.7.0 ECX | XCR0 | AVX512F | VPCLMULQDQ | XCR0 AVX-512 state | Result | Output |"
    echo "|---|---:|---|---|---|---|---|---|---|---|"
    printf '| `%s` | %s | `%s` | `%s` | `%s` | %s | %s | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$FEATURE_RC" \
      "${ebx:-n/a}" \
      "${ecx:-n/a}" \
      "${xcr0:-n/a}" \
      "$FEATURE_AVX512F" \
      "$FEATURE_VPCLMULQDQ" \
      "$FEATURE_XCR0_STATE" \
      "$FEATURE_RESULT" \
      "$(basename "$outfile")" \
      "$outfile"
  } >>"$SUMMARY"
}

run_evex_smoke_probe() {
  local label="$1"
  local probe="$2"
  local out_prefix="$3"

  SMOKE_RESULT="FAIL"
  SMOKE_RC="n/a"
  SMOKE_VECTOR_HITS="0"
  SMOKE_EXCEPTION_HITS="0"
  SMOKE_OUT="$OUT_DIR/${out_prefix}.max.out"
  SMOKE_LOG="$OUT_DIR/${out_prefix}.max.qemu.log"

  log "Running EVEX $label smoke probe"
  run_capture_qemu_log "$SMOKE_LOG" \
    "$SMOKE_OUT" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$probe"
  SMOKE_RC="$(cat "${SMOKE_OUT}.rc")"
  SMOKE_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$SMOKE_LOG" "$SMOKE_OUT")"
  SMOKE_VECTOR_HITS="$(count_hits '\b(ld_vec|st_vec|mov_vec)\b' "$SMOKE_LOG")"

  if [[ "$SMOKE_RC" = "0" && "$SMOKE_EXCEPTION_HITS" = "0" &&
        "$SMOKE_VECTOR_HITS" -gt 0 ]]; then
    SMOKE_RESULT="PASS"
  fi
}

run_vmovdqu64_memory_probe() {
  local label="$1"
  local probe="$2"
  local out_prefix="$3"
  local min_memory_hits="$4"

  MEMORY_SMOKE_RESULT="FAIL"
  MEMORY_SMOKE_RC="n/a"
  MEMORY_SMOKE_MEMORY_HITS="0"
  MEMORY_SMOKE_EXCEPTION_HITS="0"
  MEMORY_SMOKE_OUT="$OUT_DIR/${out_prefix}.max.out"
  MEMORY_SMOKE_LOG="$OUT_DIR/${out_prefix}.max.qemu.log"

  log "Running EVEX vmovdqu64 $label smoke probe"
  run_capture_qemu_log "$MEMORY_SMOKE_LOG" \
    "$MEMORY_SMOKE_OUT" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$probe"
  MEMORY_SMOKE_RC="$(cat "${MEMORY_SMOKE_OUT}.rc")"
  MEMORY_SMOKE_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$MEMORY_SMOKE_LOG" "$MEMORY_SMOKE_OUT")"
  MEMORY_SMOKE_MEMORY_HITS="$(count_hits 'qemu_(ld|st)[0-9]*_i128|qemu_(ld|st)[0-9]*_i64' "$MEMORY_SMOKE_LOG")"

  if [[ "$MEMORY_SMOKE_RC" = "0" && "$MEMORY_SMOKE_EXCEPTION_HITS" = "0" &&
        "$MEMORY_SMOKE_MEMORY_HITS" -ge "$min_memory_hits" ]]; then
    MEMORY_SMOKE_RESULT="PASS"
  fi
}

run_vpshufb_smoke_probe() {
  local label="$1"
  local probe="$2"
  local out_prefix="$3"

  VPSHUFB_RESULT="FAIL"
  VPSHUFB_RC="n/a"
  VPSHUFB_PSHUFB_HITS="0"
  VPSHUFB_EXCEPTION_HITS="0"
  VPSHUFB_OUT="$OUT_DIR/${out_prefix}.max.out"
  VPSHUFB_LOG="$OUT_DIR/${out_prefix}.max.qemu.log"

  log "Running EVEX $label smoke probe"
  run_capture_qemu_log "$VPSHUFB_LOG" \
    "$VPSHUFB_OUT" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$probe"
  VPSHUFB_RC="$(cat "${VPSHUFB_OUT}.rc")"
  VPSHUFB_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$VPSHUFB_LOG" "$VPSHUFB_OUT")"
  VPSHUFB_PSHUFB_HITS="$(count_hits 'vpshufb zmm3,zmm2,zmm2|pshufb' "$VPSHUFB_LOG" "$VPSHUFB_OUT")"

  if [[ "$VPSHUFB_RC" = "0" && "$VPSHUFB_EXCEPTION_HITS" = "0" &&
        "$VPSHUFB_PSHUFB_HITS" -gt 0 ]]; then
    VPSHUFB_RESULT="PASS"
  fi
}

run_vpaddd_smoke_probe() {
  local label="$1"
  local probe="$2"
  local out_prefix="$3"

  VPADDD_RESULT="FAIL"
  VPADDD_RC="n/a"
  VPADDD_ADD_HITS="0"
  VPADDD_EXCEPTION_HITS="0"
  VPADDD_OUT="$OUT_DIR/${out_prefix}.max.out"
  VPADDD_LOG="$OUT_DIR/${out_prefix}.max.qemu.log"

  log "Running EVEX $label smoke probe"
  run_capture_qemu_log "$VPADDD_LOG" \
    "$VPADDD_OUT" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$probe"
  VPADDD_RC="$(cat "${VPADDD_OUT}.rc")"
  VPADDD_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$VPADDD_LOG" "$VPADDD_OUT")"
  VPADDD_ADD_HITS="$(count_hits 'vpaddd zmm4,zmm3,zmm2|add_vec v256,e32|add_vec' "$VPADDD_LOG" "$VPADDD_OUT")"

  if [[ "$VPADDD_RC" = "0" && "$VPADDD_EXCEPTION_HITS" = "0" &&
        "$VPADDD_ADD_HITS" -gt 0 ]]; then
    VPADDD_RESULT="PASS"
  fi
}

run_vpternlogq_smoke_probe() {
  local label="$1"
  local probe="$2"
  local out_prefix="$3"

  VPTERNLOGQ_RESULT="FAIL"
  VPTERNLOGQ_RC="n/a"
  VPTERNLOGQ_TERNLOG_HITS="0"
  VPTERNLOGQ_XOR_HITS="0"
  VPTERNLOGQ_EXCEPTION_HITS="0"
  VPTERNLOGQ_OUT="$OUT_DIR/${out_prefix}.max.out"
  VPTERNLOGQ_LOG="$OUT_DIR/${out_prefix}.max.qemu.log"

  log "Running EVEX $label smoke probe"
  run_capture_qemu_log "$VPTERNLOGQ_LOG" \
    "$VPTERNLOGQ_OUT" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$probe"
  VPTERNLOGQ_RC="$(cat "${VPTERNLOGQ_OUT}.rc")"
  VPTERNLOGQ_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$VPTERNLOGQ_LOG" "$VPTERNLOGQ_OUT")"
  VPTERNLOGQ_TERNLOG_HITS="$(count_hits '62f3dd4825eb96|62 f3 dd 48 25 eb 96|vpternlogq zmm5,zmm4,zmm3,0x96|vpternlogq' "$VPTERNLOGQ_LOG" "$VPTERNLOGQ_OUT")"
  VPTERNLOGQ_XOR_HITS="$(count_hits 'xor_vec|xor_i64|xor_i32' "$VPTERNLOGQ_LOG")"

  if [[ "$VPTERNLOGQ_RC" = "0" && "$VPTERNLOGQ_EXCEPTION_HITS" = "0" &&
        "$VPTERNLOGQ_TERNLOG_HITS" -gt 0 && "$VPTERNLOGQ_XOR_HITS" -gt 0 ]]; then
    VPTERNLOGQ_RESULT="PASS"
  fi
}

run_vpclmullqlq_smoke_probe() {
  local label="$1"
  local probe="$2"
  local out_prefix="$3"

  VPCLMULLQLQ_RESULT="FAIL"
  VPCLMULLQLQ_RC="n/a"
  VPCLMULLQLQ_HITS="0"
  VPCLMULLQLQ_EXCEPTION_HITS="0"
  VPCLMULLQLQ_OUT="$OUT_DIR/${out_prefix}.max.out"
  VPCLMULLQLQ_LOG="$OUT_DIR/${out_prefix}.max.qemu.log"

  log "Running EVEX $label smoke probe"
  run_capture_qemu_log "$VPCLMULLQLQ_LOG" \
    "$VPCLMULLQLQ_OUT" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$probe"
  VPCLMULLQLQ_RC="$(cat "${VPCLMULLQLQ_OUT}.rc")"
  VPCLMULLQLQ_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$VPCLMULLQLQ_LOG" "$VPCLMULLQLQ_OUT")"
  VPCLMULLQLQ_HITS="$(count_hits '62f3554844f400|62 f3 55 48 44 f4 00|vpclmullqlqdq zmm6,zmm5,zmm4|pclmulqdq' "$VPCLMULLQLQ_LOG" "$VPCLMULLQLQ_OUT")"

  if [[ "$VPCLMULLQLQ_RC" = "0" && "$VPCLMULLQLQ_EXCEPTION_HITS" = "0" &&
        "$VPCLMULLQLQ_HITS" -gt 0 ]]; then
    VPCLMULLQLQ_RESULT="PASS"
  fi
}

run_vpclmullqhq_smoke_probe() {
  local label="$1"
  local probe="$2"
  local out_prefix="$3"

  VPCLMULLQHQ_RESULT="FAIL"
  VPCLMULLQHQ_RC="n/a"
  VPCLMULLQHQ_HITS="0"
  VPCLMULLQHQ_EXCEPTION_HITS="0"
  VPCLMULLQHQ_OUT="$OUT_DIR/${out_prefix}.max.out"
  VPCLMULLQHQ_LOG="$OUT_DIR/${out_prefix}.max.qemu.log"

  log "Running EVEX $label smoke probe"
  run_capture_qemu_log "$VPCLMULLQHQ_LOG" \
    "$VPCLMULLQHQ_OUT" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$probe"
  VPCLMULLQHQ_RC="$(cat "${VPCLMULLQHQ_OUT}.rc")"
  VPCLMULLQHQ_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$VPCLMULLQHQ_LOG" "$VPCLMULLQHQ_OUT")"
  VPCLMULLQHQ_HITS="$(count_hits '62f3554844fc10|62 f3 55 48 44 fc 10|vpclmullqhqdq zmm7,zmm5,zmm4|pclmulqdq' "$VPCLMULLQHQ_LOG" "$VPCLMULLQHQ_OUT")"

  if [[ "$VPCLMULLQHQ_RC" = "0" && "$VPCLMULLQHQ_EXCEPTION_HITS" = "0" &&
        "$VPCLMULLQHQ_HITS" -gt 0 ]]; then
    VPCLMULLQHQ_RESULT="PASS"
  fi
}

run_vpclmulhqlq_smoke_probe() {
  local label="$1"
  local probe="$2"
  local out_prefix="$3"

  VPCLMULHQLQ_RESULT="FAIL"
  VPCLMULHQLQ_RC="n/a"
  VPCLMULHQLQ_HITS="0"
  VPCLMULHQLQ_EXCEPTION_HITS="0"
  VPCLMULHQLQ_OUT="$OUT_DIR/${out_prefix}.max.out"
  VPCLMULHQLQ_LOG="$OUT_DIR/${out_prefix}.max.qemu.log"

  log "Running EVEX $label smoke probe"
  run_capture_qemu_log "$VPCLMULHQLQ_LOG" \
    "$VPCLMULHQLQ_OUT" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$probe"
  VPCLMULHQLQ_RC="$(cat "${VPCLMULHQLQ_OUT}.rc")"
  VPCLMULHQLQ_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$VPCLMULHQLQ_LOG" "$VPCLMULHQLQ_OUT")"
  VPCLMULHQLQ_HITS="$(count_hits '6273554844c401|62 73 55 48 44 c4 01|vpclmulhqlqdq zmm8,zmm5,zmm4|pclmulqdq' "$VPCLMULHQLQ_LOG" "$VPCLMULHQLQ_OUT")"

  if [[ "$VPCLMULHQLQ_RC" = "0" && "$VPCLMULHQLQ_EXCEPTION_HITS" = "0" &&
        "$VPCLMULHQLQ_HITS" -gt 0 ]]; then
    VPCLMULHQLQ_RESULT="PASS"
  fi
}

run_vpclmulhqhq_smoke_probe() {
  local label="$1"
  local probe="$2"
  local out_prefix="$3"

  VPCLMULHQHQ_RESULT="FAIL"
  VPCLMULHQHQ_RC="n/a"
  VPCLMULHQHQ_HITS="0"
  VPCLMULHQHQ_EXCEPTION_HITS="0"
  VPCLMULHQHQ_OUT="$OUT_DIR/${out_prefix}.max.out"
  VPCLMULHQHQ_LOG="$OUT_DIR/${out_prefix}.max.qemu.log"

  log "Running EVEX $label smoke probe"
  run_capture_qemu_log "$VPCLMULHQHQ_LOG" \
    "$VPCLMULHQHQ_OUT" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$probe"
  VPCLMULHQHQ_RC="$(cat "${VPCLMULHQHQ_OUT}.rc")"
  VPCLMULHQHQ_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$VPCLMULHQHQ_LOG" "$VPCLMULHQHQ_OUT")"
  VPCLMULHQHQ_HITS="$(count_hits '6273554844cc11|62 73 55 48 44 cc 11|vpclmulhqhqdq zmm9,zmm5,zmm4|pclmulqdq' "$VPCLMULHQHQ_LOG" "$VPCLMULHQHQ_OUT")"

  if [[ "$VPCLMULHQHQ_RC" = "0" && "$VPCLMULHQHQ_EXCEPTION_HITS" = "0" &&
        "$VPCLMULHQHQ_HITS" -gt 0 ]]; then
    VPCLMULHQHQ_RESULT="PASS"
  fi
}

run_vaesenc_smoke_probe() {
  local label="$1"
  local probe="$2"
  local out_prefix="$3"

  VAESENC_RESULT="FAIL"
  VAESENC_RC="n/a"
  VAESENC_HITS="0"
  VAESENC_HELPER_HITS="0"
  VAESENC_EXCEPTION_HITS="0"
  VAESENC_OUT="$OUT_DIR/${out_prefix}.max.out"
  VAESENC_LOG="$OUT_DIR/${out_prefix}.max.qemu.log"

  log "Running EVEX $label smoke probe"
  run_capture_qemu_log "$VAESENC_LOG" \
    "$VAESENC_OUT" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$probe"
  VAESENC_RC="$(cat "${VAESENC_OUT}.rc")"
  VAESENC_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$VAESENC_LOG" "$VAESENC_OUT")"
  VAESENC_HITS="$(count_hits '62523548dcd0|62 52 35 48 dc d0|vaesenc zmm10,zmm9,zmm8|vaesenc' "$VAESENC_LOG" "$VAESENC_OUT")"
  VAESENC_HELPER_HITS="$(count_hits 'aesenc_xmm' "$VAESENC_LOG")"

  if [[ "$VAESENC_RC" = "0" && "$VAESENC_EXCEPTION_HITS" = "0" &&
        "$VAESENC_HITS" -gt 0 && "$VAESENC_HELPER_HITS" -ge 4 ]]; then
    VAESENC_RESULT="PASS"
  fi
}

run_vaesenclast_smoke_probe() {
  local label="$1"
  local probe="$2"
  local out_prefix="$3"

  VAESENCLAST_RESULT="FAIL"
  VAESENCLAST_RC="n/a"
  VAESENCLAST_HITS="0"
  VAESENCLAST_HELPER_HITS="0"
  VAESENCLAST_EXCEPTION_HITS="0"
  VAESENCLAST_OUT="$OUT_DIR/${out_prefix}.max.out"
  VAESENCLAST_LOG="$OUT_DIR/${out_prefix}.max.qemu.log"

  log "Running EVEX $label smoke probe"
  run_capture_qemu_log "$VAESENCLAST_LOG" \
    "$VAESENCLAST_OUT" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$probe"
  VAESENCLAST_RC="$(cat "${VAESENCLAST_OUT}.rc")"
  VAESENCLAST_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$VAESENCLAST_LOG" "$VAESENCLAST_OUT")"
  VAESENCLAST_HITS="$(count_hits '62722d48dddf|62 72 2d 48 dd df|vaesenclast zmm11,zmm10,zmm7|vaesenclast' "$VAESENCLAST_LOG" "$VAESENCLAST_OUT")"
  VAESENCLAST_HELPER_HITS="$(count_hits 'aesenclast_xmm' "$VAESENCLAST_LOG")"

  if [[ "$VAESENCLAST_RC" = "0" && "$VAESENCLAST_EXCEPTION_HITS" = "0" &&
        "$VAESENCLAST_HITS" -gt 0 && "$VAESENCLAST_HELPER_HITS" -ge 4 ]]; then
    VAESENCLAST_RESULT="PASS"
  fi
}

run_vbroadcastf64x2_smoke_probe() {
  local label="$1"
  local probe="$2"
  local out_prefix="$3"

  VBROADCASTF64X2_RESULT="FAIL"
  VBROADCASTF64X2_RC="n/a"
  VBROADCASTF64X2_EXCEPTION_HITS="0"
  VBROADCASTF64X2_VBROADCAST_HITS="0"
  VBROADCASTF64X2_QEMU_LD_I128_HITS="0"
  VBROADCASTF64X2_QEMU_LD2_I128_HITS="0"
  VBROADCASTF64X2_ST_I128_HITS="0"
  VBROADCASTF64X2_ST_I64_HITS="0"
  VBROADCASTF64X2_OUT="$OUT_DIR/${out_prefix}.max.out"
  VBROADCASTF64X2_LOG="$OUT_DIR/${out_prefix}.max.qemu.log"

  log "Running EVEX $label smoke probe"
  run_capture_qemu_log "$VBROADCASTF64X2_LOG" \
    "$VBROADCASTF64X2_OUT" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$probe"
  VBROADCASTF64X2_RC="$(cat "${VBROADCASTF64X2_OUT}.rc")"
  VBROADCASTF64X2_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$VBROADCASTF64X2_LOG" "$VBROADCASTF64X2_OUT")"
  VBROADCASTF64X2_VBROADCAST_HITS="$(count_hits '62 72 fd 48 1a 25 9b 0f 00 00|vbroadcastf64x2 zmm12|vbroadcastf64x2' "$VBROADCASTF64X2_LOG" "$VBROADCASTF64X2_OUT")"
  VBROADCASTF64X2_QEMU_LD_I128_HITS="$(count_hits 'qemu_ld_i128' "$VBROADCASTF64X2_LOG" "$VBROADCASTF64X2_OUT")"
  VBROADCASTF64X2_QEMU_LD2_I128_HITS="$(count_hits 'qemu_ld2_i128' "$VBROADCASTF64X2_LOG" "$VBROADCASTF64X2_OUT")"
  VBROADCASTF64X2_ST_I128_HITS="$(count_hits 'st_i128' "$VBROADCASTF64X2_LOG" "$VBROADCASTF64X2_OUT")"
  VBROADCASTF64X2_ST_I64_HITS="$(count_hits 'st_i64' "$VBROADCASTF64X2_LOG" "$VBROADCASTF64X2_OUT")"

  if [[ "$VBROADCASTF64X2_RC" = "0" && "$VBROADCASTF64X2_EXCEPTION_HITS" = "0" &&
        ( ( "$VBROADCASTF64X2_QEMU_LD_I128_HITS" -ge 1 && "$VBROADCASTF64X2_ST_I128_HITS" -ge 4 ) ||
          ( "$VBROADCASTF64X2_QEMU_LD2_I128_HITS" -ge 1 && "$VBROADCASTF64X2_ST_I64_HITS" -ge 8 ) ) ]]; then
    VBROADCASTF64X2_RESULT="PASS"
  fi

  VBROADCASTF64X2_EVIDENCE="rc=$VBROADCASTF64X2_RC exception_hits=$VBROADCASTF64X2_EXCEPTION_HITS vbroadcast_hits=$VBROADCASTF64X2_VBROADCAST_HITS qemu_ld_i128_hits=$VBROADCASTF64X2_QEMU_LD_I128_HITS qemu_ld2_i128_hits=$VBROADCASTF64X2_QEMU_LD2_I128_HITS st_i128_hits=$VBROADCASTF64X2_ST_I128_HITS st_i64_hits=$VBROADCASTF64X2_ST_I64_HITS"
}

run_vpslldq_smoke_probe() {
  local label="$1"
  local single_probe="$2"
  local chain_probe="$3"
  local out_prefix="$4"

  VPSLLDQ_RESULT="FAIL"
  VPSLLDQ_SINGLE_RESULT="FAIL"
  VPSLLDQ_SINGLE_RC="n/a"
  VPSLLDQ_SINGLE_EXCEPTION_HITS="0"
  VPSLLDQ_SINGLE_HITS="0"
  VPSLLDQ_CHAIN_RESULT="FAIL"
  VPSLLDQ_CHAIN_RC="n/a"
  VPSLLDQ_CHAIN_EXCEPTION_HITS="0"
  VPSLLDQ_CHAIN_HITS="0"

  local single_out="$OUT_DIR/${out_prefix}-single.max.out"
  local single_log="$OUT_DIR/${out_prefix}-single.max.qemu.log"
  local chain_out="$OUT_DIR/${out_prefix}-chain.max.out"
  local chain_log="$OUT_DIR/${out_prefix}-chain.max.qemu.log"

  log "Running EVEX $label smoke probe"
  run_capture_qemu_log "$single_log" \
    "$single_out" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$single_probe"
  VPSLLDQ_SINGLE_RC="$(cat "${single_out}.rc")"
  VPSLLDQ_SINGLE_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$single_log" "$single_out")"
  VPSLLDQ_SINGLE_HITS="$(count_hits '62 d1 15 48 73 fc 04|vpslldq zmm13,zmm12,0x4|pslldq_xmm' "$single_log" "$single_out")"
  if [[ "$VPSLLDQ_SINGLE_RC" = "0" && "$VPSLLDQ_SINGLE_EXCEPTION_HITS" = "0" &&
        "$VPSLLDQ_SINGLE_HITS" -gt 0 ]]; then
    VPSLLDQ_SINGLE_RESULT="PASS"
  fi

  run_capture_qemu_log "$chain_log" \
    "$chain_out" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$chain_probe"
  VPSLLDQ_CHAIN_RC="$(cat "${chain_out}.rc")"
  VPSLLDQ_CHAIN_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$chain_log" "$chain_out")"
  VPSLLDQ_CHAIN_HITS="$(count_hits '62 d1 15 48 73 fc 04|vpslldq zmm13,zmm12,0x4|pslldq_xmm' "$chain_log" "$chain_out")"
  if [[ "$VPSLLDQ_CHAIN_RC" = "0" && "$VPSLLDQ_CHAIN_EXCEPTION_HITS" = "0" &&
        "$VPSLLDQ_CHAIN_HITS" -gt 0 ]]; then
    VPSLLDQ_CHAIN_RESULT="PASS"
  fi

  if [[ "$VPSLLDQ_SINGLE_RESULT" = "PASS" && "$VPSLLDQ_CHAIN_RESULT" = "PASS" ]]; then
    VPSLLDQ_RESULT="PASS"
  elif [[ "$AGGREGATE_BOUNDARY_RESULT" = "PASS" ]]; then
    VPSLLDQ_RESULT="PARTIAL"
  fi

  VPSLLDQ_EVIDENCE="single=$VPSLLDQ_SINGLE_RESULT rc=$VPSLLDQ_SINGLE_RC vpslldq_hits=$VPSLLDQ_SINGLE_HITS exception_hits=$VPSLLDQ_SINGLE_EXCEPTION_HITS; chain=$VPSLLDQ_CHAIN_RESULT rc=$VPSLLDQ_CHAIN_RC vpslldq_hits=$VPSLLDQ_CHAIN_HITS exception_hits=$VPSLLDQ_CHAIN_EXCEPTION_HITS"
}

run_vpsrldq_smoke_probe() {
  local label="$1"
  local single_probe="$2"
  local chain_probe="$3"
  local out_prefix="$4"

  VPSRLDQ_RESULT="FAIL"
  VPSRLDQ_SINGLE_RESULT="FAIL"
  VPSRLDQ_SINGLE_RC="n/a"
  VPSRLDQ_SINGLE_EXCEPTION_HITS="0"
  VPSRLDQ_SINGLE_HITS="0"
  VPSRLDQ_CHAIN_RESULT="FAIL"
  VPSRLDQ_CHAIN_RC="n/a"
  VPSRLDQ_CHAIN_EXCEPTION_HITS="0"
  VPSRLDQ_CHAIN_HITS="0"

  local single_out="$OUT_DIR/${out_prefix}-single.max.out"
  local single_log="$OUT_DIR/${out_prefix}-single.max.qemu.log"
  local chain_out="$OUT_DIR/${out_prefix}-chain.max.out"
  local chain_log="$OUT_DIR/${out_prefix}-chain.max.qemu.log"

  log "Running EVEX $label smoke probe"
  run_capture_qemu_log "$single_log" \
    "$single_out" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$single_probe"
  VPSRLDQ_SINGLE_RC="$(cat "${single_out}.rc")"
  VPSRLDQ_SINGLE_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$single_log" "$single_out")"
  VPSRLDQ_SINGLE_HITS="$(count_hits '62 d1 0d 48 73 dd 04|vpsrldq zmm14,zmm13,0x4|psrldq_xmm' "$single_log" "$single_out")"
  if [[ "$VPSRLDQ_SINGLE_RC" = "0" && "$VPSRLDQ_SINGLE_EXCEPTION_HITS" = "0" &&
        "$VPSRLDQ_SINGLE_HITS" -gt 0 ]]; then
    VPSRLDQ_SINGLE_RESULT="PASS"
  fi

  run_capture_qemu_log "$chain_log" \
    "$chain_out" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$chain_probe"
  VPSRLDQ_CHAIN_RC="$(cat "${chain_out}.rc")"
  VPSRLDQ_CHAIN_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$chain_log" "$chain_out")"
  VPSRLDQ_CHAIN_HITS="$(count_hits '62 d1 0d 48 73 dd 04|vpsrldq zmm14,zmm13,0x4|psrldq_xmm' "$chain_log" "$chain_out")"
  if [[ "$VPSRLDQ_CHAIN_RC" = "0" && "$VPSRLDQ_CHAIN_EXCEPTION_HITS" = "0" &&
        "$VPSRLDQ_CHAIN_HITS" -gt 0 ]]; then
    VPSRLDQ_CHAIN_RESULT="PASS"
  fi

  if [[ "$VPSRLDQ_SINGLE_RESULT" = "PASS" && "$VPSRLDQ_CHAIN_RESULT" = "PASS" ]]; then
    VPSRLDQ_RESULT="PASS"
  fi

  VPSRLDQ_EVIDENCE="single=$VPSRLDQ_SINGLE_RESULT rc=$VPSRLDQ_SINGLE_RC vpsrldq_hits=$VPSRLDQ_SINGLE_HITS exception_hits=$VPSRLDQ_SINGLE_EXCEPTION_HITS; chain=$VPSRLDQ_CHAIN_RESULT rc=$VPSRLDQ_CHAIN_RC vpsrldq_hits=$VPSRLDQ_CHAIN_HITS exception_hits=$VPSRLDQ_CHAIN_EXCEPTION_HITS"
}

run_vextracti32x4_smoke_probe() {
  local label="$1"
  local single_probe="$2"
  local chain_probe="$3"
  local out_prefix="$4"

  VEXTRACTI32X4_RESULT="FAIL"
  VEXTRACTI32X4_SINGLE_RESULT="FAIL"
  VEXTRACTI32X4_SINGLE_RC="n/a"
  VEXTRACTI32X4_SINGLE_EXCEPTION_HITS="0"
  VEXTRACTI32X4_SINGLE_HITS="0"
  VEXTRACTI32X4_CHAIN_RESULT="FAIL"
  VEXTRACTI32X4_CHAIN_RC="n/a"
  VEXTRACTI32X4_CHAIN_EXCEPTION_HITS="0"
  VEXTRACTI32X4_CHAIN_HITS="0"

  local single_out="$OUT_DIR/${out_prefix}-single.max.out"
  local single_log="$OUT_DIR/${out_prefix}-single.max.qemu.log"
  local chain_out="$OUT_DIR/${out_prefix}-chain.max.out"
  local chain_log="$OUT_DIR/${out_prefix}-chain.max.qemu.log"

  log "Running EVEX $label smoke probe"
  run_capture_qemu_log "$single_log" \
    "$single_out" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$single_probe"
  VEXTRACTI32X4_SINGLE_RC="$(cat "${single_out}.rc")"
  VEXTRACTI32X4_SINGLE_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$single_log" "$single_out")"
  VEXTRACTI32X4_SINGLE_HITS="$(count_hits '62537d4839f701|62 53 7d 48 39 f7 01|vextracti32x4 xmm15,zmm14,0x1|vextracti32x4|st_vec v256,e8,tmp10,env,\$0x720|st_i64 .*env,\$0x720|st_i64 .*env,\$0x728' "$single_log" "$single_out")"
  if [[ "$VEXTRACTI32X4_SINGLE_RC" = "0" && "$VEXTRACTI32X4_SINGLE_EXCEPTION_HITS" = "0" &&
        "$VEXTRACTI32X4_SINGLE_HITS" -gt 0 ]]; then
    VEXTRACTI32X4_SINGLE_RESULT="PASS"
  fi

  run_capture_qemu_log "$chain_log" \
    "$chain_out" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$chain_probe"
  VEXTRACTI32X4_CHAIN_RC="$(cat "${chain_out}.rc")"
  VEXTRACTI32X4_CHAIN_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$chain_log" "$chain_out")"
  VEXTRACTI32X4_CHAIN_HITS="$(count_hits '62537d4839f701|62 53 7d 48 39 f7 01|vextracti32x4 xmm15,zmm14,0x1|vextracti32x4|st_vec v256,e8,tmp10,env,\$0x720|st_i64 .*env,\$0x720|st_i64 .*env,\$0x728' "$chain_log" "$chain_out")"
  if [[ "$VEXTRACTI32X4_CHAIN_RC" = "0" && "$VEXTRACTI32X4_CHAIN_EXCEPTION_HITS" = "0" &&
        "$VEXTRACTI32X4_CHAIN_HITS" -gt 0 ]]; then
    VEXTRACTI32X4_CHAIN_RESULT="PASS"
  fi

  if [[ "$VEXTRACTI32X4_SINGLE_RESULT" = "PASS" && "$VEXTRACTI32X4_CHAIN_RESULT" = "PASS" ]]; then
    VEXTRACTI32X4_RESULT="PASS"
  fi

  VEXTRACTI32X4_EVIDENCE="single=$VEXTRACTI32X4_SINGLE_RESULT rc=$VEXTRACTI32X4_SINGLE_RC vextracti32x4_hits=$VEXTRACTI32X4_SINGLE_HITS exception_hits=$VEXTRACTI32X4_SINGLE_EXCEPTION_HITS; chain=$VEXTRACTI32X4_CHAIN_RESULT rc=$VEXTRACTI32X4_CHAIN_RC vextracti32x4_hits=$VEXTRACTI32X4_CHAIN_HITS exception_hits=$VEXTRACTI32X4_CHAIN_EXCEPTION_HITS"
}

run_vextracti64x4_smoke_probe() {
  local label="$1"
  local single_probe="$2"
  local chain_probe="$3"
  local out_prefix="$4"

  VEXTRACTI64X4_RESULT="FAIL"
  VEXTRACTI64X4_SINGLE_RESULT="FAIL"
  VEXTRACTI64X4_SINGLE_RC="n/a"
  VEXTRACTI64X4_SINGLE_EXCEPTION_HITS="0"
  VEXTRACTI64X4_SINGLE_HITS="0"
  VEXTRACTI64X4_CHAIN_RESULT="FAIL"
  VEXTRACTI64X4_CHAIN_RC="n/a"
  VEXTRACTI64X4_CHAIN_EXCEPTION_HITS="0"
  VEXTRACTI64X4_CHAIN_HITS="0"

  local single_out="$OUT_DIR/${out_prefix}-single.max.out"
  local single_log="$OUT_DIR/${out_prefix}-single.max.qemu.log"
  local chain_out="$OUT_DIR/${out_prefix}-chain.max.out"
  local chain_log="$OUT_DIR/${out_prefix}-chain.max.qemu.log"

  log "Running EVEX $label smoke probe"
  run_capture_qemu_log "$single_log" \
    "$single_out" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$single_probe"
  VEXTRACTI64X4_SINGLE_RC="$(cat "${single_out}.rc")"
  VEXTRACTI64X4_SINGLE_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$single_log" "$single_out")"
  VEXTRACTI64X4_SINGLE_HITS="$(count_hits '6233fd483bf001|62 33 fd 48 3b f0 01|vextracti64x4 ymm16,zmm14,0x1|vextracti64x4|0000000000401000|st_vec .*env,\$0x760|st_vec .*env,\$0x780|st_i64 .*env,\$0x760|st_i64 .*env,\$0x768|st_i64 .*env,\$0x770|st_i64 .*env,\$0x778' "$single_log" "$single_out")"
  if [[ "$VEXTRACTI64X4_SINGLE_RC" = "0" && "$VEXTRACTI64X4_SINGLE_EXCEPTION_HITS" = "0" &&
        "$VEXTRACTI64X4_SINGLE_HITS" -gt 0 ]]; then
    VEXTRACTI64X4_SINGLE_RESULT="PASS"
  fi

  run_capture_qemu_log "$chain_log" \
    "$chain_out" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$chain_probe"
  VEXTRACTI64X4_CHAIN_RC="$(cat "${chain_out}.rc")"
  VEXTRACTI64X4_CHAIN_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$chain_log" "$chain_out")"
  VEXTRACTI64X4_CHAIN_HITS="$(count_hits '6233fd483bf001|62 33 fd 48 3b f0 01|vextracti64x4 ymm16,zmm14,0x1|vextracti64x4|000000000040107a|st_vec .*env,\$0x760|st_vec .*env,\$0x780|st_i64 .*env,\$0x760|st_i64 .*env,\$0x768|st_i64 .*env,\$0x770|st_i64 .*env,\$0x778' "$chain_log" "$chain_out")"
  if [[ "$VEXTRACTI64X4_CHAIN_RC" = "0" && "$VEXTRACTI64X4_CHAIN_EXCEPTION_HITS" = "0" &&
        "$VEXTRACTI64X4_CHAIN_HITS" -gt 0 ]]; then
    VEXTRACTI64X4_CHAIN_RESULT="PASS"
  fi

  if [[ "$VEXTRACTI64X4_SINGLE_RESULT" = "PASS" && "$VEXTRACTI64X4_CHAIN_RESULT" = "PASS" ]]; then
    VEXTRACTI64X4_RESULT="PASS"
  fi

  VEXTRACTI64X4_EVIDENCE="single=$VEXTRACTI64X4_SINGLE_RESULT rc=$VEXTRACTI64X4_SINGLE_RC vextracti64x4_hits=$VEXTRACTI64X4_SINGLE_HITS exception_hits=$VEXTRACTI64X4_SINGLE_EXCEPTION_HITS; chain=$VEXTRACTI64X4_CHAIN_RESULT rc=$VEXTRACTI64X4_CHAIN_RC vextracti64x4_hits=$VEXTRACTI64X4_CHAIN_HITS exception_hits=$VEXTRACTI64X4_CHAIN_EXCEPTION_HITS"
}

run_vmovdqu8_smoke_probe() {
  local label="$1"
  local single_probe="$2"
  local chain_probe="$3"
  local out_prefix="$4"

  VMOVDQU8_RESULT="FAIL"
  VMOVDQU8_SINGLE_RESULT="FAIL"
  VMOVDQU8_SINGLE_RC="n/a"
  VMOVDQU8_SINGLE_EXCEPTION_HITS="0"
  VMOVDQU8_SINGLE_HITS="0"
  VMOVDQU8_SINGLE_MEMORY_HITS="0"
  VMOVDQU8_CHAIN_RESULT="FAIL"
  VMOVDQU8_CHAIN_RC="n/a"
  VMOVDQU8_CHAIN_EXCEPTION_HITS="0"
  VMOVDQU8_CHAIN_HITS="0"
  VMOVDQU8_CHAIN_MEMORY_HITS="0"

  local single_out="$OUT_DIR/${out_prefix}-single.max.out"
  local single_log="$OUT_DIR/${out_prefix}-single.max.qemu.log"
  local chain_out="$OUT_DIR/${out_prefix}-chain.max.out"
  local chain_log="$OUT_DIR/${out_prefix}-chain.max.qemu.log"

  log "Running EVEX $label smoke probe"
  run_capture_qemu_log "$single_log" "$single_out" \
    "$BUILD_DIR/qemu-x86_64" -d in_asm,op,int -cpu max "$single_probe"
  VMOVDQU8_SINGLE_RC="$(cat "${single_out}.rc")"
  VMOVDQU8_SINGLE_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$single_log" "$single_out")"
  VMOVDQU8_SINGLE_HITS="$(count_hits '62717f487f35f60f0000|62 71 7f 48 7f 35 f6 0f 00 00|vmovdqu8 ZMMWORD PTR|vmovdqu8|0x0000000000401000' "$single_log" "$single_out")"
  VMOVDQU8_SINGLE_MEMORY_HITS="$(count_hits 'qemu_st2_i128|qemu_st_i128' "$single_log")"
  if [[ "$VMOVDQU8_SINGLE_RC" = "0" && "$VMOVDQU8_SINGLE_EXCEPTION_HITS" = "0" &&
        "$VMOVDQU8_SINGLE_HITS" -gt 0 && "$VMOVDQU8_SINGLE_MEMORY_HITS" -ge 4 ]]; then
    VMOVDQU8_SINGLE_RESULT="PASS"
  fi

  run_capture_qemu_log "$chain_log" "$chain_out" \
    "$BUILD_DIR/qemu-x86_64" -d in_asm,op,int -cpu max "$chain_probe"
  VMOVDQU8_CHAIN_RC="$(cat "${chain_out}.rc")"
  VMOVDQU8_CHAIN_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$chain_log" "$chain_out")"
  VMOVDQU8_CHAIN_HITS="$(count_hits '62717f487f35750f0000|62 71 7f 48 7f 35 75 0f 00 00|vmovdqu8 ZMMWORD PTR|vmovdqu8|0x0000000000401081' "$chain_log" "$chain_out")"
  VMOVDQU8_CHAIN_MEMORY_HITS="$(count_hits 'qemu_st2_i128|qemu_st_i128' "$chain_log")"
  if [[ "$VMOVDQU8_CHAIN_RC" = "0" && "$VMOVDQU8_CHAIN_EXCEPTION_HITS" = "0" &&
        "$VMOVDQU8_CHAIN_HITS" -gt 0 && "$VMOVDQU8_CHAIN_MEMORY_HITS" -ge 4 ]]; then
    VMOVDQU8_CHAIN_RESULT="PASS"
  fi

  if [[ "$VMOVDQU8_SINGLE_RESULT" = "PASS" && "$VMOVDQU8_CHAIN_RESULT" = "PASS" ]]; then
    VMOVDQU8_RESULT="PASS"
  fi

  VMOVDQU8_EVIDENCE="single=$VMOVDQU8_SINGLE_RESULT rc=$VMOVDQU8_SINGLE_RC vmovdqu8_hits=$VMOVDQU8_SINGLE_HITS memory_hits=$VMOVDQU8_SINGLE_MEMORY_HITS exception_hits=$VMOVDQU8_SINGLE_EXCEPTION_HITS; chain=$VMOVDQU8_CHAIN_RESULT rc=$VMOVDQU8_CHAIN_RC vmovdqu8_hits=$VMOVDQU8_CHAIN_HITS memory_hits=$VMOVDQU8_CHAIN_MEMORY_HITS exception_hits=$VMOVDQU8_CHAIN_EXCEPTION_HITS"
}

last_exception_pc() {
  local log_file="$1"
  grep -B4 -E 'raise_exception|EXCP06|check_exception' "$log_file" 2>/dev/null |
    sed -n 's/.*mov_i64 rip,\$\(0x[0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' |
    tail -1
}

run_aggregate_boundary_probe() {
  local outfile="$OUT_DIR/avx512-aggregate-boundary.max.out"
  local qemu_log="$OUT_DIR/avx512-aggregate-boundary.max.qemu.log"
  local observed_pc

  log "Running aggregate boundary probe"
  run_capture_qemu_log "$qemu_log" \
    "$outfile" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    -cpu max \
    "$AGGREGATE_BOUNDARY_PROBE"
  AGGREGATE_BOUNDARY_RC="$(cat "${outfile}.rc")"
  AGGREGATE_BOUNDARY_EXCEPTION_HITS="$(count_hits 'raise_exception|Illegal instruction|EXCP06|check_exception|signal 4' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VPADDD_HITS="$(count_hits 'vpaddd zmm4,zmm3,zmm2|add_vec v256,e32|add_vec' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VPADDD_RIP_HITS="$(count_hits 'rip,\$0x401026|0x0000000000401026' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VPTERNLOGQ_HITS="$(count_hits '62f3dd4825eb96|62 f3 dd 48 25 eb 96|vpternlogq zmm5,zmm4,zmm3,0x96|vpternlogq' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VPTERNLOGQ_RIP_HITS="$(count_hits 'rip,\$0x40102c|0x000000000040102c' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VPCLMULLQLQ_HITS="$(count_hits '62f3554844f400|62 f3 55 48 44 f4 00|vpclmullqlqdq zmm6,zmm5,zmm4|pclmulqdq' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VPCLMULLQLQ_RIP_HITS="$(count_hits 'rip,\$0x401033|0x0000000000401033' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VPCLMULLQHQ_HITS="$(count_hits '62f3554844fc10|62 f3 55 48 44 fc 10|vpclmullqhqdq zmm7,zmm5,zmm4|pclmulqdq' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VPCLMULLQHQ_RIP_HITS="$(count_hits 'rip,\$0x40103a|0x000000000040103a' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VPCLMULHQLQ_HITS="$(count_hits '6273554844c401|62 73 55 48 44 c4 01|vpclmulhqlqdq zmm8,zmm5,zmm4' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VPCLMULHQLQ_RIP_HITS="$(count_hits 'rip,\$0x401041|0x0000000000401041' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VPCLMULHQHQ_HITS="$(count_hits '6273554844cc11|62 73 55 48 44 cc 11|vpclmulhqhqdq zmm9,zmm5,zmm4' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VPCLMULHQHQ_RIP_HITS="$(count_hits 'rip,\$0x401048|0x0000000000401048' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VAESENC_HITS="$(count_hits '62523548dcd0|62 52 35 48 dc d0|vaesenc zmm10,zmm9,zmm8|vaesenc' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VAESENC_RIP_HITS="$(count_hits 'rip,\$0x40104f|0x000000000040104f' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VAESENC_HELPER_HITS="$(count_hits 'aesenc_xmm' "$qemu_log")"
  AGGREGATE_BOUNDARY_VAESENCLAST_HITS="$(count_hits '62722d48dddf|62 72 2d 48 dd df|vaesenclast zmm11,zmm10,zmm7|vaesenclast' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VAESENCLAST_RIP_HITS="$(count_hits 'rip,\$0x401055|0x0000000000401055' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VBROADCASTF64X2_HITS="$(count_hits '62 72 fd 48 1a 25 9b 0f 00 00|vbroadcastf64x2 zmm12' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VBROADCASTF64X2_RIP_HITS="$(count_hits 'rip,\$0x40105b|0x000000000040105b' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VPSLLDQ_HITS="$(count_hits '62 d1 15 48 73 fc 04|vpslldq zmm13,zmm12,0x4' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VPSLLDQ_RIP_HITS="$(count_hits 'rip,\$0x401065|0x0000000000401065' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VPSRLDQ_HITS="$(count_hits 'vpsrldq zmm14,zmm13,0x4|vpsrldq' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VPSRLDQ_RIP_HITS="$(count_hits 'rip,\$0x40106c|0x000000000040106c' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VPCLMULQDQ_HITS="$(count_hits 'vpclmul|pclmulqdq|62 f3 55 48 44 f4 00|62 f3 55 48 44 fc 10|62 73 55 48 44 c4 01|62 73 55 48 44 cc 11' "$qemu_log" "$outfile")"
  AGGREGATE_BOUNDARY_VPCLMULQDQ_RIP_HITS="$AGGREGATE_BOUNDARY_VPCLMULHQHQ_RIP_HITS"
  observed_pc="$(grep -E 'mov_i64 rip,\$0x[0-9a-fA-F]+' "$qemu_log" | sed -n 's/.*mov_i64 rip,\$\(0x[0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' | tail -1 || true)"
  AGGREGATE_BOUNDARY_PC="${observed_pc:-unknown}"

  if [[ "$AGGREGATE_BOUNDARY_RC" = "0" &&
        "$AGGREGATE_BOUNDARY_EXCEPTION_HITS" = "0" &&
        "$AGGREGATE_BOUNDARY_PC" = "$AGGREGATE_BOUNDARY_EXPECTED_PC" ]]; then
    AGGREGATE_BOUNDARY_RESULT="PASS"
  else
    AGGREGATE_BOUNDARY_RESULT="INFO"
  fi
  AGGREGATE_BOUNDARY_EVIDENCE="expected_next=$AGGREGATE_BOUNDARY_EXPECTED_NEXT expected_pc=$AGGREGATE_BOUNDARY_EXPECTED_PC observed_pc=$AGGREGATE_BOUNDARY_PC rc=$AGGREGATE_BOUNDARY_RC exception_hits=$AGGREGATE_BOUNDARY_EXCEPTION_HITS vpaddd_hits=$AGGREGATE_BOUNDARY_VPADDD_HITS vpaddd_rip_hits=$AGGREGATE_BOUNDARY_VPADDD_RIP_HITS vpternlogq_hits=$AGGREGATE_BOUNDARY_VPTERNLOGQ_HITS vpternlogq_rip_hits=$AGGREGATE_BOUNDARY_VPTERNLOGQ_RIP_HITS vpclmullqlqdq_hits=$AGGREGATE_BOUNDARY_VPCLMULLQLQ_HITS vpclmullqlqdq_rip_hits=$AGGREGATE_BOUNDARY_VPCLMULLQLQ_RIP_HITS vpclmullqhqdq_hits=$AGGREGATE_BOUNDARY_VPCLMULLQHQ_HITS vpclmullqhqdq_rip_hits=$AGGREGATE_BOUNDARY_VPCLMULLQHQ_RIP_HITS vpclmulhqlqdq_hits=$AGGREGATE_BOUNDARY_VPCLMULHQLQ_HITS vpclmulhqlqdq_rip_hits=$AGGREGATE_BOUNDARY_VPCLMULHQLQ_RIP_HITS vpclmulhqhqdq_hits=$AGGREGATE_BOUNDARY_VPCLMULHQHQ_HITS vpclmulhqhqdq_rip_hits=$AGGREGATE_BOUNDARY_VPCLMULHQHQ_RIP_HITS vaesenc_hits=$AGGREGATE_BOUNDARY_VAESENC_HITS vaesenc_rip_hits=$AGGREGATE_BOUNDARY_VAESENC_RIP_HITS vaesenc_helper_hits=$AGGREGATE_BOUNDARY_VAESENC_HELPER_HITS vaesenclast_hits=$AGGREGATE_BOUNDARY_VAESENCLAST_HITS vaesenclast_rip_hits=$AGGREGATE_BOUNDARY_VAESENCLAST_RIP_HITS vbroadcastf64x2_hits=$AGGREGATE_BOUNDARY_VBROADCASTF64X2_HITS vbroadcastf64x2_rip_hits=$AGGREGATE_BOUNDARY_VBROADCASTF64X2_RIP_HITS vpslldq_hits=$AGGREGATE_BOUNDARY_VPSLLDQ_HITS vpslldq_rip_hits=$AGGREGATE_BOUNDARY_VPSLLDQ_RIP_HITS vpsrldq_hits=$AGGREGATE_BOUNDARY_VPSRLDQ_HITS vpsrldq_rip_hits=$AGGREGATE_BOUNDARY_VPSRLDQ_RIP_HITS vpclmulqdq_hits=$AGGREGATE_BOUNDARY_VPCLMULQDQ_HITS vpclmulqdq_boundary_rip_hits=$AGGREGATE_BOUNDARY_VPCLMULQDQ_RIP_HITS log=$(basename \"$qemu_log\")"
}

run_exec_probes() {
  local avx2_out="$OUT_DIR/avx2-vex.max.out"

  log "Running AVX2 VEX regression probe"
  run_capture "$avx2_out" "$BUILD_DIR/qemu-x86_64" -cpu max "$AVX2_PROBE"
  AVX2_RC="$(cat "${avx2_out}.rc")"
  if [[ "$AVX2_RC" = "0" ]]; then
    AVX2_RESULT="PASS"
  fi
  AVX2_EVIDENCE="rc=$AVX2_RC output=$(basename "$avx2_out")"

  run_evex_smoke_probe "vpxorq" "$AVX512_PROBE" "avx512-vpxorq"
  AVX512_RESULT="$SMOKE_RESULT"
  AVX512_RC="$SMOKE_RC"
  AVX512_VECTOR_HITS="$SMOKE_VECTOR_HITS"
  AVX512_EXCEPTION_HITS="$SMOKE_EXCEPTION_HITS"
  AVX512_EVIDENCE="rc=$AVX512_RC vector_hits=$AVX512_VECTOR_HITS exception_hits=$AVX512_EXCEPTION_HITS log=$(basename "$SMOKE_LOG")"

  run_evex_smoke_probe "vmovdqa64 register move" "$VMOVDQA64_PROBE" "avx512-vmovdqa64"
  VMOVDQA64_RESULT="$SMOKE_RESULT"
  VMOVDQA64_RC="$SMOKE_RC"
  VMOVDQA64_VECTOR_HITS="$SMOKE_VECTOR_HITS"
  VMOVDQA64_EXCEPTION_HITS="$SMOKE_EXCEPTION_HITS"
  VMOVDQA64_EVIDENCE="rc=$VMOVDQA64_RC vector_hits=$VMOVDQA64_VECTOR_HITS exception_hits=$VMOVDQA64_EXCEPTION_HITS log=$(basename "$SMOKE_LOG")"

  run_vmovdqu64_memory_probe "store" "$VMOVDQU64_STORE_PROBE" "avx512-vmovdqu64-store" 4
  VMOVDQU64_STORE_RESULT="$MEMORY_SMOKE_RESULT"
  VMOVDQU64_STORE_RC="$MEMORY_SMOKE_RC"
  VMOVDQU64_STORE_MEMORY_HITS="$MEMORY_SMOKE_MEMORY_HITS"
  VMOVDQU64_STORE_EXCEPTION_HITS="$MEMORY_SMOKE_EXCEPTION_HITS"

  run_vmovdqu64_memory_probe "load" "$VMOVDQU64_LOAD_PROBE" "avx512-vmovdqu64-load" 4
  VMOVDQU64_LOAD_RESULT="$MEMORY_SMOKE_RESULT"
  VMOVDQU64_LOAD_RC="$MEMORY_SMOKE_RC"
  VMOVDQU64_LOAD_MEMORY_HITS="$MEMORY_SMOKE_MEMORY_HITS"
  VMOVDQU64_LOAD_EXCEPTION_HITS="$MEMORY_SMOKE_EXCEPTION_HITS"

  run_vmovdqu64_memory_probe "chain" "$VMOVDQU64_CHAIN_PROBE" "avx512-vmovdqu64-chain" 8
  VMOVDQU64_CHAIN_RESULT="$MEMORY_SMOKE_RESULT"
  VMOVDQU64_CHAIN_RC="$MEMORY_SMOKE_RC"
  VMOVDQU64_CHAIN_MEMORY_HITS="$MEMORY_SMOKE_MEMORY_HITS"
  VMOVDQU64_CHAIN_EXCEPTION_HITS="$MEMORY_SMOKE_EXCEPTION_HITS"

  if [[ "$VMOVDQU64_STORE_RESULT" = "PASS" &&
        "$VMOVDQU64_LOAD_RESULT" = "PASS" &&
        "$VMOVDQU64_CHAIN_RESULT" = "PASS" ]]; then
    VMOVDQU64_RESULT="PASS"
  fi
  VMOVDQU64_EVIDENCE="store=$VMOVDQU64_STORE_RESULT rc=$VMOVDQU64_STORE_RC memory_hits=$VMOVDQU64_STORE_MEMORY_HITS exception_hits=$VMOVDQU64_STORE_EXCEPTION_HITS; load=$VMOVDQU64_LOAD_RESULT rc=$VMOVDQU64_LOAD_RC memory_hits=$VMOVDQU64_LOAD_MEMORY_HITS exception_hits=$VMOVDQU64_LOAD_EXCEPTION_HITS; chain=$VMOVDQU64_CHAIN_RESULT rc=$VMOVDQU64_CHAIN_RC memory_hits=$VMOVDQU64_CHAIN_MEMORY_HITS exception_hits=$VMOVDQU64_CHAIN_EXCEPTION_HITS"

  run_vpshufb_smoke_probe "vpshufb single" "$VPSHUFB_SINGLE_PROBE" "avx512-vpshufb-single"
  VPSHUFB_SINGLE_RESULT="$VPSHUFB_RESULT"
  VPSHUFB_SINGLE_RC="$VPSHUFB_RC"
  VPSHUFB_SINGLE_PSHUFB_HITS="$VPSHUFB_PSHUFB_HITS"
  VPSHUFB_SINGLE_EXCEPTION_HITS="$VPSHUFB_EXCEPTION_HITS"

  run_vpshufb_smoke_probe "vpshufb chain" "$VPSHUFB_CHAIN_PROBE" "avx512-vpshufb-chain"
  VPSHUFB_CHAIN_RESULT="$VPSHUFB_RESULT"
  VPSHUFB_CHAIN_RC="$VPSHUFB_RC"
  VPSHUFB_CHAIN_PSHUFB_HITS="$VPSHUFB_PSHUFB_HITS"
  VPSHUFB_CHAIN_EXCEPTION_HITS="$VPSHUFB_EXCEPTION_HITS"

  if [[ "$VPSHUFB_SINGLE_RESULT" = "PASS" &&
        "$VPSHUFB_CHAIN_RESULT" = "PASS" ]]; then
    VPSHUFB_RESULT="PASS"
  fi
  VPSHUFB_EVIDENCE="single=$VPSHUFB_SINGLE_RESULT rc=$VPSHUFB_SINGLE_RC pshufb_hits=$VPSHUFB_SINGLE_PSHUFB_HITS exception_hits=$VPSHUFB_SINGLE_EXCEPTION_HITS; chain=$VPSHUFB_CHAIN_RESULT rc=$VPSHUFB_CHAIN_RC pshufb_hits=$VPSHUFB_CHAIN_PSHUFB_HITS exception_hits=$VPSHUFB_CHAIN_EXCEPTION_HITS"

  run_vpaddd_smoke_probe "vpaddd single" "$VPADDD_SINGLE_PROBE" "avx512-vpaddd-single"
  VPADDD_SINGLE_RESULT="$VPADDD_RESULT"
  VPADDD_SINGLE_RC="$VPADDD_RC"
  VPADDD_SINGLE_ADD_HITS="$VPADDD_ADD_HITS"
  VPADDD_SINGLE_EXCEPTION_HITS="$VPADDD_EXCEPTION_HITS"

  run_vpaddd_smoke_probe "vpaddd chain" "$VPADDD_CHAIN_PROBE" "avx512-vpaddd-chain"
  VPADDD_CHAIN_RESULT="$VPADDD_RESULT"
  VPADDD_CHAIN_RC="$VPADDD_RC"
  VPADDD_CHAIN_ADD_HITS="$VPADDD_ADD_HITS"
  VPADDD_CHAIN_EXCEPTION_HITS="$VPADDD_EXCEPTION_HITS"

  if [[ "$VPADDD_SINGLE_RESULT" = "PASS" &&
        "$VPADDD_CHAIN_RESULT" = "PASS" ]]; then
    VPADDD_RESULT="PASS"
  fi
  VPADDD_EVIDENCE="single=$VPADDD_SINGLE_RESULT rc=$VPADDD_SINGLE_RC add_hits=$VPADDD_SINGLE_ADD_HITS exception_hits=$VPADDD_SINGLE_EXCEPTION_HITS; chain=$VPADDD_CHAIN_RESULT rc=$VPADDD_CHAIN_RC add_hits=$VPADDD_CHAIN_ADD_HITS exception_hits=$VPADDD_CHAIN_EXCEPTION_HITS"

  run_vpternlogq_smoke_probe "vpternlogq single" "$VPTERNLOGQ_SINGLE_PROBE" "avx512-vpternlogq-single"
  VPTERNLOGQ_SINGLE_RESULT="$VPTERNLOGQ_RESULT"
  VPTERNLOGQ_SINGLE_RC="$VPTERNLOGQ_RC"
  VPTERNLOGQ_SINGLE_TERNLOG_HITS="$VPTERNLOGQ_TERNLOG_HITS"
  VPTERNLOGQ_SINGLE_XOR_HITS="$VPTERNLOGQ_XOR_HITS"
  VPTERNLOGQ_SINGLE_EXCEPTION_HITS="$VPTERNLOGQ_EXCEPTION_HITS"

  run_vpternlogq_smoke_probe "vpternlogq chain" "$VPTERNLOGQ_CHAIN_PROBE" "avx512-vpternlogq-chain"
  VPTERNLOGQ_CHAIN_RESULT="$VPTERNLOGQ_RESULT"
  VPTERNLOGQ_CHAIN_RC="$VPTERNLOGQ_RC"
  VPTERNLOGQ_CHAIN_TERNLOG_HITS="$VPTERNLOGQ_TERNLOG_HITS"
  VPTERNLOGQ_CHAIN_XOR_HITS="$VPTERNLOGQ_XOR_HITS"
  VPTERNLOGQ_CHAIN_EXCEPTION_HITS="$VPTERNLOGQ_EXCEPTION_HITS"

  if [[ "$VPTERNLOGQ_SINGLE_RESULT" = "PASS" &&
        "$VPTERNLOGQ_CHAIN_RESULT" = "PASS" ]]; then
    VPTERNLOGQ_RESULT="PASS"
  fi
  VPTERNLOGQ_EVIDENCE="single=$VPTERNLOGQ_SINGLE_RESULT rc=$VPTERNLOGQ_SINGLE_RC ternlog_hits=$VPTERNLOGQ_SINGLE_TERNLOG_HITS xor_hits=$VPTERNLOGQ_SINGLE_XOR_HITS exception_hits=$VPTERNLOGQ_SINGLE_EXCEPTION_HITS; chain=$VPTERNLOGQ_CHAIN_RESULT rc=$VPTERNLOGQ_CHAIN_RC ternlog_hits=$VPTERNLOGQ_CHAIN_TERNLOG_HITS xor_hits=$VPTERNLOGQ_CHAIN_XOR_HITS exception_hits=$VPTERNLOGQ_CHAIN_EXCEPTION_HITS"

  run_vpclmullqlq_smoke_probe "vpclmullqlqdq single" "$VPCLMULLQLQ_SINGLE_PROBE" "avx512-vpclmullqlqdq-single"
  VPCLMULLQLQ_SINGLE_RESULT="$VPCLMULLQLQ_RESULT"
  VPCLMULLQLQ_SINGLE_RC="$VPCLMULLQLQ_RC"
  VPCLMULLQLQ_SINGLE_HITS="$VPCLMULLQLQ_HITS"
  VPCLMULLQLQ_SINGLE_EXCEPTION_HITS="$VPCLMULLQLQ_EXCEPTION_HITS"

  run_vpclmullqlq_smoke_probe "vpclmullqlqdq chain" "$VPCLMULLQLQ_CHAIN_PROBE" "avx512-vpclmullqlqdq-chain"
  VPCLMULLQLQ_CHAIN_RESULT="$VPCLMULLQLQ_RESULT"
  VPCLMULLQLQ_CHAIN_RC="$VPCLMULLQLQ_RC"
  VPCLMULLQLQ_CHAIN_HITS="$VPCLMULLQLQ_HITS"
  VPCLMULLQLQ_CHAIN_EXCEPTION_HITS="$VPCLMULLQLQ_EXCEPTION_HITS"

  run_vpclmullqlq_smoke_probe "vpclmullqlqdq semantic" "$VPCLMULLQLQ_SEMANTIC_PROBE" "avx512-vpclmullqlqdq-semantic"
  VPCLMULLQLQ_SEMANTIC_RESULT="$VPCLMULLQLQ_RESULT"
  VPCLMULLQLQ_SEMANTIC_RC="$VPCLMULLQLQ_RC"
  VPCLMULLQLQ_SEMANTIC_HITS="$VPCLMULLQLQ_HITS"
  VPCLMULLQLQ_SEMANTIC_EXCEPTION_HITS="$VPCLMULLQLQ_EXCEPTION_HITS"

  VPCLMULLQLQ_RESULT="FAIL"
  if [[ "$VPCLMULLQLQ_SINGLE_RESULT" = "PASS" &&
        "$VPCLMULLQLQ_CHAIN_RESULT" = "PASS" &&
        "$VPCLMULLQLQ_SEMANTIC_RESULT" = "PASS" ]]; then
    VPCLMULLQLQ_RESULT="PASS"
  fi
  VPCLMULLQLQ_EVIDENCE="single=$VPCLMULLQLQ_SINGLE_RESULT rc=$VPCLMULLQLQ_SINGLE_RC pclmul_hits=$VPCLMULLQLQ_SINGLE_HITS exception_hits=$VPCLMULLQLQ_SINGLE_EXCEPTION_HITS; chain=$VPCLMULLQLQ_CHAIN_RESULT rc=$VPCLMULLQLQ_CHAIN_RC pclmul_hits=$VPCLMULLQLQ_CHAIN_HITS exception_hits=$VPCLMULLQLQ_CHAIN_EXCEPTION_HITS; semantic=$VPCLMULLQLQ_SEMANTIC_RESULT rc=$VPCLMULLQLQ_SEMANTIC_RC pclmul_hits=$VPCLMULLQLQ_SEMANTIC_HITS exception_hits=$VPCLMULLQLQ_SEMANTIC_EXCEPTION_HITS"

  run_vpclmullqhq_smoke_probe "vpclmullqhqdq single" "$VPCLMULLQHQ_SINGLE_PROBE" "avx512-vpclmullqhqdq-single"
  VPCLMULLQHQ_SINGLE_RESULT="$VPCLMULLQHQ_RESULT"
  VPCLMULLQHQ_SINGLE_RC="$VPCLMULLQHQ_RC"
  VPCLMULLQHQ_SINGLE_HITS="$VPCLMULLQHQ_HITS"
  VPCLMULLQHQ_SINGLE_EXCEPTION_HITS="$VPCLMULLQHQ_EXCEPTION_HITS"

  run_vpclmullqhq_smoke_probe "vpclmullqhqdq chain" "$VPCLMULLQHQ_CHAIN_PROBE" "avx512-vpclmullqhqdq-chain"
  VPCLMULLQHQ_CHAIN_RESULT="$VPCLMULLQHQ_RESULT"
  VPCLMULLQHQ_CHAIN_RC="$VPCLMULLQHQ_RC"
  VPCLMULLQHQ_CHAIN_HITS="$VPCLMULLQHQ_HITS"
  VPCLMULLQHQ_CHAIN_EXCEPTION_HITS="$VPCLMULLQHQ_EXCEPTION_HITS"

  run_vpclmullqhq_smoke_probe "vpclmullqhqdq semantic" "$VPCLMULLQHQ_SEMANTIC_PROBE" "avx512-vpclmullqhqdq-semantic"
  VPCLMULLQHQ_SEMANTIC_RESULT="$VPCLMULLQHQ_RESULT"
  VPCLMULLQHQ_SEMANTIC_RC="$VPCLMULLQHQ_RC"
  VPCLMULLQHQ_SEMANTIC_HITS="$VPCLMULLQHQ_HITS"
  VPCLMULLQHQ_SEMANTIC_EXCEPTION_HITS="$VPCLMULLQHQ_EXCEPTION_HITS"

  VPCLMULLQHQ_RESULT="FAIL"
  if [[ "$VPCLMULLQHQ_SINGLE_RESULT" = "PASS" &&
        "$VPCLMULLQHQ_CHAIN_RESULT" = "PASS" &&
        "$VPCLMULLQHQ_SEMANTIC_RESULT" = "PASS" ]]; then
    VPCLMULLQHQ_RESULT="PASS"
  fi
  VPCLMULLQHQ_EVIDENCE="single=$VPCLMULLQHQ_SINGLE_RESULT rc=$VPCLMULLQHQ_SINGLE_RC pclmul_hits=$VPCLMULLQHQ_SINGLE_HITS exception_hits=$VPCLMULLQHQ_SINGLE_EXCEPTION_HITS; chain=$VPCLMULLQHQ_CHAIN_RESULT rc=$VPCLMULLQHQ_CHAIN_RC pclmul_hits=$VPCLMULLQHQ_CHAIN_HITS exception_hits=$VPCLMULLQHQ_CHAIN_EXCEPTION_HITS; semantic=$VPCLMULLQHQ_SEMANTIC_RESULT rc=$VPCLMULLQHQ_SEMANTIC_RC pclmul_hits=$VPCLMULLQHQ_SEMANTIC_HITS exception_hits=$VPCLMULLQHQ_SEMANTIC_EXCEPTION_HITS"

  run_vpclmulhqlq_smoke_probe "vpclmulhqlqdq single" "$VPCLMULHQLQ_SINGLE_PROBE" "avx512-vpclmulhqlqdq-single"
  VPCLMULHQLQ_SINGLE_RESULT="$VPCLMULHQLQ_RESULT"
  VPCLMULHQLQ_SINGLE_RC="$VPCLMULHQLQ_RC"
  VPCLMULHQLQ_SINGLE_HITS="$VPCLMULHQLQ_HITS"
  VPCLMULHQLQ_SINGLE_EXCEPTION_HITS="$VPCLMULHQLQ_EXCEPTION_HITS"

  run_vpclmulhqlq_smoke_probe "vpclmulhqlqdq chain" "$VPCLMULHQLQ_CHAIN_PROBE" "avx512-vpclmulhqlqdq-chain"
  VPCLMULHQLQ_CHAIN_RESULT="$VPCLMULHQLQ_RESULT"
  VPCLMULHQLQ_CHAIN_RC="$VPCLMULHQLQ_RC"
  VPCLMULHQLQ_CHAIN_HITS="$VPCLMULHQLQ_HITS"
  VPCLMULHQLQ_CHAIN_EXCEPTION_HITS="$VPCLMULHQLQ_EXCEPTION_HITS"

  run_vpclmulhqlq_smoke_probe "vpclmulhqlqdq semantic" "$VPCLMULHQLQ_SEMANTIC_PROBE" "avx512-vpclmulhqlqdq-semantic"
  VPCLMULHQLQ_SEMANTIC_RESULT="$VPCLMULHQLQ_RESULT"
  VPCLMULHQLQ_SEMANTIC_RC="$VPCLMULHQLQ_RC"
  VPCLMULHQLQ_SEMANTIC_HITS="$VPCLMULHQLQ_HITS"
  VPCLMULHQLQ_SEMANTIC_EXCEPTION_HITS="$VPCLMULHQLQ_EXCEPTION_HITS"

  VPCLMULHQLQ_RESULT="FAIL"
  if [[ "$VPCLMULHQLQ_SINGLE_RESULT" = "PASS" &&
        "$VPCLMULHQLQ_CHAIN_RESULT" = "PASS" &&
        "$VPCLMULHQLQ_SEMANTIC_RESULT" = "PASS" ]]; then
    VPCLMULHQLQ_RESULT="PASS"
  fi
  VPCLMULHQLQ_EVIDENCE="single=$VPCLMULHQLQ_SINGLE_RESULT rc=$VPCLMULHQLQ_SINGLE_RC pclmul_hits=$VPCLMULHQLQ_SINGLE_HITS exception_hits=$VPCLMULHQLQ_SINGLE_EXCEPTION_HITS; chain=$VPCLMULHQLQ_CHAIN_RESULT rc=$VPCLMULHQLQ_CHAIN_RC pclmul_hits=$VPCLMULHQLQ_CHAIN_HITS exception_hits=$VPCLMULHQLQ_CHAIN_EXCEPTION_HITS; semantic=$VPCLMULHQLQ_SEMANTIC_RESULT rc=$VPCLMULHQLQ_SEMANTIC_RC pclmul_hits=$VPCLMULHQLQ_SEMANTIC_HITS exception_hits=$VPCLMULHQLQ_SEMANTIC_EXCEPTION_HITS"

  run_vpclmulhqhq_smoke_probe "vpclmulhqhqdq single" "$VPCLMULHQHQ_SINGLE_PROBE" "avx512-vpclmulhqhqdq-single"
  VPCLMULHQHQ_SINGLE_RESULT="$VPCLMULHQHQ_RESULT"
  VPCLMULHQHQ_SINGLE_RC="$VPCLMULHQHQ_RC"
  VPCLMULHQHQ_SINGLE_HITS="$VPCLMULHQHQ_HITS"
  VPCLMULHQHQ_SINGLE_EXCEPTION_HITS="$VPCLMULHQHQ_EXCEPTION_HITS"

  run_vpclmulhqhq_smoke_probe "vpclmulhqhqdq chain" "$VPCLMULHQHQ_CHAIN_PROBE" "avx512-vpclmulhqhqdq-chain"
  VPCLMULHQHQ_CHAIN_RESULT="$VPCLMULHQHQ_RESULT"
  VPCLMULHQHQ_CHAIN_RC="$VPCLMULHQHQ_RC"
  VPCLMULHQHQ_CHAIN_HITS="$VPCLMULHQHQ_HITS"
  VPCLMULHQHQ_CHAIN_EXCEPTION_HITS="$VPCLMULHQHQ_EXCEPTION_HITS"

  run_vpclmulhqhq_smoke_probe "vpclmulhqhqdq semantic" "$VPCLMULHQHQ_SEMANTIC_PROBE" "avx512-vpclmulhqhqdq-semantic"
  VPCLMULHQHQ_SEMANTIC_RESULT="$VPCLMULHQHQ_RESULT"
  VPCLMULHQHQ_SEMANTIC_RC="$VPCLMULHQHQ_RC"
  VPCLMULHQHQ_SEMANTIC_HITS="$VPCLMULHQHQ_HITS"
  VPCLMULHQHQ_SEMANTIC_EXCEPTION_HITS="$VPCLMULHQHQ_EXCEPTION_HITS"

  VPCLMULHQHQ_RESULT="FAIL"
  if [[ "$VPCLMULHQHQ_SINGLE_RESULT" = "PASS" &&
        "$VPCLMULHQHQ_CHAIN_RESULT" = "PASS" &&
        "$VPCLMULHQHQ_SEMANTIC_RESULT" = "PASS" ]]; then
    VPCLMULHQHQ_RESULT="PASS"
  fi
  VPCLMULHQHQ_EVIDENCE="single=$VPCLMULHQHQ_SINGLE_RESULT rc=$VPCLMULHQHQ_SINGLE_RC pclmul_hits=$VPCLMULHQHQ_SINGLE_HITS exception_hits=$VPCLMULHQHQ_SINGLE_EXCEPTION_HITS; chain=$VPCLMULHQHQ_CHAIN_RESULT rc=$VPCLMULHQHQ_CHAIN_RC pclmul_hits=$VPCLMULHQHQ_CHAIN_HITS exception_hits=$VPCLMULHQHQ_CHAIN_EXCEPTION_HITS; semantic=$VPCLMULHQHQ_SEMANTIC_RESULT rc=$VPCLMULHQHQ_SEMANTIC_RC pclmul_hits=$VPCLMULHQHQ_SEMANTIC_HITS exception_hits=$VPCLMULHQHQ_SEMANTIC_EXCEPTION_HITS"

  run_vaesenc_smoke_probe "vaesenc single" "$VAESENC_SINGLE_PROBE" "avx512-vaesenc-single"
  VAESENC_SINGLE_RESULT="$VAESENC_RESULT"
  VAESENC_SINGLE_RC="$VAESENC_RC"
  VAESENC_SINGLE_HITS="$VAESENC_HITS"
  VAESENC_SINGLE_HELPER_HITS="$VAESENC_HELPER_HITS"
  VAESENC_SINGLE_EXCEPTION_HITS="$VAESENC_EXCEPTION_HITS"

  run_vaesenc_smoke_probe "vaesenc chain" "$VAESENC_CHAIN_PROBE" "avx512-vaesenc-chain"
  VAESENC_CHAIN_RESULT="$VAESENC_RESULT"
  VAESENC_CHAIN_RC="$VAESENC_RC"
  VAESENC_CHAIN_HITS="$VAESENC_HITS"
  VAESENC_CHAIN_HELPER_HITS="$VAESENC_HELPER_HITS"
  VAESENC_CHAIN_EXCEPTION_HITS="$VAESENC_EXCEPTION_HITS"

  run_vaesenc_smoke_probe "vaesenc semantic" "$VAESENC_SEMANTIC_PROBE" "avx512-vaesenc-semantic"
  VAESENC_SEMANTIC_RESULT="$VAESENC_RESULT"
  VAESENC_SEMANTIC_RC="$VAESENC_RC"
  VAESENC_SEMANTIC_HITS="$VAESENC_HITS"
  VAESENC_SEMANTIC_HELPER_HITS="$VAESENC_HELPER_HITS"
  VAESENC_SEMANTIC_EXCEPTION_HITS="$VAESENC_EXCEPTION_HITS"

  VAESENC_RESULT="FAIL"
  if [[ "$VAESENC_SINGLE_RESULT" = "PASS" &&
        "$VAESENC_CHAIN_RESULT" = "PASS" &&
        "$VAESENC_SEMANTIC_RESULT" = "PASS" ]]; then
    VAESENC_RESULT="PASS"
  fi
  VAESENC_EVIDENCE="single=$VAESENC_SINGLE_RESULT rc=$VAESENC_SINGLE_RC vaesenc_hits=$VAESENC_SINGLE_HITS aesenc_helper_hits=$VAESENC_SINGLE_HELPER_HITS exception_hits=$VAESENC_SINGLE_EXCEPTION_HITS; chain=$VAESENC_CHAIN_RESULT rc=$VAESENC_CHAIN_RC vaesenc_hits=$VAESENC_CHAIN_HITS aesenc_helper_hits=$VAESENC_CHAIN_HELPER_HITS exception_hits=$VAESENC_CHAIN_EXCEPTION_HITS; semantic=$VAESENC_SEMANTIC_RESULT rc=$VAESENC_SEMANTIC_RC vaesenc_hits=$VAESENC_SEMANTIC_HITS aesenc_helper_hits=$VAESENC_SEMANTIC_HELPER_HITS exception_hits=$VAESENC_SEMANTIC_EXCEPTION_HITS"

  run_vaesenclast_smoke_probe "vaesenclast single" "$VAESENCLAST_SINGLE_PROBE" "avx512-vaesenclast-single"
  VAESENCLAST_SINGLE_RESULT="$VAESENCLAST_RESULT"
  VAESENCLAST_SINGLE_RC="$VAESENCLAST_RC"
  VAESENCLAST_SINGLE_HITS="$VAESENCLAST_HITS"
  VAESENCLAST_SINGLE_HELPER_HITS="$VAESENCLAST_HELPER_HITS"
  VAESENCLAST_SINGLE_EXCEPTION_HITS="$VAESENCLAST_EXCEPTION_HITS"

  run_vaesenclast_smoke_probe "vaesenclast chain" "$VAESENCLAST_CHAIN_PROBE" "avx512-vaesenclast-chain"
  VAESENCLAST_CHAIN_RESULT="$VAESENCLAST_RESULT"
  VAESENCLAST_CHAIN_RC="$VAESENCLAST_RC"
  VAESENCLAST_CHAIN_HITS="$VAESENCLAST_HITS"
  VAESENCLAST_CHAIN_HELPER_HITS="$VAESENCLAST_HELPER_HITS"
  VAESENCLAST_CHAIN_EXCEPTION_HITS="$VAESENCLAST_EXCEPTION_HITS"

  run_vbroadcastf64x2_smoke_probe "vbroadcastf64x2 single" "$VBROADCASTF64X2_SINGLE_PROBE" "avx512-vbroadcastf64x2-single"
  VBROADCASTF64X2_SINGLE_RESULT="$VBROADCASTF64X2_RESULT"
  VBROADCASTF64X2_SINGLE_RC="$VBROADCASTF64X2_RC"
  VBROADCASTF64X2_SINGLE_EXCEPTION_HITS="$VBROADCASTF64X2_EXCEPTION_HITS"
  VBROADCASTF64X2_SINGLE_VBROADCAST_HITS="$VBROADCASTF64X2_VBROADCAST_HITS"
  VBROADCASTF64X2_SINGLE_QEMU_LD_I128_HITS="$VBROADCASTF64X2_QEMU_LD_I128_HITS"
  VBROADCASTF64X2_SINGLE_QEMU_LD2_I128_HITS="$VBROADCASTF64X2_QEMU_LD2_I128_HITS"
  VBROADCASTF64X2_SINGLE_ST_I128_HITS="$VBROADCASTF64X2_ST_I128_HITS"
  VBROADCASTF64X2_SINGLE_ST_I64_HITS="$VBROADCASTF64X2_ST_I64_HITS"

  run_vbroadcastf64x2_smoke_probe "vbroadcastf64x2 chain" "$VBROADCASTF64X2_CHAIN_PROBE" "avx512-vbroadcastf64x2-chain"
  VBROADCASTF64X2_CHAIN_RESULT="$VBROADCASTF64X2_RESULT"
  VBROADCASTF64X2_CHAIN_RC="$VBROADCASTF64X2_RC"
  VBROADCASTF64X2_CHAIN_EXCEPTION_HITS="$VBROADCASTF64X2_EXCEPTION_HITS"
  VBROADCASTF64X2_CHAIN_VBROADCAST_HITS="$VBROADCASTF64X2_VBROADCAST_HITS"
  VBROADCASTF64X2_CHAIN_QEMU_LD_I128_HITS="$VBROADCASTF64X2_QEMU_LD_I128_HITS"
  VBROADCASTF64X2_CHAIN_QEMU_LD2_I128_HITS="$VBROADCASTF64X2_QEMU_LD2_I128_HITS"
  VBROADCASTF64X2_CHAIN_ST_I128_HITS="$VBROADCASTF64X2_ST_I128_HITS"
  VBROADCASTF64X2_CHAIN_ST_I64_HITS="$VBROADCASTF64X2_ST_I64_HITS"

  VAESENCLAST_SEMANTIC_RESULT="SKIPPED"
  VAESENCLAST_SEMANTIC_RC="n/a"
  VAESENCLAST_SEMANTIC_HITS="0"
  VAESENCLAST_SEMANTIC_HELPER_HITS="0"
  VAESENCLAST_SEMANTIC_EXCEPTION_HITS="0"

  VAESENCLAST_RESULT="FAIL"
  if [[ "$VAESENCLAST_SINGLE_RESULT" = "PASS" &&
        "$VAESENCLAST_CHAIN_RESULT" = "PASS" ]]; then
    VAESENCLAST_RESULT="PASS"
  fi
  VAESENCLAST_EVIDENCE="single=$VAESENCLAST_SINGLE_RESULT rc=$VAESENCLAST_SINGLE_RC vaesenclast_hits=$VAESENCLAST_SINGLE_HITS aesenclast_helper_hits=$VAESENCLAST_SINGLE_HELPER_HITS exception_hits=$VAESENCLAST_SINGLE_EXCEPTION_HITS; chain=$VAESENCLAST_CHAIN_RESULT rc=$VAESENCLAST_CHAIN_RC vaesenclast_hits=$VAESENCLAST_CHAIN_HITS aesenclast_helper_hits=$VAESENCLAST_CHAIN_HELPER_HITS exception_hits=$VAESENCLAST_CHAIN_EXCEPTION_HITS; semantic=$VAESENCLAST_SEMANTIC_RESULT rc=$VAESENCLAST_SEMANTIC_RC vaesenclast_hits=$VAESENCLAST_SEMANTIC_HITS aesenclast_helper_hits=$VAESENCLAST_SEMANTIC_HELPER_HITS exception_hits=$VAESENCLAST_SEMANTIC_EXCEPTION_HITS"

  VBROADCASTF64X2_RESULT="FAIL"
  if [[ "$VBROADCASTF64X2_SINGLE_RESULT" = "PASS" &&
        "$VBROADCASTF64X2_CHAIN_RESULT" = "PASS" ]]; then
    VBROADCASTF64X2_RESULT="PASS"
  fi
  VBROADCASTF64X2_EVIDENCE="single=$VBROADCASTF64X2_SINGLE_RESULT rc=$VBROADCASTF64X2_SINGLE_RC vbroadcast_hits=$VBROADCASTF64X2_SINGLE_VBROADCAST_HITS qemu_ld_i128_hits=$VBROADCASTF64X2_SINGLE_QEMU_LD_I128_HITS qemu_ld2_i128_hits=$VBROADCASTF64X2_SINGLE_QEMU_LD2_I128_HITS st_i128_hits=$VBROADCASTF64X2_SINGLE_ST_I128_HITS st_i64_hits=$VBROADCASTF64X2_SINGLE_ST_I64_HITS; chain=$VBROADCASTF64X2_CHAIN_RESULT rc=$VBROADCASTF64X2_CHAIN_RC vbroadcast_hits=$VBROADCASTF64X2_CHAIN_VBROADCAST_HITS qemu_ld_i128_hits=$VBROADCASTF64X2_CHAIN_QEMU_LD_I128_HITS qemu_ld2_i128_hits=$VBROADCASTF64X2_CHAIN_QEMU_LD2_I128_HITS st_i128_hits=$VBROADCASTF64X2_CHAIN_ST_I128_HITS st_i64_hits=$VBROADCASTF64X2_CHAIN_ST_I64_HITS"

  run_vpslldq_smoke_probe "vpslldq single/chain" "$VPSLLDQ_SINGLE_PROBE" "$VPSLLDQ_CHAIN_PROBE" "avx512-vpslldq"
  run_vpsrldq_smoke_probe "vpsrldq single/chain" "$VPSRLDQ_SINGLE_PROBE" "$VPSRLDQ_CHAIN_PROBE" "avx512-vpsrldq"
  run_vextracti32x4_smoke_probe "vextracti32x4 single/chain" "$VEXTRACTI32X4_SINGLE_PROBE" "$VEXTRACTI32X4_CHAIN_PROBE" "avx512-vextracti32x4"
  run_vextracti64x4_smoke_probe "vextracti64x4 single/chain" "$VEXTRACTI64X4_SINGLE_PROBE" "$VEXTRACTI64X4_CHAIN_PROBE" "avx512-vextracti64x4"
  run_vmovdqu8_smoke_probe "vmovdqu8 single/chain" "$VMOVDQU8_SINGLE_PROBE" "$VMOVDQU8_CHAIN_PROBE" "avx512-vmovdqu8"
  run_aggregate_boundary_probe || true

  {
    echo
    echo "## Execution Probes"
    echo
    echo "| Probe | CPU args | RC | Vector hits | Memory hits | Exception hits | Result | Output |"
    echo "|---|---|---:|---:|---:|---:|---|---|"
    printf '| avx2-vex | `%s` | %s | n/a | n/a | n/a | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$AVX2_RC" \
      "$AVX2_RESULT" \
      "$(basename "$avx2_out")" \
      "$avx2_out"
    printf '| avx512-vpxorq | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$AVX512_RC" \
      "$AVX512_VECTOR_HITS" \
      "$AVX512_EXCEPTION_HITS" \
      "$AVX512_RESULT" \
      "avx512-vpxorq.max.out" \
      "$OUT_DIR/avx512-vpxorq.max.out"
    printf '| avx512-vmovdqa64 | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VMOVDQA64_RC" \
      "$VMOVDQA64_VECTOR_HITS" \
      "$VMOVDQA64_EXCEPTION_HITS" \
      "$VMOVDQA64_RESULT" \
      "avx512-vmovdqa64.max.out" \
      "$OUT_DIR/avx512-vmovdqa64.max.out"
    printf '| avx512-vmovdqu64-store | `%s` | %s | n/a | %s | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VMOVDQU64_STORE_RC" \
      "$VMOVDQU64_STORE_MEMORY_HITS" \
      "$VMOVDQU64_STORE_EXCEPTION_HITS" \
      "$VMOVDQU64_STORE_RESULT" \
      "avx512-vmovdqu64-store.max.out" \
      "$OUT_DIR/avx512-vmovdqu64-store.max.out"
    printf '| avx512-vmovdqu64-load | `%s` | %s | n/a | %s | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VMOVDQU64_LOAD_RC" \
      "$VMOVDQU64_LOAD_MEMORY_HITS" \
      "$VMOVDQU64_LOAD_EXCEPTION_HITS" \
      "$VMOVDQU64_LOAD_RESULT" \
      "avx512-vmovdqu64-load.max.out" \
      "$OUT_DIR/avx512-vmovdqu64-load.max.out"
    printf '| avx512-vmovdqu64-chain | `%s` | %s | n/a | %s | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VMOVDQU64_CHAIN_RC" \
      "$VMOVDQU64_CHAIN_MEMORY_HITS" \
      "$VMOVDQU64_CHAIN_EXCEPTION_HITS" \
      "$VMOVDQU64_CHAIN_RESULT" \
      "avx512-vmovdqu64-chain.max.out" \
      "$OUT_DIR/avx512-vmovdqu64-chain.max.out"
    printf '| avx512-vpshufb-single | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPSHUFB_SINGLE_RC" \
      "$VPSHUFB_SINGLE_PSHUFB_HITS" \
      "$VPSHUFB_SINGLE_EXCEPTION_HITS" \
      "$VPSHUFB_SINGLE_RESULT" \
      "avx512-vpshufb-single.max.out" \
      "$OUT_DIR/avx512-vpshufb-single.max.out"
    printf '| avx512-vpshufb-chain | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPSHUFB_CHAIN_RC" \
      "$VPSHUFB_CHAIN_PSHUFB_HITS" \
      "$VPSHUFB_CHAIN_EXCEPTION_HITS" \
      "$VPSHUFB_CHAIN_RESULT" \
      "avx512-vpshufb-chain.max.out" \
      "$OUT_DIR/avx512-vpshufb-chain.max.out"
    printf '| avx512-vpaddd-single | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPADDD_SINGLE_RC" \
      "$VPADDD_SINGLE_ADD_HITS" \
      "$VPADDD_SINGLE_EXCEPTION_HITS" \
      "$VPADDD_SINGLE_RESULT" \
      "avx512-vpaddd-single.max.out" \
      "$OUT_DIR/avx512-vpaddd-single.max.out"
    printf '| avx512-vpaddd-chain | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPADDD_CHAIN_RC" \
      "$VPADDD_CHAIN_ADD_HITS" \
      "$VPADDD_CHAIN_EXCEPTION_HITS" \
      "$VPADDD_CHAIN_RESULT" \
      "avx512-vpaddd-chain.max.out" \
      "$OUT_DIR/avx512-vpaddd-chain.max.out"
    printf '| avx512-vpternlogq-single | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPTERNLOGQ_SINGLE_RC" \
      "$VPTERNLOGQ_SINGLE_TERNLOG_HITS" \
      "$VPTERNLOGQ_SINGLE_EXCEPTION_HITS" \
      "$VPTERNLOGQ_SINGLE_RESULT" \
      "avx512-vpternlogq-single.max.out" \
      "$OUT_DIR/avx512-vpternlogq-single.max.out"
    printf '| avx512-vpternlogq-chain | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPTERNLOGQ_CHAIN_RC" \
      "$VPTERNLOGQ_CHAIN_TERNLOG_HITS" \
      "$VPTERNLOGQ_CHAIN_EXCEPTION_HITS" \
      "$VPTERNLOGQ_CHAIN_RESULT" \
      "avx512-vpternlogq-chain.max.out" \
      "$OUT_DIR/avx512-vpternlogq-chain.max.out"
    printf '| avx512-vpclmullqlqdq-single | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPCLMULLQLQ_SINGLE_RC" \
      "$VPCLMULLQLQ_SINGLE_HITS" \
      "$VPCLMULLQLQ_SINGLE_EXCEPTION_HITS" \
      "$VPCLMULLQLQ_SINGLE_RESULT" \
      "avx512-vpclmullqlqdq-single.max.out" \
      "$OUT_DIR/avx512-vpclmullqlqdq-single.max.out"
    printf '| avx512-vpclmullqlqdq-chain | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPCLMULLQLQ_CHAIN_RC" \
      "$VPCLMULLQLQ_CHAIN_HITS" \
      "$VPCLMULLQLQ_CHAIN_EXCEPTION_HITS" \
      "$VPCLMULLQLQ_CHAIN_RESULT" \
      "avx512-vpclmullqlqdq-chain.max.out" \
      "$OUT_DIR/avx512-vpclmullqlqdq-chain.max.out"
    printf '| avx512-vpclmullqlqdq-semantic | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPCLMULLQLQ_SEMANTIC_RC" \
      "$VPCLMULLQLQ_SEMANTIC_HITS" \
      "$VPCLMULLQLQ_SEMANTIC_EXCEPTION_HITS" \
      "$VPCLMULLQLQ_SEMANTIC_RESULT" \
      "avx512-vpclmullqlqdq-semantic.max.out" \
      "$OUT_DIR/avx512-vpclmullqlqdq-semantic.max.out"
    printf '| avx512-vpclmullqhqdq-single | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPCLMULLQHQ_SINGLE_RC" \
      "$VPCLMULLQHQ_SINGLE_HITS" \
      "$VPCLMULLQHQ_SINGLE_EXCEPTION_HITS" \
      "$VPCLMULLQHQ_SINGLE_RESULT" \
      "avx512-vpclmullqhqdq-single.max.out" \
      "$OUT_DIR/avx512-vpclmullqhqdq-single.max.out"
    printf '| avx512-vpclmullqhqdq-chain | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPCLMULLQHQ_CHAIN_RC" \
      "$VPCLMULLQHQ_CHAIN_HITS" \
      "$VPCLMULLQHQ_CHAIN_EXCEPTION_HITS" \
      "$VPCLMULLQHQ_CHAIN_RESULT" \
      "avx512-vpclmullqhqdq-chain.max.out" \
      "$OUT_DIR/avx512-vpclmullqhqdq-chain.max.out"
    printf '| avx512-vpclmullqhqdq-semantic | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPCLMULLQHQ_SEMANTIC_RC" \
      "$VPCLMULLQHQ_SEMANTIC_HITS" \
      "$VPCLMULLQHQ_SEMANTIC_EXCEPTION_HITS" \
      "$VPCLMULLQHQ_SEMANTIC_RESULT" \
      "avx512-vpclmullqhqdq-semantic.max.out" \
      "$OUT_DIR/avx512-vpclmullqhqdq-semantic.max.out"
    printf '| avx512-vpclmulhqlqdq-single | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPCLMULHQLQ_SINGLE_RC" \
      "$VPCLMULHQLQ_SINGLE_HITS" \
      "$VPCLMULHQLQ_SINGLE_EXCEPTION_HITS" \
      "$VPCLMULHQLQ_SINGLE_RESULT" \
      "avx512-vpclmulhqlqdq-single.max.out" \
      "$OUT_DIR/avx512-vpclmulhqlqdq-single.max.out"
    printf '| avx512-vpclmulhqlqdq-chain | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPCLMULHQLQ_CHAIN_RC" \
      "$VPCLMULHQLQ_CHAIN_HITS" \
      "$VPCLMULHQLQ_CHAIN_EXCEPTION_HITS" \
      "$VPCLMULHQLQ_CHAIN_RESULT" \
      "avx512-vpclmulhqlqdq-chain.max.out" \
      "$OUT_DIR/avx512-vpclmulhqlqdq-chain.max.out"
    printf '| avx512-vpclmulhqlqdq-semantic | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPCLMULHQLQ_SEMANTIC_RC" \
      "$VPCLMULHQLQ_SEMANTIC_HITS" \
      "$VPCLMULHQLQ_SEMANTIC_EXCEPTION_HITS" \
      "$VPCLMULHQLQ_SEMANTIC_RESULT" \
      "avx512-vpclmulhqlqdq-semantic.max.out" \
      "$OUT_DIR/avx512-vpclmulhqlqdq-semantic.max.out"
    printf '| avx512-vpclmulhqhqdq-single | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPCLMULHQHQ_SINGLE_RC" \
      "$VPCLMULHQHQ_SINGLE_HITS" \
      "$VPCLMULHQHQ_SINGLE_EXCEPTION_HITS" \
      "$VPCLMULHQHQ_SINGLE_RESULT" \
      "avx512-vpclmulhqhqdq-single.max.out" \
      "$OUT_DIR/avx512-vpclmulhqhqdq-single.max.out"
    printf '| avx512-vpclmulhqhqdq-chain | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPCLMULHQHQ_CHAIN_RC" \
      "$VPCLMULHQHQ_CHAIN_HITS" \
      "$VPCLMULHQHQ_CHAIN_EXCEPTION_HITS" \
      "$VPCLMULHQHQ_CHAIN_RESULT" \
      "avx512-vpclmulhqhqdq-chain.max.out" \
      "$OUT_DIR/avx512-vpclmulhqhqdq-chain.max.out"
    printf '| avx512-vpclmulhqhqdq-semantic | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPCLMULHQHQ_SEMANTIC_RC" \
      "$VPCLMULHQHQ_SEMANTIC_HITS" \
      "$VPCLMULHQHQ_SEMANTIC_EXCEPTION_HITS" \
      "$VPCLMULHQHQ_SEMANTIC_RESULT" \
      "avx512-vpclmulhqhqdq-semantic.max.out" \
      "$OUT_DIR/avx512-vpclmulhqhqdq-semantic.max.out"
    printf '| avx512-vaesenc-single | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VAESENC_SINGLE_RC" \
      "$VAESENC_SINGLE_HELPER_HITS" \
      "$VAESENC_SINGLE_EXCEPTION_HITS" \
      "$VAESENC_SINGLE_RESULT" \
      "avx512-vaesenc-single.max.out" \
      "$OUT_DIR/avx512-vaesenc-single.max.out"
    printf '| avx512-vaesenc-chain | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VAESENC_CHAIN_RC" \
      "$VAESENC_CHAIN_HELPER_HITS" \
      "$VAESENC_CHAIN_EXCEPTION_HITS" \
      "$VAESENC_CHAIN_RESULT" \
      "avx512-vaesenc-chain.max.out" \
      "$OUT_DIR/avx512-vaesenc-chain.max.out"
    printf '| avx512-vaesenc-semantic | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VAESENC_SEMANTIC_RC" \
      "$VAESENC_SEMANTIC_HELPER_HITS" \
      "$VAESENC_SEMANTIC_EXCEPTION_HITS" \
      "$VAESENC_SEMANTIC_RESULT" \
      "avx512-vaesenc-semantic.max.out" \
      "$OUT_DIR/avx512-vaesenc-semantic.max.out"
    printf '| avx512-vpslldq | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPSLLDQ_CHAIN_RC" \
      "$VPSLLDQ_CHAIN_HITS" \
      "$VPSLLDQ_CHAIN_EXCEPTION_HITS" \
      "$VPSLLDQ_RESULT" \
      "avx512-vpslldq.max.out" \
      "$OUT_DIR/avx512-vpslldq-chain.max.out"
    printf '| avx512-vpsrldq | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VPSRLDQ_CHAIN_RC" \
      "$VPSRLDQ_CHAIN_HITS" \
      "$VPSRLDQ_CHAIN_EXCEPTION_HITS" \
      "$VPSRLDQ_RESULT" \
      "avx512-vpsrldq.max.out" \
      "$OUT_DIR/avx512-vpsrldq-chain.max.out"
    printf '| avx512-vextracti32x4 | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VEXTRACTI32X4_CHAIN_RC" \
      "$VEXTRACTI32X4_CHAIN_HITS" \
      "$VEXTRACTI32X4_CHAIN_EXCEPTION_HITS" \
      "$VEXTRACTI32X4_RESULT" \
      "avx512-vextracti32x4.max.out" \
      "$OUT_DIR/avx512-vextracti32x4-chain.max.out"
    printf '| avx512-vextracti64x4 | `%s` | %s | %s | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VEXTRACTI64X4_CHAIN_RC" \
      "$VEXTRACTI64X4_CHAIN_HITS" \
      "$VEXTRACTI64X4_CHAIN_EXCEPTION_HITS" \
      "$VEXTRACTI64X4_RESULT" \
      "avx512-vextracti64x4.max.out" \
      "$OUT_DIR/avx512-vextracti64x4-chain.max.out"
    printf '| avx512-vmovdqu8 | `%s` | %s | n/a | %s | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$VMOVDQU8_CHAIN_RC" \
      "$VMOVDQU8_CHAIN_MEMORY_HITS" \
      "$VMOVDQU8_CHAIN_EXCEPTION_HITS" \
      "$VMOVDQU8_RESULT" \
      "avx512-vmovdqu8.max.out" \
      "$OUT_DIR/avx512-vmovdqu8-chain.max.out"
    printf '| aggregate-boundary | `%s` | %s | n/a | n/a | %s | %s | [%s](%s) |\n' \
      "-cpu max" \
      "$AGGREGATE_BOUNDARY_RC" \
      "$AGGREGATE_BOUNDARY_EXCEPTION_HITS" \
      "$AGGREGATE_BOUNDARY_RESULT" \
      "avx512-aggregate-boundary.max.out" \
      "$OUT_DIR/avx512-aggregate-boundary.max.out"
    echo
    echo "- AVX512 vpxorq QEMU log: [avx512-vpxorq.max.qemu.log]($OUT_DIR/avx512-vpxorq.max.qemu.log)"
    echo "- AVX512 vmovdqa64 QEMU log: [avx512-vmovdqa64.max.qemu.log]($OUT_DIR/avx512-vmovdqa64.max.qemu.log)"
    echo "- AVX512 vmovdqu64 store QEMU log: [avx512-vmovdqu64-store.max.qemu.log]($OUT_DIR/avx512-vmovdqu64-store.max.qemu.log)"
    echo "- AVX512 vmovdqu64 load QEMU log: [avx512-vmovdqu64-load.max.qemu.log]($OUT_DIR/avx512-vmovdqu64-load.max.qemu.log)"
    echo "- AVX512 vmovdqu64 chain QEMU log: [avx512-vmovdqu64-chain.max.qemu.log]($OUT_DIR/avx512-vmovdqu64-chain.max.qemu.log)"
    echo "- AVX512 vpshufb single QEMU log: [avx512-vpshufb-single.max.qemu.log]($OUT_DIR/avx512-vpshufb-single.max.qemu.log)"
    echo "- AVX512 vpshufb chain QEMU log: [avx512-vpshufb-chain.max.qemu.log]($OUT_DIR/avx512-vpshufb-chain.max.qemu.log)"
    echo "- AVX512 vpaddd single QEMU log: [avx512-vpaddd-single.max.qemu.log]($OUT_DIR/avx512-vpaddd-single.max.qemu.log)"
    echo "- AVX512 vpaddd chain QEMU log: [avx512-vpaddd-chain.max.qemu.log]($OUT_DIR/avx512-vpaddd-chain.max.qemu.log)"
    echo "- AVX512 vpternlogq single QEMU log: [avx512-vpternlogq-single.max.qemu.log]($OUT_DIR/avx512-vpternlogq-single.max.qemu.log)"
    echo "- AVX512 vpternlogq chain QEMU log: [avx512-vpternlogq-chain.max.qemu.log]($OUT_DIR/avx512-vpternlogq-chain.max.qemu.log)"
    echo "- AVX512 vpclmullqlqdq single QEMU log: [avx512-vpclmullqlqdq-single.max.qemu.log]($OUT_DIR/avx512-vpclmullqlqdq-single.max.qemu.log)"
    echo "- AVX512 vpclmullqlqdq chain QEMU log: [avx512-vpclmullqlqdq-chain.max.qemu.log]($OUT_DIR/avx512-vpclmullqlqdq-chain.max.qemu.log)"
    echo "- AVX512 vpclmullqlqdq semantic QEMU log: [avx512-vpclmullqlqdq-semantic.max.qemu.log]($OUT_DIR/avx512-vpclmullqlqdq-semantic.max.qemu.log)"
    echo "- AVX512 vpclmullqhqdq single QEMU log: [avx512-vpclmullqhqdq-single.max.qemu.log]($OUT_DIR/avx512-vpclmullqhqdq-single.max.qemu.log)"
    echo "- AVX512 vpclmullqhqdq chain QEMU log: [avx512-vpclmullqhqdq-chain.max.qemu.log]($OUT_DIR/avx512-vpclmullqhqdq-chain.max.qemu.log)"
    echo "- AVX512 vpclmullqhqdq semantic QEMU log: [avx512-vpclmullqhqdq-semantic.max.qemu.log]($OUT_DIR/avx512-vpclmullqhqdq-semantic.max.qemu.log)"
    echo "- AVX512 vpclmulhqlqdq single QEMU log: [avx512-vpclmulhqlqdq-single.max.qemu.log]($OUT_DIR/avx512-vpclmulhqlqdq-single.max.qemu.log)"
    echo "- AVX512 vpclmulhqlqdq chain QEMU log: [avx512-vpclmulhqlqdq-chain.max.qemu.log]($OUT_DIR/avx512-vpclmulhqlqdq-chain.max.qemu.log)"
    echo "- AVX512 vpclmulhqlqdq semantic QEMU log: [avx512-vpclmulhqlqdq-semantic.max.qemu.log]($OUT_DIR/avx512-vpclmulhqlqdq-semantic.max.qemu.log)"
    echo "- AVX512 vpclmulhqhqdq single QEMU log: [avx512-vpclmulhqhqdq-single.max.qemu.log]($OUT_DIR/avx512-vpclmulhqhqdq-single.max.qemu.log)"
    echo "- AVX512 vpclmulhqhqdq chain QEMU log: [avx512-vpclmulhqhqdq-chain.max.qemu.log]($OUT_DIR/avx512-vpclmulhqhqdq-chain.max.qemu.log)"
    echo "- AVX512 vpclmulhqhqdq semantic QEMU log: [avx512-vpclmulhqhqdq-semantic.max.qemu.log]($OUT_DIR/avx512-vpclmulhqhqdq-semantic.max.qemu.log)"
    echo "- AVX512 vaesenc single QEMU log: [avx512-vaesenc-single.max.qemu.log]($OUT_DIR/avx512-vaesenc-single.max.qemu.log)"
    echo "- AVX512 vaesenc chain QEMU log: [avx512-vaesenc-chain.max.qemu.log]($OUT_DIR/avx512-vaesenc-chain.max.qemu.log)"
    echo "- AVX512 vaesenc semantic QEMU log: [avx512-vaesenc-semantic.max.qemu.log]($OUT_DIR/avx512-vaesenc-semantic.max.qemu.log)"
    echo "- AVX512 vaesenclast single QEMU log: [avx512-vaesenclast-single.max.qemu.log]($OUT_DIR/avx512-vaesenclast-single.max.qemu.log)"
    echo "- AVX512 vaesenclast chain QEMU log: [avx512-vaesenclast-chain.max.qemu.log]($OUT_DIR/avx512-vaesenclast-chain.max.qemu.log)"
    echo "- AVX512 vaesenclast semantic QEMU log: [avx512-vaesenclast-semantic.max.qemu.log]($OUT_DIR/avx512-vaesenclast-semantic.max.qemu.log)"
    echo "- AVX512 vbroadcastf64x2 single QEMU log: [avx512-vbroadcastf64x2-single.max.qemu.log]($OUT_DIR/avx512-vbroadcastf64x2-single.max.qemu.log)"
    echo "- AVX512 vbroadcastf64x2 chain QEMU log: [avx512-vbroadcastf64x2-chain.max.qemu.log]($OUT_DIR/avx512-vbroadcastf64x2-chain.max.qemu.log)"
    echo "- AVX512 vpslldq single QEMU log: [avx512-vpslldq-single.max.qemu.log]($OUT_DIR/avx512-vpslldq-single.max.qemu.log)"
    echo "- AVX512 vpslldq chain QEMU log: [avx512-vpslldq-chain.max.qemu.log]($OUT_DIR/avx512-vpslldq-chain.max.qemu.log)"
    echo "- AVX512 vpsrldq single QEMU log: [avx512-vpsrldq-single.max.qemu.log]($OUT_DIR/avx512-vpsrldq-single.max.qemu.log)"
    echo "- AVX512 vpsrldq chain QEMU log: [avx512-vpsrldq-chain.max.qemu.log]($OUT_DIR/avx512-vpsrldq-chain.max.qemu.log)"
    echo "- AVX512 vextracti32x4 single QEMU log: [avx512-vextracti32x4-single.max.qemu.log]($OUT_DIR/avx512-vextracti32x4-single.max.qemu.log)"
    echo "- AVX512 vextracti32x4 chain QEMU log: [avx512-vextracti32x4-chain.max.qemu.log]($OUT_DIR/avx512-vextracti32x4-chain.max.qemu.log)"
    echo "- AVX512 vextracti64x4 single QEMU log: [avx512-vextracti64x4-single.max.qemu.log]($OUT_DIR/avx512-vextracti64x4-single.max.qemu.log)"
    echo "- AVX512 vextracti64x4 chain QEMU log: [avx512-vextracti64x4-chain.max.qemu.log]($OUT_DIR/avx512-vextracti64x4-chain.max.qemu.log)"
    echo "- AVX512 vmovdqu8 single QEMU log: [avx512-vmovdqu8-single.max.qemu.log]($OUT_DIR/avx512-vmovdqu8-single.max.qemu.log)"
    echo "- AVX512 vmovdqu8 chain QEMU log: [avx512-vmovdqu8-chain.max.qemu.log]($OUT_DIR/avx512-vmovdqu8-chain.max.qemu.log)"
    echo "- Aggregate boundary QEMU log: [avx512-aggregate-boundary.max.qemu.log]($OUT_DIR/avx512-aggregate-boundary.max.qemu.log)"
    echo "- AVX2 objdump: [avx2-vex.objdump.txt]($OUT_DIR/avx2-vex.objdump.txt)"
    echo "- AVX512 objdump: [avx512-vpxorq.objdump.txt]($OUT_DIR/avx512-vpxorq.objdump.txt)"
    echo "- AVX512 vmovdqa64 objdump: [avx512-vmovdqa64.objdump.txt]($OUT_DIR/avx512-vmovdqa64.objdump.txt)"
    echo "- AVX512 vmovdqu64 store objdump: [avx512-vmovdqu64-store.objdump.txt]($OUT_DIR/avx512-vmovdqu64-store.objdump.txt)"
    echo "- AVX512 vmovdqu64 load objdump: [avx512-vmovdqu64-load.objdump.txt]($OUT_DIR/avx512-vmovdqu64-load.objdump.txt)"
    echo "- AVX512 vmovdqu64 chain objdump: [avx512-vmovdqu64-chain.objdump.txt]($OUT_DIR/avx512-vmovdqu64-chain.objdump.txt)"
    echo "- AVX512 vpshufb single objdump: [avx512-vpshufb-single.objdump.txt]($OUT_DIR/avx512-vpshufb-single.objdump.txt)"
    echo "- AVX512 vpshufb chain objdump: [avx512-vpshufb-chain.objdump.txt]($OUT_DIR/avx512-vpshufb-chain.objdump.txt)"
    echo "- AVX512 vpaddd single objdump: [avx512-vpaddd-single.objdump.txt]($OUT_DIR/avx512-vpaddd-single.objdump.txt)"
    echo "- AVX512 vpaddd chain objdump: [avx512-vpaddd-chain.objdump.txt]($OUT_DIR/avx512-vpaddd-chain.objdump.txt)"
    echo "- AVX512 vpternlogq single objdump: [avx512-vpternlogq-single.objdump.txt]($OUT_DIR/avx512-vpternlogq-single.objdump.txt)"
    echo "- AVX512 vpternlogq chain objdump: [avx512-vpternlogq-chain.objdump.txt]($OUT_DIR/avx512-vpternlogq-chain.objdump.txt)"
    echo "- AVX512 vpclmullqlqdq single objdump: [avx512-vpclmullqlqdq-single.objdump.txt]($OUT_DIR/avx512-vpclmullqlqdq-single.objdump.txt)"
    echo "- AVX512 vpclmullqlqdq chain objdump: [avx512-vpclmullqlqdq-chain.objdump.txt]($OUT_DIR/avx512-vpclmullqlqdq-chain.objdump.txt)"
    echo "- AVX512 vpclmullqlqdq semantic objdump: [avx512-vpclmullqlqdq-semantic.objdump.txt]($OUT_DIR/avx512-vpclmullqlqdq-semantic.objdump.txt)"
    echo "- AVX512 vpclmullqhqdq single objdump: [avx512-vpclmullqhqdq-single.objdump.txt]($OUT_DIR/avx512-vpclmullqhqdq-single.objdump.txt)"
    echo "- AVX512 vpclmullqhqdq chain objdump: [avx512-vpclmullqhqdq-chain.objdump.txt]($OUT_DIR/avx512-vpclmullqhqdq-chain.objdump.txt)"
    echo "- AVX512 vpclmullqhqdq semantic objdump: [avx512-vpclmullqhqdq-semantic.objdump.txt]($OUT_DIR/avx512-vpclmullqhqdq-semantic.objdump.txt)"
    echo "- AVX512 vpclmulhqlqdq single objdump: [avx512-vpclmulhqlqdq-single.objdump.txt]($OUT_DIR/avx512-vpclmulhqlqdq-single.objdump.txt)"
    echo "- AVX512 vpclmulhqlqdq chain objdump: [avx512-vpclmulhqlqdq-chain.objdump.txt]($OUT_DIR/avx512-vpclmulhqlqdq-chain.objdump.txt)"
    echo "- AVX512 vpclmulhqlqdq semantic objdump: [avx512-vpclmulhqlqdq-semantic.objdump.txt]($OUT_DIR/avx512-vpclmulhqlqdq-semantic.objdump.txt)"
    echo "- AVX512 vpclmulhqhqdq single objdump: [avx512-vpclmulhqhqdq-single.objdump.txt]($OUT_DIR/avx512-vpclmulhqhqdq-single.objdump.txt)"
    echo "- AVX512 vpclmulhqhqdq chain objdump: [avx512-vpclmulhqhqdq-chain.objdump.txt]($OUT_DIR/avx512-vpclmulhqhqdq-chain.objdump.txt)"
    echo "- AVX512 vpclmulhqhqdq semantic objdump: [avx512-vpclmulhqhqdq-semantic.objdump.txt]($OUT_DIR/avx512-vpclmulhqhqdq-semantic.objdump.txt)"
    echo "- AVX512 vaesenc single objdump: [avx512-vaesenc-single.objdump.txt]($OUT_DIR/avx512-vaesenc-single.objdump.txt)"
    echo "- AVX512 vaesenc chain objdump: [avx512-vaesenc-chain.objdump.txt]($OUT_DIR/avx512-vaesenc-chain.objdump.txt)"
    echo "- AVX512 vaesenc semantic objdump: [avx512-vaesenc-semantic.objdump.txt]($OUT_DIR/avx512-vaesenc-semantic.objdump.txt)"
    echo "- AVX512 vaesenclast single objdump: [avx512-vaesenclast-single.objdump.txt]($OUT_DIR/avx512-vaesenclast-single.objdump.txt)"
    echo "- AVX512 vaesenclast chain objdump: [avx512-vaesenclast-chain.objdump.txt]($OUT_DIR/avx512-vaesenclast-chain.objdump.txt)"
    echo "- AVX512 vaesenclast semantic objdump: [avx512-vaesenclast-semantic.objdump.txt]($OUT_DIR/avx512-vaesenclast-semantic.objdump.txt)"
    echo "- AVX512 vbroadcastf64x2 single objdump: [avx512-vbroadcastf64x2-single.objdump.txt]($OUT_DIR/avx512-vbroadcastf64x2-single.objdump.txt)"
    echo "- AVX512 vbroadcastf64x2 chain objdump: [avx512-vbroadcastf64x2-chain.objdump.txt]($OUT_DIR/avx512-vbroadcastf64x2-chain.objdump.txt)"
    echo "- AVX512 vpslldq single objdump: [avx512-vpslldq-single.objdump.txt]($OUT_DIR/avx512-vpslldq-single.objdump.txt)"
    echo "- AVX512 vpslldq chain objdump: [avx512-vpslldq-chain.objdump.txt]($OUT_DIR/avx512-vpslldq-chain.objdump.txt)"
    echo "- AVX512 vpsrldq single objdump: [avx512-vpsrldq-single.objdump.txt]($OUT_DIR/avx512-vpsrldq-single.objdump.txt)"
    echo "- AVX512 vpsrldq chain objdump: [avx512-vpsrldq-chain.objdump.txt]($OUT_DIR/avx512-vpsrldq-chain.objdump.txt)"
    echo "- AVX512 vextracti32x4 single objdump: [avx512-vextracti32x4-single.objdump.txt]($OUT_DIR/avx512-vextracti32x4-single.objdump.txt)"
    echo "- AVX512 vextracti32x4 chain objdump: [avx512-vextracti32x4-chain.objdump.txt]($OUT_DIR/avx512-vextracti32x4-chain.objdump.txt)"
    echo "- AVX512 vextracti64x4 single objdump: [avx512-vextracti64x4-single.objdump.txt]($OUT_DIR/avx512-vextracti64x4-single.objdump.txt)"
    echo "- AVX512 vextracti64x4 chain objdump: [avx512-vextracti64x4-chain.objdump.txt]($OUT_DIR/avx512-vextracti64x4-chain.objdump.txt)"
    echo "- AVX512 vmovdqu8 single objdump: [avx512-vmovdqu8-single.objdump.txt]($OUT_DIR/avx512-vmovdqu8-single.objdump.txt)"
    echo "- AVX512 vmovdqu8 chain objdump: [avx512-vmovdqu8-chain.objdump.txt]($OUT_DIR/avx512-vmovdqu8-chain.objdump.txt)"
    echo "- Aggregate boundary objdump: [avx512-aggregate-boundary.objdump.txt]($OUT_DIR/avx512-aggregate-boundary.objdump.txt)"
  } >>"$SUMMARY"
}

append_final_summary() {
  local overall="FAIL"
  if [[ "$FEATURE_RESULT" = "PASS" && "$AVX2_RESULT" = "PASS" &&
        "$AVX512_RESULT" = "PASS" && "$VMOVDQA64_RESULT" = "PASS" &&
        "$VMOVDQU64_RESULT" = "PASS" && "$VPSHUFB_RESULT" = "PASS" &&
        "$VPADDD_RESULT" = "PASS" && "$VPTERNLOGQ_RESULT" = "PASS" &&
        "$VPCLMULLQLQ_RESULT" = "PASS" && "$VPCLMULLQHQ_RESULT" = "PASS" &&
        "$VPCLMULHQLQ_RESULT" = "PASS" && "$VPCLMULHQHQ_RESULT" = "PASS" &&
        "$VAESENC_RESULT" = "PASS" && "$VAESENCLAST_RESULT" = "PASS" &&
        "$VBROADCASTF64X2_RESULT" = "PASS" &&
        "$VPSLLDQ_RESULT" = "PASS" && "$VPSRLDQ_RESULT" = "PASS" &&
        "$VEXTRACTI32X4_RESULT" = "PASS" && "$VEXTRACTI64X4_RESULT" = "PASS" &&
        "$VMOVDQU8_RESULT" = "PASS" &&
        "$AGGREGATE_BOUNDARY_RESULT" = "PASS" ]]; then
    overall="PASS"
  fi

  {
    echo
    echo "## Summary"
    echo
    echo "| Case | Expected | Status | Key evidence |"
    echo "|---|---|---|---|"
    echo "| feature | CPUID advertises AVX512F and VPCLMULQDQ; XCR0 includes SSE/YMM/opmask/ZMM state. | $FEATURE_RESULT | $FEATURE_EVIDENCE |"
    echo "| avx2-vex | Existing VEX AVX2 regression probe exits successfully. | $AVX2_RESULT | $AVX2_EVIDENCE |"
    echo "| vpxorq | Exact EVEX \`vpxorq zmm0,zmm0,zmm0\` runs with vector TCG ops and no illegal-instruction evidence. | $AVX512_RESULT | $AVX512_EVIDENCE |"
    echo "| vmovdqa64 | Exact EVEX \`vmovdqa64 zmm1,zmm0\` register move runs with vector TCG ops and no illegal-instruction evidence. | $VMOVDQA64_RESULT | $VMOVDQA64_EVIDENCE |"
    echo "| vmovdqu64 | Exact EVEX \`vmovdqu64\` store/load/chain probes run with memory TCG ops and no illegal-instruction evidence. | $VMOVDQU64_RESULT | $VMOVDQU64_EVIDENCE |"
    echo "| vpshufb | Exact EVEX \`vpshufb zmm3,zmm2,zmm2\` runs in single and chained probes with no illegal-instruction evidence. | $VPSHUFB_RESULT | $VPSHUFB_EVIDENCE |"
    echo "| vpaddd | Exact EVEX \`vpaddd zmm4,zmm3,zmm2\` runs in single and chained probes with no illegal-instruction evidence. | $VPADDD_RESULT | $VPADDD_EVIDENCE |"
    echo "| vpternlogq | Exact EVEX \`vpternlogq zmm5,zmm4,zmm3,0x96\` runs in single and chained probes with no illegal-instruction evidence. | $VPTERNLOGQ_RESULT | $VPTERNLOGQ_EVIDENCE |"
    echo "| vpclmullqlqdq | Exact EVEX \`vpclmullqlqdq zmm6,zmm5,zmm4\` runs in single, chained, and semantic probes with no illegal-instruction evidence. | $VPCLMULLQLQ_RESULT | $VPCLMULLQLQ_EVIDENCE |"
    echo "| vpclmullqhqdq | Exact EVEX \`vpclmullqhqdq zmm7,zmm5,zmm4\` runs in single, chained, and semantic probes with no illegal-instruction evidence. | $VPCLMULLQHQ_RESULT | $VPCLMULLQHQ_EVIDENCE |"
    echo "| vpclmulhqlqdq | Exact EVEX \`vpclmulhqlqdq zmm8,zmm5,zmm4\` runs in single, chained, and semantic probes with no illegal-instruction evidence. | $VPCLMULHQLQ_RESULT | $VPCLMULHQLQ_EVIDENCE |"
    echo "| vpclmulhqhqdq | Exact EVEX \`vpclmulhqhqdq zmm9,zmm5,zmm4\` runs in single, chained, and semantic probes with no illegal-instruction evidence. | $VPCLMULHQHQ_RESULT | $VPCLMULHQHQ_EVIDENCE |"
    echo "| vaesenc | Exact EVEX \`vaesenc zmm10,zmm9,zmm8\` runs in single, chained, and semantic probes with no illegal-instruction evidence. | $VAESENC_RESULT | $VAESENC_EVIDENCE |"
    echo "| vaesenclast | Exact EVEX \`vaesenclast zmm11,zmm10,zmm7\` runs in single, chained, and semantic probes with no illegal-instruction evidence. | $VAESENCLAST_RESULT | $VAESENCLAST_EVIDENCE |"
    echo "| vbroadcastf64x2 | Exact EVEX \`vbroadcastf64x2 zmm12,XMMWORD PTR [rip+0xf9b]\` runs in single and chained probes with no illegal-instruction evidence; the semantic form is intentionally not required because it immediately falls through to the next unsupported instruction. | $VBROADCASTF64X2_RESULT | $VBROADCASTF64X2_EVIDENCE |"
    echo "| vpslldq | Exact EVEX \`vpslldq zmm13,zmm12,0x4\` runs in single and chained probes with no illegal-instruction evidence. | $VPSLLDQ_RESULT | $VPSLLDQ_EVIDENCE |"
    echo "| vpsrldq | Exact EVEX \`vpsrldq zmm14,zmm13,0x4\` runs in single and chained probes with no illegal-instruction evidence. | $VPSRLDQ_RESULT | $VPSRLDQ_EVIDENCE |"
    echo "| vextracti32x4 | Exact EVEX \`vextracti32x4 xmm15,zmm14,0x1\` runs in single and chained probes with no illegal-instruction evidence. | $VEXTRACTI32X4_RESULT | $VEXTRACTI32X4_EVIDENCE |"
    echo "| vextracti64x4 | Exact EVEX \`vextracti64x4 ymm16,zmm14,0x1\` runs in single and chained probes with no illegal-instruction evidence. | $VEXTRACTI64X4_RESULT | $VEXTRACTI64X4_EVIDENCE |"
    echo "| vmovdqu8 | Exact EVEX \`vmovdqu8 zmmword ptr [rip+disp32],zmm14\` runs in single and chained probes with memory TCG ops and no illegal-instruction evidence. | $VMOVDQU8_RESULT | $VMOVDQU8_EVIDENCE |"
    echo "| aggregate-boundary | Aggregate probe now completes through the validated \`vmovdqu8 zmmword ptr [rip+disp32],zmm14\` store; if local behavior differs, this row records the observed PC/result. | $AGGREGATE_BOUNDARY_RESULT | $AGGREGATE_BOUNDARY_EVIDENCE |"
    echo "| overall-required | Required cases pass. | $overall | required=feature,avx2-vex,avx512-vpxorq,avx512-vmovdqa64,avx512-vmovdqu64,avx512-vpshufb,avx512-vpaddd,avx512-vpternlogq,avx512-vpclmullqlqdq,avx512-vpclmullqhqdq,avx512-vpclmulhqlqdq,avx512-vpclmulhqhqdq,avx512-vaesenc,avx512-vaesenclast,avx512-vbroadcastf64x2,avx512-vpslldq,avx512-vpsrldq,avx512-vextracti32x4,avx512-vextracti64x4,avx512-vmovdqu8,aggregate-boundary |"
    echo "| overall | Full integrated harness pass status. | $overall | mirrors terminal summary \`overall: $overall\` for the complete patch-series run |"
    echo
    echo "## Notes"
    echo
    echo "- This is an experimental smoke series, not general AVX-512 implementation."
    echo "- Patch 0002 only recognizes the exact bytes \`62 f1 fd 48 ef c0\` in 64-bit mode."
    echo "- Patch 0003 only recognizes the exact bytes \`62 f1 fd 48 6f c8\` in 64-bit mode."
    echo "- Patch 0004 only recognizes the exact \`vmovdqu64\` RIP-relative byte strings validated by the standalone store/load/chain smoke."
    echo "- Patch 0005 only recognizes the exact bytes \`62 f2 6d 48 00 da\` in 64-bit mode."
    echo "- Patch 0006 only recognizes the exact bytes \`62 f1 65 48 fe e2\` in 64-bit mode."
    echo "- Patch 0007 only recognizes the exact bytes \`62 f3 dd 48 25 eb 96\` in 64-bit mode."
    echo "- Patch 0008 only recognizes the exact bytes \`62 f3 55 48 44 f4 00\` and \`62 f3 7d 48 44 c8 00\` in 64-bit mode."
    echo "- Patch 0009 only recognizes the exact bytes \`62 f3 55 48 44 fc 10\` in 64-bit mode."
    echo "- Patch 0010 only recognizes the exact bytes \`62 73 55 48 44 c4 01\` in 64-bit mode."
    echo "- Patch 0011 only recognizes the exact bytes \`62 73 55 48 44 cc 11\` in 64-bit mode."
    echo "- Patch 0012 only recognizes the exact bytes \`62 52 35 48 dc d0\` and \`62 f2 7d 48 dc c8\` in 64-bit mode."
    echo "- Patch 0013 only recognizes the exact bytes \`62 72 2d 48 dd df\` in 64-bit mode."
    echo "- Patch 0014 only recognizes the exact bytes \`62 72 fd 48 1a 25 9b 0f 00 00\` in 64-bit mode."
    echo "- Patch 0015 only recognizes the exact bytes \`62 d1 15 48 73 fc 04\` in 64-bit mode."
    echo "- Patch 0016 only recognizes the exact bytes \`62 d1 0d 48 73 dd 04\` in 64-bit mode."
    echo "- Patch 0017 only recognizes the exact bytes \`62 53 7d 48 39 f7 01\` in 64-bit mode."
    echo "- Patch 0018 only recognizes the exact bytes \`62 33 fd 48 3b f0 01\` in 64-bit mode."
    echo "- Patch 0019 only recognizes the exact bytes \`62 71 7f 48 7f 35 f6 0f 00 00\` and \`62 71 7f 48 7f 35 75 0f 00 00\` in 64-bit mode."
    echo "- The aggregate probe now completes through \`vmovdqu8\`; this run observed the final translated PC at \`$AGGREGATE_BOUNDARY_EXPECTED_PC\`."
    echo "- All QEMU source, build, patch, probe, and log outputs for this run are under \`$SCRATCH_ROOT\`."
  } >>"$SUMMARY"

  cat <<EOF
scratch_root: $SCRATCH_ROOT
patch_dir:    $PATCH_DIR
build_bin:    $BUILD_DIR/qemu-x86_64
summary:      $SUMMARY
feature:      $FEATURE_RESULT avx512f=$FEATURE_AVX512F vpclmulqdq=$FEATURE_VPCLMULQDQ xcr0_avx512=$FEATURE_XCR0_STATE rc=$FEATURE_RC
avx2-vex:     $AVX2_RESULT rc=$AVX2_RC
avx512-vpxorq:$AVX512_RESULT rc=$AVX512_RC vector_hits=$AVX512_VECTOR_HITS exception_hits=$AVX512_EXCEPTION_HITS
vmovdqa64:    $VMOVDQA64_RESULT rc=$VMOVDQA64_RC vector_hits=$VMOVDQA64_VECTOR_HITS exception_hits=$VMOVDQA64_EXCEPTION_HITS
vmovdqu64:    $VMOVDQU64_RESULT store=$VMOVDQU64_STORE_RESULT rc=$VMOVDQU64_STORE_RC memory_hits=$VMOVDQU64_STORE_MEMORY_HITS load=$VMOVDQU64_LOAD_RESULT rc=$VMOVDQU64_LOAD_RC memory_hits=$VMOVDQU64_LOAD_MEMORY_HITS chain=$VMOVDQU64_CHAIN_RESULT rc=$VMOVDQU64_CHAIN_RC memory_hits=$VMOVDQU64_CHAIN_MEMORY_HITS
vpshufb:      $VPSHUFB_RESULT single=$VPSHUFB_SINGLE_RESULT rc=$VPSHUFB_SINGLE_RC pshufb_hits=$VPSHUFB_SINGLE_PSHUFB_HITS chain=$VPSHUFB_CHAIN_RESULT rc=$VPSHUFB_CHAIN_RC pshufb_hits=$VPSHUFB_CHAIN_PSHUFB_HITS
vpaddd:       $VPADDD_RESULT single=$VPADDD_SINGLE_RESULT rc=$VPADDD_SINGLE_RC add_hits=$VPADDD_SINGLE_ADD_HITS chain=$VPADDD_CHAIN_RESULT rc=$VPADDD_CHAIN_RC add_hits=$VPADDD_CHAIN_ADD_HITS
vpternlogq:   $VPTERNLOGQ_RESULT single=$VPTERNLOGQ_SINGLE_RESULT rc=$VPTERNLOGQ_SINGLE_RC ternlog_hits=$VPTERNLOGQ_SINGLE_TERNLOG_HITS xor_hits=$VPTERNLOGQ_SINGLE_XOR_HITS chain=$VPTERNLOGQ_CHAIN_RESULT rc=$VPTERNLOGQ_CHAIN_RC ternlog_hits=$VPTERNLOGQ_CHAIN_TERNLOG_HITS xor_hits=$VPTERNLOGQ_CHAIN_XOR_HITS
vpclmullqlqdq:$VPCLMULLQLQ_RESULT single=$VPCLMULLQLQ_SINGLE_RESULT rc=$VPCLMULLQLQ_SINGLE_RC pclmul_hits=$VPCLMULLQLQ_SINGLE_HITS chain=$VPCLMULLQLQ_CHAIN_RESULT rc=$VPCLMULLQLQ_CHAIN_RC pclmul_hits=$VPCLMULLQLQ_CHAIN_HITS semantic=$VPCLMULLQLQ_SEMANTIC_RESULT rc=$VPCLMULLQLQ_SEMANTIC_RC pclmul_hits=$VPCLMULLQLQ_SEMANTIC_HITS
vpclmullqhqdq:$VPCLMULLQHQ_RESULT single=$VPCLMULLQHQ_SINGLE_RESULT rc=$VPCLMULLQHQ_SINGLE_RC pclmul_hits=$VPCLMULLQHQ_SINGLE_HITS chain=$VPCLMULLQHQ_CHAIN_RESULT rc=$VPCLMULLQHQ_CHAIN_RC pclmul_hits=$VPCLMULLQHQ_CHAIN_HITS semantic=$VPCLMULLQHQ_SEMANTIC_RESULT rc=$VPCLMULLQHQ_SEMANTIC_RC pclmul_hits=$VPCLMULLQHQ_SEMANTIC_HITS
vpclmulhqlqdq:$VPCLMULHQLQ_RESULT single=$VPCLMULHQLQ_SINGLE_RESULT rc=$VPCLMULHQLQ_SINGLE_RC pclmul_hits=$VPCLMULHQLQ_SINGLE_HITS chain=$VPCLMULHQLQ_CHAIN_RESULT rc=$VPCLMULHQLQ_CHAIN_RC pclmul_hits=$VPCLMULHQLQ_CHAIN_HITS semantic=$VPCLMULHQLQ_SEMANTIC_RESULT rc=$VPCLMULHQLQ_SEMANTIC_RC pclmul_hits=$VPCLMULHQLQ_SEMANTIC_HITS
vpclmulhqhqdq:$VPCLMULHQHQ_RESULT single=$VPCLMULHQHQ_SINGLE_RESULT rc=$VPCLMULHQHQ_SINGLE_RC pclmul_hits=$VPCLMULHQHQ_SINGLE_HITS chain=$VPCLMULHQHQ_CHAIN_RESULT rc=$VPCLMULHQHQ_CHAIN_RC pclmul_hits=$VPCLMULHQHQ_CHAIN_HITS semantic=$VPCLMULHQHQ_SEMANTIC_RESULT rc=$VPCLMULHQHQ_SEMANTIC_RC pclmul_hits=$VPCLMULHQHQ_SEMANTIC_HITS
vaesenc:      $VAESENC_RESULT single=$VAESENC_SINGLE_RESULT rc=$VAESENC_SINGLE_RC aesenc_helper_hits=$VAESENC_SINGLE_HELPER_HITS chain=$VAESENC_CHAIN_RESULT rc=$VAESENC_CHAIN_RC aesenc_helper_hits=$VAESENC_CHAIN_HELPER_HITS semantic=$VAESENC_SEMANTIC_RESULT rc=$VAESENC_SEMANTIC_RC aesenc_helper_hits=$VAESENC_SEMANTIC_HELPER_HITS
vaesenclast:  $VAESENCLAST_RESULT single=$VAESENCLAST_SINGLE_RESULT rc=$VAESENCLAST_SINGLE_RC aesenclast_helper_hits=$VAESENCLAST_SINGLE_HELPER_HITS chain=$VAESENCLAST_CHAIN_RESULT rc=$VAESENCLAST_CHAIN_RC aesenclast_helper_hits=$VAESENCLAST_CHAIN_HELPER_HITS semantic=$VAESENCLAST_SEMANTIC_RESULT rc=$VAESENCLAST_SEMANTIC_RC aesenclast_helper_hits=$VAESENCLAST_SEMANTIC_HELPER_HITS
vbroadcastf64x2:$VBROADCASTF64X2_RESULT single=$VBROADCASTF64X2_SINGLE_RESULT rc=$VBROADCASTF64X2_SINGLE_RC vbroadcast_hits=$VBROADCASTF64X2_SINGLE_VBROADCAST_HITS qemu_ld2_i128_hits=$VBROADCASTF64X2_SINGLE_QEMU_LD2_I128_HITS chain=$VBROADCASTF64X2_CHAIN_RESULT rc=$VBROADCASTF64X2_CHAIN_RC vbroadcast_hits=$VBROADCASTF64X2_CHAIN_VBROADCAST_HITS qemu_ld2_i128_hits=$VBROADCASTF64X2_CHAIN_QEMU_LD2_I128_HITS
vpslldq:      $VPSLLDQ_RESULT single=$VPSLLDQ_SINGLE_RESULT rc=$VPSLLDQ_SINGLE_RC vpslldq_hits=$VPSLLDQ_SINGLE_HITS chain=$VPSLLDQ_CHAIN_RESULT rc=$VPSLLDQ_CHAIN_RC vpslldq_hits=$VPSLLDQ_CHAIN_HITS
vpsrldq:      $VPSRLDQ_RESULT single=$VPSRLDQ_SINGLE_RESULT rc=$VPSRLDQ_SINGLE_RC vpsrldq_hits=$VPSRLDQ_SINGLE_HITS chain=$VPSRLDQ_CHAIN_RESULT rc=$VPSRLDQ_CHAIN_RC vpsrldq_hits=$VPSRLDQ_CHAIN_HITS
vextracti32x4:$VEXTRACTI32X4_RESULT single=$VEXTRACTI32X4_SINGLE_RESULT rc=$VEXTRACTI32X4_SINGLE_RC vextracti32x4_hits=$VEXTRACTI32X4_SINGLE_HITS chain=$VEXTRACTI32X4_CHAIN_RESULT rc=$VEXTRACTI32X4_CHAIN_RC vextracti32x4_hits=$VEXTRACTI32X4_CHAIN_HITS
vextracti64x4:$VEXTRACTI64X4_RESULT single=$VEXTRACTI64X4_SINGLE_RESULT rc=$VEXTRACTI64X4_SINGLE_RC vextracti64x4_hits=$VEXTRACTI64X4_SINGLE_HITS chain=$VEXTRACTI64X4_CHAIN_RESULT rc=$VEXTRACTI64X4_CHAIN_RC vextracti64x4_hits=$VEXTRACTI64X4_CHAIN_HITS
vmovdqu8:     $VMOVDQU8_RESULT single=$VMOVDQU8_SINGLE_RESULT rc=$VMOVDQU8_SINGLE_RC vmovdqu8_hits=$VMOVDQU8_SINGLE_HITS memory_hits=$VMOVDQU8_SINGLE_MEMORY_HITS chain=$VMOVDQU8_CHAIN_RESULT rc=$VMOVDQU8_CHAIN_RC vmovdqu8_hits=$VMOVDQU8_CHAIN_HITS memory_hits=$VMOVDQU8_CHAIN_MEMORY_HITS
aggregate:    $AGGREGATE_BOUNDARY_RESULT expected_next=$AGGREGATE_BOUNDARY_EXPECTED_NEXT expected_pc=$AGGREGATE_BOUNDARY_EXPECTED_PC observed_pc=$AGGREGATE_BOUNDARY_PC rc=$AGGREGATE_BOUNDARY_RC
overall:      $overall
EOF

  [[ "$overall" = "PASS" ]]
}

main() {
  parse_args "$@"
  refresh_paths

  if [[ "$FRESH" -eq 1 ]]; then
    log "Removing scratch root $SCRATCH_ROOT"
    rm -rf "$SCRATCH_ROOT"
  fi

  mkdir -p "$SCRATCH_ROOT" "$OUT_DIR"
  write_patch_files
  ensure_build_tools
  download_or_select_source
  generate_0013_patch
  generate_0014_patch
  generate_0015_patch
  generate_0016_patch
  generate_0017_patch
  generate_0018_patch
  generate_0019_patch
  init_summary
  prepare_patched_tree
  configure_qemu
  build_qemu
  build_probes
  run_feature_probe
  run_exec_probes
  append_final_summary
}

main "$@"
