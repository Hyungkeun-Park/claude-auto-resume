#!/usr/bin/env bash
# Prompt Guard Basic tests (T07-T12)
source "$(cd "$(dirname "$0")" && pwd)/test-framework.sh"

echo "════════════════════════════════════════════════════════"
echo " Prompt Guard Basic Tests (T07-T12)"
echo "════════════════════════════════════════════════════════"

# ─── T07: Prompt guard, rate < 100% → no action ────────────────────────────
setup_test "T07_guard_rate_low"
write_cache 50 30
EXIT=$(run_prompt_guard "$(make_hook_input "sess-007" "$TEST_CWD" "hello")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-007)"

# ─── T08: Prompt guard, rate 100% → create with user prompt ────────────────
setup_test "T08_guard_rate_100_create"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-008" "$TEST_CWD" "my actual prompt")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-008)"
assert_json_field "$(resume_file_for sess-008)" '.session_id' "sess-008"
assert_json_field "$(resume_file_for sess-008)" '.prompt' "my actual prompt"
assert_stderr_contains "$TEST_DIR/stderr_out" "Auto-resume scheduled"

# ─── T09: Prompt guard, same session already scheduled → updates prompt ──────
setup_test "T09_guard_already_scheduled"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
jq -n --arg sid "sess-009" --argjson rat "$FUTURE" --arg rah "$FUTURE_DATE" \
    --argjson sat "$NOW" --arg p "old prompt" --argjson car 50 --arg src "stop" \
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, prompt: $p, created_at_rate: $car, source: $src}' \
    > "$(resume_file_for sess-009)"
EXIT=$(run_prompt_guard "$(make_hook_input "sess-009" "$TEST_CWD" "new prompt")")
assert_exit_code "$EXIT" 0
# Installed hooks now update prompt on existing schedule (user's latest intent)
assert_json_field "$(resume_file_for sess-009)" '.prompt' "new prompt"
assert_stderr_contains "$TEST_DIR/stderr_out" "prompt updated"

# ─── T10: Prompt guard, different session → creates new file ────────────────
setup_test "T10_guard_different_session"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
echo '{"session_id":"sess-X","resume_at":99999,"prompt":"x","resume_at_human":"x","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-X)"
EXIT=$(run_prompt_guard "$(make_hook_input "sess-010" "$TEST_CWD" "my prompt")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-X)"
assert_file_exists "$(resume_file_for sess-010)"
assert_json_field "$(resume_file_for sess-010)" '.prompt' "my prompt"
assert_file_count "$RESUME_DIR/queued" 2

# ─── T11: Prompt guard, stale cache at 100% → still creates schedule ──────
setup_test "T11_guard_stale_cache_at_limit"
write_cache 100 57 "$FUTURE" "$FUTURE" "$((NOW - 600))"
EXIT=$(run_prompt_guard "$(make_hook_input "sess-011" "$TEST_CWD" "stale prompt")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-011)"
assert_json_field "$(resume_file_for sess-011)" '.session_id' "sess-011"
assert_json_field "$(resume_file_for sess-011)" '.prompt' "stale prompt"

# ─── T12: Prompt guard, no cache file → skip ───────────────────────────────
setup_test "T12_guard_no_cache"
rm -f "$HOME/.claude/rate-limits.json"
EXIT=$(run_prompt_guard "$(make_hook_input "sess-012" "$TEST_CWD" "prompt")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-012)"
write_cache 50 30

print_summary "Prompt Guard Basic"
