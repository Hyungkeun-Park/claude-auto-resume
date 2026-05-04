# G3: Overuse Mode Makes Hooks Fire Normally at 100%

**What**: When "additional usage" (overuse) is enabled, API calls succeed at 100% rate with reduced priority. All hooks fire normally — UserPromptSubmit, Stop, etc. The hooks see rate=100% and create schedules, but the session never actually stops.

**Why it matters**: Without overuse detection, every turn at 100% creates a schedule that persists → daemon spawns → tries to resume a session that's already running → wastes tokens and creates confusion.

**Resolution**: Track `created_at_rate` in the state file. If Stop fires at 100% and finds a schedule created at 100%, that proves the turn succeeded despite 100% rate → overuse is active → delete the schedule.
