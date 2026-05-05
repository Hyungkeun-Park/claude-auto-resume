#!/usr/bin/env bash
# Stale Cache + Rate Gate G17 tests (T67-T72)
source "$(cd "$(dirname "$0")" && pwd)/test-framework.sh"

echo "════════════════════════════════════════════════════════"
echo " Stale Cache + Rate Gate G17 Tests (T67-T72)"
echo "════════════════════════════════════════════════════════"

# ─── T67: Stop hook, stale cache + rate < 100% → still skips ─────────────
setup_test "T67_stop_stale_cache_low_rate"
write_cache 80 57 "$FUTURE" "$FUTURE" "$((NOW - 600))"
EXIT=$(run_stop_hook "$(make_hook_input "sess-067")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-067)"

# ─── T68: Prompt guard, stale cache + rate < 100% → still skips ──────────
setup_test "T68_guard_stale_cache_low_rate"
write_cache 80 57 "$FUTURE" "$FUTURE" "$((NOW - 600))"
EXIT=$(run_prompt_guard "$(make_hook_input "sess-068" "$TEST_CWD" "stale low")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-068)"

# ─── T69: StopFailure, stale cache + rate < 100% → still skips ───────────
setup_test "T69_failure_stale_cache_low_rate"
write_cache 80 57 "$FUTURE" "$FUTURE" "$((NOW - 600))"
EXIT=$(run_stop_failure "$(make_hook_input "sess-069")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-069)"

# ─── T70: Stale cache at 100% — Stop creates schedule (overuse→block) ────
# Simulates: overuse turns off, client blocks prompt, cache goes stale at 100%
setup_test "T70_stop_stale_cache_overuse_to_block"
write_cache 101 57 "$FUTURE" "$FUTURE" "$((NOW - 900))"
EXIT=$(run_stop_hook "$(make_hook_input "sess-070")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-070)"
assert_json_field "$(resume_file_for sess-070)" '.source' "stop"
assert_stderr_contains "$TEST_DIR/stderr_out" "Auto-resume"

# ─── T71: Stale cache — Stop does NOT clean up existing schedule ──────────
# If cache is stale + rate < 100%, don't trust it for cleanup either
setup_test "T71_stop_stale_cache_no_cleanup"
write_cache 100 57
# First, create a schedule with fresh cache
EXIT=$(run_stop_hook "$(make_hook_input "sess-071")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-071)"
# Now make cache stale with rate < 100% — should NOT clean up
write_cache 50 30 "$FUTURE" "$FUTURE" "$((NOW - 600))"
EXIT=$(run_stop_hook "$(make_hook_input "sess-071")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-071)"

# ─── T72: Stale cache at 100% — Guard preserves user prompt ──────────────
setup_test "T72_guard_stale_cache_preserves_prompt"
write_cache 100 57 "$FUTURE" "$FUTURE" "$((NOW - 400))"
EXIT=$(run_prompt_guard "$(make_hook_input "sess-072" "$TEST_CWD" "my important work")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-072)"
assert_json_field "$(resume_file_for sess-072)" '.prev_prompt' "my important work"
assert_json_field "$(resume_file_for sess-072)" '.source' "user_prompt"

print_summary "Stale Cache + Rate Gate G17"
