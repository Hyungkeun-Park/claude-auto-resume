#!/usr/bin/env bash
# Statusline wrapper: caches rate limit data, then delegates to inner statusline.
# This ensures rate-limit hooks always have fresh data regardless of which
# statusline display the user has configured.
#
# Inner statusline command is read from ~/.claude/statusline-inner.conf
# If the conf file doesn't exist or is empty, only caching is performed.

INPUT=$(cat)

# ── 1. Cache rate limits (fast, always runs) ──
if command -v jq >/dev/null 2>&1; then
    five_pct=$(echo "$INPUT" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
    five_reset=$(echo "$INPUT" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)
    week_pct=$(echo "$INPUT" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)
    week_reset=$(echo "$INPUT" | jq -r '.rate_limits.seven_day.resets_at // empty' 2>/dev/null)

    if [ -n "$five_pct" ] || [ -n "$week_pct" ]; then
        now=$(date +%s)
        cache_json="{\"rate_limits\":{\"five_hour\":{\"used_percentage\":${five_pct:-0},\"resets_at\":${five_reset:-0}},\"seven_day\":{\"used_percentage\":${week_pct:-0},\"resets_at\":${week_reset:-0}}},\"last_updated\":${now}}"
        echo "$cache_json" > "$HOME/.claude/rate-limits.json.tmp" && mv "$HOME/.claude/rate-limits.json.tmp" "$HOME/.claude/rate-limits.json"
    fi
fi

# ── 2. Delegate to inner statusline ──
CONF="$HOME/.claude/statusline-inner.conf"
if [ -f "$CONF" ]; then
    INNER_CMD=$(cat "$CONF")
    if [ -n "$INNER_CMD" ]; then
        echo "$INPUT" | eval "$INNER_CMD"
        exit $?
    fi
fi
