#!/usr/bin/env bash
# Subagent Marker Lifecycle G16 tests (T57-T66)
source "$(cd "$(dirname "$0")" && pwd)/test-framework.sh"

echo "════════════════════════════════════════════════════════"
echo " Subagent Marker Lifecycle G16 Tests (T57-T66)"
echo "════════════════════════════════════════════════════════"

echo ""
echo "── Subagent Marker Lifecycle (G16) ──"

# ─── T57: SubagentStart creates marker file ─────────────────────────────────
setup_test "T57_subagent_start_creates_marker"
write_cache 80 30
EXIT=$(run_subagent_start "$(make_hook_input "sess-057" "$TEST_CWD" "" "SubagentStart" "agent-abc-001")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(marker_file_for sess-057 agent-abc-001)"

# ─── T58: SubagentStop deletes marker ───────────────────────────────────────
setup_test "T58_subagent_stop_deletes_marker"
write_cache 80 30
# Create marker first
mkdir -p "$(marker_dir_for sess-058)"
echo "$(date +%s)" > "$(marker_file_for sess-058 agent-abc-002)"
assert_file_exists "$(marker_file_for sess-058 agent-abc-002)"
# SubagentStop should delete it
EXIT=$(run_stop_hook "$(make_hook_input "sess-058" "$TEST_CWD" "" "SubagentStop" "agent-abc-002")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(marker_file_for sess-058 agent-abc-002)"

# ─── T59: Stop skips overuse when marker exists (G16 core fix) ──────────────
setup_test "T59_stop_skips_overuse_with_marker"
write_cache 100 57
# Create schedule (as if UserPromptSubmit created it at 100%)
mkdir -p "$RESUME_DIR/queued"
jq -n --arg sid "sess-059" --argjson rat "$FUTURE" --arg rah "$FUTURE_DATE" \
    --argjson sat "$NOW" --arg p "prompt" --argjson car 100 --arg src "user_prompt" \
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, prompt: $p, created_at_rate: $car, source: $src}' \
    > "$(resume_file_for sess-059)"
# Create surviving marker (rate-limited subagent hasn't stopped yet)
mkdir -p "$(marker_dir_for sess-059)"
echo "$(date +%s)" > "$(marker_file_for sess-059 agent-pending-001)"
# Stop fires — should NOT delete schedule (overuse skipped due to marker)
EXIT=$(run_stop_hook "$(make_hook_input "sess-059")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-059)"
assert_stderr_not_contains "$TEST_DIR/stderr_out" "Overuse detected"
assert_stderr_contains "$TEST_DIR/stderr_out" "Auto-resume confirmed"
assert_log_contains "OVERUSE_SKIPPED_SUBAGENT"

# ─── T60: Stop applies overuse when no markers (existing behavior) ──────────
setup_test "T60_stop_overuse_no_markers"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
jq -n --arg sid "sess-060" --argjson rat "$FUTURE" --arg rah "$FUTURE_DATE" \
    --argjson sat "$NOW" --arg p "prompt" --argjson car 100 --arg src "user_prompt" \
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, prompt: $p, created_at_rate: $car, source: $src}' \
    > "$(resume_file_for sess-060)"
# No markers — overuse should trigger as before
EXIT=$(run_stop_hook "$(make_hook_input "sess-060")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-060)"
assert_stderr_contains "$TEST_DIR/stderr_out" "Overuse detected"

# ─── T61: SubagentStop deletes marker even with stale cache ─────────────────
setup_test "T61_subagent_stop_marker_stale_cache"
STALE_TIME=$((NOW - 600))
write_cache 94 30 "$FUTURE" "$FUTURE" "$STALE_TIME"
# Create marker
mkdir -p "$(marker_dir_for sess-061)"
echo "$(date +%s)" > "$(marker_file_for sess-061 agent-stale-001)"
# SubagentStop with stale cache — hook exits early but marker should still be deleted
EXIT=$(run_stop_hook "$(make_hook_input "sess-061" "$TEST_CWD" "" "SubagentStop" "agent-stale-001")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(marker_file_for sess-061 agent-stale-001)"

# ─── T62: Multiple subagents — partial completion leaves markers ────────────
setup_test "T62_multiple_subagents_partial"
write_cache 100 57
# Start 3 subagents
EXIT=$(run_subagent_start "$(make_hook_input "sess-062" "$TEST_CWD" "" "SubagentStart" "agent-a")")
assert_exit_code "$EXIT" 0
EXIT=$(run_subagent_start "$(make_hook_input "sess-062" "$TEST_CWD" "" "SubagentStart" "agent-b")")
assert_exit_code "$EXIT" 0
EXIT=$(run_subagent_start "$(make_hook_input "sess-062" "$TEST_CWD" "" "SubagentStart" "agent-c")")
assert_exit_code "$EXIT" 0
# agent-a completes (SubagentStop)
EXIT=$(run_stop_hook "$(make_hook_input "sess-062" "$TEST_CWD" "" "SubagentStop" "agent-a")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(marker_file_for sess-062 agent-a)"
# agent-b and agent-c still pending
assert_file_exists "$(marker_file_for sess-062 agent-b)"
assert_file_exists "$(marker_file_for sess-062 agent-c)"

# ─── T63: Full G16 lifecycle — Guard→Start→Stop(success)→Stop(pending)→no overuse ──
setup_test "T63_full_g16_lifecycle"
write_cache 100 57
# UserPromptSubmit creates schedule
EXIT=$(run_prompt_guard "$(make_hook_input "sess-063" "$TEST_CWD" "user prompt")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-063)"
assert_json_field "$(resume_file_for sess-063)" '.source' "user_prompt"
# SubagentStart for 2 agents
EXIT=$(run_subagent_start "$(make_hook_input "sess-063" "$TEST_CWD" "" "SubagentStart" "agent-ok")")
assert_exit_code "$EXIT" 0
EXIT=$(run_subagent_start "$(make_hook_input "sess-063" "$TEST_CWD" "" "SubagentStart" "agent-stuck")")
assert_exit_code "$EXIT" 0
# agent-ok completes normally
EXIT=$(run_stop_hook "$(make_hook_input "sess-063" "$TEST_CWD" "" "SubagentStop" "agent-ok")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(marker_file_for sess-063 agent-ok)"
assert_file_exists "$(marker_file_for sess-063 agent-stuck)"
# Parent Stop fires — agent-stuck marker survives → overuse skipped
EXIT=$(run_stop_hook "$(make_hook_input "sess-063")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-063)"
assert_stderr_not_contains "$TEST_DIR/stderr_out" "Overuse detected"
# Later: agent-stuck's SubagentStop arrives (stale cache) — marker cleaned up
STALE_TIME=$((NOW - 600))
write_cache 94 30 "$FUTURE" "$FUTURE" "$STALE_TIME"
EXIT=$(run_stop_hook "$(make_hook_input "sess-063" "$TEST_CWD" "" "SubagentStop" "agent-stuck")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(marker_file_for sess-063 agent-stuck)"

# ─── T64: SubagentStart with invalid agent_id is rejected ──────────────────
setup_test "T64_subagent_start_invalid_agent_id"
write_cache 80 30
EXIT=$(run_subagent_start "$(echo '{"cwd":"'"$TEST_CWD"'","session_id":"sess-064","agent_id":"agent;rm -rf","hook_event_name":"SubagentStart"}')")
assert_exit_code "$EXIT" 0
TOTAL=$((TOTAL + 1))
if [ ! -d "$RESUME_DIR/subagents" ]; then
    PASS=$((PASS + 1))
else
    COUNT=$(find "$RESUME_DIR/subagents" -type f 2>/dev/null | wc -l)
    if [ "$COUNT" -eq 0 ]; then PASS=$((PASS + 1)); else
        FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: created marker with invalid agent_id"
    fi
fi

# ─── T65: SubagentStart respects project opt-out ───────────────────────────
setup_test "T65_subagent_start_project_optout"
write_cache 80 30
mkdir -p "$TEST_CWD/.claude"
echo "enabled=false" > "$TEST_CWD/.claude/auto-resume.conf"
EXIT=$(run_subagent_start "$(make_hook_input "sess-065" "$TEST_CWD" "" "SubagentStart" "agent-optout")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(marker_file_for sess-065 agent-optout)"

# ─── T66: Empty marker dir does not block overuse ──────────────────────────
setup_test "T66_empty_marker_dir_no_block"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
jq -n --arg sid "sess-066" --argjson rat "$FUTURE" --arg rah "$FUTURE_DATE" \
    --argjson sat "$NOW" --arg p "prompt" --argjson car 100 --arg src "user_prompt" \
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, prompt: $p, created_at_rate: $car, source: $src}' \
    > "$(resume_file_for sess-066)"
# Create empty marker dir (all subagents completed)
mkdir -p "$(marker_dir_for sess-066)"
# Stop should still detect overuse (empty dir = no pending agents)
EXIT=$(run_stop_hook "$(make_hook_input "sess-066")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-066)"
assert_stderr_contains "$TEST_DIR/stderr_out" "Overuse detected"

print_summary "Subagent Marker Lifecycle G16"
