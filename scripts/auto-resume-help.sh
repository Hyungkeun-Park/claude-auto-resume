#!/usr/bin/env bash
# Print auto-resume usage help

cat << 'EOF'
═══ Auto-Resume ═══

Rate limit auto-resume system for Claude Code sessions.
When rate limit hits 100%, schedules automatic session resume after recovery.

Commands:
  /auto-resume              — install (first time) or show this help
  /auto-resume setup        — install/reinstall globally
  /auto-resume enable       — enable for current project
  /auto-resume disable      — disable for current project
  /auto-resume status       — show installation & project dashboard
  /auto-resume uninstall    — remove globally

Cancel a pending resume:
  rm <project>/.claude/auto-resume/queued/*-<session-id>.json

Cancel all pending:
  rm -rf <project>/.claude/auto-resume/queued/

How it works:
  Rate limit 100% → hook creates schedule → daemon waits → rate recovers → session resumes
  Overuse detection: if a turn completes at 100%, schedule is auto-cancelled (overuse mode)

State files (named yymmdd-hhmmss-<session-id>.json):
  <project>/.claude/auto-resume/queued/    — pending schedules
  <project>/.claude/auto-resume/success/   — completed resumes
  <project>/.claude/auto-resume/failed/    — failed resumes (with error_output)
EOF
