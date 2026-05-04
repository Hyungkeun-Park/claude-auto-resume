#!/usr/bin/env bash
# Stop hook: manage auto-resume schedule based on rate limit state.
#
# Each session manages its own file in <project>/.claude/auto-resume/queued/<session-id>.json
#
# State machine (for MY session only):
# - rate 100% + my file doesn't exist → create (fixed prompt, spawn resume)
# - rate 100% + my file exists → update resume_at and prompt
# - rate < 100% + my file exists → delete + kill my resume process
# - rate < 100% + my file doesn't exist → nothing
#
# Cancel: rm <project>/.claude/auto-resume/queued/<session-id>.json
# Cancel all: rm -rf <project>/.claude/auto-resume/queued/

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)

# 1. Wait briefly for statusline to flush rate-limits.json
sleep 0.3

# 2. Read rate limit cache
CACHE="$HOME/.claude/rate-limits.json"
if [ ! -f "$CACHE" ]; then
    if ! jq -r '.statusLine.command // ""' "$HOME/.claude/settings.json" 2>/dev/null | grep -q "statusline-rate-cache-wrapper"; then
        echo "⚠️ Auto-resume: statusline not configured. Run /setup-auto-resume to set up." >&2
    fi
    exit 0
fi
DATA=$(jq '.' "$CACHE" 2>/dev/null) || exit 0

# 3. Freshness check (skip if cache older than 5 minutes)
LAST_UPDATED=$(echo "$DATA" | jq -r '.last_updated // 0')
NOW=$(date +%s)
[ $((NOW - LAST_UPDATED)) -gt 300 ] && exit 0

# 4. Check rate limits
FIVE_PCT=$(echo "$DATA" | jq -r '.rate_limits.five_hour.used_percentage // 0')
FIVE_RESET=$(echo "$DATA" | jq -r '.rate_limits.five_hour.resets_at // 0')
SEVEN_PCT=$(echo "$DATA" | jq -r '.rate_limits.seven_day.used_percentage // 0')
SEVEN_RESET=$(echo "$DATA" | jq -r '.rate_limits.seven_day.resets_at // 0')

FIVE_INT=$(printf '%.0f' "$FIVE_PCT" 2>/dev/null || echo 0)
SEVEN_INT=$(printf '%.0f' "$SEVEN_PCT" 2>/dev/null || echo 0)

CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
[ -z "$CWD" ] && exit 0

# Project-level opt-out
CONF="$CWD/.claude/auto-resume.conf"
if [ -f "$CONF" ] && grep -qi "^enabled=false" "$CONF" 2>/dev/null; then
    exit 0
fi

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
[ -z "$SESSION_ID" ] && exit 0

RESUME_DIR="$CWD/.claude/auto-resume"
QUEUED_DIR="$RESUME_DIR/queued"
RESUME_FILE="$QUEUED_DIR/${SESSION_ID}.json"

# 5. Rate < 100%: clean up MY schedule if exists
if [ "$FIVE_INT" -lt 100 ] && [ "$SEVEN_INT" -lt 100 ]; then
    if [ -f "$RESUME_FILE" ]; then
        rm -f "$RESUME_FILE"
        pkill -f "claude-auto-resume.sh.*$SESSION_ID" 2>/dev/null || true
        rmdir "$QUEUED_DIR" 2>/dev/null || true
        echo "$(date -Iseconds) CLEARED session=$SESSION_ID cwd=$CWD" \
            >> "$HOME/.claude/logs/auto-resume-$(date +%Y-%m-%d).log"
        echo "✅ Rate recovered. Auto-resume cleared." >&2
    fi
    exit 0
fi

# 6. Rate 100%: determine resume time
if [ "$FIVE_INT" -ge 100 ] && [ "$SEVEN_INT" -ge 100 ]; then
    [ "$SEVEN_RESET" -gt "$FIVE_RESET" ] && RESUME_AT=$SEVEN_RESET || RESUME_AT=$FIVE_RESET
elif [ "$SEVEN_INT" -ge 100 ]; then
    RESUME_AT=$SEVEN_RESET
else
    RESUME_AT=$FIVE_RESET
fi

# Too far in the future (>8 hours) — skip
[ $((RESUME_AT - NOW)) -gt 28800 ] && exit 0

RESUME_DATE=$(date -d "@$RESUME_AT" -Iseconds 2>/dev/null || date -r "$RESUME_AT" -Iseconds 2>/dev/null || echo "$RESUME_AT")
FIXED_PROMPT="If any agents failed in the previous task, do not perform their work directly — re-launch the same agents. If it was not an agent failure, continue with the remaining work."

mkdir -p "$QUEUED_DIR"
mkdir -p "$HOME/.claude/logs"

# 7. My file exists → update prompt and resume_at (if valid JSON)
if [ -f "$RESUME_FILE" ]; then
    EXISTING_SID=$(jq -r '.session_id // empty' "$RESUME_FILE" 2>/dev/null || echo "")
    if [ -n "$EXISTING_SID" ]; then
        jq --arg p "$FIXED_PROMPT" --argjson rat "$RESUME_AT" --arg rah "$RESUME_DATE" \
            '.prompt = $p | .resume_at = $rat | .resume_at_human = $rah' \
            "$RESUME_FILE" > "$RESUME_FILE.tmp" 2>/dev/null && mv "$RESUME_FILE.tmp" "$RESUME_FILE"
        echo "⏳ Auto-resume confirmed at $RESUME_DATE" >&2
        exit 0
    fi
    # File corrupted — fall through to create
    rm -f "$RESUME_FILE"
fi

# 8. No file → create with fixed prompt + spawn resume process
jq -n \
    --arg sid "$SESSION_ID" \
    --argjson rat "$RESUME_AT" \
    --arg rah "$RESUME_DATE" \
    --argjson sat "$NOW" \
    --arg p "$FIXED_PROMPT" \
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, prompt: $p}' \
    > "$RESUME_FILE.tmp" && mv "$RESUME_FILE.tmp" "$RESUME_FILE"

nohup bash "$HOME/.claude/bin/claude-auto-resume.sh" "$SESSION_ID" "$RESUME_AT" "$CWD" \
    >> "$HOME/.claude/logs/resume-${SESSION_ID}.log" 2>&1 &

echo "$(date -Iseconds) SCHEDULED session=$SESSION_ID resume_at=$RESUME_DATE five=${FIVE_PCT}% seven=${SEVEN_PCT}% cwd=$CWD" \
    >> "$HOME/.claude/logs/auto-resume-$(date +%Y-%m-%d).log"

echo "⏳ Auto-resume confirmed at $RESUME_DATE" >&2
echo "   Cancel: rm $RESUME_FILE" >&2

exit 0
