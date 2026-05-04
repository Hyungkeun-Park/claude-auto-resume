# G12: Active Session Kill Is Dangerous

**What (v1)**: The daemon detected active sessions via pgrep and killed them before resuming, assuming it could restart them cleanly via tmux or headless mode.

**Why it matters**: Killing an active session discards the user's in-progress work, loses context, and can corrupt state. If the user is actively typing, their work is gone.

**Resolution (v4)**: Active sessions are skipped, not killed. The daemon archives the state file as `"skipped" / "session_still_active"` and exits. The user's session continues undisturbed. With overuse detection, unnecessary schedules are already cleaned up, so the daemon rarely encounters an active session.
