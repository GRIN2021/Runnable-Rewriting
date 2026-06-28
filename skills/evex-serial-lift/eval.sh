#!/usr/bin/env bash
# Evaluate recall/precision of a lifted .ll file against the libcrypto ground truth.
#
# Usage:
#   ./eval.sh --install-dir ~/runnable-evex --ll ~/evex-lift-out/libcrypto.evex.serial.ll --out-dir ~/evex-eval-out
#
# Expected output (Jun-28 baseline):
#   precision=0.986520  recall=0.927971

set -euo pipefail

INSTALL_DIR="${HOME}/runnable-evex"
LL_FILE=""
OUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --ll)          LL_FILE="$2";     shift 2 ;;
        --out-dir)     OUT_DIR="$2";     shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "${LL_FILE}" || -z "${OUT_DIR}" ]]; then
    echo "Usage: $0 --install-dir <dir> --ll <file.ll> --out-dir <dir>"
    exit 1
fi

SCRIPTS_DIR="${INSTALL_DIR}/share/runnable"
GT_DIR="${INSTALL_DIR}/ground-truth"

mkdir -p "${OUT_DIR}"

# The eval scripts import each other by name; run from share/runnable
export RUNNABLE_LIBCRYPTO_GROUND_TRUTH="${GT_DIR}/libcrypto.so.3"
export RUNNABLE_LIBCRYPTO_GROUND_TRUTH_PB="${GT_DIR}/libcrypto.gtBlock.pb"

echo "=== cmp evaluation ==="
echo "ll      : ${LL_FILE}"
echo "gt      : ${RUNNABLE_LIBCRYPTO_GROUND_TRUTH}"
echo "gt_pb   : ${RUNNABLE_LIBCRYPTO_GROUND_TRUTH_PB}"
echo "out_dir : ${OUT_DIR}"
echo ""

cd "${SCRIPTS_DIR}"
python3 validate_libcrypto_ground_truth.py \
    cmp \
    --ll "${LL_FILE}" \
    --out-dir "${OUT_DIR}" \
    --allow-low-metrics \
    2>&1 | tee "${OUT_DIR}/eval.log"

echo ""
if [[ -f "${OUT_DIR}/cmp.json" ]]; then
    echo "=== Summary ==="
    python3 -c "
import json, sys
d = json.load(open('${OUT_DIR}/cmp.json'))
print(f'  precision : {d[\"precision\"]:.6f}')
print(f'  recall    : {d[\"recall\"]:.6f}')
print(f'  hit       : {d[\"hit\"]}')
print(f'  fn        : {d.get(\"fn_count\", d.get(\"obj_only\", \"?\"))}')
print(f'  fp        : {d.get(\"fp_count\", d.get(\"ll_only\", \"?\"))}')
" 2>/dev/null || true
fi
