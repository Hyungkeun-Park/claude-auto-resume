# G4: Ralph Loop Doesn't Traverse UserPromptSubmit After First Turn

**What**: Ralph's loop mechanism uses Stop hook `exit 2` to continue. After the first turn, subsequent iterations go directly from Stop → rate limit check → API, bypassing UserPromptSubmit entirely.

**Why it matters**: If overuse detection only existed in UserPromptSubmit, Ralph loops at 100% would never trigger it. The Stop hook must handle overuse detection independently.

**Resolution**: Stop hook has its own overuse detection block that catches the Ralph loop case: Stop creates schedule at 100% → next Ralph turn succeeds → Stop fires again → sees `created_at_rate >= 100` → deletes.
