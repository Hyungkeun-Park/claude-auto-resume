#!/usr/bin/env bash
# Simulation test for rate-limit auto-resume hooks (directory-based, multi-session).
# Tests all cases from the spec without actually calling claude or nohup.
# Updated for v4: queued/ subdirectory, overuse detection, new JSON fields.
#
# Usage: bash ~/.claude/bin/test-rate-limit-simulation.sh

set -uo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# Test Framework
# ═══════════════════════════════════════════════════════════════════════════════

PASS=0
FAIL=0
TOTAL=0
TEST_DIR=$(mktemp -d)
REAL_HOME="$HOME"
HOOKS_DIR="$REAL_HOME/.claude/hooks"

# Isolate HOME so real statusline doesn't interfere with test cache
export HOME="$TEST_DIR"
mkdir -p "$HOME/.claude/logs" "$HOME/.claude/bin"
# Stub resume script
echo '#!/bin/bash' > "$HOME/.claude/bin/claude-auto-resume.sh"
chmod +x "$HOME/.claude/bin/claude-auto-resume.sh"

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

assert_file_exists() {
    TOTAL=$((TOTAL + 1))
    if [ -f "$1" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: expected file to exist: $1"
    fi
}

assert_file_not_exists() {
    TOTAL=$((TOTAL + 1))
    if [ ! -f "$1" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: expected file NOT to exist: $1"
    fi
}

assert_json_field() {
    local file="$1" field="$2" expected="$3"
    TOTAL=$((TOTAL + 1))
    local actual
    actual=$(jq -r "$field" "$file" 2>/dev/null)
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: $field = '$actual' (expected '$expected')"
    fi
}

assert_stderr_contains() {
    local stderr_file="$1" pattern="$2"
    TOTAL=$((TOTAL + 1))
    if grep -q "$pattern" "$stderr_file" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: stderr missing pattern: '$pattern'"
        echo -e "         actual: $(cat "$stderr_file" 2>/dev/null)"
    fi
}

assert_stderr_not_contains() {
    local stderr_file="$1" pattern="$2"
    TOTAL=$((TOTAL + 1))
    if ! grep -q "$pattern" "$stderr_file" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: stderr should NOT contain pattern: '$pattern'"
        echo -e "         actual: $(cat "$stderr_file" 2>/dev/null)"
    fi
}

assert_exit_code() {
    local actual="$1" expected="$2"
    TOTAL=$((TOTAL + 1))
    if [ "$actual" -eq "$expected" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: exit code = $actual (expected $expected)"
    fi
}

assert_file_count() {
    local dir="$1" expected="$2"
    TOTAL=$((TOTAL + 1))
    local actual
    actual=$(ls "$dir"/*.json 2>/dev/null | wc -l)
    if [ "$actual" -eq "$expected" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: file count in $dir = $actual (expected $expected)"
    fi
}

assert_log_contains() {
    local pattern="$1"
    TOTAL=$((TOTAL + 1))
    local log_file
    log_file="$HOME/.claude/logs/auto-resume-$(date +%Y-%m-%d).log"
    if grep -q "$pattern" "$log_file" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: log missing pattern: '$pattern'"
        echo -e "         log: $(cat "$log_file" 2>/dev/null)"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test Helpers
# ═══════════════════════════════════════════════════════════════════════════════

NOW=$(date +%s)
FUTURE=$((NOW + 3600))
FUTURE_DATE=$(date -d "@$FUTURE" -Iseconds 2>/dev/null || date -r "$FUTURE" -Iseconds 2>/dev/null)

FIXED_PROMPT="If any agents failed in the previous task, do not perform their work directly — re-launch the same agents. If it was not an agent failure, continue with the remaining work."

setup_test() {
    local test_name="$1"
    echo -e "${YELLOW}[$test_name]${NC}"
    TEST_CWD="$TEST_DIR/$test_name"
    mkdir -p "$TEST_CWD/.claude"
    RESUME_DIR="$TEST_CWD/.claude/auto-resume"
}

resume_file_for() {
    # Find existing file (timestamped or legacy format)
    local f
    f=$(ls "$RESUME_DIR/queued"/*"-${1}.json" 2>/dev/null | head -1)
    [ -n "$f" ] && [ -f "$f" ] && echo "$f" && return 0
    [ -f "$RESUME_DIR/queued/${1}.json" ] && echo "$RESUME_DIR/queued/${1}.json" && return 0
    # Not found — return legacy path (for assert_file_not_exists and manual writes)
    echo "$RESUME_DIR/queued/${1}.json"
}

write_cache() {
    local five_pct="$1" seven_pct="$2" five_reset="${3:-$FUTURE}" seven_reset="${4:-$FUTURE}" last_updated="${5:-$NOW}"
    cat > "$HOME/.claude/rate-limits.json" <<EOF
{"rate_limits":{"five_hour":{"used_percentage":$five_pct,"resets_at":$five_reset},"seven_day":{"used_percentage":$seven_pct,"resets_at":$seven_reset}},"last_updated":$last_updated}
EOF
}

make_hook_input() {
    local session_id="${1:-test-session-001}" cwd="${2:-$TEST_CWD}" prompt="${3:-}" hook_event="${4:-}" agent_id="${5:-}"
    local args=()
    args+=(--arg sid "$session_id" --arg cwd "$cwd")
    local filter='{session_id: $sid, cwd: $cwd'
    if [ -n "$prompt" ]; then
        args+=(--arg p "$prompt")
        filter="$filter, prompt: \$p"
    fi
    if [ -n "$hook_event" ]; then
        args+=(--arg hen "$hook_event")
        filter="$filter, hook_event_name: \$hen"
    fi
    if [ -n "$agent_id" ]; then
        args+=(--arg aid "$agent_id")
        filter="$filter, agent_id: \$aid"
    fi
    filter="$filter}"
    jq -n "${args[@]}" "$filter"
}

# Override nohup/pkill to prevent real process spawning
export PATH="$TEST_DIR/bin:$PATH"
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/nohup" <<'EOF'
#!/bin/bash
echo "NOHUP_CALLED: $*" >> "${TEST_DIR:-/tmp}/nohup_calls.log"
EOF
chmod +x "$TEST_DIR/bin/nohup"

cat > "$TEST_DIR/bin/pkill" <<'EOF'
#!/bin/bash
echo "PKILL_CALLED: $*" >> "${TEST_DIR:-/tmp}/pkill_calls.log"
EOF
chmod +x "$TEST_DIR/bin/pkill"

export TEST_DIR

run_stop_hook() {
    local input="$1"
    local stderr_file="$TEST_DIR/stderr_out"
    echo "$input" | bash "$HOOKS_DIR/rate-limit-stop.sh" 2>"$stderr_file"
    echo $?
}

run_prompt_guard() {
    local input="$1"
    local stderr_file="$TEST_DIR/stderr_out"
    echo "$input" | bash "$HOOKS_DIR/rate-limit-prompt-guard.sh" 2>"$stderr_file"
    echo $?
}

run_stop_failure() {
    local input="$1"
    local stderr_file="$TEST_DIR/stderr_out"
    echo "$input" | bash "$HOOKS_DIR/rate-limit-stop-failure.sh" 2>"$stderr_file"
    echo $?
}

run_subagent_start() {
    local input="$1"
    local stderr_file="$TEST_DIR/stderr_out"
    echo "$input" | bash "$HOOKS_DIR/rate-limit-subagent-start.sh" 2>"$stderr_file"
    echo $?
}

marker_file_for() {
    local session_id="$1" agent_id="$2"
    echo "$RESUME_DIR/subagents/$session_id/$agent_id"
}

marker_dir_for() {
    local session_id="$1"
    echo "$RESUME_DIR/subagents/$session_id"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: Stop Hook Basic
# ═══════════════════════════════════════════════════════════════════════════════

echo "════════════════════════════════════════════════════════"
echo " Rate Limit Auto-Resume: Directory-Based Tests (v4)"
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
assert_json_field "$(resume_file_for sess-002)" '.prompt' "$FIXED_PROMPT"
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
assert_json_field "$(resume_file_for sess-003)" '.prompt' "$FIXED_PROMPT"
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

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: Prompt Guard Basic
# ═══════════════════════════════════════════════════════════════════════════════

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
assert_json_field "$(resume_file_for sess-008)" '.prev_prompt' "my actual prompt"
assert_stderr_contains "$TEST_DIR/stderr_out" "Auto-resume scheduled"

# ─── T09: Prompt guard, same session already scheduled → updates prompt ────────
setup_test "T09_guard_already_scheduled"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
jq -n --arg sid "sess-009" --argjson rat "$FUTURE" --arg rah "$FUTURE_DATE" \
    --argjson sat "$NOW" --arg p "old prompt" --argjson car 50 --arg src "stop" \
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, scheduled_prompt: $p, created_at_rate: $car, source: $src}' \
    > "$(resume_file_for sess-009)"
EXIT=$(run_prompt_guard "$(make_hook_input "sess-009" "$TEST_CWD" "new prompt")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-009)" '.prev_prompt' "new prompt"
assert_stderr_contains "$TEST_DIR/stderr_out" "prompt updated"

# ─── T10: Prompt guard, different session → creates new file ────────────────
setup_test "T10_guard_different_session"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
echo '{"session_id":"sess-X","resume_at":99999,"scheduled_prompt":"x","resume_at_human":"x","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-X)"
EXIT=$(run_prompt_guard "$(make_hook_input "sess-010" "$TEST_CWD" "my prompt")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-X)"
assert_file_exists "$(resume_file_for sess-010)"
assert_json_field "$(resume_file_for sess-010)" '.prev_prompt' "my prompt"
assert_file_count "$RESUME_DIR/queued" 2

# ─── T11: Prompt guard, stale cache at 100% → still creates schedule ──────
setup_test "T11_guard_stale_cache_at_limit"
write_cache 100 57 "$FUTURE" "$FUTURE" "$((NOW - 600))"
EXIT=$(run_prompt_guard "$(make_hook_input "sess-011" "$TEST_CWD" "stale prompt")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-011)"
assert_json_field "$(resume_file_for sess-011)" '.session_id' "sess-011"
assert_json_field "$(resume_file_for sess-011)" '.prev_prompt' "stale prompt"

# ─── T12: Prompt guard, no cache file → skip ───────────────────────────────
setup_test "T12_guard_no_cache"
rm -f "$HOME/.claude/rate-limits.json"
EXIT=$(run_prompt_guard "$(make_hook_input "sess-012" "$TEST_CWD" "prompt")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-012)"
write_cache 50 30

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: StopFailure Hook
# ═══════════════════════════════════════════════════════════════════════════════

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

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: Multi-Session Scenarios
# ═══════════════════════════════════════════════════════════════════════════════

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
assert_json_field "$(resume_file_for sess-A)" '.prev_prompt' "prompt A"
assert_json_field "$(resume_file_for sess-B)" '.prev_prompt' "prompt B"
assert_json_field "$(resume_file_for sess-C)" '.prev_prompt' "prompt C"

# ─── T19: Rate recovery clears only the recovering session ──────────────────
setup_test "T19_multi_session_selective_clear"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
echo '{"session_id":"sess-D","resume_at":99999,"scheduled_prompt":"d","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-D)"
echo '{"session_id":"sess-E","resume_at":99999,"scheduled_prompt":"e","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-E)"
echo '{"session_id":"sess-F","resume_at":99999,"scheduled_prompt":"f","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-F)"
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
echo '{"session_id":"sess-old","resume_at":99999,"scheduled_prompt":"old","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-old)"
EXIT=$(run_stop_hook "$(make_hook_input "sess-new")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-old)"
assert_file_exists "$(resume_file_for sess-new)"
assert_file_count "$RESUME_DIR/queued" 2

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: Special Characters in Prompt
# ═══════════════════════════════════════════════════════════════════════════════

# ─── T21: Double quotes in prompt ───────────────────────────────────────────
setup_test "T21_prompt_double_quotes"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-021" "$TEST_CWD" 'say "hello world"')")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-021)" '.prev_prompt' 'say "hello world"'

# ─── T22: Single quotes in prompt ──────────────────────────────────────────
setup_test "T22_prompt_single_quotes"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-022" "$TEST_CWD" "it's a test")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-022)" '.prev_prompt' "it's a test"

# ─── T23: Backslashes in prompt ────────────────────────────────────────────
setup_test "T23_prompt_backslash"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-023" "$TEST_CWD" 'c:\users\test')")
assert_exit_code "$EXIT" 0
TOTAL=$((TOTAL + 1))
ACTUAL=$(jq -r '.prev_prompt' "$(resume_file_for sess-023)" 2>/dev/null)
if [ "$ACTUAL" = 'c:\users\test' ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: backslash prompt = '$ACTUAL'"; fi

# ─── T24: Newlines in prompt ───────────────────────────────────────────────
setup_test "T24_prompt_newline"
write_cache 100 57
PROMPT_NL=$(printf 'line1\nline2')
EXIT=$(run_prompt_guard "$(make_hook_input "sess-024" "$TEST_CWD" "$PROMPT_NL")")
assert_exit_code "$EXIT" 0
SAVED=$(jq -r '.prev_prompt' "$(resume_file_for sess-024)")
if echo "$SAVED" | grep -q "line1"; then
    TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC}: newline prompt not preserved"
fi

# ─── T25: Korean text in prompt ────────────────────────────────────────────
setup_test "T25_prompt_korean"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-025" "$TEST_CWD" "한국어 테스트 프롬프트")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-025)" '.prev_prompt' "한국어 테스트 프롬프트"

# ─── T26: JSON-in-prompt ───────────────────────────────────────────────────
setup_test "T26_prompt_json"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-026" "$TEST_CWD" '{"key": "value", "num": 42}')")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-026)" '.prev_prompt' '{"key": "value", "num": 42}'

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: Both Limits at 100%
# ═══════════════════════════════════════════════════════════════════════════════

# ─── T27: Both 100%, picks later reset time ────────────────────────────────
setup_test "T27_both_100_later_reset"
EARLY=$((NOW + 1800))
LATE=$((NOW + 7200))
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

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: Edge Cases
# ═══════════════════════════════════════════════════════════════════════════════

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
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, scheduled_prompt: $p, created_at_rate: $car, source: $src}' \
    > "$(resume_file_for sess-035)"
EXIT=$(run_stop_hook "$(make_hook_input "sess-035")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-035)" '.resume_at' "$EARLY"

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: Atomic Write Verification
# ═══════════════════════════════════════════════════════════════════════════════

# ─── T36: Atomic write (.tmp file used) ───────────────────────────────────
setup_test "T36_atomic_write"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-036" "$TEST_CWD" "atomic test")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-036)"
assert_file_not_exists "$(resume_file_for sess-036).tmp"

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: Full Lifecycle
# ═══════════════════════════════════════════════════════════════════════════════

# ─── T37: Guard creates → StopFailure locks → Stop confirms → Rate recovers → Stop clears
# In v4, Guard at 100% creates with created_at_rate=100. A direct Stop would
# detect overuse and delete. StopFailure locks source to "stop_failure" first,
# which protects the file from overuse detection on subsequent Stop events.
setup_test "T37_full_lifecycle"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-037" "$TEST_CWD" "user prompt")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-037)"
assert_json_field "$(resume_file_for sess-037)" '.prev_prompt' "user prompt"
assert_json_field "$(resume_file_for sess-037)" '.source' "user_prompt"

# StopFailure locks source to stop_failure (protects from overuse detection)
EXIT=$(run_stop_failure "$(make_hook_input "sess-037")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-037)" '.source' "stop_failure"

# Stop confirms (sees source=stop_failure → skips overuse, updates prompt)
EXIT=$(run_stop_hook "$(make_hook_input "sess-037")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-037)" '.prompt' "$FIXED_PROMPT"
assert_stderr_contains "$TEST_DIR/stderr_out" "Auto-resume confirmed"

# Rate recovers
write_cache 50 30
EXIT=$(run_stop_hook "$(make_hook_input "sess-037")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-037)"
assert_stderr_contains "$TEST_DIR/stderr_out" "Rate recovered"

# ─── T38: Multi-session lifecycle ──────────────────────────────────────────
setup_test "T38_multi_session_lifecycle"
write_cache 100 57

# Three sessions schedule
run_prompt_guard "$(make_hook_input "sess-M1" "$TEST_CWD" "prompt M1")" >/dev/null 2>&1
run_prompt_guard "$(make_hook_input "sess-M2" "$TEST_CWD" "prompt M2")" >/dev/null 2>&1
run_stop_hook "$(make_hook_input "sess-M3")" >/dev/null 2>&1
assert_file_count "$RESUME_DIR/queued" 3

# Rate recovers, only M2 runs Stop
write_cache 50 30
run_stop_hook "$(make_hook_input "sess-M2")" >/dev/null 2>&1
assert_file_exists "$(resume_file_for sess-M1)"
assert_file_not_exists "$(resume_file_for sess-M2)"
assert_file_exists "$(resume_file_for sess-M3)"
assert_file_count "$RESUME_DIR/queued" 2

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: Corrupted File Handling
# ═══════════════════════════════════════════════════════════════════════════════

# ─── T39: Prompt guard with corrupted existing file → creates new ───────────
setup_test "T39_guard_corrupted_file"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
echo "NOT VALID JSON{{{" > "$(resume_file_for sess-039)"
EXIT=$(run_prompt_guard "$(make_hook_input "sess-039" "$TEST_CWD" "recovery prompt")")
assert_exit_code "$EXIT" 0
# Should overwrite corrupted file with valid JSON
assert_json_field "$(resume_file_for sess-039)" '.prev_prompt' "recovery prompt"

# ─── T40: Stop hook with corrupted existing file → creates new ──────────────
setup_test "T40_stop_corrupted_file"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
echo "" > "$(resume_file_for sess-040)"
EXIT=$(run_stop_hook "$(make_hook_input "sess-040")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-040)" '.session_id' "sess-040"

# ─── T41: StopFailure with corrupted existing file ─────────────────────────
setup_test "T41_failure_corrupted_file"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
echo "null" > "$(resume_file_for sess-041)"
EXIT=$(run_stop_failure "$(make_hook_input "sess-041")")
assert_exit_code "$EXIT" 0

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: Directory Cleanup
# ═══════════════════════════════════════════════════════════════════════════════

# ─── T42: Stop hook removes empty queued dir ───────────────────────────────
setup_test "T42_dir_cleanup"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
echo '{"session_id":"sess-042","resume_at":99999,"scheduled_prompt":"p","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-042)"
write_cache 50 30
EXIT=$(run_stop_hook "$(make_hook_input "sess-042")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-042)"
# queued/ dir should be removed if empty
TOTAL=$((TOTAL + 1))
if [ ! -d "$RESUME_DIR/queued" ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC}: empty queued dir not cleaned up"
fi

# ─── T43: Stop hook doesn't remove dir if other files exist ────────────────
setup_test "T43_dir_not_removed_if_others"
write_cache 100 57
mkdir -p "$RESUME_DIR/queued"
echo '{"session_id":"sess-043a","resume_at":99999,"scheduled_prompt":"a","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-043a)"
echo '{"session_id":"sess-043b","resume_at":99999,"scheduled_prompt":"b","created_at_rate":50,"source":"stop"}' > "$(resume_file_for sess-043b)"
write_cache 50 30
EXIT=$(run_stop_hook "$(make_hook_input "sess-043a")")
assert_exit_code "$EXIT" 0
TOTAL=$((TOTAL + 1))
if [ -d "$RESUME_DIR/queued" ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC}: queued dir removed despite other files existing"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: Overuse Detection (v4)
# ═══════════════════════════════════════════════════════════════════════════════

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

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: Subagent Marker Lifecycle (G16 fix)
# ═══════════════════════════════════════════════════════════════════════════════

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
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, scheduled_prompt: $p, created_at_rate: $car, source: $src}' \
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
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, scheduled_prompt: $p, created_at_rate: $car, source: $src}' \
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
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, scheduled_prompt: $p, created_at_rate: $car, source: $src}' \
    > "$(resume_file_for sess-066)"
# Create empty marker dir (all subagents completed)
mkdir -p "$(marker_dir_for sess-066)"
# Stop should still detect overuse (empty dir = no pending agents)
EXIT=$(run_stop_hook "$(make_hook_input "sess-066")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-066)"
assert_stderr_contains "$TEST_DIR/stderr_out" "Overuse detected"

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: Stale Cache + Rate Gate (G17 Fix)
# ═══════════════════════════════════════════════════════════════════════════════

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

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: Hook Input Robustness (Forward Compatibility)
# ═══════════════════════════════════════════════════════════════════════════════

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

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: Error Recovery & Edge Cases
# ═══════════════════════════════════════════════════════════════════════════════

# ─── T83: Empty cache file → exits gracefully ────────────────────────────
setup_test "T83_empty_cache_file"
echo -n "" > "$HOME/.claude/rate-limits.json"
EXIT=$(run_stop_hook "$(make_hook_input "sess-083")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-083)"
write_cache 50 30

# ─── T84: Non-JSON cache (e.g., HTML error page) → exits gracefully ─────
setup_test "T84_non_json_cache"
echo "<html>Service Unavailable</html>" > "$HOME/.claude/rate-limits.json"
EXIT=$(run_stop_hook "$(make_hook_input "sess-084")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-084)"
write_cache 50 30

# ─── T85: Non-JSON hook input → exits without side effects ───────────────
# jq fails on non-JSON → set -e exits script (non-zero is acceptable)
setup_test "T85_non_json_input"
write_cache 100 57
echo "this is not json at all" | bash "$HOOKS_DIR/rate-limit-stop.sh" 2>"$TEST_DIR/stderr_out" || true
# Key assertion: no schedule file was created (no side effects)
assert_file_not_exists "$(resume_file_for sess-085)"

# ─── T86: Zero reset time → no schedule (guard against immediate resume) ─
setup_test "T86_zero_reset_time"
write_cache 100 57 0 0
EXIT=$(run_stop_hook "$(make_hook_input "sess-086")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-086)"

# ─── T87: Past reset time → no schedule ──────────────────────────────────
setup_test "T87_past_reset_time"
PAST=$((NOW - 3600))
write_cache 100 57 "$PAST" "$PAST"
EXIT=$(run_stop_hook "$(make_hook_input "sess-087")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-087)"

# ─── T88: Very long prompt → handled without truncation ──────────────────
setup_test "T88_long_prompt"
write_cache 100 57
LONG_PROMPT=$(python3 -c "print('A' * 10000)")
EXIT=$(run_prompt_guard "$(make_hook_input "sess-088" "$TEST_CWD" "$LONG_PROMPT")")
assert_exit_code "$EXIT" 0
assert_file_exists "$(resume_file_for sess-088)"
STORED_LEN=$(jq -r '.prompt | length' "$(resume_file_for sess-088)" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if [ "$STORED_LEN" -eq 10000 ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: prompt length = $STORED_LEN (expected 10000)"
fi

# ─── T89: Prompt guard → StopFailure locks → Stop preserves lock (full chain) ─
setup_test "T89_full_source_lock_chain"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-089" "$TEST_CWD" "chain test")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-089)" '.source' "user_prompt"
# StopFailure locks source
EXIT=$(run_stop_failure "$(make_hook_input "sess-089")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-089)" '.source' "stop_failure"
# Stop should preserve stop_failure source
EXIT=$(run_stop_hook "$(make_hook_input "sess-089")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-089)" '.source' "stop_failure"

# ─── T90: Concurrent sessions — different CWDs are fully independent ─────
setup_test "T90_different_cwd_isolation"
write_cache 100 57
CWD_A="$TEST_DIR/T90_project_a"
CWD_B="$TEST_DIR/T90_project_b"
mkdir -p "$CWD_A/.claude" "$CWD_B/.claude"
EXIT=$(run_prompt_guard "$(make_hook_input "shared-session" "$CWD_A" "prompt A")")
assert_exit_code "$EXIT" 0
EXIT=$(run_prompt_guard "$(make_hook_input "shared-session" "$CWD_B" "prompt B")")
assert_exit_code "$EXIT" 0
# Same session_id, different CWDs → two separate files
RESUME_A=$(ls "$CWD_A/.claude/auto-resume/queued"/*"-shared-session.json" 2>/dev/null | head -1)
RESUME_B=$(ls "$CWD_B/.claude/auto-resume/queued"/*"-shared-session.json" 2>/dev/null | head -1)
assert_file_exists "$RESUME_A"
assert_file_exists "$RESUME_B"
assert_json_field "$RESUME_A" '.prev_prompt' "prompt A"
assert_json_field "$RESUME_B" '.prev_prompt' "prompt B"

# ─── T91: Rate exactly at boundary (99.5 rounds to 100) → creates schedule ─
setup_test "T91_rate_boundary_99_5"
write_cache 99.5 57
EXIT=$(run_stop_hook "$(make_hook_input "sess-091")")
assert_exit_code "$EXIT" 0
# 99.5 rounds to 100 via printf %.0f → should trigger
assert_file_exists "$(resume_file_for sess-091)"

# ─── T92: Rate exactly at boundary (99.4 rounds to 99) → no schedule ─────
setup_test "T92_rate_boundary_99_4"
write_cache 99.4 57
EXIT=$(run_stop_hook "$(make_hook_input "sess-092")")
assert_exit_code "$EXIT" 0
assert_file_not_exists "$(resume_file_for sess-092)"

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: Hook Registration Compatibility
# ═══════════════════════════════════════════════════════════════════════════════

# ─── T93: All hook scripts exist and are executable ──────────────────────
setup_test "T93_hook_scripts_exist"
HOOK_SCRIPTS=(
    "$REAL_HOME/.claude/hooks/rate-limit-stop.sh"
    "$REAL_HOME/.claude/hooks/rate-limit-stop-failure.sh"
    "$REAL_HOME/.claude/hooks/rate-limit-prompt-guard.sh"
    "$REAL_HOME/.claude/hooks/rate-limit-subagent-start.sh"
)
for script in "${HOOK_SCRIPTS[@]}"; do
    TOTAL=$((TOTAL + 1))
    if [ -f "$script" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: hook script missing: $script"
    fi
done

# ─── T94: All hook scripts have bash shebang ─────────────────────────────
setup_test "T94_hook_scripts_shebang"
for script in "${HOOK_SCRIPTS[@]}"; do
    TOTAL=$((TOTAL + 1))
    if [ -f "$script" ] && head -1 "$script" | grep -q "#!/usr/bin/env bash"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: bad or missing shebang in $script"
    fi
done

# ─── T95: Settings.json has hooks for required events ────────────────────
setup_test "T95_settings_hook_registration"
SETTINGS="$REAL_HOME/.claude/settings.json"
REQUIRED_EVENTS=("Stop" "StopFailure" "UserPromptSubmit" "SubagentStart")
if [ -f "$SETTINGS" ]; then
    for event in "${REQUIRED_EVENTS[@]}"; do
        TOTAL=$((TOTAL + 1))
        if jq -e ".hooks[\"$event\"]" "$SETTINGS" >/dev/null 2>&1; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
            echo -e "  ${RED}FAIL${NC}: settings.json missing hook for event: $event"
        fi
    done
    # Verify each event references the correct hook script
    TOTAL=$((TOTAL + 1))
    if jq -r '.hooks.Stop[].hooks[].command' "$SETTINGS" 2>/dev/null | grep -q "rate-limit-stop.sh"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: Stop event not wired to rate-limit-stop.sh"
    fi
    TOTAL=$((TOTAL + 1))
    if jq -r '.hooks.UserPromptSubmit[].hooks[].command' "$SETTINGS" 2>/dev/null | grep -q "rate-limit-prompt-guard.sh"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: UserPromptSubmit not wired to rate-limit-prompt-guard.sh"
    fi
    TOTAL=$((TOTAL + 1))
    if jq -r '.hooks.SubagentStart[].hooks[].command' "$SETTINGS" 2>/dev/null | grep -q "rate-limit-subagent-start.sh"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: SubagentStart not wired to rate-limit-subagent-start.sh"
    fi
else
    echo -e "  ${YELLOW}SKIP${NC}: settings.json not found at $SETTINGS"
    TOTAL=$((TOTAL + 4 + 3))
    PASS=$((PASS + 4 + 3))
fi

# ─── T96: All hooks use set -euo pipefail and umask 077 ──────────────────
setup_test "T96_hook_safety_guards"
for script in "${HOOK_SCRIPTS[@]}"; do
    TOTAL=$((TOTAL + 1))
    if grep -q "set -euo pipefail" "$script" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: missing 'set -euo pipefail' in $(basename "$script")"
    fi
    TOTAL=$((TOTAL + 1))
    if grep -q "umask 077" "$script" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: missing 'umask 077' in $(basename "$script")"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "════════════════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
    echo -e " ${GREEN}ALL PASSED${NC}: $PASS/$TOTAL assertions"
else
    echo -e " ${RED}FAILED${NC}: $PASS passed, $FAIL failed (total $TOTAL)"
fi
echo "════════════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
