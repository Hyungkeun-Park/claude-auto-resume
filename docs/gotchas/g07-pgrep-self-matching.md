# G7: pgrep Self-Matching in Daemon

**What**: The daemon's cmdline contains the session ID (passed as argument). When using `pgrep -f "claude.*$SESSION_ID"` to find active Claude sessions, the daemon matches itself — falsely detecting an "active session" and skipping resume.

**Why it matters**: Every resume attempt would be skipped because the daemon always matches its own process.

**Resolution (v1)**: `pgrep -af` + `grep -v "auto-resume"` to exclude the daemon process.
**Resolution (v2)**: Replaced with `pgrep -x claude` (exact binary name match) + `ps -o args=` direct inspection with explicit `auto-resume` exclusion. More robust, avoids shell quoting issues, and works on both macOS and Linux.
