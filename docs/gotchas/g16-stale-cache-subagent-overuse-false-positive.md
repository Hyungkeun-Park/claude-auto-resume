# G16: Stale Cache During Subagent Execution (Overuse False Positive)

**What**: When subagents hit rate limit ("You've hit your limit"), the parent session's rate cache still shows pre-subagent values (e.g., 85%). SubagentStop fires but the hook sees rate < 100% and exits without creating a schedule. Later, UserPromptSubmit creates a schedule when the cache finally updates, but the subsequent Stop event classifies it as overuse (turn completed at 100%) and deletes it.

**Why it matters**: This is a two-bug chain that completely defeats auto-resume for the most common parallel-agent rate limit scenario:
- **Bug 1 (stale cache)**: The statusline cache is updated only by the parent session's API response headers. While the parent waits for subagents, the cache is stale — subagent quota consumption is invisible.
- **Bug 2 (overuse false positive)**: The parent turn completes successfully (in overuse mode), so Stop's overuse detection fires. But subagents within that turn FAILED, meaning the work was not completed.

**Observed production sequence**:
```
SubagentStop(rate-limited) → cache=85% → exit 0 (silent, no schedule)
UserPromptSubmit           → cache=101% → schedule created
Stop                       → cache=101% → OVERUSE_DETECTED → schedule deleted
```

**Root cause**: Hook input for SubagentStop contains no rate limit data — only lifecycle fields (`agent_id`, `cwd`, `session_id`, etc.). The rate cache is the sole rate data source, and it only reflects the parent's last API response.

**Key discovery**: SubagentStop DOES fire for rate-limited subagents, but with a 10+ minute delay compared to successful subagents. The parent Stop fires first, creating a timing gap where the rate-limited subagent's marker still exists.

**Resolution (v1.2.0)**: Subagent marker tracking via SubagentStart hook.
1. SubagentStart creates marker file at `subagents/<session_id>/<agent_id>`
2. SubagentStop deletes marker (runs before cache check, so stale cache won't skip it)
3. Stop checks for surviving markers before overuse detection — if any exist, overuse is skipped

The timing difference is the key: successful SubagentStop fires immediately (marker deleted before parent Stop), while rate-limited SubagentStop fires much later (marker survives through parent Stop → overuse skipped → schedule preserved).

**Verified**: Production diagnostic logs confirmed the timing gap. Test cases T57-T66 cover the full marker lifecycle.
