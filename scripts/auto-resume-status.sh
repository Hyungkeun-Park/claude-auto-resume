#!/usr/bin/env bash
# Print auto-resume status dashboard

command -v jq >/dev/null 2>&1 || { echo "jq required but not found"; exit 1; }

CWD="${1:-$(pwd)}"

echo "═══ Auto-Resume Status ═══"
echo ""

# ── Global Installation ──
echo "Global Installation:"

SCRIPT_COUNT=0
for f in ~/.claude/hooks/rate-limit-stop.sh ~/.claude/hooks/rate-limit-stop-failure.sh ~/.claude/hooks/rate-limit-prompt-guard.sh ~/.claude/bin/claude-auto-resume.sh ~/.claude/bin/statusline-rate-cache-wrapper.sh; do
    [ -x "$f" ] && SCRIPT_COUNT=$((SCRIPT_COUNT + 1))
done
if [ "$SCRIPT_COUNT" -eq 5 ]; then
    echo "  Scripts:    ✓ installed ($SCRIPT_COUNT/5)"
else
    echo "  Scripts:    ✗ installed ($SCRIPT_COUNT/5)"
fi

HOOK_LIST=""
HOOK_COUNT=0
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
    for event in Stop SubagentStop StopFailure UserPromptSubmit; do
        case "$event" in
            StopFailure) pattern="rate-limit-stop-failure" ;;
            UserPromptSubmit) pattern="rate-limit-prompt-guard" ;;
            *) pattern="rate-limit-stop" ;;
        esac
        if jq -e ".hooks.${event}[0].hooks[]?.command" "$SETTINGS" 2>/dev/null | grep -q "$pattern"; then
            HOOK_COUNT=$((HOOK_COUNT + 1))
            [ -n "$HOOK_LIST" ] && HOOK_LIST="$HOOK_LIST, "
            HOOK_LIST="$HOOK_LIST$event"
        fi
    done
fi
if [ "$HOOK_COUNT" -eq 4 ]; then
    echo "  Hooks:      ✓ registered ($HOOK_LIST)"
else
    echo "  Hooks:      ✗ registered ($HOOK_COUNT/4: $HOOK_LIST)"
fi

if [ -f "$SETTINGS" ] && jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null | grep -q "statusline-rate-cache-wrapper"; then
    echo "  Statusline: ✓ configured"
else
    echo "  Statusline: ✗ not configured"
fi

# ── Project ──
echo ""
echo "Project: $CWD"

CONF="$CWD/.claude/auto-resume.conf"
if [ -f "$CONF" ]; then
    if grep -qi "^enabled=false" "$CONF" 2>/dev/null; then
        echo "  Enabled:    ✗ disabled (auto-resume.conf)"
    else
        echo "  Enabled:    ✓ enabled (auto-resume.conf)"
    fi
else
    echo "  Enabled:    ✓ enabled (default, no conf)"
fi

QUEUED=$(ls "$CWD/.claude/auto-resume/queued/" 2>/dev/null | wc -l)
SUCCESS=$(ls "$CWD/.claude/auto-resume/success/" 2>/dev/null | wc -l)
FAILED=$(ls "$CWD/.claude/auto-resume/failed/" 2>/dev/null | wc -l)
echo "  Queued:     $QUEUED sessions"
echo "  Success:    $SUCCESS sessions"
echo "  Failed:     $FAILED sessions"

DAEMONS=$(pgrep -af "claude-auto-resume.sh" 2>/dev/null | grep -v grep | grep -v "auto-resume-status" | wc -l)
echo "  Daemons:    $DAEMONS running"
