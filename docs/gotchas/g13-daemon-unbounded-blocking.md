# G13: Daemon Unbounded Blocking on `claude -p --resume`

**What**: If `claude -p --resume` hangs (e.g., waiting for user input that never comes in headless mode), the daemon blocks forever — consuming a process slot and holding the state file.

**Why it matters**: A stuck daemon prevents cleanup and may cause duplicate daemons on subsequent hook fires.

**Resolution**: Wrapped with `timeout 3600` (1 hour). If the resume doesn't complete in 1 hour, it's killed and archived as failed.
