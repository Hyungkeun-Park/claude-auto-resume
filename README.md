# Claude Auto-Resume

Rate limit auto-resume system for [Claude Code](https://code.claude.com). When your session hits the rate limit, it automatically schedules a resume — so you can walk away and come back to completed work.

## How It Works

```
Rate limit 100% → hook saves session state → daemon waits for recovery → session resumes automatically
```

1. **Statusline wrapper** caches rate limit data to `~/.claude/rate-limits.json` every turn
2. **Hook scripts** detect rate limit 100% on Stop/StopFailure/SubagentStop/UserPromptSubmit events
3. **State file** is created at `<project>/.claude/auto-resume/queued/<session-id>.json`
4. **Daemon** polls until reset time, verifies rate recovery, then resumes the session
5. **Resume** via `claude --resume <session-id>` (tmux interactive or headless fallback)

## Features

- **Hook API-based** — not tmux polling or process watching
- **Per-session state files** — multiple sessions can be tracked independently
- **Parallel subagent support** — SubagentStop events trigger scheduling too
- **Smart resume** — tmux pane detection with headless fallback
- **Cancellation** — delete the state file to cancel any pending resume
- **Project-level opt-out** — enable/disable per project
- **Success/failure history** — archived with error output for debugging
- **Duplicate prevention** — new daemon kills existing one for same session

## Requirements

- [Claude Code](https://code.claude.com) CLI
- `jq` — `apt install jq` / `brew install jq`

## Installation

```bash
# Clone to global skills directory
git clone https://github.com/Hyungkeun-Park-Nota/claude-auto-resume.git ~/.claude/skills/auto-resume

# Then in any Claude Code session:
/auto-resume setup
```

## Commands

| Command | Description |
|---------|-------------|
| `/auto-resume` | Install (first time) or show help |
| `/auto-resume setup` | Install/reinstall globally |
| `/auto-resume status` | Show installation & project dashboard |
| `/auto-resume enable` | Enable for current project |
| `/auto-resume disable` | Disable for current project |
| `/auto-resume uninstall` | Remove globally |

## What Gets Installed

| File | Purpose |
|------|---------|
| `~/.claude/hooks/rate-limit-stop.sh` | Stop + SubagentStop hook |
| `~/.claude/hooks/rate-limit-stop-failure.sh` | StopFailure hook (API error fallback) |
| `~/.claude/hooks/rate-limit-prompt-guard.sh` | UserPromptSubmit hook (speculative scheduling) |
| `~/.claude/bin/claude-auto-resume.sh` | Resume daemon |
| `~/.claude/bin/statusline-rate-cache-wrapper.sh` | Rate limit data cache |
| `~/.claude/bin/auto-resume-help.sh` | Help output |
| `~/.claude/bin/auto-resume-status.sh` | Status dashboard |

## State Files

```
<project>/.claude/auto-resume/
├── queued/        ← pending resume schedules
│   └── <session-id>.json
├── success/       ← completed resumes
│   └── <session-id>.json   (includes completed_at)
└── failed/        ← failed resumes
    └── <session-id>.json   (includes error_output)
```

## Cancel a Pending Resume

```bash
# Cancel specific session
rm <project>/.claude/auto-resume/queued/<session-id>.json

# Cancel all
rm -rf <project>/.claude/auto-resume/queued/
```

## Per-Project Control

Auto-resume is **enabled by default** for all projects after setup. To opt out a specific project:

```bash
# In Claude Code session, inside the project:
/auto-resume disable

# Re-enable:
/auto-resume enable
```

This creates `<project>/.claude/auto-resume.conf` with `enabled=true/false`.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Claude Code Session                       │
│                                                             │
│  statusline ──→ statusline-rate-cache-wrapper.sh            │
│                        │                                    │
│                        ▼                                    │
│              ~/.claude/rate-limits.json                      │
│                        ▲                                    │
│  ┌─────────┐  ┌───────┴──────┐  ┌────────────────┐         │
│  │  Stop   │  │ StopFailure  │  │UserPromptSubmit │         │
│  │Subagent │  │              │  │                 │         │
│  │  Stop   │  │              │  │                 │         │
│  └────┬────┘  └──────┬───────┘  └───────┬─────────┘        │
│       └──────────────┼──────────────────┘                   │
│                      ▼                                      │
│  <project>/.claude/auto-resume/queued/<session-id>.json     │
│                      │                                      │
│                      ▼                                      │
│        claude-auto-resume.sh (background daemon)            │
│              │                                              │
│              ├─ poll every 60s (cancel check)               │
│              ├─ verify rate recovery                        │
│              └─ resume session                              │
│                   ├─ tmux → kill + send-keys (interactive)  │
│                   └─ no tmux → claude -p --resume (headless)│
└─────────────────────────────────────────────────────────────┘
```

## Comparison with Existing Tools

| Feature | claude-auto-retry (npm) | bash wrapper | **claude-auto-resume** |
|---------|------------------------|--------------|----------------------|
| Detection | tmux polling (5s) | exit code check | Hook API events |
| Resume method | tmux send-keys "continue" | `claude -c` (history only) | `claude --resume` (full context) |
| Cancellation | kill process | Ctrl+C during sleep | Delete state file |
| Parallel sessions | No | No | Per-session state files |
| Subagent support | No | No | SubagentStop hook |
| Failure tracking | No | No | Failed dir + error_output |
| Project opt-out | No | No | Per-project conf |
| tmux required | Yes | No | Optional (auto-detect) |

## License

MIT
