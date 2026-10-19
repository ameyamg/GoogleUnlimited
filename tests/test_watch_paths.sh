#!/usr/bin/env bash
# Regression tests for safe Unix watch_dirs.txt path expansion.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../google-unlimited.sh
source "$REPO_DIR/google-unlimited.sh"

PASSED=0
FAILED=0

assert_equal() {
    local name="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "[PASS] $name"
        PASSED=$((PASSED + 1))
    else
        echo "[FAIL] $name: expected '$expected', got '$actual'"
        FAILED=$((FAILED + 1))
    fi
}

export WATCH_PATH_TEST_ROOT="/tmp/Google Photos"
assert_equal '\$VAR expansion' \
    "$(expand_watch_path '$WATCH_PATH_TEST_ROOT/Album')" \
    "/tmp/Google Photos/Album"
assert_equal '\${VAR} expansion' \
    "$(expand_watch_path '${WATCH_PATH_TEST_ROOT}/Album')" \
    "/tmp/Google Photos/Album"
assert_equal 'leading ~ expansion' \
    "$(expand_watch_path '~/Pictures')" \
    "$HOME/Pictures"
assert_equal 'multiple variables' \
    "$(expand_watch_path '$WATCH_PATH_TEST_ROOT/${USER}')" \
    "/tmp/Google Photos/${USER}"
assert_equal 'unknown variable remains literal' \
    "$(expand_watch_path '$GOOGLE_UNLIMITED_UNDEFINED/Album')" \
    '$GOOGLE_UNLIMITED_UNDEFINED/Album'
assert_equal 'shell syntax is not executed' \
    "$(expand_watch_path '$(touch /tmp/should-not-exist)')" \
    '$(touch /tmp/should-not-exist)'

echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
