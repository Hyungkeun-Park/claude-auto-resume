#!/usr/bin/env bash
# Stop hook: manage auto-resume schedule based on rate limit state.
#
# Each session manages its own file in <project>/.claude/auto-resume/queued/yymmdd-hhmmss-<session-id>.json
#
# State machine (for MY session only):
# - rate 100% + my file doesn't exist → create (fixed scheduled_prompt, spawn resume)
# - rate 100% + my file exists → update resume_at and scheduled_prompt
# - rate < 100% + my file exists → delete + kill my resume process
# - rate < 100% + my file doesn't exist → nothing
#
# Subagent marker lifecycle (G16 fix):
# - SubagentStart hook creates marker in subagents/<session>/<agent_id>
# - SubagentStop deletes marker (before cache check, so stale cache won't skip it)
# - Stop checks for surviving markers → skips overuse detection if any exist
#
# Cancel: rm <project>/.claude/auto-resume/queued/*-<session-id>.json
# Cancel all: rm -rf <project>/.claude/auto-resume/queued/

set -euo pipefail
umask 077

_LIB="${BASH_SOURCE[0]%/*}/lib-resume-file.sh"
[ -f "$_LIB" ] || _LIB="$HOME/.claude/hooks/lib-resume-file.sh"
source "$_LIB"

command -v jq >/dev/null 2>&1 || exit 0

cleanup_markers() {
    local dir="$RESUME_DIR/subagents/$SESSION_ID"
    [ -d "$dir" ] && rm -rf "$dir"
    rmdir "$RESUME_DIR/subagents" 2>/dev/null || true
}

schedule_session_kill() {
    local resume_file=$1
    local claude_pid=""
    for pid in $(pgrep -x claude 2>/dev/null || true); do
        local cmdline=$(ps -o args= -p "$pid" 2>/dev/null || true)
        if [ -n "$cmdline" ] && echo "$cmdline" | grep -q "$SESSION_ID" && ! echo "$cmdline" | grep -q "auto-resume"; then
            claude_pid="$pid"
            break
        fi
    done
    if [ -n "$claude_pid" ]; then
        (sleep 60 && [ -f "$resume_file" ] && kill "$claude_pid" 2>/dev/null) &
        _diag "KILL_SCHEDULED" "pid=$claude_pid delay=60s"
    fi
}

INPUT=$(cat)

DIAG_LOG="$HOME/.claude/logs/auto-resume-$(date +%Y-%m-%d).log"
_diag() { echo "$(date +"%Y-%m-%dT%H:%M:%S%z") DIAG[$1] $2" >> "$DIAG_LOG" 2>/dev/null || true; }

# ── 0. Extract session context early (needed for marker cleanup before cache check) ──
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "Stop"')
_diag "ENTER" "event=$EVENT keys=$(echo "$INPUT" | jq -r 'keys | join(",")')"

CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
if [ -z "$CWD" ]; then
    _diag "EXIT" "reason=empty_cwd"
    exit 0
fi

CONF="$CWD/.claude/auto-resume.conf"
if [ -f "$CONF" ] && grep -qi "^enabled=false" "$CONF" 2>/dev/null; then
    exit 0
fi

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
if [ -z "$SESSION_ID" ]; then
    _diag "EXIT" "reason=empty_session_id"
    exit 0
fi
if [[ ! "$SESSION_ID" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    _diag "EXIT" "reason=invalid_session_id id=$SESSION_ID"
    exit 0
fi

RESUME_DIR="$CWD/.claude/auto-resume"
QUEUED_DIR="$RESUME_DIR/queued"
RESUME_FILE=$(find_resume_file "$QUEUED_DIR" "$SESSION_ID") || RESUME_FILE=""

# ── 0b. SubagentStop: delete marker unconditionally (before cache check) ──
if [ "$EVENT" = "SubagentStop" ]; then
    AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // ""')
    if [ -n "$AGENT_ID" ] && [[ "$AGENT_ID" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        rm -f "$RESUME_DIR/subagents/$SESSION_ID/$AGENT_ID"
        rmdir "$RESUME_DIR/subagents/$SESSION_ID" 2>/dev/null || true
        rmdir "$RESUME_DIR/subagents" 2>/dev/null || true
    fi
fi

# ── 1. Wait briefly for statusline to flush rate-limits.json ──
sleep 0.3

# ── 2. Read rate limit cache ──
CACHE="$HOME/.claude/rate-limits.json"
if [ ! -f "$CACHE" ]; then
    _diag "EXIT" "reason=no_cache_file"
    if ! jq -r '.statusLine.command // ""' "$HOME/.claude/settings.json" 2>/dev/null | grep -q "statusline-rate-cache-wrapper"; then
        echo "⚠️ Auto-resume: statusline not configured. Run /setup-auto-resume to set up." >&2
    fi
    exit 0
fi
DATA=$(jq '.' "$CACHE" 2>/dev/null) || { _diag "EXIT" "reason=cache_parse_fail"; exit 0; }

# ── 3. Check rate limits (before freshness gate) ──
FIVE_PCT=$(echo "$DATA" | jq -r '.rate_limits.five_hour.used_percentage // 0')
FIVE_RESET=$(echo "$DATA" | jq -r '.rate_limits.five_hour.resets_at // 0')
SEVEN_PCT=$(echo "$DATA" | jq -r '.rate_limits.seven_day.used_percentage // 0')
SEVEN_RESET=$(echo "$DATA" | jq -r '.rate_limits.seven_day.resets_at // 0')

FIVE_INT=$(printf '%.0f' "$FIVE_PCT" 2>/dev/null || echo 0)
SEVEN_INT=$(printf '%.0f' "$SEVEN_PCT" 2>/dev/null || echo 0)

# ── 4. Freshness + rate gate ──
# Rate only resets downward — stale cache at ≥100% is still valid for scheduling
LAST_UPDATED=$(echo "$DATA" | jq -r '.last_updated // 0')
NOW=$(date +%s)
CACHE_AGE=$((NOW - LAST_UPDATED))
if [ "$CACHE_AGE" -gt 300 ] && [ "$FIVE_INT" -lt 100 ] && [ "$SEVEN_INT" -lt 100 ]; then
    _diag "EXIT" "reason=stale_cache age=${CACHE_AGE}s last_updated=$LAST_UPDATED"
    exit 0
fi

_diag "RATE" "five=${FIVE_PCT}% seven=${SEVEN_PCT}% cache_age=${CACHE_AGE}s"

# ── 5. Rate < 100%: clean up MY schedule if exists ──
if [ "$FIVE_INT" -lt 100 ] && [ "$SEVEN_INT" -lt 100 ]; then
    _diag "BELOW100" "event=$EVENT five=${FIVE_INT}% seven=${SEVEN_INT}% file_exists=$([ -n "$RESUME_FILE" ] && echo Y || echo N)"
    if [ -n "$RESUME_FILE" ]; then
        CLEARED_SOURCE=$(jq -r '.source // ""' "$RESUME_FILE" 2>/dev/null || echo "")
        CLEARED_RATE=$(jq -r '.created_at_rate // 0' "$RESUME_FILE" 2>/dev/null || echo "0")
        CLEARED_RATE_INT=$(printf '%.0f' "$CLEARED_RATE" 2>/dev/null || echo 0)
        rm -f "$RESUME_FILE"
        rm -f "$(prompt_side_file "$RESUME_DIR" "$SESSION_ID")"
        rmdir "$RESUME_DIR/prompts" 2>/dev/null || true
        cleanup_markers
        for _pid in $(pgrep -f "claude-auto-resume" 2>/dev/null || true); do
            _pcmd=$(ps -o args= -p "$_pid" 2>/dev/null || true)
            [ -n "$_pcmd" ] && echo "$_pcmd" | grep -q "$SESSION_ID" && kill "$_pid" 2>/dev/null || true
        done
        rmdir "$QUEUED_DIR" 2>/dev/null || true
        if [ "$CLEARED_RATE_INT" -ge 100 ] && [ "$CLEARED_SOURCE" != "stop_failure" ]; then
            echo "$(date +"%Y-%m-%dT%H:%M:%S%z") OVERUSE_CLEARED session=$SESSION_ID source=$CLEARED_SOURCE created_at_rate=$CLEARED_RATE cwd=$CWD" \
                >> "$HOME/.claude/logs/auto-resume-$(date +%Y-%m-%d).log"
        else
            echo "$(date +"%Y-%m-%dT%H:%M:%S%z") CLEARED session=$SESSION_ID cwd=$CWD" \
                >> "$HOME/.claude/logs/auto-resume-$(date +%Y-%m-%d).log"
        fi
        echo "✅ Rate recovered. Auto-resume cleared." >&2
    else
        cleanup_markers
        rm -f "$(prompt_side_file "$RESUME_DIR" "$SESSION_ID")"
        rmdir "$RESUME_DIR/prompts" 2>/dev/null || true
    fi
    exit 0
fi

# ── 6. Rate 100%: determine resume time ──
if [ "$FIVE_INT" -ge 100 ] && [ "$SEVEN_INT" -ge 100 ]; then
    [ "$SEVEN_RESET" -gt "$FIVE_RESET" ] && RESUME_AT=$SEVEN_RESET || RESUME_AT=$FIVE_RESET
elif [ "$SEVEN_INT" -ge 100 ]; then
    RESUME_AT=$SEVEN_RESET
else
    RESUME_AT=$FIVE_RESET
fi

# Resume time in the past or zero — bad data, skip
[ "$RESUME_AT" -le "$NOW" ] && exit 0
# Too far in the future (>8 hours) — skip
[ $((RESUME_AT - NOW)) -gt 28800 ] && exit 0

RESUME_DATE=$(human_ts "$RESUME_AT")
FIXED_PROMPT="If any agents failed in the previous task, do not perform their work directly — re-launch the same agents. If it was not an agent failure, continue with the remaining work."

mkdir -p "$QUEUED_DIR"
mkdir -p "$HOME/.claude/logs"

# ── 7. Overuse detection: Stop only (not SubagentStop) ──
if [ "$EVENT" = "Stop" ] && [ -n "$RESUME_FILE" ]; then
    # G16 fix: surviving subagent markers mean a rate-limited subagent hasn't
    # fired SubagentStop yet — skip overuse detection to preserve the schedule
    MARKER_DIR="$RESUME_DIR/subagents/$SESSION_ID"
    SKIP_OVERUSE=false
    if [ -d "$MARKER_DIR" ] && [ -n "$(ls -A "$MARKER_DIR" 2>/dev/null)" ]; then
        MARKER_COUNT=$(ls -A "$MARKER_DIR" 2>/dev/null | wc -l | tr -d ' ')
        _diag "SUBAGENT_PENDING" "markers=$MARKER_COUNT"
        echo "$(date +"%Y-%m-%dT%H:%M:%S%z") OVERUSE_SKIPPED_SUBAGENT session=$SESSION_ID pending_agents=$MARKER_COUNT" \
            >> "$HOME/.claude/logs/auto-resume-$(date +%Y-%m-%d).log"
        SKIP_OVERUSE=true
    fi

    if [ "$SKIP_OVERUSE" = "false" ]; then
        CREATED_RATE=$(jq -r '.created_at_rate // 0' "$RESUME_FILE" 2>/dev/null || echo "0")
        FILE_SOURCE=$(jq -r '.source // ""' "$RESUME_FILE" 2>/dev/null || echo "")
        CREATED_INT=$(printf '%.0f' "$CREATED_RATE" 2>/dev/null || echo 0)

        if [ "$CREATED_INT" -ge 100 ] && [ "$FILE_SOURCE" = "stop" ]; then
            # Re-read source to close TOCTOU window (StopFailure may have locked it between reads)
            FILE_SOURCE=$(jq -r '.source // ""' "$RESUME_FILE" 2>/dev/null || echo "")
            if [ "$FILE_SOURCE" = "stop" ]; then
                # Stop-created schedule + another turn completed at 100% → overuse confirmed
                rm -f "$RESUME_FILE"
                cleanup_markers
                for _pid in $(pgrep -f "claude-auto-resume" 2>/dev/null || true); do
                    _pcmd=$(ps -o args= -p "$_pid" 2>/dev/null || true)
                    [ -n "$_pcmd" ] && echo "$_pcmd" | grep -q "$SESSION_ID" && kill "$_pid" 2>/dev/null || true
                done
                rmdir "$QUEUED_DIR" 2>/dev/null || true
                echo "$(date +"%Y-%m-%dT%H:%M:%S%z") OVERUSE_DETECTED session=$SESSION_ID source=$FILE_SOURCE created_at_rate=$CREATED_RATE" \
                    >> "$HOME/.claude/logs/auto-resume-$(date +%Y-%m-%d).log"
                echo "✅ Overuse detected (turn completed at 100%). Schedule cancelled." >&2
                exit 0
            fi
        fi
    fi
fi

CURRENT_RATE=$(echo "$FIVE_PCT $SEVEN_PCT" | awk '{print ($1 > $2) ? $1 : $2}')
if [ "$EVENT" = "Stop" ]; then
    SOURCE="stop"
else
    SOURCE="subagent_stop"
fi

# ── 7b. Determine prompt: saved user prompt or fixed (subagent relaunch) ──
SELECTED_PROMPT="$FIXED_PROMPT"
PROMPT_SOURCE="fixed"
PROMPT_SIDE_FILE=$(prompt_side_file "$RESUME_DIR" "$SESSION_ID")
MARKER_DIR_PROMPT="$RESUME_DIR/subagents/$SESSION_ID"
HAS_MARKERS_PROMPT=false
if [ -d "$MARKER_DIR_PROMPT" ] && [ -n "$(ls -A "$MARKER_DIR_PROMPT" 2>/dev/null)" ]; then
    HAS_MARKERS_PROMPT=true
fi
if [ "$HAS_MARKERS_PROMPT" = "false" ] && [ -f "$PROMPT_SIDE_FILE" ] && [ ! -L "$PROMPT_SIDE_FILE" ]; then
    SAVED_USER_PROMPT=$(cat "$PROMPT_SIDE_FILE" 2>/dev/null || echo "")
    if [ -n "$SAVED_USER_PROMPT" ]; then
        SELECTED_PROMPT="$SAVED_USER_PROMPT"
        PROMPT_SOURCE="saved_user_prompt"
    fi
fi
_diag "PROMPT_SELECTED" "source=$PROMPT_SOURCE has_markers=$HAS_MARKERS_PROMPT side_file=$([ -f "$PROMPT_SIDE_FILE" ] && echo Y || echo N)"

# ── 8. My file exists → update scheduled_prompt and resume_at (if valid JSON) ──
[ -n "$RESUME_FILE" ] && [ -L "$RESUME_FILE" ] && rm -f "$RESUME_FILE" && RESUME_FILE=""
if [ -n "$RESUME_FILE" ]; then
    EXISTING_SID=$(jq -r '.session_id // empty' "$RESUME_FILE" 2>/dev/null || echo "")
    if [ -n "$EXISTING_SID" ]; then
        jq --arg p "$SELECTED_PROMPT" --argjson rat "$RESUME_AT" --arg rah "$RESUME_DATE" --arg src "$SOURCE" --argjson car "$CURRENT_RATE" \
            '.scheduled_prompt = $p | .resume_at = $rat | .resume_at_human = $rah | .created_at_rate = $car | .source = (if .source == "stop_failure" then "stop_failure" else $src end)' \
            "$RESUME_FILE" > "$RESUME_FILE.tmp" 2>/dev/null && mv "$RESUME_FILE.tmp" "$RESUME_FILE" || rm -f "$RESUME_FILE.tmp"
        DELTA=$((RESUME_AT - NOW)); MINS=$((DELTA / 60)); SECS=$((DELTA % 60))
        echo -e "⏳ Auto-resume scheduled at $RESUME_DATE (in ${MINS}m ${SECS}s)\n   Session will terminate in 60s for scheduled resume.\n   Cancel: rm $RESUME_FILE" >&2
        schedule_session_kill "$RESUME_FILE"
        exit 0
    fi
    # File corrupted — fall through to create
    rm -f "$RESUME_FILE"
fi

# ── 9. No file → create with selected prompt + spawn resume process ──
RESUME_FILE=$(new_resume_filename "$QUEUED_DIR" "$SESSION_ID")
[ -L "$RESUME_FILE" ] && rm -f "$RESUME_FILE"
jq -n \
    --arg sid "$SESSION_ID" \
    --argjson rat "$RESUME_AT" \
    --arg rah "$RESUME_DATE" \
    --argjson sat "$NOW" \
    --arg sah "$(human_ts "$NOW")" \
    --arg p "$SELECTED_PROMPT" \
    --argjson car "$CURRENT_RATE" \
    --arg src "$SOURCE" \
    '{session_id: $sid, resume_at: $rat, resume_at_human: $rah, scheduled_at: $sat, scheduled_at_human: $sah, scheduled_prompt: $p, created_at_rate: $car, source: $src}' \
    > "$RESUME_FILE.tmp" && mv "$RESUME_FILE.tmp" "$RESUME_FILE" || rm -f "$RESUME_FILE.tmp"

nohup bash "$HOME/.claude/bin/claude-auto-resume.sh" "$SESSION_ID" "$RESUME_AT" "$CWD" \
    >> "$HOME/.claude/logs/resume-${SESSION_ID}.log" 2>&1 &

echo "$(date +"%Y-%m-%dT%H:%M:%S%z") SCHEDULED session=$SESSION_ID resume_at=$RESUME_DATE five=${FIVE_PCT}% seven=${SEVEN_PCT}% cwd=$CWD" \
    >> "$HOME/.claude/logs/auto-resume-$(date +%Y-%m-%d).log"

DELTA=$((RESUME_AT - NOW)); MINS=$((DELTA / 60)); SECS=$((DELTA % 60))
echo -e "⏳ Auto-resume scheduled at $RESUME_DATE (in ${MINS}m ${SECS}s)\n   Session will terminate in 60s for scheduled resume.\n   Cancel: rm $RESUME_FILE" >&2
schedule_session_kill "$RESUME_FILE"

exit 0
