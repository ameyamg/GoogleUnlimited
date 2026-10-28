#!/usr/bin/env bash
# =====================================================================
# Comprehensive Test Runner: Unix / Linux (Bash)
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_FILES=(
    "test_readiness.sh"
    "test_creds.sh"
    "test_dedup.sh"
    "test_permissions.sh"
    "test_process_stop.sh"
    "test_upload_progress.sh"
    "test_upload_verification.sh"
    "test_watch_paths.sh"
)

TOTAL_PASSED=0
TOTAL_FAILED=0

echo "=========================================================="
echo "  GoogleUnlimited - Unix Regression Test Suite"
echo "=========================================================="

for test_name in "${TEST_FILES[@]}"; do
    test_path="$SCRIPT_DIR/$test_name"
    echo ""
    echo -e "\033[1;33m>>> Running: $test_name\033[0m"
    if bash "$test_path"; then
        TOTAL_PASSED=$((TOTAL_PASSED + 1))
    else
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        echo -e "\033[0;31mFAILED: $test_name\033[0m"
    fi
done

echo ""
echo "=========================================================="
echo "  FINAL SUMMARY: $TOTAL_PASSED Suites Passed, $TOTAL_FAILED Suites Failed"
echo "=========================================================="

if [ "$TOTAL_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
