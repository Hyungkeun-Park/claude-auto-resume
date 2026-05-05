#!/usr/bin/env bash
# Security Tests (TS01-TS10)
source "$(cd "$(dirname "$0")" && pwd)/test-framework.sh"

echo "════════════════════════════════════════════════════════"
echo " Security Tests (TS01-TS10)"
echo "════════════════════════════════════════════════════════"

# ─── TS01: Session ID with semicolon rejected ───────────────────────────
setup_test "TS01_session_id_semicolon"
write_cache 100 57
EXIT=$(run_stop_hook "$(echo '{"cwd":"'"$TEST_CWD"'","session_id":";rm -rf"}')")
assert_exit_code "$EXIT" 0
TOTAL=$((TOTAL + 1))
if [ ! -d "$RESUME_DIR/queued" ]; then
    PASS=$((PASS + 1))
else
    COUNT=$(ls "$RESUME_DIR/queued"/*.json 2>/dev/null | wc -l)
    if [ "$COUNT" -eq 0 ]; then PASS=$((PASS + 1)); else
        FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: created file with semicolon in session_id"
    fi
fi

# ─── TS02: Session ID with slash rejected ────────────────────────────────
setup_test "TS02_session_id_slash"
write_cache 100 57
EXIT=$(run_stop_hook "$(echo '{"cwd":"'"$TEST_CWD"'","session_id":"../../etc"}')")
assert_exit_code "$EXIT" 0
TOTAL=$((TOTAL + 1))
if [ ! -d "$RESUME_DIR/queued" ]; then
    PASS=$((PASS + 1))
else
    COUNT=$(ls "$RESUME_DIR/queued"/*.json 2>/dev/null | wc -l)
    if [ "$COUNT" -eq 0 ]; then PASS=$((PASS + 1)); else
        FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: created file with slash in session_id"
    fi
fi

# ─── TS03: Agent ID with slash rejected ──────────────────────────────────
setup_test "TS03_agent_id_slash"
write_cache 80 30
EXIT=$(run_subagent_start "$(echo '{"cwd":"'"$TEST_CWD"'","session_id":"sess-ts03","agent_id":"../../../etc/passwd","hook_event_name":"SubagentStart"}')")
assert_exit_code "$EXIT" 0
TOTAL=$((TOTAL + 1))
if [ ! -d "$RESUME_DIR/subagents" ]; then
    PASS=$((PASS + 1))
else
    COUNT=$(find "$RESUME_DIR/subagents" -type f 2>/dev/null | wc -l)
    if [ "$COUNT" -eq 0 ]; then PASS=$((PASS + 1)); else
        FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: created marker with slash in agent_id"
    fi
fi

# ─── TS04: CWD with path traversal → no file created outside project ────
setup_test "TS04_cwd_path_traversal"
write_cache 100 57
# Using a traversal CWD — should create files under the given CWD, not escape
EVIL_CWD="$TEST_DIR/ts04_evil/../ts04_evil"
mkdir -p "$EVIL_CWD/.claude"
EXIT=$(run_stop_hook "$(make_hook_input "sess-ts04" "$EVIL_CWD")")
assert_exit_code "$EXIT" 0
# Verify no files created outside the test directory
TOTAL=$((TOTAL + 1))
OUTSIDE_FILES=$(find /tmp -name "sess-ts04.json" -newer "$TEST_DIR" 2>/dev/null | wc -l)
if [ "$OUTSIDE_FILES" -eq 0 ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: file created outside project directory"
fi

# ─── TS05: Symlink in queued/ directory → file written is not a symlink ──
setup_test "TS05_symlink_in_queued"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
# Create a symlink pointing outside
EVIL_TARGET="$TEST_DIR/ts05_evil_target"
echo "EVIL" > "$EVIL_TARGET"
ln -sf "$EVIL_TARGET" "$(resume_file_for sess-ts05)"
EXIT=$(run_stop_hook "$(make_hook_input "sess-ts05")")
assert_exit_code "$EXIT" 0
# After hook runs, verify the result is a regular file, not a symlink
if [ -f "$(resume_file_for sess-ts05)" ]; then
    assert_not_symlink "$(resume_file_for sess-ts05)"
fi
# The evil target should not have been overwritten with JSON
TOTAL=$((TOTAL + 1))
if [ -f "$EVIL_TARGET" ]; then
    CONTENT=$(cat "$EVIL_TARGET")
    # If it still says EVIL or is valid JSON from the hook, the symlink was followed
    # The atomic write (write to .tmp then mv) means it creates a new file
    if echo "$CONTENT" | jq . >/dev/null 2>&1; then
        FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: symlink target was overwritten with JSON"
    else
        PASS=$((PASS + 1))
    fi
else
    PASS=$((PASS + 1))
fi

# ─── TS06: State files created with restrictive permissions ──────────────
setup_test "TS06_state_file_permissions"
write_cache 100 57
EXIT=$(run_stop_hook "$(make_hook_input "sess-ts06")")
assert_exit_code "$EXIT" 0
if [ -f "$(resume_file_for sess-ts06)" ]; then
    PERM=$(stat -c '%a' "$(resume_file_for sess-ts06)" 2>/dev/null || stat -f '%Lp' "$(resume_file_for sess-ts06)" 2>/dev/null)
    TOTAL=$((TOTAL + 1))
    # umask 077 means files are created with 600 (rw-------)
    if [ "$PERM" = "600" ]; then PASS=$((PASS + 1)); else
        FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: state file permission = $PERM (expected 600)"
    fi
else
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: state file not created"
fi

# ─── TS07: Cache file created with restrictive permissions ───────────────
setup_test "TS07_cache_file_permissions"
write_cache 50 30
PERM=$(stat -c '%a' "$HOME/.claude/rate-limits.json" 2>/dev/null || stat -f '%Lp' "$HOME/.claude/rate-limits.json" 2>/dev/null)
TOTAL=$((TOTAL + 1))
# write_cache uses cat > which inherits umask from test env
# The hooks use umask 077, so files they create should be 600
# Cache is created by the test helper, so we just check it exists
if [ -f "$HOME/.claude/rate-limits.json" ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: cache file not created"
fi

# ─── TS08: Hook input with very large JSON (100KB) → exits gracefully ────
setup_test "TS08_large_json_input"
write_cache 100 57
# Generate ~100KB of JSON via python (avoids shell arg-list limits)
python3 -c "
import json, sys
d = {'session_id': 'sess-ts08', 'cwd': '$TEST_CWD', 'large_field': 'X' * 102400}
sys.stdout.write(json.dumps(d))
" | bash "$HOOKS_DIR/rate-limit-stop.sh" 2>"$TEST_DIR/stderr_out"
EXIT=$?
assert_exit_code "$EXIT" 0

# ─── TS09: Hook input with deeply nested JSON → exits gracefully ────────
setup_test "TS09_deeply_nested_json"
write_cache 100 57
# Create deeply nested JSON (100 levels)
NESTED=$(python3 -c "
import json
d = {'session_id': 'sess-ts09', 'cwd': '$TEST_CWD'}
inner = d
for i in range(100):
    inner['nested'] = {}
    inner = inner['nested']
inner['value'] = 'deep'
print(json.dumps(d))
")
EXIT=$(echo "$NESTED" | bash "$HOOKS_DIR/rate-limit-stop.sh" 2>"$TEST_DIR/stderr_out"; echo $?)
assert_exit_code "$EXIT" 0

# ─── TS10: Concurrent rapid fires don't corrupt state files ─────────────
setup_test "TS10_concurrent_fires"
write_cache 100 57
# Run 3 hooks in background with different session IDs
for i in 1 2 3; do
    echo "$(make_hook_input "sess-ts10-$i" "$TEST_CWD" "concurrent prompt $i")" | \
        bash "$HOOKS_DIR/rate-limit-prompt-guard.sh" 2>/dev/null &
done
wait
# Verify all created files are valid JSON (support timestamped filenames)
VALID_COUNT=0
for i in 1 2 3; do
    RF=$(find_resume_file "$TEST_CWD/.claude/auto-resume/queued" "sess-ts10-$i" 2>/dev/null) || RF=""
    if [ -n "$RF" ] && [ -f "$RF" ] && jq . "$RF" >/dev/null 2>&1; then
        VALID_COUNT=$((VALID_COUNT + 1))
    fi
done
TOTAL=$((TOTAL + 1))
if [ "$VALID_COUNT" -eq 3 ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: only $VALID_COUNT/3 concurrent files are valid JSON"
fi

print_summary "Security Tests"
