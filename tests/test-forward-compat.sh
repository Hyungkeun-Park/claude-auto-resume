#!/usr/bin/env bash
# Hook Input Robustness (Forward Compatibility) tests (T73-T82)
source "$(cd "$(dirname "$0")" && pwd)/test-framework.sh"

echo "════════════════════════════════════════════════════════"
echo " Hook Input Robustness Tests (T73-T82)"
echo "════════════════════════════════════════════════════════"

# ─── T73: Extra unknown fields in hook input → still works ────────────────
# Claude Code may add new fields in future versions
setup_test "T73_extra_fields_in_input"
write_cache 100 57
INPUT=$(jq -n --arg sid "sess-073" --arg cwd "$TEST_CWD" \
    '{session_id: $sid, cwd: $cwd, new_field: "future_value", transcript_path: "/tmp/t", agent_type: "subagent", model: "opus"}')
EXIT=$(echo "$INPUT" | bash "$HOOKS_DIR/rate-limit-stop.sh" 2>"$TEST_DIR/stderr_out"; echo $?)
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-073)"

# ─── T74: Missing cwd in hook input → exits gracefully ───────────────────
setup_test "T74_missing_cwd"
write_cache 100 57
INPUT=$(jq -n --arg sid "sess-074" '{session_id: $sid}')
EXIT=$(echo "$INPUT" | bash "$HOOKS_DIR/rate-limit-stop.sh" 2>"$TEST_DIR/stderr_out"; echo $?)
assert_exit_code "$EXIT" 0
# No cwd → can't determine project dir → no file created
TOTAL=$((TOTAL + 1))
if [ ! -d "$RESUME_DIR" ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: resume dir should not exist without cwd"
fi

# ─── T75: Missing session_id → exits gracefully ──────────────────────────
setup_test "T75_missing_session_id"
write_cache 100 57
INPUT=$(jq -n --arg cwd "$TEST_CWD" '{cwd: $cwd}')
EXIT=$(echo "$INPUT" | bash "$HOOKS_DIR/rate-limit-stop.sh" 2>"$TEST_DIR/stderr_out"; echo $?)
assert_exit_code "$EXIT" 0
TOTAL=$((TOTAL + 1))
if [ ! -d "$RESUME_DIR/queued" ]; then PASS=$((PASS + 1)); else
    COUNT=$(ls "$RESUME_DIR/queued"/*.json 2>/dev/null | wc -l)
    if [ "$COUNT" -eq 0 ]; then PASS=$((PASS + 1)); else
        FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: should not create file without session_id"
    fi
fi

# ─── T76: Cache with extra rate windows → still parses known fields ──────
setup_test "T76_cache_extra_fields"
cat > "$HOME/.claude/rate-limits.json" <<CEOF
{"rate_limits":{"five_hour":{"used_percentage":100,"resets_at":$FUTURE},"seven_day":{"used_percentage":57,"resets_at":$FUTURE},"new_window":{"used_percentage":0,"resets_at":$FUTURE}},"last_updated":$NOW,"version":"2.0","region":"us-east"}
CEOF
EXIT=$(run_stop_hook "$(make_hook_input "sess-076")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-076)"

# ─── T77: Cache with negative percentage → treated as rate < 100% ────────
setup_test "T77_negative_percentage"
write_cache -1 -5
EXIT=$(run_stop_hook "$(make_hook_input "sess-077")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-077)"

# ─── T78: Empty JSON object input → exits gracefully ─────────────────────
setup_test "T78_empty_json_input"
write_cache 100 57
EXIT=$(echo '{}' | bash "$HOOKS_DIR/rate-limit-stop.sh" 2>"$TEST_DIR/stderr_out"; echo $?)
assert_exit_code "$EXIT" 0

# ─── T79: Null fields in input → exits gracefully ────────────────────────
setup_test "T79_null_fields"
write_cache 100 57
INPUT=$(jq -n '{session_id: null, cwd: null, hook_event_name: null}')
EXIT=$(echo "$INPUT" | bash "$HOOKS_DIR/rate-limit-stop.sh" 2>"$TEST_DIR/stderr_out"; echo $?)
assert_exit_code "$EXIT" 0

# ─── T80: Rapid sequential fires: guard → failure(lock) → stop → stop ────
setup_test "T80_rapid_sequential_fires"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-080" "$TEST_CWD" "rapid test")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-080)"
assert_json_field "$(resume_file_for sess-080)" '.source' "user_prompt"
# StopFailure locks source — prevents overuse detection from deleting
EXIT=$(run_stop_failure "$(make_hook_input "sess-080")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-080)" '.source' "stop_failure"
# Stop should preserve (stop_failure lock active)
EXIT=$(run_stop_hook "$(make_hook_input "sess-080")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-080)"
# Another Stop still preserves
EXIT=$(run_stop_hook "$(make_hook_input "sess-080")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-080)"

# ─── T81: Cache with null percentage → treated as 0 (< 100%) ────────────
setup_test "T81_null_percentage"
cat > "$HOME/.claude/rate-limits.json" <<CEOF
{"rate_limits":{"five_hour":{"used_percentage":null,"resets_at":$FUTURE},"seven_day":{"used_percentage":null,"resets_at":$FUTURE}},"last_updated":$NOW}
CEOF
EXIT=$(run_stop_hook "$(make_hook_input "sess-081")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-081)"

# ─── T82: hook_event_name with unknown event → treated as Stop ───────────
setup_test "T82_unknown_event_name"
write_cache 100 57
EXIT=$(run_stop_hook "$(make_hook_input "sess-082" "$TEST_CWD" "" "NewFutureEvent")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-082)"

print_summary "Hook Input Robustness"
