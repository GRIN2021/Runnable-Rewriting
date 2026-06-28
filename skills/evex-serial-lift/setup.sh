#!/usr/bin/env bash
# Run this on the TARGET Ubuntu 24.04 machine.
# Installs system dependencies and extracts the artifact tarball.
#
# Usage:
#   ./setup.sh runnable-evex-artifacts.tar.gz [--install-dir ~/runnable-evex]

set -euo pipefail

TARBALL="${1:-}"
INSTALL_DIR="${HOME}/runnable-evex"

if [[ -z "${TARBALL}" ]]; then
    echo "Usage: $0 <artifacts.tar.gz> [--install-dir <dir>]"
    echo "  First run package.sh on the source machine to create the tarball."
    exit 1
fi
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

echo "=== Installing system dependencies ==="
sudo apt-get update -qq
sudo apt-get install -y \
    zlib1g \
    libzstd1 \
    libtinfo6 \
    libstdc++6 \
    python3 \
    binutils

echo ""
echo "=== Extracting artifacts to ${INSTALL_DIR} ==="
mkdir -p "${INSTALL_DIR}"
tar -xzf "${TARBALL}" -C "${INSTALL_DIR}" --strip-components=1

chmod +x "${INSTALL_DIR}/bin/runnable-lift"

echo ""
echo "=== Verifying ==="
ldd "${INSTALL_DIR}/bin/runnable-lift" | grep "not found" && {
    echo "ERROR: missing shared libraries (see above)"
    exit 1
} || echo "  runnable-lift: all deps resolved"

echo "  libtinycode: $(stat -c %s ${INSTALL_DIR}/lib/libtinycode-x86_64.so) bytes"
echo "  libcrypto.so.3: $(stat -c %s ${INSTALL_DIR}/ground-truth/libcrypto.so.3) bytes"
echo ""
echo "Setup complete. Install dir: ${INSTALL_DIR}"
echo ""
echo "Next steps:"
echo "  # Run serial lift (~40 min):"
echo "  ./lift.sh --install-dir ${INSTALL_DIR} --out-dir ~/evex-lift-out"
echo ""
echo "  # Evaluate recall:"
echo "  ./eval.sh --install-dir ${INSTALL_DIR} --ll ~/evex-lift-out/libcrypto.evex.serial.ll --out-dir ~/evex-eval-out"
