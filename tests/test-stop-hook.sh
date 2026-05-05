#!/usr/bin/env bash
# Stop Hook Basic tests (T01-T06)
source "$(cd "$(dirname "$0")" && pwd)/test-framework.sh"

echo "════════════════════════════════════════════════════════"
echo " Stop Hook Basic Tests (T01-T06)"
echo "════════════════════════════════════════════════════════"

# ─── T01: Stop hook, rate < 100% ────────────────────────────────────────────
setup_test "T01_stop_rate_low"
write_cache 50 30
EXIT=$(run_stop_hook "$(make_hook_input "sess-001")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-001)"

# ─── T02: Stop hook, rate 100%, create per-session file ─────────────────────
setup_test "T02_stop_rate_100_create"
write_cache 100 57
EXIT=$(run_stop_hook "$(make_hook_input "sess-002")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-002)"
assert_json_field "$(resume_file_for sess-002)" '.session_id' "sess-002"
assert_json_field "$(resume_file_for sess-002)" '.scheduled_prompt' "$FIXED_PROMPT"
assert_stderr_contains "$TEST_DIR/stderr_out" "Auto-resume confirmed"

# ─── T03: Stop hook, my file exists → update prompt and resume_at ───────────
setup_test "T03_stop_update_existing"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
jq -n --arg sid "sess-003" --argjson rat "$FUTURE" --arg rah "$FUTURE_DATE" \
    --argjson sat "$NOW" --arg p "original prompt" --argjson car 50 --arg src "stop" \
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, scheduled_prompt: $p, created_at_rate: $car, source: $src}' \
    > "$(resume_file_for sess-003)"
EXIT=$(run_stop_hook "$(make_hook_input "sess-003")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-003)" '.scheduled_prompt' "$FIXED_PROMPT"
assert_stderr_contains "$TEST_DIR/stderr_out" "Auto-resume confirmed"

# ─── T04: Stop hook, rate < 100% → clear MY file only ──────────────────────
setup_test "T04_stop_clear_own_file"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
echo '{"session_id":"sess-A","resume_at":99999,"scheduled_prompt":"a","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-A)"
echo '{"session_id":"sess-B","resume_at":99999,"scheduled_prompt":"b","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-B)"
# Now rate recovers
write_cache 50 30
EXIT=$(run_stop_hook "$(make_hook_input "sess-A")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-A)"
assert_file_exists "$(resume_file_for sess-B)"
assert_stderr_contains "$TEST_DIR/stderr_out" "Rate recovered"

# ─── T05: Stop hook, stale cache at 100% → still creates schedule ─────────
setup_test "T05_stop_stale_cache_at_limit"
write_cache 100 57 "$FUTURE" "$FUTURE" "$((NOW - 600))"
EXIT=$(run_stop_hook "$(make_hook_input "sess-005")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-005)"
assert_json_field "$(resume_file_for sess-005)" '.session_id' "sess-005"

# ─── T06: Stop hook, no cache file → skip ──────────────────────────────────
setup_test "T06_stop_no_cache"
rm -f "$HOME/.claude/rate-limits.json"
EXIT=$(run_stop_hook "$(make_hook_input "sess-006")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-006)"
write_cache 50 30  # restore for next tests

print_summary "Stop Hook Basic"
