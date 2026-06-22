#!/bin/bash
# Monitor libcrypto evaluation progress
WORK_DIR="${1:-/hdd/runnable-runs/runs/libcrypto-eval-1780155895}"

echo "=== Libcrypto Evaluation Monitor ==="
echo "Work dir: $WORK_DIR"
echo ""

if [ ! -d "$WORK_DIR" ]; then
    echo "ERROR: Work directory not found"
    exit 1
fi

# Check if process is still running
RUNNABLE_PID=$(pgrep -f "runnable-lift.*libcrypto" | head -1)
if [ -n "$RUNNABLE_PID" ]; then
    echo "Status: RUNNING (PID: $RUNNABLE_PID)"
    # Get elapsed time
    ELAPSED=$(ps -p $RUNNABLE_PID -o etimes= | xargs)
    MINUTES=$((ELAPSED / 60))
    SECONDS=$((ELAPSED % 60))
    echo "Elapsed: ${MINUTES}m ${SECONDS}s"
else
    echo "Status: COMPLETED or NOT RUNNING"
fi

echo ""

# Check lift progress
if [ -f "$WORK_DIR/lift.log" ]; then
    LIFT_SIZE=$(du -h "$WORK_DIR/lift.log" | cut -f1)
    echo "Lift log size: $LIFT_SIZE"

    # Count discovered branches (Branch targets total numbers)
    BRANCH_COUNT=$(grep -c "Branch targets total numbers:" "$WORK_DIR/lift.log" 2>/dev/null || echo "0")
    echo "Basic blocks processed: $BRANCH_COUNT"
fi

# Check fragments
if [ -d "$WORK_DIR/fragments" ]; then
    FRAG_SIZE=$(du -sh "$WORK_DIR/fragments" | cut -f1)
    echo "Fragment dir: $FRAG_SIZE"
fi

# Check if output exists
if [ -f "$WORK_DIR/raw/libcrypto.ll" ]; then
    LL_SIZE=$(du -h "$WORK_DIR/raw/libcrypto.ll" | cut -f1)
    LL_LINES=$(wc -l < "$WORK_DIR/raw/libcrypto.ll")
    echo "Output file: $LL_SIZE ($LL_LINES lines)"
fi

echo ""
echo "Tail of lift.log:"
tail -5 "$WORK_DIR/lift.log" 2>/dev/null
