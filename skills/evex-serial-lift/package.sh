#!/usr/bin/env bash
# Run this on the SOURCE machine to package all artifacts needed for the serial lift.
# Output: runnable-evex-artifacts.tar.gz in the current directory (or --out <path>).
#
# Usage:
#   ./package.sh
#   ./package.sh --out /tmp/artifacts.tar.gz
#   ./package.sh --shared-install-dir /path/to/shared-install --gt-dir /path/to/ground-truth
#
# Environment overrides (alternative to flags):
#   RUNNABLE_SHARED_INSTALL   path to shared-install-runnable directory
#   RUNNABLE_GT_DIR           path to directory containing libcrypto.so.3 and libcrypto.gtBlock.pb

set -euo pipefail

# Defaults — override via env or flags
SI="${RUNNABLE_SHARED_INSTALL:-/hdd/runnable-libcrypto-dynamic-parallel-optimized/shared-install-runnable}"
GT_DIR="${RUNNABLE_GT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)/GroudTruth/groundtruth-gap-analysis-skill/results/libcrypto-artifacts}"

OUT="runnable-evex-artifacts.tar.gz"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)                OUT="$2";    shift 2 ;;
        --shared-install-dir) SI="$2";     shift 2 ;;
        --gt-dir)             GT_DIR="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

echo "=== Packaging runnable EVEX artifacts ==="
echo "shared-install : ${SI}"
echo "ground truth   : ${GT_DIR}"
echo "output         : ${OUT}"
echo ""

STAGING=$(mktemp -d)
trap "rm -rf ${STAGING}" EXIT

PKG="${STAGING}/runnable-evex-artifacts"
mkdir -p "${PKG}/bin" \
         "${PKG}/lib/runnable/analyses" \
         "${PKG}/share/runnable" \
         "${PKG}/ground-truth"

# runnable-lift binary (statically linked LLVM 18, Ubuntu 24.04)
cp "${SI}/bin/runnable-lift"          "${PKG}/bin/"

# EVEX libtinycode + helpers (4.4 MB self-contained QEMU v2 backend)
cp "${SI}/lib/libtinycode-x86_64.so"         "${PKG}/lib/"
cp "${SI}/lib/libtinycode-helpers-x86_64.ll" "${PKG}/lib/"

# runnable shared libraries (loaded via RPATH relative to runnable-lift)
cp "${SI}/lib/librunnableSupport.so"                           "${PKG}/lib/"
cp "${SI}/lib/runnable/analyses/librunnableStackAnalysis.so"   "${PKG}/lib/runnable/analyses/"
cp "${SI}/lib/runnable/analyses/librunnableBasicAnalyses.so"   "${PKG}/lib/runnable/analyses/"
cp "${SI}/lib/runnable/analyses/librunnableDump.so"            "${PKG}/lib/runnable/analyses/"
cp "${SI}/lib/runnable/analyses/librunnableFunctionIsolation.so" "${PKG}/lib/runnable/analyses/"

# evaluation helper scripts (pure Python, stdlib only)
for f in validate_libcrypto_ground_truth.py \
          run_cmp_eval.py \
          _compare_runnable_text_lib.py \
          _fn_fp_root_cause_lib.py \
          libcrypto_bench_paths.py; do
    cp "${SI}/share/runnable/${f}" "${PKG}/share/runnable/"
done

# ground truth assets
cp "${GT_DIR}/libcrypto.so.3"      "${PKG}/ground-truth/"
cp "${GT_DIR}/libcrypto.gtBlock.pb" "${PKG}/ground-truth/"

echo "Files included:"
find "${PKG}" -type f | sort | while read f; do
    printf "  %-60s %s\n" "${f#${PKG}/}" "$(du -sh "$f" | cut -f1)"
done

tar -czf "${OUT}" -C "${STAGING}" runnable-evex-artifacts
echo ""
echo "Done: $(du -sh ${OUT} | cut -f1)  ${OUT}"
echo "Transfer to target machine with:"
echo "  scp ${OUT} user@target-host:~/"
