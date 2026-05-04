# G6: StopFailure Must Lock Against Overuse Detection

**What**: If a turn gets an API 429 error, StopFailure fires AND Stop fires (both fire on the same event). Without protection, Stop's overuse detection could delete a schedule that StopFailure just created/confirmed for a genuine rate limit.

**Why it matters**: A genuine API error at 100% should create a schedule (the session actually stopped). But if the schedule was speculatively created at 100% by UserPromptSubmit, Stop would see `created_at_rate=100` and classify it as overuse.

**Resolution**: StopFailure sets `source: "stop_failure"` on the state file. Stop's overuse detection skips files with `source == "stop_failure"`. This "locks" the schedule against false deletion.
