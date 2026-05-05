#!/usr/bin/env bash
# Claude Code Contract Tests (TC01-TC12)
# Validates assumptions about Claude Code's interface that hooks depend on.
source "$(cd "$(dirname "$0")" && pwd)/test-framework.sh"

echo "════════════════════════════════════════════════════════"
echo " Claude Code Contract Tests (TC01-TC12)"
echo "════════════════════════════════════════════════════════"

# ─── TC01: Hook input contains session_id field ─────────────────────────
setup_test "TC01_input_has_session_id"
write_cache 100 57
INPUT=$(make_hook_input "contract-sess-001" "$TEST_CWD")
# Verify our hook can extract session_id and use it
EXIT=$(run_stop_hook "$INPUT")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for contract-sess-001)"
assert_json_field "$(resume_file_for contract-sess-001)" '.session_id' "contract-sess-001"

# ─── TC02: Hook input contains cwd field ────────────────────────────────
setup_test "TC02_input_has_cwd"
write_cache 100 57
INPUT=$(make_hook_input "contract-sess-002" "$TEST_CWD")
EXIT=$(run_stop_hook "$INPUT")
assert_exit_code "$EXIT" 0
# File created under the CWD path proves cwd was extracted correctly
TC02_FILE=$(find_resume_file "$TEST_CWD/.claude/auto-resume/queued" "contract-sess-002" 2>/dev/null) || TC02_FILE=""
assert_not_empty "$TC02_FILE" "resume file should exist for contract-sess-002"

# ─── TC03: Hook input contains hook_event_name field ────────────────────
setup_test "TC03_input_has_hook_event_name"
write_cache 100 57
INPUT=$(make_hook_input "contract-sess-003" "$TEST_CWD" "" "SubagentStop")
EXIT=$(run_stop_hook "$INPUT")
assert_exit_code "$EXIT" 0
# SubagentStop sets source to subagent_stop — proves hook_event_name was read
assert_json_field "$(resume_file_for contract-sess-003)" '.source' "subagent_stop"

# ─── TC04: Hook input with renamed field (sessionId instead of session_id) → graceful exit ─
setup_test "TC04_renamed_session_id_field"
write_cache 100 57
INPUT=$(jq -n --arg sid "contract-sess-004" --arg cwd "$TEST_CWD" '{sessionId: $sid, cwd: $cwd}')
EXIT=$(echo "$INPUT" | bash "$HOOKS_DIR/rate-limit-stop.sh" 2>"$TEST_DIR/stderr_out"; echo $?)
assert_exit_code "$EXIT" 0
# No schedule should be created (session_id field is missing)
TOTAL=$((TOTAL + 1))
if [ ! -d "$RESUME_DIR/queued" ]; then
    PASS=$((PASS + 1))
else
    COUNT=$(ls "$RESUME_DIR/queued"/*.json 2>/dev/null | wc -l)
    if [ "$COUNT" -eq 0 ]; then PASS=$((PASS + 1)); else
        FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: created schedule with renamed session_id field"
    fi
fi

# ─── TC05: Statusline cache schema has five_hour.used_percentage path ────
setup_test "TC05_cache_schema_five_hour_pct"
write_cache 75 40
TOTAL=$((TOTAL + 1))
VAL=$(jq -r '.rate_limits.five_hour.used_percentage' "$HOME/.claude/rate-limits.json" 2>/dev/null)
if [ "$VAL" = "75" ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: five_hour.used_percentage = '$VAL' (expected '75')"
fi

# ─── TC06: Statusline cache schema has five_hour.resets_at path ──────────
setup_test "TC06_cache_schema_five_hour_reset"
write_cache 75 40
TOTAL=$((TOTAL + 1))
VAL=$(jq -r '.rate_limits.five_hour.resets_at' "$HOME/.claude/rate-limits.json" 2>/dev/null)
if [ "$VAL" = "$FUTURE" ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: five_hour.resets_at = '$VAL' (expected '$FUTURE')"
fi

# ─── TC07: Statusline cache schema has seven_day paths ───────────────────
setup_test "TC07_cache_schema_seven_day"
write_cache 75 40
TOTAL=$((TOTAL + 1))
VAL=$(jq -r '.rate_limits.seven_day.used_percentage' "$HOME/.claude/rate-limits.json" 2>/dev/null)
if [ "$VAL" = "40" ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: seven_day.used_percentage = '$VAL' (expected '40')"
fi
TOTAL=$((TOTAL + 1))
VAL=$(jq -r '.rate_limits.seven_day.resets_at' "$HOME/.claude/rate-limits.json" 2>/dev/null)
if [ "$VAL" = "$FUTURE" ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: seven_day.resets_at = '$VAL' (expected '$FUTURE')"
fi

# ─── TC08: Cache with renamed schema (usage_percent instead of used_percentage) → treated as 0
setup_test "TC08_renamed_cache_schema"
cat > "$HOME/.claude/rate-limits.json" <<CEOF
{"rate_limits":{"five_hour":{"usage_percent":100,"resets_at":$FUTURE},"seven_day":{"usage_percent":100,"resets_at":$FUTURE}},"last_updated":$NOW}
CEOF
EXIT=$(run_stop_hook "$(make_hook_input "contract-sess-008")")
assert_exit_code "$EXIT" 0
# used_percentage is missing → defaults to 0 → rate < 100% → no schedule
assert_file_not_exists "$(resume_file_for contract-sess-008)"
write_cache 50 30

# ─── TC09: settings.json hooks structure matches expected format ─────────
setup_test "TC09_settings_hooks_structure"
SETTINGS="$REAL_HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
    # Verify hooks is an object with event name keys
    TOTAL=$((TOTAL + 1))
    if jq -e '.hooks | type == "object"' "$SETTINGS" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: hooks is not an object"
    fi
    # Verify each hook event is an array
    TOTAL=$((TOTAL + 1))
    if jq -e '.hooks.Stop | type == "array"' "$SETTINGS" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: hooks.Stop is not an array"
    fi
else
    echo -e "  ${YELLOW}SKIP${NC}: settings.json not found"
    TOTAL=$((TOTAL + 2)); PASS=$((PASS + 2))
fi

# ─── TC10: Known hook event names are handled ────────────────────────────
setup_test "TC10_known_hook_events"
write_cache 100 57
KNOWN_EVENTS=("Stop" "SubagentStop" "StopFailure" "UserPromptSubmit" "SubagentStart")
for event in "${KNOWN_EVENTS[@]}"; do
    TOTAL=$((TOTAL + 1))
    # Each event should not cause an error (exit 0)
    if [ "$event" = "SubagentStart" ]; then
        INPUT=$(make_hook_input "contract-evt-$event" "$TEST_CWD" "" "$event" "agent-test-001")
        EXIT_CODE=$(echo "$INPUT" | bash "$HOOKS_DIR/rate-limit-subagent-start.sh" 2>/dev/null; echo $?)
    elif [ "$event" = "StopFailure" ]; then
        INPUT=$(make_hook_input "contract-evt-$event" "$TEST_CWD" "" "$event")
        EXIT_CODE=$(echo "$INPUT" | bash "$HOOKS_DIR/rate-limit-stop-failure.sh" 2>/dev/null; echo $?)
    elif [ "$event" = "UserPromptSubmit" ]; then
        INPUT=$(make_hook_input "contract-evt-$event" "$TEST_CWD" "test" "$event")
        EXIT_CODE=$(echo "$INPUT" | bash "$HOOKS_DIR/rate-limit-prompt-guard.sh" 2>/dev/null; echo $?)
    else
        INPUT=$(make_hook_input "contract-evt-$event" "$TEST_CWD" "" "$event")
        EXIT_CODE=$(echo "$INPUT" | bash "$HOOKS_DIR/rate-limit-stop.sh" 2>/dev/null; echo $?)
    fi
    if [ "$EXIT_CODE" -eq 0 ]; then PASS=$((PASS + 1)); else
        FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: event $event exited with code $EXIT_CODE"
    fi
done

# ─── TC11: Hook input with ALL known fields → works ─────────────────────
setup_test "TC11_all_known_fields"
write_cache 100 57
INPUT=$(jq -n --arg sid "contract-sess-011" --arg cwd "$TEST_CWD" --arg p "full input test" \
    --arg hen "Stop" --arg aid "agent-full-001" --arg tp "/tmp/transcript" \
    '{session_id: $sid, cwd: $cwd, prompt: $p, hook_event_name: $hen, agent_id: $aid, transcript_path: $tp}')
EXIT=$(echo "$INPUT" | bash "$HOOKS_DIR/rate-limit-stop.sh" 2>"$TEST_DIR/stderr_out"; echo $?)
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for contract-sess-011)"

# ─── TC12: Claude --resume flag exists ───────────────────────────────────
setup_test "TC12_claude_resume_flag"
TOTAL=$((TOTAL + 1))
if command -v claude >/dev/null 2>&1; then
    if claude --help 2>&1 | grep -q "\-\-resume"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: claude --help does not show --resume flag"
    fi
else
    echo -e "  ${YELLOW}SKIP${NC}: claude not installed"
    PASS=$((PASS + 1))
fi

print_summary "Claude Code Contract Tests"
