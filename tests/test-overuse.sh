#!/usr/bin/env bash
# Overuse Detection v4 tests (T44-T56)
source "$(cd "$(dirname "$0")" && pwd)/test-framework.sh"

echo "════════════════════════════════════════════════════════"
echo " Overuse Detection v4 Tests (T44-T56)"
echo "════════════════════════════════════════════════════════"

# ─── T44: UPS creates at 100% → Stop detects overuse → deletes schedule ────
setup_test "T44_overuse_prompt_guard_then_stop"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-044" "$TEST_CWD" "user prompt")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-044)"
assert_json_field "$(resume_file_for sess-044)" '.created_at_rate' "100"
assert_json_field "$(resume_file_for sess-044)" '.source' "user_prompt"
# Stop event sees created_at_rate=100, source!=stop_failure → overuse
EXIT=$(run_stop_hook "$(make_hook_input "sess-044")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-044)"
assert_stderr_contains "$TEST_DIR/stderr_out" "Overuse detected"

# ─── T45: Stop creates at 100% → next Stop detects overuse (Ralph loop) ────
setup_test "T45_overuse_stop_then_stop"
write_cache 100 57
EXIT=$(run_stop_hook "$(make_hook_input "sess-045")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-045)"
# Second Stop sees created_at_rate=100, source=stop → overuse
EXIT=$(run_stop_hook "$(make_hook_input "sess-045")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-045)"
assert_stderr_contains "$TEST_DIR/stderr_out" "Overuse detected"

# ─── T46: SubagentStop does NOT trigger overuse detection ───────────────────
setup_test "T46_subagent_stop_no_overuse"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
jq -n --arg sid "sess-046" --argjson rat "$FUTURE" --arg rah "$FUTURE_DATE" \
    --argjson sat "$NOW" --arg p "prompt" --argjson car 100 --arg src "user_prompt" \
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, scheduled_prompt: $p, created_at_rate: $car, source: $src}' \
    > "$(resume_file_for sess-046)"
EXIT=$(run_stop_hook "$(make_hook_input "sess-046" "$TEST_CWD" "" "SubagentStop")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-046)"
assert_stderr_contains "$TEST_DIR/stderr_out" "Auto-resume confirmed"

# ─── T47: StopFailure locks source → Stop cannot delete ────────────────────
setup_test "T47_stop_failure_locks_source"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-047" "$TEST_CWD" "user prompt")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-047)" '.source' "user_prompt"
# StopFailure locks source to stop_failure
EXIT=$(run_stop_failure "$(make_hook_input "sess-047")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-047)" '.source' "stop_failure"
# Stop event sees source=stop_failure → skips overuse
EXIT=$(run_stop_hook "$(make_hook_input "sess-047")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-047)"
assert_stderr_contains "$TEST_DIR/stderr_out" "Auto-resume confirmed"
assert_stderr_not_contains "$TEST_DIR/stderr_out" "Overuse detected"

# ─── T48: Rate recovery clears overuse-created file + logs OVERUSE_CLEARED ──
setup_test "T48_rate_recovery_overuse_cleared"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
jq -n --arg sid "sess-048" --argjson rat "$FUTURE" --arg rah "$FUTURE_DATE" \
    --argjson sat "$NOW" --arg p "prompt" --argjson car 100 --arg src "user_prompt" \
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, scheduled_prompt: $p, created_at_rate: $car, source: $src}' \
    > "$(resume_file_for sess-048)"
# Rate recovers
write_cache 50 30
EXIT=$(run_stop_hook "$(make_hook_input "sess-048")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-048)"
assert_stderr_contains "$TEST_DIR/stderr_out" "Rate recovered"
# Check log file for OVERUSE_CLEARED
assert_log_contains "OVERUSE_CLEARED"

# ─── T49: created_at_rate < 100 → Stop does NOT delete (normal case) ───────
setup_test "T49_no_overuse_low_created_rate"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
jq -n --arg sid "sess-049" --argjson rat "$FUTURE" --arg rah "$FUTURE_DATE" \
    --argjson sat "$NOW" --arg p "prompt" --argjson car 50 --arg src "stop" \
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, scheduled_prompt: $p, created_at_rate: $car, source: $src}' \
    > "$(resume_file_for sess-049)"
EXIT=$(run_stop_hook "$(make_hook_input "sess-049")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-049)"

# ─── T50: New fields present in Prompt Guard creation ───────────────────────
setup_test "T50_prompt_guard_new_fields"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-050" "$TEST_CWD" "test prompt")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-050)" '.created_at_rate' "100"
assert_json_field "$(resume_file_for sess-050)" '.source' "user_prompt"

# ─── T51: New fields present in Stop creation ──────────────────────────────
setup_test "T51_stop_new_fields"
write_cache 100 57
EXIT=$(run_stop_hook "$(make_hook_input "sess-051")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-051)" '.created_at_rate' "100"
assert_json_field "$(resume_file_for sess-051)" '.source' "stop"

# ─── T52: New fields present in StopFailure creation ───────────────────────
setup_test "T52_stop_failure_new_fields"
write_cache 100 57
EXIT=$(run_stop_failure "$(make_hook_input "sess-052")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-052)" '.created_at_rate' "100"
assert_json_field "$(resume_file_for sess-052)" '.source' "stop_failure"

# ─── T53: SubagentStop sets source correctly ────────────────────────────────
setup_test "T53_subagent_stop_source"
write_cache 100 57
EXIT=$(run_stop_hook "$(make_hook_input "sess-053" "$TEST_CWD" "" "SubagentStop")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-053)" '.source' "subagent_stop"

# ─── T54: StopFailure updates existing source to stop_failure ──────────────
setup_test "T54_stop_failure_updates_source"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
jq -n --arg sid "sess-054" --argjson rat "$FUTURE" --arg rah "$FUTURE_DATE" \
    --argjson sat "$NOW" --arg p "prompt" --argjson car 50 --arg src "user_prompt" \
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, scheduled_prompt: $p, created_at_rate: $car, source: $src}' \
    > "$(resume_file_for sess-054)"
EXIT=$(run_stop_failure "$(make_hook_input "sess-054")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-054)" '.source' "stop_failure"

# ─── T55: Stop preserves stop_failure source on update ─────────────────────
setup_test "T55_stop_preserves_stop_failure_source"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
jq -n --arg sid "sess-055" --argjson rat "$FUTURE" --arg rah "$FUTURE_DATE" \
    --argjson sat "$NOW" --arg p "prompt" --argjson car 50 --arg src "stop_failure" \
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, scheduled_prompt: $p, created_at_rate: $car, source: $src}' \
    > "$(resume_file_for sess-055)"
EXIT=$(run_stop_hook "$(make_hook_input "sess-055")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-055)" '.source' "stop_failure"

# ─── T56: Session ID regex validation — invalid chars rejected ──────────────
setup_test "T56_session_id_invalid_chars"
write_cache 100 57
EXIT=$(run_stop_hook "$(echo '{"cwd":"'"$TEST_CWD"'","session_id":"sess;rm -rf"}')")
assert_exit_code "$EXIT" 0
TOTAL=$((TOTAL + 1))
if [ ! -d "$RESUME_DIR/queued" ]; then
    PASS=$((PASS + 1))
else
    COUNT=$(ls "$RESUME_DIR/queued"/*.json 2>/dev/null | wc -l)
    if [ "$COUNT" -eq 0 ]; then PASS=$((PASS + 1)); else
        FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: created file with invalid session_id"
    fi
fi

print_summary "Overuse Detection v4"
