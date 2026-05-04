# G5: SubagentStop Is Not Overuse Evidence

**What**: When parallel subagents complete, SubagentStop fires for each one. Multiple SubagentStop events at 100% look like "repeated turns succeeding at 100%" but they're actually parallel completions from a single turn.

**Why it matters**: If overuse detection treated SubagentStop the same as Stop, it would falsely delete schedules during parallel agent work — even when overuse is NOT active.

**Resolution**: Overuse detection is gated on `EVENT = "Stop"` only. SubagentStop events are exempt. The `hook_event_name` field in the hook input JSON distinguishes them.
