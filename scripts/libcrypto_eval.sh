#!/bin/bash
# Automation script to lift libcrypto.so and evaluate recall/precision
# Usage: bash libcrypto_eval.sh [start|status|eval]

set -e

# Configuration
RUNNABLE_ROOT="/home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting"
BUILD_DIR="$RUNNABLE_ROOT/build-codex-dynamic-current"
LIBCRYPTO="/home/iskindar/Project/runnable-rewriting-project/GroudTruth/groundtruth-gap-analysis-skill/results/libcrypto-artifacts/libcrypto.so.3"
WORK_DIR="/hdd/runnable-runs/runs/libcrypto-eval-$(date +%s)"
BASE_ADDR="0x50000000"
ENTRY_POINT="0x500cef80"  # text_start entry point
PARALLEL_WORKERS=4
LIFT_TIMEOUT_SEC=7200  # 2 hours for lifting

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
}

# Phase 1: Lift libcrypto with cleanup optimization
phase1_lift() {
    log "=== Phase 1: Lifting libcrypto.so ==="
    log "Binary: $LIBCRYPTO"
    log "Base: $BASE_ADDR"
    log "Entry: $ENTRY_POINT"
    log "Work dir: $WORK_DIR"

    mkdir -p "$WORK_DIR/raw"
    cd "$WORK_DIR"

    # Set library path
    export LD_LIBRARY_PATH="$BUILD_DIR/lib/StackAnalysis:$BUILD_DIR/lib/BasicAnalyses:$BUILD_DIR/lib/Support"

    log "Starting runnable-lift (timeout: ${LIFT_TIMEOUT_SEC}s)..."
    START_TIME=$(date +%s)

    timeout $LIFT_TIMEOUT_SEC $BUILD_DIR/tools/runnable-lift/runnable-lift \
      -base=$BASE_ADDR \
      -entry=$ENTRY_POINT \
      "$LIBCRYPTO" \
      raw/libcrypto.ll \
      -dynamic-parallel \
      -parallel-workers=$PARALLEL_WORKERS \
      -parallel-fragment-dir="$WORK_DIR/fragments" \
      > lift.log 2>&1

    EXIT_CODE=$?
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    if [ $EXIT_CODE -eq 124 ]; then
        error "TIMEOUT after $DURATION seconds"
        return 1
    elif [ $EXIT_CODE -eq 0 ]; then
        log "SUCCESS in $DURATION seconds"
    else
        error "FAILED with exit code $EXIT_CODE"
        tail -20 lift.log
        return 1
    fi

    # Check output
    if [ -f raw/libcrypto.ll ]; then
        OUTPUT_SIZE=$(ls -lh raw/libcrypto.ll | awk '{print $5}')
        LINE_COUNT=$(wc -l < raw/libcrypto.ll)
        log "Output file: $OUTPUT_SIZE ($LINE_COUNT lines)"
    else
        error "Output file not generated"
        return 1
    fi

    # Check cleanup - should have NO worker files
    WORKER_FILES=$(find fragments -name 'worker_*.ll' 2>/dev/null | wc -l)
    if [ $WORKER_FILES -eq 0 ]; then
        log "Cleanup verified: 0 worker fragment files (disk saved)"
    else
        warn "Found $WORKER_FILES worker files (cleanup may not be working)"
    fi

    return 0
}

# Phase 2: Generate objdump for comparison
phase2_objdump() {
    log ""
    log "=== Phase 2: Generating objdump ==="
    cd "$WORK_DIR"

    log "Running objdump on libcrypto.so..."
    objdump -d "$LIBCRYPTO" > raw/libcrypto.obj 2>/dev/null

    OBJ_LINES=$(wc -l < raw/libcrypto.obj)
    log "Objdump generated: $OBJ_LINES lines"

    return 0
}

# Phase 3: Compare and generate metrics
phase3_eval() {
    log ""
    log "=== Phase 3: Evaluation (recall/precision) ==="
    cd "$WORK_DIR"

    export LD_LIBRARY_PATH="$BUILD_DIR/lib/StackAnalysis:$BUILD_DIR/lib/BasicAnalyses:$BUILD_DIR/lib/Support"

    # Run comparison
    log "Running cmp_instruction.py..."
    python3 $RUNNABLE_ROOT/test/cmp_instruction.py raw/libcrypto > eval.log 2>&1

    if [ -f raw/libcrypto.result ]; then
        log "Result file generated: raw/libcrypto.result"

        # Extract key metrics
        SUCCESS=$(grep "Success count:" raw/libcrypto.result | cut -d':' -f2 | xargs)
        NOT_FOUND=$(grep "Not found count:" raw/libcrypto.result | head -1 | cut -d':' -f2 | xargs)
        OBJ_COUNT=$(grep "OBJDump file Ins count:" raw/libcrypto.result | cut -d':' -f2 | xargs)
        LL_COUNT=$(grep ".ll file Ins count:" raw/libcrypto.result | cut -d':' -f2 | xargs)

        log "=== Results ==="
        log "Ground truth (objdump): $OBJ_COUNT instructions"
        log "Lifted (.ll): $LL_COUNT instructions"
        log "True Positives: $SUCCESS"
        log "False Negatives (not found): $NOT_FOUND"

        # Calculate metrics
        if [ -n "$SUCCESS" ] && [ -n "$OBJ_COUNT" ] && [ "$OBJ_COUNT" -gt 0 ]; then
            RECALL=$(echo "scale=2; $SUCCESS * 100 / $OBJ_COUNT" | bc)
            log "Recall: ${RECALL}%"
        fi

        # Generate formatted result
        mkdir -p results
        python3 $RUNNABLE_ROOT/test/generate_result.py raw -o results/libcrypto_metrics.csv

        if [ -f results/libcrypto_metrics.csv ]; then
            log ""
            log "=== Final Metrics ==="
            cat results/libcrypto_metrics.csv
            log ""
            log "Full results in: $WORK_DIR/results/libcrypto_metrics.csv"
        fi
    else
        error "Evaluation failed - no result file generated"
        cat eval.log
        return 1
    fi

    return 0
}

# Main command dispatcher
case "${1:-start}" in
    start)
        log "Starting libcrypto evaluation pipeline..."
        phase1_lift || exit 1
        phase2_objdump || exit 1
        phase3_eval || exit 1
        log ""
        log "=== Evaluation Complete ==="
        log "Work directory: $WORK_DIR"
        ;;
    status)
        if [ -d "$WORK_DIR" ]; then
            echo "Work dir: $WORK_DIR"
            echo "Files:"
            ls -lh "$WORK_DIR/raw/" 2>/dev/null || echo "No raw files yet"
        else
            echo "No work directory found"
        fi
        ;;
    eval)
        if [ -d "$WORK_DIR/raw" ]; then
            phase2_objdump || exit 1
            phase3_eval || exit 1
        else
            error "No raw files found. Run 'start' first."
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {start|status|eval}"
        echo "  start  - Run full pipeline (lift + eval)"
        echo "  status - Check current status"
        echo "  eval   - Run evaluation only (requires lift to be done)"
        exit 1
        ;;
esac
