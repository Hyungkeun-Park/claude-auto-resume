#!/usr/bin/env bash
# Error Recovery tests (T83-T92)
source "$(cd "$(dirname "$0")" && pwd)/test-framework.sh"

echo "════════════════════════════════════════════════════════"
echo " Error Recovery Tests (T83-T92)"
echo "════════════════════════════════════════════════════════"

# ─── T83: Empty cache file → exits gracefully ────────────────────────────
setup_test "T83_empty_cache_file"
echo -n "" > "$HOME/.claude/rate-limits.json"
EXIT=$(run_stop_hook "$(make_hook_input "sess-083")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-083)"
write_cache 50 30

# ─── T84: Non-JSON cache (e.g., HTML error page) → exits gracefully ─────
setup_test "T84_non_json_cache"
echo "<html>Service Unavailable</html>" > "$HOME/.claude/rate-limits.json"
EXIT=$(run_stop_hook "$(make_hook_input "sess-084")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-084)"
write_cache 50 30

# ─── T85: Non-JSON hook input → exits without side effects ───────────────
# jq fails on non-JSON → set -e exits script (non-zero is acceptable)
setup_test "T85_non_json_input"
write_cache 100 57
echo "this is not json at all" | bash "$HOOKS_DIR/rate-limit-stop.sh" 2>"$TEST_DIR/stderr_out" || true
# Key assertion: no schedule file was created (no side effects)
assert_file_not_exists "$(resume_file_for sess-085)"

# ─── T86: Zero reset time → no schedule (guard against immediate resume) ─
setup_test "T86_zero_reset_time"
write_cache 100 57 0 0
EXIT=$(run_stop_hook "$(make_hook_input "sess-086")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-086)"

# ─── T87: Past reset time → no schedule ──────────────────────────────────
setup_test "T87_past_reset_time"
PAST=$((NOW - 3600))
write_cache 100 57 "$PAST" "$PAST"
EXIT=$(run_stop_hook "$(make_hook_input "sess-087")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-087)"

# ─── T88: Very long prompt → handled without truncation ──────────────────
setup_test "T88_long_prompt"
write_cache 100 57
LONG_PROMPT=$(python3 -c "print('A' * 10000)")
EXIT=$(run_prompt_guard "$(make_hook_input "sess-088" "$TEST_CWD" "$LONG_PROMPT")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-088)"
STORED_LEN=$(jq -r '.prev_prompt | length' "$(resume_file_for sess-088)" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if [ "$STORED_LEN" -eq 10000 ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: prompt length = $STORED_LEN (expected 10000)"
fi

# ─── T89: Prompt guard → StopFailure locks → Stop preserves lock (full chain) ─
setup_test "T89_full_source_lock_chain"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-089" "$TEST_CWD" "chain test")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-089)" '.source' "user_prompt"
# StopFailure locks source
EXIT=$(run_stop_failure "$(make_hook_input "sess-089")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-089)" '.source' "stop_failure"
# Stop should preserve stop_failure source
EXIT=$(run_stop_hook "$(make_hook_input "sess-089")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-089)" '.source' "stop_failure"

# ─── T90: Concurrent sessions — different CWDs are fully independent ─────
setup_test "T90_different_cwd_isolation"
write_cache 100 57
CWD_A="$TEST_DIR/T90_project_a"
CWD_B="$TEST_DIR/T90_project_b"
mkdir -p "$CWD_A/.claude" "$CWD_B/.claude"
EXIT=$(run_prompt_guard "$(make_hook_input "shared-session" "$CWD_A" "prompt A")")
assert_exit_code "$EXIT" 0
EXIT=$(run_prompt_guard "$(make_hook_input "shared-session" "$CWD_B" "prompt B")")
assert_exit_code "$EXIT" 0
# Same session_id, different CWDs → two separate files
FILE_A=$(find_resume_file "$CWD_A/.claude/auto-resume/queued" "shared-session" 2>/dev/null) || FILE_A=""
FILE_B=$(find_resume_file "$CWD_B/.claude/auto-resume/queued" "shared-session" 2>/dev/null) || FILE_B=""
assert_not_empty "$FILE_A" "resume file should exist in CWD_A"
assert_not_empty "$FILE_B" "resume file should exist in CWD_B"
if [ -n "$FILE_A" ]; then assert_json_field "$FILE_A" '.prev_prompt' "prompt A"; else TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); fi
if [ -n "$FILE_B" ]; then assert_json_field "$FILE_B" '.prev_prompt' "prompt B"; else TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); fi

# ─── T91: Rate exactly at boundary (99.5 rounds to 100) → creates schedule ─
setup_test "T91_rate_boundary_99_5"
write_cache 99.5 57
EXIT=$(run_stop_hook "$(make_hook_input "sess-091")")
assert_exit_code "$EXIT" 0
# 99.5 rounds to 100 via printf %.0f → should trigger
assert_file_exists "$(resume_file_for sess-091)"

# ─── T92: Rate exactly at boundary (99.4 rounds to 99) → no schedule ─────
setup_test "T92_rate_boundary_99_4"
write_cache 99.4 57
EXIT=$(run_stop_hook "$(make_hook_input "sess-092")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-092)"

print_summary "Error Recovery"
