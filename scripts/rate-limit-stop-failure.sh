#!/usr/bin/env bash
# StopFailure hook: schedule auto-resume when API error ends the turn.
# Fallback for cases where Stop hook didn't fire (e.g., API-level rate limit error).
#
# Each session manages its own file in <project>/.claude/auto-resume/queued/yymmdd-hhmmss-<session-id>.json
#
# Logic:
# - rate < 100% → nothing
# - rate 100% + my file exists → lock source to stop_failure
# - rate 100% + no file for me → create + spawn
#
# Cancel: rm <project>/.claude/auto-resume/queued/*-<session-id>.json

set -euo pipefail
umask 077

_LIB="${BASH_SOURCE[0]%/*}/lib-resume-file.sh"
[ -f "$_LIB" ] || _LIB="$HOME/.claude/hooks/lib-resume-file.sh"
source "$_LIB"

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)

# 1. Read rate limit cache
CACHE="$HOME/.claude/rate-limits.json"
if [ ! -f "$CACHE" ]; then
    if ! jq -r '.statusLine.command // ""' "$HOME/.claude/settings.json" 2>/dev/null | grep -q "statusline-rate-cache-wrapper"; then
        echo "⚠️ Auto-resume: statusline not configured. Run /setup-auto-resume to set up." >&2
    fi
    exit 0
fi
DATA=$(jq '.' "$CACHE" 2>/dev/null) || exit 0

# 2. Check rate limits (before freshness gate — needed for stale-but-at-limit logic)
FIVE_PCT=$(echo "$DATA" | jq -r '.rate_limits.five_hour.used_percentage // 0')
FIVE_RESET=$(echo "$DATA" | jq -r '.rate_limits.five_hour.resets_at // 0')
SEVEN_PCT=$(echo "$DATA" | jq -r '.rate_limits.seven_day.used_percentage // 0')
SEVEN_RESET=$(echo "$DATA" | jq -r '.rate_limits.seven_day.resets_at // 0')

FIVE_INT=$(printf '%.0f' "$FIVE_PCT" 2>/dev/null || echo 0)
SEVEN_INT=$(printf '%.0f' "$SEVEN_PCT" 2>/dev/null || echo 0)

# 3. Freshness + rate gate
# Rate only resets downward — stale cache at ≥100% is still valid for scheduling
LAST_UPDATED=$(echo "$DATA" | jq -r '.last_updated // 0')
NOW=$(date +%s)
if [ $((NOW - LAST_UPDATED)) -gt 300 ] && [ "$FIVE_INT" -lt 100 ] && [ "$SEVEN_INT" -lt 100 ]; then
    exit 0
fi

[ "$FIVE_INT" -lt 100 ] && [ "$SEVEN_INT" -lt 100 ] && exit 0

# 4. Identify session and project
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
[ -z "$CWD" ] && exit 0

# Project-level opt-out
CONF="$CWD/.claude/auto-resume.conf"
if [ -f "$CONF" ] && grep -qi "^enabled=false" "$CONF" 2>/dev/null; then
    exit 0
fi

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
[ -z "$SESSION_ID" ] && exit 0
[[ ! "$SESSION_ID" =~ ^[a-zA-Z0-9._-]+$ ]] && exit 0

RESUME_DIR="$CWD/.claude/auto-resume"
QUEUED_DIR="$RESUME_DIR/queued"
RESUME_FILE=$(find_resume_file "$QUEUED_DIR" "$SESSION_ID") || RESUME_FILE=""

# Already scheduled for this session → lock source to stop_failure
if [ -n "$RESUME_FILE" ]; then
    EXISTING_SID=$(jq -r '.session_id // empty' "$RESUME_FILE" 2>/dev/null || echo "")
    if [ -n "$EXISTING_SID" ]; then
        jq '.source = "stop_failure"' "$RESUME_FILE" > "$RESUME_FILE.tmp" 2>/dev/null && mv "$RESUME_FILE.tmp" "$RESUME_FILE" || rm -f "$RESUME_FILE.tmp"
        EXISTING_TIME=$(jq -r '.resume_at_human // "unknown"' "$RESUME_FILE" 2>/dev/null || echo "unknown")
        EXISTING_AT=$(jq -r '.resume_at // 0' "$RESUME_FILE" 2>/dev/null || echo "0")
        EXISTING_INT=$(printf '%.0f' "$EXISTING_AT" 2>/dev/null || echo 0)
        DELTA=$((EXISTING_INT - NOW)); MINS=$((DELTA / 60)); SECS=$((DELTA % 60))
        echo -e "⏳ Auto-resume already scheduled at $EXISTING_TIME (in ${MINS}m ${SECS}s) [locked by stop_failure]\n   State: $RESUME_FILE\n   Cancel: rm $RESUME_FILE" >&2
        exit 0
    fi
    # File corrupted — fall through to create
    rm -f "$RESUME_FILE"
fi

# 5. Determine resume time
if [ "$FIVE_INT" -ge 100 ] && [ "$SEVEN_INT" -ge 100 ]; then
    [ "$SEVEN_RESET" -gt "$FIVE_RESET" ] && RESUME_AT=$SEVEN_RESET || RESUME_AT=$FIVE_RESET
elif [ "$SEVEN_INT" -ge 100 ]; then
    RESUME_AT=$SEVEN_RESET
else
    RESUME_AT=$FIVE_RESET
fi

[ "$RESUME_AT" -le "$NOW" ] && exit 0
[ $((RESUME_AT - NOW)) -gt 28800 ] && exit 0

# 6. Create schedule
RESUME_DATE=$(human_ts "$RESUME_AT")
CURRENT_RATE=$(echo "$FIVE_PCT $SEVEN_PCT" | awk '{print ($1 > $2) ? $1 : $2}')

mkdir -p "$QUEUED_DIR"
RESUME_FILE=$(new_resume_filename "$QUEUED_DIR" "$SESSION_ID")
jq -n \
    --arg sid "$SESSION_ID" \
    --argjson rat "$RESUME_AT" \
    --arg rah "$RESUME_DATE" \
    --argjson sat "$NOW" \
    --arg sah "$(human_ts "$NOW")" \
    --arg p "If any agents failed in the previous task, do not perform their work directly — re-launch the same agents. If it was not an agent failure, continue with the remaining work." \
    --argjson car "$CURRENT_RATE" \
    --arg src "stop_failure" \
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, scheduled_at_human: $sah, prompt: $p, created_at_rate: $car, source: $src}' \
    > "$RESUME_FILE.tmp" && mv "$RESUME_FILE.tmp" "$RESUME_FILE" || rm -f "$RESUME_FILE.tmp"

# 7. Spawn resume process
mkdir -p "$HOME/.claude/logs"
nohup bash "$HOME/.claude/bin/claude-auto-resume.sh" "$SESSION_ID" "$RESUME_AT" "$CWD" \
    >> "$HOME/.claude/logs/resume-${SESSION_ID}.log" 2>&1 &

# 8. Log + stderr
echo "$(date +"%Y-%m-%dT%H:%M:%S%z") SCHEDULED_BY_FAILURE session=$SESSION_ID resume_at=$RESUME_DATE five=${FIVE_PCT}% seven=${SEVEN_PCT}% cwd=$CWD" \
    >> "$HOME/.claude/logs/auto-resume-$(date +%Y-%m-%d).log"

DELTA=$((RESUME_AT - NOW)); MINS=$((DELTA / 60)); SECS=$((DELTA % 60))
echo -e "⏳ Auto-resume scheduled at $RESUME_DATE (in ${MINS}m ${SECS}s) [locked by stop_failure]\n   State: $RESUME_FILE\n   Cancel: rm $RESUME_FILE" >&2

exit 0
