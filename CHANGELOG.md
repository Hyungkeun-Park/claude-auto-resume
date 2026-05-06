# Changelog

All notable changes to this project are documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/).

## [1.1.1] - 2026-05-06

### Fixed
- **Overuse detection too aggressive**: guard-created (`user_prompt`) and subagent-updated (`subagent_stop`) schedules were incorrectly deleted by overuse detection. Narrowed to `source=stop` only — other sources indicate normal rate-limit shutdown, not overuse.

## [1.1.0] - 2026-05-05

### Added
- **Session kill on scheduling** — when rate limit triggers auto-resume, the idle Claude process is killed after 60s so the resume daemon can start a fresh session
- User-facing message in Claude UI: "Session will terminate in 60s for scheduled resume" with cancel instructions
- Safety guard: if user deletes the resume file within 60s, the kill is cancelled (allows manual overuse usage)
- Safety guard: if the session is still active at resume time (user revived it), resume is skipped

### Changed
- Stop/StopFailure hooks now call `schedule_session_kill()` after scheduling
- Hook messages updated: "confirmed" → "scheduled", added termination notice and skip note
- Test assertions updated for new field names and messages

## [1.0.0] - 2026-05-05

### Added
- `prev_prompt` field in state files: stores the user's original prompt so users can identify what each session was working on
- `scheduled_prompt` field: renamed from `prompt` for clarity (the prompt sent on resume)
- Modular test architecture: 16 independent suites with shared framework and runner (`--smoke`, `--contract` modes)
- Contract tests (TC01-TC12): validate Claude Code hook input schema, statusline cache schema, settings.json structure, and `--resume` CLI flag
- Daemon tests (TD01-TD12): `find_claude_bin()` fallbacks, `archive_resume_file()` lifecycle, `cleanup_old_logs()`, session ID validation
- Security tests (TS01-TS10): symlink attack prevention, path traversal rejection, injection, large JSON handling, concurrent fires
- Standalone installer (`install.sh`) with `--upgrade`, `--uninstall`, `--check` modes
- `VERSION` file for machine-readable version tracking
- Timestamped state filenames (`yymmdd-hhmmss-<session-id>.json`) with backward-compatible lookup

### Fixed
- Symlink hardening: all state file write paths check for and remove symlinks before writing
- Statusline command injection: `$INNER_CMD` execution changed to `bash -c "$INNER_CMD"`
- Stop hook no longer overwrites user's original prompt when updating existing files

### Changed
- `prompt` field renamed to `scheduled_prompt` across all hooks and state files
- Stop hook preserves `prev_prompt` when updating existing files
- UserPromptSubmit hook saves both `prev_prompt` and `scheduled_prompt`
- Test suite: 130 tests, 379+ assertions across 16 suites

## [0.3.1] - 2026-05-04

### Fixed
- **G17**: Stale cache (>5min) was unconditionally blocking scheduling even when cached rate was ≥100%. Combined freshness+rate gate: exit only when stale AND rate < 100%.
- All three hooks fixed: `rate-limit-prompt-guard.sh`, `rate-limit-stop.sh`, `rate-limit-stop-failure.sh`

### Changed
- Test suite: 66 → 96 tests, 214 → 313 assertions

## [0.3.0] - 2026-05-03

### Added
- **G16 fix**: SubagentStart hook creates marker files; Stop checks surviving markers to skip overuse detection
- New hook: `rate-limit-subagent-start.sh`
- RESUME_AT=0 guard: all hooks reject resume times in the past or zero
- `umask 077` in all hooks and daemon

### Fixed
- `eval` removal: statusline wrapper replaced `eval "$INNER_CMD"` with `$INNER_CMD`
- macOS portability: `/proc/$pid/cmdline` replaced with `ps -o args=`
- POSIX date: replaced `date -Iseconds` with portable `date +"%Y-%m-%dT%H:%M:%S%z"`
- Atomic write cleanup: all jq write paths clean up `.tmp` files on failure
- `pkill` → targeted `pgrep` + session-specific `kill`

### Removed
- `resume_via_tmux()` (35 lines, unused since v0.2.0)

### Changed
- Stop hook restructure: CWD/SESSION_ID extraction moved before cache check
- `created_at_rate` now updated on schedule update
- Gotchas split: `docs/gotchas.md` → individual files in `docs/gotchas/`
- Test suite: 56 → 66 tests, 172 → 214 assertions

## [0.2.0] - 2026-05-02

### Added
- Overuse detection via `created_at_rate` + `source` fields
- SubagentStop exception: parallel agent completion exempt from overuse detection
- StopFailure source lock: `source: stop_failure` protects genuine API errors
- TOCTOU re-read guard before overuse deletion
- Active session skip (daemon skips instead of killing)
- Resume timeout: `timeout 3600` prevents unbounded blocking
- Log cleanup: 7-day resume logs, 30-day event logs, 50-file archive cap
- Resume metadata: `[Auto-resumed after Nm wait]` prefix
- Safe JSON via `jq -n --argjson` in statusline wrapper
- `find_claude_bin()` replaces shell profile sourcing
- User-visible stderr messages with time delta, state path, cancel command

### Changed
- Test suite: 56 tests, 172 assertions

## [0.1.0] - 2026-05-01

Initial release — hook-based auto-resume with per-session state files, subagent support, and headless resume.
