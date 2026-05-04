#!/usr/bin/env bash
# SubagentStart hook: create marker for active subagent tracking.
# Stop hook checks surviving markers to skip false overuse detection (G16 fix).
#
# Marker: <cwd>/.claude/auto-resume/subagents/<session_id>/<agent_id>
# Lifecycle: SubagentStart creates → SubagentStop deletes → Stop checks

set -euo pipefail
umask 077

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)

CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
[ -z "$CWD" ] && exit 0

CONF="$CWD/.claude/auto-resume.conf"
if [ -f "$CONF" ] && grep -qi "^enabled=false" "$CONF" 2>/dev/null; then
    exit 0
fi

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
[ -z "$SESSION_ID" ] && exit 0
[[ ! "$SESSION_ID" =~ ^[a-zA-Z0-9._-]+$ ]] && exit 0

AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // ""')
[ -z "$AGENT_ID" ] && exit 0
[[ ! "$AGENT_ID" =~ ^[a-zA-Z0-9._-]+$ ]] && exit 0

MARKER_DIR="$CWD/.claude/auto-resume/subagents/$SESSION_ID"
mkdir -p "$MARKER_DIR"
echo "$(date +%s)" > "$MARKER_DIR/$AGENT_ID"

exit 0
