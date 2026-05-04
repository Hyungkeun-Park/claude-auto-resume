# G14: Shell Profile Dependency in Daemon

**What (v1)**: The daemon sourced `~/.bashrc` / `~/.zshrc` to set up PATH before finding the `claude` binary. In non-login shells (nohup, cron), these profiles may not exist or may error out.

**Why it matters**: The daemon would fail to find `claude` and archive every resume as failed.

**Resolution (v4)**: Explicit `find_claude_bin()` function that checks `command -v claude`, then iterates known paths (`~/.claude/local/bin/claude`, `~/.local/bin/claude`, `/usr/local/bin/claude`, `/opt/homebrew/bin/claude`). No shell profile dependency.
