#!/usr/bin/env bash
# Multi-Session Scenarios tests (T18-T20)
source "$(cd "$(dirname "$0")" && pwd)/test-framework.sh"

echo "════════════════════════════════════════════════════════"
echo " Multi-Session Scenario Tests (T18-T20)"
echo "════════════════════════════════════════════════════════"

# ─── T18: Three sessions all schedule independently ─────────────────────────
setup_test "T18_multi_session_coexist"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-A" "$TEST_CWD" "prompt A")")
assert_exit_code "$EXIT" 0
EXIT=$(run_prompt_guard "$(make_hook_input "sess-B" "$TEST_CWD" "prompt B")")
assert_exit_code "$EXIT" 0
EXIT=$(run_prompt_guard "$(make_hook_input "sess-C" "$TEST_CWD" "prompt C")")
assert_exit_code "$EXIT" 0
assert_file_count "$RESUME_DIR/queued" 3
assert_json_field "$(resume_file_for sess-A)" '.prompt' "prompt A"
assert_json_field "$(resume_file_for sess-B)" '.prompt' "prompt B"
assert_json_field "$(resume_file_for sess-C)" '.prompt' "prompt C"

# ─── T19: Rate recovery clears only the recovering session ──────────────────
setup_test "T19_multi_session_selective_clear"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
echo '{"session_id":"sess-D","resume_at":99999,"prompt":"d","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-D)"
echo '{"session_id":"sess-E","resume_at":99999,"prompt":"e","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-E)"
echo '{"session_id":"sess-F","resume_at":99999,"prompt":"f","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-F)"
write_cache 50 30
EXIT=$(run_stop_hook "$(make_hook_input "sess-E")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-D)"
assert_file_not_exists "$(resume_file_for sess-E)"
assert_file_exists "$(resume_file_for sess-F)"

# ─── T20: Stop hook creates for session that has no file yet ────────────────
setup_test "T20_stop_creates_for_new_session"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
echo '{"session_id":"sess-old","resume_at":99999,"prompt":"old","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-old)"
EXIT=$(run_stop_hook "$(make_hook_input "sess-new")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-old)"
assert_file_exists "$(resume_file_for sess-new)"
assert_file_count "$RESUME_DIR/queued" 2

print_summary "Multi-Session Scenarios"
