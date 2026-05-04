# G1: Client-Side Rate Limiter Blocks AFTER Hooks

**What**: When rate limit is 100%, the client-side blocker fires *after* UserPromptSubmit hooks but *before* the API call. No hooks fire after the block — not Stop, not StopFailure, nothing.

**Why it matters**: If you only create schedules in Stop/StopFailure hooks, the first blocked prompt will never create a schedule. The session just dies with no recovery path.

**Resolution**: UserPromptSubmit hook creates the schedule speculatively ("create first, manage later"). If the client blocks, the schedule already exists. If the turn succeeds, Stop manages the schedule.

**Verified**: Production trace logs confirmed this ordering.
