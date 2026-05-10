---
name: auto-resume
description: Manage rate-limit auto-resume system — setup, enable/disable per project, status dashboard, uninstall. Automatically resumes Claude sessions after rate limit recovery.
disable-model-invocation: true
---

# Auto-Resume

Manage the rate-limit auto-resume system for Claude Code sessions.

## Command Routing

Parse the argument passed by the user:

| Argument | Action |
|----------|--------|
| (no argument) | Check if installed → if yes: run `bash ~/.claude/bin/auto-resume-help.sh`; if no: run **Setup** |
| `setup` | Run **Setup** |
| `enable` | Run **Enable** |
| `disable` | Run **Disable** |
| `status` | Run `bash ~/.claude/bin/auto-resume-status.sh` |
| `uninstall` | Run **Uninstall** |

**Installed check**: `test -x ~/.claude/bin/claude-auto-resume.sh` — if exists, system is installed.

**Token minimization**: For `status` and help, run the shell scripts and show their output directly. Do not generate equivalent output yourself.

## Prerequisites Check

For `setup` only: run `command -v jq` — if not found, stop and tell the user: "jq is required. Install it first (`apt install jq` / `brew install jq`)."

## Setup

Install the auto-resume system globally to `~/.claude/`.

### Step 1: Install Scripts

Copy scripts from this skill's `scripts/` directory. Read each file, then write to the target path. Make all scripts executable.

| Source (read from skill dir) | Target | chmod |
|------------------------------|--------|-------|
| `scripts/lib-resume-file.sh` | `~/.claude/hooks/lib-resume-file.sh` | +x |
| `scripts/rate-limit-stop.sh` | `~/.claude/hooks/rate-limit-stop.sh` | +x |
| `scripts/rate-limit-stop-failure.sh` | `~/.claude/hooks/rate-limit-stop-failure.sh` | +x |
| `scripts/rate-limit-prompt-guard.sh` | `~/.claude/hooks/rate-limit-prompt-guard.sh` | +x |
| `scripts/claude-auto-resume.sh` | `~/.claude/bin/claude-auto-resume.sh` | +x |
| `scripts/statusline-rate-cache-wrapper.sh` | `~/.claude/bin/statusline-rate-cache-wrapper.sh` | +x |
| `scripts/auto-resume-help.sh` | `~/.claude/bin/auto-resume-help.sh` | +x |
| `scripts/auto-resume-status.sh` | `~/.claude/bin/auto-resume-status.sh` | +x |

Create target directories if they don't exist: `~/.claude/hooks/`, `~/.claude/bin/`, `~/.claude/logs/`.

### Step 2: Configure Statusline

The statusline wrapper caches rate limit data to `~/.claude/rate-limits.json`. It delegates to the user's existing statusline if present.

1. Read `~/.claude/settings.json` and check `.statusLine`
2. If `.statusLine` is already the wrapper (`statusline-rate-cache-wrapper.sh`): skip
3. If `.statusLine` exists and is something else:
   - Save the existing command to `~/.claude/statusline-inner.conf`
   - Replace `.statusLine` with the wrapper
   - Tell the user: "Existing statusline preserved in `~/.claude/statusline-inner.conf` and will be called by the wrapper."
4. If `.statusLine` doesn't exist:
   - Set it to the wrapper
   - No inner conf needed

Set statusLine to:
```json
{
  "statusLine": {
    "type": "command",
    "command": "bash $HOME/.claude/bin/statusline-rate-cache-wrapper.sh"
  }
}
```

### Step 3: Register Hooks

Merge hook entries into `~/.claude/settings.json`. **Do not overwrite existing hooks** — append to the hooks array for each event.

For each of these events, add the hook entry if not already present (check by `command` field match):

**Stop:**
```json
{"type": "command", "command": "bash /root/.claude/hooks/rate-limit-stop.sh", "timeout": 10}
```

**SubagentStop:** (same script as Stop)
```json
{"type": "command", "command": "bash /root/.claude/hooks/rate-limit-stop.sh", "timeout": 10}
```

**StopFailure:**
```json
{"type": "command", "command": "bash /root/.claude/hooks/rate-limit-stop-failure.sh", "timeout": 10}
```

**UserPromptSubmit:**
```json
{"type": "command", "command": "bash /root/.claude/hooks/rate-limit-prompt-guard.sh", "timeout": 10}
```

**Important**: The hook commands must use the **actual `$HOME` path** (e.g., `/root/.claude/hooks/...` or `/home/user/.claude/hooks/...`), not the literal `$HOME` variable, because hook commands don't expand environment variables. Use `$HOME` resolved at install time.

Merge algorithm for each event:
1. If the event key doesn't exist in `.hooks`: create it with `[{"matcher": "", "hooks": [<entry>]}]`
2. If the event key exists: check if any existing hook has the same `command` string. If not found, append to the first matcher's `hooks` array.

### Step 4: Verify & Report

Run verification checks and print summary:

```bash
# Scripts exist and are executable
test -x ~/.claude/hooks/rate-limit-stop.sh && echo "✓ stop hook" || echo "✗ stop hook"
test -x ~/.claude/hooks/rate-limit-stop-failure.sh && echo "✓ stop-failure hook" || echo "✗ stop-failure hook"
test -x ~/.claude/hooks/rate-limit-prompt-guard.sh && echo "✓ prompt-guard hook" || echo "✗ prompt-guard hook"
test -x ~/.claude/bin/claude-auto-resume.sh && echo "✓ daemon" || echo "✗ daemon"
test -x ~/.claude/bin/statusline-rate-cache-wrapper.sh && echo "✓ statusline wrapper" || echo "✗ statusline wrapper"
test -x ~/.claude/bin/auto-resume-help.sh && echo "✓ help script" || echo "✗ help script"
test -x ~/.claude/bin/auto-resume-status.sh && echo "✓ status script" || echo "✗ status script"

# Settings.json has hooks registered
jq '.hooks.Stop[0].hooks[]?.command' ~/.claude/settings.json 2>/dev/null | grep -q "rate-limit-stop" && echo "✓ Stop hook registered" || echo "✗ Stop hook not registered"
jq '.hooks.SubagentStop[0].hooks[]?.command' ~/.claude/settings.json 2>/dev/null | grep -q "rate-limit-stop" && echo "✓ SubagentStop hook registered" || echo "✗ SubagentStop hook not registered"
jq '.hooks.StopFailure[0].hooks[]?.command' ~/.claude/settings.json 2>/dev/null | grep -q "rate-limit-stop-failure" && echo "✓ StopFailure hook registered" || echo "✗ StopFailure hook not registered"
jq '.hooks.UserPromptSubmit[0].hooks[]?.command' ~/.claude/settings.json 2>/dev/null | grep -q "rate-limit-prompt-guard" && echo "✓ UserPromptSubmit hook registered" || echo "✗ UserPromptSubmit hook not registered"

# Statusline configured
jq -r '.statusLine.command // ""' ~/.claude/settings.json 2>/dev/null | grep -q "statusline-rate-cache-wrapper" && echo "✓ statusline configured" || echo "✗ statusline not configured"
```

Print:
```
═══ Auto-Resume Setup Complete ═══

Installed:
  ~/.claude/hooks/rate-limit-stop.sh
  ~/.claude/hooks/rate-limit-stop-failure.sh
  ~/.claude/hooks/rate-limit-prompt-guard.sh
  ~/.claude/bin/claude-auto-resume.sh
  ~/.claude/bin/statusline-rate-cache-wrapper.sh
  ~/.claude/bin/auto-resume-help.sh
  ~/.claude/bin/auto-resume-status.sh

Hooks registered: Stop, SubagentStop, StopFailure, UserPromptSubmit

Run /auto-resume for help, or /auto-resume status to see dashboard.
```

## Modification Notes

When modifying the hook scripts, keep these cross-file dependencies in mind:

| Change | Files to update |
|--------|----------------|
| Prompt side file path or format | `lib-resume-file.sh` (`prompt_side_file()`), `rate-limit-prompt-guard.sh` (write), `rate-limit-stop.sh` (read + cleanup), `rate-limit-stop-failure.sh` (read) |
| Resume file JSON schema (new/renamed fields) | All 3 hook scripts + `claude-auto-resume.sh` (daemon reads `scheduled_prompt`) + tests |
| Overuse detection logic | `rate-limit-stop.sh` (section 7) — check `source` field values, subagent marker interaction |
| Subagent marker directory structure | `rate-limit-subagent-start.sh`, `rate-limit-stop.sh` (overuse skip + prompt selection), `rate-limit-stop-failure.sh` (prompt selection) |
| Prompt selection logic (saved vs fixed) | `rate-limit-stop.sh` (section 7b), `rate-limit-stop-failure.sh` (section 6) — both must use same decision: markers → fixed, no markers → saved |
| Cleanup paths (rate recovery) | `rate-limit-stop.sh` (section 5) — must clean resume file, prompt side file, markers |

## Enable

Re-enable auto-resume for the current project.

1. If `<cwd>/.claude/auto-resume.conf` exists: replace content with `enabled=true`
2. If it doesn't exist: tell the user "Auto-resume is already enabled (default)."
3. Report: "✓ Auto-resume enabled for this project."

## Disable

Disable auto-resume for the current project.

1. Create (or overwrite) `<cwd>/.claude/auto-resume.conf` with content: `enabled=false`
2. Kill any running daemons for this project: `pkill -f "claude-auto-resume.sh.*$(pwd)"`
3. Report: "✗ Auto-resume disabled for this project. Re-enable with `/auto-resume enable`."

## Status

Run: `bash ~/.claude/bin/auto-resume-status.sh`

Show the script output to the user. Do not generate your own version.

## Uninstall

Remove the auto-resume system globally.

1. Remove hook scripts: `~/.claude/hooks/rate-limit-stop.sh`, `rate-limit-stop-failure.sh`, `rate-limit-prompt-guard.sh`
2. Remove daemon: `~/.claude/bin/claude-auto-resume.sh`
3. Remove hook entries from `~/.claude/settings.json` (entries containing `rate-limit-stop`, `rate-limit-stop-failure`, `rate-limit-prompt-guard`)
4. Restore inner statusline if `~/.claude/statusline-inner.conf` exists
5. Kill any running daemons: `pkill -f "claude-auto-resume.sh"`
6. Do NOT remove: `~/.claude/bin/statusline-rate-cache-wrapper.sh` (may be used by other tools), `~/.claude/rate-limits.json`, logs, auto-resume state files, project conf files
