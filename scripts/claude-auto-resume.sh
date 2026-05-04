#!/usr/bin/env bash
# Resume executor: wait until rate limit resets, then resume the session.
# Usage: claude-auto-resume.sh <session_id> <resume_epoch> <cwd>
#
# State file: <cwd>/.claude/auto-resume/queued/<session_id>.json
# Cancellation: delete the state file (checked every 60 seconds)
#
# Resume strategies:
# - Session inactive: claude -p --resume <id> "<prompt>"
# - Session active: skip (let hooks handle schedule cleanup)

set -uo pipefail
umask 077

SESSION_ID="$1"
TARGET_EPOCH="$2"
CWD="$3"

if [ -z "$SESSION_ID" ] || [ -z "$TARGET_EPOCH" ] || [ -z "$CWD" ]; then
    echo "Usage: claude-auto-resume.sh <session_id> <resume_epoch> <cwd>" >&2
    exit 1
fi

if [[ ! "$SESSION_ID" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "ERROR: Invalid session ID format: '$SESSION_ID'" >&2
    exit 1
fi

RESUME_DIR="$CWD/.claude/auto-resume"
QUEUED_DIR="$RESUME_DIR/queued"
SUCCESS_DIR="$RESUME_DIR/success"
FAILED_DIR="$RESUME_DIR/failed"
RESUME_FILE="$QUEUED_DIR/${SESSION_ID}.json"
CACHE="$HOME/.claude/rate-limits.json"
MAX_RETRIES=5
STALE_THRESHOLD=300
FIXED_PROMPT="If any agents failed in the previous task, do not perform their work directly — re-launch the same agents. If it was not an agent failure, continue with the remaining work."

mkdir -p "$HOME/.claude/logs"

log() {
    local LOG_FILE="$HOME/.claude/logs/auto-resume-$(date +%Y-%m-%d).log"
    echo "$(date +"%Y-%m-%dT%H:%M:%S%z") $1" >> "$LOG_FILE"
}

RESUME_ERROR_OUTPUT=""

cleanup_old_logs() {
    find "$HOME/.claude/logs" -name "resume-*.log" -mtime +7 -delete 2>/dev/null || true
    find "$HOME/.claude/logs" -name "auto-resume-*.log" -mtime +30 -delete 2>/dev/null || true
    local archive_dirs="$CWD/.claude/auto-resume/success $CWD/.claude/auto-resume/failed"
    for dir in $archive_dirs; do
        if [ -d "$dir" ]; then
            ls -t "$dir"/*.json 2>/dev/null | tail -n +51 | xargs rm -f 2>/dev/null || true
        fi
    done
}

archive_resume_file() {
    local result=$1
    local reason=${2:-""}
    [ ! -f "$RESUME_FILE" ] && return 0

    local dest_dir
    if [ "$result" = "success" ]; then
        dest_dir="$SUCCESS_DIR"
    else
        dest_dir="$FAILED_DIR"
    fi
    mkdir -p "$dest_dir"

    local completed_at
    completed_at=$(date +"%Y-%m-%dT%H:%M:%S%z")
    jq --arg r "$result" --arg reason "$reason" --arg cat "$completed_at" \
        --arg err "$RESUME_ERROR_OUTPUT" \
        '. + {result: $r, reason: $reason, completed_at: $cat} | if $err != "" then . + {error_output: $err} else . end' \
        "$RESUME_FILE" > "$RESUME_FILE.tmp" 2>/dev/null && mv "$RESUME_FILE.tmp" "$dest_dir/${SESSION_ID}.json"
    rm -f "$RESUME_FILE" "$RESUME_FILE.tmp"
}

# Find claude binary (needed for all resume paths)
find_claude_bin() {
    local bin
    bin=$(command -v claude 2>/dev/null || echo "")
    if [ -z "$bin" ]; then
        for p in "$HOME/.claude/local/bin/claude" "$HOME/.local/bin/claude" "/usr/local/bin/claude" "/opt/homebrew/bin/claude"; do
            [ -x "$p" ] && { bin="$p"; break; }
        done
    fi
    echo "$bin"
}

# Find tmux pane for a given PID (walks up process tree)
find_tmux_pane() {
    local target_pid=$1
    local pid=$target_pid

    command -v tmux >/dev/null 2>&1 || return 1
    tmux info >/dev/null 2>&1 || return 1

    while [ "$pid" != "1" ] && [ -n "$pid" ] && [ "$pid" != "0" ]; do
        local pane
        pane=$(tmux list-panes -a -F '#{pane_pid} #{pane_id}' 2>/dev/null \
            | awk -v p="$pid" '$1 == p {print $2}')
        if [ -n "$pane" ]; then
            echo "$pane"
            return 0
        fi
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    return 1
}

# Kill claude process and wait for it to exit
kill_claude() {
    local pid=$1
    kill "$pid" 2>/dev/null
    for i in $(seq 1 5); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
    sleep 1
}

# Resume via background print mode
resume_via_print() {
    local prompt=$1

    local claude_bin
    claude_bin=$(find_claude_bin)
    if [ -z "$claude_bin" ]; then
        RESUME_ERROR_OUTPUT="claude binary not found in PATH or common locations"
        log "FAILED session=$SESSION_ID reason=claude_binary_not_found"
        return 1
    fi

    log "BG_RESUME session=$SESSION_ID prompt=\"${prompt:0:80}\""

    cd "$CWD"
    local output
    output=$(timeout 3600 "$claude_bin" -p --resume "$SESSION_ID" "$prompt" 2>&1)
    local exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        RESUME_ERROR_OUTPUT=$(echo "$output" | tail -20)
        log "DONE session=$SESSION_ID exit_code=$exit_code error=\"${RESUME_ERROR_OUTPUT:0:200}\""
    else
        log "DONE session=$SESSION_ID exit_code=$exit_code"
    fi
    return $exit_code
}

TARGET_HUMAN=$(date -d "@$TARGET_EPOCH" +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || date -r "$TARGET_EPOCH" +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || echo "$TARGET_EPOCH")

# ── 0. Kill any existing daemon for this session (prevent duplicates) ──
for old_pid in $(pgrep -f "claude-auto-resume" 2>/dev/null || true); do
    [ "$old_pid" = "$$" ] && continue
    OLD_CMD=$(ps -o args= -p "$old_pid" 2>/dev/null || true)
    if [ -n "$OLD_CMD" ] && echo "$OLD_CMD" | grep -q "$SESSION_ID"; then
        log "KILL_OLD_DAEMON session=$SESSION_ID old_pid=$old_pid"
        kill "$old_pid" 2>/dev/null || true
    fi
done

cleanup_old_logs

# ── 1. Wall-clock polling (handles machine sleep correctly) ──
log "WAITING session=$SESSION_ID target=$TARGET_HUMAN"

while [ "$(date +%s)" -lt "$TARGET_EPOCH" ]; do
    if [ ! -f "$RESUME_FILE" ]; then
        log "CANCELLED session=$SESSION_ID reason=file_deleted_during_wait"
        exit 0
    fi
    sleep 60
done

# ── 2. Pre-resume checks ──

# 2a. Cancellation check
if [ ! -f "$RESUME_FILE" ]; then
    log "CANCELLED session=$SESSION_ID reason=file_deleted_at_resume_time"
    exit 0
fi

# 2b. Rate limit re-check with retries
RETRY=0
RATE_OK=false

while [ $RETRY -lt $MAX_RETRIES ]; do
    if [ -f "$CACHE" ]; then
        CACHE_TIME=$(jq -r '.last_updated // 0' "$CACHE" 2>/dev/null)
        CURRENT=$(date +%s)
        CACHE_AGE=$((CURRENT - CACHE_TIME))

        if [ "$CACHE_AGE" -gt "$STALE_THRESHOLD" ]; then
            # Cache is stale — try to wait for a fresh update
            if [ "$RETRY" -lt 2 ]; then
                log "CACHE_STALE session=$SESSION_ID age=${CACHE_AGE}s retry=$RETRY waiting_for_fresh"
                RETRY=$((RETRY + 1))
                sleep 60
                continue
            fi
            # After 2 retries with stale cache, assume recovered
            log "CACHE_STALE session=$SESSION_ID age=${CACHE_AGE}s assuming_recovered_after_retries"
            RATE_OK=true
            break
        fi

        FIVE_INT=$(printf '%.0f' "$(jq -r '.rate_limits.five_hour.used_percentage // 0' "$CACHE" 2>/dev/null)" 2>/dev/null || echo 0)
        SEVEN_INT=$(printf '%.0f' "$(jq -r '.rate_limits.seven_day.used_percentage // 0' "$CACHE" 2>/dev/null)" 2>/dev/null || echo 0)

        if [ "$FIVE_INT" -lt 100 ] && [ "$SEVEN_INT" -lt 100 ]; then
            log "RATE_RECOVERED session=$SESSION_ID five=${FIVE_INT}% seven=${SEVEN_INT}%"
            RATE_OK=true
            break
        fi
    else
        log "NO_CACHE session=$SESSION_ID assuming_recovered"
        RATE_OK=true
        break
    fi

    RETRY=$((RETRY + 1))
    log "STILL_LIMITED session=$SESSION_ID retry=$RETRY five=${FIVE_INT:-?}% seven=${SEVEN_INT:-?}%"
    sleep 60
done

if [ "$RATE_OK" != "true" ]; then
    log "GAVE_UP session=$SESSION_ID reason=still_rate_limited_after_${MAX_RETRIES}_retries"
    archive_resume_file "failed" "still_rate_limited_after_${MAX_RETRIES}_retries"
    exit 1
fi

# ── 3. Read prompt from state file ──
SAVED_PROMPT="$FIXED_PROMPT"
if [ -f "$RESUME_FILE" ]; then
    FILE_PROMPT=$(jq -r '.prompt // ""' "$RESUME_FILE" 2>/dev/null)
    [ -n "$FILE_PROMPT" ] && SAVED_PROMPT="$FILE_PROMPT"
fi

SCHEDULED_AT=$(jq -r '.scheduled_at // 0' "$RESUME_FILE" 2>/dev/null || echo "0")
WAIT_MINS=$(( ($(date +%s) - SCHEDULED_AT) / 60 ))
SAVED_PROMPT="[Auto-resumed after ${WAIT_MINS}m wait for rate limit recovery]
$SAVED_PROMPT"

# ── 4. Check if session is active and resume accordingly ──
CLAUDE_PID=""
for pid in $(pgrep -x claude 2>/dev/null || true); do
    CMDLINE=$(ps -o args= -p "$pid" 2>/dev/null || true)
    if [ -n "$CMDLINE" ] && echo "$CMDLINE" | grep -q "$SESSION_ID" && ! echo "$CMDLINE" | grep -q "auto-resume"; then
        CLAUDE_PID="$pid"
        break
    fi
done

RESUME_EXIT=1

if [ -n "$CLAUDE_PID" ]; then
    # ── Session is ACTIVE — do not kill, just skip ──
    log "SKIPPED session=$SESSION_ID reason=session_still_active pid=$CLAUDE_PID"
    archive_resume_file "skipped" "session_still_active"
    exit 0
else
    # ── Session is INACTIVE ──
    resume_via_print "$SAVED_PROMPT" && RESUME_EXIT=0 || RESUME_EXIT=$?
fi

# Archive to success/ or failed/
if [ "$RESUME_EXIT" -eq 0 ]; then
    archive_resume_file "success" "exit_code_0"
else
    log "RESUME_FAILED session=$SESSION_ID exit_code=$RESUME_EXIT"
    archive_resume_file "failed" "resume_exit_code_${RESUME_EXIT}"
fi

exit $RESUME_EXIT
