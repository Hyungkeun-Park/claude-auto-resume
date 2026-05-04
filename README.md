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
│   └── <session-id>.json
├── success/       ← completed resumes (includes completed_at)
│   └── <session-id>.json
└── failed/        ← failed resumes (includes error_output)
    └── <session-id>.json
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
  "prompt": "If any agents failed in the previous task, do not perform their work directly — re-launch the same agents. If it was not an agent failure, continue with the remaining work."
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
| `prompt` | Prompt to send on resume (editable by user) |

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
bash ~/.claude/bin/test-rate-limit-simulation.sh
```

96 test cases, 313 assertions covering:

| Category | Tests | Coverage |
|----------|-------|----------|
| Stop hook basic | T01-T06 | Rate states, stale/missing cache |
| Prompt guard basic | T07-T12 | Scheduling, dedup, edge cases |
| StopFailure basic | T13-T17 | API error fallback, source lock |
| Multi-session | T18-T20 | Coexistence, selective cleanup |
| Special characters | T21-T26 | Quotes, backslash, newline, Korean, JSON |
| Both limits at 100% | T27-T29 | Reset time selection |
| Edge cases | T30-T36 | 8h limit, rounding, empty input, atomic write |
| Full lifecycle | T37-T38 | Guard → StopFailure lock → Stop confirm → recovery |
| Corrupted files | T39-T43 | Invalid JSON, empty files, directory cleanup |
| **Overuse detection** | **T44-T56** | **Overuse via UPS/Stop, SubagentStop exempt, StopFailure lock, field validation, invalid session ID** |
| **Subagent marker (G16)** | **T57-T66** | **Marker create/delete, overuse skip, stale cache cleanup, full G16 lifecycle, validation** |
| **Stale cache + rate gate (G17)** | **T67-T72** | **Stale at low rate skips, stale at 100% schedules, overuse→block transition, prompt preservation** |
| Hook input robustness | T73-T82 | Extra/missing/null fields, cache schema changes, rapid fires, unknown events |
| Error recovery | T83-T92 | Empty/non-JSON cache, zero/past reset, long prompt, CWD isolation, rate boundary |
| Hook registration | T93-T96 | Script existence, shebang, settings.json wiring, safety guards |

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

## Changelog

### v1.2.1

**Stale Cache Freshness Gate Fix (G17)**

- **G17 fix — stale cache blocks scheduling at 100%**: Freshness check was unconditionally exiting on stale cache (>5min), even when cached rate was ≥100%. Since rate only resets downward, stale cache at ≥100% is valid for scheduling. Combined freshness+rate gate: exit only when stale AND rate < 100%
- **All three hooks fixed**: `rate-limit-prompt-guard.sh`, `rate-limit-stop.sh`, `rate-limit-stop-failure.sh` — rate data now read before freshness gate
- **Overuse→block transition**: When overuse turns off and client blocks, statusline stops updating but schedule is now correctly created from stale cache at ≥100%
- **Test suite**: 66 → 96 tests, 214 → 313 assertions (T05/T11/T17 updated, T67-T72 stale cache gate, T73-T82 input robustness, T83-T92 error recovery, T93-T96 hook registration compatibility)

### v1.2.0

**Subagent Marker Tracking (G16 Fix) & Hardening**

- **G16 fix — subagent rate limit false positive**: SubagentStart hook creates marker files; Stop checks surviving markers to skip overuse detection when rate-limited subagents haven't fired SubagentStop yet
- **New hook**: `rate-limit-subagent-start.sh` — creates `subagents/<session_id>/<agent_id>` marker on SubagentStart
- **Stop hook restructure**: CWD/SESSION_ID extraction moved before cache check so SubagentStop marker deletion works even with stale cache
- **RESUME_AT=0 guard**: All hooks reject resume times in the past or zero (prevents uncontrolled immediate resume)
- **eval removal**: Statusline wrapper replaced `eval "$INNER_CMD"` with `$INNER_CMD` (command injection hardening)
- **macOS portability**: `/proc/$pid/cmdline` replaced with `ps -o args=` in daemon (both duplicate detection and active session detection)
- **umask 077**: All hooks and daemon set restrictive file permissions
- **POSIX date**: Replaced `date -Iseconds` with portable `date +"%Y-%m-%dT%H:%M:%S%z"`
- **Dead code removal**: `resume_via_tmux()` removed from daemon (35 lines, unused since v1.1.0)
- **created_at_rate update**: Stop hook now updates `created_at_rate` on schedule update (was frozen at creation value)
- **pkill → targeted kill**: Replaced broad `pkill -f` with `pgrep` + `ps -o args=` + session-specific `kill`
- **Atomic write cleanup**: All jq write paths clean up `.tmp` files on failure
- **Gotchas split**: `docs/gotchas.md` → individual files in `docs/gotchas/` for easier reference
- **Test suite**: 56 → 66 tests, 172 → 214 assertions (10 new subagent marker lifecycle tests T57-T66)

### v1.1.0

**Overuse Detection & Daemon Safety**

- **Overuse detection**: `created_at_rate` + `source` fields in session.json to detect and cancel unnecessary schedules when "additional usage" is active
- **SubagentStop exception**: Parallel agent completion exempt from overuse detection
- **StopFailure source lock**: `source: stop_failure` protects genuine API errors from overuse classification
- **TOCTOU re-read guard**: Re-verifies source before deletion to prevent race conditions
- **Active session skip**: Daemon skips (not kills) active sessions
- **Process detection**: `ps -o args=` inspection replaces `pgrep -af` (macOS/Linux portable)
- **Resume timeout**: `timeout 3600` prevents unbounded blocking
- **Log cleanup**: 7-day resume logs, 30-day event logs, 50-file archive cap
- **Resume metadata**: `[Auto-resumed after Nm wait]` prefix in resumed sessions
- **Safe JSON**: `jq -n --argjson` in statusline wrapper replaces string interpolation
- **Explicit PATH**: `find_claude_bin()` replaces shell profile sourcing
- **User-visible logging**: stderr messages with time delta, state path, cancel command
- **Test suite**: 56 tests, 172 assertions (13 new overuse detection tests)

### v1.0.0

Initial release — hook-based auto-resume with per-session state files, subagent support, and tmux/headless resume.

## License

MIT
