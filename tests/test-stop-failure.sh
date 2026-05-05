#!/usr/bin/env bash
# StopFailure Hook tests (T13-T17)
source "$(cd "$(dirname "$0")" && pwd)/test-framework.sh"

echo "════════════════════════════════════════════════════════"
echo " StopFailure Hook Tests (T13-T17)"
echo "════════════════════════════════════════════════════════"

# ─── T13: StopFailure, rate < 100% → no action ─────────────────────────────
setup_test "T13_failure_rate_low"
write_cache 50 30
EXIT=$(run_stop_failure "$(make_hook_input "sess-013")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-013)"

# ─── T14: StopFailure, rate 100% → create ──────────────────────────────────
setup_test "T14_failure_rate_100_create"
write_cache 100 57
EXIT=$(run_stop_failure "$(make_hook_input "sess-014")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-014)"
assert_json_field "$(resume_file_for sess-014)" '.session_id' "sess-014"
assert_json_field "$(resume_file_for sess-014)" '.source' "stop_failure"
assert_stderr_contains "$TEST_DIR/stderr_out" "Auto-resume scheduled"

# ─── T15: StopFailure, my file already exists → updates source to stop_failure
setup_test "T15_failure_already_scheduled"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
jq -n --arg sid "sess-015" --argjson rat "$FUTURE" --arg rah "$FUTURE_DATE" \
    --argjson sat "$NOW" --arg p "p" --argjson car 50 --arg src "stop" \
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, scheduled_prompt: $p, created_at_rate: $car, source: $src}' \
    > "$(resume_file_for sess-015)"
EXIT=$(run_stop_failure "$(make_hook_input "sess-015")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-015)" '.source' "stop_failure"
assert_stderr_contains "$TEST_DIR/stderr_out" "locked by stop_failure"

# ─── T16: StopFailure, different session exists → creates own file ──────────
setup_test "T16_failure_different_session"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
echo '{"session_id":"sess-other","resume_at":99999,"scheduled_prompt":"p","resume_at_human":"t","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-other)"
EXIT=$(run_stop_failure "$(make_hook_input "sess-016")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-other)"
assert_file_exists "$(resume_file_for sess-016)"

# ─── T17: StopFailure, stale cache at 100% → still creates schedule ───────
setup_test "T17_failure_stale_cache_at_limit"
write_cache 100 57 "$FUTURE" "$FUTURE" "$((NOW - 600))"
EXIT=$(run_stop_failure "$(make_hook_input "sess-017")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-017)"
assert_json_field "$(resume_file_for sess-017)" '.session_id' "sess-017"
assert_json_field "$(resume_file_for sess-017)" '.source' "stop_failure"

print_summary "StopFailure Hook"
