# G12: Active Session Kill Is Dangerous

**What (v1)**: The daemon detected active sessions via pgrep and killed them before resuming, assuming it could restart them cleanly via tmux or headless mode.

**Why it matters**: Killing an active session discards the user's in-progress work, loses context, and can corrupt state. If the user is actively typing, their work is gone.

**Resolution (v4)**: Active sessions are skipped, not killed. The daemon archives the state file as `"skipped" / "session_still_active"` and exits.

**Resolution (v5)**: The daemon now distinguishes idle rate-limited sessions from user-revived sessions using the `source` field. If `source` is `stop` or `stop_failure`, the session is idle (rate-limited, waiting) — the daemon kills it via `kill_claude()` and resumes. For any other source, the session is skipped as before. This fixes the race condition where the fire-and-forget `schedule_session_kill` from Stop hooks could fail, leaving the session alive and the resume permanently skipped.
