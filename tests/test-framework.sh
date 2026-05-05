#!/usr/bin/env bash
# Shared test framework for claude-auto-resume test suite.
# Source this file at the top of each test file.
#
# Provides: assertion functions, test helpers, environment isolation, mock binaries.

set -uo pipefail

PASS=0
FAIL=0
TOTAL=0
TEST_DIR=$(mktemp -d)
REAL_HOME="$HOME"
HOOKS_DIR="$REAL_HOME/.claude/hooks"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"

export HOME="$TEST_DIR"
mkdir -p "$HOME/.claude/logs" "$HOME/.claude/bin"
echo '#!/bin/bash' > "$HOME/.claude/bin/claude-auto-resume.sh"
chmod +x "$HOME/.claude/bin/claude-auto-resume.sh"

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Assertion Functions ──

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

assert_equals() {
    local actual="$1" expected="$2" msg="${3:-value mismatch}"
    TOTAL=$((TOTAL + 1))
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: $msg: '$actual' (expected '$expected')"
    fi
}

assert_not_empty() {
    local value="$1" msg="${2:-expected non-empty value}"
    TOTAL=$((TOTAL + 1))
    if [ -n "$value" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
    fi
}

assert_dir_exists() {
    TOTAL=$((TOTAL + 1))
    if [ -d "$1" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: expected directory to exist: $1"
    fi
}

assert_dir_not_exists() {
    TOTAL=$((TOTAL + 1))
    if [ ! -d "$1" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: expected directory NOT to exist: $1"
    fi
}

assert_file_permission() {
    local file="$1" expected="$2"
    TOTAL=$((TOTAL + 1))
    local actual
    actual=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null)
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: permission on $file = $actual (expected $expected)"
    fi
}

assert_not_symlink() {
    local path="$1"
    TOTAL=$((TOTAL + 1))
    if [ ! -L "$path" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}: expected non-symlink: $path"
    fi
}

# ── Installed library (timestamped resume files) ──

_LIB="$REAL_HOME/.claude/hooks/lib-resume-file.sh"
if [ -f "$_LIB" ]; then
    source "$_LIB"
    HAS_LIB_RESUME=true
else
    HAS_LIB_RESUME=false
    # Fallback implementations for legacy naming
    find_resume_file() {
        local dir=$1 sid=$2
        [ -f "$dir/${sid}.json" ] && echo "$dir/${sid}.json" && return 0
        return 1
    }
    new_resume_filename() {
        local dir=$1 sid=$2
        echo "$dir/${sid}.json"
    }
fi

# ── Test Helpers ──

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

# resume_file_for: find existing resume file for a session, or return legacy path for pre-creation
resume_file_for() {
    local sid="$1"
    local found
    found=$(find_resume_file "$RESUME_DIR/queued" "$sid" 2>/dev/null) && echo "$found" && return 0
    # Not found — return legacy path (used for pre-creating test fixtures)
    echo "$RESUME_DIR/queued/$sid.json"
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

marker_file_for() {
    local session_id="$1" agent_id="$2"
    echo "$RESUME_DIR/subagents/$session_id/$agent_id"
}

marker_dir_for() {
    local session_id="$1"
    echo "$RESUME_DIR/subagents/$session_id"
}

# ── Mock Binaries ──

export PATH="$TEST_DIR/bin:$PATH"
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/nohup" <<'MOCKEOF'
#!/bin/bash
echo "NOHUP_CALLED: $*" >> "${TEST_DIR:-/tmp}/nohup_calls.log"
MOCKEOF
chmod +x "$TEST_DIR/bin/nohup"

cat > "$TEST_DIR/bin/pkill" <<'MOCKEOF'
#!/bin/bash
echo "PKILL_CALLED: $*" >> "${TEST_DIR:-/tmp}/pkill_calls.log"
MOCKEOF
chmod +x "$TEST_DIR/bin/pkill"

export TEST_DIR

# ── Hook Runners ──

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

# ── Summary ──

print_summary() {
    local suite_name="${1:-Tests}"
    echo ""
    echo "────────────────────────────────────────────────────"
    if [ "$FAIL" -eq 0 ]; then
        echo -e " ${GREEN}PASSED${NC}: $PASS/$TOTAL assertions  [$suite_name]"
    else
        echo -e " ${RED}FAILED${NC}: $PASS passed, $FAIL failed (total $TOTAL)  [$suite_name]"
    fi
    echo "────────────────────────────────────────────────────"
    return "$FAIL"
}
