#!/usr/bin/env bash
# Both Limits at 100% + Edge Cases tests (T27-T35)
source "$(cd "$(dirname "$0")" && pwd)/test-framework.sh"

echo "════════════════════════════════════════════════════════"
echo " Both Limits at 100% + Edge Cases Tests (T27-T35)"
echo "════════════════════════════════════════════════════════"

EARLY=$((NOW + 1800))
LATE=$((NOW + 7200))

# ─── T27: Both 100%, picks later reset time ────────────────────────────────
setup_test "T27_both_100_later_reset"
write_cache 100 100 "$EARLY" "$LATE"
EXIT=$(run_stop_hook "$(make_hook_input "sess-027")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-027)" '.resume_at' "$LATE"

# ─── T28: Both 100%, five is later ────────────────────────────────────────
setup_test "T28_both_100_five_later"
write_cache 100 100 "$LATE" "$EARLY"
EXIT=$(run_stop_hook "$(make_hook_input "sess-028")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-028)" '.resume_at' "$LATE"

# ─── T29: Only seven at 100% ──────────────────────────────────────────────
setup_test "T29_only_seven_100"
write_cache 80 100 "$EARLY" "$LATE"
EXIT=$(run_stop_hook "$(make_hook_input "sess-029")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-029)" '.resume_at' "$LATE"

# ─── T30: Resume time > 8 hours → skip ────────────────────────────────────
setup_test "T30_too_far_future"
FAR=$((NOW + 36000))
write_cache 100 57 "$FAR" "$FAR"
EXIT=$(run_stop_hook "$(make_hook_input "sess-030")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-030)"

# ─── T31: 99.5% rounds to 100 → triggers ──────────────────────────────────
setup_test "T31_rounding_99_5"
write_cache 99.5 57
EXIT=$(run_stop_hook "$(make_hook_input "sess-031")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-031)"

# ─── T32: 99.4% rounds to 99 → no trigger ─────────────────────────────────
setup_test "T32_rounding_99_4"
write_cache 99.4 57
EXIT=$(run_stop_hook "$(make_hook_input "sess-032")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-032)"

# ─── T33: Empty session_id → skip ─────────────────────────────────────────
setup_test "T33_empty_session_id"
write_cache 100 57
EXIT=$(run_stop_hook "$(echo '{"cwd":"'"$TEST_CWD"'","session_id":""}')")
assert_exit_code "$EXIT" 0
# Should not create any file in auto-resume dir
TOTAL=$((TOTAL + 1))
if [ ! -d "$RESUME_DIR/queued" ]; then
    PASS=$((PASS + 1))
else
    COUNT=$(ls "$RESUME_DIR/queued"/*.json 2>/dev/null | wc -l)
    if [ "$COUNT" -eq 0 ]; then PASS=$((PASS + 1)); else
        FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: created file with empty session_id"
    fi
fi

# ─── T34: Empty CWD → skip ────────────────────────────────────────────────
setup_test "T34_empty_cwd"
write_cache 100 57
EXIT=$(run_stop_hook "$(echo '{"cwd":"","session_id":"sess-034"}')")
assert_exit_code "$EXIT" 0

# ─── T35: Stop hook resume_at update ──────────────────────────────────────
setup_test "T35_stop_updates_resume_at"
EARLY=$((NOW + 1800))
LATE=$((NOW + 3600))
write_cache 100 57 "$EARLY"
mkdir -p "$RESUME_DIR/queued"
jq -n --arg sid "sess-035" --argjson rat "$LATE" --arg rah "old-time" \
    --argjson sat "$NOW" --arg p "old prompt" --argjson car 50 --arg src "stop" \
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, prompt: $p, created_at_rate: $car, source: $src}' \
    > "$(resume_file_for sess-035)"
EXIT=$(run_stop_hook "$(make_hook_input "sess-035")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-035)" '.resume_at' "$EARLY"

print_summary "Both Limits at 100% + Edge Cases"
