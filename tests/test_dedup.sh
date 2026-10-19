#!/usr/bin/env bash
# =====================================================================
# Regression Test Suite: BUG-05 (Cross-Platform Deduplication - Unix)
# =====================================================================
set -euo pipefail

TEMP_DIR="$(mktemp -d -t gotohp_test_dedup_XXXXXX)"
cleanup() {
    rm -rf "$TEMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

TEST_DB="$TEMP_DIR/test_gphotos.db"

echo "=========================================================="
echo "  TEST SUITE: BUG-05 Deduplication (Bash/Unix)"
echo "  Test DB: $TEST_DB"
echo "=========================================================="

sqlite3 "$TEST_DB" << 'EOF'
CREATE TABLE IF NOT EXISTS uploads (
    path         TEXT PRIMARY KEY,
    media_key    TEXT,
    uploaded_at  TEXT NOT NULL DEFAULT (datetime('now','localtime')),
    file_name    TEXT,
    file_size    INTEGER,
    content_hash TEXT
);
CREATE INDEX IF NOT EXISTS idx_uploads_file ON uploads(file_name, file_size);
CREATE INDEX IF NOT EXISTS idx_uploads_hash ON uploads(content_hash);
EOF

compute_hash() {
    local fpath="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$fpath" | awk '{print $1}'
    else
        shasum -a 256 "$fpath" | awk '{print $1}'
    fi
}

test_is_uploaded() {
    local fpath="$1"
    local fname
    fname="$(basename "$fpath")"
    local fsize
    fsize="$(stat -c%s "$fpath" 2>/dev/null || stat -f%z "$fpath" 2>/dev/null || echo 0)"
    local escaped_path="${fpath//\'/\'\'}"
    local escaped_name="${fname//\'/\'\'}"

    # 1. Exact path (with in-place modification verification)
    local exact_row
    exact_row=$(sqlite3 "$TEST_DB" <<EOF 2>/dev/null || true
SELECT file_size || '|' || COALESCE(content_hash, '') FROM uploads WHERE path = '$escaped_path' LIMIT 1;
EOF
)
    if [ -n "$exact_row" ]; then
        local prev_size="${exact_row%%|*}"
        local prev_hash="${exact_row#*|}"
        if [ "$prev_size" -gt 0 ] && [ "$fsize" -gt 0 ] && [ "$prev_size" -ne "$fsize" ]; then
            return 1
        fi
        if [ -n "$prev_hash" ]; then
            local cur_hash
            cur_hash="$(compute_hash "$fpath")"
            if [ -n "$cur_hash" ] && [ "$cur_hash" != "$prev_hash" ]; then
                return 1
            fi
        fi
        return 0
    fi

    # 2. Check candidate hash against records with matching name and size
    if [ "$fsize" -gt 0 ]; then
        local match_row
        match_row=$(sqlite3 "$TEST_DB" <<EOF 2>/dev/null || true
SELECT content_hash FROM uploads WHERE file_name = '$escaped_name' AND file_size = $fsize LIMIT 1;
EOF
)
        if [ -n "$match_row" ]; then
            local current_hash
            current_hash="$(compute_hash "$fpath")"
            local hash_match
            hash_match=$(sqlite3 "$TEST_DB" <<EOF 2>/dev/null || echo 0
SELECT COUNT(*) FROM uploads WHERE file_name = '$escaped_name' AND file_size = $fsize AND content_hash = '$current_hash';
EOF
)
            if [ "$hash_match" -gt 0 ]; then
                return 0
            fi
            # Legacy entry without content_hash
            local legacy_match
            legacy_match=$(sqlite3 "$TEST_DB" <<EOF 2>/dev/null || echo 0
SELECT COUNT(*) FROM uploads WHERE file_name = '$escaped_name' AND file_size = $fsize AND (content_hash IS NULL OR content_hash = '');
EOF
)
            if [ "$legacy_match" -gt 0 ]; then
                return 0
            fi
            return 1
        fi
    fi

    return 1
}

PASSED=0
FAILED=0

assert_result() {
    local name="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" -eq "$expected" ]; then
        echo -e "  \033[0;32m[PASS]\033[0m $name (Result: $actual)"
        PASSED=$((PASSED + 1))
    else
        echo -e "  \033[0;31m[FAIL]\033[0m $name (Expected: $expected, Got: $actual)"
        FAILED=$((FAILED + 1))
    fi
}

# Create File A (1024 bytes of 'A')
FILE_A="$TEMP_DIR/FolderA/photo.jpg"
mkdir -p "$TEMP_DIR/FolderA"
head -c 1024 < /dev/zero | tr '\0' 'A' > "$FILE_A"
HASH_A="$(compute_hash "$FILE_A")"

# Insert File A into test DB via heredoc
sqlite3 "$TEST_DB" <<EOF
INSERT INTO uploads(path, media_key, file_name, file_size, content_hash) VALUES ('${FILE_A//\'/\'\'}', 'KEY_A', 'photo.jpg', 1024, '$HASH_A');
EOF

# 1. Exact path
test_is_uploaded "$FILE_A" && res1=0 || res1=$?
assert_result "Exact path match returns 0 (duplicate)" "$res1" 0

# 2. File B with identical name, size, and content
FILE_B="$TEMP_DIR/FolderB/photo.jpg"
mkdir -p "$TEMP_DIR/FolderB"
head -c 1024 < /dev/zero | tr '\0' 'A' > "$FILE_B"
test_is_uploaded "$FILE_B" && res2=0 || res2=$?
assert_result "Identical content in different folder returns 0 (duplicate)" "$res2" 0

# 3. File C with SAME NAME, SAME SIZE, but DIFFERENT CONTENT (BUG-05)
FILE_C="$TEMP_DIR/FolderC/photo.jpg"
mkdir -p "$TEMP_DIR/FolderC"
head -c 1024 < /dev/zero | tr '\0' 'Z' > "$FILE_C"
test_is_uploaded "$FILE_C" && res3=0 || res3=$?
assert_result "Same name and size but different content returns 1 (NOT duplicate)" "$res3" 1

# 4. File A modified in-place with different size (CONF-04)
head -c 2048 < /dev/zero | tr '\0' 'A' > "$FILE_A"
test_is_uploaded "$FILE_A" && res4=0 || res4=$?
assert_result "Modified file with different size on same path returns 1 (NOT duplicate)" "$res4" 1

# 5. File A modified in-place with same size but different content (CONF-04)
head -c 1024 < /dev/zero | tr '\0' 'M' > "$FILE_A"
test_is_uploaded "$FILE_A" && res5=0 || res5=$?
assert_result "Modified file with same size but different content on same path returns 1 (NOT duplicate)" "$res5" 1

# 6. File A restored to original content: should return 0 (duplicate)
head -c 1024 < /dev/zero | tr '\0' 'A' > "$FILE_A"
test_is_uploaded "$FILE_A" && res6=0 || res6=$?
assert_result "Restored file with original content on same path returns 0 (duplicate)" "$res6" 0

# 7. File with double quotes in filename: vacation"photo.jpg (Finding 6)
FILE_QUOTE="$TEMP_DIR/FolderD/vacation\"photo.jpg"
mkdir -p "$TEMP_DIR/FolderD"
head -c 512 < /dev/zero | tr '\0' 'Q' > "$FILE_QUOTE"
HASH_QUOTE="$(compute_hash "$FILE_QUOTE")"
escaped_quote_path="${FILE_QUOTE//\'/\'\'}"
escaped_quote_name="$(basename "$FILE_QUOTE")"
escaped_quote_name="${escaped_quote_name//\'/\'\'}"
sqlite3 "$TEST_DB" <<EOF
INSERT INTO uploads(path, media_key, file_name, file_size, content_hash) VALUES ('$escaped_quote_path', 'KEY_Q', '$escaped_quote_name', 512, '$HASH_QUOTE');
EOF
test_is_uploaded "$FILE_QUOTE" && res7=0 || res7=$?
assert_result "File with double quote in name queries safely via heredoc (duplicate)" "$res7" 0

# 8. File with single quote in filename: mom's_photo.jpg (Finding 6)
FILE_APOS="$TEMP_DIR/FolderE/mom's_photo.jpg"
mkdir -p "$TEMP_DIR/FolderE"
head -c 512 < /dev/zero | tr '\0' 'S' > "$FILE_APOS"
HASH_APOS="$(compute_hash "$FILE_APOS")"
escaped_apos_path="${FILE_APOS//\'/\'\'}"
escaped_apos_name="$(basename "$FILE_APOS")"
escaped_apos_name="${escaped_apos_name//\'/\'\'}"
sqlite3 "$TEST_DB" <<EOF
INSERT INTO uploads(path, media_key, file_name, file_size, content_hash) VALUES ('$escaped_apos_path', 'KEY_S', '$escaped_apos_name', 512, '$HASH_APOS');
EOF
test_is_uploaded "$FILE_APOS" && res8=0 || res8=$?
assert_result "File with single quote in name queries safely via heredoc (duplicate)" "$res8" 0

echo "=========================================================="
echo "  RESULTS: $PASSED Passed, $FAILED Failed"
echo "=========================================================="

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
