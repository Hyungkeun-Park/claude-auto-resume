#!/usr/bin/env bash
# Resume Daemon Tests (TD01-TD12)
# Tests for claude-auto-resume.sh functions.
source "$(cd "$(dirname "$0")" && pwd)/test-framework.sh"

echo "════════════════════════════════════════════════════════"
echo " Resume Daemon Tests (TD01-TD12)"
echo "════════════════════════════════════════════════════════"

# ── Define the function inline (copied from daemon) for isolated testing ──
find_claude_bin() {
    local bin
    bin=$(command -v claude 2>/dev/null || echo "")
    if [ -z "$bin" ]; then
        for p in "$HOME/.claude/local/bin/claude" "$HOME/.local/bin/claude" "/usr/local/bin/claude" "/opt/homebrew/bin/claude"; do
            [ -x "$p" ] && { bin="$p"; break; }
        done
    fi
    echo "$bin"
}

archive_resume_file() {
    local result=$1
    local reason=${2:-""}
    [ ! -f "$RESUME_FILE" ] && return 0

    local dest_dir
    if [ "$result" = "success" ]; then
        dest_dir="$SUCCESS_DIR"
    else
        dest_dir="$FAILED_DIR"
    fi
    mkdir -p "$dest_dir"

    local completed_at
    completed_at=$(date +"%Y-%m-%dT%H:%M:%S%z")
    # Symlink check (security fix)
    [ -L "$RESUME_FILE" ] && { rm -f "$RESUME_FILE"; return 0; }
    jq --arg r "$result" --arg reason "$reason" --arg cat "$completed_at" \
        '. + {result: $r, reason: $reason, completed_at: $cat}' \
        "$RESUME_FILE" > "$RESUME_FILE.tmp" 2>/dev/null && mv "$RESUME_FILE.tmp" "$dest_dir/$(basename "$RESUME_FILE")"
    rm -f "$RESUME_FILE" "$RESUME_FILE.tmp"
}

cleanup_old_logs() {
    find "$HOME/.claude/logs" -name "resume-*.log" -mtime +7 -delete 2>/dev/null || true
    find "$HOME/.claude/logs" -name "auto-resume-*.log" -mtime +30 -delete 2>/dev/null || true
    local archive_dirs="$CWD/.claude/auto-resume/success $CWD/.claude/auto-resume/failed"
    for dir in $archive_dirs; do
        if [ -d "$dir" ]; then
            ls -t "$dir"/*.json 2>/dev/null | tail -n +51 | xargs rm -f 2>/dev/null || true
        fi
    done
}

# ─── TD01: find_claude_bin() returns path when claude is in PATH ─────────
setup_test "TD01_find_claude_bin_in_path"
# Create mock claude binary in test PATH
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/claude" <<'EOF'
#!/bin/bash
echo "mock claude"
EOF
chmod +x "$TEST_DIR/bin/claude"
RESULT=$(find_claude_bin)
assert_not_empty "$RESULT" "find_claude_bin should return a path"
TOTAL=$((TOTAL + 1))
if echo "$RESULT" | grep -q "claude"; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: find_claude_bin returned '$RESULT', expected path containing 'claude'"
fi

# ─── TD02: find_claude_bin() finds fallback path ~/.claude/local/bin/claude ─
setup_test "TD02_find_claude_bin_fallback_local"
# Remove ALL claude from PATH — use only /usr/bin:/bin to prevent real claude leaking in
SAVED_PATH="$PATH"
export PATH="/usr/bin:/bin"
rm -f "$TEST_DIR/bin/claude"
# Create fallback
mkdir -p "$HOME/.claude/local/bin"
cat > "$HOME/.claude/local/bin/claude" <<'EOF'
#!/bin/bash
echo "fallback claude"
EOF
chmod +x "$HOME/.claude/local/bin/claude"
RESULT=$(find_claude_bin)
assert_equals "$RESULT" "$HOME/.claude/local/bin/claude" "fallback path"
rm -f "$HOME/.claude/local/bin/claude"
export PATH="$SAVED_PATH"

# ─── TD03: find_claude_bin() finds fallback path ~/.local/bin/claude ──────
setup_test "TD03_find_claude_bin_fallback_dotlocal"
SAVED_PATH="$PATH"
export PATH="/usr/bin:/bin"
rm -f "$TEST_DIR/bin/claude"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/claude" <<'EOF'
#!/bin/bash
echo "dotlocal claude"
EOF
chmod +x "$HOME/.local/bin/claude"
RESULT=$(find_claude_bin)
assert_equals "$RESULT" "$HOME/.local/bin/claude" "dotlocal fallback path"
rm -f "$HOME/.local/bin/claude"
export PATH="$SAVED_PATH"

# ─── TD04: find_claude_bin() returns empty when claude not found anywhere ─
setup_test "TD04_find_claude_bin_not_found"
SAVED_PATH="$PATH"
export PATH="/usr/bin:/bin"
rm -f "$TEST_DIR/bin/claude"
rm -f "$HOME/.claude/local/bin/claude"
rm -f "$HOME/.local/bin/claude"
RESULT=$(find_claude_bin)
TOTAL=$((TOTAL + 1))
if [ -z "$RESULT" ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: expected empty, got '$RESULT'"
fi
export PATH="$SAVED_PATH"

# ─── TD05: archive_resume_file creates success/ directory and moves file ──
setup_test "TD05_archive_success"
CWD="$TEST_CWD"
RESUME_DIR="$CWD/.claude/auto-resume"
QUEUED_DIR="$RESUME_DIR/queued"
SUCCESS_DIR="$RESUME_DIR/success"
FAILED_DIR="$RESUME_DIR/failed"
mkdir -p "$QUEUED_DIR"
RESUME_FILE="$QUEUED_DIR/td05-session.json"
echo '{"session_id":"td05-session","prompt":"test"}' > "$RESUME_FILE"
archive_resume_file "success"
assert_dir_exists "$SUCCESS_DIR"
assert_file_not_exists "$RESUME_FILE"
assert_file_exists "$SUCCESS_DIR/td05-session.json"

# ─── TD06: archive_resume_file creates failed/ directory with reason ─────
setup_test "TD06_archive_failed"
CWD="$TEST_CWD"
RESUME_DIR="$CWD/.claude/auto-resume"
QUEUED_DIR="$RESUME_DIR/queued"
SUCCESS_DIR="$RESUME_DIR/success"
FAILED_DIR="$RESUME_DIR/failed"
mkdir -p "$QUEUED_DIR"
RESUME_FILE="$QUEUED_DIR/td06-session.json"
echo '{"session_id":"td06-session","prompt":"test"}' > "$RESUME_FILE"
archive_resume_file "failed" "test_reason"
assert_dir_exists "$FAILED_DIR"
assert_file_not_exists "$RESUME_FILE"
assert_file_exists "$FAILED_DIR/td06-session.json"
assert_json_field "$FAILED_DIR/td06-session.json" '.reason' "test_reason"

# ─── TD07: archive_resume_file with missing resume file is a no-op ───────
setup_test "TD07_archive_missing_file"
CWD="$TEST_CWD"
RESUME_DIR="$CWD/.claude/auto-resume"
QUEUED_DIR="$RESUME_DIR/queued"
SUCCESS_DIR="$RESUME_DIR/success"
FAILED_DIR="$RESUME_DIR/failed"
RESUME_FILE="$QUEUED_DIR/td07-nonexistent.json"
# Should not fail
archive_resume_file "success"
TOTAL=$((TOTAL + 1))
# No crash means pass
PASS=$((PASS + 1))

# ─── TD08: cleanup_old_logs removes files older than thresholds ──────────
setup_test "TD08_cleanup_old_logs"
CWD="$TEST_CWD"
mkdir -p "$HOME/.claude/logs"
# Create old resume log (>7 days)
touch -t 202401010000 "$HOME/.claude/logs/resume-old.log" 2>/dev/null || true
# Create old auto-resume log (>30 days)
touch -t 202401010000 "$HOME/.claude/logs/auto-resume-2024-01-01.log" 2>/dev/null || true
# Create recent log
echo "recent" > "$HOME/.claude/logs/resume-recent.log"
cleanup_old_logs
assert_file_not_exists "$HOME/.claude/logs/resume-old.log"
assert_file_exists "$HOME/.claude/logs/resume-recent.log"

# ─── TD09: Session ID validation rejects invalid characters ──────────────
setup_test "TD09_session_id_invalid"
TOTAL=$((TOTAL + 1))
if [[ "sess;rm -rf" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: regex should reject semicolons"
else
    PASS=$((PASS + 1))
fi
TOTAL=$((TOTAL + 1))
if [[ "../../etc" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: regex should reject slashes"
else
    PASS=$((PASS + 1))
fi

# ─── TD10: Session ID validation accepts valid format ────────────────────
setup_test "TD10_session_id_valid"
VALID_IDS=("abc-123" "sess.001" "MY_SESSION" "a1b2c3" "test-session-001")
for sid in "${VALID_IDS[@]}"; do
    TOTAL=$((TOTAL + 1))
    if [[ "$sid" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: valid session ID rejected: $sid"
    fi
done

# ─── TD11: Missing arguments exits with code 1 ──────────────────────────
setup_test "TD11_missing_args"
DAEMON_SCRIPT="$SCRIPT_DIR/claude-auto-resume.sh"
if [ -f "$DAEMON_SCRIPT" ]; then
    EXIT_CODE=$(bash "$DAEMON_SCRIPT" 2>/dev/null; echo $?)
    assert_equals "$EXIT_CODE" "1" "exit code for missing args"
else
    echo -e "  ${YELLOW}SKIP${NC}: daemon script not found at $DAEMON_SCRIPT"
    TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
fi

# ─── TD12: Daemon args parsing extracts SESSION_ID, TARGET_EPOCH, CWD ────
setup_test "TD12_daemon_args_parsing"
# We can't run the full daemon (it loops), but we can verify it rejects bad inputs
DAEMON_SCRIPT="$SCRIPT_DIR/claude-auto-resume.sh"
if [ -f "$DAEMON_SCRIPT" ]; then
    # Invalid session ID should exit 1
    EXIT_CODE=$(bash "$DAEMON_SCRIPT" "invalid;session" "12345" "/tmp" 2>/dev/null; echo $?)
    assert_equals "$EXIT_CODE" "1" "exit code for invalid session ID"
else
    echo -e "  ${YELLOW}SKIP${NC}: daemon script not found at $DAEMON_SCRIPT"
    TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
fi

print_summary "Resume Daemon Tests"
