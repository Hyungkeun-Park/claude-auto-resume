# Gotchas

Edge cases and non-obvious behaviors discovered during development. Each entry explains what happened, why it was surprising, and how it was resolved.

---

## G1: Client-Side Rate Limiter Blocks AFTER Hooks

**What**: When rate limit is 100%, the client-side blocker fires *after* UserPromptSubmit hooks but *before* the API call. No hooks fire after the block — not Stop, not StopFailure, nothing.

**Why it matters**: If you only create schedules in Stop/StopFailure hooks, the first blocked prompt will never create a schedule. The session just dies with no recovery path.

**Resolution**: UserPromptSubmit hook creates the schedule speculatively ("create first, manage later"). If the client blocks, the schedule already exists. If the turn succeeds, Stop manages the schedule.

**Verified**: Production trace logs confirmed this ordering.

---

## G2: StopFailure Only Fires on API Errors, Not Client Blocks

**What**: StopFailure fires on HTTP 429 from the API, but NOT when the client-side rate limiter blocks the request before it reaches the API.

**Why it matters**: You cannot rely on StopFailure as the sole scheduling mechanism. Many rate limit scenarios never produce a StopFailure event.

**Resolution**: StopFailure is a fallback, not the primary path. The primary scheduling happens in UserPromptSubmit (speculative) and Stop (confirmatory).

**Verified**: Production testing confirmed StopFailure never fires on client-side blocks.

---

## G3: Overuse Mode Makes Hooks Fire Normally at 100%

**What**: When "additional usage" (overuse) is enabled, API calls succeed at 100% rate with reduced priority. All hooks fire normally — UserPromptSubmit, Stop, etc. The hooks see rate=100% and create schedules, but the session never actually stops.

**Why it matters**: Without overuse detection, every turn at 100% creates a schedule that persists → daemon spawns → tries to resume a session that's already running → wastes tokens and creates confusion.

**Resolution**: Track `created_at_rate` in the state file. If Stop fires at 100% and finds a schedule created at 100%, that proves the turn succeeded despite 100% rate → overuse is active → delete the schedule.

---

## G4: Ralph Loop Doesn't Traverse UserPromptSubmit After First Turn

**What**: Ralph's loop mechanism uses Stop hook `exit 2` to continue. After the first turn, subsequent iterations go directly from Stop → rate limit check → API, bypassing UserPromptSubmit entirely.

**Why it matters**: If overuse detection only existed in UserPromptSubmit, Ralph loops at 100% would never trigger it. The Stop hook must handle overuse detection independently.

**Resolution**: Stop hook has its own overuse detection block that catches the Ralph loop case: Stop creates schedule at 100% → next Ralph turn succeeds → Stop fires again → sees `created_at_rate >= 100` → deletes.

---

## G5: SubagentStop Is Not Overuse Evidence

**What**: When parallel subagents complete, SubagentStop fires for each one. Multiple SubagentStop events at 100% look like "repeated turns succeeding at 100%" but they're actually parallel completions from a single turn.

**Why it matters**: If overuse detection treated SubagentStop the same as Stop, it would falsely delete schedules during parallel agent work — even when overuse is NOT active.

**Resolution**: Overuse detection is gated on `EVENT = "Stop"` only. SubagentStop events are exempt. The `hook_event_name` field in the hook input JSON distinguishes them.

---

## G6: StopFailure Must Lock Against Overuse Detection

**What**: If a turn gets an API 429 error, StopFailure fires AND Stop fires (both fire on the same event). Without protection, Stop's overuse detection could delete a schedule that StopFailure just created/confirmed for a genuine rate limit.

**Why it matters**: A genuine API error at 100% should create a schedule (the session actually stopped). But if the schedule was speculatively created at 100% by UserPromptSubmit, Stop would see `created_at_rate=100` and classify it as overuse.

**Resolution**: StopFailure sets `source: "stop_failure"` on the state file. Stop's overuse detection skips files with `source == "stop_failure"`. This "locks" the schedule against false deletion.

---

## G7: pgrep Self-Matching in Daemon

**What**: The daemon's cmdline contains the session ID (passed as argument). When using `pgrep -f "claude.*$SESSION_ID"` to find active Claude sessions, the daemon matches itself — falsely detecting an "active session" and skipping resume.

**Why it matters**: Every resume attempt would be skipped because the daemon always matches its own process.

**Resolution (v1)**: `pgrep -af` + `grep -v "auto-resume"` to exclude the daemon process.
**Resolution (v2)**: Replaced with `pgrep -x claude` (exact binary name match) + `/proc/$pid/cmdline` direct inspection with explicit `auto-resume` exclusion. More robust and avoids shell quoting issues.

---

## G8: jq `//` Operator Does Not Catch `false`

**What**: In jq, `false // "default"` returns `"default"`, not `false`. The `//` (alternative) operator treats both `null` and `false` as "empty".

**Why it matters**: If a JSON field is legitimately `false` (e.g., an `overage` boolean), `jq -r '.overage // "unknown"'` would return `"unknown"` instead of `"false"`.

**Resolution**: Use explicit `if .field == false then "false" else (.field // "default") end` for boolean fields. In practice, the v4 design avoids boolean fields in state files entirely, using numeric `created_at_rate` and string `source` instead.

---

## G9: `set -euo pipefail` + jq on Invalid JSON = Silent Exit

**What**: Under `set -e`, if jq fails to parse corrupted JSON, the script exits immediately with no error message. The hook silently disappears, and no schedule is created or updated.

**Why it matters**: A single corrupted state file could silently disable auto-resume for that session.

**Resolution**: Every jq read uses `jq ... 2>/dev/null || echo ""` (or `|| echo "0"` for numeric fields). This ensures the script continues even on corrupted input. The fallback values cause the hook to fall through to the "create new file" path.

---

## G10: Race Window Between Stop and StopFailure (TOCTOU)

**What**: Stop and StopFailure can both read the same state file. If Stop reads `source=user_prompt`, then StopFailure writes `source=stop_failure`, then Stop deletes based on its stale read — the lock is defeated.

**Why it matters**: A genuine API error could have its schedule incorrectly classified as overuse and deleted.

**Resolution**: Stop re-reads the `source` field immediately before deletion (TOCTOU guard). If the re-read shows `stop_failure`, the deletion is aborted. The window is now reduced to the time between the re-read and the `rm` — effectively negligible.

**Practical risk**: Very low. Claude hooks fire sequentially within a session's event lifecycle. This race requires concurrent hook execution for the same session across different events.

---

## G11: Statusline JSON String Interpolation Vulnerability

**What**: The original statusline wrapper used shell string interpolation to build JSON: `"{\"rate\":${value}}"`. If the parsed value contained unexpected characters, the JSON would be malformed.

**Why it matters**: Malformed `rate-limits.json` would cause all hooks to skip processing (jq parse failure → fallback to 0 → rate < 100% → exit).

**Resolution**: Replaced with `jq -n --argjson` for all JSON construction. jq handles escaping and type validation.

---

## G12: Active Session Kill Is Dangerous

**What (v1)**: The daemon detected active sessions via pgrep and killed them before resuming, assuming it could restart them cleanly via tmux or headless mode.

**Why it matters**: Killing an active session discards the user's in-progress work, loses context, and can corrupt state. If the user is actively typing, their work is gone.

**Resolution (v4)**: Active sessions are skipped, not killed. The daemon archives the state file as `"skipped" / "session_still_active"` and exits. The user's session continues undisturbed. With overuse detection, unnecessary schedules are already cleaned up, so the daemon rarely encounters an active session.

---

## G13: Daemon Unbounded Blocking on `claude -p --resume`

**What**: If `claude -p --resume` hangs (e.g., waiting for user input that never comes in headless mode), the daemon blocks forever — consuming a process slot and holding the state file.

**Why it matters**: A stuck daemon prevents cleanup and may cause duplicate daemons on subsequent hook fires.

**Resolution**: Wrapped with `timeout 3600` (1 hour). If the resume doesn't complete in 1 hour, it's killed and archived as failed.

---

## G14: Shell Profile Dependency in Daemon

**What (v1)**: The daemon sourced `~/.bashrc` / `~/.zshrc` to set up PATH before finding the `claude` binary. In non-login shells (nohup, cron), these profiles may not exist or may error out.

**Why it matters**: The daemon would fail to find `claude` and archive every resume as failed.

**Resolution (v4)**: Explicit `find_claude_bin()` function that checks `command -v claude`, then iterates known paths (`~/.claude/local/bin/claude`, `~/.local/bin/claude`, `/usr/local/bin/claude`, `/opt/homebrew/bin/claude`). No shell profile dependency.

---

## G15: Resume Metadata Absence

**What**: When a session was auto-resumed, there was no indication within the session itself that it had been resumed, or how long it waited.

**Why it matters**: The model (and user reviewing transcripts) couldn't distinguish a manual resume from an auto-resume, making debugging and behavior tuning harder.

**Resolution**: The daemon prepends `[Auto-resumed after {N}m wait for rate limit recovery]` to the prompt. This appears in the session transcript and gives the model context about the gap.

---

## Adding New Gotchas

When discovering a new edge case, add an entry following this template:

```markdown
## G{N}: {Short Title}

**What**: {What happened or what the behavior is}

**Why it matters**: {Why this is surprising or what breaks without handling it}

**Resolution**: {How it was fixed}
```

Number sequentially. Reference the relevant source file and line numbers if helpful.
