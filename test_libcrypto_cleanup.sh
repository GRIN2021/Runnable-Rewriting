#!/bin/bash
# Test libcrypto.so with cleanup optimization
# This script runs runnable-lift on libcrypto and evaluates recall/precision

set -e

# Configuration
RUNNABLE_ROOT="/home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting"
BUILD_DIR="$RUNNABLE_ROOT/build-codex-dynamic-current"
LIBCRYPTO="/home/iskindar/Project/runnable-rewriting-project/GroudTruth/groundtruth-gap-analysis-skill/results/libcrypto-artifacts/libcrypto.so.3"
WORK_DIR="/tmp/libcrypto-test-$$"
BASE_ADDR="0x50000000"
ENTRY_POINT="0x500cef80"  # text_start entry point
PARALLEL_WORKERS=4
TIMEOUT_SEC=7200  # 2 hours

# Create work directory
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Set library path
export LD_LIBRARY_PATH="$BUILD_DIR/lib/StackAnalysis:$BUILD_DIR/lib/BasicAnalyses:$BUILD_DIR/lib/Support"

echo "======================================"
echo "libcrypto.so Cleanup Test"
echo "======================================"
echo "Binary: $LIBCRYPTO"
echo "Base: $BASE_ADDR"
echo "Entry: $ENTRY_POINT"
echo "Workers: $PARALLEL_WORKERS"
echo "Timeout: $TIMEOUT_SEC sec"
echo "Work dir: $WORK_DIR"
echo ""

# Phase 1: Test with auto cleanup (default mode)
echo "=== Phase 1: Default mode (auto cleanup) ==="
echo "Start: $(date)"
START_TIME=$(date +%s)

timeout $TIMEOUT_SEC $BUILD_DIR/tools/runnable-lift/runnable-lift \
  -base=$BASE_ADDR \
  -entry=$ENTRY_POINT \
  "$LIBCRYPTO" \
  libcrypto_auto.ll \
  -dynamic-parallel \
  -parallel-workers=$PARALLEL_WORKERS \
  -parallel-fragment-dir="$WORK_DIR/fragments_auto" \
  > auto_test.log 2>&1

EXIT_CODE=$?
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [ $EXIT_CODE -eq 124 ]; then
    echo "TIMEOUT after $DURATION seconds"
elif [ $EXIT_CODE -eq 0 ]; then
    echo "SUCCESS in $DURATION seconds"
else
    echo "FAILED with exit code $EXIT_CODE"
fi

# Check results
echo ""
echo "=== Auto cleanup results ==="
if [ -f libcrypto_auto.ll ]; then
    OUTPUT_SIZE=$(ls -lh libcrypto_auto.ll | awk '{print $5}')
    echo "Output file: $OUTPUT_SIZE"
    LINE_COUNT=$(wc -l < libcrypto_auto.ll)
    echo "Lines: $LINE_COUNT"
fi

WORKER_FILES=$(find fragments_auto -name 'worker_*.ll' 2>/dev/null | wc -l)
echo "Worker .ll files: $WORKER_FILES"
FRAG_SIZE=$(du -sh fragments_auto 2>/dev/null | cut -f1)
echo "Fragments dir: $FRAG_SIZE"

# Phase 2: Test with keep-worker-fragments
echo ""
echo "=== Phase 2: Keep-worker-fragments mode ==="
echo "Start: $(date)"
START_TIME=$(date +%s)

timeout $TIMEOUT_SEC $BUILD_DIR/tools/runnable-lift/runnable-lift \
  -base=$BASE_ADDR \
  -entry=$ENTRY_POINT \
  "$LIBCRYPTO" \
  libcrypto_keep.ll \
  -dynamic-parallel \
  -parallel-workers=$PARALLEL_WORKERS \
  -parallel-fragment-dir="$WORK_DIR/fragments_keep" \
  --keep-worker-fragments \
  > keep_test.log 2>&1

EXIT_CODE=$?
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [ $EXIT_CODE -eq 124 ]; then
    echo "TIMEOUT after $DURATION seconds"
elif [ $EXIT_CODE -eq 0 ]; then
    echo "SUCCESS in $DURATION seconds"
else
    echo "FAILED with exit code $EXIT_CODE"
fi

# Check results
echo ""
echo "=== Keep-worker-fragments results ==="
if [ -f libcrypto_keep.ll ]; then
    OUTPUT_SIZE=$(ls -lh libcrypto_keep.ll | awk '{print $5}')
    echo "Output file: $OUTPUT_SIZE"
    LINE_COUNT=$(wc -l < libcrypto_keep.ll)
    echo "Lines: $LINE_COUNT"
fi

WORKER_FILES=$(find fragments_keep -name 'worker_*.ll' 2>/dev/null | wc -l)
echo "Worker .ll files: $WORKER_FILES"
FRAG_SIZE=$(du -sh fragments_keep 2>/dev/null | cut -f1)
echo "Fragments dir: $FRAG_SIZE"

# Phase 3: Generate comparison files
echo ""
echo "=== Phase 3: Comparison ==="
echo "Generating objdump..."
objdump -d "$LIBCRYPTO" > libcrypto.obj 2>/dev/null
OBJ_LINES=$(wc -l < libcrypto.obj)
echo "Objdump lines: $OBJ_LINES"

# Phase 4: Calculate metrics
echo ""
echo "=== Summary ==="
echo "Auto mode worker files: $WORKER_FILES (expected: 0)"
echo "Keep mode worker files: $(find fragments_keep -name 'worker_*.ll' 2>/dev/null | wc -l)"

# Calculate disk savings
if [ -d fragments_keep ]; then
    KEEP_SIZE=$(du -sk fragments_keep | cut -f1)
    AUTO_SIZE=$(du -sk fragments_auto 2>/dev/null | cut -f1 || echo "0")
    SAVED=$((KEEP_SIZE - AUTO_SIZE))
    echo "Disk saved: ${SAVED}KB"
fi

echo ""
echo "Results saved in: $WORK_DIR"
echo "To cleanup: rm -rf $WORK_DIR"
