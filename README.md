# Claude Auto-Resume

Rate limit auto-resume system for [Claude Code](https://code.claude.com). When your session hits the rate limit, it automatically schedules a resume — so you can walk away and come back to completed work.

## How It Works

```
Rate limit 100% → hook saves session state → daemon waits for recovery → session resumes automatically
```

1. **Statusline wrapper** caches rate limit data to `~/.claude/rate-limits.json` every turn
2. **Hook scripts** detect rate limit 100% on Stop/StopFailure/SubagentStop/UserPromptSubmit events
3. **State file** is created at `<project>/.claude/auto-resume/queued/<yymmdd-hhmmss>-<session-id>.json`
4. **Daemon** polls until reset time, verifies rate recovery, then resumes the session
5. **Resume** via `claude -p --resume <session-id>` (headless mode)

## Features

- **Hook API-based** — not tmux polling or process watching
- **Overuse detection** — automatically detects "additional usage" mode and cancels unnecessary schedules
- **Per-session state files** — multiple sessions can be tracked independently
- **Parallel subagent support** — SubagentStop events trigger scheduling too
- **Active session safety** — skips resume when session is already running (no kill)
- **Cancellation** — delete the state file to cancel any pending resume
- **Project-level opt-out** — enable/disable per project
- **Success/failure history** — archived with error output for debugging
- **Duplicate prevention** — new daemon kills existing one for same session
- **Resume metadata** — resumed session knows it was auto-resumed and how long it waited
- **Log cleanup** — automatic rotation (7-day resume logs, 30-day event logs, 50-file archive cap)

## Requirements

- [Claude Code](https://code.claude.com) CLI
- `jq` — `apt install jq` / `brew install jq`

## Installation

```bash
# Option 1: Standalone installer (recommended)
git clone https://github.com/Hyungkeun-Park/claude-auto-resume.git
cd claude-auto-resume
bash install.sh

# Option 2: As Claude Code skill
git clone https://github.com/Hyungkeun-Park/claude-auto-resume.git ~/.claude/skills/auto-resume
# Then in any Claude Code session:
/auto-resume setup
```

The installer copies scripts, merges hooks into `settings.json`, and configures the statusline wrapper. Use `bash install.sh --check` to verify, `--upgrade` to update, or `--uninstall` to remove.

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
| `~/.claude/hooks/rate-limit-subagent-start.sh` | SubagentStart hook (marker tracking for G16 fix) |
| `~/.claude/bin/claude-auto-resume.sh` | Resume daemon |
| `~/.claude/bin/statusline-rate-cache-wrapper.sh` | Rate limit data cache |
| `~/.claude/bin/auto-resume-help.sh` | Help output |
| `~/.claude/bin/auto-resume-status.sh` | Status dashboard |
| `~/.claude/bin/test-rate-limit-simulation.sh` | Hook simulation test suite |
| `~/.claude/bin/test-resume-daemon.sh` | Daemon unit test suite |

## Overuse Detection

When "additional usage" (overuse) is enabled in your Anthropic account, API calls succeed even at 100% rate — meaning the session never actually stops. Without overuse detection, auto-resume would create unnecessary schedules and waste tokens trying to resume sessions that are still running.

### How It Works

Each session state file tracks two extra fields:

| Field | Description |
|-------|-------------|
| `created_at_rate` | Rate % when the schedule was created |
| `source` | Which hook created it (`user_prompt`, `stop`, `subagent_stop`, `stop_failure`) |

**Detection algorithm:**
- If Stop fires at 100% AND the existing schedule was created at 100% (`created_at_rate >= 100`) AND `source != stop_failure` → **overuse confirmed** → schedule deleted
- If the turn completed, it means the client-side rate limiter didn't block it, proving overuse is active

**Safety guards:**
- **SubagentStop exempt** — parallel agent completion is not overuse evidence
- **StopFailure lock** — sets `source: stop_failure` to protect genuine API errors from being classified as overuse
- **TOCTOU re-read** — re-verifies source immediately before deletion to prevent race conditions

### Overuse Scenarios

```
Normal session (overuse ON):
  UPS(100%) → schedule {created_at_rate:100} → turn succeeds → Stop detects overuse → ✅ deleted

Ralph loop (overuse ON):
  Stop(100%) → schedule {created_at_rate:100} → next turn succeeds → Stop detects overuse → ✅ deleted

Overuse → hard limit transition:
  Overuse keeps deleting → Anthropic ends overuse → client blocks → schedule survives → ✅ daemon resumes
```

## State Files

```
<project>/.claude/auto-resume/
├── queued/        ← pending resume schedules
│   └── <yymmdd-hhmmss>-<session-id>.json
├── success/       ← completed resumes (includes completed_at)
│   └── <yymmdd-hhmmss>-<session-id>.json
└── failed/        ← failed resumes (includes error_output)
    └── <yymmdd-hhmmss>-<session-id>.json
```

### State File Format

```json
{
  "session_id": "abc-123-def",
  "resume_at": 1777662000,
  "resume_at_human": "2026-05-02T04:00:00+09:00",
  "scheduled_at": 1777648658,
  "created_at_rate": 100,
  "source": "user_prompt",
  "prev_prompt": "implement the login feature with OAuth",
  "scheduled_prompt": "If any agents failed in the previous task, do not perform their work directly — re-launch the same agents. If it was not an agent failure, continue with the remaining work."
}
```

| Field | Description |
|-------|-------------|
| `session_id` | Resume target session |
| `resume_at` | Reset epoch timestamp |
| `resume_at_human` | Human-readable ISO time |
| `scheduled_at` | When the schedule was created |
| `created_at_rate` | Rate % at creation time (overuse detection) |
| `source` | Creating hook: `user_prompt`, `stop`, `subagent_stop`, `stop_failure` |
| `prev_prompt` | User's original prompt (what was being worked on) |
| `scheduled_prompt` | Prompt to send on resume (editable by user) |

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

## User-Facing Messages

All messages appear in stderr (visible to user, not to model):

| Event | Message |
|-------|---------|
| Schedule created | `⏳ Auto-resume scheduled at {time} (in {N}m {N}s)` |
| Already scheduled | `⏳ Auto-resume already scheduled at {time} (in {N}m {N}s)` |
| Stop confirms | `⏳ Auto-resume confirmed at {time} (in {N}m {N}s)` |
| Overuse detected | `✅ Overuse detected (turn completed at 100%). Schedule cancelled.` |
| Rate recovered | `✅ Rate recovered. Auto-resume cleared.` |

All messages include the state file path and cancel command.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Claude Code Session                       │
│                                                             │
│  statusline ──→ statusline-rate-cache-wrapper.sh            │
│                        │ (jq atomic write)                  │
│                        ▼                                    │
│              ~/.claude/rate-limits.json                      │
│                        ▲                                    │
│  ┌─────────┐  ┌───────┴──────┐  ┌────────────────┐         │
│  │  Stop   │  │ StopFailure  │  │UserPromptSubmit │         │
│  │Subagent │  │  (source     │  │  (user prompt   │         │
│  │  Stop   │  │   lock)      │  │   preserved)    │         │
│  └────┬────┘  └──────┬───────┘  └───────┬─────────┘        │
│       │              │                  │                   │
│       │   overuse    │   source lock    │  speculative      │
│       │   detection  │   protection     │  scheduling       │
│       └──────────────┼──────────────────┘                   │
│                      ▼                                      │
│  <project>/.claude/auto-resume/queued/<session-id>.json     │
│    { created_at_rate, source, prompt, resume_at, ... }      │
│                      │                                      │
│                      ▼                                      │
│        claude-auto-resume.sh (background daemon)            │
│              │                                              │
│              ├─ poll every 60s (cancel check)               │
│              ├─ verify rate recovery (5 retries)            │
│              ├─ active session → skip + archive             │
│              └─ inactive → timeout 3600 claude -p --resume  │
│                                                             │
│        ┌──────────────────────────────────────┐             │
│        │ success/ │ failed/ │ (archived)      │             │
│        └──────────────────────────────────────┘             │
└─────────────────────────────────────────────────────────────┘
```

## Logs

```
~/.claude/logs/
├── auto-resume-YYYY-MM-DD.log    # Daily event log (30-day retention)
└── resume-<session-id>.log       # Per-daemon log (7-day retention)
```

### Event Log Prefixes

| Prefix | Source |
|--------|--------|
| `SCHEDULED` | Stop hook created schedule |
| `SCHEDULED_BY_GUARD` | UserPromptSubmit created schedule |
| `SCHEDULED_BY_FAILURE` | StopFailure created schedule |
| `CLEARED` | Rate recovered, schedule deleted |
| `OVERUSE_DETECTED` | Overuse detected, schedule deleted |
| `OVERUSE_CLEARED` | Overuse schedule cleared on rate recovery |

### Daemon Log Prefixes

| Prefix | Description |
|--------|-------------|
| `WAITING` | Daemon started, waiting for reset time |
| `CANCELLED` | State file deleted during wait |
| `RATE_RECOVERED` | Rate confirmed below 100% |
| `SKIPPED` | Active session detected, skipping |
| `BG_RESUME` | Headless resume started |
| `DONE` | Resume completed |
| `RESUME_FAILED` | Resume failed (archived to failed/) |

## Testing

```bash
# Modular test suite (recommended)
bash tests/run-tests.sh              # all 16 suites
bash tests/run-tests.sh --smoke      # quick health check (4 core suites)
bash tests/run-tests.sh --contract   # Claude Code compatibility checks only
bash tests/run-tests.sh stop-hook overuse  # specific suites

# Legacy monolithic test (backward compatible)
bash scripts/test-rate-limit-simulation.sh
```

16 test suites, 130 test cases, 379+ assertions:

| Suite | Tests | Coverage |
|-------|-------|----------|
| Stop hook basic | T01-T06 | Rate states, stale/missing cache |
| Prompt guard basic | T07-T12 | Scheduling, dedup, edge cases |
| StopFailure basic | T13-T17 | API error fallback, source lock |
| Multi-session | T18-T20 | Coexistence, selective cleanup |
| Special characters | T21-T26 | Quotes, backslash, newline, Korean, JSON |
| Edge cases | T27-T35 | 8h limit, rounding, empty input, both limits |
| Lifecycle | T36-T43 | Atomic write, full lifecycle, corrupted files, dir cleanup |
| Overuse detection | T44-T56 | Overuse via UPS/Stop, SubagentStop exempt, StopFailure lock |
| Subagent marker (G16) | T57-T66 | Marker lifecycle, overuse skip, stale cache cleanup |
| Stale cache + rate gate (G17) | T67-T72 | Stale at 100% schedules, overuse→block transition |
| Forward compatibility | T73-T82 | Extra/missing/null fields, cache schema changes, rapid fires |
| Error recovery | T83-T92 | Empty/non-JSON cache, zero/past reset, long prompt, CWD isolation |
| Hook registration | T93-T96 | Script existence, shebang, settings.json wiring, safety guards |
| **Contract** | **TC01-TC12** | **Hook input schema, statusline schema, settings structure, CLI --resume flag** |
| **Daemon** | **TD01-TD12** | **find_claude_bin() fallbacks, archive lifecycle, cleanup, arg validation** |
| **Security** | **TS01-TS10** | **Injection, symlink, path traversal, large input, concurrent fires** |

### Test Architecture

```
tests/
├── test-framework.sh      # Shared assertions, helpers, environment isolation
├── run-tests.sh            # Runner with --smoke, --contract modes
├── test-stop-hook.sh       # T01-T06
├── test-prompt-guard.sh    # T07-T12
├── ...                     # 13 more hook logic suites
├── test-contract.sh        # Claude Code API contract validation
├── test-daemon.sh          # Resume daemon unit tests
└── test-security.sh        # Security hardening verification
```

## Comparison with Existing Tools

| Feature | claude-auto-retry (npm) | bash wrapper | **claude-auto-resume** |
|---------|------------------------|--------------|----------------------|
| Detection | tmux polling (5s) | exit code check | Hook API events |
| Resume method | tmux send-keys "continue" | `claude -c` (history only) | `claude --resume` (full context) |
| Overuse detection | No | No | `created_at_rate` + `source` |
| Cancellation | kill process | Ctrl+C during sleep | Delete state file |
| Parallel sessions | No | No | Per-session state files |
| Subagent support | No | No | SubagentStop hook |
| Failure tracking | No | No | Failed dir + error_output |
| Active session safety | No (kills) | N/A | Skip + archive |
| Project opt-out | No | No | Per-project conf |
| tmux required | Yes | No | No (headless default) |

## Documentation

| Document | Description |
|----------|-------------|
| [docs/spec.md](docs/spec.md) | Full technical spec — hook lifecycle, case analysis, design decisions |
| [docs/gotchas.md](docs/gotchas.md) | Edge cases index — individual entries in [docs/gotchas/](docs/gotchas/) |
| [tests/test-framework.sh](tests/test-framework.sh) | Shared test framework — assertions, helpers, environment isolation |
| [install.sh](install.sh) | Standalone installer — `--upgrade`, `--uninstall`, `--check` |

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the full release history.

## License

MIT
