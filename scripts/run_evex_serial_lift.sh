#!/usr/bin/env bash
# Serial lift of libcrypto.so.3 using EVEX libtinycode (new QEMU v2 backend).
# Reproduces the Jun-25 result: precision=0.9767, recall=0.9306, elapsed~3118s.
#
# Usage:
#   ./scripts/run_evex_serial_lift.sh [--out-dir <dir>] [--eval-only <ll-file>]
#
# --out-dir <dir>   Where to write the .ll output and logs (default: /hdd/evex-serial-<timestamp>)
# --eval-only <ll>  Skip lifting; run cmp evaluation on an existing .ll file

set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NEWLIB_DIR="/hdd/runnable-libcrypto-evex-lift-20260625/newlib"
LIBCRYPTO_BIN="${WORKSPACE_ROOT}/GroudTruth/groundtruth-gap-analysis-skill/results/libcrypto-artifacts/libcrypto.so.3"
GTBLOCK_PB="${WORKSPACE_ROOT}/GroudTruth/groundtruth-gap-analysis-skill/results/libcrypto-artifacts/libcrypto.gtBlock.pb"
IMAGE="rr_qemu_v2_runtime:latest"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUT_DIR="/hdd/evex-serial-${TIMESTAMP}"
EVAL_ONLY_LL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out-dir)   OUT_DIR="$2";       shift 2 ;;
        --eval-only) EVAL_ONLY_LL="$2";  shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

mkdir -p "${OUT_DIR}"
OUT_LL="${OUT_DIR}/libcrypto.evex.serial.ll"

if [[ -z "${EVAL_ONLY_LL}" ]]; then
    echo "=== EVEX serial lift ==="
    echo "out_dir  : ${OUT_DIR}"
    echo "image    : ${IMAGE}"
    echo "newlib   : ${NEWLIB_DIR}"
    echo "binary   : ${LIBCRYPTO_BIN}"
    echo "entry    : 0x500cef80 (base=0x50000000 + text_start=0xcef80)"
    echo "Expected : ~3118s (~52 min), rc=0"
    echo ""

    # Inner script run inside the container
    read -r -d '' INNER_SCRIPT << 'INNER_EOF' || true
set -euo pipefail
NEWLIB=/liftws/newlib
BIN=/liftws/libcrypto.so.3
OUTLL=/liftws/out/libcrypto.evex.serial.ll

export LD_LIBRARY_PATH="$NEWLIB:/root/Runnable-Rewriting/root/lib"

echo "[$(date --iso-8601=seconds)] START serial EVEX lift"
echo "libtinycode=${NEWLIB}/libtinycode-x86_64.so ($(stat -c %s ${NEWLIB}/libtinycode-x86_64.so) bytes)"
START=$(date +%s)

"${NEWLIB}/runnable-lift" "$BIN" "$OUTLL" \
    -base=0x50000000 \
    -entry=0x500cef80 \
    -use-debug-symbols \
    -no-link \
    > /liftws/out/lift.stdout 2> /liftws/out/lift.stderr

rc=$?
END=$(date +%s)
echo "[$(date --iso-8601=seconds)] END lift rc=${rc} elapsed=$((END-START))s"
echo "${rc}" > /liftws/out/lift.rc

if [[ $rc -eq 0 && -s "$OUTLL" ]]; then
    echo "LL_OK size=$(stat -c %s $OUTLL) lines=$(wc -l < $OUTLL)"
else
    echo "LL_FAIL"
    exit 1
fi
INNER_EOF

    START_TS=$(date +%s)
    docker run --rm \
        --memory="32g" --memory-swap="32g" \
        --cpus="30" \
        -v "${NEWLIB_DIR}:/liftws/newlib:ro" \
        -v "${LIBCRYPTO_BIN}:/liftws/libcrypto.so.3:ro" \
        -v "${OUT_DIR}:/liftws/out" \
        -v "${WORKSPACE_ROOT}:/workspace:ro" \
        "${IMAGE}" \
        bash -c "${INNER_SCRIPT}" 2>&1 | tee "${OUT_DIR}/container.log"

    END_TS=$(date +%s)
    echo ""
    echo "=== Lift complete: elapsed=$(( END_TS - START_TS ))s, ll=${OUT_LL} ==="
else
    OUT_LL="${EVAL_ONLY_LL}"
    echo "=== Skipping lift, evaluating existing: ${OUT_LL} ==="
fi

if [[ ! -f "${OUT_LL}" ]]; then
    echo "ERROR: .ll file not found: ${OUT_LL}"
    exit 1
fi

echo ""
echo "=== Running cmp evaluation ==="
EVAL_OUT="${OUT_DIR}/cmp_eval"
mkdir -p "${EVAL_OUT}"

python3 "${WORKSPACE_ROOT}/Runnable-Rewriting/runnable/scripts/validate_libcrypto_ground_truth.py" \
    cmp \
    --ll "${OUT_LL}" \
    --out-dir "${EVAL_OUT}" \
    --allow-low-metrics \
    2>&1 | tee "${OUT_DIR}/eval.log"

echo ""
echo "=== Results in: ${EVAL_OUT}/cmp.json ==="
if command -v jq &>/dev/null && [[ -f "${EVAL_OUT}/cmp.json" ]]; then
    jq '{precision, recall, hit, fn_count, fp_count}' "${EVAL_OUT}/cmp.json" 2>/dev/null || true
fi
