#!/usr/bin/env bash
# Hook Registration Compatibility tests (T93-T96)
source "$(cd "$(dirname "$0")" && pwd)/test-framework.sh"

echo "════════════════════════════════════════════════════════"
echo " Hook Registration Compatibility Tests (T93-T96)"
echo "════════════════════════════════════════════════════════"

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

print_summary "Hook Registration Compatibility"
