#!/usr/bin/env bash
# Shared helpers for auto-resume file management.
# Sourced by hook scripts and the resume daemon.

# Find existing resume file for a session in a directory.
# Supports timestamped (yymmdd-hhmmss-<sid>.json) and legacy (<sid>.json) formats.
# Prints path on stdout. Returns 0 if found, 1 if not.
find_resume_file() {
    local dir=$1 sid=$2
    local f
    f=$(ls "$dir"/*"-${sid}.json" 2>/dev/null | head -1)
    [ -n "$f" ] && [ -f "$f" ] && echo "$f" && return 0
    [ -f "$dir/${sid}.json" ] && echo "$dir/${sid}.json" && return 0
    return 1
}

# Generate new resume filename with yymmdd-hhmmss timestamp prefix.
new_resume_filename() {
    local dir=$1 sid=$2
    echo "$dir/$(date +%y%m%d-%H%M%S)-${sid}.json"
}

# Human-readable timestamp (no T separator, no timezone).
# Usage: human_ts → "2026-05-04 17:10:00"
#        human_ts "$epoch" → from epoch
human_ts() {
    if [ -n "${1:-}" ]; then
        date -d "@$1" +"%Y-%m-%d %H:%M:%S" 2>/dev/null \
            || date -r "$1" +"%Y-%m-%d %H:%M:%S" 2>/dev/null \
            || echo "$1"
    else
        date +"%Y-%m-%d %H:%M:%S"
    fi
}
