#!/usr/bin/env bash
# Run serial EVEX lift on libcrypto.so.3.
# Expected: ~40 minutes, rc=0, precision=0.987, recall=0.928.
#
# Usage:
#   ./lift.sh --install-dir ~/runnable-evex --out-dir ~/evex-lift-out

set -euo pipefail

INSTALL_DIR="${HOME}/runnable-evex"
OUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --out-dir)     OUT_DIR="$2";     shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "${OUT_DIR}" ]]; then
    echo "Usage: $0 --install-dir <dir> --out-dir <dir>"
    exit 1
fi

BINARY="${INSTALL_DIR}/ground-truth/libcrypto.so.3"
RUNNABLE_LIFT="${INSTALL_DIR}/bin/runnable-lift"
OUT_LL="${OUT_DIR}/libcrypto.evex.serial.ll"

if [[ ! -f "${BINARY}" ]]; then
    echo "ERROR: libcrypto.so.3 not found at ${BINARY}"
    echo "  Run setup.sh first."
    exit 1
fi

mkdir -p "${OUT_DIR}"

export LD_LIBRARY_PATH="${INSTALL_DIR}/lib:${INSTALL_DIR}/lib/runnable/analyses${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

echo "=== Serial EVEX lift ==="
echo "runnable-lift : ${RUNNABLE_LIFT} ($(stat -c %s ${RUNNABLE_LIFT}) bytes)"
echo "libtinycode   : ${INSTALL_DIR}/lib/libtinycode-x86_64.so ($(stat -c %s ${INSTALL_DIR}/lib/libtinycode-x86_64.so) bytes)"
echo "binary        : ${BINARY}"
echo "output        : ${OUT_LL}"
echo "entry         : 0x500cef80 (base=0x50000000 + text_start=0xcef80)"
echo "expected      : ~40 min, precision=0.987, recall=0.928"
echo ""

START=$(date +%s)
echo "[$(date --iso-8601=seconds)] START"

"${RUNNABLE_LIFT}" "${BINARY}" "${OUT_LL}" \
    -base=0x50000000 \
    -entry=0x500cef80 \
    -use-debug-symbols \
    -no-link \
    > "${OUT_DIR}/lift.stdout" 2> "${OUT_DIR}/lift.stderr"

rc=$?
END=$(date +%s)
ELAPSED=$(( END - START ))
echo "[$(date --iso-8601=seconds)] END rc=${rc} elapsed=${ELAPSED}s"
echo "${rc}" > "${OUT_DIR}/lift.rc"

if [[ $rc -eq 0 && -s "${OUT_LL}" ]]; then
    SIZE=$(stat -c %s "${OUT_LL}")
    LINES=$(wc -l < "${OUT_LL}")
    echo "LL_OK size=${SIZE} lines=${LINES}"
    echo ""
    echo "Lift done. Run eval:"
    echo "  ./eval.sh --install-dir ${INSTALL_DIR} --ll ${OUT_LL} --out-dir ${OUT_DIR}/cmp_eval"
else
    echo "LL_FAIL — stderr:"
    tail -10 "${OUT_DIR}/lift.stderr"
    exit 1
fi
