#!/usr/bin/env bash
# Atomic Write + Full Lifecycle + Corrupted Files + Dir Cleanup tests (T36-T43)
source "$(cd "$(dirname "$0")" && pwd)/test-framework.sh"

echo "════════════════════════════════════════════════════════"
echo " Lifecycle Tests (T36-T43)"
echo "════════════════════════════════════════════════════════"

# ─── T36: Atomic write (.tmp file used) ───────────────────────────────────
setup_test "T36_atomic_write"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-036" "$TEST_CWD" "atomic test")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-036)"
assert_file_not_exists "$(resume_file_for sess-036).tmp"

# ─── T37: Guard creates → StopFailure locks → Stop confirms → Rate recovers → Stop clears
setup_test "T37_full_lifecycle"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-037" "$TEST_CWD" "user prompt")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-037)"
assert_json_field "$(resume_file_for sess-037)" '.prompt' "user prompt"
assert_json_field "$(resume_file_for sess-037)" '.source' "user_prompt"

# StopFailure locks source to stop_failure (protects from overuse detection)
EXIT=$(run_stop_failure "$(make_hook_input "sess-037")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-037)" '.source' "stop_failure"

# Stop confirms (sees source=stop_failure → skips overuse, updates prompt)
EXIT=$(run_stop_hook "$(make_hook_input "sess-037")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-037)" '.prompt' "$FIXED_PROMPT"
assert_stderr_contains "$TEST_DIR/stderr_out" "Auto-resume confirmed"

# Rate recovers
write_cache 50 30
EXIT=$(run_stop_hook "$(make_hook_input "sess-037")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-037)"
assert_stderr_contains "$TEST_DIR/stderr_out" "Rate recovered"

# ─── T38: Multi-session lifecycle ──────────────────────────────────────────
setup_test "T38_multi_session_lifecycle"
write_cache 100 57

# Three sessions schedule
run_prompt_guard "$(make_hook_input "sess-M1" "$TEST_CWD" "prompt M1")" >/dev/null 2>&1
run_prompt_guard "$(make_hook_input "sess-M2" "$TEST_CWD" "prompt M2")" >/dev/null 2>&1
run_stop_hook "$(make_hook_input "sess-M3")" >/dev/null 2>&1
assert_file_count "$RESUME_DIR/queued" 3

# Rate recovers, only M2 runs Stop
write_cache 50 30
run_stop_hook "$(make_hook_input "sess-M2")" >/dev/null 2>&1
assert_file_exists "$(resume_file_for sess-M1)"
assert_file_not_exists "$(resume_file_for sess-M2)"
assert_file_exists "$(resume_file_for sess-M3)"
assert_file_count "$RESUME_DIR/queued" 2

# ─── T39: Prompt guard with corrupted existing file → creates new ───────────
setup_test "T39_guard_corrupted_file"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
echo "NOT VALID JSON{{{" > "$(resume_file_for sess-039)"
EXIT=$(run_prompt_guard "$(make_hook_input "sess-039" "$TEST_CWD" "recovery prompt")")
assert_exit_code "$EXIT" 0
# Should overwrite corrupted file with valid JSON
assert_json_field "$(resume_file_for sess-039)" '.prompt' "recovery prompt"

# ─── T40: Stop hook with corrupted existing file → creates new ──────────────
setup_test "T40_stop_corrupted_file"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
echo "" > "$(resume_file_for sess-040)"
EXIT=$(run_stop_hook "$(make_hook_input "sess-040")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-040)" '.session_id' "sess-040"

# ─── T41: StopFailure with corrupted existing file ─────────────────────────
setup_test "T41_failure_corrupted_file"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
echo "null" > "$(resume_file_for sess-041)"
EXIT=$(run_stop_failure "$(make_hook_input "sess-041")")
assert_exit_code "$EXIT" 0

# ─── T42: Stop hook removes empty queued dir ───────────────────────────────
setup_test "T42_dir_cleanup"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
echo '{"session_id":"sess-042","resume_at":99999,"prompt":"p","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-042)"
write_cache 50 30
EXIT=$(run_stop_hook "$(make_hook_input "sess-042")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-042)"
# queued/ dir should be removed if empty
TOTAL=$((TOTAL + 1))
if [ ! -d "$RESUME_DIR/queued" ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC}: empty queued dir not cleaned up"
fi

# ─── T43: Stop hook doesn't remove dir if other files exist ────────────────
setup_test "T43_dir_not_removed_if_others"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
echo '{"session_id":"sess-043a","resume_at":99999,"prompt":"a","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-043a)"
echo '{"session_id":"sess-043b","resume_at":99999,"prompt":"b","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-043b)"
write_cache 50 30
EXIT=$(run_stop_hook "$(make_hook_input "sess-043a")")
assert_exit_code "$EXIT" 0
TOTAL=$((TOTAL + 1))
if [ -d "$RESUME_DIR/queued" ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC}: queued dir removed despite other files existing"
fi

print_summary "Lifecycle Tests"
